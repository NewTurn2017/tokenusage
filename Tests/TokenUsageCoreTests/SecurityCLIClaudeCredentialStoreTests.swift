import Foundation
import XCTest
@testable import TokenUsageCore

final class SecurityCLIClaudeCredentialStoreTests: XCTestCase {
    func testSuccessUsesAbsoluteSecurityAndExactArguments() throws {
        let runner = RecordingSecurityCLIProcessRunner(
            result: .init(terminationStatus: 0, stdout: Data("credential-bytes".utf8))
        )
        let store = SecurityCLIClaudeCredentialStore(runner: runner)

        XCTAssertEqual(try store.credential(named: "alice"), Data("credential-bytes".utf8))
        XCTAssertEqual(runner.invocations, [
            .init(
                executable: URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            )
        ])
    }

    func testSuccessTrimsOnlyOneTrailingNewline() throws {
        let runner = RecordingSecurityCLIProcessRunner(
            result: .init(terminationStatus: 0, stdout: Data([0x61, 0x0a, 0x0a]))
        )
        let store = SecurityCLIClaudeCredentialStore(runner: runner)

        XCTAssertEqual(try store.credential(named: "alice"), Data([0x61, 0x0a]))
    }

    func testNotFoundDeniedAndNonzeroErrorsAreSanitized() {
        let secret = "sentinel-secret"
        let cases: [SecurityCLIProcessResult] = [
            .init(terminationStatus: 44, stdout: Data(secret.utf8)),
            .init(terminationStatus: 1, stdout: Data("password: \(secret)".utf8)),
            .init(terminationStatus: 2, stdout: Data("error \(secret)".utf8))
        ]

        for result in cases {
            let store = SecurityCLIClaudeCredentialStore(
                runner: RecordingSecurityCLIProcessRunner(result: result)
            )
            XCTAssertThrowsError(try store.credential(named: secret)) { error in
                XCTAssertEqual(error as? SecurityCLIClaudeCredentialStoreError, .credentialUnavailable)
                XCTAssertFalse(String(describing: error).contains(secret))
                XCTAssertFalse(error.localizedDescription.contains(secret))
                XCTAssertFalse(error.localizedDescription.contains("stdout"))
                XCTAssertFalse(error.localizedDescription.contains("stderr"))
            }
        }
    }

    func testRunnerErrorIsSanitized() {
        let secret = "sentinel-secret"
        let runner = RecordingSecurityCLIProcessRunner(
            error: RunnerFailure(message: "denied: \(secret), stdout=\(secret), stderr=\(secret)")
        )
        let store = SecurityCLIClaudeCredentialStore(runner: runner)

        XCTAssertThrowsError(try store.credential(named: secret)) { error in
            XCTAssertEqual(error as? SecurityCLIClaudeCredentialStoreError, .credentialUnavailable)
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(error.localizedDescription.contains("stdout"))
            XCTAssertFalse(error.localizedDescription.contains("stderr"))
        }
    }

    func testMalformedSuccessOutputIsSanitized() {
        let runner = RecordingSecurityCLIProcessRunner(
            result: .init(terminationStatus: 0, stdout: Data())
        )
        let store = SecurityCLIClaudeCredentialStore(runner: runner)

        XCTAssertThrowsError(try store.credential(named: "sentinel-secret")) { error in
            XCTAssertEqual(error as? SecurityCLIClaudeCredentialStoreError, .credentialUnavailable)
            XCTAssertFalse(error.localizedDescription.contains("sentinel-secret"))
        }
    }

    func testStoreAndRemoveAreUnavailableWithoutWritingOrExposingCredential() {
        let runner = RecordingSecurityCLIProcessRunner(
            result: .init(terminationStatus: 0, stdout: Data("sentinel-secret".utf8))
        )
        let store = SecurityCLIClaudeCredentialStore(runner: runner)

        XCTAssertThrowsError(
            try store.storeCredential(Data("sentinel-secret".utf8), named: "alice")
        ) { error in
            XCTAssertEqual(error as? SecurityCLIClaudeCredentialStoreError, .credentialUnavailable)
            XCTAssertFalse(error.localizedDescription.contains("sentinel-secret"))
        }
        XCTAssertThrowsError(try store.removeCredential(named: "alice")) { error in
            XCTAssertEqual(error as? SecurityCLIClaudeCredentialStoreError, .credentialUnavailable)
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testEmptyAccountIsMalformedWithoutInvokingRunner() {
        let runner = RecordingSecurityCLIProcessRunner(
            result: .init(terminationStatus: 0, stdout: Data("sentinel-secret".utf8))
        )
        let store = SecurityCLIClaudeCredentialStore(runner: runner)

        XCTAssertThrowsError(try store.credential(named: "")) { error in
            XCTAssertEqual(error as? SecurityCLIClaudeCredentialStoreError, .credentialUnavailable)
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }
}
