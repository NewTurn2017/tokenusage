import Darwin
import Foundation

public protocol LaunchdJobRunning: Sendable {
    func submit(
        label: String,
        standardOutputPath: String,
        executable: URL,
        arguments: [String]
    ) throws -> Int32
    func remove(label: String) throws
}

public struct SystemLaunchdJobRunner: LaunchdJobRunning, Sendable {
    private static let launchctl = URL(fileURLWithPath: "/bin/launchctl")
    private static let commandTimeout: DispatchTimeInterval = .seconds(2)

    public init() {}

    public func submit(
        label: String,
        standardOutputPath: String,
        executable: URL,
        arguments: [String]
    ) throws -> Int32 {
        try runLaunchctl(
            arguments: [
                "submit", "-l", label,
                "-o", standardOutputPath,
                "-e", "/dev/null",
                "--", executable.path
            ] + arguments
        )
    }

    public func remove(label: String) throws {
        guard try runLaunchctl(arguments: ["remove", label]) == 0 else {
            throw SystemLaunchdJobRunnerError.removalFailed
        }
        let target = "gui/\(getuid())/\(label)"
        guard try runLaunchctl(arguments: ["print", target]) != 0 else {
            throw SystemLaunchdJobRunnerError.removalUnconfirmed
        }
    }

    private func runLaunchctl(arguments: [String]) throws -> Int32 {
        let process = Process()
        let terminated = DispatchSemaphore(value: 0)
        process.executableURL = Self.launchctl
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()

        guard terminated.wait(timeout: .now() + Self.commandTimeout) == .success else {
            let pid = process.processIdentifier
            process.terminate()
            if terminated.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                _ = Darwin.kill(pid, SIGKILL)
                guard terminated.wait(timeout: .now() + Self.commandTimeout) == .success else {
                    throw SystemLaunchdJobRunnerError.commandTimedOut
                }
            }
            throw SystemLaunchdJobRunnerError.commandTimedOut
        }
        return process.terminationStatus
    }
}

private enum SystemLaunchdJobRunnerError: Error {
    case commandTimedOut
    case removalFailed
    case removalUnconfirmed
}
