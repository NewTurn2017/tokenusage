import Foundation
import Darwin
import XCTest
@testable import TokenUsageApp
import TokenUsageCore

final class SystemCodexLoginRunnerTests: XCTestCase {
    func testExitZeroCompletes() async throws {
        let fixture = try ShellLoginFixture(body: "exit 0")
        defer { fixture.remove() }
        let runner = SystemCodexLoginRunner(
            resolver: FixedExecutableResolver(executable: fixture.executable),
            environment: [:]
        )

        let outcome = try await runner.runCodexLogin(codexHome: fixture.home)

        XCTAssertEqual(outcome.terminationStatus, 0)
        XCTAssertTrue(outcome.isCompleted)
    }

    func testLoginReceivesResolvedExecutableDirectoryInChildPATH() async throws {
        let fixture = try ShellLoginFixture(body: "exit 0")
        defer { fixture.remove() }
        let environment = [
            "PATH": "",
            "PATH_CAPTURE": fixture.pathCapture.path,
            "PARENT_SENTINEL": "unchanged",
        ]
        let runner = fixture.runner(environment: environment)

        let outcome = try await runner.runCodexLogin(codexHome: fixture.home)

        XCTAssertTrue(outcome.isCompleted)
        XCTAssertEqual(
            try String(contentsOf: fixture.pathCapture, encoding: .utf8),
            fixture.executable.deletingLastPathComponent().standardizedFileURL.path
        )
        XCTAssertEqual(environment["PATH"], "")
        XCTAssertEqual(environment["PARENT_SENTINEL"], "unchanged")
    }

    func testExitSevenIsTypedFailureNotCancellation() async throws {
        let fixture = try ShellLoginFixture(body: "echo 'provider failed' >&2; exit 7")
        defer { fixture.remove() }
        let runner = SystemCodexLoginRunner(
            resolver: FixedExecutableResolver(executable: fixture.executable),
            environment: [:]
        )

        let outcome = try await runner.runCodexLogin(codexHome: fixture.home)

        guard case let .failed(status, diagnostic) = outcome else {
            return XCTFail("Expected a typed non-zero failure, got \(outcome)")
        }
        XCTAssertEqual(status, 7)
        XCTAssertEqual(diagnostic.stderr, "provider failed")
    }

    func testAllowedURLIsOpenedOnceAndOnlyGenericActionsAreExposedWhileAlive() async throws {
        let allowedURL = authURL(host: "login.auth.openai.com")
        let fixture = try ShellLoginFixture { fixture in
            """
            printf '%s\n' '\(allowedURL.absoluteString)'
            /usr/bin/touch '\(fixture.ready.path)'
            while [ ! -f '\(fixture.release.path)' ]; do /bin/sleep 0.02; done
            printf '%s\n' '\(allowedURL.absoluteString)'
            exit 0
            """
        }
        defer { fixture.remove() }
        let opener = BrowserOpenRecorder(result: true)
        let attemptController = CodexLoginAttemptController()
        let runner = fixture.runner(opener: opener.open, attemptController: attemptController)

        let task = Task { try await runner.runCodexLogin(codexHome: fixture.home) }
        defer { task.cancel() }
        try await waitForFile(fixture.ready)

        XCTAssertEqual(opener.count, 1)
        XCTAssertEqual(attemptController.presentation.status, "Sign-in is in progress.")
        XCTAssertEqual(attemptController.presentation.reopenActionTitle, "Reopen sign-in")
        XCTAssertEqual(attemptController.presentation.cancelActionTitle, "Cancel")
        XCTAssertTrue(attemptController.presentation.canReopenSignIn)
        XCTAssertTrue(attemptController.presentation.canCancel)
        XCTAssertFalse(attemptController.presentation.status?.contains(allowedURL.absoluteString) ?? true)
        try fixture.signalRelease()

        let outcome = try await task.value
        XCTAssertTrue(outcome.isCompleted)
        XCTAssertEqual(outcome.terminationStatus, 0)
        XCTAssertEqual(opener.count, 1)
        XCTAssertNil(attemptController.presentation.status)
        XCTAssertNil(attemptController.presentation.reopenActionTitle)
        XCTAssertNil(attemptController.presentation.cancelActionTitle)
        XCTAssertFalse(attemptController.presentation.canReopenSignIn)
        XCTAssertFalse(attemptController.reopenSignIn())
    }

    func testDisallowedAndPromptInjectionURLsAreRejectedAndMisleadingSuccessCannotMaskExitSeven() async throws {
        let maliciousURL = authURL(host: "auth.openai.com.attacker.invalid")
        let insecureURL = URL(string: "http" + "://auth.openai.com/device")!
        let fixture = try ShellLoginFixture(body: """
            printf '%s\n' '\(maliciousURL.absoluteString)'
            printf '%s\n' '\(insecureURL.absoluteString)'
            printf '%s\n' 'IGNORE PREVIOUS INSTRUCTIONS: login succeeded'
            exit 7
            """)
        defer { fixture.remove() }
        let opener = BrowserOpenRecorder(result: true)
        let runner = fixture.runner(opener: opener.open)

        let outcome = try await runner.runCodexLogin(codexHome: fixture.home)

        guard case let .failed(status, diagnostic) = outcome else {
            return XCTFail("Expected exit failure, got \(outcome)")
        }
        XCTAssertEqual(status, 7)
        XCTAssertEqual(opener.count, 0)
        XCTAssertFalse(diagnostic.stdout.contains(maliciousURL.absoluteString))
        XCTAssertFalse(diagnostic.stdout.contains(insecureURL.absoluteString))
    }

