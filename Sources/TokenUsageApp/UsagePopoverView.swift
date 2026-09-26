import AppKit
import SwiftUI
import TokenUsageCore

enum ProviderMark: String, Sendable {
    case anthropic = "Anthropic"
    case openAI = "OpenAI"

    var resourceName: String { rawValue }

    var provider: PopoverDesignSystem.Provider {
        switch self {
        case .anthropic:
            .claude
        case .openAI:
            .codex
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .anthropic:
            "provider-anthropic-icon"
        case .openAI:
            "provider-openai-icon"
        }
    }

    @MainActor
    func image(in bundle: Bundle = .main) -> NSImage? {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: "svg",
            subdirectory: "ProviderIcons"
        ) else {
            return nil
        }
        return image(at: url)
    }

    @MainActor
    func image(at url: URL) -> NSImage? {
        guard let source = NSImage(contentsOf: url),
            let image = source.copy() as? NSImage
        else {
            return nil
        }
        image.isTemplate = true
        return image
    }
}

struct ProviderMarkView: View {
    let mark: ProviderMark

    var body: some View {
        Group {
            if let image = mark.image() ?? mark.image(in: .module) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .imageScale(.small)
            }
        }
        .frame(
            width: PopoverDesignSystem.Size.providerIcon,
            height: PopoverDesignSystem.Size.providerIcon
        )
        .foregroundStyle(mark.provider.accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mark.rawValue)
        .accessibilityIdentifier(mark.accessibilityIdentifier)
    }

    private var fallbackSymbol: String {
        switch mark {
        case .anthropic:
            "sparkles"
        case .openAI:
            "circle.hexagongrid"
        }
    }
}

public struct UsagePopoverView: View {
    @ObservedObject private var model: AppViewModel

    public init(model: AppViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.small) {
            PopoverHeader(model: model)
            ClaudeQuotaSection(model: model)
            CodexQuotaSection(model: model)
            OpenRouterQuotaSection(model: model)
            RefreshStatus(model: model)
            Divider()
            PopoverActions(model: model)
        }
        .padding(PopoverDesignSystem.Spacing.medium)
        .frame(width: PopoverDesignSystem.Size.popoverWidth)
        .font(PopoverDesignSystem.Typography.body)
        .task { model.start() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Token Usage 사용량 창")
        .accessibilityIdentifier("usage-popover-window")
    }
}

private struct PopoverHeader: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopoverDesignSystem.Spacing.small) {
            Text("남은 사용량")
                .font(PopoverDesignSystem.Typography.title)
            Text(model.statusText)
                .font(PopoverDesignSystem.Typography.detail)
                .foregroundStyle(statusColor)
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("사용량 새로고침 중")
            }
        }
    }

    private var statusColor: Color {
        model.errorText == nil
            ? PopoverDesignSystem.Palette.secondary
            : PopoverDesignSystem.Palette.warning
    }
}

private struct ProfileDeletionTarget: Equatable {
    let id: String
    let name: String
}

private struct ClaudeQuotaSection: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.small) {
            HStack(spacing: PopoverDesignSystem.Spacing.small) {
                ProviderMarkView(mark: .anthropic)
                Text("Claude")
                    .font(PopoverDesignSystem.Typography.section)
                if model.claudeQuotaRows.isEmpty, let coupon = model.claudeResetCoupon {
                    ClaudeCouponBadge(coupon: coupon, accessibilityIdentifier: "claude-reset-coupon")
                }
                Spacer(minLength: 0)
                if !model.claudeProfiles.isEmpty {
                    Picker("계정", selection: profileSelection) {
                        ForEach(model.claudeProfiles, id: \.id) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityLabel("사용 중인 Claude 계정")
                    .accessibilityValue(model.activeClaudeProfileName)
                    .accessibilityIdentifier("claude-profile-picker")
                    .disabled(model.isPerformingProfileAction)
                }
            }

            if model.claudeQuotaRows.isEmpty {
                CompactQuotaLine(presentation: model.claudeFiveHour, provider: .claude)
                CompactQuotaLine(presentation: model.claudeWeekly, provider: .claude)
                CompactQuotaLine(presentation: model.claudeFableWeekly, provider: .claude)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: PopoverDesignSystem.Spacing.xxSmall) {
                        ForEach(model.claudeQuotaRows) { row in
                            ClaudeProfileQuotaRow(presentation: row) {
                                Task { await model.selectClaudeProfile(id: row.profileID) }
                            }
                            .disabled(model.isPerformingProfileAction)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(
                    maxHeight: ClaudeProfileQuotaListLayout.maximumHeight(
                        rowCount: model.claudeQuotaRows.count
                    )
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Claude 계정 사용량")
                .accessibilityIdentifier("claude-profile-quota-list")

                CompactQuotaLine(
                    presentation: model.claudeFableWeekly,
                    provider: .claude,
                    leadingSymbol: "wand.and.stars"
                )
            }

            ClaudeProfileControls(model: model)
        }
        .providerPanel(.claude)
    }

    private var profileSelection: Binding<String?> {
        Binding(
            get: { model.selectedClaudeProfileID },
            set: { id in
                guard let id else { return }
                Task { await model.selectClaudeProfile(id: id) }
            }
        )
    }
}

enum ClaudeProfileQuotaListLayout {
    static let rowHeight = PopoverDesignSystem.Size.claudeAccountRowHeight
    static let unscrolledRowLimit = 3

