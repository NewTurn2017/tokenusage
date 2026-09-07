import Foundation

public enum ClaudeOAuthRefreshError: Error, Equatable, Sendable, LocalizedError {
    case refreshTokenMissing
    case rejected
    case rateLimited
    case networkFailure
    case malformedResponse
    case unexpectedHTTPStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .refreshTokenMissing:
            "저장된 Claude 계정에 리프레시 토큰이 없습니다."
        case .rejected:
            "Claude 계정 토큰이 만료되었습니다. 다시 로그인해 주세요."
        case .rateLimited:
            "Claude 토큰 갱신 요청이 제한되었습니다. 잠시 후 다시 시도합니다."
        case .networkFailure:
            "Claude 토큰 갱신 요청이 실패했습니다."
        case .malformedResponse:
            "Claude 토큰 갱신 응답을 해석할 수 없습니다."
        case let .unexpectedHTTPStatus(statusCode):
            "Claude 토큰 갱신이 HTTP \(statusCode) 로 실패했습니다."
        }
    }
}

public protocol ClaudeOAuthRefreshing: Sendable {
    func refresh(_ token: ClaudeOAuthToken) async throws -> ClaudeOAuthToken
}

/// Renews a stored account's access token with its refresh token.
///
/// Only accounts that are *not* the one Claude Code is currently signed in as may be refreshed
/// here. Claude Code renews its own token, and a rotated refresh token that only this app knows
/// about would sign the running CLI out.
public struct ClaudeOAuthRefresher: ClaudeOAuthRefreshing, Sendable {
    public static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's public OAuth client identifier; the token endpoint rejects any other.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private let session: any URLSessionProtocol
    private let endpoint: URL
    private let clientID: String
    private let now: @Sendable () -> Date

    public init(
        session: any URLSessionProtocol = URLSession.shared,
        endpoint: URL = ClaudeOAuthRefresher.endpoint,
        clientID: String = ClaudeOAuthRefresher.clientID,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.endpoint = endpoint
        self.clientID = clientID
        self.now = now
    }

    public func refresh(_ token: ClaudeOAuthToken) async throws -> ClaudeOAuthToken {
        guard let refreshToken = token.refreshToken else {
            throw ClaudeOAuthRefreshError.refreshTokenMissing
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        guard request.httpBody != nil else { throw ClaudeOAuthRefreshError.malformedResponse }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClaudeOAuthRefreshError.networkFailure
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeOAuthRefreshError.malformedResponse
        }
        switch httpResponse.statusCode {
        case 200...299:
            break
        case 400, 401, 403:
            throw ClaudeOAuthRefreshError.rejected
        case 429:
            throw ClaudeOAuthRefreshError.rateLimited
        default:
            throw ClaudeOAuthRefreshError.unexpectedHTTPStatus(httpResponse.statusCode)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = root["access_token"] as? String,
              !accessToken.isEmpty else {
            throw ClaudeOAuthRefreshError.malformedResponse
        }
        let rotatedRefreshToken = (root["refresh_token"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        let expiresAt: Date?
        if let expiresIn = root["expires_in"] as? NSNumber {
            expiresAt = now().addingTimeInterval(expiresIn.doubleValue)
        } else if let expiresAtMilliseconds = root["expires_at"] as? NSNumber {
            expiresAt = Date(timeIntervalSince1970: expiresAtMilliseconds.doubleValue / 1_000)
        } else {
            expiresAt = nil
        }
        return ClaudeOAuthToken(
            accessToken: accessToken,
            refreshToken: rotatedRefreshToken,
            expiresAt: expiresAt,
            subscriptionType: (root["subscription_type"] as? String) ?? token.subscriptionType
        )
    }
}
