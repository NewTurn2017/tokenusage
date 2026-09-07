import Foundation
import Security

public enum KeychainCredentialStoreError: Error, Equatable, LocalizedError {
    case operationFailed

    public var errorDescription: String? {
        "Credential storage operation failed."
    }
}

public protocol ConditionalGenericPasswordClient: GenericPasswordClient {
    func compareAndSwapGenericPassword(
        data: Data,
        expectedData: Data,
        service: String,
        account: String
    ) throws -> Bool
}

public protocol ConditionalCredentialStoring: CredentialStoring {
    func storeCredential(
        _ credential: Data,
        named name: String,
        ifCurrentMatches expectedCredential: Data
    ) throws -> Bool
}

public struct SystemGenericPasswordClient: ConditionalGenericPasswordClient, Sendable {
    private static let operationLock = NSLock()

    public init() {}

    public func copyGenericPassword(service: String, account: String) throws -> Data? {
        try Self.operationLock.withLock {
            try copyGenericPasswordUnlocked(service: service, account: account)
        }
    }

    public func upsertGenericPassword(data: Data, service: String, account: String) throws {
        try Self.operationLock.withLock {
            try upsertGenericPasswordUnlocked(data: data, service: service, account: account)
        }
    }

    public func removeGenericPassword(service: String, account: String) throws {
        try Self.operationLock.withLock {
            try removeGenericPasswordUnlocked(service: service, account: account)
        }
    }

    public func compareAndSwapGenericPassword(
        data: Data,
        expectedData: Data,
        service: String,
        account: String
    ) throws -> Bool {
        // Security.framework exposes no cross-process compare-and-swap primitive.
        // This lock makes the baseline recheck and update indivisible only for
        // SystemGenericPasswordClient operations in this process.
        try Self.operationLock.withLock {
            guard try copyGenericPasswordUnlocked(service: service, account: account) == expectedData else {
                return false
            }
            try upsertGenericPasswordUnlocked(data: data, service: service, account: account)
            return true
        }
    }

    private func copyGenericPasswordUnlocked(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainCredentialStoreError.operationFailed
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainCredentialStoreError.operationFailed
        }
    }

    private func upsertGenericPasswordUnlocked(data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound || status == errSecDuplicateItem {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.operationFailed
        }
    }

    private func removeGenericPasswordUnlocked(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.operationFailed
        }
    }
}

public struct KeychainCredentialStore: ConditionalCredentialStoring, Sendable {
    private let service: String
    private let keychain: any GenericPasswordClient

    public init(service: String) {
        self.init(service: service, keychain: SystemGenericPasswordClient())
    }

    public init(service: String, keychain: any GenericPasswordClient) {
        self.service = service
        self.keychain = keychain
    }

    public func credential(named name: String) throws -> Data? {
        do {
            return try keychain.copyGenericPassword(service: service, account: name)
        } catch {
            throw KeychainCredentialStoreError.operationFailed
        }
    }

    public func storeCredential(_ credential: Data, named name: String) throws {
        do {
            try keychain.upsertGenericPassword(data: credential, service: service, account: name)
        } catch {
            throw KeychainCredentialStoreError.operationFailed
        }
    }

    public func removeCredential(named name: String) throws {
        do {
            try keychain.removeGenericPassword(service: service, account: name)
        } catch {
            throw KeychainCredentialStoreError.operationFailed
        }
    }

    public func storeCredential(
        _ credential: Data,
        named name: String,
        ifCurrentMatches expectedCredential: Data
    ) throws -> Bool {
        guard let conditionalKeychain = keychain as? any ConditionalGenericPasswordClient else {
            throw KeychainCredentialStoreError.operationFailed
        }
        do {
            return try conditionalKeychain.compareAndSwapGenericPassword(
                data: credential,
                expectedData: expectedCredential,
                service: service,
                account: name
            )
        } catch {
            throw KeychainCredentialStoreError.operationFailed
        }
    }
}

public final class ReadFailureCachingCredentialStore: CredentialStoring, @unchecked Sendable {
    private let wrapped: any CredentialStoring
    private let lock = NSLock()
    private var failedNames: Set<String> = []

    public init(wrapping wrapped: any CredentialStoring) {
        self.wrapped = wrapped
    }

    public func credential(named name: String) throws -> Data? {
        try lock.withLock {
            guard !failedNames.contains(name) else {
                throw KeychainCredentialStoreError.operationFailed
            }
            do {
                return try wrapped.credential(named: name)
            } catch {
                failedNames.insert(name)
                throw KeychainCredentialStoreError.operationFailed
            }
        }
    }

    public func storeCredential(_ credential: Data, named name: String) throws {
        try lock.withLock {
            try wrapped.storeCredential(credential, named: name)
            failedNames.remove(name)
        }
    }

    public func removeCredential(named name: String) throws {
        try lock.withLock {
            try wrapped.removeCredential(named: name)
            failedNames.remove(name)
        }
    }
}

public actor ReadFailureCachingCredentialReader: AsyncCredentialReading {
    private let wrapped: any AsyncCredentialReading
    private var failedNames: Set<String> = []

    public init(wrapping wrapped: any AsyncCredentialReading) {
        self.wrapped = wrapped
    }

    public func credential(named name: String) async throws -> Data? {
        guard !failedNames.contains(name) else {
            throw KeychainCredentialStoreError.operationFailed
        }
        do {
            return try await wrapped.credential(named: name)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failedNames.insert(name)
            throw KeychainCredentialStoreError.operationFailed
        }
    }
}

public struct CodexProfileMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum CodexProfilePreferencesError: Error, Equatable, LocalizedError {
    case invalidProfileMetadata

    public var errorDescription: String? {
        "Profile metadata is invalid."
    }
}

public protocol CodexProfilePreferencesStoring: AnyObject {
    func saveProfiles(_ profiles: [CodexProfileMetadata]) throws
    func profiles() throws -> [CodexProfileMetadata]
    var activeProfileID: String? { get set }
}

public final class CodexProfilePreferences: CodexProfilePreferencesStoring {
    private let defaults: UserDefaults
    private static let profilesKey = "codex.profileMetadata"
    private static let activeProfileIDKey = "codex.activeProfileID"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func saveProfiles(_ profiles: [CodexProfileMetadata]) throws {
        do {
            let data = try JSONEncoder().encode(profiles)
            defaults.set(data, forKey: Self.profilesKey)
        } catch {
            throw CodexProfilePreferencesError.invalidProfileMetadata
        }
    }

    public func profiles() throws -> [CodexProfileMetadata] {
        guard let data = defaults.data(forKey: Self.profilesKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([CodexProfileMetadata].self, from: data)
        } catch {
            throw CodexProfilePreferencesError.invalidProfileMetadata
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