    static func maximumHeight(rowCount: Int) -> CGFloat {
        let rows = min(max(rowCount, 1), unscrolledRowLimit)
        return CGFloat(rows) * rowHeight
            + CGFloat(rows - 1) * PopoverDesignSystem.Spacing.xxSmall
    }
}

private struct ClaudeProfileQuotaRow: View {
    let presentation: ClaudeProfileQuotaPresentation
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.xSmall) {
                HStack(spacing: PopoverDesignSystem.Spacing.small) {
                    Text(presentation.name)
                        .font(PopoverDesignSystem.Typography.section)
                        .lineLimit(1)
                        .layoutPriority(2)
                    if let email = presentation.emailAddress {
                        Text(email)
                            .font(PopoverDesignSystem.Typography.detail)
                            .foregroundStyle(PopoverDesignSystem.Palette.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if let coupon = presentation.resetCoupon {
                        ClaudeCouponBadge(
                            coupon: coupon,
                            accessibilityIdentifier: "claude-reset-coupon-\(presentation.profileID)"
                        )
                    }
                    if presentation.isActive {
                        ActiveBadge(provider: .claude)
                    }
                    // A coupon badge can crowd the header; the name truncates, not the freshness.
                    FreshnessLabel(text: presentation.freshnessText)
                        .fixedSize()
                }
                HStack(alignment: .top, spacing: PopoverDesignSystem.Spacing.medium) {
                    ClaudeWindowSummary(presentation: presentation.fiveHour)
                    ClaudeWindowSummary(presentation: presentation.weekly)
                }
            }
            .padding(.horizontal, PopoverDesignSystem.Spacing.small)
            .padding(.vertical, PopoverDesignSystem.Spacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ClaudeProfileQuotaListLayout.rowHeight)
            .background(
                RoundedRectangle(
                    cornerRadius: PopoverDesignSystem.Radius.section,
                    style: .continuous
                )
                .fill(
                    presentation.isActive
                        ? PopoverDesignSystem.Provider.claude.accent.opacity(
                            PopoverDesignSystem.Opacity.activeFill
                        )
                        : PopoverDesignSystem.Palette.transparent
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Button(presentation.accessibilityLabel, action: activate)
                .accessibilityIdentifier(presentation.accessibilityIdentifier)
        }
    }
}

private struct ClaudeWindowSummary: View {
    let presentation: QuotaWindowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.xxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: PopoverDesignSystem.Spacing.xSmall) {
                Text(presentation.window)
                    .foregroundStyle(PopoverDesignSystem.Palette.secondary)
                Text(presentation.remaining)
                    .font(PopoverDesignSystem.Typography.metric)
                    .monospacedDigit()
                    .foregroundStyle(quotaColor)
                Spacer(minLength: 0)
                QuotaCue(presentation: presentation, provider: .claude)
            }
            QuotaBar(presentation: presentation, provider: .claude)
            Text(presentation.reset)
                .foregroundStyle(PopoverDesignSystem.Palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(PopoverDesignSystem.Scale.minimumText)
        }
        .font(PopoverDesignSystem.Typography.detail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quotaColor: Color {
        PopoverDesignSystem.Palette.quota(presentation, provider: .claude)
    }
}

private struct CodexQuotaSection: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.small) {
            HStack(spacing: PopoverDesignSystem.Spacing.small) {
                ProviderMarkView(mark: .openAI)
                Text("Codex")
                    .font(PopoverDesignSystem.Typography.section)
                Spacer(minLength: 0)
                Picker("계정", selection: profileSelection) {
                    Text("현재 로그인").tag(Optional<String>.none)
                    ForEach(model.codexProfiles, id: \.id) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("사용 중인 Codex 계정")
                .accessibilityValue(model.activeCodexProfileName)
                .accessibilityIdentifier("codex-profile-picker")
                .disabled(model.isPerformingProfileAction)
            }

            if model.codexQuotaRows.isEmpty {
                CompactQuotaLine(presentation: model.codexWeekly, provider: .codex)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: PopoverDesignSystem.Spacing.xxSmall) {
                        ForEach(model.codexQuotaRows) { row in
                            CodexProfileQuotaRow(presentation: row)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(
                    maxHeight: CodexProfileQuotaListLayout.maximumHeight(
                        rowCount: model.codexQuotaRows.count
                    )
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Codex 프로필 사용량")
                .accessibilityIdentifier("codex-profile-quota-scroll")
            }

            ProfileControls(model: model)
        }
        .providerPanel(.codex)
    }

    private var profileSelection: Binding<String?> {
        Binding(
            get: { model.selectedCodexProfileID },
            set: { id in
                guard let id else { return }
                Task { await model.selectCodexProfile(id: id) }
            }
        )
    }
}

enum CodexProfileQuotaListLayout {
    static let rowHeight = PopoverDesignSystem.Size.codexAccountRowHeight
    static let unscrolledRowLimit = 3

