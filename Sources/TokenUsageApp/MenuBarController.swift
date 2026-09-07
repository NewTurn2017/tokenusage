import AppKit
import Combine
import Darwin
import Foundation
import TokenUsageCore

struct SystemRefreshClock: RefreshClock {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

struct ProductionCodexDependencies {
    let environment: [String: String]
    let applicationSupportDirectory: URL
    let profileHomesRoot: URL
    let defaultCodexHome: URL

    private let resolver: any CodexExecutableResolving
    private let browserOpener: SystemCodexLoginRunner.BrowserOpener

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = nil,
        resolver: any CodexExecutableResolving = InstalledCodexExecutableResolver(),
        browserOpener: @escaping SystemCodexLoginRunner.BrowserOpener = {
            NSWorkspace.shared.open($0)
        }
    ) {
        let environmentHome = environment["HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
        let resolvedApplicationSupport = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? (environmentHome ?? FileManager.default.homeDirectoryForCurrentUser)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let resolvedDefaultCodexHome = environment["CODEX_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? (environmentHome ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent(".codex", isDirectory: true)

        self.environment = environment
        self.applicationSupportDirectory = resolvedApplicationSupport.standardizedFileURL
        profileHomesRoot = resolvedApplicationSupport
            .appendingPathComponent("TokenUsage/CodexProfiles", isDirectory: true)
            .standardizedFileURL
        defaultCodexHome = resolvedDefaultCodexHome.standardizedFileURL
        self.resolver = resolver
        self.browserOpener = browserOpener
    }

    func makeCodexClient(
        runner: any JSONRPCProcessRunning = JSONRPCProcessRunner()
    ) -> CodexAppServerClient {
        CodexAppServerClient(
            runner: runner,
            executableResolver: resolver,
            environment: environment
        )
    }

    func makeLoginRunner(
        attemptController: CodexLoginAttemptController
    ) -> SystemCodexLoginRunner {
        SystemCodexLoginRunner(
            resolver: resolver,
            environment: environment,
            browserOpener: browserOpener,
            attemptController: attemptController
        )
    }

    func resolveCodexExecutable() throws -> URL {
        try resolver.resolve(environment: environment)
    }
}

final class SystemCodexLoginRunner: CodexLoginRunning, @unchecked Sendable {
    typealias BrowserOpener = @Sendable (URL) -> Bool

    private let resolver: any CodexExecutableResolving
    private let environment: [String: String]
    private let browserOpener: BrowserOpener
    let attemptController: CodexLoginAttemptController

    init(
        resolver: any CodexExecutableResolving = InstalledCodexExecutableResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        browserOpener: @escaping BrowserOpener = { NSWorkspace.shared.open($0) },
        attemptController: CodexLoginAttemptController = CodexLoginAttemptController()
    ) {
        self.resolver = resolver
        self.environment = environment
        self.browserOpener = browserOpener
        self.attemptController = attemptController
    }

    func runCodexLogin(codexHome: URL) async throws -> CodexLoginOutcome {
        let resolution = try resolver.resolveProcess(environment: environment)
        var loginEnvironment = resolution.environment
        loginEnvironment["CODEX_HOME"] = codexHome.path
        let process = OwnedProcess(
            executable: resolution.executable,
            arguments: ["login"],
            environment: loginEnvironment
        )
        let outputObserver = LoginOutputObserver(
            attemptController: attemptController,
            browserOpener: browserOpener
        )
        process.setOutputHandler { [weak process] data in
            if outputObserver.consume(data), outputObserver.browserOpenFailed {
                process?.terminate()
            }
        }
        attemptController.begin {
            outputObserver.cancel()
            process.terminate()
        }
        defer { attemptController.clear() }
        do {
            try process.start()
        } catch {
            attemptController.clear()
            throw error
        }
        return await withTaskCancellationHandler {
            let status = await process.waitUntilExit()
            let diagnostic = process.diagnostic
            if Task.isCancelled || outputObserver.wasCancelled {
                return .cancelled(terminationStatus: status, diagnostic: diagnostic)
            }
            if outputObserver.browserOpenFailed {
                return .browserOpenFailed(terminationStatus: status, diagnostic: diagnostic)
            }
            if status == 0 {
                return .completed(terminationStatus: status, diagnostic: diagnostic)
            }
            return .failed(terminationStatus: status, diagnostic: diagnostic)
        } onCancel: {
            process.terminate()
        }
    }
}

final class OwnedProcess: @unchecked Sendable {
    private let process = Process()
    private let stdout = CapturedProcessStream()
    private let stderr = CapturedProcessStream()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var started = false
    private var terminationRequested = false
    private var outputHandler: (@Sendable (Data) -> Void)?

    init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        stdout.startReading(from: stdoutPipe.fileHandleForReading) { [weak self] data in
            self?.handleOutput(data)
        }
        stderr.startReading(from: stderrPipe.fileHandleForReading) { [weak self] data in
            self?.handleOutput(data)
        }
        try process.run()
        let shouldTerminate = lock.withLock {
            started = true
            return terminationRequested
        }
        if shouldTerminate { terminateRunningProcess() }
    }

    func waitUntilExit() async -> Int32 {
        await Task.detached(priority: .userInitiated) { [process, stdout, stderr] in
            process.waitUntilExit()
            stdout.waitUntilFinished()
            stderr.waitUntilFinished()
            return process.terminationStatus
        }.value
    }

    func terminate() {
        let shouldTerminate = lock.withLock {
            terminationRequested = true
            return started && process.isRunning
        }
        guard shouldTerminate else { return }
        terminateRunningProcess()
    }

    func setOutputHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        lock.withLock { outputHandler = handler }
    }

