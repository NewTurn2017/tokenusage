import AppKit
import Foundation
import XCTest
@testable import TokenUsageApp
import TokenUsageCore

@MainActor
final class ClaudeProfilePresentationTests: XCTestCase {
    func testShowsOneRowPerClaudeAccountWithExactlyOneActiveMarker() {
        let model = makeModel()
        let snapshot = twoAccountSnapshot(activeID: "claude-2")

        model.apply(.current(snapshot))

        XCTAssertEqual(model.claudeQuotaRows.map(\.profileID), ["claude-1", "claude-2"])
        XCTAssertEqual(model.claudeQuotaRows.map(\.name), ["personal", "work"])
        XCTAssertEqual(model.claudeQuotaRows.map(\.emailAddress), [
            "personal@example.com",
            "work@example.com",
        ])
        XCTAssertEqual(model.claudeQuotaRows.map(\.fiveHour.remaining), ["91% 남음", "64% 남음"])
        XCTAssertEqual(model.claudeQuotaRows.map(\.weekly.remaining), ["78% 남음", "22% 남음"])
        XCTAssertEqual(model.claudeQuotaRows.filter(\.isActive).map(\.profileID), ["claude-2"])
        XCTAssertEqual(model.selectedClaudeProfileID, "claude-2")
        XCTAssertEqual(model.activeClaudeProfileName, "work")
    }

    func testEachAccountRowShowsWhenItsWindowsReset() {
        let model = makeModel()
        let fiveHourReset = Date(timeIntervalSince1970: 1_787_003_600)
        let weeklyReset = Date(timeIntervalSince1970: 1_787_432_000)
        let snapshot = AppUsageSnapshot(
            claude: .unavailable(message: ""),
            codexUsage: [],
            codexProfiles: [],
            activeCodexProfileID: nil,
            openRouter: .notConfigured(message: ""),
            removedCodexProfileNames: [],
            claudeUsage: [
                ClaudeProfileUsage(
                    profileID: "claude-1",
                    state: .fresh(UsageSnapshot(
                        capturedAt: Date(timeIntervalSince1970: 1_787_000_000),
                        fiveHour: QuotaWindow(remainingPercent: 91, resetsAt: fiveHourReset),
                        weekly: QuotaWindow(remainingPercent: 78, resetsAt: weeklyReset)
                    ))
                ),
                ClaudeProfileUsage(
                    profileID: "claude-2",
                    state: .fresh(usage(fiveHour: 64, weekly: 22))
                ),
            ],
            claudeProfiles: [
                ClaudeProfileMetadata(id: "claude-1", name: "personal"),
                ClaudeProfileMetadata(id: "claude-2", name: "work"),
            ],
            activeClaudeProfileID: "claude-1"
        )

        model.apply(.current(snapshot))

        // The inactive account's reset times are only visible here, so every row carries its own.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.dateFormat = "M월 d일 a h:mm"
        XCTAssertEqual(
            model.claudeQuotaRows[0].fiveHour.reset,
            "\(formatter.string(from: fiveHourReset)) 초기화"
        )
        XCTAssertEqual(
            model.claudeQuotaRows[0].weekly.reset,
            "\(formatter.string(from: weeklyReset)) 초기화"
        )
        XCTAssertTrue(model.claudeQuotaRows[0].accessibilityLabel.contains("초기화"))
        // An unknown reset stays a quiet placeholder in the row and out of the spoken label.
        XCTAssertEqual(model.claudeQuotaRows[1].fiveHour.reset, "--")
        XCTAssertFalse(model.claudeQuotaRows[1].accessibilityLabel.contains("--"))
    }

