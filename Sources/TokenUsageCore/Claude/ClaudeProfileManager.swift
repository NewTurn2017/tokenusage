import Foundation

public enum ClaudeProfileManagerError: Error, Equatable, Sendable, LocalizedError {
    case invalidProfileName
    case currentAccountMissing
    case profileNotFound
    case credentialMissing
    case activeCredentialExpired
    case accountValidationFailed
    case accountIdentityMismatch
    case concurrentModification
    case activationFailed
    case rollbackFailed
    case storageFailed
    case signedOut
    case loginUnavailable
    case loginFailed
    case loginFailedWithStatus(Int32)
    case temporaryDirectoryFailed
    case credentialHeldByAnotherAccount

    public var errorDescription: String? {
        switch self {
        case .invalidProfileName:
            "계정 이름이 비어 있습니다."
        case .currentAccountMissing:
            "현재 로그인된 Claude 계정을 읽지 못했습니다."
        case .profileNotFound:
            "해당 Claude 계정을 찾지 못했습니다."
        case .credentialMissing:
            "저장된 Claude 자격 증명이 없습니다."
        case .activeCredentialExpired:
            "현재 Claude Code 토큰이 만료되었습니다. Claude Code에서 다시 로그인해 주세요."
        case .accountValidationFailed:
            "Claude 계정을 확인하지 못했습니다."
        case .accountIdentityMismatch:
            "전환된 계정이 선택한 계정과 다릅니다."
        case .concurrentModification:
            "전환하는 사이에 Claude Code 계정이 바뀌었습니다."
        case .activationFailed:
            "Claude 계정을 전환하지 못했습니다."
        case .rollbackFailed:
            "이전 Claude 계정을 되돌리지 못했습니다."
        case .storageFailed:
            "Claude 계정 저장소 작업에 실패했습니다."
        case .signedOut:
            "저장된 Claude 계정의 로그인이 만료되었습니다. 다시 로그인해 주세요."
        case .loginUnavailable:
            "claude 실행 파일을 찾지 못해 로그인을 시작할 수 없습니다."
        case .loginFailed:
            "Claude 로그인에 실패했습니다."
        case let .loginFailedWithStatus(status):
            "Claude 로그인이 종료 코드 \(status) 로 실패했습니다."
        case .temporaryDirectoryFailed:
            "로그인용 임시 디렉터리를 만들지 못했습니다."
        case .credentialHeldByAnotherAccount:
            "이 계정에 다른 계정의 토큰이 저장되어 있습니다. 이 계정으로 새 로그인해 주세요."
        }
    }
}

