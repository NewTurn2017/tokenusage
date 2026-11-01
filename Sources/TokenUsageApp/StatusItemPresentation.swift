import Foundation
import TokenUsageCore

struct StatusItemClaudeProfileState: Equatable, Sendable {
    let profileID: String
    let name: String
    let state: UsageState
}

enum StatusItemClaudeWindow: Equatable, Sendable {
    case fiveHour
    case weekly
    case fableWeekly

    var accessibilityName: String {
        switch self {
        case .fiveHour: "five hour"
        case .weekly: "weekly"
        case .fableWeekly: "Fable weekly"
        }
    }
}

/// One account's column: the first two limits its plan reports. 5-hour over weekly on Pro and
/// Max, 5-hour over Fable on Team (no all-model weekly limit), weekly over Fable on Ultra (no
/// 5-hour limit).
struct StatusItemClaudeProfile: Equatable, Sendable {
    let profileID: String
    let name: String
    let upperText: String
    let upperWindow: StatusItemClaudeWindow
    let lowerText: String
    let lowerWindow: StatusItemClaudeWindow
}

struct StatusItemCodexProfileState: Equatable, Sendable {
    let profileID: String
    let name: String
    let state: UsageState
}

struct StatusItemCodexProfile: Equatable, Sendable {
    let profileID: String
    let name: String
    let weeklyText: String
}

struct StatusItemPresentation: Equatable, Sendable {
    static let claudeMark = "✳"
    static let codexMark = "◎"
    static let openRouterMark = "◑"
    static let staleIndicator = "•"

    /// One column per signed-in Claude account, each stacking the first two limits its plan
    /// reports (see `StatusItemClaudeProfile`).
    let claudeProfiles: [StatusItemClaudeProfile]
    let codexProfiles: [StatusItemCodexProfile]
    /// nil when OpenRouter has no key or its balance could not be read; the label stays hidden then.
    let openRouterBalanceText: String?
    let isStale: Bool

    var claudeUpperText: String {
        claudeProfiles.first?.upperText ?? "--"
    }

    var claudeLowerText: String {
        claudeProfiles.first?.lowerText ?? "--"
    }

    var codexWeeklyTexts: [String] {
        codexProfiles.map(\.weeklyText)
    }

    var visibleLabels: [String] {
        claudeProfiles.flatMap { [$0.upperText, $0.lowerText] }
            + codexWeeklyTexts
            + [openRouterBalanceText].compactMap { $0 }
    }

    var staleIndicatorText: String? {
        isStale ? Self.staleIndicator : nil
    }

    init(
        claudeProfiles: [StatusItemClaudeProfileState],
        codexProfiles: [StatusItemCodexProfileState],
        openRouter: OpenRouterUsageState = .notConfigured(message: "")
    ) {
        let claudeContents = claudeProfiles.map { Self.content(from: $0.state) }
        let codexContents = codexProfiles.map { Self.content(from: $0.state) }

        self.claudeProfiles = zip(claudeProfiles, claudeContents).map { profile, content in
            let windows = Self.claudeWindows(in: content.snapshot)
            let upper = windows[0]
            let lower = windows.count > 1 ? windows[1] : (window: .fableWeekly, value: nil)
            return StatusItemClaudeProfile(
                profileID: profile.profileID,
                name: profile.name,
                upperText: Self.label(value: upper.value),
                upperWindow: upper.window,
                lowerText: Self.label(value: lower.value),
                lowerWindow: lower.window
            )
        }
        self.codexProfiles = zip(codexProfiles, codexContents).map { profile, content in
            StatusItemCodexProfile(
                profileID: profile.profileID,
                name: profile.name,
                weeklyText: Self.label(value: content.snapshot?.weekly)
            )
        }
        openRouterBalanceText = Self.balanceLabel(from: openRouter)
        isStale = claudeContents.contains { $0.isStale } || codexContents.contains { $0.isStale }
    }

    /// Single-account form, used before any Claude profile has been captured.
    init(
        claude: UsageState,
        codexProfiles: [StatusItemCodexProfileState],
        openRouter: OpenRouterUsageState = .notConfigured(message: "")
    ) {
        self.init(
            claudeProfiles: [
                StatusItemClaudeProfileState(profileID: "", name: "Claude", state: claude)
            ],
            codexProfiles: codexProfiles,
            openRouter: openRouter
        )
    }

    /// The limits an account's plan reports, in display order, with the same rule as the popover
    /// rows: the 5-hour placeholder goes only when the plan reports another limit, and the weekly
    /// one only when Fable stands in for it.
    private static func claudeWindows(
        in snapshot: UsageSnapshot?
    ) -> [(window: StatusItemClaudeWindow, value: QuotaWindow?)] {
        let fable = snapshot?.fableWeekly
        let reportsLimit = snapshot?.weekly != nil || fable != nil
        var windows: [(window: StatusItemClaudeWindow, value: QuotaWindow?)] = []
        if snapshot?.fiveHour != nil || !reportsLimit {
            windows.append((.fiveHour, snapshot?.fiveHour))
        }
        if snapshot?.weekly != nil || fable == nil {
            windows.append((.weekly, snapshot?.weekly))
        }
        if let fable {
            windows.append((.fableWeekly, fable))
        }
        return windows
    }

    private static func balanceLabel(from state: OpenRouterUsageState) -> String? {
        let remaining: Double
        switch state {
        case let .fresh(snapshot):
            remaining = snapshot.remaining
        case let .stale(lastGood, _):
            remaining = lastGood.remaining
        case .unavailable, .notConfigured:
            return nil
        }
        guard remaining.isFinite else { return nil }
        return String(
            format: "$%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            max(0, remaining)
        )
    }

    private static func content(from state: UsageState) -> (snapshot: UsageSnapshot?, isStale: Bool) {
        switch state {
        case let .fresh(snapshot):
            return (snapshot, false)
        case let .stale(lastGood, _):
            return (lastGood, true)
        case .unavailable:
            return (nil, false)
        }
    }

    private static func label(value: QuotaWindow?) -> String {
        guard let remaining = value?.remainingPercent,
              remaining.isFinite,
              remaining <= 100
        else {
            return "--"
        }

        return "\(Int(max(0, remaining).rounded()))%"
    }
}
