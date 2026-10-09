import Foundation
import XCTest
@testable import TokenUsageCore

final class ClaudeProfileManagerTests: XCTestCase {
    func testSaveCurrentStoresOnlyTheAccountSectionAndLeavesMCPTokensAlone() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()

        let saved = try await manager.saveCurrent(named: "personal")

        let stored = try XCTUnwrap(fixture.credentials.credential(named: saved.id))
        let storedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: stored) as? [String: Any]
        )
        XCTAssertEqual(storedRoot["accessToken"] as? String, "personal-token")
        XCTAssertNil(storedRoot["mcpOAuth"], "MCP tokens belong to the machine, not the account")
        XCTAssertEqual(saved.emailAddress, "personal@example.com")
        XCTAssertEqual(saved.name, "personal")
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, saved.id)
    }

    func testSavingTheSameAccountTwiceRenamesItInsteadOfAddingADuplicate() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()

        let first = try await manager.saveCurrent(named: "personal")
        let second = try await manager.saveCurrent(named: "개인")

        let profiles = try await manager.listProfiles()
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(profiles.map(\.name), ["개인"])
    }

    func testActivateSwapsTheAccountSectionAndKeepsEverythingElse() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        let personal = try await manager.saveCurrent(named: "personal")
        let work = try fixture.addStoredProfile(
            name: "work",
            accessToken: "work-token",
            email: "work@example.com"
        )
        fixture.authStatus.setAccount(ClaudeAccount(email: "work@example.com"))

        try await manager.activateProfile(id: work.id)

        let live = try XCTUnwrap(fixture.liveCredential.current)
        let liveRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: live) as? [String: Any])
        let oauth = try XCTUnwrap(liveRoot["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "work-token")
        XCTAssertNotNil(liveRoot["mcpOAuth"], "the MCP tokens must survive an account switch")
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, work.id)
        XCTAssertEqual(
            fixture.configOperator.appliedAccounts.last ?? nil,
            work.configAccountJSON
        )
        XCTAssertNotEqual(personal.id, work.id)
    }

    func testActivateRenewsAnExpiredInactiveAccountBeforeInstallingIt() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = Fixture(liveAccessToken: "personal-token")
        fixture.refresher = FakeClaudeOAuthRefresher(
            replacement: ClaudeOAuthToken(
                accessToken: "work-token-renewed",
                refreshToken: "work-refresh-rotated",
                expiresAt: now.addingTimeInterval(28_800)
            )
        )
        let manager = fixture.manager(now: { now })
        _ = try await manager.saveCurrent(named: "personal")
        let work = try fixture.addStoredProfile(
            name: "work",
            accessToken: "work-token-expired",
            email: "work@example.com",
            expiresAtMilliseconds: 1_699_999_000_000
        )
        fixture.authStatus.setAccount(ClaudeAccount(email: "work@example.com"))

        try await manager.activateProfile(id: work.id)

        let live = try XCTUnwrap(fixture.liveCredential.current)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: live) as? [String: Any])
        let token = try ClaudeCredentialEnvelope.token(
            in: ClaudeCredentialEnvelope.oauthSection(from: live)
        )
        XCTAssertEqual(token.accessToken, "work-token-renewed")
        XCTAssertEqual(fixture.refresher.callCount, 1)
        XCTAssertNotNil(root["mcpOAuth"])
    }

    func testSaveCurrentRejectsExpiredCredentialsBeforeInvokingTheCLI() async throws {
        let fixture = Fixture(
            liveAccessToken: "expired-token",
            expiresAtMilliseconds: 1_699_999_000_000
        )
        let manager = fixture.manager(now: { Date(timeIntervalSince1970: 1_700_000_000) })

        do {
            _ = try await manager.saveCurrent(named: "personal")
            XCTFail("Expired credentials must not be captured as a signed-in account")
        } catch {
            XCTAssertEqual(error as? ClaudeProfileManagerError, .activeCredentialExpired)
        }

        XCTAssertEqual(fixture.authStatus.callCount, 0)
        XCTAssertTrue(try fixture.preferences.profiles().isEmpty)
    }

    func testSaveCurrentAvoidsTheCLIInsideItsTokenRefreshWindow() async throws {
        let fixture = Fixture(
            liveAccessToken: "nearly-expired-token",
            expiresAtMilliseconds: 1_700_000_240_000
        )
        let manager = fixture.manager(now: { Date(timeIntervalSince1970: 1_700_000_000) })

        do {
            _ = try await manager.saveCurrent(named: "personal")
            XCTFail("A short-lived auth check must not start a token refresh")
        } catch {
            XCTAssertEqual(error as? ClaudeProfileManagerError, .activeCredentialExpired)
        }

        XCTAssertEqual(fixture.authStatus.callCount, 0)
    }

    func testActivateKeepsTheOutgoingAccountsFreshestToken() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        let personal = try await manager.saveCurrent(named: "personal")
        let work = try fixture.addStoredProfile(
            name: "work",
            accessToken: "work-token",
            email: "work@example.com"
        )
        fixture.authStatus.setAccount(ClaudeAccount(email: "work@example.com"))
        // Claude Code renewed its own token since the profile was captured.
        try fixture.replaceLive(accessToken: "personal-token-renewed")

        try await manager.activateProfile(id: work.id)

        let storedPersonal = try XCTUnwrap(fixture.credentials.credential(named: personal.id))
        let token = try ClaudeCredentialEnvelope.token(in: storedPersonal)
        XCTAssertEqual(token.accessToken, "personal-token-renewed")
    }

    func testActivateRollsBackWhenTheCLIReportsADifferentAccount() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        _ = try await manager.saveCurrent(named: "personal")
        let originalEnvelope = fixture.liveCredential.current
        let work = try fixture.addStoredProfile(
            name: "work",
            accessToken: "work-token",
            email: "work@example.com"
        )
        fixture.authStatus.setAccount(ClaudeAccount(email: "someone-else@example.com"))

        do {
            try await manager.activateProfile(id: work.id)
            XCTFail("a mismatched identity must not be accepted")
        } catch let error as ClaudeProfileManagerError {
            XCTAssertEqual(error, .accountIdentityMismatch)
        }

        XCTAssertEqual(fixture.liveCredential.current, originalEnvelope)
        XCTAssertEqual(
            fixture.configOperator.appliedAccounts.last ?? nil,
            ClaudeCredentialFixture.configAccount(
                email: "personal@example.com",
                accountUUID: "personal-uuid"
            )
        )
    }

    func testActivateReportsAConcurrentSignInInsteadOfOverwritingIt() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        _ = try await manager.saveCurrent(named: "personal")
        let work = try fixture.addStoredProfile(
            name: "work",
            accessToken: "work-token",
            email: "work@example.com"
        )
        fixture.liveCredential.failNextReplace(with: ClaudeLiveCredentialError.conflict)

        do {
            try await manager.activateProfile(id: work.id)
            XCTFail("a credential that changed underneath must abort the switch")
        } catch let error as ClaudeProfileManagerError {
            XCTAssertEqual(error, .concurrentModification)
        }
    }

    func testAccessTokenRejectsAnExpiredActiveAccountWithoutRenewingIt() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let personal = try await manager.saveCurrent(named: "personal")
        try fixture.credentials.storeCredential(
            ClaudeCredentialFixture.oauthSection(
                accessToken: "personal-token",
                expiresAtMilliseconds: 1_699_999_000_000
            ),
            named: personal.id
        )

        do {
            _ = try await manager.accessToken(for: personal.id)
            XCTFail("An expired active token must not be sent to the API")
        } catch {
            XCTAssertEqual(error as? ClaudeProfileManagerError, .activeCredentialExpired)
        }

        XCTAssertEqual(fixture.refresher.callCount, 0)
    }

    func testAccessTokenReturnsAValidActiveAccountWithoutRenewingIt() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let personal = try await manager.saveCurrent(named: "personal")

        let token = try await manager.accessToken(for: personal.id)

        XCTAssertEqual(token, "personal-token")
        XCTAssertEqual(fixture.refresher.callCount, 0)
    }

    func testAccessTokenRenewsAnExpiredInactiveAccountAndKeepsTheNewToken() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        fixture.refresher = FakeClaudeOAuthRefresher(
            replacement: ClaudeOAuthToken(
                accessToken: "work-token-renewed",
                refreshToken: "work-refresh-rotated",
                expiresAt: Date().addingTimeInterval(28_800)
            )
        )
        let manager = fixture.manager()
        _ = try await manager.saveCurrent(named: "personal")
        let expired = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        let work = try fixture.addStoredProfile(
            name: "work",
            accessToken: "work-token",
            email: "work@example.com",
            expiresAtMilliseconds: expired
        )

        let token = try await manager.accessToken(for: work.id)

        XCTAssertEqual(token, "work-token-renewed")
        XCTAssertEqual(fixture.refresher.callCount, 1)
        let stored = try XCTUnwrap(fixture.credentials.credential(named: work.id))
        let renewed = try ClaudeCredentialEnvelope.token(in: stored)
        XCTAssertEqual(renewed.accessToken, "work-token-renewed")
        XCTAssertEqual(renewed.refreshToken, "work-refresh-rotated")
    }

    func testARenewedTokenTheKeychainRefusesIsKeptAndWrittenLater() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        fixture.refresher = FakeClaudeOAuthRefresher(
            replacement: ClaudeOAuthToken(
                accessToken: "work-token-renewed",
                refreshToken: "work-refresh-rotated",
                expiresAt: Date().addingTimeInterval(28_800)
            )
        )
        let manager = fixture.manager()
        _ = try await manager.saveCurrent(named: "personal")
        let expired = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        let work = try fixture.addStoredProfile(
            name: "work",
            accessToken: "work-token",
            email: "work@example.com",
            expiresAtMilliseconds: expired
        )

        fixture.credentials.setRefusesWrites(true)
        let first = try await manager.accessToken(for: work.id)
        // The rotated refresh token exists only in memory now; it must not be renewed again
        // from the spent one still in the Keychain.
        let second = try await manager.accessToken(for: work.id)

        XCTAssertEqual(first, "work-token-renewed")
        XCTAssertEqual(second, "work-token-renewed")
        XCTAssertEqual(fixture.refresher.callCount, 1)

        fixture.credentials.setRefusesWrites(false)
        _ = try await manager.accessToken(for: work.id)
        let stored = try XCTUnwrap(fixture.credentials.credential(named: work.id))
        XCTAssertEqual(try ClaudeCredentialEnvelope.token(in: stored).refreshToken, "work-refresh-rotated")
    }

    func testAccessTokenReportsASignedOutAccountDistinctly() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        fixture.refresher.setFailure(ClaudeOAuthRefreshError.rejected)
        let manager = fixture.manager()
        _ = try await manager.saveCurrent(named: "personal")
        let expired = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        let work = try fixture.addStoredProfile(
            name: "work",
            accessToken: "work-token",
            email: "work@example.com",
            expiresAtMilliseconds: expired
        )

        do {
            _ = try await manager.accessToken(for: work.id)
            XCTFail("a rejected refresh must surface as a signed-out account")
        } catch let error as ClaudeProfileManagerError {
            XCTAssertEqual(error, .signedOut)
        }
    }

    func testRemoveProfileDropsTheCredentialAndClearsTheActiveSelection() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        let personal = try await manager.saveCurrent(named: "personal")

        try await manager.removeProfile(id: personal.id)

        let profiles = try await manager.listProfiles()
        let activeProfileID = await manager.activeProfileID()
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertNil(activeProfileID)
        XCTAssertTrue(fixture.credentials.storedNames.isEmpty)
    }

    func testAddingAnAccountSignsInWithoutDisturbingTheCurrentOne() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        let personal = try await manager.saveCurrent(named: "personal")
        let liveBefore = fixture.liveCredential.current
        fixture.plantLoginResult(accessToken: "work-token", email: "work@example.com")

        let added = try await manager.addAccount(named: "work")

        let work = try XCTUnwrap(added)
        XCTAssertEqual(work.name, "work")
        XCTAssertEqual(work.emailAddress, "work@example.com")
        XCTAssertEqual(fixture.liveCredential.current, liveBefore, "the signed-in account is untouched")
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, personal.id, "a new account is stored, not activated")
        let stored = try XCTUnwrap(fixture.credentials.credential(named: work.id))
        XCTAssertEqual(try ClaudeCredentialEnvelope.token(in: stored).accessToken, "work-token")
        let profiles = try await manager.listProfiles()
        XCTAssertEqual(profiles.map(\.name), ["personal", "work"])
    }

    func testAddingAnAccountSignsInInsideAThrowawayDirectoryAndLeavesNothingBehind() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        _ = try await manager.saveCurrent(named: "personal")
        fixture.plantLoginResult(accessToken: "work-token", email: "work@example.com")

        _ = try await manager.addAccount(named: "work")

        let directory = try XCTUnwrap(fixture.loginRunner.configurationDirectories.first)
        let expectedService = ClaudeKeychainService.service(forConfigurationDirectory: directory)
        XCTAssertEqual(fixture.isolatedCredentials.removedServices, [expectedService])
        XCTAssertTrue(fixture.isolatedCredentials.remainingServices.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testACancelledSignInAddsNothing() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        fixture.loginRunner = FakeClaudeLoginRunner(outcome: .cancelled)
        let manager = fixture.manager()
        _ = try await manager.saveCurrent(named: "personal")

        let added = try await manager.addAccount(named: "work")

        XCTAssertNil(added)
        let profiles = try await manager.listProfiles()
        XCTAssertEqual(profiles.map(\.name), ["personal"])
    }

    func testAFailedSignInReportsItsExitStatus() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        fixture.loginRunner = FakeClaudeLoginRunner(outcome: .failed(terminationStatus: 7))
        let manager = fixture.manager()

        do {
            _ = try await manager.addAccount(named: "work")
            XCTFail("a failed sign-in must not be reported as success")
        } catch let error as ClaudeProfileManagerError {
            XCTAssertEqual(error, .loginFailedWithStatus(7))
        }
    }

    func testAddingTheAccountAlreadySignedInRenamesItRatherThanDuplicatingIt() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        let personal = try await manager.saveCurrent(named: "personal")
        fixture.plantLoginResult(
            accessToken: "personal-token",
            email: "personal@example.com",
            accountUUID: "personal-uuid"
        )

        let added = try await manager.addAccount(named: "개인")

        XCTAssertEqual(added?.id, personal.id)
        let profiles = try await manager.listProfiles()
        XCTAssertEqual(profiles.map(\.name), ["개인"])
        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, personal.id, "renaming the live account keeps it active")
    }

    func testAddingAnAccountFallsBackToThePlaintextCredentialFile() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        _ = try await manager.saveCurrent(named: "personal")
        // Claude Code writes this file instead when the Keychain refuses the write.
        fixture.loginRunner.onLogin { directory, _ in
            try? ClaudeCredentialFixture.envelope(accessToken: "work-token").write(
                to: directory.appendingPathComponent(".credentials.json")
            )
        }

        let added = try await manager.addAccount(named: "work")

        let work = try XCTUnwrap(added)
        let stored = try XCTUnwrap(fixture.credentials.credential(named: work.id))
        XCTAssertEqual(try ClaudeCredentialEnvelope.token(in: stored).accessToken, "work-token")
    }

    func testAddingAnAccountIsRefusedWhenNoSignInRunnerIsWired() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager(withLoginRunner: false)

        do {
            _ = try await manager.addAccount(named: "work")
            XCTFail("there is no way to sign in without a runner")
        } catch let error as ClaudeProfileManagerError {
            XCTAssertEqual(error, .loginUnavailable)
        }
    }

    func testSigningInElsewhereMovesTheActivePointerInsteadOfOverwritingTheOtherAccount() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        let personal = try await manager.saveCurrent(named: "personal")
        let work = try fixture.addStoredProfile(
            name: "work",
            accessToken: "work-token",
            email: "work@example.com"
        )
        let personalCredential = try XCTUnwrap(fixture.credentials.credential(named: personal.id))
        // The user ran `/login` in Claude Code instead of switching in the app.
        try fixture.signInLive(accessToken: "work-token-renewed", email: "work@example.com", accountUUID: "work-uuid")

        await manager.syncActiveProfile()

        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, work.id)
        XCTAssertEqual(
            try fixture.credentials.credential(named: personal.id),
            personalCredential,
            "the account that is no longer signed in must keep its own token"
        )
        let storedWork = try XCTUnwrap(fixture.credentials.credential(named: work.id))
        XCTAssertEqual(
            try ClaudeCredentialEnvelope.token(in: storedWork).accessToken,
            "work-token-renewed"
        )
    }

    func testSigningInAsAnUncapturedAccountLeavesNoAccountMarkedActive() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        let personal = try await manager.saveCurrent(named: "personal")
        let personalCredential = try XCTUnwrap(fixture.credentials.credential(named: personal.id))
        try fixture.signInLive(
            accessToken: "stranger-token",
            email: "stranger@example.com",
            accountUUID: "stranger-uuid"
        )

        await manager.syncActiveProfile()

        let activeProfileID = await manager.activeProfileID()
        XCTAssertNil(activeProfileID)
        XCTAssertEqual(try fixture.credentials.credential(named: personal.id), personalCredential)
    }

    func testAConfigFileNamingAnotherAccountNeverFilesTheLiveTokenUnderIt() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        let personal = try await manager.saveCurrent(named: "personal")
        let work = try fixture.addStoredProfile(
            name: "work",
            accessToken: "work-token",
            email: "work@example.com"
        )
        let workCredential = try XCTUnwrap(fixture.credentials.credential(named: work.id))
        // The Keychain still holds personal's token, but the config file names work: a session
        // still running on another account rewrote it, or the app was started with another
        // profile's CLAUDE_CONFIG_DIR.
        try fixture.configOperator.applyAccountJSON(
            ClaudeCredentialFixture.configAccount(email: "work@example.com", accountUUID: "work-uuid")
        )

        await manager.syncActiveProfile()

        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, personal.id)
        XCTAssertEqual(
            try fixture.credentials.credential(named: work.id),
            workCredential,
            "work must keep its own token, not receive personal's"
        )
    }

    func testAnAccountHoldingAnotherAccountsTokenIsNeitherReadNorRenewed() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        let personal = try await manager.saveCurrent(named: "personal")
        let work = try fixture.addStoredProfile(
            name: "work",
            accessToken: "work-token",
            email: "work@example.com",
            expiresAtMilliseconds: Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        )
        // The damage an earlier mismatch left behind: work's slot holds personal's token.
        let personalCredential = try XCTUnwrap(fixture.credentials.credential(named: personal.id))
        try fixture.credentials.storeCredential(personalCredential, named: work.id)

        do {
            _ = try await manager.accessToken(for: work.id)
            XCTFail("another account's token must not report usage for, or be renewed as, work")
        } catch let error as ClaudeProfileManagerError {
            XCTAssertEqual(error, .credentialHeldByAnotherAccount)
        }
        XCTAssertEqual(fixture.refresher.callCount, 0)
        // The account the token really belongs to keeps working.
        let personalToken = try await manager.accessToken(for: personal.id)
        XCTAssertEqual(personalToken, "personal-token")
    }

    func testSyncLeavesEverythingAloneWhenTheConfigNamesNoAccount() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        let personal = try await manager.saveCurrent(named: "personal")
        try fixture.configOperator.applyAccountJSON(nil)
        try fixture.replaceLive(accessToken: "personal-token-renewed")

        await manager.syncActiveProfile()

        let activeProfileID = await manager.activeProfileID()
        XCTAssertEqual(activeProfileID, personal.id)
        let stored = try XCTUnwrap(fixture.credentials.credential(named: personal.id))
        XCTAssertEqual(
            try ClaudeCredentialEnvelope.token(in: stored).accessToken,
            "personal-token",
            "without an identity to compare, mirroring could copy the wrong account's token"
        )
    }

    func testSyncActiveProfileCapturesTokensClaudeCodeRenewedOnItsOwn() async throws {
        let fixture = Fixture(liveAccessToken: "personal-token")
        let manager = fixture.manager()
        let personal = try await manager.saveCurrent(named: "personal")
        try fixture.replaceLive(accessToken: "personal-token-renewed")

        await manager.syncActiveProfile()

        let stored = try XCTUnwrap(fixture.credentials.credential(named: personal.id))
        XCTAssertEqual(
            try ClaudeCredentialEnvelope.token(in: stored).accessToken,
            "personal-token-renewed"
        )
    }
}

