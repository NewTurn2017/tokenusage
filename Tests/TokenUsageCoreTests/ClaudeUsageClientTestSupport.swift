import Foundation
import XCTest
@testable import TokenUsageCore

final class BlockingCredentialReader: AsyncCredentialReading, @unchecked Sendable {
    private let lock = NSLock()
    private let started: XCTestExpectation
    private let cancelled: XCTestExpectation
    private var continuation: CheckedContinuation<Data?, any Error>?
    private var cancellationRequested = false

    init(started: XCTestExpectation, cancelled: XCTestExpectation) {
        self.started = started
        self.cancelled = cancelled
    }

    func credential(named name: String) async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelImmediately = lock.withLock {
                    if cancellationRequested { return true }
                    self.continuation = continuation
                    return false
                }
                started.fulfill()
                if cancelImmediately {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = lock.withLock {
                cancellationRequested = true
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
            cancelled.fulfill()
        }
    }
}

struct StubCredentialStore: CredentialStoring {
    let credential: Data?

    func credential(named name: String) throws -> Data? { credential }

    func storeCredential(_ credential: Data, named name: String) throws {
        XCTFail("ClaudeUsageClient must not store credentials")
    }

    func removeCredential(named name: String) throws {
        XCTFail("ClaudeUsageClient must not remove credentials")
    }
}

final class FixtureURLSession: URLSessionProtocol, @unchecked Sendable {
    private let identifier = UUID().uuidString
    private let session: URLSession

    private init(outcome: FixtureURLProtocol.Outcome) {
        FixtureURLProtocol.register(outcome, for: identifier)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
        FixtureURLProtocol.unregister(identifier)
    }

    static func responding(statusCode: Int, body: Data) -> FixtureURLSession {
        FixtureURLSession(outcome: .response(statusCode: statusCode, body: body))
    }

    static func failing(with code: URLError.Code) -> FixtureURLSession {
        FixtureURLSession(outcome: .failure(code))
    }

    var requests: [RecordedRequest] {
        FixtureURLProtocol.requests(for: identifier)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(identifier, forKey: FixtureURLProtocol.fixtureKey, in: mutableRequest)
        return try await session.data(for: mutableRequest as URLRequest)
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome: Sendable {
        case response(statusCode: Int, body: Data)
        case failure(URLError.Code)
    }

    static let fixtureKey = "ClaudeUsageClientTests.fixture"
    private static let registry = FixtureRegistry()

    static func register(_ outcome: Outcome, for identifier: String) {
        registry.register(outcome, for: identifier)
    }

    static func unregister(_ identifier: String) {
        registry.unregister(identifier)
    }

    static func requests(for identifier: String) -> [RecordedRequest] {
        registry.requests(for: identifier)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        URLProtocol.property(forKey: fixtureKey, in: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let identifier = URLProtocol.property(
            forKey: Self.fixtureKey,
            in: request
        ) as? String,
            let outcome = Self.registry.recordAndReadOutcome(request, for: identifier)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch outcome {
        case let .response(statusCode, body):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: ["Content-Type": "application/json"]
                  )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

struct RecordedRequest: Sendable {
    let url: String?
    let method: String?
    let anthropicBeta: String?
    let userAgent: String?
    let hasBearerAuthorization: Bool

    init(_ request: URLRequest) {
        url = request.url?.absoluteString
        method = request.httpMethod
        anthropicBeta = request.value(forHTTPHeaderField: "anthropic-beta")
        userAgent = request.value(forHTTPHeaderField: "User-Agent")
        hasBearerAuthorization = request.value(forHTTPHeaderField: "Authorization")?
            .hasPrefix("Bearer ") == true
    }
}

private final class FixtureRegistry: @unchecked Sendable {
    private struct Fixture {
        let outcome: FixtureURLProtocol.Outcome
        var requests: [RecordedRequest]
    }

    private let lock = NSLock()
    private var fixtures: [String: Fixture] = [:]

    func register(_ outcome: FixtureURLProtocol.Outcome, for identifier: String) {
        lock.withLock {
            fixtures[identifier] = Fixture(outcome: outcome, requests: [])
        }
    }

    func unregister(_ identifier: String) {
        _ = lock.withLock { fixtures.removeValue(forKey: identifier) }
    }

    func requests(for identifier: String) -> [RecordedRequest] {
        lock.withLock { fixtures[identifier]?.requests ?? [] }
    }

    func recordAndReadOutcome(
        _ request: URLRequest,
        for identifier: String
    ) -> FixtureURLProtocol.Outcome? {
        lock.withLock {
            guard var fixture = fixtures[identifier] else { return nil }
            fixture.requests.append(RecordedRequest(request))
            fixtures[identifier] = fixture
            return fixture.outcome
        }
    }
}
