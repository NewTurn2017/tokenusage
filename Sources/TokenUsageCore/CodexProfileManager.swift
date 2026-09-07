import Darwin
import Foundation

public enum CodexProfileManagerError: Error, Equatable, Sendable, LocalizedError {
    case invalidProfileName
    case invalidProfileID
    case currentAccountMissing
    case profileNotFound
    case credentialMissing
    case loginFailed
    case loginFailedWithStatus(Int32)
    case loginBrowserOpenFailed
    case accountValidationFailed
    case accountIdentityMismatch
    case concurrentModification
    case defaultHomeVerificationFailed
    case rollbackFailed
    case storageFailed
    case temporaryDirectoryFailed
    case unsafeProfileHome
    case profileCredentialConflict

    public var errorDescription: String? {
        switch self {
        case .invalidProfileName:
            "The profile name is empty."
        case .invalidProfileID:
            "The Codex profile identifier is invalid."
        case .currentAccountMissing:
            "The current Codex account is unavailable."
        case .profileNotFound:
            "The Codex profile was not found."
        case .credentialMissing:
            "The Codex profile credential is unavailable."
        case .loginFailed:
            "Codex login failed."
        case let .loginFailedWithStatus(status):
            "Codex login failed with exit status \(status)."
        case .loginBrowserOpenFailed:
            "The Codex sign-in browser could not be opened."
        case .accountValidationFailed:
            "The Codex account could not be validated."
        case .accountIdentityMismatch:
            "The validated Codex account identity does not match the selected profile."
        case .concurrentModification:
            "The current Codex account changed during activation."
        case .defaultHomeVerificationFailed:
            "The activated Codex account could not be verified."
        case .rollbackFailed:
            "The previous Codex account could not be restored."
        case .storageFailed:
            "Codex profile storage failed."
        case .temporaryDirectoryFailed:
            "A private Codex login directory could not be created."
        case .unsafeProfileHome:
            "The Codex profile home is unsafe."
        case .profileCredentialConflict:
            "The Codex profile credential changed before it could be updated."
        }
    }
}

public struct CodexProfileHomeMaterialization: Equatable, Sendable {
    public let homeURL: URL
    public let credentialBaseline: Data

    public init(homeURL: URL, credentialBaseline: Data) {
        self.homeURL = homeURL
        self.credentialBaseline = credentialBaseline
    }
}

private final class StagedProfileHome {
    private var directoryFD: Int32
    private let rootURL: URL
    private let originalName: String
    private let tombstoneName: String
    private let device: dev_t
    private let inode: ino_t

    init(
        directoryFD: Int32,
        rootURL: URL,
        originalName: String,
        tombstoneName: String,
        device: dev_t,
        inode: ino_t
    ) {
        self.directoryFD = directoryFD
        self.rootURL = rootURL
        self.originalName = originalName
        self.tombstoneName = tombstoneName
        self.device = device
        self.inode = inode
    }

    func remove() throws {
        try validateRootAndTombstone()
        try FileManager.default.removeItem(
            at: rootURL.appendingPathComponent(tombstoneName, isDirectory: true)
        )
    }

