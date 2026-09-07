import Foundation

public protocol CodexExecutableResolving: Sendable {
    func resolve(environment: [String: String]) throws -> URL
}

public struct CodexExecutableResolution: Sendable {
    public let executable: URL
    public let environment: [String: String]

    public init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }
}

public extension CodexExecutableResolving {
    func resolveProcess(environment: [String: String]) throws -> CodexExecutableResolution {
        let executable = try resolve(environment: environment)
        let executableDirectory = executable.standardizedFileURL
            .deletingLastPathComponent()
            .path
        let existingPath = environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != executableDirectory } ?? []

        var childEnvironment = environment
        childEnvironment["PATH"] = ([executableDirectory] + existingPath).joined(separator: ":")
        return CodexExecutableResolution(
            executable: executable,
            environment: childEnvironment
        )
    }
}

public struct InstalledCodexExecutableResolver: CodexExecutableResolving, Sendable {
    private let explicitExecutableURL: URL?
    private let fallbackDirectories: [URL]

    public init(explicitExecutableURL: URL? = nil) {
        self.explicitExecutableURL = explicitExecutableURL
        fallbackDirectories = [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
        ]
    }

    init(explicitExecutableURL: URL? = nil, fallbackDirectories: [URL]) {
        self.explicitExecutableURL = explicitExecutableURL
        self.fallbackDirectories = fallbackDirectories
    }

    public func resolve(environment: [String: String]) throws -> URL {
        let fileManager = FileManager.default
        if let explicitExecutableURL {
            guard Self.isExecutable(explicitExecutableURL, fileManager: fileManager) else {
                throw CodexAppServerClient.Error.invalidExecutableOverride
            }
            return explicitExecutableURL
        }
        if let overridePath = environment["TOKENUSAGE_CODEX_PATH"] {
            guard !overridePath.isEmpty else {
                throw CodexAppServerClient.Error.invalidExecutableOverride
            }
            let overrideURL = URL(fileURLWithPath: overridePath, isDirectory: false)
            guard Self.isExecutable(overrideURL, fileManager: fileManager) else {
                throw CodexAppServerClient.Error.invalidExecutableOverride
            }
            return overrideURL
        }
        var directories = environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []

        if let home = environment["HOME"], !home.isEmpty {
            directories.append(contentsOf: [
                "\(home)/.local/bin",
                "\(home)/bin",
            ])
        }

        let fnmRoots = Self.fnmRoots(environment: environment)
        directories.append(contentsOf: fnmRoots.map { root in
            root.appendingPathComponent("aliases/default/bin", isDirectory: true).path
        })
        for root in fnmRoots {
            directories.append(contentsOf: Self.fnmVersionBinDirectories(
                root: root,
                fileManager: fileManager
            ))
        }
        directories.append(contentsOf: fallbackDirectories.map(\.path))

        var visited = Set<String>()
        for directory in directories where visited.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("codex", isDirectory: false)
            guard Self.isExecutable(candidate, fileManager: fileManager) else {
                continue
            }
            return candidate
        }