    static func maximumHeight(rowCount: Int) -> CGFloat {
        let rows = min(max(rowCount, 1), unscrolledRowLimit)
        return CGFloat(rows) * rowHeight
            + CGFloat(rows - 1) * PopoverDesignSystem.Spacing.xxSmall
    }
}

private struct CodexProfileQuotaRow: View {
    let presentation: CodexProfileQuotaPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: PopoverDesignSystem.Spacing.small) {
                Text(presentation.name)
                    .font(PopoverDesignSystem.Typography.section)
                    .lineLimit(1)
                    .layoutPriority(1)
                if presentation.isActive {
                    ActiveBadge(provider: .codex)
                }
                Spacer(minLength: 0)
                Text(presentation.quota.remaining)
                    .font(PopoverDesignSystem.Typography.metric)
                    .monospacedDigit()
                    .foregroundStyle(quotaColor)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
                if let resetCouponText = presentation.resetCouponText {
                    CouponBadge(
                        text: resetCouponText.replacingOccurrences(of: "초기화 ", with: ""),
                        provider: .codex,
                        accessibilityIdentifier: "codex-reset-coupon-count-\(presentation.profileID)"
                    )
                }
            }
            HStack(spacing: PopoverDesignSystem.Spacing.small) {
                QuotaBar(presentation: presentation.quota, provider: .codex)
                    .frame(width: PopoverDesignSystem.Size.compactProgressWidth)
                Text(presentation.quota.reset)
                    .lineLimit(1)
                    .minimumScaleFactor(PopoverDesignSystem.Scale.minimumText)
                Spacer(minLength: 0)
                QuotaCue(presentation: presentation.quota, provider: .codex)
                FreshnessLabel(text: presentation.freshnessText)
            }
            .font(PopoverDesignSystem.Typography.detail)
            .foregroundStyle(PopoverDesignSystem.Palette.secondary)
        }
        .padding(.horizontal, PopoverDesignSystem.Spacing.small)
        .padding(.vertical, PopoverDesignSystem.Spacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CodexProfileQuotaListLayout.rowHeight)
        .background(
            RoundedRectangle(
                cornerRadius: PopoverDesignSystem.Radius.section,
                style: .continuous
            )
            .fill(
                presentation.isActive
                    ? PopoverDesignSystem.Provider.codex.accent.opacity(
                        PopoverDesignSystem.Opacity.activeFill
                    )
                    : PopoverDesignSystem.Palette.transparent
            )
        )
        .accessibilityRepresentation {
            Text(presentation.accessibilityLabel)
                .accessibilityIdentifier(presentation.accessibilityIdentifier)
        }
    }

    private var quotaColor: Color {
        PopoverDesignSystem.Palette.quota(presentation.quota, provider: .codex)
    }
}