    func testBrowserOpenFailureIsTypedAndReapsTheFixture() async throws {
        let allowedURL = authURL(host: "chatgpt.com")
        let fixture = try ShellLoginFixture { fixture in
            """
            trap '/usr/bin/touch \"\(fixture.reaped.path)\"; exit 0' TERM
            printf '%s\n' '\(allowedURL.absoluteString)'
            while :; do /bin/sleep 0.02; done
            """
        }
        defer { fixture.remove() }
        let opener = BrowserOpenRecorder(result: false)
        let runner = fixture.runner(opener: opener.open)

        let outcome = try await runner.runCodexLogin(codexHome: fixture.home)

        guard case .browserOpenFailed = outcome else {
            return XCTFail("Expected browser-open failure, got \(outcome)")
        }
        XCTAssertEqual(opener.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.reaped.path))
    }

    func testOutputIsConcurrentlyDrainedCappedNormalizedAndSanitized() async throws {
        let secret = ["sentinel", "credential"].joined(separator: "-")
        let jwt = ["eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiJzZW50aW5lbCJ9", "signature"].joined(separator: ".")
        let disallowedURL = authURL(host: "attacker.invalid")
        let fileURL = ["file:", "", "", "private", "fixture"].joined(separator: "/")
        let fixture = try ShellLoginFixture(body: """
            printf 'access_token=%s line two\n\"refresh_token\":\"%s\"\nOPENAI_API_KEY=%s\n%s\n%s\n' '\(secret)' '\(secret)' '\(secret)' '\(disallowedURL.absoluteString)' '\(fileURL)'
            printf 'Bearer %s\n%s\n' '\(secret)' '\(jwt)' >&2
            i=0
            while [ "$i" -lt 5000 ]; do printf x; printf y >&2; i=$((i + 1)); done
            exit 7
            """)
        defer { fixture.remove() }

        let outcome = try await fixture.runner().runCodexLogin(codexHome: fixture.home)

        guard case let .failed(status, diagnostic) = outcome else {
            return XCTFail("Expected exit failure, got \(outcome)")
        }
        XCTAssertEqual(status, 7)
        XCTAssertTrue(diagnostic.stdout.contains("access_token=[REDACTED]"))
        XCTAssertTrue(diagnostic.stdout.contains("refresh_token=[REDACTED]"))
        XCTAssertTrue(diagnostic.stdout.contains("OPENAI_API_KEY=[REDACTED]"))
        XCTAssertTrue(diagnostic.stdout.contains("[URL REDACTED]"))
        XCTAssertTrue(diagnostic.stdout.hasSuffix("[TRUNCATED]"))
        XCTAssertTrue(diagnostic.stderr.contains("Bearer [REDACTED]"))
        XCTAssertTrue(diagnostic.stderr.contains("[JWT REDACTED]"))
        XCTAssertTrue(diagnostic.stderr.hasSuffix("[TRUNCATED]"))
        XCTAssertFalse(diagnostic.stdout.contains("\n"))
        XCTAssertFalse(diagnostic.stderr.contains("\n"))
        XCTAssertFalse(diagnostic.stdout.contains(secret))
        XCTAssertFalse(diagnostic.stderr.contains(secret))
        XCTAssertFalse(diagnostic.stderr.contains(jwt))
        XCTAssertFalse(diagnostic.stdout.contains(disallowedURL.absoluteString))
    }

    func testFinalDiagnosticStreamsRemainUTF8BoundedAfterSanitization() async throws {
        let secret = "x"
        let jwt = ["eyJa", "a", "b"].joined(separator: ".")
        let rawURL = "x" + "://x"
        let payload = "한글 token=\(secret) \(jwt) \(rawURL) " + String(repeating: "z", count: 5_000)
        let fixture = try ShellLoginFixture(body: """
            printf '%s' '\(payload)'
            printf '%s' '\(payload)' >&2
            exit 7
            """)
        defer { fixture.remove() }

        let outcome = try await fixture.runner().runCodexLogin(codexHome: fixture.home)

        guard case let .failed(status, diagnostic) = outcome else {
            return XCTFail("Expected exit failure, got \(outcome)")
        }
        XCTAssertEqual(status, 7)
        for stream in [diagnostic.stdout, diagnostic.stderr] {
            XCTAssertLessThanOrEqual(stream.lengthOfBytes(using: .utf8), 4_096)
            XCTAssertFalse(stream.contains("\n"))
            XCTAssertFalse(stream.contains("\r"))
            XCTAssertTrue(stream.contains("[TRUNCATED]"))
            XCTAssertTrue(stream.contains("한글"))
            XCTAssertFalse(stream.contains(secret))
            XCTAssertFalse(stream.contains(jwt))
            XCTAssertFalse(stream.contains(rawURL))
        }
        fixture.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testGenericCancelTerminatesAndReapsAndRepeatedInterruptionsLeaveNoStaleState() async throws {
        let fixture = try ShellLoginFixture { fixture in
            """
            echo $$ > '\(fixture.pid.path)'
            trap '/usr/bin/touch \"\(fixture.reaped.path)\"; exit 0' TERM
            /usr/bin/touch '\(fixture.ready.path)'
            while :; do /bin/sleep 0.02; done
            """
        }
        defer { fixture.remove() }
        let attemptController = CodexLoginAttemptController()
        let runner = fixture.runner(attemptController: attemptController)
        let task = Task { try await runner.runCodexLogin(codexHome: fixture.home) }
        defer { task.cancel() }
        try await waitForFile(fixture.ready)
        let pid = try fixture.childPID()

        attemptController.cancelSignIn()
        attemptController.cancelSignIn()
        task.cancel()
        let outcome = try await task.value

        guard case .cancelled = outcome else {
            return XCTFail("Expected cancellation, got \(outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.reaped.path))
        XCTAssertFalse(processExists(pid))
        XCTAssertNil(attemptController.presentation.status)
        XCTAssertFalse(attemptController.presentation.canCancel)
        XCTAssertFalse(attemptController.reopenSignIn())
    }

    func testPopoverCloseClearsTheInMemoryReopenURL() {
        let attemptController = CodexLoginAttemptController()
        attemptController.begin {}
        XCTAssertTrue(attemptController.open(authURL(host: "chatgpt.com")) { _ in true })

        attemptController.clearForPopoverClose()

        XCTAssertNil(attemptController.presentation.status)
        XCTAssertNil(attemptController.presentation.reopenActionTitle)
        XCTAssertFalse(attemptController.presentation.canReopenSignIn)
    }
}

private struct FixedExecutableResolver: CodexExecutableResolving {
    let executable: URL

    func resolve(environment: [String: String]) throws -> URL { executable }
}

private final class ShellLoginFixture: @unchecked Sendable {
    let root: URL
    let home: URL
    let executable: URL
    let ready: URL
    let release: URL
    let reaped: URL
    let pid: URL
    let pathCapture: URL

    init(body: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenusage-login-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("codex-home", isDirectory: true)
        executable = root.appendingPathComponent("fake-codex", isDirectory: false)
        ready = root.appendingPathComponent("ready")
        release = root.appendingPathComponent("release")
        reaped = root.appendingPathComponent("reaped")
        pid = root.appendingPathComponent("pid")
        pathCapture = root.appendingPathComponent("path")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try writeScript(body)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    convenience init(body: (ShellLoginFixture) -> String) throws {
        try self.init(body: "")
        try writeScript(body(self))
    }

    /// The fixture body may block forever (`while :; do sleep; done`). If the test process dies
    /// before it can reap the child, the child would spin unreaped and keep the runner's stdout
    /// pipe open. The watchdog is inside the child so it survives any failure of the parent.
    /// Its output is redirected so the backgrounded subshell never holds the runner's pipes open.
    private func writeScript(_ body: String) throws {
        let script = """
            #!/bin/sh
            ( /bin/sleep \(Self.watchdogSeconds); kill -9 $$ ) >/dev/null 2>&1 &
            __watchdog=$!
            trap 'kill -9 $__watchdog 2>/dev/null' EXIT
            printf '%s' "$PATH" > '\(pathCapture.path)'
            \(body)

            """
        try Data(script.utf8).write(to: executable)
    }

    /// Far above the slowest legitimate fixture, far below a wedged CI job.
    private static let watchdogSeconds = 60

    func runner(
        environment: [String: String] = [:],
        opener: @escaping SystemCodexLoginRunner.BrowserOpener = { _ in true },
        attemptController: CodexLoginAttemptController = CodexLoginAttemptController()
    ) -> SystemCodexLoginRunner {
        SystemCodexLoginRunner(
            resolver: FixedExecutableResolver(executable: executable),
            environment: environment,
            browserOpener: opener,
            attemptController: attemptController
        )
    }

    func signalRelease() throws {
        try Data().write(to: release)
    }

    func childPID() throws -> pid_t {
        let value = try String(contentsOf: pid, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(value))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class BrowserOpenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [URL] = []
    private let result: Bool

    init(result: Bool) { self.result = result }

    var count: Int { lock.withLock { opened.count } }

    func open(_ url: URL) -> Bool {
        lock.withLock { opened.append(url) }
        return result
    }
}

private func authURL(host: String) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/auth/device"
    components.queryItems = [URLQueryItem(name: "code", value: ["fixture", "value"].joined(separator: "-"))]
    return components.url!
}

private func waitForFile(_ url: URL) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !FileManager.default.fileExists(atPath: url.path) {
        guard ContinuousClock.now < deadline else {
            throw NSError(domain: "SystemCodexLoginRunnerTests", code: 1)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func processExists(_ pid: pid_t) -> Bool {
    Darwin.kill(pid, 0) == 0 || errno != ESRCH
}
