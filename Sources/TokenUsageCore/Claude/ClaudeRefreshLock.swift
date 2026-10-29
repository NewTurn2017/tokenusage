import Darwin
import Foundation

/// A held refresh lock; `release` gives it back.
public struct ClaudeRefreshLease: Sendable {
    public let release: @Sendable () -> Void

    public init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }
}

/// The lock Claude Code takes around a token renewal in a configuration directory.
///
/// Every Claude Code process in a directory renews the same Keychain item. Each one takes this
/// lock, reads the item again, and adopts a token another process already renewed instead of
/// spending the refresh token a second time. Taking the same lock lets this app renew a directory
/// nobody is running, without racing a session that is.
public protocol ClaudeRefreshLocking: Sendable {
    /// nil while another process holds the lock.
    func acquire(configurationDirectory: URL) -> ClaudeRefreshLease?
}

/// Claude Code's own lock files: `.oauth_refresh.lock` inside the directory, plus the
/// `<directory>.lock` that older Claude Code versions take. Both are `proper-lockfile` locks - a
/// directory whose holder refreshes its modification date every few seconds and that anyone may
/// take over once it has gone a minute without one.
public struct DirectoryClaudeRefreshLock: ClaudeRefreshLocking, Sendable {
    static let staleInterval: TimeInterval = 60

    private enum Outcome {
        case acquired
        case held
        case failed
    }

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func acquire(configurationDirectory: URL) -> ClaudeRefreshLease? {
        let current = configurationDirectory
            .appendingPathComponent(".oauth_refresh.lock", isDirectory: true).path
        let legacy = configurationDirectory.resolvingSymlinksInPath().path + ".lock"
        guard lock(current) == .acquired else { return nil }
        // Claude Code itself goes ahead when only the legacy lock cannot be created.
        switch lock(legacy) {
        case .acquired:
            return ClaudeRefreshLease {
                rmdir(legacy)
                rmdir(current)
            }
        case .failed:
            return ClaudeRefreshLease { rmdir(current) }
        case .held:
            rmdir(current)
            return nil
        }
    }

    private func lock(_ path: String) -> Outcome {
        if mkdir(path, 0o755) == 0 { return .acquired }
        guard errno == EEXIST else { return .failed }
        // A holder that died left its lock behind. `rmdir` refuses a lock that is not empty,
        // which leaves anything unfamiliar to Claude Code's own takeover.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              now().timeIntervalSince(modified) > Self.staleInterval,
              rmdir(path) == 0,
              mkdir(path, 0o755) == 0
        else {
            return .held
        }
        return .acquired
    }
}
