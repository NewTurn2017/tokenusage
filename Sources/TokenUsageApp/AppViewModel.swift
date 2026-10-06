import AppKit
import Combine
import Foundation
import TokenUsageCore

public struct ClaudeProfileUsage: Equatable, Sendable {
    public let profileID: String
    public let state: UsageState

    public init(profileID: String, state: UsageState) {
        self.profileID = profileID
        self.state = state
    }
}

public struct CodexProfileUsage: Equatable, Sendable {
    public let profileID: String
    public let state: UsageState

    public init(profileID: String, state: UsageState) {
        self.profileID = profileID
        self.state = state
    }
}

public enum OpenRouterUsageState: Equatable, Sendable {
    case fresh(OpenRouterUsageSnapshot)
    case stale(lastGood: OpenRouterUsageSnapshot, message: String)
    case unavailable(message: String)
    case notConfigured(message: String)

    public static let notConfiguredHint = "~/.config/openrouter/key 에 키를 넣어 주세요."

    public static func refreshFailed(
        message: String,
        previous: OpenRouterUsageState?
    ) -> OpenRouterUsageState {
        switch previous {
        case let .fresh(snapshot):
            return .stale(lastGood: snapshot, message: message)
        case let .stale(lastGood, _):
            return .stale(lastGood: lastGood, message: message)
        case .unavailable, .notConfigured, .none:
            return .unavailable(message: message)
        }
    }
}

public struct AppUsageSnapshot: Equatable, Sendable {
    public let claude: UsageState
    public let codexUsage: [CodexProfileUsage]
    public let codexProfiles: [CodexProfileMetadata]
    public let activeCodexProfileID: String?
    public let openRouter: OpenRouterUsageState
    public let removedCodexProfileNames: [String]
    public let claudeUsage: [ClaudeProfileUsage]
    public let claudeProfiles: [ClaudeProfileMetadata]
    public let activeClaudeProfileID: String?

    public init(
        claude: UsageState,
        codexUsage: [CodexProfileUsage],
        codexProfiles: [CodexProfileMetadata],
        activeCodexProfileID: String?,
        openRouter: OpenRouterUsageState = .notConfigured(
            message: OpenRouterUsageState.notConfiguredHint
        ),
        removedCodexProfileNames: [String] = [],
        claudeUsage: [ClaudeProfileUsage] = [],
        claudeProfiles: [ClaudeProfileMetadata] = [],
        activeClaudeProfileID: String? = nil
    ) {
        self.claude = claude
        self.codexUsage = codexUsage
        self.codexProfiles = codexProfiles
        self.activeCodexProfileID = activeCodexProfileID
        self.openRouter = openRouter
        self.removedCodexProfileNames = removedCodexProfileNames
        self.claudeUsage = claudeUsage
        self.claudeProfiles = claudeProfiles
        self.activeClaudeProfileID = activeClaudeProfileID
    }
}

public protocol AppUsageCoordinating: Sendable {
    func start() async
    func stateChanges() async -> AsyncStream<RefreshState<AppUsageSnapshot>>
    func requestRefresh() async
    func performProfileOperation(
        _ operation: @escaping @Sendable () async throws -> AppUsageSnapshot
    ) async throws -> AppUsageSnapshot
    func stop() async
}

public actor AppRefreshCoordinator: AppUsageCoordinating {
    private let coordinator: RefreshCoordinator<AppUsageSnapshot>

    public init(coordinator: RefreshCoordinator<AppUsageSnapshot>) {
        self.coordinator = coordinator
    }

    public func start() async {
        await coordinator.start()
    }

    public func stateChanges() async -> AsyncStream<RefreshState<AppUsageSnapshot>> {
        await coordinator.stateChanges()
    }

    public func requestRefresh() async {
        await coordinator.requestRefresh()
    }

    public func performProfileOperation(
        _ operation: @escaping @Sendable () async throws -> AppUsageSnapshot
    ) async throws -> AppUsageSnapshot {
        try await coordinator.performSwitch(operation)
    }

    public func stop() async {
        await coordinator.stop()
    }
}

public protocol ClaudeProfileActionHandling: Sendable {
    func selectClaudeProfile(id: String) async throws -> AppUsageSnapshot
    func saveCurrentClaudeProfile(named name: String) async throws -> AppUsageSnapshot
    func addClaudeAccount(named name: String) async throws -> AppUsageSnapshot
    func deleteClaudeProfile(id: String) async throws -> AppUsageSnapshot
}

