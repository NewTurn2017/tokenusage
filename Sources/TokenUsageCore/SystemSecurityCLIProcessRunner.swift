import Foundation

public struct SecurityCLIProcessResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let stdout: Data

    public init(terminationStatus: Int32, stdout: Data) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
    }
}

public protocol SecurityCLIProcessRunning: Sendable {
    func run(executable: URL, arguments: [String]) throws -> SecurityCLIProcessResult
    func runCancellable(
        executable: URL,
        arguments: [String]
    ) async throws -> SecurityCLIProcessResult
}

public extension SecurityCLIProcessRunning {
    func runCancellable(
        executable: URL,
        arguments: [String]
    ) async throws -> SecurityCLIProcessResult {
        try Task.checkCancellation()
        return try run(executable: executable, arguments: arguments)
    }
}

enum SystemSecurityCLIProcessRunnerError: Error, Equatable {
    case transportUnavailable
    case jobRemovalFailed
}

public final class SystemSecurityCLIProcessRunner: SecurityCLIProcessRunning, @unchecked Sendable {
    private let jobRunner: any LaunchdJobRunning
    private let temporaryDirectory: URL
    private let readTimeoutMilliseconds: Int32
    private let maxPayloadBytes: Int
    private let labelGenerator: @Sendable () -> String

    public init() {
        jobRunner = SystemLaunchdJobRunner()
        temporaryDirectory = FileManager.default.temporaryDirectory
        readTimeoutMilliseconds = 5_000
        maxPayloadBytes = 64 * 1_024
        labelGenerator = {
            "com.tokenusage.claude-credential.\(UUID().uuidString.lowercased())"
        }
    }

    init(
        jobRunner: any LaunchdJobRunning,
        temporaryDirectory: URL,
        readTimeout: Duration,
        maxPayloadBytes: Int,
        labelGenerator: @escaping @Sendable () -> String
    ) {
        self.jobRunner = jobRunner
        self.temporaryDirectory = temporaryDirectory
        readTimeoutMilliseconds = readTimeout.pollMilliseconds
        self.maxPayloadBytes = maxPayloadBytes
        self.labelGenerator = labelGenerator
    }

    public func run(executable: URL, arguments: [String]) throws -> SecurityCLIProcessResult {
        let operation = try SecurityCLIFIFOReadOperation(jobRunner: jobRunner)
        return try operation.execute(
            executable: executable,
            arguments: arguments,
            label: labelGenerator(),
            temporaryDirectory: temporaryDirectory,
            readTimeoutMilliseconds: readTimeoutMilliseconds,
            maxPayloadBytes: maxPayloadBytes
        )
    }

    public func runCancellable(
        executable: URL,
        arguments: [String]
    ) async throws -> SecurityCLIProcessResult {
        let operation = try SecurityCLIFIFOReadOperation(jobRunner: jobRunner)
        let label = labelGenerator()
        let directory = temporaryDirectory
        let timeout = readTimeoutMilliseconds
        let payloadLimit = maxPayloadBytes
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try operation.execute(
                    executable: executable,
                    arguments: arguments,
                    label: label,
                    temporaryDirectory: directory,
                    readTimeoutMilliseconds: timeout,
                    maxPayloadBytes: payloadLimit
                )
            }.value
        } onCancel: {
            operation.cancel()
        }
    }
}

private extension Duration {
    var pollMilliseconds: Int32 {
        let components = self.components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        let fromSeconds = seconds.multipliedReportingOverflow(by: 1_000)
        guard !fromSeconds.overflow else { return Int32.max }
        let milliseconds = fromSeconds.partialValue + attoseconds / 1_000_000_000_000_000
        return Int32(clamping: max(1, milliseconds))
    }
}