        throw CodexAppServerClient.Error.executableNotFound
    }

    private static func isExecutable(_ url: URL, fileManager: FileManager) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath()
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolvedURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return false
        }
        return fileManager.isExecutableFile(atPath: resolvedURL.path)
    }

    private static func fnmRoots(environment: [String: String]) -> [URL] {
        var roots: [URL] = []
        if let fnmDirectory = environment["FNM_DIR"], !fnmDirectory.isEmpty {
            roots.append(URL(fileURLWithPath: fnmDirectory, isDirectory: true))
        }
        if let home = environment["HOME"], !home.isEmpty {
            let homeURL = URL(fileURLWithPath: home, isDirectory: true)
            roots.append(contentsOf: [
                homeURL.appendingPathComponent(".local/share/fnm", isDirectory: true),
                homeURL.appendingPathComponent(".fnm", isDirectory: true),
                homeURL.appendingPathComponent("Library/Application Support/fnm", isDirectory: true),
            ])
        }
        var visited = Set<String>()
        return roots.filter { visited.insert($0.standardizedFileURL.path).inserted }
    }

    private static func fnmVersionBinDirectories(root: URL, fileManager: FileManager) -> [String] {
        let versionsRoot = root.appendingPathComponent("node-versions", isDirectory: true)
        guard let versions = try? fileManager.contentsOfDirectory(
            at: versionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return versions.compactMap { url -> (url: URL, version: SemanticNodeVersion)? in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let version = SemanticNodeVersion(url.lastPathComponent) else {
                return nil
            }
            return (url, version)
        }
        .sorted { lhs, rhs in
            if lhs.version != rhs.version { return lhs.version > rhs.version }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
        .map { item in
            item.url.appendingPathComponent("installation/bin", isDirectory: true).path
        }
    }

    private struct SemanticNodeVersion: Equatable, Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        init?(_ directoryName: String) {
            let normalized = directoryName.first == "v"
                ? String(directoryName.dropFirst())
                : directoryName
            let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 3,
                  let major = Int(components[0]),
                  let minor = Int(components[1]),
                  let patch = Int(components[2]),
                  major >= 0, minor >= 0, patch >= 0 else {
                return nil
            }
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }
}

public struct CodexAccount: Equatable, Sendable {
    public let type: String
    public let email: String?
    public let planType: String?

    public init(type: String, email: String? = nil, planType: String? = nil) {
        self.type = type
        self.email = email
        self.planType = planType
    }
}

public struct CodexAppServerClient: UsageProviding, CodexAccountValidating, Sendable {
    public enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case executableNotFound
        case invalidExecutableOverride
        case invalidCodexHome
        case invalidAuthData
        case temporaryAuthUnavailable
        case malformedResponse
        case methodFailed(code: Int?)
        case notAuthenticated
        case processFailed

        public var errorDescription: String? {
            switch self {
            case .executableNotFound:
                return "The installed Codex executable could not be found."
            case .invalidExecutableOverride:
                return "The configured Codex executable is invalid."
            case .invalidCodexHome:
                return "The requested Codex home is unavailable."
            case .invalidAuthData:
                return "The Codex authentication data is invalid."
            case .temporaryAuthUnavailable:
                return "A private temporary Codex home could not be prepared."
            case .malformedResponse:
                return "The Codex app server returned an invalid response."
            case let .methodFailed(code):
                if let code {
                    return "The Codex app server rejected the request (code \(code))."
                }
                return "The Codex app server rejected the request."
            case .notAuthenticated:
                return "Codex is not authenticated."
            case .processFailed:
                return "The Codex app server request failed."
            }
        }
    }

    private let runner: any JSONRPCProcessRunning
    private let executableResolver: any CodexExecutableResolving
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    public init(
        runner: any JSONRPCProcessRunning = JSONRPCProcessRunner(),
        executableResolver: any CodexExecutableResolving = InstalledCodexExecutableResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runner = runner
        self.executableResolver = executableResolver
        self.environment = environment
        self.now = now
    }

    public func usage() async throws -> UsageSnapshot {
        let response = try await perform(
            request: Self.rateLimitsRequest,
            environment: environment
        )
        do {
            return try CodexUsageDecoder().decode(response, capturedAt: now())
        } catch {
            throw Error.malformedResponse
        }
    }

    public func usage(codexHome: URL) async throws -> UsageSnapshot {
        let isolatedEnvironment = try environment(forCodexHome: codexHome)
        let response = try await perform(
            request: Self.rateLimitsRequest,
            environment: isolatedEnvironment
        )
        do {
            return try CodexUsageDecoder().decode(response, capturedAt: now())
        } catch {
            throw Error.malformedResponse
        }
    }

    public func validate(codexHome: URL) async throws -> CodexAccount {
        let isolatedEnvironment = try environment(forCodexHome: codexHome)
        let accountResponse = try await perform(
            request: Self.accountRequest,
            environment: isolatedEnvironment
        )
        let account = try Self.decodeAccount(accountResponse)
        let rateLimitsResponse = try await perform(
            request: Self.rateLimitsRequest,
            environment: isolatedEnvironment
        )
        do {
            _ = try CodexUsageDecoder().decode(rateLimitsResponse, capturedAt: now())
        } catch {
            throw Error.malformedResponse
        }
        return account
    }

    private func environment(forCodexHome codexHome: URL) throws -> [String: String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: codexHome.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Error.invalidCodexHome
        }
        var isolatedEnvironment = environment
        isolatedEnvironment["CODEX_HOME"] = codexHome.path
        return isolatedEnvironment
    }

    public func validate(authData: Data) async throws -> CodexAccount {
        guard !authData.isEmpty,
              (try? JSONSerialization.jsonObject(with: authData)) is [String: Any] else {
            throw Error.invalidAuthData
        }

        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("TokenUsage-Codex-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: temporaryHome,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let authURL = temporaryHome.appendingPathComponent("auth.json", isDirectory: false)
            guard fileManager.createFile(
                atPath: authURL.path,
                contents: authData,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw Error.temporaryAuthUnavailable
            }
        } catch let error as Error {
            throw error
        } catch {
            try? fileManager.removeItem(at: temporaryHome)
            throw Error.temporaryAuthUnavailable
        }
        defer {
            try? fileManager.removeItem(at: temporaryHome)
        }

        do {
            return try await validate(codexHome: temporaryHome)
        } catch let error as Error {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.temporaryAuthUnavailable
        }
    }

    private func perform(request: Data, environment: [String: String]) async throws -> Data {
        let resolution: CodexExecutableResolution
        do {
            resolution = try executableResolver.resolveProcess(environment: environment)
        } catch let error as Error {
            throw error
        } catch {
            throw Error.executableNotFound
        }

        let response: Data
        do {
            response = try await runner.run(
                executable: resolution.executable,
                arguments: ["app-server", "--stdio"],
                environment: resolution.environment,
                request: request
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.processFailed
        }

        let root = try Self.responseObject(response)
        if let rawError = root["error"] {
            guard let methodError = rawError as? [String: Any] else {
                throw Error.malformedResponse
            }
            throw Error.methodFailed(code: Self.integer(methodError["code"]))
        }
        guard root["result"] is [String: Any] else {
            throw Error.malformedResponse
        }
        return response
    }

    private static func decodeAccount(_ data: Data) throws -> CodexAccount {
        let root = try responseObject(data)
        guard let result = root["result"] as? [String: Any],
              let requiresOpenAIAuth = result["requiresOpenaiAuth"] as? Bool else {
            throw Error.malformedResponse
        }
        guard let account = result["account"] as? [String: Any],
              let type = account["type"] as? String else {
            if requiresOpenAIAuth {
                throw Error.notAuthenticated
            }
            throw Error.malformedResponse
        }

        let email = try optionalString(account["email"])
        let planType = try optionalString(account["planType"])
        return CodexAccount(type: type, email: email, planType: planType)
    }

    private static func responseObject(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let root = value as? [String: Any] else {
            throw Error.malformedResponse
        }
        if let version = root["jsonrpc"], version as? String != "2.0" {
            throw Error.malformedResponse
        }
        return root
    }

    private static func optionalString(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw Error.malformedResponse }
        return string
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.intValue
    }

    private static let rateLimitsRequest = Data(
        #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}"#.utf8
    )
    private static let accountRequest = Data(
        #"{"jsonrpc":"2.0","id":2,"method":"account/read","params":{"refreshToken":false}}"#.utf8
    )
}