    func restore() throws {
        guard directoryFD >= 0 else { throw CodexProfileManagerError.rollbackFailed }
        try validateRootAndTombstone()
        var originalInfo = stat()
        guard fstatat(directoryFD, originalName, &originalInfo, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT,
              renameat(directoryFD, tombstoneName, directoryFD, originalName) == 0 else {
            throw CodexProfileManagerError.rollbackFailed
        }
    }

    func close() {
        if directoryFD >= 0 {
            Darwin.close(directoryFD)
            directoryFD = -1
        }
    }

    private func validateRootAndTombstone() throws {
        guard directoryFD >= 0 else { throw CodexProfileManagerError.rollbackFailed }
        var openedRoot = stat()
        var pathRoot = stat()
        var tombstone = stat()
        guard fstat(directoryFD, &openedRoot) == 0,
              lstat(rootURL.path, &pathRoot) == 0,
              openedRoot.st_dev == pathRoot.st_dev,
              openedRoot.st_ino == pathRoot.st_ino,
              fstatat(directoryFD, tombstoneName, &tombstone, AT_SYMLINK_NOFOLLOW) == 0,
              tombstone.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              tombstone.st_dev == device,
              tombstone.st_ino == inode else {
            throw CodexProfileManagerError.rollbackFailed
        }
    }
}

public actor CodexProfileManager {
    private let credentialStore: any CredentialStoring
    private let preferences: any CodexProfilePreferencesStoring
    private let authFileOperator: any AuthFileOperating
    private let validateAccount: @Sendable (URL) async throws -> CodexAccount
    private let loginRunner: any CodexLoginRunning
    private let defaultCodexHome: URL
    private let applicationSupportRoot: URL
    private let temporaryDirectory: URL
    private let makeProfileAuthFileOperator: @Sendable (URL) -> any AuthFileOperating
    private let profileID: @Sendable () -> String

    public init<Validator: CodexAccountValidating>(
        credentialStore: any CredentialStoring,
        preferences: any CodexProfilePreferencesStoring,
        authFileOperator: any AuthFileOperating,
        accountValidator: Validator,
        loginRunner: any CodexLoginRunning,
        defaultCodexHome: URL,
        applicationSupportRoot: URL? = nil,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        profileAuthFileOperator: (@Sendable (URL) -> any AuthFileOperating)? = nil,
        profileID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) where Validator.Account == CodexAccount {
        self.credentialStore = credentialStore
        self.preferences = preferences
        self.authFileOperator = authFileOperator
        validateAccount = { home in
            try await accountValidator.validate(codexHome: home)
        }
        self.loginRunner = loginRunner
        self.defaultCodexHome = defaultCodexHome.standardizedFileURL
        self.applicationSupportRoot = (
            applicationSupportRoot ?? Self.defaultApplicationSupportRoot()
        ).standardizedFileURL
        self.temporaryDirectory = temporaryDirectory
        makeProfileAuthFileOperator = profileAuthFileOperator ?? {
            AtomicAuthFileOperator(authFileURL: $0)
        }
        self.profileID = profileID
    }

    public func saveCurrent(named requestedName: String = "codex2") async throws -> CodexProfileMetadata {
        let name = try validatedName(requestedName)
        let original: Data
        do {
            guard let data = try authFileOperator.readAuthFile() else {
                throw CodexProfileManagerError.currentAccountMissing
            }
            original = data
        } catch let error as CodexProfileManagerError {
            throw error
        } catch {
            throw CodexProfileManagerError.storageFailed
        }

        do {
            _ = try await validateAccount(defaultCodexHome)
        } catch {
            throw CodexProfileManagerError.accountValidationFailed
        }

        do {
            guard try authFileOperator.readAuthFile() == original else {
                throw CodexProfileManagerError.concurrentModification
            }
        } catch let error as CodexProfileManagerError {
            throw error
        } catch {
            throw CodexProfileManagerError.storageFailed
        }

        let profile = CodexProfileMetadata(id: profileID(), name: name)
        try persist(profile: profile, credential: original, makeActive: true)
        return profile
    }

    public func addAccount(named requestedName: String) async throws -> CodexProfileMetadata? {
        let name = try validatedName(requestedName)
        let isolatedHome = try makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: isolatedHome) }

        let outcome: CodexLoginOutcome
        do {
            outcome = try await loginRunner.runCodexLogin(codexHome: isolatedHome)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexProfileManagerError.loginFailed
        }
        switch outcome {
        case .completed:
            break
        case .cancelled:
            return nil
        case .browserOpenFailed:
            throw CodexProfileManagerError.loginBrowserOpenFailed
        case let .failed(status, _):
            throw CodexProfileManagerError.loginFailedWithStatus(status)
        }

        let credential: Data
        do {
            credential = try Data(contentsOf: isolatedHome.appendingPathComponent("auth.json"))
        } catch {
            throw CodexProfileManagerError.currentAccountMissing
        }

        do {
            _ = try await validateAccount(isolatedHome)
        } catch {
            throw CodexProfileManagerError.accountValidationFailed
        }