    func testEachAccountRowShowsItsResetCouponAndDeadlineButHidesZero() {
        let model = makeModel()
        func withCoupons(_ count: Int?, expiresAt: Date?) -> UsageSnapshot {
            UsageSnapshot(
                capturedAt: Date(timeIntervalSince1970: 1_787_000_000),
                fiveHour: QuotaWindow(remainingPercent: 91, resetsAt: nil),
                weekly: QuotaWindow(remainingPercent: 2, resetsAt: nil),
                rateLimitResetCreditsAvailableCount: count,
                rateLimitResetCreditsExpireAt: expiresAt
            )
        }
        let snapshot = AppUsageSnapshot(
            claude: .unavailable(message: ""),
            codexUsage: [],
            codexProfiles: [],
            activeCodexProfileID: nil,
            openRouter: .notConfigured(message: ""),
            removedCodexProfileNames: [],
            claudeUsage: [
                ClaudeProfileUsage(
                    profileID: "claude-1",
                    // 2026-10-22T16:00:00Z
                    state: .fresh(withCoupons(1, expiresAt: Date(timeIntervalSince1970: 1_792_684_800)))
                ),
                ClaudeProfileUsage(profileID: "claude-2", state: .fresh(withCoupons(0, expiresAt: nil))),
                ClaudeProfileUsage(profileID: "claude-3", state: .fresh(withCoupons(nil, expiresAt: nil))),
            ],
            claudeProfiles: [
                ClaudeProfileMetadata(id: "claude-1", name: "personal"),
                ClaudeProfileMetadata(id: "claude-2", name: "work"),
                ClaudeProfileMetadata(id: "claude-3", name: "team"),
            ],
            activeClaudeProfileID: "claude-1"
        )

        model.apply(.current(snapshot))

        XCTAssertEqual(
            model.claudeQuotaRows.map(\.resetCoupon),
            [ResetCouponPresentation(countText: "쿠폰 1개", expiryText: "10/22까지"), nil, nil]
        )
        XCTAssertTrue(
            model.claudeQuotaRows[0].accessibilityLabel.contains("초기화 쿠폰 1개, 10/22까지 사용"),
            model.claudeQuotaRows[0].accessibilityLabel
        )
        XCTAssertFalse(model.claudeQuotaRows[1].accessibilityLabel.contains("쿠폰"))
    }

    func testTheActiveAccountDrivesTheDetailCards() {
        let model = makeModel()

        model.apply(.current(twoAccountSnapshot(activeID: "claude-2")))

        XCTAssertEqual(model.claudeFiveHour.remaining, "64% 남음")
        XCTAssertEqual(model.claudeWeekly.remaining, "22% 남음")
    }

    func testTheMenuBarGetsAFiveHourOverWeeklyColumnForEachAccount() {
        let model = makeModel()

        model.apply(.current(twoAccountSnapshot(activeID: "claude-1")))

        let presentation = model.statusItemPresentation
        XCTAssertEqual(
            presentation.claudeProfiles.map(\.fiveHourText),
            ["91%", "64%"]
        )
        XCTAssertEqual(presentation.claudeProfiles.map(\.weeklyText), ["78%", "22%"])
        // The menu bar carries 5-hour over weekly per account; Fable stays in the popover.
        XCTAssertEqual(presentation.visibleLabels, ["91%", "78%", "64%", "22%"])
        print(
            "CLAUDE_QA menu_bar columns=2 "
                + "values=\(presentation.claudeProfiles.map { "\($0.fiveHourText)/\($0.weeklyText)" }.joined(separator: ","))"
        )
    }

