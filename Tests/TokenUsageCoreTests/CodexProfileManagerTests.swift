import Darwin
import Foundation
import XCTest
@testable import TokenUsageCore

final class CodexProfileManagerTests: XCTestCase {
    func testSaveCurrentDefaultsToCodex2AndAllowsAnEditedName() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let current = codex2Auth(token: "current")
        try fixture.writeDefaultAuth(current)
        let validator = RecordingValidator()
        let manager = fixture.manager(validator: validator)

        let saved = try await manager.saveCurrent()
        let renamed = try await manager.saveCurrent(named: "Work")

        XCTAssertEqual(saved.name, "codex2")
        XCTAssertEqual(renamed.name, "Work")
        XCTAssertEqual(try fixture.credentials.credential(named: saved.id), current)
        XCTAssertEqual(try fixture.credentials.credential(named: renamed.id), current)
        let names = try await manager.listProfiles().map(\.name)
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(names, ["codex2", "Work"])
        XCTAssertEqual(activeProfileID, renamed.id)
    }

    func testSwitchValidatesInIsolationThenDefaultHomeAndRetainsPreviousProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = codex2Auth(token: "previous")
        let next = codex2Auth(token: "next")
        try fixture.writeDefaultAuth(previous)
        let previousProfile = try fixture.seedProfile(name: "Previous", credential: previous)
        let nextProfile = try fixture.seedProfile(name: "Next", credential: next)
        fixture.preferences.activeProfileID = previousProfile.id
        let validator = RecordingValidator { _, _ in
            XCTAssertEqual(fixture.preferences.activeProfileID, previousProfile.id)
            return testAccount
        }
        let manager = fixture.manager(validator: validator)

        try await manager.activateProfile(id: nextProfile.id)

        let profiles = try await manager.listProfiles()
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), next)
        XCTAssertEqual(permissions(at: fixture.defaultAuthURL), 0o600)
        XCTAssertEqual(profiles, [previousProfile, nextProfile])
        XCTAssertEqual(try fixture.credentials.credential(named: previousProfile.id), previous)
        XCTAssertEqual(activeProfileID, nextProfile.id)
        let homes = validator.validatedHomes
        XCTAssertEqual(homes.count, 2)
        XCTAssertNotEqual(homes[0], fixture.defaultHome)
        XCTAssertEqual(homes[1], fixture.defaultHome)
        XCTAssertFalse(FileManager.default.fileExists(atPath: homes[0].path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.profileHomesRoot
                .appendingPathComponent(nextProfile.id)
                .appendingPathComponent("auth.json")),
            next
        )
    }

    func testSameByteActivationStillValidatesCandidateAndDefaultIdentityBeforeActiveID() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = codex2Auth(token: "same-byte")
        try fixture.writeDefaultAuth(bytes)
        let previous = try fixture.seedProfile(name: "Previous", credential: bytes)
        let selected = try fixture.seedProfile(name: "Selected", credential: bytes)
        fixture.preferences.activeProfileID = previous.id
        let validator = RecordingValidator { _, _ in
            XCTAssertEqual(fixture.preferences.activeProfileID, previous.id)
            return testAccount
        }
        let manager = fixture.manager(validator: validator)

        try await manager.activateProfile(id: selected.id)

        XCTAssertEqual(validator.validatedHomes.count, 2)
        XCTAssertEqual(validator.validatedHomes.last, fixture.defaultHome)
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, selected.id)
        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), bytes)
    }

    func testDefaultIdentityMismatchRollsBackAndPreservesActiveProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "identity-original")
        let candidate = codex2Auth(token: "identity-candidate")
        try fixture.writeDefaultAuth(original)
        let previous = try fixture.seedProfile(name: "Previous", credential: original)
        let selected = try fixture.seedProfile(name: "Selected", credential: candidate)
        fixture.preferences.activeProfileID = previous.id
        let validator = RecordingValidator { home, _ in
            home == fixture.defaultHome
                ? CodexAccount(type: "chatgpt", email: "other@example.test", planType: "team")
                : CodexAccount(type: "chatgpt", email: "selected@example.test", planType: "team")
        }
        let manager = fixture.manager(validator: validator)

        await XCTAssertThrowsErrorAsync(try await manager.activateProfile(id: selected.id)) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .accountIdentityMismatch)
            XCTAssertFalse(error.localizedDescription.contains("selected@example.test"))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), original)
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, previous.id)
    }

    func testIdentityRequiresTypeAndOnlyComparesOptionalFieldsWhenBothArePresent() async throws {
        struct Scenario {
            let candidate: CodexAccount
            let installed: CodexAccount
            let expectedError: CodexProfileManagerError?
        }
        let scenarios = [
            Scenario(
                candidate: CodexAccount(type: "chatgpt", email: nil, planType: "plus"),
                installed: CodexAccount(
                    type: "chatgpt",
                    email: "available@example.test",
                    planType: "plus"
                ),
                expectedError: nil
            ),
            Scenario(
                candidate: CodexAccount(type: "chatgpt", planType: "plus"),
                installed: CodexAccount(type: "api", planType: "plus"),
                expectedError: .accountIdentityMismatch
            ),
            Scenario(
                candidate: CodexAccount(type: "chatgpt", planType: "plus"),
                installed: CodexAccount(type: "chatgpt", planType: "team"),
                expectedError: .accountIdentityMismatch
            ),
        ]

        for scenario in scenarios {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let original = codex2Auth(token: "optional-original")
            let candidate = codex2Auth(token: "optional-candidate")
            try fixture.writeDefaultAuth(original)
            let previous = try fixture.seedProfile(name: "Previous", credential: original)
            let selected = try fixture.seedProfile(name: "Selected", credential: candidate)
            fixture.preferences.activeProfileID = previous.id
            let validator = RecordingValidator { home, _ in
                home == fixture.defaultHome ? scenario.installed : scenario.candidate
            }
            let manager = fixture.manager(validator: validator)

            if let expectedError = scenario.expectedError {
                await XCTAssertThrowsErrorAsync(
                    try await manager.activateProfile(id: selected.id)
                ) { error in
                    XCTAssertEqual(error as? CodexProfileManagerError, expectedError)
                }
                XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), original)
                let activeProfileID = await manager.activeProfileID()
                XCTAssertEqual(activeProfileID, previous.id)
            } else {
                try await manager.activateProfile(id: selected.id)
                XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), candidate)
                let activeProfileID = await manager.activeProfileID()
                XCTAssertEqual(activeProfileID, selected.id)
            }
        }
    }

    func testActivationMissingCredentialPreservesDefaultAndActiveProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "missing-original")
        try fixture.writeDefaultAuth(original)
        let previous = try fixture.seedProfile(name: "Previous", credential: original)
        let missing = try fixture.seedProfile(name: "Missing", credential: codex2Auth(token: "gone"))
        try fixture.credentials.removeCredential(named: missing.id)
        fixture.preferences.activeProfileID = previous.id
        let manager = fixture.manager(validator: RecordingValidator())

        await XCTAssertThrowsErrorAsync(try await manager.activateProfile(id: missing.id)) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .credentialMissing)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), original)
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, previous.id)
    }

    func testRollbackIOFailureIsTypedAndDoesNotChangeActiveProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "rollback-io-original")
        let candidate = codex2Auth(token: "rollback-io-candidate")
        let previous = try fixture.seedProfile(name: "Previous", credential: original)
        let selected = try fixture.seedProfile(name: "Selected", credential: candidate)
        fixture.preferences.activeProfileID = previous.id
        let authOperator = RollbackFailingAuthFileOperator(original: original)
        let validator = RecordingValidator { home, _ in
            if home == fixture.defaultHome { throw TestFailure.rejected }
            return testAccount
        }
        let manager = fixture.manager(validator: validator, authOperator: authOperator)

        await XCTAssertThrowsErrorAsync(try await manager.activateProfile(id: selected.id)) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .rollbackFailed)
        }

        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, previous.id)
        XCTAssertEqual(authOperator.currentData, candidate)
    }

    func testCancellationAtIsolatedValidationPreservesDefaultAndActiveProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "cancel-isolated-original")
        try fixture.writeDefaultAuth(original)
        let previous = try fixture.seedProfile(name: "Previous", credential: original)
        let selected = try fixture.seedProfile(name: "Selected", credential: codex2Auth(token: "cancel-isolated-selected"))
        fixture.preferences.activeProfileID = previous.id
        let validator = RecordingValidator { home, _ in
            if home != fixture.defaultHome { throw CancellationError() }
            return testAccount
        }
        let manager = fixture.manager(validator: validator)

        await XCTAssertThrowsErrorAsync(try await manager.activateProfile(id: selected.id)) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), original)
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, previous.id)
        XCTAssertTrue(try fixture.temporaryChildren().isEmpty)
    }

    func testCancellationAfterInstallRollsBackAndPreservesActiveProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "cancel-post-original")
        let candidate = codex2Auth(token: "cancel-post-selected")
        let previous = try fixture.seedProfile(name: "Previous", credential: original)
        let selected = try fixture.seedProfile(name: "Selected", credential: candidate)
        fixture.preferences.activeProfileID = previous.id
        let authOperator = CancelAfterReplaceAuthFileOperator(original: original)
        let manager = fixture.manager(validator: RecordingValidator(), authOperator: authOperator)

        let result = await Task { () -> (any Error)? in
            do { try await manager.activateProfile(id: selected.id); return nil }
            catch { return error }
        }.value

        XCTAssertTrue(result is CancellationError)
        XCTAssertEqual(authOperator.currentData, original)
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, previous.id)
    }

    func testCancellationAtDefaultValidationRollsBackAndPreservesActiveProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "cancel-default-original")
        let candidate = codex2Auth(token: "cancel-default-selected")
        try fixture.writeDefaultAuth(original)
        let previous = try fixture.seedProfile(name: "Previous", credential: original)
        let selected = try fixture.seedProfile(name: "Selected", credential: candidate)
        fixture.preferences.activeProfileID = previous.id
        let validator = RecordingValidator { home, _ in
            if home == fixture.defaultHome { throw CancellationError() }
            return testAccount
        }
        let manager = fixture.manager(validator: validator)

        await XCTAssertThrowsErrorAsync(try await manager.activateProfile(id: selected.id)) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), original)
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, previous.id)
        XCTAssertTrue(try fixture.temporaryChildren().isEmpty)
    }

    func testMalformedAndExpiredAccountsAreRejectedBeforeKeychainImport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let malformed = Data("not-json".utf8)
        let expired = codex2Auth(token: "expired")
        let validator = RecordingValidator { _, data in
            guard data != malformed, data != expired else { throw TestFailure.rejected }
            return testAccount
        }
        let login = RecordingLogin { home, invocation in
            try (invocation == 1 ? malformed : expired).write(
                to: home.appendingPathComponent("auth.json")
            )
            return .completed(terminationStatus: 0, diagnostic: emptyLoginDiagnostic)
        }
        let manager = fixture.manager(validator: validator, login: login)

        for name in ["Malformed", "Expired"] {
            await XCTAssertThrowsErrorAsync(try await manager.addAccount(named: name)) { error in
                XCTAssertEqual(error as? CodexProfileManagerError, .accountValidationFailed)
            }
        }

        let profiles = try await manager.listProfiles()
        XCTAssertEqual(profiles, [])
        XCTAssertEqual(fixture.credentials.storedNames, [])
        XCTAssertTrue(try fixture.temporaryChildren().isEmpty)
    }

    func testPreSwitchValidatorFailureLeavesCurrentProfileUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "original")
        try fixture.writeDefaultAuth(original)
        let target = try fixture.seedProfile(
            name: "Target",
            credential: codex2Auth(token: "target", accountID: "different-account")
        )
        let validator = RecordingValidator { home, _ in
            if home != fixture.defaultHome { throw TestFailure.rejected }
            return testAccount
        }
        let manager = fixture.manager(validator: validator)

        await XCTAssertThrowsErrorAsync(try await manager.activateProfile(id: target.id)) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .accountValidationFailed)
        }

        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), original)
        XCTAssertNil(activeProfileID)
        XCTAssertTrue(try fixture.temporaryChildren().isEmpty)
    }

    func testActivationRepairsRevokedProfileFromMatchingCurrentAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let current = codex2Auth(token: "current-valid")
        try fixture.writeDefaultAuth(current)
        let target = try fixture.seedProfile(name: "Target", credential: codex2Auth(token: "revoked"))
        let validator = RecordingValidator { home, data in
            if home == fixture.defaultHome {
                return testAccount
            }
            guard data == current else { throw TestFailure.rejected }
            return testAccount
        }
        let manager = fixture.manager(validator: validator)

        try await manager.activateProfile(id: target.id)

        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(try fixture.credentials.credential(named: target.id), current)
        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), current)
        XCTAssertEqual(activeProfileID, target.id)
    }

    func testHashOrMtimeConflictAbortsWithoutOverwritingConcurrentMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "original")
        try fixture.writeDefaultAuth(original)
        let target = try fixture.seedProfile(name: "Target", credential: codex2Auth(token: "target"))
        let validator = RecordingValidator { home, _ in
            if home != fixture.defaultHome {
                XCTAssertEqual(chmod(fixture.defaultAuthURL.path, 0o640), 0)
            }
            return testAccount
        }
        let manager = fixture.manager(validator: validator)

        await XCTAssertThrowsErrorAsync(try await manager.activateProfile(id: target.id)) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .concurrentModification)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), original)
        XCTAssertEqual(permissions(at: fixture.defaultAuthURL), 0o640)
    }

    func testPostWriteConcurrentMismatchIsPreserved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data([0x00, 0xff, 0x41, 0x10])
        let targetData = codex2Auth(token: "target")
        let target = try fixture.seedProfile(name: "Target", credential: targetData)
        let authOperator = MismatchingAuthFileOperator(original: original)
        let manager = fixture.manager(
            validator: RecordingValidator(),
            authOperator: authOperator
        )

        await XCTAssertThrowsErrorAsync(try await manager.activateProfile(id: target.id)) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .concurrentModification)
        }

        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(authOperator.currentData, Data("post-write-mismatch".utf8))
        XCTAssertNil(authOperator.restoredBytes)
        XCTAssertNil(activeProfileID)
    }

    func testRollbackUsesCandidateCASAndPreservesConcurrentExternalChange() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "original")
        let candidate = codex2Auth(token: "candidate")
        let external = codex2Auth(token: "external")
        try fixture.writeDefaultAuth(original)
        let target = try fixture.seedProfile(name: "Target", credential: candidate)
        let validator = RecordingValidator { home, _ in
            if home == fixture.defaultHome {
                try external.write(to: fixture.defaultAuthURL, options: .atomic)
                throw TestFailure.rejected
            }
            return testAccount
        }
        let manager = fixture.manager(validator: validator)

        await XCTAssertThrowsErrorAsync(try await manager.activateProfile(id: target.id)) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .concurrentModification)
        }

        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), external)
        XCTAssertNil(activeProfileID)
    }

    func testDefaultHomeValidatorFailureRollsBackBytesAndDoesNotExposeTokens() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "original")
        let secret = ["sentinel", "secret"].joined(separator: "-")
        try fixture.writeDefaultAuth(original)
        let target = try fixture.seedProfile(name: "Target", credential: codex2Auth(token: secret))
        let validator = RecordingValidator { home, _ in
            if home == fixture.defaultHome { throw SecretFailure(value: secret) }
            return testAccount
        }
        let manager = fixture.manager(validator: validator)

        await XCTAssertThrowsErrorAsync(try await manager.activateProfile(id: target.id)) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .defaultHomeVerificationFailed)
            XCTAssertFalse(error.localizedDescription.contains(secret))
            XCTAssertFalse(String(describing: error).contains(secret))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), original)
        XCTAssertEqual(permissions(at: fixture.defaultAuthURL), 0o600)
    }

    func testAddAccountUsesPrivateTemporaryHomeImportsAfterValidationAndCleansUp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let existing = codex2Auth(token: "running-account")
        let added = codex2Auth(token: "added-account")
        try fixture.writeDefaultAuth(existing)
        let login = RecordingLogin { home, _ in
            XCTAssertEqual(permissions(at: home), 0o700)
            try added.write(to: home.appendingPathComponent("auth.json"))
            return .completed(terminationStatus: 0, diagnostic: emptyLoginDiagnostic)
        }
        let validator = RecordingValidator()
        let manager = fixture.manager(validator: validator, login: login)

        let addedProfile = try await manager.addAccount(named: "Added")
        let profile = try XCTUnwrap(addedProfile)

        XCTAssertEqual(profile.name, "Added")
        XCTAssertEqual(try fixture.credentials.credential(named: profile.id), added)
        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), existing)
        XCTAssertEqual(login.homes.count, 1)
        XCTAssertEqual(validator.validatedHomes, login.homes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: login.homes[0].path))
        XCTAssertTrue(try fixture.temporaryChildren().isEmpty)
    }

    func testCancelledLoginImportsNothingAndDeletesTemporaryHome() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let login = RecordingLogin {
            _, _ in .cancelled(terminationStatus: SIGTERM, diagnostic: emptyLoginDiagnostic)
        }
        let validator = RecordingValidator()
        let manager = fixture.manager(validator: validator, login: login)

        let result = try await manager.addAccount(named: "Cancelled")

        let profiles = try await manager.listProfiles()
        XCTAssertNil(result)
        XCTAssertEqual(profiles, [])
        XCTAssertEqual(fixture.credentials.storedNames, [])
        XCTAssertEqual(validator.validatedHomes, [])
        XCTAssertEqual(login.homes.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: login.homes[0].path))
        XCTAssertTrue(try fixture.temporaryChildren().isEmpty)
    }

    func testTypedLoginFailuresThrowAndImportNothing() async throws {
        let secret = "sentinel-login-secret"
        let outcomes: [CodexLoginOutcome] = [
            .failed(
                terminationStatus: 7,
                diagnostic: CodexLoginDiagnostic(stdout: "", stderr: secret)
            ),
            .browserOpenFailed(
                terminationStatus: SIGTERM,
                diagnostic: CodexLoginDiagnostic(stdout: "", stderr: "browser unavailable")
            ),
        ]

        for (index, outcome) in outcomes.enumerated() {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let login = RecordingLogin { _, _ in outcome }
            let validator = RecordingValidator()
            let manager = fixture.manager(validator: validator, login: login)

            await XCTAssertThrowsErrorAsync(
                try await manager.addAccount(named: "Failure \(index)")
            ) { error in
                if index == 0 {
                    XCTAssertTrue(error.localizedDescription.contains("7"))
                } else {
                    XCTAssertTrue(error.localizedDescription.lowercased().contains("browser"))
                }
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }

            let profiles = try await manager.listProfiles()
            XCTAssertEqual(profiles, [])
            XCTAssertEqual(fixture.credentials.storedNames, [])
            XCTAssertEqual(validator.validatedHomes, [])
            XCTAssertEqual(login.homes.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: login.homes[0].path))
            XCTAssertTrue(try fixture.temporaryChildren().isEmpty)
        }
    }

    func testListAndRemoveDeleteVaultItemWithoutChangingRunningCodexAuth() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let running = codex2Auth(token: "running")
        try fixture.writeDefaultAuth(running)
        let first = try fixture.seedProfile(name: "First", credential: codex2Auth(token: "first"))
        let second = try fixture.seedProfile(name: "Second", credential: codex2Auth(token: "second"))
        fixture.preferences.activeProfileID = first.id
        let manager = fixture.manager(validator: RecordingValidator())

        try await manager.removeProfile(id: first.id)

        let profiles = try await manager.listProfiles()
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(profiles, [second])
        XCTAssertNil(try fixture.credentials.credential(named: first.id))
        XCTAssertNotNil(try fixture.credentials.credential(named: second.id))
        XCTAssertNil(activeProfileID)
        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), running)
    }

    func testExistingSaveListAndRemoveBehaviorRemainsStable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let current = codex2Auth(token: "characterization")
        try fixture.writeDefaultAuth(current)
        let manager = fixture.manager(validator: RecordingValidator())

        let saved = try await manager.saveCurrent(named: "Characterized")
        let profilesAfterSave = try await manager.listProfiles()
        let activeAfterSave = await manager.activeProfileID()
        XCTAssertEqual(profilesAfterSave, [saved])
        XCTAssertEqual(activeAfterSave, saved.id)
        XCTAssertEqual(try fixture.credentials.credential(named: saved.id), current)

        try await manager.removeProfile(id: saved.id)

        let profilesAfterRemove = try await manager.listProfiles()
        let activeAfterRemove = await manager.activeProfileID()
        XCTAssertEqual(profilesAfterRemove, [])
        XCTAssertNil(activeAfterRemove)
        XCTAssertNil(try fixture.credentials.credential(named: saved.id))
        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), current)
    }

    func testMaterializedHomeWritesProviderRotationBackWithMatchingBaselineCAS() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "materialized")
        let rotated = codex2Auth(token: "rotated")
        let profile = try fixture.seedProfile(name: "Materialized", credential: original)
        let manager = fixture.manager(validator: RecordingValidator())

        let materialized = try await manager.materializeProfileHome(id: profile.id)

        XCTAssertEqual(
            materialized.homeURL,
            fixture.applicationSupportRoot
                .appendingPathComponent("TokenUsage/CodexProfiles/\(profile.id)", isDirectory: true)
        )
        XCTAssertEqual(materialized.credentialBaseline, original)
        XCTAssertEqual(
            try Data(contentsOf: materialized.homeURL.appendingPathComponent("auth.json")),
            original
        )

        try rotated.write(
            to: materialized.homeURL.appendingPathComponent("auth.json"),
            options: .atomic
        )
        try await manager.writeBackProfileCredential(
            id: profile.id,
            baseline: materialized.credentialBaseline
        )

        XCTAssertEqual(try fixture.credentials.credential(named: profile.id), rotated)
    }

    func testMaterializationIsPrivateIdempotentAndRefreshesChangedKeychainBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "first")
        let refreshed = codex2Auth(token: "refreshed")
        let defaultBytes = codex2Auth(token: "default-untouched")
        try fixture.writeDefaultAuth(defaultBytes)
        let profile = try fixture.seedProfile(name: "Private", credential: original)
        let manager = fixture.manager(validator: RecordingValidator())

        let first = try await manager.materializeProfileHome(id: profile.id)
        let authURL = first.homeURL.appendingPathComponent("auth.json")
        let firstInode = inode(at: authURL)
        let repeated = try await manager.materializeProfileHome(id: profile.id)

        XCTAssertEqual(repeated, first)
        XCTAssertEqual(permissions(at: first.homeURL), 0o700)
        XCTAssertEqual(permissions(at: authURL), 0o600)
        XCTAssertEqual(inode(at: authURL), firstInode)

        try fixture.credentials.storeCredential(refreshed, named: profile.id)
        let changed = try await manager.materializeProfileHome(id: profile.id)

        XCTAssertEqual(changed.credentialBaseline, refreshed)
        XCTAssertEqual(try Data(contentsOf: authURL), refreshed)
        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), defaultBytes)
    }

    func testMaterializationWithMissingCredentialCreatesNoHome() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = fixture.manager(validator: RecordingValidator())

        await XCTAssertThrowsErrorAsync(
            try await manager.materializeProfileHome(id: "profile-missing")
        ) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .credentialMissing)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.profileHomesRoot.path))
    }

    func testMaterializationRejectsTraversalSeparatorsAbsoluteAndNonASCIIIDs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = fixture.manager(validator: RecordingValidator())
        let invalidIDs = ["../escape", "nested/profile", "nested\\profile", "/absolute", ".", "..", "profile id", "프로필"]

        for id in invalidIDs {
            try fixture.credentials.storeCredential(codex2Auth(token: "unsafe"), named: id)
            await XCTAssertThrowsErrorAsync(
                try await manager.materializeProfileHome(id: id)
            ) { error in
                XCTAssertEqual(error as? CodexProfileManagerError, .invalidProfileID)
            }
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.applicationSupportRoot.appendingPathComponent("escape").path
            )
        )
    }

    func testMaterializationRefusesSymlinkedHomeAndAuthFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let homeLinked = try fixture.seedProfile(
            name: "Home link",
            credential: codex2Auth(token: "home-link")
        )
        let authLinked = try fixture.seedProfile(
            name: "Auth link",
            credential: codex2Auth(token: "auth-link")
        )
        let manager = fixture.manager(validator: RecordingValidator())
        try FileManager.default.createDirectory(
            at: fixture.profileHomesRoot,
            withIntermediateDirectories: true
        )

        let externalHome = fixture.root.appendingPathComponent("external-home", isDirectory: true)
        try FileManager.default.createDirectory(at: externalHome, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: fixture.profileHomesRoot.appendingPathComponent(homeLinked.id),
            withDestinationURL: externalHome
        )

        await XCTAssertThrowsErrorAsync(
            try await manager.materializeProfileHome(id: homeLinked.id)
        ) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .unsafeProfileHome)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: externalHome.appendingPathComponent("auth.json").path
            )
        )

        let authLinkedHome = fixture.profileHomesRoot.appendingPathComponent(authLinked.id)
        try FileManager.default.createDirectory(at: authLinkedHome, withIntermediateDirectories: false)
        let externalAuth = fixture.root.appendingPathComponent("external-auth.json")
        let externalBytes = codex2Auth(token: "external")
        try externalBytes.write(to: externalAuth)
        try FileManager.default.createSymbolicLink(
            at: authLinkedHome.appendingPathComponent("auth.json"),
            withDestinationURL: externalAuth
        )

        await XCTAssertThrowsErrorAsync(
            try await manager.materializeProfileHome(id: authLinked.id)
        ) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .unsafeProfileHome)
        }
        XCTAssertEqual(try Data(contentsOf: externalAuth), externalBytes)
    }

    func testWriteBackConflictPreservesNewerKeychainCredential() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let baseline = codex2Auth(token: "baseline")
        let providerRotation = codex2Auth(token: "provider-rotation")
        let newerKeychain = codex2Auth(token: "newer-keychain")
        let profile = try fixture.seedProfile(name: "Conflict", credential: baseline)
        let manager = fixture.manager(validator: RecordingValidator())
        let materialized = try await manager.materializeProfileHome(id: profile.id)
        try providerRotation.write(
            to: materialized.homeURL.appendingPathComponent("auth.json"),
            options: .atomic
        )
        try fixture.credentials.storeCredential(newerKeychain, named: profile.id)

        await XCTAssertThrowsErrorAsync(
            try await manager.writeBackProfileCredential(
                id: profile.id,
                baseline: materialized.credentialBaseline
            )
        ) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .profileCredentialConflict)
        }

        XCTAssertEqual(try fixture.credentials.credential(named: profile.id), newerKeychain)
    }

    func testWriteBackRaceBetweenCompareAndStorePreservesNewerKeychainCredential() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let baseline = codex2Auth(token: "race-baseline")
        let providerRotation = codex2Auth(token: "race-provider")
        let newerKeychain = codex2Auth(token: "race-newer-keychain")
        let profile = try fixture.seedProfile(name: "CAS race", credential: baseline)
        let manager = fixture.manager(validator: RecordingValidator())
        let materialized = try await manager.materializeProfileHome(id: profile.id)
        try providerRotation.write(
            to: materialized.homeURL.appendingPathComponent("auth.json"),
            options: .atomic
        )
        fixture.credentials.simulateConcurrentChangeOnNextWriteBack(
            named: profile.id,
            credential: newerKeychain
        )

        await XCTAssertThrowsErrorAsync(
            try await manager.writeBackProfileCredential(
                id: profile.id,
                baseline: materialized.credentialBaseline
            )
        ) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .profileCredentialConflict)
        }

        XCTAssertEqual(try fixture.credentials.credential(named: profile.id), newerKeychain)
    }

    func testConcurrentSameProfileMaterializationReturnsOneConsistentHome() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let credential = codex2Auth(token: "concurrent")
        let profile = try fixture.seedProfile(name: "Concurrent", credential: credential)
        let manager = fixture.manager(validator: RecordingValidator())

        async let first = manager.materializeProfileHome(id: profile.id)
        async let second = manager.materializeProfileHome(id: profile.id)
        let (firstResult, secondResult) = try await (first, second)

        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(
            try Data(contentsOf: firstResult.homeURL.appendingPathComponent("auth.json")),
            credential
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.profileHomesRoot.path), [profile.id])
    }

    func testInjectedAtomicWriteFailurePreservesPreviousMirrorAndLeavesNoNewPartialHome() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = codex2Auth(token: "original-mirror")
        let replacement = codex2Auth(token: "replacement")
        let existing = try fixture.seedProfile(name: "Existing", credential: original)
        let fresh = try fixture.seedProfile(name: "Fresh", credential: replacement)
        let normalManager = fixture.manager(validator: RecordingValidator())
        let existingHome = try await normalManager.materializeProfileHome(id: existing.id).homeURL
        let existingAuth = existingHome.appendingPathComponent("auth.json")
        try fixture.credentials.storeCredential(replacement, named: existing.id)
        let failingManager = fixture.manager(
            validator: RecordingValidator(),
            profileAuthFileOperator: { FailingProfileAuthFileOperator(authFileURL: $0) }
        )

        for profile in [existing, fresh] {
            await XCTAssertThrowsErrorAsync(
                try await failingManager.materializeProfileHome(id: profile.id)
            ) { error in
                XCTAssertEqual(error as? CodexProfileManagerError, .storageFailed)
            }
        }

        XCTAssertEqual(try Data(contentsOf: existingAuth), original)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.profileHomesRoot.appendingPathComponent(fresh.id).path
            )
        )
    }

    func testRemoveProfileDeletesOnlyItsValidatedAppOwnedHome() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profile = try fixture.seedProfile(
            name: "Delete",
            credential: codex2Auth(token: "delete")
        )
        let manager = fixture.manager(validator: RecordingValidator())
        let home = try await manager.materializeProfileHome(id: profile.id).homeURL
        let unrelated = fixture.applicationSupportRoot.appendingPathComponent("Unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let marker = unrelated.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)

        try await manager.removeProfile(id: profile.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        XCTAssertNil(try fixture.credentials.credential(named: profile.id))
        let remainingProfiles = try await manager.listProfiles()
        XCTAssertEqual(remainingProfiles, [])
    }

    func testRemoveProfileWhenCredentialRemovalFailsLeavesHomeCredentialMetadataAndActiveIDUnchanged() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let credential = codex2Auth(token: "removal-failure")
        let defaultBytes = codex2Auth(token: "default-removal-failure")
        try fixture.writeDefaultAuth(defaultBytes)
        let profile = try fixture.seedProfile(name: "Removal failure", credential: credential)
        fixture.preferences.activeProfileID = profile.id
        let manager = fixture.manager(validator: RecordingValidator())
        let home = try await manager.materializeProfileHome(id: profile.id).homeURL
        fixture.credentials.failNextRemoval(named: profile.id)

        await XCTAssertThrowsErrorAsync(
            try await manager.removeProfile(id: profile.id)
        ) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .storageFailed)
            XCTAssertFalse(error.localizedDescription.contains("removal-failure"))
        }

        XCTAssertEqual(
            try Data(contentsOf: home.appendingPathComponent("auth.json")),
            credential
        )
        XCTAssertEqual(try fixture.credentials.credential(named: profile.id), credential)
        let profiles = try await manager.listProfiles()
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(profiles, [profile])
        XCTAssertEqual(activeProfileID, profile.id)
        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), defaultBytes)
    }

    func testRemoveProfileWhenSavingMetadataFailsRestoresCredentialHomeAndActiveID() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let selectedCredential = codex2Auth(token: "metadata-failure-selected")
        let survivorCredential = codex2Auth(token: "metadata-failure-survivor")
        let defaultBytes = codex2Auth(token: "default-metadata-failure")
        try fixture.writeDefaultAuth(defaultBytes)
        let selected = try fixture.seedProfile(
            name: "Selected",
            credential: selectedCredential
        )
        let survivor = try fixture.seedProfile(
            name: "Survivor",
            credential: survivorCredential
        )
        fixture.preferences.activeProfileID = selected.id
        let manager = fixture.manager(validator: RecordingValidator())
        let home = try await manager.materializeProfileHome(id: selected.id).homeURL
        fixture.preferences.failNextSave()

        await XCTAssertThrowsErrorAsync(
            try await manager.removeProfile(id: selected.id)
        ) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .storageFailed)
            XCTAssertFalse(error.localizedDescription.contains("metadata-failure"))
        }

        XCTAssertEqual(
            try Data(contentsOf: home.appendingPathComponent("auth.json")),
            selectedCredential
        )
        XCTAssertEqual(
            try fixture.credentials.credential(named: selected.id),
            selectedCredential
        )
        XCTAssertEqual(
            try fixture.credentials.credential(named: survivor.id),
            survivorCredential
        )
        let profiles = try await manager.listProfiles()
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(profiles, [selected, survivor])
        XCTAssertEqual(activeProfileID, selected.id)
        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), defaultBytes)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.profileHomesRoot.path),
            [selected.id]
        )
    }

    func testRemoveProfileWhenCompensationFailsReturnsRollbackFailedAndContinuesRestoringState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let credential = codex2Auth(token: "rollback-failure")
        let defaultBytes = codex2Auth(token: "default-rollback-failure")
        try fixture.writeDefaultAuth(defaultBytes)
        let profile = try fixture.seedProfile(name: "Rollback failure", credential: credential)
        fixture.preferences.activeProfileID = profile.id
        let manager = fixture.manager(validator: RecordingValidator())
        let home = try await manager.materializeProfileHome(id: profile.id).homeURL
        fixture.preferences.failNextSave()
        fixture.credentials.failNextStore(named: profile.id)

        await XCTAssertThrowsErrorAsync(
            try await manager.removeProfile(id: profile.id)
        ) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .rollbackFailed)
            XCTAssertFalse(error.localizedDescription.contains("rollback-failure"))
        }

        XCTAssertEqual(
            try Data(contentsOf: home.appendingPathComponent("auth.json")),
            credential
        )
        XCTAssertNil(try fixture.credentials.credential(named: profile.id))
        let profiles = try await manager.listProfiles()
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(profiles, [profile])
        XCTAssertEqual(activeProfileID, profile.id)
        XCTAssertEqual(try Data(contentsOf: fixture.defaultAuthURL), defaultBytes)
    }

    func testRemoveProfileRefusesSymlinkedAuthAndPreservesProfileAndExternalFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let credential = codex2Auth(token: "delete-symlink")
        let profile = try fixture.seedProfile(name: "Unsafe delete", credential: credential)
        let manager = fixture.manager(validator: RecordingValidator())
        let home = try await manager.materializeProfileHome(id: profile.id).homeURL
        let authURL = home.appendingPathComponent("auth.json")
        let external = fixture.root.appendingPathComponent("external-delete-auth.json")
        let externalBytes = codex2Auth(token: "external-delete")
        try externalBytes.write(to: external)
        try FileManager.default.removeItem(at: authURL)
        try FileManager.default.createSymbolicLink(at: authURL, withDestinationURL: external)

        await XCTAssertThrowsErrorAsync(
            try await manager.removeProfile(id: profile.id)
        ) { error in
            XCTAssertEqual(error as? CodexProfileManagerError, .storageFailed)
        }

        XCTAssertEqual(try Data(contentsOf: external), externalBytes)
        XCTAssertEqual(try fixture.credentials.credential(named: profile.id), credential)
        let remainingProfiles = try await manager.listProfiles()
        XCTAssertEqual(remainingProfiles, [profile])
    }

}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let defaultHome: URL
    let defaultAuthURL: URL
    let temporaryRoot: URL
    let applicationSupportRoot: URL
    var profileHomesRoot: URL {
        applicationSupportRoot.appendingPathComponent("TokenUsage/CodexProfiles", isDirectory: true)
    }
    let credentials = InMemoryCredentialStore()
    let preferences: FaultInjectingProfilePreferences
    private var nextID = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexProfileManagerTests-\(UUID().uuidString)", isDirectory: true)
        defaultHome = root.appendingPathComponent("default", isDirectory: true)
        defaultAuthURL = defaultHome.appendingPathComponent("auth.json")
        temporaryRoot = root.appendingPathComponent("temporary", isDirectory: true)
        applicationSupportRoot = root.appendingPathComponent("application-support", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let suite = "CodexProfileManagerTests.\(UUID().uuidString)"
        preferences = FaultInjectingProfilePreferences(
            wrapping: CodexProfilePreferences(
                defaults: try XCTUnwrap(UserDefaults(suiteName: suite))
            )
        )
    }

    func manager(
        validator: RecordingValidator,
        login: RecordingLogin = RecordingLogin(),
        authOperator: (any AuthFileOperating)? = nil,
        profileAuthFileOperator: (@Sendable (URL) -> any AuthFileOperating)? = nil
    ) -> CodexProfileManager {
        CodexProfileManager(
            credentialStore: credentials,
            preferences: preferences,
            authFileOperator: authOperator ?? AtomicAuthFileOperator(authFileURL: defaultAuthURL),
            accountValidator: validator,
            loginRunner: login,
            defaultCodexHome: defaultHome,
            applicationSupportRoot: applicationSupportRoot,
            temporaryDirectory: temporaryRoot,
            profileAuthFileOperator: profileAuthFileOperator,
            profileID: { [weak self] in self?.makeID() ?? UUID().uuidString }
        )
    }

    func seedProfile(name: String, credential: Data) throws -> CodexProfileMetadata {
        let profile = CodexProfileMetadata(id: makeID(), name: name)
        try credentials.storeCredential(credential, named: profile.id)
        var profiles = try preferences.profiles()
        profiles.append(profile)
        try preferences.saveProfiles(profiles)
        return profile
    }

    func writeDefaultAuth(_ data: Data) throws {
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
        try data.write(to: defaultAuthURL)
        XCTAssertEqual(chmod(defaultAuthURL.path, 0o600), 0)
    }

    func temporaryChildren() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeID() -> String {
        nextID += 1
        return "profile-\(nextID)"
    }
}