        let profile = CodexProfileMetadata(id: profileID(), name: name)
        try persist(profile: profile, credential: credential, makeActive: false)
        return profile
    }

    public func listProfiles() throws -> [CodexProfileMetadata] {
        do {
            return try preferences.profiles()
        } catch {
            throw CodexProfileManagerError.storageFailed
        }
    }

    public func activeProfileID() -> String? {
        preferences.activeProfileID
    }

    public func materializeProfileHome(id: String) throws -> CodexProfileHomeMaterialization {
        let credential: Data
        do {
            guard let stored = try credentialStore.credential(named: id) else {
                throw CodexProfileManagerError.credentialMissing
            }
            credential = stored
        } catch let error as CodexProfileManagerError {
            throw error
        } catch {
            throw CodexProfileManagerError.storageFailed
        }

        let homeURL = try profileHomeURL(id: id)
        let authURL = homeURL.appendingPathComponent("auth.json")
        let homeExisted = try itemExists(at: homeURL)
        do {
            try ensureAppOwnedProfileDirectories(homeURL: homeURL)
            try rejectSymlink(at: authURL)
            let authOperator = makeProfileAuthFileOperator(authURL)
            let mirrored = try authOperator.readAuthFile()
            if mirrored != credential {
                try authOperator.replaceAuthFile(with: credential, ifCurrentMatches: mirrored)
            }
            guard chmod(authURL.path, mode_t(0o600)) == 0 else {
                throw CodexProfileManagerError.storageFailed
            }
        } catch let error as CodexProfileManagerError {
            if !homeExisted {
                try? FileManager.default.removeItem(at: homeURL)
            }
            throw error
        } catch {
            if !homeExisted {
                try? FileManager.default.removeItem(at: homeURL)
            }
            throw CodexProfileManagerError.storageFailed
        }
        return CodexProfileHomeMaterialization(
            homeURL: homeURL,
            credentialBaseline: credential
        )
    }

    public func writeBackProfileCredential(id: String, baseline: Data) throws {
        let homeURL = try profileHomeURL(id: id)
        let authURL = homeURL.appendingPathComponent("auth.json")
        do {
            try rejectSymlink(at: homeURL)
            try rejectSymlink(at: authURL)
            let mirrored = try Data(contentsOf: authURL)
            guard mirrored != baseline else { return }
            guard let conditionalStore = credentialStore as? any ConditionalCredentialStoring else {
                throw CodexProfileManagerError.storageFailed
            }
            guard try conditionalStore.storeCredential(
                mirrored,
                named: id,
                ifCurrentMatches: baseline
            ) else {
                throw CodexProfileManagerError.profileCredentialConflict
            }
        } catch let error as CodexProfileManagerError {
            throw error
        } catch {
            throw CodexProfileManagerError.storageFailed
        }
    }

    public func removeProfile(id: String) throws {
        let profiles: [CodexProfileMetadata]
        let activeProfileID: String?
        do {
            profiles = try preferences.profiles()
            activeProfileID = preferences.activeProfileID
        } catch {
            throw CodexProfileManagerError.storageFailed
        }
        guard profiles.contains(where: { $0.id == id }) else {
            throw CodexProfileManagerError.profileNotFound
        }
        let credential: Data?
        do {
            credential = try credentialStore.credential(named: id)
        } catch {
            throw CodexProfileManagerError.storageFailed
        }

        let stagedHome: StagedProfileHome?
        do {
            stagedHome = try stageProfileHomeIfPresent(id: id)
        } catch {
            throw CodexProfileManagerError.storageFailed
        }
        defer { stagedHome?.close() }

        var credentialRemoved = false
        var metadataChanged = false
        var activeIDChanged = false
        do {
            try credentialStore.removeCredential(named: id)
            credentialRemoved = true
            try preferences.saveProfiles(profiles.filter { $0.id != id })
            metadataChanged = true
            if activeProfileID == id {
                preferences.activeProfileID = nil
                activeIDChanged = true
            }
            try stagedHome?.remove()
        } catch {
            var rollbackSucceeded = true
            if credentialRemoved, let credential {
                do {
                    try credentialStore.storeCredential(credential, named: id)
                } catch {
                    rollbackSucceeded = false
                }
            }
            if metadataChanged {
                do {
                    try preferences.saveProfiles(profiles)
                } catch {
                    rollbackSucceeded = false
                }
            }
            if activeIDChanged {
                preferences.activeProfileID = activeProfileID
            }
            do {
                try stagedHome?.restore()
            } catch {
                rollbackSucceeded = false
            }
            throw rollbackSucceeded
                ? CodexProfileManagerError.storageFailed
                : CodexProfileManagerError.rollbackFailed
        }
    }

    public func activateProfile(id: String) async throws {
        let profiles: [CodexProfileMetadata]
        do {
            profiles = try preferences.profiles()
        } catch {
            throw CodexProfileManagerError.storageFailed
        }
        guard profiles.contains(where: { $0.id == id }) else {
            throw CodexProfileManagerError.profileNotFound
        }

        var candidate = try materializeProfileHome(id: id).credentialBaseline

        let original: Data?
        do {
            original = try authFileOperator.readAuthFile()
        } catch {
            throw CodexProfileManagerError.storageFailed
        }
        let isolatedHome = try makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: isolatedHome) }
        let candidateAccount: CodexAccount
        do {
            let isolatedOperator = AtomicAuthFileOperator(
                authFileURL: isolatedHome.appendingPathComponent("auth.json")
            )
            try isolatedOperator.replaceAuthFile(with: candidate, ifCurrentMatches: nil)
            candidateAccount = try await validateAccount(isolatedHome)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let original,
                  Self.accountID(in: candidate) == Self.accountID(in: original),
                  Self.accountID(in: candidate) != nil else {
                throw CodexProfileManagerError.accountValidationFailed
            }
            do {
                candidateAccount = try await validateAccount(defaultCodexHome)
                guard let conditionalStore = credentialStore as? any ConditionalCredentialStoring else {
                    throw CodexProfileManagerError.storageFailed
                }
                guard try conditionalStore.storeCredential(
                    original,
                    named: id,
                    ifCurrentMatches: candidate
                ) else {
                    throw CodexProfileManagerError.profileCredentialConflict
                }
                candidate = original
                _ = try materializeProfileHome(id: id)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CodexProfileManagerError {
                throw error
            } catch {
                throw CodexProfileManagerError.accountValidationFailed
            }
        }

        try Task.checkCancellation()
        let installedByActivation = original != candidate
        do {
            try authFileOperator.replaceAuthFile(with: candidate, ifCurrentMatches: original)
        } catch AtomicAuthFileError.conflict {
            throw CodexProfileManagerError.concurrentModification
        } catch {
            throw CodexProfileManagerError.storageFailed
        }

        do {
            try Task.checkCancellation()
            try verifyInstalledCredential(candidate)

            let defaultAccount: CodexAccount
            do {
                defaultAccount = try await validateAccount(defaultCodexHome)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CodexProfileManagerError.defaultHomeVerificationFailed
            }
            guard accountsMatch(candidateAccount, defaultAccount) else {
                throw CodexProfileManagerError.accountIdentityMismatch
            }

            try Task.checkCancellation()
            try verifyInstalledCredential(candidate)
        } catch {
            guard installedByActivation else { throw error }
            try rollbackAfterActivationFailure(
                to: original,
                replacing: candidate,
                underlying: error
            )
        }

        preferences.activeProfileID = id
    }

    private static func accountID(in credential: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: credential) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accountID = tokens["account_id"] as? String,
              !accountID.isEmpty else {
            return nil
        }
        return accountID
    }

    private func accountsMatch(_ candidate: CodexAccount, _ installed: CodexAccount) -> Bool {
        guard candidate.type == installed.type else { return false }
        if let candidateEmail = candidate.email, let installedEmail = installed.email,
           candidateEmail != installedEmail {
            return false
        }
        if let candidatePlan = candidate.planType, let installedPlan = installed.planType,
           candidatePlan != installedPlan {
            return false
        }
        return true
    }

    private func verifyInstalledCredential(_ expected: Data) throws {
        do {
            guard try authFileOperator.readAuthFile() == expected else {
                throw CodexProfileManagerError.concurrentModification
            }
        } catch let error as CodexProfileManagerError {
            throw error
        } catch {
            throw CodexProfileManagerError.defaultHomeVerificationFailed
        }
    }

    private func validatedName(_ requestedName: String) throws -> String {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CodexProfileManagerError.invalidProfileName }
        return name
    }

    private static func defaultApplicationSupportRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private func profileHomeURL(id: String) throws -> URL {
        guard !id.isEmpty,
              id.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 90)
                      || (byte >= 97 && byte <= 122)
                      || byte == 45
                      || byte == 95
              }) else {
            throw CodexProfileManagerError.invalidProfileID
        }
        return profileHomesRoot
            .appendingPathComponent(id, isDirectory: true)
    }

    private var profileHomesRoot: URL {
        applicationSupportRoot
            .appendingPathComponent("TokenUsage", isDirectory: true)
            .appendingPathComponent("CodexProfiles", isDirectory: true)
    }

    private func ensureAppOwnedProfileDirectories(homeURL: URL) throws {
        try FileManager.default.createDirectory(
            at: applicationSupportRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try ensureDirectory(at: applicationSupportRoot, permissions: 0o700)
        try ensureDirectory(
            at: applicationSupportRoot.appendingPathComponent("TokenUsage", isDirectory: true),
            permissions: 0o700
        )
        try ensureDirectory(at: profileHomesRoot, permissions: 0o700)
        try ensureDirectory(at: homeURL, permissions: 0o700)
    }

    private func ensureDirectory(at url: URL, permissions: mode_t) throws {
        try rejectSymlink(at: url)
        if !(try itemExists(at: url)) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: permissions)]
            )
        }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              chmod(url.path, permissions) == 0 else {
            throw CodexProfileManagerError.unsafeProfileHome
        }
    }

    private func stageProfileHomeIfPresent(id: String) throws -> StagedProfileHome? {
        let homeURL = try profileHomeURL(id: id)
        guard try itemExists(at: homeURL) else { return nil }
        try rejectSymlink(at: applicationSupportRoot)
        try rejectSymlink(
            at: applicationSupportRoot.appendingPathComponent("TokenUsage", isDirectory: true)
        )
        try rejectSymlink(at: profileHomesRoot)
        try rejectSymlink(at: homeURL)
        var info = stat()
        guard lstat(homeURL.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw CodexProfileManagerError.unsafeProfileHome
        }
        let authURL = homeURL.appendingPathComponent("auth.json")
        try rejectSymlink(at: authURL)

        let directoryFD = open(profileHomesRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw CodexProfileManagerError.unsafeProfileHome }
        let tombstoneName = ".deleting-\(id)-\(UUID().uuidString)"
        guard renameat(directoryFD, id, directoryFD, tombstoneName) == 0 else {
            close(directoryFD)
            throw CodexProfileManagerError.storageFailed
        }
        var stagedInfo = stat()
        guard fstatat(directoryFD, tombstoneName, &stagedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              stagedInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            let restored = renameat(directoryFD, tombstoneName, directoryFD, id) == 0
            close(directoryFD)
            throw restored
                ? CodexProfileManagerError.unsafeProfileHome
                : CodexProfileManagerError.rollbackFailed
        }
        return StagedProfileHome(
            directoryFD: directoryFD,
            rootURL: profileHomesRoot,
            originalName: id,
            tombstoneName: tombstoneName,
            device: stagedInfo.st_dev,
            inode: stagedInfo.st_ino
        )
    }

    private func rejectSymlink(at url: URL) throws {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result == 0 {
            guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                throw CodexProfileManagerError.unsafeProfileHome
            }
        } else if errno != ENOENT {
            throw CodexProfileManagerError.storageFailed
        }
    }

    private func itemExists(at url: URL) throws -> Bool {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result == 0 { return true }
        guard errno == ENOENT else { throw CodexProfileManagerError.storageFailed }
        return false
    }

    private func persist(
        profile: CodexProfileMetadata,
        credential: Data,
        makeActive: Bool
    ) throws {
        let profiles: [CodexProfileMetadata]
        do {
            profiles = try preferences.profiles()
            try credentialStore.storeCredential(credential, named: profile.id)
            do {
                try preferences.saveProfiles(profiles + [profile])
            } catch {
                try? credentialStore.removeCredential(named: profile.id)
                throw error
            }
        } catch {
            throw CodexProfileManagerError.storageFailed
        }
        if makeActive {
            preferences.activeProfileID = profile.id
        }
    }

    private func makeTemporaryCodexHome() throws -> URL {
        let home = temporaryDirectory
            .appendingPathComponent("tokenusage-codex-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: home,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(home.path, mode_t(0o700)) == 0 else {
                throw CodexProfileManagerError.temporaryDirectoryFailed
            }
            return home
        } catch let error as CodexProfileManagerError {
            try? FileManager.default.removeItem(at: home)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: home)
            throw CodexProfileManagerError.temporaryDirectoryFailed
        }
    }

    private func rollbackAfterActivationFailure(
        to original: Data?,
        replacing installed: Data,
        underlying: any Error
    ) throws -> Never {
        do {
            try authFileOperator.restoreAuthFile(
                to: original,
                ifCurrentMatches: installed
            )
        } catch AtomicAuthFileError.conflict {
            throw CodexProfileManagerError.concurrentModification
        } catch {
            throw CodexProfileManagerError.rollbackFailed
        }
        throw underlying
    }
}
