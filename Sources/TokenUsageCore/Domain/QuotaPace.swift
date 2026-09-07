import Foundation

/// How fast the quota is being spent relative to how much of the window is left.
///
/// Half a weekly quota left is healthy mid-week and alarming on Monday, so the raw remaining
/// percentage cannot answer "am I going too fast?" on its own. Comparing it against the share of
/// the window that is still ahead can.
public enum QuotaPace: Equatable, Sendable {
    /// Spending faster than the window allows.
    case overspending
    /// Spending roughly in step with the window.
    case onTrack
    /// Spending slower than the window allows.
    case comfortable
    /// Nothing left.
    case exhausted
    /// Not enough information to judge — no reset instant, no window length, or a window that
    /// already elapsed.
    case unknown
}

public extension QuotaWindow {
    /// How far actual and expected remaining percentages may diverge before the pace is called
    /// fast or slow. Wide enough that ordinary bursts do not flip the colour on every refresh.
    static let paceTolerancePercentagePoints = 10.0

    /// The share of the quota that should still be left if it were spent evenly across the window.
    func expectedRemainingPercent(now: Date) -> Double? {
        guard let resetsAt, let windowDuration, windowDuration > 0 else { return nil }
        let secondsLeft = resetsAt.timeIntervalSince(now)
        guard secondsLeft > 0 else { return nil }
        return min(100, secondsLeft / windowDuration * 100)
    }

    func pace(now: Date) -> QuotaPace {
        guard remainingPercent.isFinite else { return .unknown }
        if remainingPercent <= 0 { return .exhausted }
        guard let expected = expectedRemainingPercent(now: now) else { return .unknown }

        let delta = remainingPercent - expected
        if delta <= -Self.paceTolerancePercentagePoints { return .overspending }
        if delta >= Self.paceTolerancePercentagePoints { return .comfortable }
        return .onTrack
    }
}