/// Stands in until a composition wires real Claude account actions, so previews and tests can
/// build a view model without one.
public struct UnavailableClaudeProfileActions: ClaudeProfileActionHandling {
    public init() {}

    public func selectClaudeProfile(id: String) async throws -> AppUsageSnapshot {
        throw ClaudeProfileManagerError.storageFailed
    }

    public func saveCurrentClaudeProfile(named name: String) async throws -> AppUsageSnapshot {
        throw ClaudeProfileManagerError.storageFailed
    }

    public func addClaudeAccount(named name: String) async throws -> AppUsageSnapshot {
        throw ClaudeProfileManagerError.loginUnavailable
    }

    public func deleteClaudeProfile(id: String) async throws -> AppUsageSnapshot {
        throw ClaudeProfileManagerError.storageFailed
    }
}

public protocol CodexProfileActionHandling: Sendable {
    func selectProfile(id: String) async throws -> AppUsageSnapshot
    func saveCurrentProfile(named name: String) async throws -> AppUsageSnapshot
    func addAccount(named name: String) async throws -> AppUsageSnapshot
    func deleteProfile(id: String) async throws -> AppUsageSnapshot
}

public struct QuotaWindowPresentation: Equatable, Sendable {
    public let service: String
    public let window: String
    public let remaining: String
    public let reset: String
    public let remainingFraction: Double?
    public let pace: QuotaPace

    public init(
        service: String,
        window: String,
        remaining: String,
        reset: String,
        remainingFraction: Double?,
        pace: QuotaPace = .unknown
    ) {
        self.service = service
        self.window = window
        self.remaining = remaining
        self.reset = reset
        self.remainingFraction = remainingFraction
        self.pace = pace
    }

    /// Short Korean label so the pace is readable without relying on colour alone.
    public var paceText: String? {
        switch pace {
        case .overspending:
            "과속"
        case .onTrack:
            "적정"
        case .comfortable:
            "여유"
        case .exhausted:
            "소진"
        case .unknown:
            nil
        }
    }

    public var accessibilityLabel: String {
        let pace = paceText.map { ", 사용 속도 \($0)" } ?? ""
        return "\(service), \(window) 창, \(remaining), \(reset)\(pace)"
    }
}

public struct OpenRouterBalancePresentation: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case configured
        case stale
        case unavailable
        case notConfigured
    }

    public let status: Status
    public let remaining: String
    public let used: String
    public let allowanceLabel: String
    public let allowance: String
    public let tier: String?
    public let rateLimit: String?
    public let message: String?

    public var freshnessText: String {
        switch status {
        case .configured:
            "최신"
        case .stale:
            "이전 값"
        case .unavailable:
            "조회 실패"
        case .notConfigured:
            "설정 안 됨"
        }
    }

    public var accessibilityLabel: String {
        switch status {
        case .notConfigured:
            let hint = message ?? OpenRouterUsageState.notConfiguredHint
            return "OpenRouter, 설정 안 됨, " + hint
        case .unavailable:
            return "OpenRouter, 조회 실패"
        case .configured, .stale:
            let tierText = tier.map { ", \($0)" } ?? ""
            return "OpenRouter, 남은 금액 \(remaining), 사용 \(used), "
                + "\(allowanceLabel) \(allowance)\(tierText)"
        }
    }
}

public struct CodexProfileQuotaPresentation: Identifiable, Equatable, Sendable {
    public var id: String { profileID }
    public let profileID: String
    public let name: String
    public let quota: QuotaWindowPresentation
    public let resetCouponText: String?
    public let additionalCreditsText: String
    public let freshnessText: String
    public let isActive: Bool

    public var accessibilityIdentifier: String {
        "codex-profile-quota-\(profileID)"
    }

    public var accessibilityLabel: String {
        let active = isActive ? ", 사용 중" : ""
        let pace = quota.paceText.map { ", 사용 속도 \($0)" } ?? ""
        let resetCoupon = resetCouponText.map { ", \($0)" } ?? ""
        return "\(name), 프로필 ID \(profileID)\(active), \(freshnessText), "
            + "\(quota.remaining), \(quota.reset)\(pace)\(resetCoupon), "
            + "추가 크레딧 \(additionalCreditsText)"
    }
}

