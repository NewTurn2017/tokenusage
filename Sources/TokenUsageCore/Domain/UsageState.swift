import Foundation

public enum UsageState: Equatable, Sendable {
    case fresh(UsageSnapshot)
    case stale(lastGood: UsageSnapshot, message: String)
    case unavailable(message: String)

    public static func refreshFailed(message: String, previous: UsageState?) -> UsageState {
        switch previous {
        case let .fresh(snapshot):
            return .stale(lastGood: snapshot, message: message)
        case let .stale(lastGood, _):
            return .stale(lastGood: lastGood, message: message)
        case .unavailable, .none:
            return .unavailable(message: message)
        }
    }
}
