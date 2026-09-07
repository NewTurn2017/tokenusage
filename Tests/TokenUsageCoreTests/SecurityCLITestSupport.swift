import Darwin
import Foundation
import XCTest
@testable import TokenUsageCore

struct RunnerFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenusage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

final class RecordingLaunchdJobRunner: LaunchdJobRunning, @unchecked Sendable {
    struct Invocation: Sendable {
        let label: String
        let executable: URL
        let arguments: [String]
        let fifoMode: mode_t
        let isFIFO: Bool
    }

    private let lock = NSLock()
    private let payload: Data?
    private let submitStatus: Int32
    private let removalError: Error?
    private let submitted: XCTestExpectation?
    private let removed: XCTestExpectation?
    private var recordedInvocations: [Invocation] = []
    private var recordedRemovedLabels: [String] = []
    private var activeJob = false

    init(
        payload: Data?,
        submitStatus: Int32 = 0,
        removalError: Error? = nil,
        submitted: XCTestExpectation? = nil,
        removed: XCTestExpectation? = nil
    ) {
        self.payload = payload
        self.submitStatus = submitStatus
        self.removalError = removalError
        self.submitted = submitted
        self.removed = removed
    }

    var invocations: [Invocation] {
        lock.withLock { recordedInvocations }
    }

    var removedLabels: [String] {
        lock.withLock { recordedRemovedLabels }
    }

    var hasActiveJob: Bool {
        lock.withLock { activeJob }
    }

    func submit(
        label: String,
        standardOutputPath: String,
        executable: URL,
        arguments: [String]
    ) throws -> Int32 {
        var metadata = stat()
        XCTAssertEqual(lstat(standardOutputPath, &metadata), 0)
        lock.withLock {
            recordedInvocations.append(.init(
                label: label,
                executable: executable,
                arguments: arguments,
                fifoMode: metadata.st_mode & 0o777,
                isFIFO: metadata.st_mode & S_IFMT == S_IFIFO
            ))
            activeJob = submitStatus == 0
        }
        submitted?.fulfill()
        guard submitStatus == 0, let payload else { return submitStatus }
        let descriptor = open(standardOutputPath, O_WRONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        _ = payload.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        return 0
    }

    func remove(label: String) throws {
        lock.withLock { recordedRemovedLabels.append(label) }
        removed?.fulfill()
        if let removalError { throw removalError }
        lock.withLock { activeJob = false }
    }
}

final class RecordingSecurityCLIProcessRunner: SecurityCLIProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        let executable: URL
        let arguments: [String]
    }

    private let lock = NSLock()
    private let configuredResult: SecurityCLIProcessResult?
    private let configuredError: Error?
    private var recordedInvocations: [Invocation] = []

    init(result: SecurityCLIProcessResult) {
        configuredResult = result
        configuredError = nil
    }

    init(error: Error) {
        configuredResult = nil
        configuredError = error
    }

    var invocations: [Invocation] {
        lock.withLock { recordedInvocations }
    }

    func run(executable: URL, arguments: [String]) throws -> SecurityCLIProcessResult {
        lock.withLock {
            recordedInvocations.append(.init(executable: executable, arguments: arguments))
        }
        if let configuredError { throw configuredError }
        return configuredResult!
    }
}
