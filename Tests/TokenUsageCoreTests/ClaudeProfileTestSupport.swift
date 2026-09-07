import Foundation
@testable import TokenUsageCore

final class MemoryClaudeCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func credential(named name: String) throws -> Data? {
        lock.withLock { storage[name] }
    }

    func storeCredential(_ credential: Data, named name: String) throws {
        lock.withLock { storage[name] = credential }
    }

    func removeCredential(named name: String) throws {
        lock.withLock { storage[name] = nil }
    }

    var storedNames: [String] {
        lock.withLock { storage.keys.sorted() }
    }
}

final class MemoryClaudeProfilePreferences: ClaudeProfilePreferencesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ClaudeProfileMetadata] = []
    private var active: String?

    var activeProfileID: String? {
        get { lock.withLock { active } }
        set { lock.withLock { active = newValue } }
    }

    func saveProfiles(_ profiles: [ClaudeProfileMetadata]) throws {
        lock.withLock { stored = profiles }
    }

    func profiles() throws -> [ClaudeProfileMetadata] {
        lock.withLock { stored }
    }
}

final class FakeClaudeLiveCredentialOperator: ClaudeLiveCredentialOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var envelope: Data?
    private var failure: (any Error)?

    init(envelope: Data?) {
        self.envelope = envelope
    }

    func failNextReplace(with error: any Error) {
        lock.withLock { failure = error }
    }

    func readEnvelope() throws -> Data? {
        lock.withLock { envelope }
    }

    func replaceEnvelope(with data: Data, ifCurrentMatches expected: Data?) throws {
        try lock.withLock {
            if let failure {
                self.failure = nil
                throw failure
            }
            guard envelope == expected else { throw ClaudeLiveCredentialError.conflict }
            envelope = data
        }
    }

    var current: Data? {
        lock.withLock { envelope }
    }
}

final class FakeClaudeConfigOperator: ClaudeConfigOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var json: String?
    private var applied: [String?] = []

    init(json: String?) {
        self.json = json
    }

    func readAccountJSON() throws -> String? {
        lock.withLock { json }
    }

    func applyAccountJSON(_ json: String?) throws {
        lock.withLock {
            self.json = json
            applied.append(json)
        }
    }

    var appliedAccounts: [String?] {
        lock.withLock { applied }
    }
}

final class FakeClaudeAuthStatusReader: ClaudeAuthStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private var account: ClaudeAccount
    private var failure: (any Error)?
    private var calls = 0

    init(account: ClaudeAccount) {
        self.account = account
    }

    func setAccount(_ account: ClaudeAccount) {
        lock.withLock { self.account = account }
    }

    func setFailure(_ failure: (any Error)?) {
        lock.withLock { self.failure = failure }
    }

    func readAuthStatus(configurationDirectory: URL?) async throws -> ClaudeAccount {
        try lock.withLock {
            calls += 1
            if let failure { throw failure }
            return account
        }
    }

    var callCount: Int {
        lock.withLock { calls }
    }
}

final class FakeClaudeOAuthRefresher: ClaudeOAuthRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var replacement: ClaudeOAuthToken?
    private var failure: (any Error)?
    private var calls = 0

    init(replacement: ClaudeOAuthToken? = nil) {
        self.replacement = replacement
    }

    func setFailure(_ failure: (any Error)?) {
        lock.withLock { self.failure = failure }
    }

    func refresh(_ token: ClaudeOAuthToken) async throws -> ClaudeOAuthToken {
        try lock.withLock {
            calls += 1
            if let failure { throw failure }
            return replacement ?? token
        }
    }

    var callCount: Int {
        lock.withLock { calls }
    }
}

final class FakeClaudeLoginRunner: ClaudeLoginRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: ClaudeLoginOutcome
    private var failure: (any Error)?
    private var directories: [URL] = []
    /// Stands in for what `claude auth login` leaves behind in the throwaway directory.
    private var plant: (@Sendable (URL, String) -> Void)?

    init(outcome: ClaudeLoginOutcome = .completed) {
        self.outcome = outcome
    }

    func setFailure(_ failure: (any Error)?) {
        lock.withLock { self.failure = failure }
    }

    func onLogin(_ plant: @escaping @Sendable (URL, String) -> Void) {
        lock.withLock { self.plant = plant }
    }

    func runClaudeLogin(configurationDirectory: URL) async throws -> ClaudeLoginOutcome {
        let action: (ClaudeLoginOutcome, (any Error)?, (@Sendable (URL, String) -> Void)?) =
            lock.withLock {
                directories.append(configurationDirectory)
                return (outcome, failure, plant)
            }
        if let error = action.1 { throw error }
        action.2?(
            configurationDirectory,
            ClaudeKeychainService.service(forConfigurationDirectory: configurationDirectory)
        )
        return action.0
    }

    var configurationDirectories: [URL] {
        lock.withLock { directories }
    }
}

final class MemoryIsolatedClaudeCredentials: ClaudeIsolatedCredentialAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var removed: [String] = []

    func plant(_ envelope: Data, service: String) {
        lock.withLock { storage[service] = envelope }
    }

    func readEnvelope(service: String) throws -> Data? {
        lock.withLock { storage[service] }
    }

    func remove(service: String) throws {
        lock.withLock {
            storage[service] = nil
            removed.append(service)
        }
    }

    var removedServices: [String] {
        lock.withLock { removed }
    }

    var remainingServices: [String] {
        lock.withLock { storage.keys.sorted() }
    }
}

enum ClaudeCredentialFixture {
    /// Mirrors the shape Claude Code stores: the signed-in account next to the machine's MCP
    /// tokens, which a switch must never disturb.
    static func envelope(
        accessToken: String,
        refreshToken: String = "refresh",
        expiresAtMilliseconds: Int64 = 4_102_444_800_000,
        mcpServerName: String = "figma"
    ) -> Data {
        let root: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": accessToken,
                "refreshToken": refreshToken,
                "expiresAt": NSNumber(value: expiresAtMilliseconds),
                "scopes": ["user:inference", "user:profile"],
                "subscriptionType": "max",
            ],
            "mcpOAuth": [
                mcpServerName: ["accessToken": "mcp-token"],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func oauthSection(
        accessToken: String,
        refreshToken: String = "refresh",
        expiresAtMilliseconds: Int64 = 4_102_444_800_000
    ) -> Data {
        try! ClaudeCredentialEnvelope.oauthSection(
            from: envelope(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAtMilliseconds: expiresAtMilliseconds
            )
        )
    }

    static func configAccount(email: String, accountUUID: String) -> String {
        let account: [String: Any] = [
            "accountUuid": accountUUID,
            "emailAddress": email,
            "organizationName": "Personal",
        ]
        return String(
            decoding: try! ClaudeCredentialEnvelope.canonicalData(account),
            as: UTF8.self
        )
    }
}