private final class FaultInjectingProfilePreferences: CodexProfilePreferencesStoring {
    private let wrapped: CodexProfilePreferences
    private let lock = NSLock()
    private var shouldFailNextSave = false

    init(wrapping wrapped: CodexProfilePreferences) {
        self.wrapped = wrapped
    }

    func saveProfiles(_ profiles: [CodexProfileMetadata]) throws {
        let shouldFail = lock.withLock {
            defer { shouldFailNextSave = false }
            return shouldFailNextSave
        }
        if shouldFail { throw TestFailure.rejected }
        try wrapped.saveProfiles(profiles)
    }

    func profiles() throws -> [CodexProfileMetadata] {
        try wrapped.profiles()
    }

    var activeProfileID: String? {
        get { wrapped.activeProfileID }
        set { wrapped.activeProfileID = newValue }
    }

    func failNextSave() {
        lock.withLock { shouldFailNextSave = true }
    }
}

private let testAccount = CodexAccount(
    type: "chatgpt",
    email: "fixture@example.test",
    planType: "plus"
)

private final class RecordingValidator: CodexAccountValidating, @unchecked Sendable {
    typealias Account = CodexAccount
    private let lock = NSLock()
    private var homes: [URL] = []
    private let result: @Sendable (URL, Data) throws -> CodexAccount

