import Foundation

/// What a phone sees: the popover's already-formatted values, without tokens, e-mail addresses,
/// or profile IDs, so the document is safe to hand to anything on the tailnet that holds the key.
public struct MobileUsageDocument: Encodable, Equatable, Sendable {
    public struct Window: Encodable, Equatable, Sendable {
        public let label: String
        /// Remaining percentage, 0...100; nil when the provider reported nothing.
        public let percent: Int?
        public let remaining: String
        public let reset: String
        public let pace: String?

        private enum CodingKeys: String, CodingKey {
            case label, percent, remaining, reset, pace
        }

        /// Writes a missing value as an explicit `null`; the synthesized encoder drops the key,
        /// which reaches the page as `undefined` and rendered as "undefined%".
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(label, forKey: .label)
            try container.encode(percent, forKey: .percent)
            try container.encode(remaining, forKey: .remaining)
            try container.encode(reset, forKey: .reset)
            try container.encode(pace, forKey: .pace)
        }
    }

    public struct Coupon: Encodable, Equatable, Sendable {
        public let text: String
        public let expiry: String?
    }

    public struct ClaudeAccount: Encodable, Equatable, Sendable {
        public let name: String
        public let active: Bool
        public let freshness: String
        public let fiveHour: Window
        /// Always present, because pasted widgets read `weekly.percent` directly.
        public let weekly: Window
        public let fable: Window?
        /// What to draw, in order: 5-hour, then whichever weekly limits the plan reports.
        public let windows: [Window]
        public let coupon: Coupon?
    }

    public struct CodexAccount: Encodable, Equatable, Sendable {
        public let name: String
        public let active: Bool
        public let freshness: String
        public let weekly: Window
        public let coupon: Coupon?
    }

    public struct OpenRouter: Encodable, Equatable, Sendable {
        public let status: String
        public let remaining: String
        public let used: String
        public let allowanceLabel: String
        public let allowance: String
    }

    public let refreshedAt: Date?
    public let refreshedText: String
    public let status: String
    public let error: String?
    public let claude: [ClaudeAccount]
    public let codex: [CodexAccount]
    public let openRouter: OpenRouter?

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

extension AppViewModel {
    public func mobileUsageDocument() -> MobileUsageDocument {
        let claude: [MobileUsageDocument.ClaudeAccount]
        if claudeQuotaRows.isEmpty {
            let fable = claudeFableWeekly.remainingFraction == nil ? nil : claudeFableWeekly
            let windows = ClaudeProfileQuotaPresentation.displayedWindows(
                fiveHour: claudeFiveHour,
                weekly: claudeWeekly,
                fable: fable,
                reportsWeekly: claudeWeekly.remainingFraction != nil
            )
            claude = [
                MobileUsageDocument.ClaudeAccount(
                    name: "Claude",
                    active: true,
                    freshness: "",
                    fiveHour: Self.mobileWindow(claudeFiveHour),
                    weekly: Self.mobileWindow(claudeWeekly),
                    fable: fable.map(Self.mobileWindow),
                    windows: windows.map(Self.mobileWindow),
                    coupon: claudeResetCoupon.map(Self.mobileCoupon)
                ),
            ]
        } else {
            claude = claudeQuotaRows.map { row in
                MobileUsageDocument.ClaudeAccount(
                    name: row.name,
                    active: row.isActive,
                    freshness: row.freshnessText,
                    fiveHour: Self.mobileWindow(row.fiveHour),
                    weekly: Self.mobileWindow(row.weekly),
                    fable: row.fable.map(Self.mobileWindow),
                    windows: row.windows.map(Self.mobileWindow),
                    coupon: row.resetCoupon.map(Self.mobileCoupon)
                )
            }
        }

        let codex: [MobileUsageDocument.CodexAccount]
        if codexQuotaRows.isEmpty {
            codex = [
                MobileUsageDocument.CodexAccount(
                    name: "Codex",
                    active: true,
                    freshness: "",
                    weekly: Self.mobileWindow(codexWeekly),
                    coupon: nil
                ),
            ]
        } else {
            codex = codexQuotaRows.map { row in
                MobileUsageDocument.CodexAccount(
                    name: row.name,
                    active: row.isActive,
                    freshness: row.freshnessText,
                    weekly: Self.mobileWindow(row.quota),
                    coupon: row.resetCouponText.map {
                        MobileUsageDocument.Coupon(
                            text: $0.replacingOccurrences(of: "초기화 ", with: ""),
                            expiry: nil
                        )
                    }
                )
            }
        }

        let balance = openRouterBalance
        let openRouter = balance.status == .notConfigured
            ? nil
            : MobileUsageDocument.OpenRouter(
                status: balance.freshnessText,
                remaining: balance.remaining,
                used: balance.used,
                allowanceLabel: balance.allowanceLabel,
                allowance: balance.allowance
            )

        return MobileUsageDocument(
            refreshedAt: lastRefreshAt,
            refreshedText: lastRefreshText,
            status: statusText,
            error: errorText,
            claude: claude,
            codex: codex,
            openRouter: openRouter
        )
    }

    private static func mobileWindow(_ window: QuotaWindowPresentation) -> MobileUsageDocument.Window {
        MobileUsageDocument.Window(
            label: window.window,
            percent: window.remainingFraction.map { Int(($0 * 100).rounded()) },
            remaining: window.remaining,
            reset: window.reset,
            pace: window.paceText
        )
    }

    private static func mobileCoupon(_ coupon: ResetCouponPresentation) -> MobileUsageDocument.Coupon {
        MobileUsageDocument.Coupon(text: coupon.countText, expiry: coupon.expiryText)
    }
}
