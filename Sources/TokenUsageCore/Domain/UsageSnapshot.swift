import Foundation

public enum UsageWarning: Equatable, Sendable {
    case providerUsedPercentOutOfRange(window: QuotaWindowKind, value: Int)
}

public struct UsageSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let fiveHour: QuotaWindow?
    public let weekly: QuotaWindow?
    public let fableWeekly: QuotaWindow?
    public let rateLimitResetCreditsAvailableCount: Int?
    public let warnings: [UsageWarning]

    public init(
        capturedAt: Date,
        fiveHour: QuotaWindow? = nil,
        weekly: QuotaWindow? = nil,
        fableWeekly: QuotaWindow? = nil,
        rateLimitResetCreditsAvailableCount: Int? = nil,
        warnings: [UsageWarning] = []
    ) {
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fableWeekly = fableWeekly
        self.rateLimitResetCreditsAvailableCount = rateLimitResetCreditsAvailableCount
        self.warnings = warnings
    }
}