public struct ClaudeProfileQuotaPresentation: Identifiable, Equatable, Sendable {
    public var id: String { profileID }
    public let profileID: String
    public let name: String
    public let emailAddress: String?
    public let fiveHour: QuotaWindowPresentation
    public let weekly: QuotaWindowPresentation
    public let resetCoupon: ResetCouponPresentation?
    public let freshnessText: String
    public let isActive: Bool

    public var accessibilityIdentifier: String {
        "claude-profile-quota-\(profileID)"
    }

    public var accessibilityLabel: String {
        let active = isActive ? ", 사용 중" : ""
        let email = emailAddress.map { ", \($0)" } ?? ""
        let coupon = resetCoupon.map { ", \($0.accessibilityText)" } ?? ""
        return "\(name)\(email)\(active), \(freshnessText), "
            + "5시간 \(fiveHour.remaining)\(resetSuffix(fiveHour)), "
            + "주간 \(weekly.remaining)\(resetSuffix(weekly))\(coupon)"
    }

    private func resetSuffix(_ window: QuotaWindowPresentation) -> String {
        window.reset == "--" ? "" : " \(window.reset)"
    }
}

/// A Claude limit-reset credit the account still holds, with the deadline for using it.
public struct ResetCouponPresentation: Equatable, Sendable {
    public let countText: String
    public let expiryText: String?

    public var accessibilityText: String {
        "초기화 \(countText)" + (expiryText.map { ", \($0) 사용" } ?? "")
    }
}

public struct CodexLoginAttemptState: Equatable, Sendable {
    public let isActive: Bool
    public let canReopen: Bool

    public init(isActive: Bool, canReopen: Bool) {
        self.isActive = isActive
        self.canReopen = canReopen
    }

