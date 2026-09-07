import Foundation

public enum ClaudeCredentialError: Error, Equatable, Sendable, LocalizedError {
    case malformedEnvelope
    case missingOAuthSection
    case missingAccessToken
    case missingRefreshToken

    public var errorDescription: String? {
        switch self {
        case .malformedEnvelope:
            "Claude 자격 증명이 올바른 JSON이 아닙니다."
        case .missingOAuthSection:
            "Claude 자격 증명에 로그인된 계정이 없습니다."
        case .missingAccessToken:
            "Claude 자격 증명에 액세스 토큰이 없습니다."
        case .missingRefreshToken:
            "Claude 자격 증명에 리프레시 토큰이 없습니다."
        }
    }
}

/// The account half of a Claude Code credential blob.
///
/// Claude Code keeps one Keychain item that holds both the signed-in account (`claudeAiOauth`)
/// and every MCP server's OAuth tokens (`mcpOAuth`). Only the account half belongs to a profile,
/// so switching accounts must never carry the MCP half along.
public struct ClaudeOAuthToken: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let subscriptionType: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        subscriptionType: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    /// Treats a token that expires within `leeway` as already expired, so a refresh happens
    /// before a request can fail in flight.
    public func isExpired(at date: Date, leeway: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(date) <= leeway
    }
}

public enum ClaudeCredentialEnvelope {
    public static let oauthKey = "claudeAiOauth"

    /// Extracts the account half of a live Claude Code credential blob, in canonical form.
    public static func oauthSection(from envelope: Data) throws -> Data {
        let root = try object(from: envelope)
        guard let section = root[oauthKey] as? [String: Any] else {
            throw ClaudeCredentialError.missingOAuthSection
        }
        return try canonicalData(section)
    }

    /// Replaces only the account half of `envelope`, preserving every other key - notably the
    /// `mcpOAuth` tokens, which belong to the machine rather than to the signed-in account.
    public static func merging(oauthSection: Data, into envelope: Data?) throws -> Data {
        let section = try object(from: oauthSection)
        var root: [String: Any]
        if let envelope, !envelope.isEmpty {
            root = try object(from: envelope)
        } else {
            root = [:]
        }
        root[oauthKey] = section
        return try canonicalData(root)
    }

    public static func token(in oauthSection: Data) throws -> ClaudeOAuthToken {
        let section = try object(from: oauthSection)
        guard let accessToken = section["accessToken"] as? String, !accessToken.isEmpty else {
            throw ClaudeCredentialError.missingAccessToken
        }
        let refreshToken = (section["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiresAt = (section["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1_000)
        }
        let subscriptionType = (section["subscriptionType"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeOAuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            subscriptionType: subscriptionType
        )
    }

    /// Writes a refreshed token back into an account section, leaving unrelated fields
    /// (scopes, rate limit tier, subscription type) exactly as the provider last wrote them.
    public static func applying(_ token: ClaudeOAuthToken, to oauthSection: Data) throws -> Data {
        var section = try object(from: oauthSection)
        section["accessToken"] = token.accessToken
        if let refreshToken = token.refreshToken {
            section["refreshToken"] = refreshToken
        }
        if let expiresAt = token.expiresAt {
            section["expiresAt"] = NSNumber(
                value: Int64((expiresAt.timeIntervalSince1970 * 1_000).rounded())
            )
        }
        if let subscriptionType = token.subscriptionType {
            section["subscriptionType"] = subscriptionType
        }
        return try canonicalData(section)
    }

    public static func canonicalData(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ClaudeCredentialError.malformedEnvelope
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw ClaudeCredentialError.malformedEnvelope
        }
    }

    private static func object(from data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCredentialError.malformedEnvelope
        }
        return root
    }
}
