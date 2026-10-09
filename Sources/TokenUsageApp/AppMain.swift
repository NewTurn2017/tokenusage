import AppKit

@main
@MainActor
struct TokenUsageApp {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        if environment["TOKENUSAGE_COMPOSITION_SMOKE"] == "1" {
            await MenuBarController.runCompositionSmoke(environment: environment)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var isStopping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = Self.otherInstances()
        guard !others.isEmpty else { return startController() }

        // The newest launch (a reinstall or update) takes over from a copy that is still running,
        // and never runs beside it: two copies would both renew the same stored refresh token,
        // and the one that loses that race signs the account out.
        others.forEach { $0.terminate() }
        Task {
            let deadline = Date().addingTimeInterval(Self.handoverTimeout)
            while others.contains(where: { !$0.isTerminated }), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if others.contains(where: { !$0.isTerminated }) {
                NSApplication.shared.terminate(nil)
            } else {
                startController()
            }
        }
    }

    private static let handoverTimeout: TimeInterval = 15

    private static func otherInstances() -> [NSRunningApplication] {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return [] }
        let current = NSRunningApplication.current.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != current }
    }

    private func startController() {
        let controller = MenuBarController.production()
        menuBarController = controller
        controller.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isStopping, let menuBarController else { return .terminateNow }
        isStopping = true
        Task {
            await menuBarController.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
