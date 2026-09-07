import Foundation
import XCTest
@testable import TokenUsageCore

final class ClaudeCredentialEnvelopeTests: XCTestCase {
    func testExtractingAnAccountLeavesTheMachinesMCPTokensBehind() throws {
        let envelope = ClaudeCredentialFixture.envelope(accessToken: "token")

        let section = try ClaudeCredentialEnvelope.oauthSection(from: envelope)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: section) as? [String: Any])
        XCTAssertEqual(root["accessToken"] as? String, "token")
        XCTAssertNil(root["mcpOAuth"])
    }

    func testMergingAnAccountReplacesOnlyTheAccountHalf() throws {
        let envelope = ClaudeCredentialFixture.envelope(accessToken: "old", mcpServerName: "figma")
        let incoming = ClaudeCredentialFixture.oauthSection(accessToken: "new")

        let merged = try ClaudeCredentialEnvelope.merging(oauthSection: incoming, into: envelope)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let account = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])
        let mcp = try XCTUnwrap(root["mcpOAuth"] as? [String: Any])
        XCTAssertEqual(account["accessToken"] as? String, "new")
        XCTAssertNotNil(mcp["figma"])
    }

    func testExpiryIsReadAndWrittenAsWholeMillisecondsRatherThanScientificNotation() throws {
        let section = ClaudeCredentialFixture.oauthSection(
            accessToken: "token",
            expiresAtMilliseconds: 1_787_094_505_331
        )

        let token = try ClaudeCredentialEnvelope.token(in: section)
        let rewritten = try ClaudeCredentialEnvelope.applying(
            ClaudeOAuthToken(
                accessToken: "renewed",
                refreshToken: "rotated",
                expiresAt: Date(timeIntervalSince1970: 1_787_123_456.789)
            ),
            to: section
        )

        XCTAssertEqual(token.accessToken, "token")
        XCTAssertEqual(token.refreshToken, "refresh")
        XCTAssertEqual(token.expiresAt?.timeIntervalSince1970 ?? 0, 1_787_094_505.331, accuracy: 0.001)
        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.contains("1787123456789"), text)
        XCTAssertFalse(text.lowercased().contains("e+"), text)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        XCTAssertEqual(root["scopes"] as? [String], ["user:inference", "user:profile"])
        XCTAssertEqual(root["subscriptionType"] as? String, "max")
    }

    func testATokenIsTreatedAsExpiredJustBeforeItActuallyLapses() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiringSoon = ClaudeOAuthToken(
            accessToken: "a",
            expiresAt: now.addingTimeInterval(60)
        )
        let comfortable = ClaudeOAuthToken(
            accessToken: "a",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let neverExpires = ClaudeOAuthToken(accessToken: "a")

        XCTAssertTrue(expiringSoon.isExpired(at: now))
        XCTAssertFalse(comfortable.isExpired(at: now))
        XCTAssertFalse(neverExpires.isExpired(at: now))
    }

    func testAnAccountWithoutAnAccessTokenIsRejected() {
        let section = try! ClaudeCredentialEnvelope.canonicalData(["refreshToken": "only"])

        XCTAssertThrowsError(try ClaudeCredentialEnvelope.token(in: section)) { error in
            XCTAssertEqual(error as? ClaudeCredentialError, .missingAccessToken)
        }
    }

    func testAnEnvelopeWithoutAnAccountIsRejected() {
        let envelope = try! ClaudeCredentialEnvelope.canonicalData(["mcpOAuth": [:]])

        XCTAssertThrowsError(try ClaudeCredentialEnvelope.oauthSection(from: envelope)) { error in
            XCTAssertEqual(error as? ClaudeCredentialError, .missingOAuthSection)
        }
    }
}