/// Named Claude Code accounts, switched by swapping the account half of the credential blob that
/// Claude Code reads at startup.
///
/// Already-running Claude Code sessions keep the credential they loaded; a switch takes effect for
/// sessions started afterwards - the same contract the Codex profiles have.
public actor ClaudeProfileManager {
    public static let bootstrapProfileName = "claude1"

    private let credentialStore: any CredentialStoring
    private let preferences: any ClaudeProfilePreferencesStoring
    private let liveCredential: any ClaudeLiveCredentialOperating
    private let configOperator: any ClaudeConfigOperating
    private let authStatus: any ClaudeAuthStatusReading
    private let refresher: any ClaudeOAuthRefreshing
    private let loginRunner: (any ClaudeLoginRunning)?
    private let isolatedCredentials: any ClaudeIsolatedCredentialAccessing
    private let temporaryDirectory: URL
    private let profileID: @Sendable () -> String
    private let now: @Sendable () -> Date
    /// Renewed credentials the Keychain refused to take. The renewal already spent the old
    /// refresh token, so dropping the new one would sign the account out on its next renewal;
    /// it is served from here and written again on every later read until the Keychain accepts it.
    private var unsavedCredentials: [String: Data] = [:]

    public init(
        credentialStore: any CredentialStoring,
        preferences: any ClaudeProfilePreferencesStoring,
        liveCredential: any ClaudeLiveCredentialOperating,
        configOperator: any ClaudeConfigOperating,
        authStatus: any ClaudeAuthStatusReading,
        refresher: any ClaudeOAuthRefreshing,
        loginRunner: (any ClaudeLoginRunning)? = nil,
        isolatedCredentials: any ClaudeIsolatedCredentialAccessing =
            SecurityCLIIsolatedClaudeCredentials(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        profileID: @escaping @Sendable () -> String = { UUID().uuidString },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialStore = credentialStore
        self.preferences = preferences
        self.liveCredential = liveCredential
        self.configOperator = configOperator
        self.authStatus = authStatus
        self.refresher = refresher
        self.loginRunner = loginRunner
        self.isolatedCredentials = isolatedCredentials
        self.temporaryDirectory = temporaryDirectory
        self.profileID = profileID
        self.now = now
    }

    // MARK: - Reading

    public func listProfiles() throws -> [ClaudeProfileMetadata] {
        do {
            return try preferences.profiles()
        } catch {
            throw ClaudeProfileManagerError.storageFailed
        }
    }

    public func activeProfileID() -> String? {
        preferences.activeProfileID
    }

    // MARK: - Capturing the signed-in account

    /// Captures whatever Claude Code is signed in as right now. Re-saving the same account
    /// refreshes the existing profile instead of adding a duplicate.
    @discardableResult
    public func saveCurrent(named requestedName: String) async throws -> ClaudeProfileMetadata {
        let name = try validatedName(requestedName)
        let section = try currentOAuthSection()
        guard !(try ClaudeCredentialEnvelope.token(in: section)).isExpired(at: now()) else {
            throw ClaudeProfileManagerError.activeCredentialExpired
        }
        let account = try await validatedCurrentAccount()
        return try persist(
            name: name,
            section: section,
            account: account,
            configAccountJSON: try? configOperator.readAccountJSON(),
            makeActive: true
        )
    }

    /// Signs in to another account in a throwaway configuration directory.
    ///
    /// Claude Code keys both its settings and its Keychain item off that directory, so the
    /// account this app is signed in as is never touched - and the new account is stored without
    /// being activated, exactly like adding a Codex account.
    public func addAccount(named requestedName: String) async throws -> ClaudeProfileMetadata? {
        let name = try validatedName(requestedName)
        guard let loginRunner else { throw ClaudeProfileManagerError.loginUnavailable }

        let configurationDirectory = try makeTemporaryConfigurationDirectory()
        let service = ClaudeKeychainService.service(
            forConfigurationDirectory: configurationDirectory
        )
        defer {
            try? isolatedCredentials.remove(service: service)
            try? FileManager.default.removeItem(at: configurationDirectory)
        }

        let outcome: ClaudeLoginOutcome
        do {
            outcome = try await loginRunner.runClaudeLogin(
                configurationDirectory: configurationDirectory
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClaudeProfileManagerError.loginFailed
        }
        switch outcome {
        case .completed:
            break
        case .cancelled:
            return nil
        case let .failed(status):
            throw ClaudeProfileManagerError.loginFailedWithStatus(status)
        }

        let section = try isolatedOAuthSection(
            service: service,
            configurationDirectory: configurationDirectory
        )
        let account: ClaudeAccount
        do {
            account = try await authStatus.readAuthStatus(
                configurationDirectory: configurationDirectory
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClaudeProfileManagerError.accountValidationFailed
        }

        let configAccountJSON = try? FileClaudeConfigOperator(
            configFileURL: configurationDirectory.appendingPathComponent(".claude.json")
        ).readAccountJSON()
        return try persist(
            name: name,
            section: section,
            account: account,
            configAccountJSON: configAccountJSON,
            makeActive: false
        )
    }

    private func persist(
        name: String,
        section: Data,
        account: ClaudeAccount,
        configAccountJSON: String?,
        makeActive: Bool
    ) throws -> ClaudeProfileMetadata {
        let identity = Self.identity(inConfigAccountJSON: configAccountJSON)
        let email = account.email ?? identity.email
        let profiles = try listProfiles()
        // Re-adding an account the app already knows renames it rather than duplicating it.
        let existing = profiles.first {
            Self.isSameAccount($0, accountUUID: identity.accountUUID, email: email)
        }
        let metadata = ClaudeProfileMetadata(
            id: existing?.id ?? profileID(),
            name: name,
            accountUUID: identity.accountUUID,
            emailAddress: email,
            organizationName: account.organizationName,
            subscriptionType: account.subscriptionType,
            configAccountJSON: configAccountJSON
        )
        do {
            try credentialStore.storeCredential(section, named: metadata.id)
            unsavedCredentials[metadata.id] = nil
            var updated = profiles
            if let index = updated.firstIndex(where: { $0.id == metadata.id }) {
                updated[index] = metadata
            } else {
                updated.append(metadata)
            }
            try preferences.saveProfiles(updated)
        } catch {
            throw ClaudeProfileManagerError.storageFailed
        }
        if makeActive || preferences.activeProfileID == metadata.id {
            preferences.activeProfileID = metadata.id
        }
        return metadata
    }

    /// The sign-in lands in the Keychain; Claude Code falls back to a plaintext file in the same
    /// directory when the Keychain refuses, so both are checked before giving up.
    private func isolatedOAuthSection(
        service: String,
        configurationDirectory: URL
    ) throws -> Data {
        if let envelope = try? isolatedCredentials.readEnvelope(service: service),
           let section = try? ClaudeCredentialEnvelope.oauthSection(from: envelope) {
            return section
        }
        let plaintext = configurationDirectory.appendingPathComponent(".credentials.json")
        guard let envelope = try? Data(contentsOf: plaintext),
              let section = try? ClaudeCredentialEnvelope.oauthSection(from: envelope) else {
            throw ClaudeProfileManagerError.currentAccountMissing
        }
        return section
    }

    private func makeTemporaryConfigurationDirectory() throws -> URL {
        let directory = temporaryDirectory.appendingPathComponent(
            "tokenusage-claude-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ClaudeProfileManagerError.temporaryDirectoryFailed
        }
        return directory.standardizedFileURL
    }

    /// Reconciles the stored accounts with whatever Claude Code is signed in as right now.
    ///
    /// Two things drift without this: Claude Code renews its own token, and the user can sign in
    /// somewhere else entirely with `/login`. Mirroring blindly would then copy one account's
    /// token over another's, so the live account is identified first and only its own profile is
    /// updated.
    public func syncActiveProfile() {
        guard let section = try? currentOAuthSection() else { return }
        let identity = Self.identity(inConfigAccountJSON: try? configOperator.readAccountJSON())
        guard identity.accountUUID != nil || identity.email != nil else { return }

        let profiles = (try? preferences.profiles()) ?? []
        let liveProfile = profiles.first {
            Self.isSameAccount($0, accountUUID: identity.accountUUID, email: identity.email)
        }
        // The config file names the account but the Keychain holds the token, and a Claude Code
        // session still running on an older account can rewrite the config file. When another
        // saved account already holds this very token the two disagree; trusting the file would
        // file one account's token under another, so nothing is changed.
        if let liveProfile,
           let liveRefreshToken = (try? ClaudeCredentialEnvelope.token(in: section))?.refreshToken,
           profile(holdingRefreshToken: liveRefreshToken, besides: liveProfile.id, in: profiles) != nil {
            return
        }
        if preferences.activeProfileID != liveProfile?.id {
            preferences.activeProfileID = liveProfile?.id
        }

        guard let liveProfile,
              (try? credentialStore.credential(named: liveProfile.id)) != section else {
            return
        }
        if (try? credentialStore.storeCredential(section, named: liveProfile.id)) != nil {
            unsavedCredentials[liveProfile.id] = nil
        }
    }

    // MARK: - Usage

    /// An access token usable against the usage API.
    ///
    /// Only inactive accounts are renewed here: Claude Code owns the token of the account it is
    /// signed in as, and a refresh token rotated behind its back would sign it out.
    public func accessToken(for id: String) async throws -> String {
        guard let stored = try storedCredential(id) else {
            throw ClaudeProfileManagerError.credentialMissing
        }
        let token: ClaudeOAuthToken
        do {
            token = try ClaudeCredentialEnvelope.token(in: stored)
        } catch {
            throw ClaudeProfileManagerError.credentialMissing
        }

        if id == preferences.activeProfileID {
            guard !token.isExpired(at: now(), leeway: 0) else {
                throw ClaudeProfileManagerError.activeCredentialExpired
            }
            return token.accessToken
        }
        // A token another saved account also holds was filed here by mistake: it would report the
        // other account's usage, and renewing it would rotate that account's refresh token and
        // sign it out wherever it is in use.
        if let refreshToken = token.refreshToken,
           profile(holdingRefreshToken: refreshToken, besides: id, in: try listProfiles()) != nil {
            throw ClaudeProfileManagerError.credentialHeldByAnotherAccount
        }
        guard token.isExpired(at: now()) else { return token.accessToken }

        let refreshed: ClaudeOAuthToken
        do {
            refreshed = try await refresher.refresh(token)
        } catch ClaudeOAuthRefreshError.rejected {
            throw ClaudeProfileManagerError.signedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClaudeProfileManagerError.accountValidationFailed
        }

        if let updated = try? ClaudeCredentialEnvelope.applying(refreshed, to: stored) {
            do {
                try credentialStore.storeCredential(updated, named: id)
                unsavedCredentials[id] = nil
            } catch {
                unsavedCredentials[id] = updated
            }
        }
        return refreshed.accessToken
    }

    // MARK: - Switching

    public func activateProfile(id: String) async throws {
        let profiles = try listProfiles()
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw ClaudeProfileManagerError.profileNotFound
        }
        syncActiveProfile()
        _ = try await accessToken(for: id)
        guard let candidate = try storedCredential(id) else {
            throw ClaudeProfileManagerError.credentialMissing
        }

        let originalEnvelope = try liveEnvelope()
        let originalSection = try? ClaudeCredentialEnvelope.oauthSection(from: originalEnvelope)
        let originalConfigAccountJSON = try? configOperator.readAccountJSON()

        guard originalSection != candidate else {
            try? configOperator.applyAccountJSON(profile.configAccountJSON)
            preferences.activeProfileID = id
            return
        }

        // Capture whatever the outgoing account looks like now, so switching back later starts
        // from its freshest token rather than the one saved days ago.
        syncActiveProfile()

        let updatedEnvelope: Data
        do {
            updatedEnvelope = try ClaudeCredentialEnvelope.merging(
                oauthSection: candidate,
                into: originalEnvelope
            )
        } catch {
            throw ClaudeProfileManagerError.credentialMissing
        }

        do {
            try liveCredential.replaceEnvelope(
                with: updatedEnvelope,
                ifCurrentMatches: originalEnvelope
            )
        } catch ClaudeLiveCredentialError.conflict {
            throw ClaudeProfileManagerError.concurrentModification
        } catch {
            throw ClaudeProfileManagerError.activationFailed
        }

        do {
            try Task.checkCancellation()
            try configOperator.applyAccountJSON(profile.configAccountJSON)
            let installed = try await validatedCurrentAccount()
            guard Self.accountsMatch(profile: profile, account: installed) else {
                throw ClaudeProfileManagerError.accountIdentityMismatch
            }
        } catch {
            try rollback(
                to: originalEnvelope,
                replacing: updatedEnvelope,
                configAccountJSON: originalConfigAccountJSON,
                underlying: error
            )
        }

        preferences.activeProfileID = id
    }

    public func removeProfile(id: String) throws {
        let profiles = try listProfiles()
        guard profiles.contains(where: { $0.id == id }) else {
            throw ClaudeProfileManagerError.profileNotFound
        }
        do {
            try credentialStore.removeCredential(named: id)
            unsavedCredentials[id] = nil
            try preferences.saveProfiles(profiles.filter { $0.id != id })
        } catch {
            throw ClaudeProfileManagerError.storageFailed
        }
        if preferences.activeProfileID == id {
            preferences.activeProfileID = nil
        }
    }

    // MARK: - Helpers

    private func rollback(
        to originalEnvelope: Data,
        replacing installed: Data,
        configAccountJSON: String?,
        underlying: any Error
    ) throws -> Never {
        do {
            try liveCredential.replaceEnvelope(
                with: originalEnvelope,
                ifCurrentMatches: installed
            )
            try? configOperator.applyAccountJSON(configAccountJSON)
        } catch {
            throw ClaudeProfileManagerError.rollbackFailed
        }
        throw underlying
    }

    private func liveEnvelope() throws -> Data {
        do {
            guard let envelope = try liveCredential.readEnvelope() else {
                throw ClaudeProfileManagerError.currentAccountMissing
            }
            return envelope
        } catch let error as ClaudeProfileManagerError {
            throw error
        } catch {
            throw ClaudeProfileManagerError.currentAccountMissing
        }
    }

    private func currentOAuthSection() throws -> Data {
        do {
            return try ClaudeCredentialEnvelope.oauthSection(from: try liveEnvelope())
        } catch let error as ClaudeProfileManagerError {
            throw error
        } catch {
            throw ClaudeProfileManagerError.currentAccountMissing
        }
    }

    private func profile(
        holdingRefreshToken refreshToken: String,
        besides id: String,
        in profiles: [ClaudeProfileMetadata]
    ) -> ClaudeProfileMetadata? {
        profiles.first { profile in
            guard profile.id != id,
                  let stored = try? storedCredential(profile.id),
                  let token = try? ClaudeCredentialEnvelope.token(in: stored)
            else {
                return false
            }
            return token.refreshToken == refreshToken
        }
    }

    private func storedCredential(_ id: String) throws -> Data? {
        if let unsaved = unsavedCredentials[id] {
            if (try? credentialStore.storeCredential(unsaved, named: id)) != nil {
                unsavedCredentials[id] = nil
            }
            return unsaved
        }
        do {
            return try credentialStore.credential(named: id)
        } catch {
            throw ClaudeProfileManagerError.storageFailed
        }
    }

    private func validatedCurrentAccount() async throws -> ClaudeAccount {
        do {
            return try await authStatus.readAuthStatus(configurationDirectory: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClaudeProfileManagerError.accountValidationFailed
        }
    }

    private func validatedName(_ requestedName: String) throws -> String {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ClaudeProfileManagerError.invalidProfileName }
        return name
    }

    static func identity(
        inConfigAccountJSON json: String?
    ) -> (accountUUID: String?, email: String?) {
        guard let json,
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                  as? [String: Any] else {
            return (nil, nil)
        }
        return (root["accountUuid"] as? String, root["emailAddress"] as? String)
    }

    static func isSameAccount(
        _ profile: ClaudeProfileMetadata,
        accountUUID: String?,
        email: String?
    ) -> Bool {
        if let accountUUID, let existing = profile.accountUUID { return accountUUID == existing }
        if let email, let existing = profile.emailAddress { return email == existing }
        return false
    }

    static func accountsMatch(profile: ClaudeProfileMetadata, account: ClaudeAccount) -> Bool {
        guard let expected = profile.emailAddress, let installed = account.email else {
            // Nothing to compare against; the credential write and its read-back verification
            // already confirmed the switch landed.
            return true
        }
        return expected == installed
    }
}
