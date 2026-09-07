import Foundation
import XCTest
@testable import TokenUsageApp
import TokenUsageCore

final class ClaudeLoginRunnerTests: XCTestCase {
    func testTheSignInURLIsRecordedWithoutOpeningASecondTab() {
        let controller = CodexLoginAttemptController()
        let opener = BrowserOpenerSpy()
        let observer = ClaudeLoginOutputObserver(
            attemptController: controller,
            browserOpener: { opener.record($0) }
        )
        controller.begin {}

        // The CLI wraps the URL in an OSC-8 hyperlink and opens the browser itself.
        let recognized = observer.consume(Data("""
        Opening browser to sign in…
        If the browser didn't open, visit: \u{1b}]8;;https://claude.com/oauth/authorize?code=1\u{1b}\\link\u{1b}]8;;\u{1b}\\
        """.utf8))

        XCTAssertTrue(recognized)
        XCTAssertEqual(opener.urls, [], "the CLI already opened it")
        XCTAssertTrue(controller.presentation.canReopenSignIn)
        XCTAssertTrue(controller.reopenSignIn())
        XCTAssertEqual(
            opener.urls.map(\.absoluteString),
            ["https://claude.com/oauth/authorize?code=1"]
        )
    }

    func testAURLSplitAcrossOutputChunksIsStillRecognized() {
        let controller = CodexLoginAttemptController()
        let opener = BrowserOpenerSpy()
        let observer = ClaudeLoginOutputObserver(
            attemptController: controller,
            browserOpener: { opener.record($0) }
        )
        controller.begin {}

        XCTAssertFalse(observer.consume(Data("visit: https://claude.co".utf8)))
        XCTAssertTrue(observer.consume(Data("m/oauth/authorize?code=2\n".utf8)))

        XCTAssertTrue(controller.reopenSignIn())
        XCTAssertEqual(
            opener.urls.map(\.absoluteString),
            ["https://claude.com/oauth/authorize?code=2"]
        )
    }

    func testOnlyAnthropicSignInHostsAreAccepted() {
        for allowed in [
            "https://claude.com/oauth",
            "https://claude.ai/oauth",
            "https://console.anthropic.com/oauth",
        ] {
            XCTAssertTrue(
                ClaudeLoginOutputObserver.isAllowed(URL(string: allowed)!),
                allowed
            )
        }
        for refused in [
            "http://claude.com/oauth",
            "https://claude.com.evil.test/oauth",
            "https://evil.test/claude.com",
        ] {
            XCTAssertFalse(
                ClaudeLoginOutputObserver.isAllowed(URL(string: refused)!),
                refused
            )
        }
    }

    func testTheSignInRunsAgainstTheThrowawayDirectoryWithItsExecutableOnPath() {
        let environment = SystemClaudeLoginRunner.loginEnvironment(
            ["PATH": "/usr/bin:/bin", "HOME": "/Users/example"],
            executable: URL(fileURLWithPath: "/Users/example/.local/bin/claude"),
            configurationDirectory: URL(fileURLWithPath: "/tmp/throwaway")
        )

        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/throwaway")
        XCTAssertEqual(environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"], "/tmp/throwaway")
        XCTAssertEqual(environment["PATH"], "/Users/example/.local/bin:/usr/bin:/bin")
    }

    func testCancellingMarksTheAttemptRatherThanReportingAFailure() {
        let controller = CodexLoginAttemptController()
        let observer = ClaudeLoginOutputObserver(
            attemptController: controller,
            browserOpener: { _ in true }
        )

        XCTAssertFalse(observer.wasCancelled)
        observer.cancel()
        XCTAssertTrue(observer.wasCancelled)
    }
}

private final class BrowserOpenerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [URL] = []

    func record(_ url: URL) -> Bool {
        lock.withLock { opened.append(url) }
        return true
    }

    var urls: [URL] {
        lock.withLock { opened }
    }
}
