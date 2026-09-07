import Foundation

public enum ClaudeConfigError: Error, Equatable, Sendable, LocalizedError {
    case malformed
    case writeFailed
    case conflict

    public var errorDescription: String? {
        switch self {
        case .malformed:
            "~/.claude.json 을 읽을 수 없습니다."
        case .writeFailed:
            "~/.claude.json 을 업데이트하지 못했습니다."
        case .conflict:
            "Claude Code 가 동시에 ~/.claude.json 을 바꿔 업데이트하지 못했습니다."
        }
    }
}

/// Reads and rewrites the `oauthAccount` block of `~/.claude.json`.
///
/// The credential in the Keychain decides which account the API accepts; this file decides which
/// account the CLI *reports*. Switching one without the other leaves `claude auth status` naming
/// the wrong person.
public protocol ClaudeConfigOperating: Sendable {
    func readAccountJSON() throws -> String?
    func applyAccountJSON(_ json: String?) throws
}

public struct FileClaudeConfigOperator: ClaudeConfigOperating, Sendable {
    public static let accountKey = "oauthAccount"

    /// Derived from the signed-in account. Dropping them makes Claude Code refetch instead of
    /// showing the previous account's plan, model access, and credit balance.
    public static let accountScopedCacheKeys = [
        "additionalModelCostsCache",
        "additionalModelOptionsCache",
        "cachedExtraUsageDisabledReason",
        "clientDataCacheSlots",
        "hasAvailableSubscription",
        "metricsStatusCache",
        "modelAccessCache",
        "orgModelDefaultCache",
        "overageCreditGrantCache",
        "passesEligibilityCache",
    ]

    private static let maximumAttempts = 5

    private let fileOperator: any AuthFileOperating

    public init(configFileURL: URL) {
        self.init(fileOperator: AtomicAuthFileOperator(authFileURL: configFileURL))
    }

    public init(fileOperator: any AuthFileOperating) {
        self.fileOperator = fileOperator
    }

    public func readAccountJSON() throws -> String? {
        guard let data = try read(), let root = try? root(from: data) else { return nil }
        guard let account = root[Self.accountKey] as? [String: Any] else { return nil }
        let encoded = try ClaudeCredentialEnvelope.canonicalData(account)
        return String(decoding: encoded, as: UTF8.self)
    }

    public func applyAccountJSON(_ json: String?) throws {
        let account: [String: Any]?
        if let json {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [String: Any] else {
                throw ClaudeConfigError.malformed
            }
            account = parsed
        } else {
            account = nil
        }

        for _ in 0..<Self.maximumAttempts {
            // Claude Code recreates the file on next launch, so a missing one needs no patch.
            guard let current = try read() else { return }
            var root = try self.root(from: current)
            if let account {
                root[Self.accountKey] = account
            } else {
                root.removeValue(forKey: Self.accountKey)
            }
            for key in Self.accountScopedCacheKeys {
                root.removeValue(forKey: key)
            }

            let updated: Data
            do {
                updated = try JSONSerialization.data(
                    withJSONObject: root,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
            } catch {
                throw ClaudeConfigError.malformed
            }
            if updated == current { return }

            do {
                try fileOperator.replaceAuthFile(with: updated, ifCurrentMatches: current)
                return
            } catch AtomicAuthFileError.conflict {
                continue
            } catch {
                throw ClaudeConfigError.writeFailed
            }
        }
        throw ClaudeConfigError.conflict
    }

    private func read() throws -> Data? {
        do {
            return try fileOperator.readAuthFile()
        } catch {
            throw ClaudeConfigError.malformed
        }
    }

    private func root(from data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeConfigError.malformed
        }
        return root
    }
}