private struct OpenRouterQuotaSection: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: PopoverDesignSystem.Spacing.small) {
                Image(systemName: "arrow.triangle.branch")
                    .font(PopoverDesignSystem.Typography.detail)
                    .frame(
                        width: PopoverDesignSystem.Size.providerIcon,
                        height: PopoverDesignSystem.Size.providerIcon
                    )
                    .foregroundStyle(PopoverDesignSystem.Provider.openRouter.accent)
                    .accessibilityHidden(true)
                Text("OpenRouter")
                    .font(PopoverDesignSystem.Typography.section)
                Spacer(minLength: 0)
                FreshnessLabel(text: model.openRouterBalance.freshnessText)
            }

            if model.openRouterBalance.status == .notConfigured {
                HStack(spacing: PopoverDesignSystem.Spacing.small) {
                    Label("키 필요", systemImage: "key.fill")
                        .font(PopoverDesignSystem.Typography.metric)
                        .foregroundStyle(PopoverDesignSystem.Provider.openRouter.accent)
                    Text(
                        model.openRouterBalance.message
                            ?? OpenRouterUsageState.notConfiguredHint
                    )
                    .font(PopoverDesignSystem.Typography.detail)
                    .foregroundStyle(PopoverDesignSystem.Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            } else {
                let presentation = model.openRouterBalance
                VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.xSmall) {
                    HStack(alignment: .firstTextBaseline, spacing: PopoverDesignSystem.Spacing.small) {
                        Text(presentation.remaining)
                            .font(PopoverDesignSystem.Typography.metric)
                            .monospacedDigit()
                            .lineLimit(1)
                        Text("남음")
                            .font(PopoverDesignSystem.Typography.detail)
                            .foregroundStyle(PopoverDesignSystem.Palette.secondary)
                        Spacer(minLength: 0)
                        Text("사용 \(presentation.used)")
                        Text("\(presentation.allowanceLabel) \(presentation.allowance)")
                    }
                    .font(PopoverDesignSystem.Typography.detail)
                    .foregroundStyle(PopoverDesignSystem.Palette.secondary)

                    HStack(spacing: PopoverDesignSystem.Spacing.small) {
                        if let tier = presentation.tier {
                            Label(tier, systemImage: "bolt.fill")
                        }
                        if let rateLimit = presentation.rateLimit {
                            Text("요청 한도 \(rateLimit)")
                        }
                        Spacer(minLength: 0)
                        if let message = presentation.message {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(PopoverDesignSystem.Palette.warning)
                                .lineLimit(1)
                        }
                    }
                    .font(PopoverDesignSystem.Typography.detail)
                    .foregroundStyle(PopoverDesignSystem.Palette.secondary)
                }
            }
        }
        .providerPanel(.openRouter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.openRouterBalance.accessibilityLabel)
        .accessibilityIdentifier("openrouter-section")
    }
}

private struct CompactQuotaLine: View {
    let presentation: QuotaWindowPresentation
    let provider: PopoverDesignSystem.Provider
    var leadingSymbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: PopoverDesignSystem.Spacing.small) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                        .foregroundStyle(provider.accent)
                        .accessibilityHidden(true)
                }
                Text(presentation.window)
                    .font(PopoverDesignSystem.Typography.detail)
                    .foregroundStyle(PopoverDesignSystem.Palette.secondary)
                Text(presentation.remaining)
                    .font(PopoverDesignSystem.Typography.metric)
                    .monospacedDigit()
                    .foregroundStyle(quotaColor)
                    .lineLimit(1)
                QuotaCue(presentation: presentation, provider: provider)
                Spacer(minLength: 0)
                Text(presentation.reset)
                    .font(PopoverDesignSystem.Typography.detail)
                    .foregroundStyle(PopoverDesignSystem.Palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(PopoverDesignSystem.Scale.minimumText)
            }
            QuotaBar(presentation: presentation, provider: provider)
        }
        .accessibilityRepresentation {
            Text(presentation.accessibilityLabel)
                .accessibilityIdentifier(
                    "\(presentation.service.lowercased())-\(presentation.window.lowercased().replacingOccurrences(of: " ", with: "-"))-quota"
                )
        }
    }

    private var quotaColor: Color {
        PopoverDesignSystem.Palette.quota(presentation, provider: provider)
    }
}