    init(result: @escaping @Sendable (URL, Data) throws -> CodexAccount = { _, _ in testAccount }) {
        self.result = result
    }

    var validatedHomes: [URL] { lock.withLock { homes } }

    func validate(codexHome: URL) async throws -> CodexAccount {
        let data = try Data(contentsOf: codexHome.appendingPathComponent("auth.json"))
        lock.withLock { homes.append(codexHome) }
        return try result(codexHome, data)
    }
}

private final class RollbackFailingAuthFileOperator: AuthFileOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    init(original: Data) { data = original }
    var currentData: Data? { lock.withLock { data } }

    func readAuthFile() throws -> Data? { lock.withLock { data } }
    func replaceAuthFile(with data: Data, ifCurrentMatches expectedData: Data?) throws {
        try lock.withLock {
            guard self.data == expectedData else { throw AtomicAuthFileError.conflict }
            self.data = data
        }
    }
    func restoreAuthFile(to data: Data?, ifCurrentMatches expectedData: Data?) throws {
        throw AtomicAuthFileError.ioFailed
    }
}

private final class CancelAfterReplaceAuthFileOperator: AuthFileOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    init(original: Data) { data = original }
    var currentData: Data? { lock.withLock { data } }

    func readAuthFile() throws -> Data? { lock.withLock { data } }
    func replaceAuthFile(with data: Data, ifCurrentMatches expectedData: Data?) throws {
        try lock.withLock {
            guard self.data == expectedData else { throw AtomicAuthFileError.conflict }
            self.data = data
        }
        withUnsafeCurrentTask { $0?.cancel() }
    }
    func restoreAuthFile(to data: Data?, ifCurrentMatches expectedData: Data?) throws {
        try lock.withLock {
            guard self.data == expectedData else { throw AtomicAuthFileError.conflict }
            self.data = data
        }
    }
}

