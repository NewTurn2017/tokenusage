import Foundation

struct CodexLoginAttemptPresentation: Equatable, Sendable {
    let status: String?
    let reopenActionTitle: String?
    let cancelActionTitle: String?
    let canReopenSignIn: Bool
    let canCancel: Bool
}

final class CodexLoginAttemptController: @unchecked Sendable {
    private struct Attempt {
        let cancel: @Sendable () -> Void
        var authURL: URL?
        var browserOpener: (@Sendable (URL) -> Bool)?
    }

    private let lock = NSLock()
    private var attempt: Attempt?

    var presentation: CodexLoginAttemptPresentation {
        lock.withLock {
            CodexLoginAttemptPresentation(
                status: attempt == nil ? nil : "Sign-in is in progress.",
                reopenActionTitle: attempt?.authURL == nil ? nil : "Reopen sign-in",
                cancelActionTitle: attempt == nil ? nil : "Cancel",
                canReopenSignIn: attempt?.authURL != nil,
                canCancel: attempt != nil
            )
        }
    }

    func begin(cancel: @escaping @Sendable () -> Void) {
        lock.withLock { attempt = Attempt(cancel: cancel) }
    }

    /// Records the sign-in page without visiting it, for a CLI that opens the browser itself.
    /// Only the "Reopen sign-in" affordance needs it then.
    func registerSignInURL(
        _ url: URL,
        using browserOpener: @escaping @Sendable (URL) -> Bool
    ) {
        lock.withLock {
            attempt?.authURL = url
            attempt?.browserOpener = browserOpener
        }
    }

    func open(_ url: URL, using browserOpener: @escaping @Sendable (URL) -> Bool) -> Bool {
        lock.withLock {
            attempt?.authURL = url
            attempt?.browserOpener = browserOpener
        }
        return browserOpener(url)
    }

    @discardableResult
    func reopenSignIn() -> Bool {
        let action = lock.withLock { attempt.flatMap { attempt in
            attempt.authURL.flatMap { url in
                attempt.browserOpener.map { opener in (url, opener) }
            }
        } }
        guard let (url, opener) = action else { return false }
        return opener(url)
    }

    func cancelSignIn() {
        lock.withLock { attempt?.cancel }?()
    }

    func clear() {
        lock.withLock { attempt = nil }
    }

    func clearForPopoverClose() {
        clear()
    }
}