struct QuotaBar: View {
    let presentation: QuotaWindowPresentation
    let provider: PopoverDesignSystem.Provider

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(PopoverDesignSystem.Palette.track)
                if let fraction = presentation.remainingFraction {
                    Capsule()
                        .fill(PopoverDesignSystem.Palette.quota(presentation, provider: provider))
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
        }
        .frame(height: PopoverDesignSystem.Size.progressHeight)
        .accessibilityHidden(true)
    }
}

private struct QuotaCue: View {
    let presentation: QuotaWindowPresentation
    let provider: PopoverDesignSystem.Provider

    var body: some View {
        if let text {
            Text(text)
                .font(PopoverDesignSystem.Typography.detailStrong)
                .foregroundStyle(PopoverDesignSystem.Palette.quota(presentation, provider: provider))
                .lineLimit(1)
                .accessibilityHidden(true)
        }
    }

    private var text: String? {
        if presentation.pace == .exhausted || presentation.remainingFraction == 0 {
            return "소진"
        }
        if let fraction = presentation.remainingFraction {
            if fraction <= 0.1 { return "부족" }
            if fraction <= 0.25 { return "주의" }
        }
        return presentation.paceText
    }
}

private struct ActiveBadge: View {
    let provider: PopoverDesignSystem.Provider

    var body: some View {
        Text("사용 중")
            .font(PopoverDesignSystem.Typography.detailStrong)
            .foregroundStyle(provider.accent)
            .padding(.horizontal, PopoverDesignSystem.Spacing.xSmall)
            .padding(.vertical, PopoverDesignSystem.Spacing.xxSmall)
            .background(
                Capsule().fill(provider.accent.opacity(PopoverDesignSystem.Opacity.badge))
            )
            .fixedSize()
    }
}

private struct CouponBadge: View {
    let text: String
    let provider: PopoverDesignSystem.Provider
    let accessibilityIdentifier: String

    var body: some View {
        Label(text, systemImage: "ticket.fill")
            .font(PopoverDesignSystem.Typography.detailStrong)
            .foregroundStyle(provider.accent)
            .padding(.horizontal, PopoverDesignSystem.Spacing.xSmall)
            .padding(.vertical, PopoverDesignSystem.Spacing.xxSmall)
            .background(
                Capsule().fill(
                    provider.accent.opacity(
                        PopoverDesignSystem.Opacity.badge
                    )
                )
            )
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct ClaudeCouponBadge: View {
    let coupon: ResetCouponPresentation
    let accessibilityIdentifier: String

    var body: some View {
        CouponBadge(
            text: [coupon.countText, coupon.expiryText].compactMap { $0 }.joined(separator: " · "),
            provider: .claude,
            accessibilityIdentifier: accessibilityIdentifier
        )
        .help("Claude Code에서 /limit-reset으로 사용량 한도를 초기화할 수 있습니다")
    }
}

private struct FreshnessLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PopoverDesignSystem.Typography.detail)
            .foregroundStyle(
                text == "최신"
                    ? PopoverDesignSystem.Palette.secondary
                    : PopoverDesignSystem.Palette.warning
            )
            .lineLimit(1)
    }
}

private struct RefreshStatus: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.xSmall) {
            if let errorText = model.errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(PopoverDesignSystem.Typography.detail)
                    .foregroundStyle(PopoverDesignSystem.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("사용량 오류, \(errorText)")
            }
            Text(model.lastRefreshText)
                .font(PopoverDesignSystem.Typography.detail)
                .foregroundStyle(PopoverDesignSystem.Palette.secondary)
                .accessibilityLabel("마지막 새로고침, \(model.lastRefreshText)")
        }
    }
}

private struct ClaudeProfileControls: View {
    private enum Editor {
        case saveCurrent
        case newLogin
    }