    func testATeamAccountShowsItsFableLimitWhereTheWeeklyOneWouldBe() {
        let model = makeModel()
        let fableReset = Date(timeIntervalSince1970: 1_787_432_000)
        let snapshot = AppUsageSnapshot(
            claude: .unavailable(message: ""),
            codexUsage: [],
            codexProfiles: [],
            activeCodexProfileID: nil,
            openRouter: .notConfigured(message: ""),
            removedCodexProfileNames: [],
            claudeUsage: [
                ClaudeProfileUsage(
                    profileID: "max",
                    state: .fresh(usage(fiveHour: 96, weekly: 54, fable: 70))
                ),
                ClaudeProfileUsage(
                    profileID: "team",
                    state: .fresh(UsageSnapshot(
                        capturedAt: Date(timeIntervalSince1970: 1_787_000_000),
                        fiveHour: QuotaWindow(remainingPercent: 68, resetsAt: nil),
                        fableWeekly: QuotaWindow(remainingPercent: 61, resetsAt: fableReset)
                    ))
                ),
                ClaudeProfileUsage(profileID: "failed", state: .unavailable(message: "")),
            ],
            claudeProfiles: [
                ClaudeProfileMetadata(id: "max", name: "claude-2020"),
                ClaudeProfileMetadata(id: "team", name: "claude2"),
                ClaudeProfileMetadata(id: "failed", name: "claude3"),
            ],
            // Fable is read per account, so an inactive account still shows its own.
            activeClaudeProfileID: "max"
        )

        model.apply(.current(snapshot))

        let rows = model.claudeQuotaRows
        XCTAssertEqual(rows.map { $0.windows.map(\.window) }, [
            ["5시간", "주간", "Fable"],
            ["5시간", "Fable"],
            // Nothing reported keeps the placeholder pair instead of an empty row.
            ["5시간", "주간"],
        ])
        XCTAssertEqual(rows[1].fable?.remaining, "61% 남음")
        XCTAssertEqual(rows[1].windows.map(\.percentText), ["68%", "61%"])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.dateFormat = "M월 d일 a h:mm"
        XCTAssertEqual(rows[1].fable?.reset, "\(formatter.string(from: fableReset)) 초기화")
        XCTAssertTrue(rows[1].accessibilityLabel.contains("Fable 61% 남음"), rows[1].accessibilityLabel)
        XCTAssertFalse(rows[1].accessibilityLabel.contains("주간"), rows[1].accessibilityLabel)
        XCTAssertNil(rows[2].fable)

        // The menu bar keeps one column per account: weekly when the plan has it, else Fable.
        let menuBar = model.statusItemPresentation.claudeProfiles
        XCTAssertEqual(menuBar.map(\.weeklyText), ["54%", "61%", "--"])
        XCTAssertEqual(menuBar.map(\.weeklyIsFable), [false, true, false])
        let view = StatusItemView(presentation: model.statusItemPresentation)
        XCTAssertTrue(
            view.accessibilityLabel()?.contains("claude2 68%, Fable weekly 61%") == true,
            view.accessibilityLabel() ?? ""
        )
    }

    func testAMenuBarWithTwoClaudeAccountsStillFitsTheStatusBarHeight() {
        let model = makeModel()
        model.apply(.current(twoAccountSnapshot(activeID: "claude-1")))
        let view = StatusItemView(presentation: model.statusItemPresentation)

        let size = view.intrinsicContentSize

        XCTAssertLessThanOrEqual(size.height, NSStatusBar.system.thickness)
        XCTAssertGreaterThan(size.width, 0)
        print("CLAUDE_QA status_item size=\(size.width)x\(size.height)")
    }

    func testBeforeAnyAccountIsCapturedTheLiveCredentialUsageIsStillShown() {
        let model = makeModel()
        let snapshot = AppUsageSnapshot(
            claude: .fresh(usage(fiveHour: 12, weekly: 34)),
            codexUsage: [],
            codexProfiles: [],
            activeCodexProfileID: nil
        )

        model.apply(.current(snapshot))

        XCTAssertTrue(model.claudeQuotaRows.isEmpty)
        XCTAssertEqual(model.claudeFiveHour.remaining, "12% 남음")
        XCTAssertEqual(model.statusItemPresentation.claudeFiveHourText, "12%")
    }

    func testSwitchingAccountsAsksTheServiceAndKeepsTheNewSelection() async {
        let actions = MockClaudeActions(result: twoAccountSnapshot(activeID: "claude-2"))
        let model = makeModel(actions: actions)
        model.apply(.current(twoAccountSnapshot(activeID: "claude-1")))

        await model.selectClaudeProfile(id: "claude-2")

        XCTAssertEqual(actions.selectedIDs, ["claude-2"])
        XCTAssertEqual(model.selectedClaudeProfileID, "claude-2")
        XCTAssertFalse(model.errorText?.contains("전환하지 못했습니다") ?? false)
    }

