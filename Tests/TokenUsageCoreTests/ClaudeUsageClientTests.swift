import Foundation
import XCTest
@testable import TokenUsageCore

final class ClaudeUsageClientTests: XCTestCase {
    func testUsageRequestsExactEndpointAndHeadersAndDecodesQuotaWindows() async throws {
        let fixture = FixtureURLSession.responding(
            statusCode: 200,
            body: jsonData(
                """
                {
                  "five_hour":{"utilization":16,"resets_at":"2026-08-03T12:34:56Z","ignored":"value"},
                  "seven_day":{"utilization":40,"resets_at":"2026-08-10T00:00:00Z"},
                  "limits":[
                    {"kind":"weekly_scoped","scope":{"model":{"display_name":"fAbLe"}},"percent":25,"resets_at":"2026-08-10T00:00:00.500Z"}
                  ],
                  "ignored_response_field":{"secret":"not decoded"}
                }
                """
            )
        )
        let client = makeClient(token: UUID().uuidString, session: fixture)

        let snapshot = try await client.usage()

        XCTAssertEqual(snapshot.capturedAt, capturedAt)
        XCTAssertEqual(snapshot.fiveHour, QuotaWindow(
            remainingPercent: 84,
            resetsAt: Date(timeIntervalSince1970: 1_785_760_496),
            windowDuration: QuotaWindowKind.fiveHour.duration
        ))
        XCTAssertEqual(snapshot.weekly, QuotaWindow(
            remainingPercent: 60,
            resetsAt: Date(timeIntervalSince1970: 1_786_320_000),
            windowDuration: QuotaWindowKind.weekly.duration
        ))
        XCTAssertEqual(snapshot.fableWeekly, QuotaWindow(
            remainingPercent: 75,
            resetsAt: Date(timeIntervalSince1970: 1_786_320_000.5),
            windowDuration: QuotaWindowKind.fableWeekly.duration
        ))

        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(
            request.url,
            "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1"
        )
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.anthropicBeta, "oauth-2025-04-20")
        XCTAssertEqual(request.userAgent, "claude-cli/2.1.283 (external, cli)")
        XCTAssertTrue(request.hasBearerAuthorization)
    }

    func testNullBucketsAndResetRemainAbsentWithoutFabricatedValues() async throws {
        let fixture = FixtureURLSession.responding(
            statusCode: 200,
            body: jsonData(
                #"{"five_hour":null,"seven_day":{"utilization":16,"resets_at":null},"limits":null}"#
            )
        )

        let snapshot = try await makeClient(token: UUID().uuidString, session: fixture).usage()

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(
            snapshot.weekly,
            QuotaWindow(
                remainingPercent: 84,
                resetsAt: nil,
                windowDuration: QuotaWindowKind.weekly.duration
            )
        )
        XCTAssertNil(snapshot.fableWeekly)
    }

    func testFableDisplayNameMutationRemovesScopedQuota() async throws {
        let matching = FixtureURLSession.responding(
            statusCode: 200,
            body: fableFixture(displayName: "FABLE")
        )
        let mutated = FixtureURLSession.responding(
            statusCode: 200,
            body: fableFixture(displayName: "Sonnet")
        )

        let matchingSnapshot = try await makeClient(token: UUID().uuidString, session: matching).usage()
        let mutatedSnapshot = try await makeClient(token: UUID().uuidString, session: mutated).usage()

        XCTAssertEqual(matchingSnapshot.fableWeekly?.remainingPercent, 84)
        XCTAssertNil(mutatedSnapshot.fableWeekly)
    }

    func testMalformedResponseIsSanitized() async {
        let sentinel = "private-response-body-\(UUID().uuidString)"
        let fixture = FixtureURLSession.responding(
            statusCode: 200,
            body: jsonData("{\"five_hour\":{\"utilization\":\"\(sentinel)\",\"resets_at\":null}}")
        )
        await assertClientError(
            .malformedResponse,
            from: makeClient(token: UUID().uuidString, session: fixture),
            excluding: sentinel
        )
    }

    func testUnauthorizedIsSanitized() async {
        let secret = "sentinel-secret-\(UUID().uuidString)"
        let responseSentinel = "private-response-body-\(UUID().uuidString)"
        let fixture = FixtureURLSession.responding(
            statusCode: 401,
            body: Data(responseSentinel.utf8)
        )
        await assertClientError(
            .unauthorized,
            from: makeClient(token: secret, session: fixture),
            excluding: secret,
            responseSentinel
        )
    }

    func testNetworkFailureIsSanitized() async {
        let secret = "sentinel-secret-\(UUID().uuidString)"
        let fixture = FixtureURLSession.failing(with: .notConnectedToInternet)
        await assertClientError(
            .networkFailure,
            from: makeClient(token: secret, session: fixture),
            excluding: secret
        )
    }

    func testExpiredLiveCredentialsNeverReachTheUsageAPI() async {
        let session = FixtureURLSession.responding(
            statusCode: 200,
            body: jsonData(#"{"five_hour":{"utilization":16,"resets_at":null}}"#)
        )
        let credential = jsonData(
            #"{"claudeAiOauth":{"accessToken":"expired-token","expiresAt":1699999000000}}"#
        )
        let client = ClaudeUsageClient(
            credentialStore: StubCredentialStore(credential: credential),
            session: session,
            capturedAt: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        await assertUsageFails(client)

        XCTAssertTrue(session.requests.isEmpty)
    }

    func testRetryAfterSuppressesRequestsBeforeTheServerDeadline() async {
        let clock = ClaudeUsageTestClock()
        let session = FixtureURLSession.responding(
            statusCode: 429,
            body: Data(),
            headers: ["Retry-After": "3105"]
        )
        let client = ClaudeUsageClient(
            credentialStore: StubCredentialStore(credential: credentialData(token: "account-a")),
            session: session,
            capturedAt: { clock.now }
        )
        await assertUsageFails(client)
        clock.advance(by: 300)

        await assertUsageFails(client)

        XCTAssertEqual(session.requests.count, 1)
    }

    func testRetryAfterAllowsARequestAtTheServerDeadline() async {
        let clock = ClaudeUsageTestClock()
        let session = FixtureURLSession.responding(
            statusCode: 429,
            body: Data(),
            headers: ["Retry-After": "3105"]
        )
        let client = ClaudeUsageClient(
            credentialStore: StubCredentialStore(credential: credentialData(token: "account-a")),
            session: session,
            capturedAt: { clock.now }
        )
        await assertUsageFails(client)
        clock.advance(by: 3105)

        await assertUsageFails(client)

        XCTAssertEqual(session.requests.count, 2)
    }

    func testHTTPDateRetryAfterAllowsARequestAtItsDeadline() async {
        let clock = ClaudeUsageTestClock()
        let session = FixtureURLSession.responding(
            statusCode: 429,
            body: Data(),
            headers: ["Retry-After": "Tue, 14 Nov 2023 22:15:20 GMT"]
        )
        let client = ClaudeUsageClient(
            credentialStore: StubCredentialStore(credential: credentialData(token: "account-a")),
            session: session,
            capturedAt: { clock.now }
        )
        await assertUsageFails(client)
        clock.advance(by: 120)

        await assertUsageFails(client)

        XCTAssertEqual(session.requests.count, 2)
    }

    func testZeroRetryAfterDoesNotPermitAnImmediateRetry() async {
        let clock = ClaudeUsageTestClock()
        let session = FixtureURLSession.responding(
            statusCode: 429,
            body: Data(),
            headers: ["Retry-After": "0"]
        )
        let client = ClaudeUsageClient(
            credentialStore: StubCredentialStore(credential: credentialData(token: "account-a")),
            session: session,
            capturedAt: { clock.now }
        )
        await assertUsageFails(client)
        clock.advance(by: 1)

        await assertUsageFails(client)

        XCTAssertEqual(session.requests.count, 1)
    }

    func testCooldownForOneTokenDoesNotBlockAnotherAccount() async {
        let session = FixtureURLSession.responding(
            statusCode: 429,
            body: Data(),
            headers: ["Retry-After": "3105"]
        )
        let client = makeClient(token: "account-a", session: session)
        await assertUsageFails(client)

        do {
            _ = try await client.usage(accessToken: "account-b")
            XCTFail("Expected the second account's server response to fail")
        } catch {
            XCTAssertTrue(error is ClaudeUsageClientError)
        }

        XCTAssertEqual(session.requests.count, 2)
    }

    func testFreshUsageIsReusedInsteadOfRepeatedlyRequestingTheSameAccount() async throws {
        let clock = ClaudeUsageTestClock()
        let session = FixtureURLSession.responding(
            statusCode: 200,
            body: jsonData(#"{"five_hour":{"utilization":16,"resets_at":null}}"#)
        )
        let client = ClaudeUsageClient(
            credentialStore: StubCredentialStore(credential: credentialData(token: "account-a")),
            session: session,
            capturedAt: { clock.now }
        )
        let previous = try await client.usage()
        clock.advance(by: 30)

        let cached = try await client.usage()

        XCTAssertEqual(session.requests.count, 1)
        XCTAssertEqual(cached, previous)
    }

    func testUsageCacheExpiresAtTheAutomaticRefreshInterval() async throws {
        let clock = ClaudeUsageTestClock()
        let session = FixtureURLSession.responding(
            statusCode: 200,
            body: jsonData(#"{"five_hour":{"utilization":16,"resets_at":null}}"#)
        )
        let client = ClaudeUsageClient(
            credentialStore: StubCredentialStore(credential: credentialData(token: "account-a")),
            session: session,
            capturedAt: { clock.now }
        )
        _ = try await client.usage()
        clock.advance(by: 300)

        let refreshed = try await client.usage()

        XCTAssertEqual(session.requests.count, 2)
        XCTAssertEqual(refreshed.capturedAt, clock.now)
    }

    private func assertUsageFails(_ client: ClaudeUsageClient) async {
        do {
            _ = try await client.usage()
            XCTFail("Expected usage to remain unavailable")
        } catch {
            XCTAssertTrue(error is ClaudeUsageClientError)
        }
    }

    func testCancellationPropagatesThroughAsyncCredentialReadBeforeNetworkRequest() async {
        let started = expectation(description: "credential read started")
        let cancelled = expectation(description: "credential read cancelled")
        let finished = expectation(description: "Claude usage task finished")
        let reader = BlockingCredentialReader(started: started, cancelled: cancelled)
        let session = FixtureURLSession.responding(statusCode: 200, body: Data())
        let client = ClaudeUsageClient(credentialReader: reader, session: session)
        let usage = Task { () -> Result<UsageSnapshot, any Error> in
            defer { finished.fulfill() }
            do { return .success(try await client.usage()) }
            catch { return .failure(error) }
        }
        await fulfillment(of: [started], timeout: 1)

        usage.cancel()

        await fulfillment(of: [cancelled, finished], timeout: 1)
        let result = await usage.value
        guard case .failure(let error) = result else {
            return XCTFail("Expected Claude usage task to be cancelled")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertTrue(session.requests.isEmpty)
    }

    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_007)

    private func makeClient(token: String, session: FixtureURLSession) -> ClaudeUsageClient {
        ClaudeUsageClient(
            credentialStore: StubCredentialStore(credential: credentialData(token: token)),
            session: session,
            capturedAt: { Date(timeIntervalSince1970: 1_700_000_007) }
        )
    }

    private func credentialData(token: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": token]
        ])
    }

    private func fableFixture(displayName: String) -> Data {
        jsonData(
            """
            {"limits":[
              {"kind":"daily_scoped","scope":{"model":{"display_name":"Fable"}},"percent":90,"resets_at":null},
              {"kind":"weekly_scoped","scope":{"model":{"display_name":"\(displayName)"}},"percent":16,"resets_at":null}
            ]}
            """
        )
    }

    private func jsonData(_ json: String) -> Data {
        Data(json.utf8)
    }

    private func assertClientError(
        _ expected: ClaudeUsageClientError,
        from client: ClaudeUsageClient,
        excluding forbiddenValues: String...
    ) async {
        do {
            _ = try await client.usage()
            XCTFail("Expected Claude usage request to fail")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageClientError, expected)
            for forbiddenValue in forbiddenValues {
                XCTAssertFalse(error.localizedDescription.contains(forbiddenValue))
                XCTAssertFalse(String(describing: error).contains(forbiddenValue))
            }
        }
    }
}

private final class ClaudeUsageTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date { lock.withLock { value } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { value.addTimeInterval(seconds) }
    }
}