    var diagnostic: CodexLoginDiagnostic {
        CodexLoginDiagnostic(stdout: stdout.sanitized, stderr: stderr.sanitized)
    }

    private func handleOutput(_ data: Data) {
        lock.withLock { outputHandler }?(data)
    }

    private func terminateRunningProcess() {
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(250)) {
            if self.process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }
}

final class CapturedProcessStream: @unchecked Sendable {
    private let lock = NSCondition()
    private var bytes = Data()
    private var truncated = false
    private var finished = false

    func startReading(
        from handle: FileHandle,
        onData: @escaping @Sendable (Data) -> Void
    ) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.markFinished()
                return
            }
            onData(data)
            self?.append(data)
        }
    }

    func waitUntilFinished() {
        lock.lock()
        while !finished { lock.wait() }
        lock.unlock()
    }

    var sanitized: String {
        let snapshot = lock.withLock { (bytes, truncated) }
        return LoginDiagnosticSanitizer.sanitize(snapshot.0, truncated: snapshot.1)
    }

    private func append(_ data: Data) {
        lock.withLock {
            let remaining = max(0, LoginDiagnosticSanitizer.maximumByteCount - bytes.count)
            bytes.append(data.prefix(remaining))
            if data.count > remaining { truncated = true }
        }
    }

    private func markFinished() {
        lock.lock()
        finished = true
        lock.broadcast()
        lock.unlock()
    }
}

private final class LoginOutputObserver: @unchecked Sendable {
    private static let urlExpression = try! NSRegularExpression(
        pattern: #"https://[^\s<>\"']+"#,
        options: [.caseInsensitive]
    )
    private let lock = NSLock()
    private let attemptController: CodexLoginAttemptController
    private let browserOpener: SystemCodexLoginRunner.BrowserOpener
    private var scanTail = ""
    private var openedURL: URL?
    private var didBrowserOpenFail = false
    private var didCancel = false

    init(
        attemptController: CodexLoginAttemptController,
        browserOpener: @escaping SystemCodexLoginRunner.BrowserOpener
    ) {
        self.attemptController = attemptController
        self.browserOpener = browserOpener
    }

    var browserOpenFailed: Bool { lock.withLock { didBrowserOpenFail } }
    var wasCancelled: Bool { lock.withLock { didCancel } }

    func cancel() {
        lock.withLock { didCancel = true }
    }

    @discardableResult
    func consume(_ data: Data) -> Bool {
        let chunk = String(decoding: data, as: UTF8.self)
        return lock.withLock {
            guard openedURL == nil else { return false }
            let candidateText = scanTail + chunk
            scanTail = String(candidateText.suffix(2_048))
            let range = NSRange(candidateText.startIndex..., in: candidateText)
            for match in Self.urlExpression.matches(in: candidateText, range: range) {
                guard let matchRange = Range(match.range, in: candidateText) else { continue }
                let raw = String(candidateText[matchRange]).trimmingCharacters(
                    in: CharacterSet(charactersIn: ").,;]}"))
                guard let url = URL(string: raw), Self.isAllowed(url) else { continue }
                openedURL = url
                if !attemptController.open(url, using: browserOpener) {
                    didBrowserOpenFail = true
                }
                return true
            }
            return false
        }
    }

    private static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
            || host == "auth.openai.com" || host.hasSuffix(".auth.openai.com")
    }
}

