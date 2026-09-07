import Foundation
import XCTest
@testable import TokenUsageApp
import TokenUsageCore

/// Drives the real `claude auth login` against a throwaway configuration directory and cancels it.
///
/// It spawns the installed CLI, which opens a browser tab, so it only runs when asked for:
/// `TOKENUSAGE_CLAUDE_LOGIN_INTEGRATION=1 swift test --filter ClaudeLoginRunnerIntegrationTests`.
/// No sign-in is completed and the account this machine is signed in as is never read.
final class ClaudeLoginRunnerIntegrationTests: XCTestCase {
    func testARealSignInStartsInIsolationAndCancelsCleanly() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TOKENUSAGE_CLAUDE_LOGIN_INTEGRATION"] == "1",
            "Set TOKENUSAGE_CLAUDE_LOGIN_INTEGRATION=1 to spawn the real claude CLI."
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenusage-login-it-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let attemptController = CodexLoginAttemptController()
        let runner = SystemClaudeLoginRunner(
            attemptController: attemptController
        )
        let outcome = Task { try await runner.runClaudeLogin(configurationDirectory: directory) }

        // The CLI prints the sign-in URL within a few seconds; the attempt exposes it for reopening.
        var attempts = 0
        while !attemptController.presentation.canReopenSignIn, attempts < 60 {
            try await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        let sawSignInURL = attemptController.presentation.canReopenSignIn
        XCTAssertTrue(attemptController.presentation.canCancel)

        attemptController.cancelSignIn()
        let result = try await outcome.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(sawSignInURL, "the sign-in URL must be captured so the tab can be reopened")
        // The isolated directory gets its own settings file, never the real one.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".claude.json").path
            )
        )
        print(
            "CLAUDE_QA real_login isolated_dir=redacted url_captured=\(sawSignInURL) "
                + "outcome=\(result)"
        )
    }
}
