import Darwin
import Foundation

public enum SecurityCLIPasswordWriterError: Error, Equatable, Sendable, LocalizedError {
    case transportUnavailable
    case writeFailed
    case jobRemovalFailed

    public var errorDescription: String? {
        switch self {
        case .transportUnavailable:
            "키체인 쓰기 채널을 열지 못했습니다."
        case .writeFailed:
            "키체인에 자격 증명을 기록하지 못했습니다."
        case .jobRemovalFailed:
            "키체인 쓰기 작업을 정리하지 못했습니다."
        }
    }
}

public protocol SecurityCLIPasswordWriting: Sendable {
    func writeGenericPassword(service: String, account: String, password: Data) throws
    func deleteGenericPassword(service: String, account: String) throws
}

/// Writes a generic password through `/usr/bin/security`, submitted as a launchd job.
///
/// Direct `SecItemUpdate` on Claude Code's Keychain item fails with `errSecAuthFailed` for this
/// app, which is why reads already take this route; writes must take it too.
///
/// The value travels in `argv`. `security` reads a prompted password through a 128-byte buffer
/// and silently truncates anything longer, so stdin cannot carry a multi-kilobyte credential.
/// The exposure this adds is narrow: the same item is already readable by any process running as
/// this user through the very same CLI.
public struct SystemSecurityCLIPasswordWriter: SecurityCLIPasswordWriting, Sendable {
    private static let shell = URL(fileURLWithPath: "/bin/sh")
    private static let securityPath = "/usr/bin/security"
    /// A submitted job reports nothing back, so `security`'s exit status lands in a file the
    /// caller polls. The job must be seen to finish before its label is removed, or the removal
    /// tears `security` down mid-write.
    private static let writeScript = """
    "$1" add-generic-password -U -s "$2" -a "$3" -w "$4"; printf '%s' "$?" > "$5"
    """
    private static let deleteScript = """
    "$1" delete-generic-password -s "$2" -a "$3" > /dev/null 2>&1; printf '%s' "$?" > "$4"
    """

    private let jobRunner: any LaunchdJobRunning
    private let temporaryDirectory: URL
    private let timeout: Duration
    private let labelGenerator: @Sendable () -> String

    public init() {
        self.init(
            jobRunner: SystemLaunchdJobRunner(),
            temporaryDirectory: FileManager.default.temporaryDirectory,
            timeout: .seconds(10),
            labelGenerator: {
                "com.tokenusage.claude-credential-write.\(UUID().uuidString.lowercased())"
            }
        )
    }

    init(
        jobRunner: any LaunchdJobRunning,
        temporaryDirectory: URL,
        timeout: Duration,
        labelGenerator: @escaping @Sendable () -> String
    ) {
        self.jobRunner = jobRunner
        self.temporaryDirectory = temporaryDirectory
        self.timeout = timeout
        self.labelGenerator = labelGenerator
    }

    public func writeGenericPassword(service: String, account: String, password: Data) throws {
        guard !password.isEmpty, let value = String(data: password, encoding: .utf8) else {
            throw SecurityCLIPasswordWriterError.writeFailed
        }
        try run { statusPath in
            ["-c", Self.writeScript, "sh", Self.securityPath, service, account, value, statusPath]
        }
    }

    /// Removing an item the user never sees keeps a throwaway sign-in from leaving a credential
    /// behind. An item that was never created is not a failure.
    public func deleteGenericPassword(service: String, account: String) throws {
        try run { statusPath in
            ["-c", Self.deleteScript, "sh", Self.securityPath, service, account, statusPath]
        }
    }

    private func run(arguments: (String) -> [String]) throws {
        let directory = temporaryDirectory.appendingPathComponent(
            "tokenusage-credential-write-\(UUID().uuidString)",
            isDirectory: true
        )
        let statusFile = directory.appendingPathComponent("status")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SecurityCLIPasswordWriterError.transportUnavailable
        }
        defer {
            unlink(statusFile.path)
            rmdir(directory.path)
        }

        let label = labelGenerator()
        let submitted: Int32
        do {
            submitted = try jobRunner.submit(
                label: label,
                standardOutputPath: "/dev/null",
                executable: Self.shell,
                arguments: arguments(statusFile.path)
            )
        } catch {
            throw SecurityCLIPasswordWriterError.transportUnavailable
        }

        var writeError: (any Error)?
        if submitted == 0 {
            do {
                guard try awaitCompletion(statusFile: statusFile) == 0 else {
                    throw SecurityCLIPasswordWriterError.writeFailed
                }
            } catch {
                writeError = error
            }
        } else {
            writeError = SecurityCLIPasswordWriterError.writeFailed
        }

        do {
            try jobRunner.remove(label: label)
        } catch {
            throw writeError ?? SecurityCLIPasswordWriterError.jobRemovalFailed
        }
        if let writeError { throw writeError }
    }

    private func awaitCompletion(statusFile: URL) throws -> Int32 {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(1, timeout.components.seconds)) * 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let contents = try? String(contentsOf: statusFile, encoding: .utf8),
               let status = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return status
            }
            usleep(20_000)
        }
        throw SecurityCLIPasswordWriterError.writeFailed
    }
}