private final class RecordingLogin: CodexLoginRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedHomes: [URL] = []
    private var invocation = 0
    private let result: @Sendable (URL, Int) throws -> CodexLoginOutcome

    init(result: @escaping @Sendable (URL, Int) throws -> CodexLoginOutcome = {
        _, _ in .cancelled(terminationStatus: SIGTERM, diagnostic: emptyLoginDiagnostic)
    }) {
        self.result = result
    }

    var homes: [URL] { lock.withLock { recordedHomes } }

    func runCodexLogin(codexHome: URL) async throws -> CodexLoginOutcome {
        let current = lock.withLock {
            invocation += 1
            recordedHomes.append(codexHome)
            return invocation
        }
        return try result(codexHome, current)
    }
}

private let emptyLoginDiagnostic = CodexLoginDiagnostic(stdout: "", stderr: "")

private final class InMemoryCredentialStore: ConditionalCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var concurrentChanges: [String: Data] = [:]
    private var failingRemovals: Set<String> = []
    private var failingStores: Set<String> = []

    var storedNames: [String] { lock.withLock { items.keys.sorted() } }

    func credential(named name: String) throws -> Data? {
        lock.withLock {
            let current = items[name]
            if let concurrent = concurrentChanges.removeValue(forKey: name) {
                items[name] = concurrent
            }
            return current
        }
    }

    func storeCredential(_ credential: Data, named name: String) throws {
        try lock.withLock {
            if failingStores.remove(name) != nil {
                throw TestFailure.rejected
            }
            items[name] = credential
        }
    }

    func removeCredential(named name: String) throws {
        try lock.withLock {
            if failingRemovals.remove(name) != nil {
                throw TestFailure.rejected
            }
            items.removeValue(forKey: name)
        }
    }

    func storeCredential(
        _ credential: Data,
        named name: String,
        ifCurrentMatches expectedCredential: Data
    ) throws -> Bool {
        lock.withLock {
            if let concurrent = concurrentChanges.removeValue(forKey: name) {
                items[name] = concurrent
            }
            guard items[name] == expectedCredential else { return false }
            items[name] = credential
            return true
        }
    }

    func simulateConcurrentChangeOnNextWriteBack(named name: String, credential: Data) {
        lock.withLock { concurrentChanges[name] = credential }
    }

    func failNextRemoval(named name: String) {
        _ = lock.withLock { failingRemovals.insert(name) }
    }

    func failNextStore(named name: String) {
        _ = lock.withLock { failingStores.insert(name) }
    }
}

