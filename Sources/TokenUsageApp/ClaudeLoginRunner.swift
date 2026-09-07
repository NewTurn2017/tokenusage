import AppKit
import Foundation
import TokenUsageCore

/// Runs `claude auth login` against a throwaway configuration directory.
///
/// The CLI opens the browser itself, so the scraped URL is only recorded - reopening it is the
/// user's call when the tab is lost. The sign-in attempt is shared with the Codex flow because
/// the popover disables every profile control while one is running, so only one can be live.
final class SystemClaudeLoginRunner: ClaudeLoginRunning, @unchecked Sendable {
    typealias BrowserOpener = @Sendable (URL) -> Bool

    private let resolver: any ClaudeExecutableResolving
    private let environment: [String: String]
    private let browserOpener: BrowserOpener
    let attemptController: CodexLoginAttemptController

    init(
        resolver: any ClaudeExecutableResolving = InstalledClaudeExecutableResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        browserOpener: @escaping BrowserOpener = { NSWorkspace.shared.open($0) },
        attemptController: CodexLoginAttemptController = CodexLoginAttemptController()
    ) {
        self.resolver = resolver
        self.environment = environment
        self.browserOpener = browserOpener
        self.attemptController = attemptController
    }

    func runClaudeLogin(configurationDirectory: URL) async throws -> ClaudeLoginOutcome {
        let executable = try resolver.resolve(environment: environment)
        let process = OwnedProcess(
            executable: executable,
            arguments: ["auth", "login"],
            environment: Self.loginEnvironment(
                environment,
                executable: executable,
                configurationDirectory: configurationDirectory
            )
        )
        let observer = ClaudeLoginOutputObserver(
            attemptController: attemptController,
            browserOpener: browserOpener
        )
        process.setOutputHandler { observer.consume($0) }
        attemptController.begin {
            observer.cancel()
            process.terminate()
        }
        defer { attemptController.clear() }
        do {
            try process.start()
        } catch {
            attemptController.clear()
            throw error
        }
        return await withTaskCancellationHandler {
            let status = await process.waitUntilExit()
            if Task.isCancelled || observer.wasCancelled { return .cancelled }
            if status == 0 { return .completed }
            return .failed(terminationStatus: status)
        } onCancel: {
            process.terminate()
        }
    }

    static func loginEnvironment(
        _ environment: [String: String],
        executable: URL,
        configurationDirectory: URL
    ) -> [String: String] {
        var isolated = ClaudeCLIEnvironment.isolating(
            environment,
            configurationDirectory: configurationDirectory
        )
        let executableDirectory = executable.standardizedFileURL
            .deletingLastPathComponent()
            .path
        let existingPath = environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != executableDirectory } ?? []
        isolated["PATH"] = ([executableDirectory] + existingPath).joined(separator: ":")
        return isolated
    }
}

final class ClaudeLoginOutputObserver: @unchecked Sendable {
    /// Stops at any control character so the OSC-8 hyperlink the CLI prints does not become part
    /// of the URL.
    private static let urlExpression = try! NSRegularExpression(
        pattern: #"https://[^\s<>"'\x00-\x1f]+"#,
        options: [.caseInsensitive]
    )
    private let lock = NSLock()
    private let attemptController: CodexLoginAttemptController
    private let browserOpener: SystemClaudeLoginRunner.BrowserOpener
    private var scanTail = ""
    private var registeredURL: URL?
    private var didCancel = false

    init(
        attemptController: CodexLoginAttemptController,
        browserOpener: @escaping SystemClaudeLoginRunner.BrowserOpener
    ) {
        self.attemptController = attemptController
        self.browserOpener = browserOpener
    }

    var wasCancelled: Bool { lock.withLock { didCancel } }

    func cancel() {
        lock.withLock { didCancel = true }
    }

    @discardableResult
    func consume(_ data: Data) -> Bool {
        let chunk = String(decoding: data, as: UTF8.self)
        let url: URL? = lock.withLock {
            guard registeredURL == nil else { return nil }
            let candidateText = scanTail + chunk
            scanTail = String(candidateText.suffix(2_048))
            let range = NSRange(candidateText.startIndex..., in: candidateText)
            for match in Self.urlExpression.matches(in: candidateText, range: range) {
                guard let matchRange = Range(match.range, in: candidateText) else { continue }
                let raw = String(candidateText[matchRange]).trimmingCharacters(
                    in: CharacterSet(charactersIn: ").,;]}")
                )
                guard let url = URL(string: raw), Self.isAllowed(url) else { continue }
                registeredURL = url
                return url
            }
            return nil
        }
        guard let url else { return false }
        attemptController.registerSignInURL(url, using: browserOpener)
        return true
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return ["claude.com", "claude.ai", "anthropic.com"].contains {
            host == $0 || host.hasSuffix(".\($0)")
        }
    }
}