    @ObservedObject var model: AppViewModel
    @State private var editor: Editor?
    @State private var deletionTarget: ProfileDeletionTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.small) {
            HStack {
                Spacer(minLength: 0)
                Menu {
                    Button("현재 계정 저장…") {
                        model.claudeProfileName = ""
                        editor = .saveCurrent
                    }
                    .accessibilityLabel("현재 Claude 로그인 저장")
                    .accessibilityIdentifier("save-current-claude-profile")

                    Button("새 로그인…") {
                        model.claudeProfileName = ""
                        editor = .newLogin
                    }
                    .accessibilityLabel("새 Claude 로그인 시작")
                    .accessibilityIdentifier("add-claude-account")

                    if !model.claudeProfiles.isEmpty {
                        Divider()
                        ForEach(model.claudeProfiles, id: \.id) { profile in
                            Button(role: .destructive) {
                                deletionTarget = ProfileDeletionTarget(
                                    id: profile.id,
                                    name: profile.name
                                )
                            } label: {
                                Text("\(profile.name) 삭제…")
                            }
                            .accessibilityIdentifier("delete-claude-profile-\(profile.id)")
                        }
                    }
                } label: {
                    Label("계정 관리", systemImage: "person.2")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Claude 계정 관리")
                .accessibilityIdentifier("claude-profile-actions")
            }
            .disabled(model.isPerformingProfileAction)

            if let editor {
                EditorPanel {
                    Text(description(for: editor))
                        .font(PopoverDesignSystem.Typography.detail)
                        .foregroundStyle(PopoverDesignSystem.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let status = model.codexLoginStatusText, editor == .newLogin {
                        Text(status)
                            .font(PopoverDesignSystem.Typography.detail)
                            .accessibilityIdentifier("claude-login-status")
                        HStack(spacing: PopoverDesignSystem.Spacing.small) {
                            if let title = model.reopenCodexSignInTitle {
                                Button(title) { model.reopenCodexSignIn() }
                                    .accessibilityIdentifier("reopen-claude-sign-in")
                            }
                            if let title = model.cancelCodexSignInTitle {
                                Button(title) { model.cancelCodexSignIn() }
                                    .accessibilityIdentifier("cancel-claude-sign-in")
                            }
                        }
                    } else {
                        HStack(spacing: PopoverDesignSystem.Spacing.small) {
                            TextField("계정 이름", text: $model.claudeProfileName)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Claude 계정 이름")
                                .accessibilityIdentifier(
                                    editor == .saveCurrent
                                        ? "claude-profile-name"
                                        : "new-claude-profile-name"
                                )

                            Button("취소") { self.editor = nil }
                                .accessibilityIdentifier(
                                    editor == .saveCurrent
                                        ? "cancel-save-current-claude-profile"
                                        : "cancel-new-claude-login"
                                )

                            Button(editor == .saveCurrent ? "저장" : "계속") {
                                Task {
                                    if editor == .saveCurrent {
                                        await model.saveCurrentClaudeProfile()
                                    } else {
                                        await model.addClaudeAccount()
                                    }
                                    self.editor = nil
                                }
                            }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier(
                                editor == .saveCurrent
                                    ? "confirm-save-current-claude-profile"
                                    : "confirm-new-claude-login"
                            )
                        }
                        .disabled(model.isPerformingProfileAction)
                    }
                }
            }
        }
        .confirmationDialog(
            deletionTarget.map { "\($0.name) 계정을 삭제할까요?" } ?? "",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                guard let target = deletionTarget else { return }
                deletionTarget = nil
                Task { await model.deleteClaudeProfile(id: target.id) }
            }
            .accessibilityIdentifier("confirm-delete-claude-profile")
            Button("취소", role: .cancel) { deletionTarget = nil }
        } message: {
            Text("저장된 토큰만 지웁니다. Claude Code 로그인 자체는 그대로입니다.")
        }
    }

    private func description(for editor: Editor) -> String {
        switch editor {
        case .saveCurrent:
            "지금 Claude Code 가 로그인된 계정을 이 이름으로 저장합니다."
        case .newLogin:
            "브라우저에서 다른 계정으로 로그인합니다. 지금 로그인된 계정은 유지됩니다."
        }
    }
}

private struct ProfileControls: View {
    private enum Editor {
        case saveCurrent
        case newLogin
    }