final class ClaudeOAuthRefresherTests: XCTestCase {
    func testARenewedTokenCarriesTheRotatedRefreshTokenAndExpiry() async throws {
        let body = Data(#"{"access_token":"new","refresh_token":"rotated","expires_in":28800}"#.utf8)
        let session = FixtureURLSession.responding(statusCode: 200, body: body)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let refresher = ClaudeOAuthRefresher(session: session, now: { now })

        let token = try await refresher.refresh(
            ClaudeOAuthToken(accessToken: "old", refreshToken: "original")
        )

        XCTAssertEqual(token.accessToken, "new")
        XCTAssertEqual(token.refreshToken, "rotated")
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(28_800))
        XCTAssertEqual(session.requests.first?.method, "POST")
        XCTAssertEqual(
            session.requests.first?.url,
            ClaudeOAuthRefresher.endpoint.absoluteString
        )
    }

    func testAResponseWithoutARotatedRefreshTokenKeepsTheExistingOne() async throws {
        let session = FixtureURLSession.responding(
            statusCode: 200,
            body: Data(#"{"access_token":"new","expires_in":600}"#.utf8)
        )
        let refresher = ClaudeOAuthRefresher(session: session)

        let token = try await refresher.refresh(
            ClaudeOAuthToken(accessToken: "old", refreshToken: "original")
        )

        XCTAssertEqual(token.refreshToken, "original")
    }

    func testAnInvalidGrantIsReportedAsARejectionRatherThanARetryableFailure() async {
        let session = FixtureURLSession.responding(
            statusCode: 400,
            body: Data(#"{"error":"invalid_grant"}"#.utf8)
        )
        let refresher = ClaudeOAuthRefresher(session: session)

        do {
            _ = try await refresher.refresh(
                ClaudeOAuthToken(accessToken: "old", refreshToken: "expired")
            )
            XCTFail("an invalid grant must not be reported as success")
        } catch {
            XCTAssertEqual(error as? ClaudeOAuthRefreshError, .rejected)
        }
    }

    func testRateLimitingIsDistinctSoItCanBeRetriedLater() async {
        let session = FixtureURLSession.responding(statusCode: 429, body: Data("{}".utf8))
        let refresher = ClaudeOAuthRefresher(session: session)

        do {
            _ = try await refresher.refresh(
                ClaudeOAuthToken(accessToken: "old", refreshToken: "valid")
            )
            XCTFail("a rate limited refresh must not be reported as success")
        } catch {
            XCTAssertEqual(error as? ClaudeOAuthRefreshError, .rateLimited)
        }
    }

    func testAnAccountWithNoRefreshTokenIsNotSentToTheNetwork() async {
        let session = FixtureURLSession.responding(statusCode: 200, body: Data("{}".utf8))
        let refresher = ClaudeOAuthRefresher(session: session)

        do {
            _ = try await refresher.refresh(ClaudeOAuthToken(accessToken: "old"))
            XCTFail("a missing refresh token cannot be renewed")
        } catch {
            XCTAssertEqual(error as? ClaudeOAuthRefreshError, .refreshTokenMissing)
        }
        XCTAssertTrue(session.requests.isEmpty)
    }
}

final class ClaudeAuthStatusParsingTests: XCTestCase {
    func testASignedInStatusIsParsedIntoAnAccount() throws {
        let output = Data(#"""
        {"loggedIn":true,"authMethod":"claude.ai","email":"me@example.com",
         "orgId":"org-1","orgName":"Personal","subscriptionType":"max"}
        """#.utf8)

        let account = try ClaudeCLIAuthStatusReader.account(from: output)

        XCTAssertEqual(account.email, "me@example.com")
        XCTAssertEqual(account.organizationName, "Personal")
        XCTAssertEqual(account.subscriptionType, "max")
    }

    func testASignedOutStatusIsRejectedRatherThanTreatedAsAnUnnamedAccount() {
        let output = Data(#"{"loggedIn":false,"authMethod":"none"}"#.utf8)

        XCTAssertThrowsError(try ClaudeCLIAuthStatusReader.account(from: output)) { error in
            XCTAssertEqual(error as? ClaudeCLIError, .notAuthenticated)
        }
    }
}
