import Foundation
import XCTest
@testable import TokenUsageCore

extension SecurityCLIClaudeCredentialStoreTests {
    func testSystemRunnerRoutesSecurityThroughMode0600FIFOAndCleansUp() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let jobRunner = RecordingLaunchdJobRunner(payload: Data("credential-bytes\n".utf8))
        let runner = makeSystemRunner(
            jobRunner: jobRunner,
            root: root,
            timeout: .seconds(1),
            payloadLimit: 64,
            label: "com.tokenusage.credential.fixed"
        )
        let arguments = [
            "find-generic-password", "-s", "Claude Code-credentials", "-a", "alice", "-w"
        ]

        let result = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: arguments
        )

        XCTAssertEqual(result, .init(terminationStatus: 0, stdout: Data("credential-bytes\n".utf8)))
        let invocation = try XCTUnwrap(jobRunner.invocations.first)
        XCTAssertEqual(invocation.label, "com.tokenusage.credential.fixed")
        XCTAssertEqual(invocation.executable.path, "/usr/bin/security")
        XCTAssertEqual(invocation.arguments, arguments)
        XCTAssertEqual(invocation.fifoMode, 0o600)
        XCTAssertTrue(invocation.isFIFO)
        XCTAssertEqual(jobRunner.removedLabels, ["com.tokenusage.credential.fixed"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.url.path), [])
    }

    func testCancellingInFlightCredentialReadRemovesJobAndBoundedlyReapsWorker() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let submitted = expectation(description: "launchd job submitted")
        let removed = expectation(description: "launchd job removed")
        let finished = expectation(description: "credential worker reaped")
        let jobRunner = RecordingLaunchdJobRunner(
            payload: nil,
            submitted: submitted,
            removed: removed
        )
        let store = SecurityCLIClaudeCredentialStore(runner: makeSystemRunner(
            jobRunner: jobRunner,
            root: root,
            timeout: .seconds(30),
            payloadLimit: 64,
            label: "com.tokenusage.credential.cancelled"
        ))
        let read = credentialRead(store, finished: finished)
        await fulfillment(of: [submitted], timeout: 1)

        read.cancel()

        await fulfillment(of: [removed, finished], timeout: 1)
        let result = await read.value
        guard case .failure(let error) = result else {
            return XCTFail("Expected cancelled credential read to fail")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(jobRunner.removedLabels, ["com.tokenusage.credential.cancelled"])
        XCTAssertFalse(jobRunner.hasActiveJob)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.url.path), [])
    }

    func testCancellationSurfacesLaunchdRemovalFailure() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let submitted = expectation(description: "launchd job submitted")
        let removed = expectation(description: "launchd removal attempted")
        let finished = expectation(description: "credential worker finished")
        let jobRunner = RecordingLaunchdJobRunner(
            payload: nil,
            removalError: RunnerFailure(message: "private launchctl detail"),
            submitted: submitted,
            removed: removed
        )
        let store = SecurityCLIClaudeCredentialStore(runner: makeSystemRunner(
            jobRunner: jobRunner,
            root: root,
            timeout: .seconds(30),
            payloadLimit: 64,
            label: "com.tokenusage.credential.remove-failure"
        ))
        let read = credentialRead(store, finished: finished)
        await fulfillment(of: [submitted], timeout: 1)

        read.cancel()

        await fulfillment(of: [removed, finished], timeout: 1)
        let result = await read.value
        guard case .failure(let error) = result else {
            return XCTFail("Expected failed launchd removal to fail the credential read")
        }
        XCTAssertEqual(error as? SecurityCLIClaudeCredentialStoreError, .credentialUnavailable)
        XCTAssertFalse(error is CancellationError)
        XCTAssertFalse(error.localizedDescription.contains("private launchctl detail"))
        XCTAssertEqual(jobRunner.removedLabels, ["com.tokenusage.credential.remove-failure"])
        XCTAssertTrue(jobRunner.hasActiveJob)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.url.path), [])
    }

    func testSystemRunnerTimeoutAndSubmitFailureCleanUpWithoutLeakingPayload() throws {
        for jobRunner in [
            RecordingLaunchdJobRunner(payload: nil),
            RecordingLaunchdJobRunner(payload: nil, submitStatus: 64)
        ] {
            let root = try TemporaryDirectory()
            defer { root.remove() }
            let store = SecurityCLIClaudeCredentialStore(runner: makeSystemRunner(
                jobRunner: jobRunner,
                root: root,
                timeout: .milliseconds(10),
                payloadLimit: 64,
                label: "com.tokenusage.credential.failure"
            ))

            XCTAssertThrowsError(try store.credential(named: "alice")) { error in
                XCTAssertEqual(error as? SecurityCLIClaudeCredentialStoreError, .credentialUnavailable)
                XCTAssertFalse(error.localizedDescription.contains("credential-bytes"))
            }
            XCTAssertEqual(jobRunner.removedLabels, ["com.tokenusage.credential.failure"])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.url.path), [])
        }
    }

    func testSystemRunnerRejectsOversizedPayloadAndLeavesNoRegularCredentialFile() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let secret = "sentinel-secret"
        let jobRunner = RecordingLaunchdJobRunner(payload: Data("\(secret)\n".utf8))
        let store = SecurityCLIClaudeCredentialStore(runner: makeSystemRunner(
            jobRunner: jobRunner,
            root: root,
            timeout: .seconds(1),
            payloadLimit: 4,
            label: "com.tokenusage.credential.oversized"
        ))

        XCTAssertThrowsError(try store.credential(named: "alice")) { error in
            XCTAssertEqual(error as? SecurityCLIClaudeCredentialStoreError, .credentialUnavailable)
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
        XCTAssertTrue(try XCTUnwrap(jobRunner.invocations.first).isFIFO)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.url.path), [])
    }

    private func makeSystemRunner(
        jobRunner: RecordingLaunchdJobRunner,
        root: TemporaryDirectory,
        timeout: Duration,
        payloadLimit: Int,
        label: String
    ) -> SystemSecurityCLIProcessRunner {
        SystemSecurityCLIProcessRunner(
            jobRunner: jobRunner,
            temporaryDirectory: root.url,
            readTimeout: timeout,
            maxPayloadBytes: payloadLimit,
            labelGenerator: { label }
        )
    }

    private func credentialRead(
        _ store: SecurityCLIClaudeCredentialStore,
        finished: XCTestExpectation
    ) -> Task<Result<Data?, any Error>, Never> {
        Task {
            defer { finished.fulfill() }
            do { return .success(try await store.credential(named: "alice")) }
            catch { return .failure(error) }
        }
    }
}
