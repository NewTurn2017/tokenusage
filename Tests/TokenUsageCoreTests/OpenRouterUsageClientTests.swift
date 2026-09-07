import Foundation
import XCTest
@testable import TokenUsageCore

final class OpenRouterUsageClientTests: XCTestCase {
    func testCreditBasedResponseCalculatesRemainingAndBuildsSafeRequests() async throws {
        let secret = "openrouter-test-secret-" + UUID().uuidString
        let session = OpenRouterFixtureSession(outcomes: [
            "/api/v1/key": .response(
                statusCode: 200,
                body: Data(
                    #"{"data":{"limit":null,"limit_remaining":null,"usage":574.18,"usage_daily":1.5,"byok_usage":25.54,"is_free_tier":false,"expires_at":null,"rate_limit":{"requests":-1,"interval":"10s","note":"This field is deprecated and safe to ignore."}}}"#.utf8
                )
            ),
            "/api/v1/credits": .response(
                statusCode: 200,
                body: Data(#"{"data":{"total_credits":600,"total_usage":574.18}}"#.utf8)
            ),
        ])
        let client = OpenRouterUsageClient(
            environment: ["OPENROUTER_API_KEY": secret],
            keyFileURL: URL(fileURLWithPath: "/private/tmp/never-read-openrouter-key"),
            fileReader: { _ in XCTFail("environment key must win"); return Data() },
            session: session,
            capturedAt: { Date(timeIntervalSince1970: 1_700_000_007) }
        )

        let snapshot = try await client.usage()

        XCTAssertEqual(snapshot.usage, 574.18, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.totalCredits, 600, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.totalUsage, 574.18, accuracy: 0.000_001)
        XCTAssertNil(snapshot.limit)
        XCTAssertEqual(snapshot.remaining, 25.82, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.isFreeTier, false)
        XCTAssertEqual(snapshot.rateLimit, "-1/10s")
        XCTAssertEqual(snapshot.capturedAt, Date(timeIntervalSince1970: 1_700_000_007))

        let requests = session.requests
        XCTAssertEqual(Set(requests.map(\.path)), ["/api/v1/key", "/api/v1/credits"])
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" })
        let expectedAuthorization = "Bearer " + secret
        XCTAssertTrue(
            requests.allSatisfy { $0.authorization == expectedAuthorization },
            "Authorization header count: \(requests.count)"
        )
    }

    func testUnexpectedRateLimitShapeStillReportsRemaining() async throws {
        let session = OpenRouterFixtureSession(outcomes: [
            "/api/v1/key": .response(
                statusCode: 200,
                body: Data(
                    #"{"data":{"limit":null,"usage":574.18,"is_free_tier":false,"rate_limit":{"renamed_again":7}}}"#.utf8
                )
            ),
            "/api/v1/credits": .response(
                statusCode: 200,
                body: Data(#"{"data":{"total_credits":600,"total_usage":574.18}}"#.utf8)
            ),
        ])

        let snapshot = try await makeClient(session: session).usage()

        XCTAssertEqual(snapshot.remaining, 25.82, accuracy: 0.000_001)
        XCTAssertNil(snapshot.rateLimit)
    }

    func testLimitBasedResponseUsesKeyLimitAndShowsLimit() async throws {
        let session = OpenRouterFixtureSession(outcomes: [
            "/api/v1/key": .response(
                statusCode: 200,
                body: Data(
                    #"{"data":{"limit":100,"usage":50,"is_free_tier":true,"rate_limit":null}}"#.utf8
                )
            ),
            "/api/v1/credits": .response(
                statusCode: 200,
                body: Data(#"{"data":{"total_credits":900,"total_usage":10}}"#.utf8)
            ),
        ])

        let snapshot = try await makeClient(session: session).usage()

        XCTAssertEqual(snapshot.limit, 100)
        XCTAssertEqual(snapshot.usage, 50)
        XCTAssertEqual(snapshot.totalCredits, 900)
        XCTAssertEqual(snapshot.totalUsage, 10)
        XCTAssertEqual(snapshot.remaining, 50)
        XCTAssertEqual(snapshot.isFreeTier, true)
        XCTAssertNil(snapshot.rateLimit)
    }

    func testFileKeyIsTrimmedWhenEnvironmentKeyIsAbsent() async throws {
        let requestedURLs = URLRecorder()
        let session = Self.successfulSession()
        let fileURL = URL(fileURLWithPath: "/private/tmp/injected-openrouter-key")
        let client = OpenRouterUsageClient(
            environment: [:],
            keyFileURL: fileURL,
            fileReader: { url in
                requestedURLs.record(url)
                return Data("\n  file-key  \n".utf8)
            },
            session: session
        )

        _ = try await client.usage()

        XCTAssertEqual(requestedURLs.values, [fileURL])
        XCTAssertTrue(session.requests.allSatisfy { $0.authorization == "Bearer file-key" })
    }

    func testMissingKeyIsTypedAndContainsNoCredentialHint() async {
        let session = OpenRouterFixtureSession(outcomes: [:])
        let client = OpenRouterUsageClient(
            environment: [:],
            keyFileURL: URL(fileURLWithPath: "/private/tmp/missing-openrouter-key"),
            fileReader: { _ in throw CocoaError(.fileNoSuchFile) },
            session: session
        )

        do {
            _ = try await client.usage()
            XCTFail("expected missing key")
        } catch {
            XCTAssertEqual(error as? OpenRouterUsageClientError, .keyUnavailable)
            XCTAssertFalse(String(describing: error).contains("Bearer"))
            XCTAssertTrue(session.requests.isEmpty)
        }
    }

    func testUnauthorizedIsSanitized() async {
        await assertClientError(
            .unauthorized,
            secret: "openrouter-401-secret",
            session: OpenRouterFixtureSession(outcomes: [
                "/api/v1/key": .response(statusCode: 401, body: Data("secret response body".utf8)),
                "/api/v1/credits": .response(statusCode: 200, body: Self.creditsBody),
            ])
        )
    }

    func testNetworkFailureIsSanitized() async {
        await assertClientError(
            .networkFailure,
            secret: "openrouter-network-secret",
            session: OpenRouterFixtureSession(outcomes: [
                "/api/v1/key": .failure(URLError(.notConnectedToInternet)),
                "/api/v1/credits": .response(statusCode: 200, body: Self.creditsBody),
            ])
        )
    }

    func testMalformedJSONIsSanitized() async {
        let secret = "openrouter-malformed-secret"
        await assertClientError(
            .malformedResponse,
            secret: secret,
            session: OpenRouterFixtureSession(outcomes: [
                "/api/v1/key": .response(
                    statusCode: 200,
                    body: Data("{\"data\":{\"usage\":\"\(secret)\"}}".utf8)
                ),
                "/api/v1/credits": .response(statusCode: 200, body: Self.creditsBody),
            ]),
            responseBodySecret: secret
        )
    }

    func testTimeoutIsTypedAndSanitized() async {
        await assertClientError(
            .timeout,
            secret: "openrouter-timeout-secret",
            session: OpenRouterFixtureSession(outcomes: [
                "/api/v1/key": .failure(URLError(.timedOut)),
                "/api/v1/credits": .response(statusCode: 200, body: Self.creditsBody),
            ])
        )
    }

    func testCancellationPropagatesWithoutExposingKey() async {
        let secret = "openrouter-cancellation-secret"
        let client = OpenRouterUsageClient(
            environment: ["OPENROUTER_API_KEY": secret],
            session: OpenRouterFixtureSession(outcomes: [
                "/api/v1/key": .failure(CancellationError()),
                "/api/v1/credits": .response(statusCode: 200, body: Self.creditsBody),
            ])
        )

        do {
            _ = try await client.usage()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    private static let keyBody = Data(
        #"{"data":{"limit":null,"usage":1,"is_free_tier":false,"rate_limit":null}}"#.utf8
    )
    private static let creditsBody = Data(
        #"{"data":{"total_credits":2,"total_usage":1}}"#.utf8
    )
    private static func successfulSession() -> OpenRouterFixtureSession {
        OpenRouterFixtureSession(outcomes: [
            "/api/v1/key": .response(statusCode: 200, body: keyBody),
            "/api/v1/credits": .response(statusCode: 200, body: creditsBody),
        ])
    }

    private func makeClient(session: OpenRouterFixtureSession) -> OpenRouterUsageClient {
        OpenRouterUsageClient(
            environment: ["OPENROUTER_API_KEY": "fixture-key"],
            keyFileURL: URL(fileURLWithPath: "/private/tmp/unused-openrouter-key"),
            fileReader: { _ in XCTFail("file key must not be read"); return Data() },
            session: session
        )
    }

    private func assertClientError(
        _ expected: OpenRouterUsageClientError,
        secret: String,
        session: OpenRouterFixtureSession,
        responseBodySecret: String? = nil
    ) async {
        let client = OpenRouterUsageClient(
            environment: ["OPENROUTER_API_KEY": secret],
            session: session
        )

        do {
            _ = try await client.usage()
            XCTFail("expected OpenRouter client error")
        } catch {
            XCTAssertEqual(error as? OpenRouterUsageClientError, expected)
            XCTAssertFalse(String(describing: error).contains(secret))
            if let responseBodySecret {
                XCTAssertFalse(String(describing: error).contains(responseBodySecret))
                XCTAssertFalse(error.localizedDescription.contains(responseBodySecret))
            }
        }
    }
}

private final class OpenRouterFixtureSession: URLSessionProtocol, @unchecked Sendable {
    enum Outcome: @unchecked Sendable {
        case response(statusCode: Int, body: Data)
        case failure(any Error)
    }

    struct Request: Sendable {
        let path: String
        let method: String?
        let authorization: String?
    }

    private let outcomes: [String: Outcome]
    private let lock = NSLock()
    private var recordedRequests: [Request] = []

    init(outcomes: [String: Outcome]) {
        self.outcomes = outcomes
    }

    var requests: [Request] {
        lock.withLock { recordedRequests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        lock.withLock {
            recordedRequests.append(
                Request(
                    path: path,
                    method: request.httpMethod,
                    authorization: request.value(forHTTPHeaderField: "Authorization")
                )
            )
        }
        guard let outcome = outcomes[path] else {
            throw URLError(.badURL)
        }
        switch outcome {
        case let .response(statusCode, body):
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (body, response)
        case let .failure(error):
            throw error
        }
    }
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [URL] = []

    var values: [URL] { lock.withLock { recordedValues } }

    func record(_ value: URL) {
        lock.withLock { recordedValues.append(value) }
    }
}