    public static let inactive = CodexLoginAttemptState(isActive: false, canReopen: false)
}

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public private(set) var claudeFiveHour: QuotaWindowPresentation
    @Published public private(set) var claudeWeekly: QuotaWindowPresentation
    @Published public private(set) var claudeFableWeekly: QuotaWindowPresentation
    /// The signed-in account's reset credit, shown when there are no saved account rows to carry it.
    @Published public private(set) var claudeResetCoupon: ResetCouponPresentation?
    @Published public private(set) var codexWeekly: QuotaWindowPresentation
    @Published public private(set) var codexQuotaRows: [CodexProfileQuotaPresentation] = []
    @Published public private(set) var claudeQuotaRows: [ClaudeProfileQuotaPresentation] = []
    @Published public private(set) var claudeProfiles: [ClaudeProfileMetadata] = []
    @Published public private(set) var selectedClaudeProfileID: String?
    @Published public private(set) var activeClaudeProfileName = "활성 계정 없음"
    @Published public private(set) var openRouterBalance: OpenRouterBalancePresentation
    @Published public private(set) var codexProfiles: [CodexProfileMetadata] = []
    @Published public private(set) var selectedCodexProfileID: String?
    @Published public private(set) var activeCodexProfileName = "활성 프로필 없음"
    @Published public private(set) var lastRefreshText = "마지막 새로고침 시각 없음"
    @Published public private(set) var lastRefreshAt: Date?
    /// The link a phone on the same tailnet opens to see this usage; nil while the server is off.
    @Published public private(set) var mobileLink: URL?
    @Published public private(set) var statusText = "새로고침 대기 중"
    @Published public private(set) var errorText: String?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isPerformingProfileAction = false
    @Published public private(set) var codexLoginStatusText: String?
    @Published public private(set) var reopenCodexSignInTitle: String?
    @Published public private(set) var cancelCodexSignInTitle: String?
    @Published public var profileName = "codex2"
    @Published public var claudeProfileName = "claude1"
    @Published private(set) var statusItemPresentation = StatusItemPresentation(
        claude: .unavailable(message: ""),
        codexProfiles: []
    )

    private let coordinator: any AppUsageCoordinating
    private let profileActions: any CodexProfileActionHandling
    private let claudeProfileActions: any ClaudeProfileActionHandling
    private let quitAction: @MainActor @Sendable () -> Void
    private let loginAttemptState: @Sendable () -> CodexLoginAttemptState
    private let reopenCodexSignInAction: @Sendable () -> Bool
    private let cancelCodexSignInAction: @Sendable () -> Void
    private let dateFormatter: DateFormatter
    private let couponExpiryFormatter: DateFormatter
    private let creditFormatter: NumberFormatter
    private let now: @Sendable () -> Date
    private var observationTask: Task<Void, Never>?
    private var loginObservationTask: Task<Void, Never>?

    public init(
        coordinator: any AppUsageCoordinating,
        profileActions: any CodexProfileActionHandling,
        claudeProfileActions: any ClaudeProfileActionHandling = UnavailableClaudeProfileActions(),
        loginAttemptState: @escaping @Sendable () -> CodexLoginAttemptState = { .inactive },
        reopenCodexSignIn: @escaping @Sendable () -> Bool = { false },
        cancelCodexSignIn: @escaping @Sendable () -> Void = {},
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        quitAction: @escaping @MainActor @Sendable () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) {
        self.now = now
        self.coordinator = coordinator
        self.profileActions = profileActions
        self.claudeProfileActions = claudeProfileActions
        self.loginAttemptState = loginAttemptState
        reopenCodexSignInAction = reopenCodexSignIn
        cancelCodexSignInAction = cancelCodexSignIn
        self.quitAction = quitAction

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "M월 d일 a h:mm"
        dateFormatter = formatter

        let expiryFormatter = DateFormatter()
        expiryFormatter.locale = locale
        expiryFormatter.timeZone = timeZone
        expiryFormatter.dateFormat = "M/d"
        couponExpiryFormatter = expiryFormatter

        let creditFormatter = NumberFormatter()
        creditFormatter.locale = locale
        creditFormatter.numberStyle = .decimal
        creditFormatter.maximumFractionDigits = 2
        self.creditFormatter = creditFormatter

        claudeFiveHour = Self.unavailableWindow(service: "Claude", window: "5시간")
        claudeWeekly = Self.unavailableWindow(service: "Claude", window: "주간")
        claudeFableWeekly = Self.unavailableWindow(service: "Claude", window: "Fable 주간")
        codexWeekly = Self.unavailableWindow(service: "Codex", window: "주간")
        openRouterBalance = Self.notConfiguredOpenRouter()
    }

    public func start() {
        guard observationTask == nil else { return }

        observationTask = Task { [weak self, coordinator] in
            let states = await coordinator.stateChanges()
            await coordinator.start()
            for await state in states {
                guard !Task.isCancelled else { return }
                self?.apply(state)
            }
        }
    }

    public func stop() async {
        observationTask?.cancel()
        observationTask = nil
        loginObservationTask?.cancel()
        loginObservationTask = nil
        await coordinator.stop()
    }

    public func setMobileLink(_ link: URL?) {
        mobileLink = link
    }

    public func refreshNow() async {
        await coordinator.requestRefresh()
    }

    public func selectClaudeProfile(id: String) async {
        guard id != selectedClaudeProfileID else { return }
        let previousID = selectedClaudeProfileID
        selectedClaudeProfileID = id
        let succeeded = await performProfileAction(
            failureMessage: "Claude 계정을 전환하지 못했습니다."
        ) {
            try await self.claudeProfileActions.selectClaudeProfile(id: id)
        }
        if !succeeded { selectedClaudeProfileID = previousID }
    }

    public func saveCurrentClaudeProfile() async {
        let name = claudeProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorText = "저장할 계정 이름을 입력해 주세요."
            return
        }
        await performProfileAction(failureMessage: "현재 Claude 계정을 저장하지 못했습니다.") {
            try await self.claudeProfileActions.saveCurrentClaudeProfile(named: name)
        }
    }

    public func addClaudeAccount() async {
        let name = claudeProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorText = "로그인할 계정 이름을 먼저 입력해 주세요."
            return
        }
        startLoginObservation()
        defer { stopLoginObservation() }
        await performProfileAction(failureMessage: "Claude 계정을 추가하지 못했습니다.") {
            try await self.claudeProfileActions.addClaudeAccount(named: name)
        }
    }

    public func deleteClaudeProfile(id: String) async {
        await performProfileAction(failureMessage: "Claude 계정을 삭제하지 못했습니다.") {
            try await self.claudeProfileActions.deleteClaudeProfile(id: id)
        }
    }

    public func deleteSelectedClaudeProfile() async {
        guard let id = selectedClaudeProfileID else {
            errorText = "삭제할 Claude 계정을 먼저 선택해 주세요."
            return
        }
        await deleteClaudeProfile(id: id)
    }

    public func selectCodexProfile(id: String) async {
        guard id != selectedCodexProfileID else { return }
        let previousID = selectedCodexProfileID
        selectedCodexProfileID = id
        let succeeded = await performProfileAction(
            failureMessage: "Codex profile could not be selected."
        ) {
            try await self.profileActions.selectProfile(id: id)
        }
        if !succeeded { selectedCodexProfileID = previousID }
    }

    public func saveCurrentProfile() async {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorText = "Enter a profile name before saving."
            return
        }
        await performProfileAction(failureMessage: "Current Codex profile could not be saved.") {
            try await self.profileActions.saveCurrentProfile(named: name)
        }
    }

    public func addAccount() async {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorText = "Enter an account name before logging in."
            return
        }
        startLoginObservation()
        defer { stopLoginObservation() }
        await performProfileAction(failureMessage: "Codex account could not be added.") {
            try await self.profileActions.addAccount(named: name)
        }
    }

    func updateCodexLoginAttemptPresentation() {
        let state = loginAttemptState()
        codexLoginStatusText = state.isActive ? "Sign-in is in progress." : nil
        reopenCodexSignInTitle = state.canReopen ? "Reopen sign-in" : nil
        cancelCodexSignInTitle = state.isActive ? "Cancel" : nil
    }

    public func reopenCodexSignIn() {
        guard reopenCodexSignInAction() else {
            errorText = "The sign-in page could not be reopened."
            return
        }
        errorText = nil
    }

    public func cancelCodexSignIn() {
        cancelCodexSignInAction()
    }

    public func deleteSelectedProfile() async {
        guard let id = selectedCodexProfileID else {
            errorText = "Select a Codex account before deleting."
            return
        }
        await deleteCodexProfile(id: id)
    }

    /// Deletes a profile by identifier, so a profile that can no longer be activated -
    /// and therefore can never become the selected one - is still removable.
    public func deleteCodexProfile(id: String) async {
        await performProfileAction(failureMessage: "Codex account could not be deleted.") {
            try await self.profileActions.deleteProfile(id: id)
        }
    }

    public func quit() {
        quitAction()
    }

    private func startLoginObservation() {
        loginObservationTask?.cancel()
        updateCodexLoginAttemptPresentation()
        loginObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateCodexLoginAttemptPresentation()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopLoginObservation() {
        loginObservationTask?.cancel()
        loginObservationTask = nil
        updateCodexLoginAttemptPresentation()
    }

    func apply(_ state: RefreshState<AppUsageSnapshot>) {
        switch state {
        case .idle:
            isRefreshing = false
            statusText = "새로고침 대기 중"
        case .refreshing(let previous):
            if let previous { applySnapshot(previous) }
            isRefreshing = true
            statusText = "사용량 새로고침 중"
            errorText = nil
        case .switching(let previous):
            if let previous { applySnapshot(previous) }
            isRefreshing = false
            isPerformingProfileAction = true
            statusText = "Codex 프로필 전환 중"
            errorText = nil
        case .current(let snapshot):
            applySnapshot(snapshot)
            isRefreshing = false
            isPerformingProfileAction = false
        case .stale(let snapshot, _):
            applySnapshot(snapshot)
            isRefreshing = false
            isPerformingProfileAction = false
            statusText = "이전 값을 보여 주고 있습니다."
            errorText = "새로고침에 실패했습니다. 다시 시도해 주세요."
        case .failed:
            clearUsage()
            isRefreshing = false
            isPerformingProfileAction = false
            statusText = "사용량을 불러오지 못했습니다"
            errorText = "새로고침에 실패했습니다. 다시 시도해 주세요."
        }
    }

    @discardableResult
    private func performProfileAction(
        failureMessage: String,
        operation: @escaping @Sendable () async throws -> AppUsageSnapshot
    ) async -> Bool {
        isPerformingProfileAction = true
        errorText = nil
        do {
            let snapshot = try await coordinator.performProfileOperation(operation)
            apply(.current(snapshot))
            return true
        } catch {
            isPerformingProfileAction = false
            if let profileError = error as? CodexProfileManagerError,
               let reason = profileError.errorDescription
            {
                errorText = "\(failureMessage) \(reason)"
            } else if let claudeError = error as? ClaudeProfileManagerError,
                      let reason = claudeError.errorDescription
            {
                errorText = "\(failureMessage) \(reason)"
            } else {
                errorText = failureMessage
            }
            return false
        }
    }

    private func applySnapshot(_ snapshot: AppUsageSnapshot) {
        let claudeStatesByProfileID = snapshot.claudeUsage.reduce(into: [String: UsageState]()) {
            $0[$1.profileID] = $1.state
        }
        let statusClaudeProfiles = snapshot.claudeProfiles.map { profile in
            StatusItemClaudeProfileState(
                profileID: profile.id,
                name: profile.name,
                state: claudeStatesByProfileID[profile.id]
                    ?? .unavailable(message: "Claude 사용량을 불러오지 못했습니다.")
            )
        }
        // Before any account has been captured the app still shows the live credential's usage.
        let claude = statusClaudeProfiles.first {
            $0.profileID == snapshot.activeClaudeProfileID
        }?.state ?? snapshot.claude
        let codexStatesByProfileID = snapshot.codexUsage.reduce(into: [String: UsageState]()) {
            $0[$1.profileID] = $1.state
        }
        let statusCodexProfiles = snapshot.codexProfiles.map { profile in
            StatusItemCodexProfileState(
                profileID: profile.id,
                name: profile.name,
                state: codexStatesByProfileID[profile.id]
                    ?? .unavailable(message: "Codex 사용량을 불러오지 못했습니다.")
            )
        }
        let codex = statusCodexProfiles.first {
            $0.profileID == snapshot.activeCodexProfileID
        }?.state ?? .unavailable(message: "Codex 사용량을 불러오지 못했습니다.")
        statusItemPresentation = statusClaudeProfiles.isEmpty
            ? StatusItemPresentation(
                claude: snapshot.claude,
                codexProfiles: statusCodexProfiles,
                openRouter: snapshot.openRouter
            )
            : StatusItemPresentation(
                claudeProfiles: statusClaudeProfiles,
                codexProfiles: statusCodexProfiles,
                openRouter: snapshot.openRouter
            )
        applyClaudeProfiles(snapshot, states: claudeStatesByProfileID)
        codexProfiles = snapshot.codexProfiles
        let activeIndex = snapshot.codexProfiles.firstIndex {
            $0.id == snapshot.activeCodexProfileID
        }
        codexQuotaRows = snapshot.codexProfiles.enumerated().map { index, profile in
            let state = codexStatesByProfileID[profile.id]
                ?? .unavailable(message: "Codex 사용량을 불러오지 못했습니다.")
            let usage = usageSnapshot(from: state)
            let quota = presentation(
                service: "Codex \(profile.name)",
                window: "주간",
                value: usage?.weekly
            )
            return CodexProfileQuotaPresentation(
                profileID: profile.id,
                name: profile.name,
                quota: QuotaWindowPresentation(
                    service: quota.service,
                    window: quota.window,
                    remaining: quota.remaining,
                    reset: quota.reset == "초기화 시각 없음" ? "--" : quota.reset,
                    remainingFraction: quota.remainingFraction,
                    pace: quota.pace
                ),
                resetCouponText: usage?.rateLimitResetCreditsAvailableCount.map {
                    "초기화 쿠폰 \($0)개"
                },
                additionalCreditsText: additionalCreditsText(from: usage?.codexCredits),
                freshnessText: freshnessText(for: state),
                isActive: index == activeIndex
            )
        }
        selectedCodexProfileID = snapshot.activeCodexProfileID
        activeCodexProfileName = snapshot.codexProfiles.first {
            $0.id == snapshot.activeCodexProfileID
        }?.name ?? "활성 프로필 없음"

        let claudeSnapshot = usageSnapshot(from: claude)
        let codexSnapshot = usageSnapshot(from: codex)
        claudeFiveHour = presentation(
            service: "Claude",
            window: "5시간",
            value: claudeSnapshot?.fiveHour
        )
        claudeWeekly = presentation(
            service: "Claude",
            window: "주간",
            value: claudeSnapshot?.weekly
        )
        claudeFableWeekly = presentation(
            service: "Claude",
            window: "Fable 주간",
            value: claudeSnapshot?.fableWeekly
        )
        claudeResetCoupon = resetCoupon(from: claudeSnapshot)
        codexWeekly = presentation(
            service: "Codex",
            window: "주간",
            value: codexSnapshot?.weekly
        )
        openRouterBalance = openRouterPresentation(from: snapshot.openRouter)

        let openRouterSnapshot = openRouterSnapshot(from: snapshot.openRouter)
        let capturedDates = [
            claudeSnapshot?.capturedAt,
            codexSnapshot?.capturedAt,
            openRouterSnapshot?.capturedAt,
        ].compactMap { $0 }
        lastRefreshAt = capturedDates.max()
        if let lastRefresh = capturedDates.max() {
            lastRefreshText = "\(dateFormatter.string(from: lastRefresh)) 새로고침"
        } else {
            lastRefreshText = "마지막 새로고침 시각 없음"
        }

        let staleServices = [
            claude.isStale ? "Claude" : nil,
            codex.isStale ? "Codex" : nil,
        ].compactMap { $0 }
        let unavailableServices = [claude, codex].filter(\.isUnavailable).count
        if !staleServices.isEmpty {
            statusText = "일부 항목은 이전 값입니다."
            errorText = "\(staleServices.joined(separator: ", ")) 사용량을 "
                + "새로고침하지 못했습니다. 다시 시도해 주세요."
        } else if unavailableServices == 2 {
            statusText = "사용량을 불러오지 못했습니다"
            errorText = "서비스를 불러오지 못했습니다. 다시 시도해 주세요."
        } else if unavailableServices == 1 {
            statusText = "일부 항목을 불러오지 못했습니다"
            errorText = "일부 서비스를 불러오지 못했습니다. 다시 시도해 주세요."
        } else {
            statusText = "최신 상태"
            errorText = nil
        }

        if !snapshot.removedCodexProfileNames.isEmpty {
            let names = snapshot.removedCodexProfileNames.joined(separator: ", ")
            errorText = "로그인이 풀린 Codex 프로필을 삭제했습니다: \(names). 다시 로그인해 주세요."
        }
    }

    private func applyClaudeProfiles(
        _ snapshot: AppUsageSnapshot,
        states: [String: UsageState]
    ) {
        claudeProfiles = snapshot.claudeProfiles
        let activeIndex = snapshot.claudeProfiles.firstIndex {
            $0.id == snapshot.activeClaudeProfileID
        }
        claudeQuotaRows = snapshot.claudeProfiles.enumerated().map { index, profile in
            let state = states[profile.id]
                ?? .unavailable(message: "Claude 사용량을 불러오지 못했습니다.")
            let value = usageSnapshot(from: state)
            return ClaudeProfileQuotaPresentation(
                profileID: profile.id,
                name: profile.name,
                emailAddress: profile.emailAddress,
                fiveHour: compactPresentation(
                    service: "Claude \(profile.name)",
                    window: "5시간",
                    value: value?.fiveHour
                ),
                weekly: compactPresentation(
                    service: "Claude \(profile.name)",
                    window: "주간",
                    value: value?.weekly
                ),
                resetCoupon: resetCoupon(from: value),
                freshnessText: freshnessText(for: state),
                isActive: index == activeIndex
            )
        }
        selectedClaudeProfileID = snapshot.activeClaudeProfileID
        activeClaudeProfileName = snapshot.claudeProfiles.first {
            $0.id == snapshot.activeClaudeProfileID
        }?.name ?? "활성 계정 없음"
    }

    /// Claude reset credits are one-off promotions rather than a recurring allowance, so an
    /// account that has none (or has used them) shows nothing instead of a zero badge.
    private func resetCoupon(from snapshot: UsageSnapshot?) -> ResetCouponPresentation? {
        guard let count = snapshot?.rateLimitResetCreditsAvailableCount, count > 0 else {
            return nil
        }
        return ResetCouponPresentation(
            countText: "쿠폰 \(count)개",
            expiryText: snapshot?.rateLimitResetCreditsExpireAt.map {
                "\(couponExpiryFormatter.string(from: $0))까지"
            }
        )
    }

    /// Row-sized variant: the account list has no room for a full reset timestamp.
    private func compactPresentation(
        service: String,
        window: String,
        value: QuotaWindow?
    ) -> QuotaWindowPresentation {
        let full = presentation(service: service, window: window, value: value)
        return QuotaWindowPresentation(
            service: full.service,
            window: full.window,
            remaining: full.remaining,
            reset: full.reset == "초기화 시각 없음" ? "--" : full.reset,
            remainingFraction: full.remainingFraction,
            pace: full.pace
        )
    }

    private func clearUsage() {
        statusItemPresentation = StatusItemPresentation(
            claude: .unavailable(message: ""),
            codexProfiles: []
        )
        claudeFiveHour = Self.unavailableWindow(service: "Claude", window: "5시간")
        claudeWeekly = Self.unavailableWindow(service: "Claude", window: "주간")
        claudeFableWeekly = Self.unavailableWindow(service: "Claude", window: "Fable 주간")
        claudeResetCoupon = nil
        codexWeekly = Self.unavailableWindow(service: "Codex", window: "주간")
        openRouterBalance = Self.notConfiguredOpenRouter()
        codexQuotaRows = []
        claudeQuotaRows = []
        lastRefreshText = "마지막 새로고침 시각 없음"
        lastRefreshAt = nil
    }

    private func openRouterPresentation(
        from state: OpenRouterUsageState
    ) -> OpenRouterBalancePresentation {
        switch state {
        case let .fresh(snapshot):
            return configuredOpenRouterPresentation(snapshot: snapshot, status: .configured)
        case let .stale(snapshot, _):
            return configuredOpenRouterPresentation(snapshot: snapshot, status: .stale)
        case .unavailable:
            return OpenRouterBalancePresentation(
                status: .unavailable,
                remaining: "--",
                used: "--",
                allowanceLabel: "총 크레딧",
                allowance: "--",
                tier: nil,
                rateLimit: nil,
                message: "OpenRouter usage is unavailable. Refresh to try again."
            )
        case .notConfigured:
            return Self.notConfiguredOpenRouter()
        }
    }

    private func configuredOpenRouterPresentation(
        snapshot: OpenRouterUsageSnapshot,
        status: OpenRouterBalancePresentation.Status
    ) -> OpenRouterBalancePresentation {
        let used = snapshot.limit == nil ? snapshot.totalUsage : snapshot.usage
        let allowance = snapshot.limit ?? snapshot.totalCredits
        return OpenRouterBalancePresentation(
            status: status,
            remaining: currency(snapshot.remaining),
            used: currency(used),
            allowanceLabel: snapshot.limit == nil ? "총 크레딧" : "한도",
            allowance: currency(allowance),
            tier: snapshot.isFreeTier.map { $0 ? "무료" : "유료" },
            rateLimit: snapshot.rateLimit,
            message: status == .stale
                ? "OpenRouter usage is stale. Refresh to try again."
                : nil
        )
    }

    private func openRouterSnapshot(from state: OpenRouterUsageState) -> OpenRouterUsageSnapshot? {
        switch state {
        case let .fresh(snapshot), let .stale(snapshot, _):
            snapshot
        case .unavailable, .notConfigured:
            nil
        }
    }

    private func currency(_ value: Double) -> String {
        String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func additionalCreditsText(from credits: CodexCredits?) -> String {
        guard let credits else { return "--" }
        if credits.unlimited { return "무제한" }
        if let balance = credits.balance {
            return "\(creditFormatter.string(from: NSNumber(value: balance)) ?? "--") 남음"
        }
        return credits.hasCredits ? "잔액 미제공" : "0 남음"
    }

    private func usageSnapshot(from state: UsageState) -> UsageSnapshot? {
        switch state {
        case .fresh(let snapshot), .stale(let snapshot, _):
            snapshot
        case .unavailable:
            nil
        }
    }

    private func presentation(
        service: String,
        window: String,
        value: QuotaWindow?
    ) -> QuotaWindowPresentation {
        guard let value,
              value.remainingPercent.isFinite,
              value.remainingPercent <= 100
        else { return Self.unavailableWindow(service: service, window: window) }
        let remainingPercent = max(0, value.remainingPercent)
        let roundedPercent = Int(remainingPercent.rounded())
        let reset = value.resetsAt.map {
            "\(dateFormatter.string(from: $0)) 초기화"
        } ?? "초기화 시각 없음"
        return QuotaWindowPresentation(
            service: service,
            window: window,
            remaining: "\(roundedPercent)% 남음",
            reset: reset,
            remainingFraction: remainingPercent / 100,
            pace: value.pace(now: now())
        )
    }

    private func freshnessText(for state: UsageState) -> String {
        switch state {
        case .fresh:
            "최신"
        case .stale:
            "이전 값"
        case .unavailable:
            "조회 실패"
        }
    }

    private static func unavailableWindow(service: String, window: String) -> QuotaWindowPresentation {
        QuotaWindowPresentation(
            service: service,
            window: window,
            remaining: "--",
            reset: "초기화 시각 없음",
            remainingFraction: nil,
            pace: .unknown
        )
    }

    private static func notConfiguredOpenRouter() -> OpenRouterBalancePresentation {
        OpenRouterBalancePresentation(
            status: .notConfigured,
            remaining: "--",
            used: "--",
            allowanceLabel: "총 크레딧",
            allowance: "--",
            tier: nil,
            rateLimit: nil,
            message: OpenRouterUsageState.notConfiguredHint
        )
    }
}

private extension UsageState {
    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
