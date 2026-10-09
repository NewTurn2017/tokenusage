import Foundation

public enum ClaudeCLIError: Error, Equatable, Sendable, LocalizedError {
    case executableNotFound
    case invalidExecutableOverride
    case processFailed
    case malformedOutput
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "claude 실행 파일을 찾지 못했습니다."
        case .invalidExecutableOverride:
            "지정한 claude 실행 파일 경로가 올바르지 않습니다."
        case .processFailed:
            "claude auth status 실행에 실패했습니다."
        case .malformedOutput:
            "claude auth status 응답을 해석할 수 없습니다."
        case .notAuthenticated:
            "Claude Code 에 로그인되어 있지 않습니다."
        }
    }
}

/// Reads the identity Claude Code itself reports, so an activation is confirmed by the CLI
/// rather than by the bytes this app just wrote.
public protocol ClaudeAuthStatusReading: Sendable {
    /// `configurationDirectory` nil reads the account Claude Code is signed in as; a directory
    /// reads a throwaway sign-in without disturbing it.
    func readAuthStatus(configurationDirectory: URL?) async throws -> ClaudeAccount
}

public protocol ClaudeExecutableResolving: Sendable {
    func resolve(environment: [String: String]) throws -> URL
}

public struct InstalledClaudeExecutableResolver: ClaudeExecutableResolving, Sendable {
    private let fallbackDirectories: [String]

    public init() {
        fallbackDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
    }

    init(fallbackDirectories: [String]) {
        self.fallbackDirectories = fallbackDirectories
    }

    public func resolve(environment: [String: String]) throws -> URL {
        let fileManager = FileManager.default
        if let override = environment["TOKENUSAGE_CLAUDE_PATH"] {
            guard !override.isEmpty else { throw ClaudeCLIError.invalidExecutableOverride }
            let url = URL(fileURLWithPath: override, isDirectory: false)
            guard Self.isExecutable(url, fileManager: fileManager) else {
                throw ClaudeCLIError.invalidExecutableOverride
            }
            return url
        }

        var directories = environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        if let home = environment["HOME"], !home.isEmpty {
            directories.append(contentsOf: ["\(home)/.local/bin", "\(home)/bin"])
        }
        directories.append(contentsOf: fallbackDirectories)

        var visited = Set<String>()
        for directory in directories where visited.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("claude", isDirectory: false)
            if Self.isExecutable(candidate, fileManager: fileManager) { return candidate }
        }
        throw ClaudeCLIError.executableNotFound
    }

    private static func isExecutable(_ url: URL, fileManager: FileManager) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }
}

public struct ClaudeCLIAuthStatusReader: ClaudeAuthStatusReading, Sendable {
    private let resolver: any ClaudeExecutableResolving
    private let environment: [String: String]
    private let timeout: Duration

    public init(
        resolver: any ClaudeExecutableResolving = InstalledClaudeExecutableResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = .seconds(30)
    ) {
        self.resolver = resolver
        self.environment = environment
        self.timeout = timeout
    }

    public func readAuthStatus(configurationDirectory: URL?) async throws -> ClaudeAccount {
        let executable = try resolver.resolve(environment: environment)
        let output = try await ClaudeCLIProcess.run(
            executable: executable,
            arguments: ["auth", "status", "--json"],
            environment: ClaudeCLIEnvironment.isolating(
                environment,
                configurationDirectory: configurationDirectory
            ),
            timeout: timeout
        )
        return try Self.account(from: output)
    }

    static func account(from output: Data) throws -> ClaudeAccount {
        guard let root = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw ClaudeCLIError.malformedOutput
        }
        guard (root["loggedIn"] as? Bool) == true else {
            throw ClaudeCLIError.notAuthenticated
        }
        return ClaudeAccount(
            email: root["email"] as? String,
            organizationID: root["orgId"] as? String,
            organizationName: root["orgName"] as? String,
            subscriptionType: root["subscriptionType"] as? String,
            accountUUID: root["accountUuid"] as? String
        )
    }
}

public enum ClaudeCLIEnvironment {
    /// Both variables are needed: the first moves the settings directory, the second moves the
    /// credential storage that the Keychain item name is derived from.
    ///
    /// Without a directory the CLI is pointed at the default account - the one whose Keychain
    /// item this app reads and swaps - even when the app inherited a `CLAUDE_CONFIG_DIR` from the
    /// terminal that launched it.
    public static func isolating(
        _ environment: [String: String],
        configurationDirectory: URL?
    ) -> [String: String] {
        var isolated = environment
        guard let configurationDirectory else {
            isolated["CLAUDE_CONFIG_DIR"] = nil
            isolated["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = nil
            return isolated
        }
        let path = configurationDirectory.path
        isolated["CLAUDE_CONFIG_DIR"] = path
        isolated["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = path
        return isolated
    }
}

private final class ClaudeCLIOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.withLock { data = value }
    }

    var value: Data {
        lock.withLock { data }
    }
}

enum ClaudeCLIProcess {
    /// Runs the CLI and returns stdout. The CLI prints a JSON object and exits; anything else -
    /// a hang, a crash, a non-JSON banner - is treated as a failed read.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try runSynchronously(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeoutSeconds: max(1, Int(timeout.components.seconds))
            )
        }.value
    }

    private static func runSynchronously(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeoutSeconds: Int
    ) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ClaudeCLIError.processFailed
        }

        // stdout is drained on its own thread so a chatty CLI cannot fill the pipe and deadlock
        // against the exit wait below.
        let output = ClaudeCLIOutputBox()
        let readFinished = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            output.store((try? handle.readToEnd()) ?? Data())
            readFinished.signal()
        }
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }

        if exited.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + .seconds(2))
            _ = readFinished.wait(timeout: .now() + .seconds(2))
            throw ClaudeCLIError.processFailed
        }
        _ = readFinished.wait(timeout: .now() + .seconds(5))
        guard process.terminationStatus == 0 else { throw ClaudeCLIError.processFailed }
        return output.value
    }
}
