import Foundation

public protocol UsageProviding: Sendable {
    associatedtype Usage: Sendable

    func usage() async throws -> Usage
}

public protocol CredentialStoring: Sendable {
    func credential(named name: String) throws -> Data?
    func storeCredential(_ credential: Data, named name: String) throws
    func removeCredential(named name: String) throws
}

public protocol AsyncCredentialReading: Sendable {
    func credential(named name: String) async throws -> Data?
}

public protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}

public protocol GenericPasswordClient: Sendable {
    func copyGenericPassword(service: String, account: String) throws -> Data?
    func upsertGenericPassword(data: Data, service: String, account: String) throws
    func removeGenericPassword(service: String, account: String) throws
}

public protocol JSONRPCProcessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        request: Data
    ) async throws -> Data
}

public protocol CodexAccountValidating: Sendable {
    associatedtype Account: Sendable

    func validate(codexHome: URL) async throws -> Account
}

public struct CodexLoginDiagnostic: Equatable, Sendable {
    public let stdout: String
    public let stderr: String

    public init(stdout: String, stderr: String) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CodexLoginOutcome: Equatable, Sendable {
    case completed(terminationStatus: Int32, diagnostic: CodexLoginDiagnostic)
    case cancelled(terminationStatus: Int32, diagnostic: CodexLoginDiagnostic)
    case browserOpenFailed(terminationStatus: Int32, diagnostic: CodexLoginDiagnostic)
    case failed(terminationStatus: Int32, diagnostic: CodexLoginDiagnostic)

    public var terminationStatus: Int32 {
        switch self {
        case let .completed(status, _), let .cancelled(status, _),
             let .browserOpenFailed(status, _), let .failed(status, _):
            status
        }
    }

    public var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

public protocol CodexLoginRunning: Sendable {
    func runCodexLogin(codexHome: URL) async throws -> CodexLoginOutcome
}

public protocol AuthFileOperating: Sendable {
    func readAuthFile() throws -> Data?
    func replaceAuthFile(with data: Data, ifCurrentMatches expectedData: Data?) throws
    func restoreAuthFile(to data: Data?, ifCurrentMatches expectedData: Data?) throws
}

public protocol RefreshClock: Sendable {
    func sleep(for duration: Duration) async throws
}
