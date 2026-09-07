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