    @ObservedObject var model: AppViewModel
    @State private var editor: Editor?
    @State private var deletionTarget: ProfileDeletionTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.small) {
            HStack {
                Spacer(minLength: 0)
                Menu {
                    Button("현재 로그인 저장…") {
                        model.profileName = ""
                        editor = .saveCurrent
                    }
                    .accessibilityLabel("현재 Codex 로그인 저장")
                    .accessibilityIdentifier("save-current-profile")

                    Button("새 로그인…") {
                        model.profileName = ""
                        editor = .newLogin
                    }
                    .accessibilityLabel("새 Codex 로그인 시작")
                    .accessibilityIdentifier("add-account")

                    Divider()
                    Button(role: .destructive) {
                        guard let id = model.selectedCodexProfileID else { return }
                        deletionTarget = ProfileDeletionTarget(
                            id: id,
                            name: model.activeCodexProfileName
                        )
                    } label: {
                        Text("\(model.activeCodexProfileName) 삭제…")
                    }
                    .accessibilityIdentifier("delete-selected-profile")
                    .disabled(model.selectedCodexProfileID == nil)

                    let inactiveProfiles = model.codexProfiles.filter {
                        $0.id != model.selectedCodexProfileID
                    }
                    ForEach(inactiveProfiles, id: \.id) { profile in
                        Button(role: .destructive) {
                            deletionTarget = ProfileDeletionTarget(
                                id: profile.id,
                                name: profile.name
                            )
                        } label: {
                            Text("\(profile.name) 삭제…")
                        }
                        .accessibilityIdentifier("delete-profile-\(profile.id)")
                    }
                } label: {
                    Label("계정 관리", systemImage: "person.2")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("\(model.activeCodexProfileName) 계정 관리")
                .accessibilityIdentifier("codex-profile-actions")
            }
            .disabled(model.isPerformingProfileAction)

            if let editor {
                EditorPanel {
                    Text(editorDescription(editor))
                        .font(PopoverDesignSystem.Typography.detail)
                        .foregroundStyle(PopoverDesignSystem.Palette.secondary)
                    if let status = model.codexLoginStatusText, editor == .newLogin {
                        Text(status)
                            .font(PopoverDesignSystem.Typography.detail)
                            .accessibilityIdentifier("codex-login-status")
                        HStack(spacing: PopoverDesignSystem.Spacing.small) {
                            if let title = model.reopenCodexSignInTitle {
                                Button(title) { model.reopenCodexSignIn() }
                                    .accessibilityIdentifier("reopen-codex-sign-in")
                            }
                            if let title = model.cancelCodexSignInTitle {
                                Button(title) { model.cancelCodexSignIn() }
                                    .accessibilityIdentifier("cancel-codex-sign-in")
                            }
                        }
                    } else {
                        HStack(spacing: PopoverDesignSystem.Spacing.small) {
                            TextField("프로필 이름", text: $model.profileName)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("로컬 프로필 이름")
                                .accessibilityIdentifier(
                                    editor == .saveCurrent
                                        ? "codex-profile-name"
                                        : "new-codex-profile-name"
                                )

                            Button("취소") { self.editor = nil }
                                .accessibilityIdentifier(
                                    editor == .saveCurrent
                                        ? "cancel-save-current-profile"
                                        : "cancel-new-codex-login"
                                )

                            Button(editor == .saveCurrent ? "저장" : "계속") {
                                Task {
                                    if editor == .saveCurrent {
                                        await model.saveCurrentProfile()
                                    } else {
                                        await model.addAccount()
                                    }
                                    if model.errorText == nil {
                                        self.editor = nil
                                    }
                                }
                            }
                            .accessibilityIdentifier(
                                editor == .saveCurrent
                                    ? "confirm-save-current-profile"
                                    : "confirm-new-codex-login"
                            )
                            .disabled(
                                model.profileName.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty || model.isPerformingProfileAction
                            )
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex 계정 관리")
        .accessibilityIdentifier("codex-account-controls")
        .confirmationDialog(
            "\(deletionTarget?.name ?? model.activeCodexProfileName) 로컬 프로필을 삭제할까요?",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = deletionTarget {
                Button("프로필 삭제", role: .destructive) {
                    Task { await model.deleteCodexProfile(id: target.id) }
                }
                .accessibilityIdentifier("confirm-delete-profile")
            }
            Button("취소", role: .cancel) {}
                .accessibilityIdentifier("cancel-delete-profile")
        } message: {
            Text("이 Mac에 저장된 자격 증명만 지웁니다. Codex 계정 자체는 삭제되지 않습니다.")
        }
    }

    private func editorDescription(_ editor: Editor) -> String {
        switch editor {
        case .saveCurrent:
            "현재 Codex 로그인을 이 Mac의 로컬 프로필로 저장합니다."
        case .newLogin:
            "현재 프로필을 유지한 채 다른 Codex 계정에 로그인합니다."
        }
    }
}

private struct EditorPanel<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesignSystem.Spacing.small) {
            content
        }
        .padding(PopoverDesignSystem.Spacing.small)
        .background(PopoverDesignSystem.Palette.track)
        .clipShape(
            RoundedRectangle(
                cornerRadius: PopoverDesignSystem.Radius.section,
                style: .continuous
            )
        )
    }
}

private struct PopoverActions: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        HStack(spacing: PopoverDesignSystem.Spacing.small) {
            Button {
                Task { await model.refreshNow() }
            } label: {
                Label("지금 새로고침", systemImage: "arrow.clockwise")
            }
            .accessibilityLabel("지금 새로고침 동작")
            .accessibilityIdentifier("refresh-now")
            .disabled(model.isRefreshing)

            if let mobileLink = model.mobileLink {
                MobileLinkButton(link: mobileLink)
            }

            Spacer(minLength: 0)

            Button {
                model.quit()
            } label: {
                Label("종료", systemImage: "power")
            }
            .accessibilityLabel("Token Usage 종료 동작")
            .accessibilityIdentifier("quit")
        }
        .controlSize(.small)
    }
}

