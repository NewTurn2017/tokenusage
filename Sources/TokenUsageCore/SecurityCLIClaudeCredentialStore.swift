import Foundation

public enum SecurityCLIClaudeCredentialStoreError: Error, Equatable, Sendable, LocalizedError {
    case credentialUnavailable

    public var errorDescription: String? {
        "Claude credentials are unavailable."
    }
}

public struct SecurityCLIClaudeCredentialStore: CredentialStoring, AsyncCredentialReading, Sendable {
    private static let securityExecutable = URL(fileURLWithPath: "/usr/bin/security")
    private static let service = "Claude Code-credentials"
    private let runner: any SecurityCLIProcessRunning

    public init() {
        runner = SystemSecurityCLIProcessRunner()
    }

    public init(runner: any SecurityCLIProcessRunning) {
        self.runner = runner
    }

    public func credential(named name: String) throws -> Data? {
        guard !name.isEmpty else { throw credentialError }
        let result: SecurityCLIProcessResult
        do {
            result = try runner.run(
                executable: Self.securityExecutable,
                arguments: Self.securityArguments
            )
        } catch {
            throw credentialError
        }
        return try credential(from: result)
    }

    public func credential(named name: String) async throws -> Data? {
        guard !name.isEmpty else { throw credentialError }
        let result: SecurityCLIProcessResult
        do {
            result = try await runner.runCancellable(
                executable: Self.securityExecutable,
                arguments: Self.securityArguments
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw credentialError
        }
        return try credential(from: result)
    }

    public func storeCredential(_ credential: Data, named name: String) throws {
        throw credentialError
    }

    public func removeCredential(named name: String) throws {
        throw credentialError
    }

    private static var securityArguments: [String] {
        ["find-generic-password", "-s", service, "-w"]
    }

    private var credentialError: SecurityCLIClaudeCredentialStoreError {
        .credentialUnavailable
    }

    private func credential(from result: SecurityCLIProcessResult) throws -> Data {
        guard result.terminationStatus == 0 else { throw credentialError }
        var credential = result.stdout
        if credential.last == 0x0A { credential.removeLast() }
        guard !credential.isEmpty else { throw credentialError }
        return credential
    }
}