enum LoginDiagnosticSanitizer {
    static let maximumByteCount = 4_096
    private static let truncationMarker = "[TRUNCATED]"
    private static let replacements: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"\b[a-z][a-z0-9+.-]*://[^\s<>\"']+"#, options: [.caseInsensitive]), "[URL REDACTED]"),
        (try! NSRegularExpression(pattern: #"(?i)\b(bearer)\s+[^\s,;]+"#), "$1 [REDACTED]"),
        (try! NSRegularExpression(pattern: #"(?i)\b([a-z0-9_-]*(?:token|api[_-]?key|authorization|cookie|credential|password|secret)[a-z0-9_-]*)\b[\"']?\s*[:=]\s*[\"']?[^\s,;}\]\"']+"#), "$1=[REDACTED]"),
        (try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#), "[JWT REDACTED]"),
    ]

    static func sanitize(_ data: Data, truncated: Bool) -> String {
        var value = String(decoding: data, as: UTF8.self)
        for (expression, replacement) in replacements {
            value = expression.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..., in: value),
                withTemplate: replacement
            )
        }
        value = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if truncated || value.lengthOfBytes(using: .utf8) > maximumByteCount {
            let suffix = value.isEmpty ? truncationMarker : " \(truncationMarker)"
            value = String(value.prefixUTF8Bytes(maximumByteCount - suffix.lengthOfBytes(using: .utf8))) + suffix
        }
        return value
    }
}

extension String {
    func prefixUTF8Bytes(_ maximumByteCount: Int) -> Substring {
        var endIndex = startIndex
        var byteCount = 0
        for index in indices {
            let nextIndex = self.index(after: index)
            let characterByteCount = self[index..<nextIndex].lengthOfBytes(using: .utf8)
            guard byteCount + characterByteCount <= maximumByteCount else { break }
            byteCount += characterByteCount
            endIndex = nextIndex
        }
        return self[..<endIndex]
    }
}

protocol ClaudeProfileManaging: Sendable {
    func listProfiles() async throws -> [ClaudeProfileMetadata]
    func activeProfileID() async -> String?
    func saveCurrent(named name: String) async throws -> ClaudeProfileMetadata
    func addAccount(named name: String) async throws -> ClaudeProfileMetadata?
    func activateProfile(id: String) async throws
    func removeProfile(id: String) async throws
    func accessToken(for id: String) async throws -> String
    func syncActiveProfile() async
}

extension ClaudeProfileManager: ClaudeProfileManaging {}

protocol CodexProfileManaging: Sendable {
    func saveCurrent(named name: String) async throws -> CodexProfileMetadata
    func addAccount(named name: String) async throws -> CodexProfileMetadata?
    func removeProfile(id: String) async throws
    func listProfiles() async throws -> [CodexProfileMetadata]
    func activeProfileID() async -> String?
    func activateProfile(id: String) async throws
    func materializeProfileHome(id: String) async throws -> CodexProfileHomeMaterialization
    func writeBackProfileCredential(id: String, baseline: Data) async throws
}

extension CodexProfileManager: CodexProfileManaging {}

struct CodexRefreshOutcome: Sendable {
    let usages: [CodexProfileUsage]
    let failures: [String: any Error]
}

actor ProductionAppService: CodexProfileActionHandling, ClaudeProfileActionHandling {
    private let loadClaude: @Sendable () async throws -> UsageSnapshot
    private let loadClaudeUsage: @Sendable (String) async throws -> UsageSnapshot
    private let loadCodex: @Sendable (URL) async throws -> UsageSnapshot
    private let loadOpenRouter: @Sendable () async throws -> OpenRouterUsageSnapshot
    private let validateCodexAccount: @Sendable (URL) async throws -> CodexAccount
    private let profileManager: any CodexProfileManaging
    private let claudeProfileManager: (any ClaudeProfileManaging)?
    private var previousClaude: UsageState?
    private var previousClaudeProfiles: [String: UsageState] = [:]
    private var previousCodex: [String: UsageState] = [:]
    private var previousOpenRouter: OpenRouterUsageState?
    private var didBootstrapProfile = false
    private var didBootstrapClaudeProfile = false

    init(
        claudeClient: ClaudeUsageClient,
        codexClient: CodexAppServerClient,
        openRouterClient: OpenRouterUsageClient,
        profileManager: any CodexProfileManaging,
        claudeProfileManager: (any ClaudeProfileManaging)? = nil
    ) {
        loadClaude = { try await claudeClient.usage() }
        loadClaudeUsage = { try await claudeClient.usage(accessToken: $0) }
        loadCodex = { try await codexClient.usage(codexHome: $0) }
        loadOpenRouter = { try await openRouterClient.usage() }
        validateCodexAccount = { try await codexClient.validate(codexHome: $0) }
        self.profileManager = profileManager
        self.claudeProfileManager = claudeProfileManager
    }

    init(
        loadClaude: @escaping @Sendable () async throws -> UsageSnapshot,
        loadCodex: @escaping @Sendable (URL) async throws -> UsageSnapshot,
        loadOpenRouter: @escaping @Sendable () async throws -> OpenRouterUsageSnapshot = {
            throw OpenRouterUsageClientError.keyUnavailable
        },
        validateCodexAccount: @escaping @Sendable (URL) async throws -> CodexAccount = { _ in
            throw CodexAppServerClient.Error.processFailed
        },
        profileManager: any CodexProfileManaging,
        loadClaudeUsage: @escaping @Sendable (String) async throws -> UsageSnapshot = { _ in
            throw ClaudeUsageClientError.credentialUnavailable
        },
        claudeProfileManager: (any ClaudeProfileManaging)? = nil
    ) {
        self.loadClaude = loadClaude
        self.loadClaudeUsage = loadClaudeUsage
        self.loadCodex = loadCodex
        self.loadOpenRouter = loadOpenRouter
        self.validateCodexAccount = validateCodexAccount
        self.profileManager = profileManager
        self.claudeProfileManager = claudeProfileManager
    }

    func refresh() async -> AppUsageSnapshot {
        await bootstrapCurrentProfileIfNeeded()
        await bootstrapClaudeProfileIfNeeded()
        // Capture whatever Claude Code refreshed on its own before reading any stored token.
        await claudeProfileManager?.syncActiveProfile()
        let claudeProfiles = await listClaudeProfiles()
        async let claudeResult = refreshLiveClaude(skip: !claudeProfiles.isEmpty)
        async let claudeProfileResult = refreshClaudeProfiles(claudeProfiles)
        async let openRouterResult = Self.loadOpenRouterUsage(loadOpenRouter)
        let profiles = (try? await profileManager.listProfiles()) ?? []
        async let codexResult = refreshCodexProfiles(profiles)
        let (loadedClaude, claudeUsages, loadedOpenRouter, codex) = await (
            claudeResult,
            claudeProfileResult,
            openRouterResult,
            codexResult
        )

        let claude: UsageState
        if let loadedClaude {
            claude = Self.state(from: loadedClaude, previous: previousClaude, service: "Claude")
            previousClaude = claude
        } else {
            claude = previousClaude ?? .unavailable(message: "Claude usage refresh failed.")
        }
        previousClaudeProfiles = Dictionary(
            uniqueKeysWithValues: claudeUsages.map { ($0.profileID, $0.state) }
        )
        let openRouter = Self.openRouterState(
            from: loadedOpenRouter,
            previous: previousOpenRouter
        )
        previousOpenRouter = openRouter

        let removed = await pruneSignedOutProfiles(profiles, failures: codex.failures)
        let removedIDs = Set(removed.map(\.id))
        let usages = codex.usages.filter { !removedIDs.contains($0.profileID) }
        previousCodex = Dictionary(uniqueKeysWithValues: usages.map { ($0.profileID, $0.state) })
        return await snapshot(
            claude: claude,
            codex: usages,
            openRouter: openRouter,
            profiles: profiles.filter { !removedIDs.contains($0.id) },
            removedProfileNames: removed.map(\.name),
            claudeUsage: claudeUsages,
            claudeProfiles: claudeProfiles
        )
    }

    private func listClaudeProfiles() async -> [ClaudeProfileMetadata] {
        guard let claudeProfileManager else { return [] }
        return (try? await claudeProfileManager.listProfiles()) ?? []
    }

    /// Skipped once accounts are captured: the active account's usage already arrives through its
    /// profile, and a second identical request would only spend quota-free rate limit.
    private func refreshLiveClaude(skip: Bool) async -> Result<UsageSnapshot, any Error>? {
        guard !skip else { return nil }
        return await Self.loadUsage(loadClaude)
    }

    private func refreshClaudeProfiles(
        _ profiles: [ClaudeProfileMetadata]
    ) async -> [ClaudeProfileUsage] {
        guard let manager = claudeProfileManager, !profiles.isEmpty else { return [] }
        let loader = loadClaudeUsage
        var states: [String: UsageState] = [:]
        await withTaskGroup(of: (String, Result<UsageSnapshot, any Error>).self) { group in
            for profile in profiles {
                group.addTask {
                    do {
                        let token = try await manager.accessToken(for: profile.id)
                        return (profile.id, .success(try await loader(token)))
                    } catch {
                        return (profile.id, .failure(error))
                    }
                }
            }
            while let (profileID, result) = await group.next() {
                states[profileID] = Self.state(
                    from: result,
                    previous: previousClaudeProfiles[profileID],
                    service: "Claude"
                )
            }
        }
        return profiles.map {
            ClaudeProfileUsage(
                profileID: $0.id,
                state: states[$0.id] ?? .unavailable(message: "Claude usage refresh failed.")
            )
        }
    }

    private func bootstrapClaudeProfileIfNeeded() async {
        guard let claudeProfileManager, !didBootstrapClaudeProfile else { return }
        didBootstrapClaudeProfile = true
        guard let profiles = try? await claudeProfileManager.listProfiles(),
              profiles.isEmpty else {
            return
        }
        _ = try? await claudeProfileManager.saveCurrent(
            named: ClaudeProfileManager.bootstrapProfileName
        )
    }

    func selectClaudeProfile(id: String) async throws -> AppUsageSnapshot {
        try await requiredClaudeProfileManager().activateProfile(id: id)
        return await refresh()
    }

    func saveCurrentClaudeProfile(named name: String) async throws -> AppUsageSnapshot {
        _ = try await requiredClaudeProfileManager().saveCurrent(named: name)
        return await refresh()
    }

    func addClaudeAccount(named name: String) async throws -> AppUsageSnapshot {
        _ = try await requiredClaudeProfileManager().addAccount(named: name)
        return await refresh()
    }

    func deleteClaudeProfile(id: String) async throws -> AppUsageSnapshot {
        try await requiredClaudeProfileManager().removeProfile(id: id)
        return await refresh()
    }

    private func requiredClaudeProfileManager() throws -> any ClaudeProfileManaging {
        guard let claudeProfileManager else { throw ClaudeProfileManagerError.storageFailed }
        return claudeProfileManager
    }

    func selectProfile(id: String) async throws -> AppUsageSnapshot {
        try await profileManager.activateProfile(id: id)
        return await refresh()
    }

    func saveCurrentProfile(named name: String) async throws -> AppUsageSnapshot {
        _ = try await profileManager.saveCurrent(named: name)
        return await refresh()
    }

    func addAccount(named name: String) async throws -> AppUsageSnapshot {
        _ = try await profileManager.addAccount(named: name)
        return await refresh()
    }

    func deleteProfile(id: String) async throws -> AppUsageSnapshot {
        try await profileManager.removeProfile(id: id)
        return await refresh()
    }

    private func bootstrapCurrentProfileIfNeeded() async {
        guard !didBootstrapProfile else { return }
        didBootstrapProfile = true
        guard let profiles = try? await profileManager.listProfiles(), profiles.isEmpty else { return }
        _ = try? await profileManager.saveCurrent(named: "codex2")
    }

    private func snapshot(
        claude: UsageState,
        codex: [CodexProfileUsage],
        openRouter: OpenRouterUsageState,
        profiles: [CodexProfileMetadata],
        removedProfileNames: [String] = [],
        claudeUsage: [ClaudeProfileUsage] = [],
        claudeProfiles: [ClaudeProfileMetadata] = []
    ) async -> AppUsageSnapshot {
        let activeID = await profileManager.activeProfileID()
        let activeClaudeID = await claudeProfileManager?.activeProfileID()
        return AppUsageSnapshot(
            claude: claude,
            codexUsage: codex,
            codexProfiles: profiles,
            activeCodexProfileID: profiles.contains(where: { $0.id == activeID }) ? activeID : nil,
            openRouter: openRouter,
            removedCodexProfileNames: removedProfileNames,
            claudeUsage: claudeUsage,
            claudeProfiles: claudeProfiles,
            activeClaudeProfileID: claudeProfiles.contains(where: { $0.id == activeClaudeID })
                ? activeClaudeID
                : nil
        )
    }

    private func refreshCodexProfiles(
        _ profiles: [CodexProfileMetadata]
    ) async -> CodexRefreshOutcome {
        var iterator = profiles.makeIterator()
        var states: [String: UsageState] = [:]
        var failures: [String: any Error] = [:]
        await withTaskGroup(of: (String, Result<UsageSnapshot, any Error>).self) { group in
            for _ in 0..<min(4, profiles.count) {
                guard let profile = iterator.next() else { break }
                addCodexRefresh(profile, to: &group)
            }
            while let (profileID, result) = await group.next() {
                if case let .failure(error) = result {
                    failures[profileID] = error
                }
                states[profileID] = Self.state(
                    from: result,
                    previous: previousCodex[profileID],
                    service: "Codex"
                )
                if let profile = iterator.next() {
                    addCodexRefresh(profile, to: &group)
                }
            }
        }
        return CodexRefreshOutcome(
            usages: profiles.map {
                CodexProfileUsage(
                    profileID: $0.id,
                    state: states[$0.id] ?? .unavailable(message: "Codex usage refresh failed.")
                )
            },
            failures: failures
        )
    }

    /// Deletes profiles whose refresh failed because the account is no longer signed in.
    /// Transient failures (network, process, timeout) never delete anything: a profile is only
    /// dropped when Codex itself reports the stored credential as unusable.
    private func pruneSignedOutProfiles(
        _ profiles: [CodexProfileMetadata],
        failures: [String: any Error]
    ) async -> [CodexProfileMetadata] {
        guard !failures.isEmpty else { return [] }
        var removed: [CodexProfileMetadata] = []
        for profile in profiles {
            guard let failure = failures[profile.id],
                  await isSignedOut(profile: profile, failure: failure) else { continue }
            do {
                try await profileManager.removeProfile(id: profile.id)
                previousCodex[profile.id] = nil
                removed.append(profile)
            } catch {
                continue
            }
        }
        return removed
    }

    private func isSignedOut(profile: CodexProfileMetadata, failure: any Error) async -> Bool {
        if failure is CancellationError { return false }
        if let managerError = failure as? CodexProfileManagerError {
            return managerError == .credentialMissing
        }
        if let clientError = failure as? CodexAppServerClient.Error,
           Self.signalsSignedOut(clientError) {
            return true
        }

        let homeURL: URL
        do {
            homeURL = try await profileManager.materializeProfileHome(id: profile.id).homeURL
        } catch CodexProfileManagerError.credentialMissing {
            return true
        } catch {
            return false
        }
        do {
            _ = try await validateCodexAccount(homeURL)
            return false
        } catch let clientError as CodexAppServerClient.Error {
            return Self.signalsSignedOut(clientError)
        } catch {
            return false
        }
    }

    private static func signalsSignedOut(_ error: CodexAppServerClient.Error) -> Bool {
        switch error {
        case .notAuthenticated, .invalidAuthData:
            return true
        default:
            return false
        }
    }

    private func addCodexRefresh(
        _ profile: CodexProfileMetadata,
        to group: inout TaskGroup<(String, Result<UsageSnapshot, any Error>)>
    ) {
        let manager = profileManager
        let loader = loadCodex
        group.addTask {
            do {
                let materialization = try await manager.materializeProfileHome(id: profile.id)
                let usage = try await loader(materialization.homeURL)
                try await manager.writeBackProfileCredential(
                    id: profile.id,
                    baseline: materialization.credentialBaseline
                )
                return (profile.id, .success(usage))
            } catch {
                return (profile.id, .failure(error))
            }
        }
    }

    private static func loadUsage(
        _ operation: @escaping @Sendable () async throws -> UsageSnapshot
    ) async -> Result<UsageSnapshot, any Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    private static func loadOpenRouterUsage(
        _ operation: @escaping @Sendable () async throws -> OpenRouterUsageSnapshot
    ) async -> Result<OpenRouterUsageSnapshot, any Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    private static func openRouterState(
        from result: Result<OpenRouterUsageSnapshot, any Error>,
        previous: OpenRouterUsageState?
    ) -> OpenRouterUsageState {
        switch result {
        case .success(let snapshot):
            return .fresh(snapshot)
        case .failure(let error):
            if let clientError = error as? OpenRouterUsageClientError {
                switch clientError {
                case .keyUnavailable:
                    return .notConfigured(message: OpenRouterUsageState.notConfiguredHint)
                case .unauthorized:
                    return .refreshFailed(
                        message: "OpenRouter authorization failed.",
                        previous: previous
                    )
                case .timeout:
                    return .refreshFailed(
                        message: "OpenRouter request timed out.",
                        previous: previous
                    )
                case .networkFailure:
                    return .refreshFailed(
                        message: "OpenRouter network request failed.",
                        previous: previous
                    )
                case .malformedResponse:
                    return .refreshFailed(
                        message: "OpenRouter returned an invalid response.",
                        previous: previous
                    )
                case .unexpectedHTTPStatus(let statusCode):
                    return .refreshFailed(
                        message: "OpenRouter request failed with HTTP status \(statusCode).",
                        previous: previous
                    )
                }
            }
            if error is CancellationError {
                return .refreshFailed(
                    message: "OpenRouter request was cancelled.",
                    previous: previous
                )
            }
            return .refreshFailed(
                message: "OpenRouter usage refresh failed.",
                previous: previous
            )
        }
    }

    private static func state(
        from result: Result<UsageSnapshot, any Error>,
        previous: UsageState?,
        service: String
    ) -> UsageState {
        switch result {
        case .success(let snapshot):
            return .fresh(snapshot)
        case .failure:
            return .refreshFailed(message: "\(service) usage refresh failed.", previous: previous)
        }
    }
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let refreshInterval: Duration = .seconds(300)

    private let statusItem: NSStatusItem
    private let statusView: StatusItemView
    private var popover: NSPopover?
    private var popoverHostingController: UsagePopoverHostingController?
    private var outsideClickMonitor: Any?
    private let model: AppViewModel
    private let loginAttemptController: CodexLoginAttemptController?
    private let removeStatusItem: @MainActor (NSStatusItem) -> Void
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    init(
        model: AppViewModel,
        statusItem: NSStatusItem,
        loginAttemptController: CodexLoginAttemptController? = nil,
        removeStatusItem: @escaping @MainActor (NSStatusItem) -> Void = {
            NSStatusBar.system.removeStatusItem($0)
        }
    ) {
        self.model = model
        self.statusItem = statusItem
        self.loginAttemptController = loginAttemptController
        self.removeStatusItem = removeStatusItem
        statusView = StatusItemView(presentation: model.statusItemPresentation)
        super.init()

        statusItem.button?.setAccessibilityIdentifier("token-usage-status-button")
        statusItem.button?.setAccessibilityLabel("Token Usage status")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        layoutStatusView()

        model.$statusItemPresentation
            .removeDuplicates()
            .sink { [weak self] presentation in self?.updateStatusItem(presentation) }
            .store(in: &cancellables)
    }

    static func production(environment: [String: String] = ProcessInfo.processInfo.environment) -> MenuBarController {
        let claudeStore = ReadFailureCachingCredentialReader(
            wrapping: SecurityCLIClaudeCredentialStore()
        )
        let claudeClient = ClaudeUsageClient(
            credentialReader: claudeStore,
            session: URLSession.shared,
            credentialName: NSUserName()
        )
        let codexDependencies = ProductionCodexDependencies(environment: environment)
        let codexClient = codexDependencies.makeCodexClient()
        let openRouterClient = OpenRouterUsageClient(environment: environment)
        let profileStore = KeychainCredentialStore(service: "local.tokenusage.codex-profiles")
        let loginAttemptController = CodexLoginAttemptController()
        let loginRunner = codexDependencies.makeLoginRunner(
            attemptController: loginAttemptController
        )
        let profileManager = CodexProfileManager(
            credentialStore: profileStore,
            preferences: CodexProfilePreferences(),
            authFileOperator: AtomicAuthFileOperator(
                authFileURL: codexDependencies.defaultCodexHome.appendingPathComponent("auth.json")
            ),
            accountValidator: codexClient,
            loginRunner: loginRunner,
            defaultCodexHome: codexDependencies.defaultCodexHome,
            applicationSupportRoot: codexDependencies.applicationSupportDirectory
        )
        let claudeProfileManager = ClaudeProfileManager(
            credentialStore: KeychainCredentialStore(service: "local.tokenusage.claude-profiles"),
            preferences: ClaudeProfilePreferences(),
            liveCredential: SecurityCLIClaudeLiveCredentialOperator(),
            configOperator: FileClaudeConfigOperator(
                configFileURL: Self.claudeConfigFileURL(environment: environment)
            ),
            authStatus: ClaudeCLIAuthStatusReader(environment: environment),
            refresher: ClaudeOAuthRefresher(),
            // Shares the Codex sign-in attempt so one status line drives both flows; the popover
            // disables every profile control while either is running.
            loginRunner: SystemClaudeLoginRunner(
                environment: environment,
                attemptController: loginAttemptController
            )
        )
        let service = ProductionAppService(
            claudeClient: claudeClient,
            codexClient: codexClient,
            openRouterClient: openRouterClient,
            profileManager: profileManager,
            claudeProfileManager: claudeProfileManager
        )
        let coordinator = AppRefreshCoordinator(
            coordinator: RefreshCoordinator(
                clock: SystemRefreshClock(),
                interval: refreshInterval,
                refresh: { await service.refresh() }
            )
        )
        let model = AppViewModel(
            coordinator: coordinator,
            profileActions: service,
            claudeProfileActions: service,
            loginAttemptState: {
                let presentation = loginAttemptController.presentation
                return CodexLoginAttemptState(
                    isActive: presentation.canCancel,
                    canReopen: presentation.canReopenSignIn
                )
            },
            reopenCodexSignIn: { loginAttemptController.reopenSignIn() },
            cancelCodexSignIn: { loginAttemptController.cancelSignIn() }
        )
        return MenuBarController(
            model: model,
            statusItem: NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength),
            loginAttemptController: loginAttemptController
        )
    }

    /// `~/.claude.json`, honouring `CLAUDE_CONFIG_DIR` the same way the CLI does.
    static func claudeConfigFileURL(environment: [String: String]) -> URL {
        if let configDirectory = environment["CLAUDE_CONFIG_DIR"], !configDirectory.isEmpty {
            return URL(fileURLWithPath: configDirectory, isDirectory: true)
                .appendingPathComponent(".claude.json", isDirectory: false)
                .standardizedFileURL
        }
        let home = environment["HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude.json", isDirectory: false).standardizedFileURL
    }

    static func runCompositionSmoke(environment: [String: String]) async -> Never {
        let dependencies = ProductionCodexDependencies(
            environment: environment,
            browserOpener: { _ in false }
        )
        do {
            let executable = try dependencies.resolveCodexExecutable().standardizedFileURL
            let snapshot = try await dependencies.makeCodexClient().usage(
                codexHome: dependencies.defaultCodexHome
            )
            let fnmDefault = environment["FNM_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .appendingPathComponent("aliases/default/bin/codex", isDirectory: false)
                    .standardizedFileURL
            }
            let source = executable == fnmDefault ? "fnm-default" : "other"
            let weekly = snapshot.weekly?.remainingPercent ?? -1
            print("TASK7_LAUNCH_SMOKE result=success resolver=\(source) executed=true weekly=\(weekly) browser_opened=false")
            fflush(stdout)
            Darwin.exit(EXIT_SUCCESS)
        } catch let error as CodexAppServerClient.Error {
            print("TASK7_LAUNCH_SMOKE result=failure error=\(error) browser_opened=false")
            fflush(stdout)
            Darwin.exit(EX_CONFIG)
        } catch {
            print("TASK7_LAUNCH_SMOKE result=failure error=executableNotFound browser_opened=false")
            fflush(stdout)
            Darwin.exit(EX_CONFIG)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        model.start()
    }

    func stop() async {
        guard started else { return }
        started = false
        closePopover()
        cancellables.removeAll()
        await model.stop()
        removeStatusItem(statusItem)
    }

    static let popoverBehavior: NSPopover.Behavior = .transient

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(relativeTo: button)
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        let popover = NSPopover()
        let hostingController = UsagePopoverHostingController(model: model)
        // .semitransient ignores clicks in other applications, so the popover stayed open until the
        // status item was clicked again. .transient closes on any click outside it.
        popover.behavior = Self.popoverBehavior
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = hostingController
        self.popover = popover
        popoverHostingController = hostingController
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        hostingController.view.layoutSubtreeIfNeeded()
        NSAccessibility.post(element: hostingController.view, notification: .created)
        startWatchingForOutsideClicks()
    }

    /// A menu bar accessory's popover never becomes key, so `.transient` alone does not see clicks
    /// that land in another application. The global monitor does.
    private func startWatchingForOutsideClicks() {
        stopWatchingForOutsideClicks()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func stopWatchingForOutsideClicks() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    private func closePopover() {
        stopWatchingForOutsideClicks()
        loginAttemptController?.clearForPopoverClose()
        popover?.close()
        popover = nil
        popoverHostingController = nil
    }

    func popoverDidClose(_ notification: Notification) {
        stopWatchingForOutsideClicks()
        loginAttemptController?.clearForPopoverClose()
        popover = nil
        popoverHostingController = nil
    }

    private func updateStatusItem(_ presentation: StatusItemPresentation) {
        statusView.update(with: presentation)
        layoutStatusView()
    }

    private func layoutStatusView() {
        guard let button = statusItem.button else { return }
        let size = statusView.intrinsicContentSize
        statusItem.length = size.width + 8
        button.image = statusView.renderedImage(appearance: button.effectiveAppearance)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.setAccessibilityLabel(statusView.accessibilityLabel() ?? "Token Usage status")
    }
}
