import CryptoKit
import Foundation

public enum ClaudeUsageClientError: Error, Equatable, Sendable {
    case credentialUnavailable
    case credentialAccessFailed
    case credentialExpired
    case malformedCredential
    case unauthorized
    case rateLimited(retryAt: Date)
    case networkFailure
    case malformedResponse
    case unexpectedHTTPStatus(Int)
}

extension ClaudeUsageClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .credentialUnavailable:
            return "Claude credentials are unavailable."
        case .credentialAccessFailed:
            return "Claude credentials could not be read."
        case .credentialExpired:
            return "Claude 로그인 토큰이 만료되었습니다. Claude Code에서 다시 로그인해 주세요."
        case .malformedCredential:
            return "Claude credentials are invalid."
        case .unauthorized:
            return "Claude authorization failed."
        case let .rateLimited(retryAt):
            return "Claude 조회가 제한되었습니다. \(retryAt.formatted(date: .abbreviated, time: .standard)) 이후 다시 시도합니다."
        case .networkFailure:
            return "Claude usage could not be reached."
        case .malformedResponse:
            return "Claude returned an invalid usage response."
        case let .unexpectedHTTPStatus(statusCode):
            return "Claude usage returned HTTP status \(statusCode)."
        }
    }
}

public struct ClaudeUsageClient: UsageProviding, Sendable {
    /// `cedar_ember=1` adds the limit-reset credit block to the same usage read, so the credits
    /// cost no extra request against the endpoint's rate limit. `skip_spend=1` drops the spend
    /// fields this app does not decode.
    public static let endpoint = URL(
        string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1"
    )!
    /// The server only reports reset credits to the Claude Code CLI surface, which it recognizes
    /// by this User-Agent prefix; any other agent is answered `ineligible_reason: "surface"`.
    public static let userAgent = "claude-cli/2.1.283 (external, cli)"
    public static let credentialName = "Claude Code-credentials"

    private let readCredential: @Sendable (String) async throws -> Data?
    private let session: any URLSessionProtocol
    private let storedCredentialName: String
    private let capturedAt: @Sendable () -> Date
    private let decoder: ClaudeUsageDecoder
    private let cache = ClaudeUsageCache()

    public init(
        credentialStore: any CredentialStoring,
        session: any URLSessionProtocol = URLSession.shared,
        credentialName: String = ClaudeUsageClient.credentialName,
        capturedAt: @escaping @Sendable () -> Date = Date.init
    ) {
        readCredential = { name in
            try credentialStore.credential(named: name)
        }
        self.session = session
        self.storedCredentialName = credentialName
        self.capturedAt = capturedAt
        self.decoder = ClaudeUsageDecoder()
    }

    public init(
        credentialReader: any AsyncCredentialReading,
        session: any URLSessionProtocol = URLSession.shared,
        credentialName: String = ClaudeUsageClient.credentialName,
        capturedAt: @escaping @Sendable () -> Date = Date.init
    ) {
        readCredential = { name in
            try await credentialReader.credential(named: name)
        }
        self.session = session
        self.storedCredentialName = credentialName
        self.capturedAt = capturedAt
        self.decoder = ClaudeUsageDecoder()
    }

    public func usage() async throws -> UsageSnapshot {
        let credentialData: Data
        do {
            guard let storedData = try await readCredential(storedCredentialName) else {
                throw ClaudeUsageClientError.credentialUnavailable
            }
            credentialData = storedData
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClaudeUsageClientError {
            throw error
        } catch {
            throw ClaudeUsageClientError.credentialAccessFailed
        }

        let token: ClaudeOAuthToken
        do {
            token = try ClaudeCredentialEnvelope.token(
                in: ClaudeCredentialEnvelope.oauthSection(from: credentialData)
            )
        } catch {
            throw ClaudeUsageClientError.malformedCredential
        }
        guard !token.isExpired(at: capturedAt(), leeway: 0) else {
            throw ClaudeUsageClientError.credentialExpired
        }

        return try await usage(accessToken: token.accessToken)
    }

    /// Reads usage for an account other than the one Claude Code is signed in as, whose token
    /// this app already holds.
    public func usage(accessToken: String) async throws -> UsageSnapshot {
        guard !accessToken.isEmpty else { throw ClaudeUsageClientError.malformedCredential }
        try Task.checkCancellation()
        if let snapshot = try await cache.snapshot(for: accessToken, at: capturedAt()) {
            try Task.checkCancellation()
            return snapshot
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClaudeUsageClientError.networkFailure
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeUsageClientError.malformedResponse
        }
        if httpResponse.statusCode == 401 {
            throw ClaudeUsageClientError.unauthorized
        }
        if httpResponse.statusCode == 429 {
            let now = capturedAt()
            var retryAt = now.addingTimeInterval(ClaudeUsageCache.minimumInterval)
            if let header = httpResponse.value(forHTTPHeaderField: "Retry-After") {
                if let seconds = TimeInterval(header), seconds.isFinite, seconds > 0 {
                    retryAt = now.addingTimeInterval(seconds)
                } else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    if let date = formatter.date(from: header), date > now {
                        retryAt = date
                    }
                }
            }
            await cache.store(.limited(retryAt), for: accessToken)
            throw ClaudeUsageClientError.rateLimited(retryAt: retryAt)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ClaudeUsageClientError.unexpectedHTTPStatus(httpResponse.statusCode)
        }

        let snapshot: UsageSnapshot
        do {
            snapshot = try decoder.decode(data, capturedAt: capturedAt())
        } catch {
            throw ClaudeUsageClientError.malformedResponse
        }
        await cache.store(.value(snapshot), for: accessToken)
        return snapshot
    }
}

private actor ClaudeUsageCache {
    static let minimumInterval: TimeInterval = 300

    enum Entry {
        case value(UsageSnapshot)
        case limited(Date)
    }

    private var entries: [SHA256.Digest: Entry] = [:]

    func snapshot(for accessToken: String, at date: Date) throws -> UsageSnapshot? {
        entries = entries.filter { _, entry in
            switch entry {
            case let .value(snapshot):
                snapshot.capturedAt.addingTimeInterval(Self.minimumInterval) > date
            case let .limited(retryAt):
                retryAt > date
            }
        }
        switch entries[SHA256.hash(data: Data(accessToken.utf8))] {
        case let .value(snapshot):
            return snapshot
        case let .limited(retryAt):
            throw ClaudeUsageClientError.rateLimited(retryAt: retryAt)
        case nil:
            return nil
        }
    }

    func store(_ entry: Entry, for accessToken: String) {
        entries[SHA256.hash(data: Data(accessToken.utf8))] = entry
    }
}
