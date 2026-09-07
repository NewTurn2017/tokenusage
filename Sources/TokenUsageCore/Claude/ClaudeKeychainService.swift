import CryptoKit
import Foundation

public enum ClaudeKeychainService {
    public static let defaultService = "Claude Code-credentials"

    /// The Keychain item Claude Code uses for a given configuration directory.
    ///
    /// Claude Code appends the first eight hex characters of the SHA-256 of the NFC-normalized
    /// configuration directory path, and appends nothing at all for the default directory.
    /// Reproducing that exactly is what lets a sign-in performed in a throwaway directory be read
    /// back without touching the signed-in account.
    public static func service(
        forConfigurationDirectory configurationDirectory: URL?,
        defaultService: String = ClaudeKeychainService.defaultService
    ) -> String {
        guard let configurationDirectory else { return defaultService }
        let path = configurationDirectory.path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(path.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(defaultService)-\(suffix)"
    }
}

/// Reads and discards the Keychain item behind a throwaway sign-in.
public protocol ClaudeIsolatedCredentialAccessing: Sendable {
    func readEnvelope(service: String) throws -> Data?
    func remove(service: String) throws
}

public struct SecurityCLIIsolatedClaudeCredentials: ClaudeIsolatedCredentialAccessing, Sendable {
    private let runner: any SecurityCLIProcessRunning
    private let writer: any SecurityCLIPasswordWriting
    private let account: String

    public init(account: String = NSUserName()) {
        self.init(
            runner: SystemSecurityCLIProcessRunner(),
            writer: SystemSecurityCLIPasswordWriter(),
            account: account
        )
    }

    public init(
        runner: any SecurityCLIProcessRunning,
        writer: any SecurityCLIPasswordWriting,
        account: String = NSUserName()
    ) {
        self.runner = runner
        self.writer = writer
        self.account = account
    }

    public func readEnvelope(service: String) throws -> Data? {
        try SecurityCLIClaudeLiveCredentialOperator(
            runner: runner,
            writer: writer,
            service: service,
            account: account
        ).readEnvelope()
    }

    public func remove(service: String) throws {
        try writer.deleteGenericPassword(service: service, account: account)
    }
}