    func testAFailedSwitchRestoresThePreviousSelectionAndExplainsWhy() async {
        let actions = MockClaudeActions(
            result: twoAccountSnapshot(activeID: "claude-1"),
            error: ClaudeProfileManagerError.accountIdentityMismatch
        )
        let model = makeModel(actions: actions)
        model.apply(.current(twoAccountSnapshot(activeID: "claude-1")))

        await model.selectClaudeProfile(id: "claude-2")

        XCTAssertEqual(model.selectedClaudeProfileID, "claude-1")
        let errorText = model.errorText ?? ""
        XCTAssertTrue(errorText.contains("전환하지 못했습니다"), errorText)
        XCTAssertTrue(errorText.contains("선택한 계정과 다릅니다"), errorText)
    }

    func testSavingTheCurrentAccountRequiresAName() async {
        let actions = MockClaudeActions(result: twoAccountSnapshot(activeID: "claude-1"))
        let model = makeModel(actions: actions)
        model.claudeProfileName = "   "

        await model.saveCurrentClaudeProfile()

        XCTAssertTrue(actions.savedNames.isEmpty)
        XCTAssertEqual(model.errorText, "저장할 계정 이름을 입력해 주세요.")
    }

    func testSavingTheCurrentAccountPassesTheTrimmedName() async {
        let actions = MockClaudeActions(result: twoAccountSnapshot(activeID: "claude-1"))
        let model = makeModel(actions: actions)
        model.claudeProfileName = "  work  "

        await model.saveCurrentClaudeProfile()

        XCTAssertEqual(actions.savedNames, ["work"])
    }

    func testStartingANewLoginPassesTheTrimmedName() async {
        let actions = MockClaudeActions(result: twoAccountSnapshot(activeID: "claude-1"))
        let model = makeModel(actions: actions)
        model.claudeProfileName = "  work  "

        await model.addClaudeAccount()

        XCTAssertEqual(actions.addedNames, ["work"])
        XCTAssertTrue(actions.savedNames.isEmpty, "a new login is not a capture of the current one")
    }

    func testANewLoginRequiresANameBeforeOpeningABrowser() async {
        let actions = MockClaudeActions(result: twoAccountSnapshot(activeID: "claude-1"))
        let model = makeModel(actions: actions)
        model.claudeProfileName = ""

        await model.addClaudeAccount()

        XCTAssertTrue(actions.addedNames.isEmpty)
        XCTAssertEqual(model.errorText, "로그인할 계정 이름을 먼저 입력해 주세요.")
    }

    func testAFailedLoginExplainsWhyInsteadOfFailingSilently() async {
        let actions = MockClaudeActions(
            result: twoAccountSnapshot(activeID: "claude-1"),
            error: ClaudeProfileManagerError.loginUnavailable
        )
        let model = makeModel(actions: actions)
        model.claudeProfileName = "work"

        await model.addClaudeAccount()

        let errorText = model.errorText ?? ""
        XCTAssertTrue(errorText.contains("추가하지 못했습니다"), errorText)
        XCTAssertTrue(errorText.contains("claude 실행 파일"), errorText)
    }

    func testAnAccountCanBeDeletedWithoutActivatingItFirst() async {
        let actions = MockClaudeActions(result: twoAccountSnapshot(activeID: "claude-1"))
        let model = makeModel(actions: actions)
        model.apply(.current(twoAccountSnapshot(activeID: "claude-1")))

        await model.deleteClaudeProfile(id: "claude-2")

        XCTAssertEqual(actions.deletedIDs, ["claude-2"])
    }

    // MARK: - Fixtures

