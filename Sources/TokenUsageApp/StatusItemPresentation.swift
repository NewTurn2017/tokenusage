import Foundation
import TokenUsageCore

struct StatusItemClaudeProfileState: Equatable, Sendable {
    let profileID: String
    let name: String
    let state: UsageState
}

struct StatusItemClaudeProfile: Equatable, Sendable {
    let profileID: String
    let name: String
    let fiveHourText: String
    let weeklyText: String
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

    /// One column per signed-in Claude account, each stacking 5-hour over weekly remaining.
    let claudeProfiles: [StatusItemClaudeProfile]
    let codexProfiles: [StatusItemCodexProfile]
    /// nil when OpenRouter has no key or its balance could not be read; the label stays hidden then.
    let openRouterBalanceText: String?
    let isStale: Bool

    var claudeFiveHourText: String {
        claudeProfiles.first?.fiveHourText ?? "--"
    }

    var claudeWeeklyText: String {
        claudeProfiles.first?.weeklyText ?? "--"
    }

    var codexWeeklyTexts: [String] {
        codexProfiles.map(\.weeklyText)
    }

    var visibleLabels: [String] {
        claudeProfiles.flatMap { [$0.fiveHourText, $0.weeklyText] }
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
            StatusItemClaudeProfile(
                profileID: profile.profileID,
                name: profile.name,
                fiveHourText: Self.label(value: content.snapshot?.fiveHour),
                weeklyText: Self.label(value: content.snapshot?.weekly)
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