private struct MobileLinkButton: View {
    let link: URL
    @State private var isShowingCode = false

    var body: some View {
        Button {
            isShowingCode.toggle()
        } label: {
            Label("휴대폰으로 보기", systemImage: "qrcode")
        }
        .accessibilityIdentifier("show-mobile-link")
        .popover(isPresented: $isShowingCode, arrowEdge: .bottom) {
            MobileLinkPanel(link: link)
        }
    }
}

/// The phone link as a QR code: the page to open in Safari, or the Scriptable widget source.
struct MobileLinkPanel: View {
    enum Target: String, CaseIterable, Identifiable {
        case page = "페이지"
        case widget = "위젯"
        var id: String { rawValue }
    }

    let link: URL
    @State var target: Target = .page
    @State private var copied = false
    private static let codeSide: CGFloat = 188

    var body: some View {
        VStack(spacing: PopoverDesignSystem.Spacing.small) {
            Picker("보기", selection: $target) {
                ForEach(Target.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let image = QRCodeImage.make(from: targetLink.absoluteString, side: Self.codeSide) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: Self.codeSide, height: Self.codeSide)
                    .padding(PopoverDesignSystem.Spacing.small)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("\(target.rawValue) 링크 QR 코드")
                    .accessibilityIdentifier("mobile-link-qr")
            }

            Text(caption)
                .font(PopoverDesignSystem.Typography.detail)
                .foregroundStyle(PopoverDesignSystem.Palette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(targetLink.absoluteString, forType: .string)
                copied = true
            } label: {
                Label(copied ? "복사됨" : "링크 복사", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .accessibilityIdentifier("copy-mobile-link")
        }
        .padding(PopoverDesignSystem.Spacing.medium)
        .frame(width: Self.codeSide + 56)
        .onChange(of: target) { copied = false }
    }

    var targetLink: URL {
        guard target == .widget,
              var components = URLComponents(url: link, resolvingAgainstBaseURL: false)
        else {
            return link
        }
        components.path = "/widget.js"
        return components.url ?? link
    }

    private var caption: String {
        switch target {
        case .page:
            "휴대폰 카메라로 찍어 Safari에서 여세요. 휴대폰에 Tailscale이 켜져 있어야 합니다."
        case .widget:
            "열린 코드를 Scriptable 새 스크립트에 붙여 넣고 위젯으로 추가하세요."
        }
    }
}

@MainActor
public final class UsagePopoverHostingController: NSHostingController<UsagePopoverView> {
    public init(model: AppViewModel) {
        super.init(rootView: UsagePopoverView(model: model))
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Token Usage 사용량 창")
        view.setAccessibilityIdentifier("usage-popover-window")
        sizingOptions = [.preferredContentSize]
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