private final class MismatchingAuthFileOperator: AuthFileOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var mismatchAfterReplace = false
    private(set) var restoredBytes: Data?

    init(original: Data) { data = original }

    var currentData: Data? { lock.withLock { data } }

    func readAuthFile() throws -> Data? {
        lock.withLock {
            if mismatchAfterReplace {
                mismatchAfterReplace = false
                data = Data("post-write-mismatch".utf8)
            }
            return data
        }
    }

    func replaceAuthFile(with data: Data, ifCurrentMatches expectedData: Data?) throws {
        try lock.withLock {
            guard self.data == expectedData else { throw AtomicAuthFileError.conflict }
            self.data = data
            mismatchAfterReplace = true
        }
    }

    func restoreAuthFile(to data: Data?, ifCurrentMatches expectedData: Data?) throws {
        try lock.withLock {
            guard self.data == expectedData else { throw AtomicAuthFileError.conflict }
            self.data = data
            restoredBytes = data
        }
    }
}

private final class FailingProfileAuthFileOperator: AuthFileOperating, @unchecked Sendable {
    private let wrapped: AtomicAuthFileOperator

    init(authFileURL: URL) {
        wrapped = AtomicAuthFileOperator(authFileURL: authFileURL)
    }

    func readAuthFile() throws -> Data? {
        try wrapped.readAuthFile()
    }

    func replaceAuthFile(with data: Data, ifCurrentMatches expectedData: Data?) throws {
        throw TestFailure.rejected
    }

    func restoreAuthFile(to data: Data?, ifCurrentMatches expectedData: Data?) throws {
        try wrapped.restoreAuthFile(to: data, ifCurrentMatches: expectedData)
    }
}

private enum TestFailure: Error { case rejected }

private struct SecretFailure: LocalizedError {
    let value: String
    var errorDescription: String? { "validation failed with \(value)" }
}

private func codex2Auth(token: String, accountID: String = "account") -> Data {
    Data("""
    {"auth_mode":"chatgpt","tokens":{"access_token":"\(token)","refresh_token":"refresh-\(token)","account_id":"\(accountID)"},"last_refresh":"2026-08-03T00:00:00Z"}
    """.utf8)
}

private func permissions(at url: URL) -> mode_t {
    var info = stat()
    XCTAssertEqual(lstat(url.path, &info), 0)
    return info.st_mode & mode_t(0o7777)
}

private func inode(at url: URL) -> ino_t {
    var info = stat()
    XCTAssertEqual(lstat(url.path, &info), 0)
    return info.st_ino
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected error")
    } catch {
        errorHandler(error)
    }
}
