import Foundation

public enum UsageWarning: Equatable, Sendable {
    case providerUsedPercentOutOfRange(window: QuotaWindowKind, value: Int)
}

public struct CodexCredits: Equatable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: Double?

    public init(hasCredits: Bool, unlimited: Bool, balance: Double? = nil) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let fiveHour: QuotaWindow?
    public let weekly: QuotaWindow?
    public let fableWeekly: QuotaWindow?
    public let rateLimitResetCreditsAvailableCount: Int?
    /// When the soonest-expiring reset credit lapses; nil when the provider reports no deadline.
    public let rateLimitResetCreditsExpireAt: Date?
    public let codexCredits: CodexCredits?
    public let warnings: [UsageWarning]

    public init(
        capturedAt: Date,
        fiveHour: QuotaWindow? = nil,
        weekly: QuotaWindow? = nil,
        fableWeekly: QuotaWindow? = nil,
        rateLimitResetCreditsAvailableCount: Int? = nil,
        rateLimitResetCreditsExpireAt: Date? = nil,
        codexCredits: CodexCredits? = nil,
        warnings: [UsageWarning] = []
    ) {
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fableWeekly = fableWeekly
        self.rateLimitResetCreditsAvailableCount = rateLimitResetCreditsAvailableCount
        self.rateLimitResetCreditsExpireAt = rateLimitResetCreditsExpireAt
        self.codexCredits = codexCredits
        self.warnings = warnings
    }
}
