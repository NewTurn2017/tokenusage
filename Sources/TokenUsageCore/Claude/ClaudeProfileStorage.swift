import Foundation

/// A named Claude Code account. Everything here is non-secret: the token itself lives in the
/// Keychain under the profile identifier.
public struct ClaudeProfileMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let accountUUID: String?
    public let emailAddress: String?
    public let organizationName: String?
    public let subscriptionType: String?
    /// Canonical JSON of the `oauthAccount` block from `~/.claude.json`, restored on activation
    /// so the CLI reports the account it is actually signed in as.
    public let configAccountJSON: String?

    public init(
        id: String,
        name: String,
        accountUUID: String? = nil,
        emailAddress: String? = nil,
        organizationName: String? = nil,
        subscriptionType: String? = nil,
        configAccountJSON: String? = nil
    ) {
        self.id = id
        self.name = name
        self.accountUUID = accountUUID
        self.emailAddress = emailAddress
        self.organizationName = organizationName
        self.subscriptionType = subscriptionType
        self.configAccountJSON = configAccountJSON
    }

    public func withIdentity(from account: ClaudeAccount, configAccountJSON: String?) -> Self {
        ClaudeProfileMetadata(
            id: id,
            name: name,
            accountUUID: account.accountUUID ?? accountUUID,
            emailAddress: account.email ?? emailAddress,
            organizationName: account.organizationName ?? organizationName,
            subscriptionType: account.subscriptionType ?? subscriptionType,
            configAccountJSON: configAccountJSON ?? self.configAccountJSON
        )
    }
}

/// Identity reported by `claude auth status --json`.
public struct ClaudeAccount: Equatable, Sendable {
    public let email: String?
    public let organizationID: String?
    public let organizationName: String?
    public let subscriptionType: String?
    public let accountUUID: String?

    public init(
        email: String? = nil,
        organizationID: String? = nil,
        organizationName: String? = nil,
        subscriptionType: String? = nil,
        accountUUID: String? = nil
    ) {
        self.email = email
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.subscriptionType = subscriptionType
        self.accountUUID = accountUUID
    }
}

public enum ClaudeProfilePreferencesError: Error, Equatable, LocalizedError {
    case invalidProfileMetadata

    public var errorDescription: String? {
        "Claude 프로필 정보를 읽을 수 없습니다."
    }
}

public protocol ClaudeProfilePreferencesStoring: AnyObject {
    func saveProfiles(_ profiles: [ClaudeProfileMetadata]) throws
    func profiles() throws -> [ClaudeProfileMetadata]
    var activeProfileID: String? { get set }
}

public final class ClaudeProfilePreferences: ClaudeProfilePreferencesStoring {
    private let defaults: UserDefaults
    private static let profilesKey = "claude.profileMetadata"
    private static let activeProfileIDKey = "claude.activeProfileID"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func saveProfiles(_ profiles: [ClaudeProfileMetadata]) throws {
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: Self.profilesKey)
        } catch {
            throw ClaudeProfilePreferencesError.invalidProfileMetadata
        }
    }

    public func profiles() throws -> [ClaudeProfileMetadata] {
        guard let data = defaults.data(forKey: Self.profilesKey) else { return [] }
        do {
            return try JSONDecoder().decode([ClaudeProfileMetadata].self, from: data)
        } catch {
            throw ClaudeProfilePreferencesError.invalidProfileMetadata
        }
    }

    public var activeProfileID: String? {
        get { defaults.string(forKey: Self.activeProfileIDKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.activeProfileIDKey)
            } else {
                defaults.removeObject(forKey: Self.activeProfileIDKey)
            }
        }
    }
}