private final class IDCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class Fixture {
    let credentials = MemoryClaudeCredentialStore()
    let preferences = MemoryClaudeProfilePreferences()
    let liveCredential: FakeClaudeLiveCredentialOperator
    let configOperator: FakeClaudeConfigOperator
    let authStatus: FakeClaudeAuthStatusReader
    var refresher = FakeClaudeOAuthRefresher()
    var loginRunner = FakeClaudeLoginRunner()
    let isolatedCredentials = MemoryIsolatedClaudeCredentials()
    let temporaryDirectory: URL
    private let issuedIDs = IDCounter()

    init(liveAccessToken: String, expiresAtMilliseconds: Int64 = 4_102_444_800_000) {
        liveCredential = FakeClaudeLiveCredentialOperator(
            envelope: ClaudeCredentialFixture.envelope(
                accessToken: liveAccessToken,
                expiresAtMilliseconds: expiresAtMilliseconds
            )
        )
        configOperator = FakeClaudeConfigOperator(
            json: ClaudeCredentialFixture.configAccount(
                email: "personal@example.com",
                accountUUID: "personal-uuid"
            )
        )
        authStatus = FakeClaudeAuthStatusReader(
            account: ClaudeAccount(email: "personal@example.com", subscriptionType: "max")
        )
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsage-ClaudeFixture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func manager(
        withLoginRunner: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> ClaudeProfileManager {
        ClaudeProfileManager(
            credentialStore: credentials,
            preferences: preferences,
            liveCredential: liveCredential,
            configOperator: configOperator,
            authStatus: authStatus,
            refresher: refresher,
            loginRunner: withLoginRunner ? loginRunner : nil,
            isolatedCredentials: isolatedCredentials,
            temporaryDirectory: temporaryDirectory,
            profileID: { [issuedIDs] in "profile-\(issuedIDs.next())" },
            now: now
        )
    }

    /// Makes the fake sign-in behave like the real one: a credential under the directory's own
    /// Keychain service, an `oauthAccount` in its own config file, and an identity the CLI agrees
    /// with.
    func plantLoginResult(
        accessToken: String,
        email: String,
        accountUUID: String? = nil
    ) {
        let uuid = accountUUID ?? "\(email)-uuid"
        let credentials = isolatedCredentials
        loginRunner.onLogin { directory, service in
            credentials.plant(
                ClaudeCredentialFixture.envelope(accessToken: accessToken),
                service: service
            )
            let config: [String: Any] = [
                "oauthAccount": ["accountUuid": uuid, "emailAddress": email],
            ]
            try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(
                to: directory.appendingPathComponent(".claude.json")
            )
        }
        authStatus.setAccount(ClaudeAccount(email: email, subscriptionType: "max"))
    }

    /// Reproduces a sign-in performed outside the app: both the credential and the config
    /// account change together.
    func signInLive(accessToken: String, email: String, accountUUID: String) throws {
        try replaceLive(accessToken: accessToken)
        try configOperator.applyAccountJSON(
            ClaudeCredentialFixture.configAccount(email: email, accountUUID: accountUUID)
        )
    }

    func replaceLive(accessToken: String) throws {
        let current = liveCredential.current
        // A sign-in or a renewal always comes with a refresh token of its own.
        try liveCredential.replaceEnvelope(
            with: ClaudeCredentialFixture.envelope(
                accessToken: accessToken,
                refreshToken: "\(accessToken)-refresh"
            ),
            ifCurrentMatches: current
        )
    }

    /// Adds a second account the way a user would: sign in elsewhere, then capture it.
    func addStoredProfile(
        name: String,
        accessToken: String,
        email: String,
        expiresAtMilliseconds: Int64 = 4_102_444_800_000
    ) throws -> ClaudeProfileMetadata {
        let metadata = ClaudeProfileMetadata(
            id: "profile-\(issuedIDs.next())",
            name: name,
            accountUUID: "\(name)-uuid",
            emailAddress: email,
            configAccountJSON: ClaudeCredentialFixture.configAccount(
                email: email,
                accountUUID: "\(name)-uuid"
            )
        )
        try credentials.storeCredential(
            ClaudeCredentialFixture.oauthSection(
                accessToken: accessToken,
                refreshToken: "\(name)-refresh",
                expiresAtMilliseconds: expiresAtMilliseconds
            ),
            named: metadata.id
        )
        try preferences.saveProfiles(preferences.profiles() + [metadata])
        return metadata
    }
}