    private func makeModel(actions: MockClaudeActions? = nil) -> AppViewModel {
        AppViewModel(
            coordinator: PassthroughCoordinator(),
            profileActions: UnusedCodexActions(),
            claudeProfileActions: actions ?? MockClaudeActions(
                result: twoAccountSnapshot(activeID: "claude-1")
            ),
            locale: Locale(identifier: "ko_KR"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func twoAccountSnapshot(activeID: String) -> AppUsageSnapshot {
        AppUsageSnapshot(
            claude: .unavailable(message: ""),
            codexUsage: [],
            codexProfiles: [],
            activeCodexProfileID: nil,
            openRouter: .notConfigured(message: ""),
            removedCodexProfileNames: [],
            claudeUsage: [
                ClaudeProfileUsage(
                    profileID: "claude-1",
                    state: .fresh(usage(fiveHour: 91, weekly: 78))
                ),
                ClaudeProfileUsage(
                    profileID: "claude-2",
                    state: .fresh(usage(fiveHour: 64, weekly: 22, fable: 40))
                ),
            ],
            claudeProfiles: [
                ClaudeProfileMetadata(
                    id: "claude-1",
                    name: "personal",
                    emailAddress: "personal@example.com"
                ),
                ClaudeProfileMetadata(
                    id: "claude-2",
                    name: "work",
                    emailAddress: "work@example.com"
                ),
            ],
            activeClaudeProfileID: activeID
        )
    }

    private func usage(
        fiveHour: Double,
        weekly: Double,
        fable: Double? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_787_000_000),
            fiveHour: QuotaWindow(remainingPercent: fiveHour, resetsAt: nil),
            weekly: QuotaWindow(remainingPercent: weekly, resetsAt: nil),
            fableWeekly: fable.map { QuotaWindow(remainingPercent: $0, resetsAt: nil) }
        )
    }
}

private final class MockClaudeActions: ClaudeProfileActionHandling, @unchecked Sendable {
    private let lock = NSLock()
    private let result: AppUsageSnapshot
    private let error: (any Error)?
    private var selected: [String] = []
    private var saved: [String] = []
    private var deleted: [String] = []
    private var added: [String] = []

    init(result: AppUsageSnapshot, error: (any Error)? = nil) {
        self.result = result
        self.error = error
    }

    func selectClaudeProfile(id: String) async throws -> AppUsageSnapshot {
        try record(id, into: \.selected)
    }

    func saveCurrentClaudeProfile(named name: String) async throws -> AppUsageSnapshot {
        try record(name, into: \.saved)
    }

    func addClaudeAccount(named name: String) async throws -> AppUsageSnapshot {
        try record(name, into: \.added)
    }

    func deleteClaudeProfile(id: String) async throws -> AppUsageSnapshot {
        try record(id, into: \.deleted)
    }

    var selectedIDs: [String] { lock.withLock { selected } }
    var savedNames: [String] { lock.withLock { saved } }
    var deletedIDs: [String] { lock.withLock { deleted } }
    var addedNames: [String] { lock.withLock { added } }

    private func record(
        _ value: String,
        into keyPath: ReferenceWritableKeyPath<MockClaudeActions, [String]>
    ) throws -> AppUsageSnapshot {
        try lock.withLock {
            self[keyPath: keyPath].append(value)
            if let error { throw error }
            return result
        }
    }
}

private struct UnusedCodexActions: CodexProfileActionHandling {
    func selectProfile(id: String) async throws -> AppUsageSnapshot {
        throw CodexProfileManagerError.profileNotFound
    }

    func saveCurrentProfile(named name: String) async throws -> AppUsageSnapshot {
        throw CodexProfileManagerError.profileNotFound
    }

    func addAccount(named name: String) async throws -> AppUsageSnapshot {
        throw CodexProfileManagerError.profileNotFound
    }

    func deleteProfile(id: String) async throws -> AppUsageSnapshot {
        throw CodexProfileManagerError.profileNotFound
    }
}

private actor PassthroughCoordinator: AppUsageCoordinating {
    func start() async {}

    func stateChanges() async -> AsyncStream<RefreshState<AppUsageSnapshot>> {
        AsyncStream { $0.finish() }
    }

    func requestRefresh() async {}

    func performProfileOperation(
        _ operation: @escaping @Sendable () async throws -> AppUsageSnapshot
    ) async throws -> AppUsageSnapshot {
        try await operation()
    }

    func stop() async {}
}
