import Foundation

public enum ClaudeLoginOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed(terminationStatus: Int32)
}

/// Runs `claude auth login` against a throwaway configuration directory, so adding an account
/// never signs the current one out.
public protocol ClaudeLoginRunning: Sendable {
    func runClaudeLogin(configurationDirectory: URL) async throws -> ClaudeLoginOutcome
}
