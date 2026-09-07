import Foundation

public enum QuotaWindowKind: String, Equatable, Sendable {
    case fiveHour
    case weekly
    case fableWeekly

    /// Providers report a reset instant but not the window length, so the length comes from the
    /// window kind. Codex only accepts buckets whose reported duration equals the weekly constant,
    /// which keeps this mapping exact rather than approximate.
    public var duration: TimeInterval {
        switch self {
        case .fiveHour:
            5 * 60 * 60
        case .weekly, .fableWeekly:
            7 * 24 * 60 * 60
        }
    }
}

public typealias UsageWindow = QuotaWindowKind

public struct QuotaWindow: Equatable, Sendable {
    public let remainingPercent: Double
    public let resetsAt: Date?
    public let windowDuration: TimeInterval?

    public init(
        remainingPercent: Double,
        resetsAt: Date?,
        windowDuration: TimeInterval? = nil
    ) {
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.windowDuration = windowDuration
    }
}
