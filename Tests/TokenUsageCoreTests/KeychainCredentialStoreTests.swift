import Foundation
import XCTest
@testable import TokenUsageCore

final class KeychainCredentialStoreTests: XCTestCase {
    func testCredentialsRoundTripAsGenericPasswordData() throws {
        let keychain = InMemoryGenericPasswordClient()
        let store = KeychainCredentialStore(
            service: "dev.tokenusage.tests",
            keychain: keychain
        )
        let credential = Data([0x00, 0xff, 0x42, 0x10])

        try store.storeCredential(credential, named: "codex-profile-id")

        XCTAssertEqual(try store.credential(named: "codex-profile-id"), credential)
        XCTAssertEqual(
            keychain.requests,
            [
                .upsert(service: "dev.tokenusage.tests", account: "codex-profile-id", data: credential),
                .copy(service: "dev.tokenusage.tests", account: "codex-profile-id")
            ]
        )
    }

    func testReplacingAndRemovingCredentialUsesSameGenericPasswordItem() throws {
        let keychain = InMemoryGenericPasswordClient()
        let store = KeychainCredentialStore(service: "service", keychain: keychain)

        try store.storeCredential(Data("first".utf8), named: "profile")
        try store.storeCredential(Data("second".utf8), named: "profile")
        try store.removeCredential(named: "profile")

        XCTAssertNil(try store.credential(named: "profile"))
    }

    func testConditionalWriteRejectsInjectedRaceAndPreservesNewerBytes() throws {
        let keychain = InMemoryGenericPasswordClient()
        let store = KeychainCredentialStore(service: "service", keychain: keychain)
        let baseline = Data("baseline".utf8)
        let providerRotation = Data("provider-rotation".utf8)
        let laterRotation = Data("later-rotation".utf8)
        let newer = Data("newer".utf8)
        try store.storeCredential(baseline, named: "profile")

        let firstUpdated = try store.storeCredential(
            providerRotation,
            named: "profile",
            ifCurrentMatches: baseline
        )
        XCTAssertTrue(firstUpdated)
        XCTAssertEqual(try store.credential(named: "profile"), providerRotation)

        keychain.simulateConcurrentChangeBeforeNextCAS(
            data: newer,
            service: "service",
            account: "profile"
        )

        let updated = try store.storeCredential(
            laterRotation,
            named: "profile",
            ifCurrentMatches: providerRotation
        )

        XCTAssertFalse(updated)
        XCTAssertEqual(try store.credential(named: "profile"), newer)
    }

    func testProfilePreferencesPersistOnlyNamesAndActiveIdentifier() throws {
        let suiteName = "KeychainCredentialStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = CodexProfilePreferences(defaults: defaults)
        let profiles = [
            CodexProfileMetadata(id: "profile-1", name: "Personal"),
            CodexProfileMetadata(id: "profile-2", name: "Work")
        ]

        try preferences.saveProfiles(profiles)
        preferences.activeProfileID = "profile-2"

        XCTAssertEqual(try preferences.profiles(), profiles)
        XCTAssertEqual(preferences.activeProfileID, "profile-2")
        let persisted = defaults.dictionaryRepresentation()
        XCTAssertFalse(String(describing: persisted).contains("sentinel-secret"))
        let codexKeys = persisted.keys.filter { $0.hasPrefix("codex.") }
        XCTAssertEqual(Set(codexKeys), ["codex.profileMetadata", "codex.activeProfileID"])
    }

    func testKeychainFailureDoesNotExposeCredentialBytes() {
        let secret = "sentinel-secret"
        let keychain = InMemoryGenericPasswordClient(failure: SecretError(secret: secret))
        let store = KeychainCredentialStore(service: "service", keychain: keychain)

        XCTAssertThrowsError(
            try store.storeCredential(Data(secret.utf8), named: "profile")
        ) { error in
            XCTAssertFalse(error.localizedDescription.contains(secret))
            XCTAssertEqual(error as? KeychainCredentialStoreError, .operationFailed)
        }
    }

    func testReadFailureCacheAvoidsRepeatedKeychainPromptsForLaunchLifetime() {
        let keychain = InMemoryGenericPasswordClient(failure: SecretError(secret: "denied"))
        let store = ReadFailureCachingCredentialStore(
            wrapping: KeychainCredentialStore(service: "service", keychain: keychain)
        )

        XCTAssertThrowsError(try store.credential(named: "claude"))
        XCTAssertThrowsError(try store.credential(named: "claude"))

        XCTAssertEqual(
            keychain.requests,
            [.copy(service: "service", account: "claude")]
        )
    }
}

private struct SecretError: LocalizedError {
    let secret: String
    var errorDescription: String? { "failed with \(secret)" }
}

private final class InMemoryGenericPasswordClient: ConditionalGenericPasswordClient, @unchecked Sendable {
    enum Request: Equatable {
        case copy(service: String, account: String)
        case upsert(service: String, account: String, data: Data)
        case remove(service: String, account: String)
    }

    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var concurrentChanges: [String: Data] = [:]
    private var recordedRequests: [Request] = []
    private let failure: Error?

    init(failure: Error? = nil) {
        self.failure = failure
    }

    var requests: [Request] {
        lock.withLock { recordedRequests }
    }

    func copyGenericPassword(service: String, account: String) throws -> Data? {
        try lock.withLock {
            recordedRequests.append(.copy(service: service, account: account))
            if let failure { throw failure }
            return items[key(service: service, account: account)]
        }
    }

    func upsertGenericPassword(data: Data, service: String, account: String) throws {
        try lock.withLock {
            recordedRequests.append(.upsert(service: service, account: account, data: data))
            if let failure { throw failure }
            items[key(service: service, account: account)] = data
        }
    }

    func removeGenericPassword(service: String, account: String) throws {
        try lock.withLock {
            recordedRequests.append(.remove(service: service, account: account))
            if let failure { throw failure }
            items.removeValue(forKey: key(service: service, account: account))
        }
    }

    func compareAndSwapGenericPassword(
        data: Data,
        expectedData: Data,
        service: String,
        account: String
    ) throws -> Bool {
        try lock.withLock {
            let itemKey = key(service: service, account: account)
            if let concurrent = concurrentChanges.removeValue(forKey: itemKey) {
                items[itemKey] = concurrent
            }
            if let failure { throw failure }
            guard items[itemKey] == expectedData else { return false }
            items[itemKey] = data
            return true
        }
    }

    func simulateConcurrentChangeBeforeNextCAS(
        data: Data,
        service: String,
        account: String
    ) {
        lock.withLock {
            concurrentChanges[key(service: service, account: account)] = data
        }
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{0}\(account)"
    }
}
