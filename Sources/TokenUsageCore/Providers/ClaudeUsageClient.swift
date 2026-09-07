import Foundation

public enum ClaudeUsageClientError: Error, Equatable, Sendable {
    case credentialUnavailable
    case credentialAccessFailed
    case malformedCredential
    case unauthorized
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
        case .malformedCredential:
            return "Claude credentials are invalid."
        case .unauthorized:
            return "Claude authorization failed."
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
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let credentialName = "Claude Code-credentials"

    private let readCredential: @Sendable (String) async throws -> Data?
    private let session: any URLSessionProtocol
    private let storedCredentialName: String
    private let capturedAt: @Sendable () -> Date
    private let decoder: ClaudeUsageDecoder

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

        let accessToken: String
        do {
            accessToken = try JSONDecoder().decode(CredentialEnvelope.self, from: credentialData)
                .claudeAiOauth.accessToken
            guard !accessToken.isEmpty else {
                throw ClaudeUsageClientError.malformedCredential
            }
        } catch let error as ClaudeUsageClientError {
            throw error
        } catch {
            throw ClaudeUsageClientError.malformedCredential
        }

        return try await usage(accessToken: accessToken)
    }

    /// Reads usage for an account other than the one Claude Code is signed in as, whose token
    /// this app already holds.
    public func usage(accessToken: String) async throws -> UsageSnapshot {
        guard !accessToken.isEmpty else { throw ClaudeUsageClientError.malformedCredential }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

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
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ClaudeUsageClientError.unexpectedHTTPStatus(httpResponse.statusCode)
        }

        do {
            return try decoder.decode(data, capturedAt: capturedAt())
        } catch {
            throw ClaudeUsageClientError.malformedResponse
        }
    }
}

private struct CredentialEnvelope: Decodable {
    let claudeAiOauth: OAuthCredential

    struct OAuthCredential: Decodable {
        let accessToken: String
    }
}
