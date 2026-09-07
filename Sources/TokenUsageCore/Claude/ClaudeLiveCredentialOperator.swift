import Foundation

public enum ClaudeLiveCredentialError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case conflict
    case writeFailed
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Claude Code 자격 증명을 읽을 수 없습니다."
        case .conflict:
            "전환하는 사이에 Claude Code 계정이 바뀌었습니다."
        case .writeFailed:
            "Claude Code 자격 증명을 바꾸지 못했습니다."
        case .verificationFailed:
            "바뀐 Claude Code 자격 증명을 확인하지 못했습니다."
        }
    }
}

/// Reads and replaces the credential blob that Claude Code itself uses.
public protocol ClaudeLiveCredentialOperating: Sendable {
    func readEnvelope() throws -> Data?
    func replaceEnvelope(with data: Data, ifCurrentMatches expected: Data?) throws
}

public struct SecurityCLIClaudeLiveCredentialOperator: ClaudeLiveCredentialOperating, Sendable {
    public static let service = "Claude Code-credentials"

    private static let securityExecutable = URL(fileURLWithPath: "/usr/bin/security")

    private let runner: any SecurityCLIProcessRunning
    private let writer: any SecurityCLIPasswordWriting
    private let service: String
    private let account: String

    public init(
        service: String = SecurityCLIClaudeLiveCredentialOperator.service,
        account: String = NSUserName()
    ) {
        self.init(
            runner: SystemSecurityCLIProcessRunner(),
            writer: SystemSecurityCLIPasswordWriter(),
            service: service,
            account: account
        )
    }

    public init(
        runner: any SecurityCLIProcessRunning,
        writer: any SecurityCLIPasswordWriting,
        service: String = SecurityCLIClaudeLiveCredentialOperator.service,
        account: String = NSUserName()
    ) {
        self.runner = runner
        self.writer = writer
        self.service = service
        self.account = account
    }

    public func readEnvelope() throws -> Data? {
        let result: SecurityCLIProcessResult
        do {
            result = try runner.run(
                executable: Self.securityExecutable,
                arguments: ["find-generic-password", "-s", service, "-a", account, "-w"]
            )
        } catch {
            throw ClaudeLiveCredentialError.unavailable
        }
        guard result.terminationStatus == 0 else { return nil }
        var payload = result.stdout
        if payload.last == 0x0A { payload.removeLast() }
        return payload.isEmpty ? nil : payload
    }

    public func replaceEnvelope(with data: Data, ifCurrentMatches expected: Data?) throws {
        let current = try readEnvelope()
        guard current == expected else { throw ClaudeLiveCredentialError.conflict }
        // `-U` updates in place; it would otherwise add a second item that Claude Code ignores.
        guard current != nil else { throw ClaudeLiveCredentialError.unavailable }
        guard current != data else { return }

        do {
            try writer.writeGenericPassword(service: service, account: account, password: data)
        } catch {
            throw ClaudeLiveCredentialError.writeFailed
        }
        guard try readEnvelope() == data else {
            throw ClaudeLiveCredentialError.verificationFailed
        }
    }
}
