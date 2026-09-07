import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TokenUsageApp
import TokenUsageCore

@MainActor
final class AppViewModelTests: XCTestCase {
    func testPresentsOrderedCodexQuotaRowPerProfileWithExactlyOneActiveMarker() {
        let base = populatedSnapshot(activeProfileID: "profile-2")
        let snapshot = AppUsageSnapshot(
            claude: base.claude,
            codexUsage: [
                CodexProfileUsage(
                    profileID: "profile-1",
                    state: .fresh(codexSnapshot(remaining: 81))
                ),
                CodexProfileUsage(
                    profileID: "profile-2",
                    state: .stale(
                        lastGood: codexSnapshot(remaining: 37),
                        message: "synthetic stale sentinel"
                    )
                ),
            ],
            codexProfiles: base.codexProfiles,
            activeCodexProfileID: "profile-2"
        )
        let model = makeDependencies(snapshot: snapshot).model

        model.apply(.current(snapshot))

        XCTAssertEqual(model.codexQuotaRows.map(\.profileID), ["profile-1", "profile-2"])
        XCTAssertEqual(model.codexQuotaRows.map(\.name), ["Personal", "codex2"])
        XCTAssertEqual(model.codexQuotaRows.map(\.quota.remaining), ["81% 남음", "37% 남음"])
        XCTAssertEqual(model.codexQuotaRows.map(\.freshnessText), ["최신", "이전 값"])
        XCTAssertEqual(model.codexQuotaRows.filter(\.isActive).map(\.profileID), ["profile-2"])
        print(
            "TASK6_QA two_rows ids=profile-1,profile-2 values=81,37 "
                + "states=Fresh,Stale active_count=1 active_id=profile-2"
        )
    }

    func testPresentsEveryApprovedQuotaFieldIncludingFableResetAndCodex2Selection() {
        let snapshot = populatedSnapshot(activeProfileID: "profile-2")
        let dependencies = makeDependencies(snapshot: snapshot)
        let model = dependencies.model

        model.apply(.current(snapshot))

        XCTAssertEqual(model.claudeFiveHour.remaining, "75% 남음")
        XCTAssertEqual(model.claudeFiveHour.reset, "8월 4일 오전 9:00 초기화")
        XCTAssertEqual(model.claudeWeekly.remaining, "42% 남음")
        XCTAssertEqual(model.claudeWeekly.reset, "8월 10일 오후 5:30 초기화")
        XCTAssertEqual(model.claudeFableWeekly.remaining, "84% 남음")
        XCTAssertEqual(model.claudeFableWeekly.reset, "8월 11일 오후 12:15 초기화")
        XCTAssertEqual(model.codexWeekly.remaining, "63% 남음")
        XCTAssertEqual(model.codexWeekly.reset, "8월 9일 오전 7:45 초기화")
        XCTAssertEqual(model.openRouterBalance.status, .configured)
        XCTAssertEqual(model.openRouterBalance.remaining, "$25.82")
        XCTAssertEqual(model.openRouterBalance.used, "$574.18")
        XCTAssertEqual(model.openRouterBalance.allowanceLabel, "총 크레딧")
        XCTAssertEqual(model.openRouterBalance.allowance, "$600.00")
        XCTAssertEqual(model.openRouterBalance.tier, "유료")
        XCTAssertEqual(model.openRouterBalance.rateLimit, "-1/10s")
        XCTAssertEqual(model.activeCodexProfileName, "codex2")
        XCTAssertEqual(model.selectedCodexProfileID, "profile-2")
        XCTAssertEqual(model.lastRefreshText, "8월 3일 오후 11:10 새로고침")
        XCTAssertEqual(model.statusText, "최신 상태")
        XCTAssertNil(model.errorText)

        XCTAssertEqual(
            model.claudeFableWeekly.accessibilityLabel,
            "Claude, Fable 주간 창, 84% 남음, 8월 11일 오후 12:15 초기화"
        )
        XCTAssertEqual(
            model.codexWeekly.accessibilityLabel,
            "Codex, 주간 창, 63% 남음, 8월 9일 오전 7:45 초기화"
        )

        let storedProperties = Mirror(reflecting: model).children.compactMap(\.label).joined(separator: " ")
        XCTAssertFalse(storedProperties.localizedCaseInsensitiveContains("statistics"))
        XCTAssertFalse(storedProperties.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(storedProperties.localizedCaseInsensitiveContains("cost"))
        XCTAssertFalse(storedProperties.localizedCaseInsensitiveContains("history"))
    }

    func testOpenRouterNotConfiguredIsFriendlyAndDoesNotChangeClaudeCodexStatus() {
        let base = populatedSnapshot(activeProfileID: "profile-2")
        let snapshot = AppUsageSnapshot(
            claude: base.claude,
            codexUsage: base.codexUsage,
            codexProfiles: base.codexProfiles,
            activeCodexProfileID: base.activeCodexProfileID,
            openRouter: .notConfigured(message: "ignored test detail")
        )
        let dependencies = makeDependencies(snapshot: snapshot)

        dependencies.model.apply(.current(snapshot))

        XCTAssertEqual(dependencies.model.openRouterBalance.status, .notConfigured)
        XCTAssertEqual(dependencies.model.openRouterBalance.remaining, "--")
        XCTAssertEqual(
            dependencies.model.openRouterBalance.message,
            OpenRouterUsageState.notConfiguredHint
        )
        XCTAssertEqual(dependencies.model.statusText, "최신 상태")
        XCTAssertNil(dependencies.model.errorText)
    }

    func testOpenRouterLimitPresentationUsesLimitInsteadOfCredits() {
        let base = populatedSnapshot(activeProfileID: "profile-2")
        let limitSnapshot = OpenRouterUsageSnapshot(
            capturedAt: date("2026-08-03T23:10:00Z"),
            usage: 50,
            totalCredits: 900,
            totalUsage: 10,
            limit: 100,
            isFreeTier: true,
            rateLimit: nil
        )
        let snapshot = AppUsageSnapshot(
            claude: base.claude,
            codexUsage: base.codexUsage,
            codexProfiles: base.codexProfiles,
            activeCodexProfileID: base.activeCodexProfileID,
            openRouter: .fresh(limitSnapshot)
        )
        let dependencies = makeDependencies(snapshot: snapshot)

        dependencies.model.apply(.current(snapshot))

        XCTAssertEqual(dependencies.model.openRouterBalance.remaining, "$50.00")
        XCTAssertEqual(dependencies.model.openRouterBalance.used, "$50.00")
        XCTAssertEqual(dependencies.model.openRouterBalance.allowanceLabel, "한도")
        XCTAssertEqual(dependencies.model.openRouterBalance.allowance, "$100.00")
        XCTAssertEqual(dependencies.model.openRouterBalance.tier, "무료")
    }

    func testAutoRemovedCodexProfilesAreReportedAndClearedOnTheNextRefresh() {
        let base = populatedSnapshot(activeProfileID: "profile-2")
        let removed = AppUsageSnapshot(
            claude: base.claude,
            codexUsage: base.codexUsage.filter { $0.profileID == "profile-2" },
            codexProfiles: base.codexProfiles.filter { $0.id == "profile-2" },
            activeCodexProfileID: "profile-2",
            openRouter: base.openRouter,
            removedCodexProfileNames: ["Personal"]
        )
        let model = makeDependencies(snapshot: removed).model

        model.apply(.current(removed))

        XCTAssertEqual(model.codexProfiles.map(\.id), ["profile-2"])
        XCTAssertEqual(
            model.errorText,
            "로그인이 풀린 Codex 프로필을 삭제했습니다: Personal. 다시 로그인해 주세요."
        )

        model.apply(.current(base))

        XCTAssertNil(model.errorText)
    }

    func testStaleAndUnavailableServicesKeepLastGoodValuesWithoutExposingProviderPayload() {
        let sentinel = "GENERATED-SENTINEL-DO-NOT-EXPOSE"
        let base = populatedSnapshot(activeProfileID: "profile-2")
        let mixed = AppUsageSnapshot(
            claude: .stale(
                lastGood: usageSnapshot(from: base.claude)!,
                message: "Malformed response body: {\"access_token\":\"\(sentinel)\"}"
            ),
            codexUsage: [
                CodexProfileUsage(
                    profileID: "profile-2",
                    state: .unavailable(message: "secret response body \(sentinel)")
                )
            ],
            codexProfiles: base.codexProfiles,
            activeCodexProfileID: base.activeCodexProfileID
        )
        let dependencies = makeDependencies(snapshot: mixed)
        let model = dependencies.model

        model.apply(.current(mixed))

        XCTAssertEqual(model.claudeFiveHour.remaining, "75% 남음")
        XCTAssertEqual(model.codexWeekly.remaining, "--")
        XCTAssertEqual(model.codexWeekly.reset, "초기화 시각 없음")
        XCTAssertEqual(model.statusText, "일부 항목은 이전 값입니다.")
        XCTAssertEqual(
            model.errorText,
            "Claude 사용량을 새로고침하지 못했습니다. 다시 시도해 주세요."
        )
        assertDoesNotExpose(sentinel, model: model)
        assertDoesNotExpose("response body", model: model)
        assertDoesNotExpose("access_token", model: model)

        model.apply(.failed(RefreshFailure(MalformedProviderError(payload: sentinel))))

        XCTAssertEqual(model.claudeFiveHour.remaining, "--")
        XCTAssertEqual(model.codexWeekly.remaining, "--")
        XCTAssertEqual(model.statusText, "사용량을 불러오지 못했습니다")
        XCTAssertEqual(model.errorText, "새로고침에 실패했습니다. 다시 시도해 주세요.")
        assertDoesNotExpose(sentinel, model: model)
    }

    func testStaleWarningIdentifiesClaudeAsTheFailedProvider() {
        let base = populatedSnapshot(activeProfileID: "profile-2")
        let snapshot = AppUsageSnapshot(
            claude: .stale(
                lastGood: usageSnapshot(from: base.claude)!,
                message: "Claude usage returned HTTP status 429."
            ),
            codexUsage: base.codexUsage,
            codexProfiles: base.codexProfiles,
            activeCodexProfileID: base.activeCodexProfileID
        )
        let model = makeDependencies(snapshot: snapshot).model

        model.apply(.current(snapshot))

        XCTAssertEqual(
            model.errorText,
            "Claude 사용량을 새로고침하지 못했습니다. 다시 시도해 주세요."
        )
    }

    func testSubscribesBeforeStartingAndMapsCoordinatorState() async {
        let snapshot = populatedSnapshot(activeProfileID: "profile-2")
        let dependencies = makeDependencies(snapshot: snapshot)
        let model = dependencies.model
        let coordinatorEvents = await dependencies.coordinator.eventChanges()
        var eventIterator = coordinatorEvents.makeAsyncIterator()
        let statusUpdated = expectation(description: "coordinator state reached the MainActor model")
        let cancellable = model.$statusText
            .dropFirst()
            .filter { $0 == "최신 상태" }
            .sink { _ in statusUpdated.fulfill() }

        model.start()
        let subscribedEvent = await eventIterator.next()
        let startedEvent = await eventIterator.next()
        XCTAssertEqual(subscribedEvent, .subscribed)
        XCTAssertEqual(startedEvent, .started)
        await dependencies.coordinator.send(.current(snapshot))
        await fulfillment(of: [statusUpdated], timeout: 2)

        XCTAssertEqual(model.activeCodexProfileName, "codex2")
        await model.refreshNow()
        let refreshEvent = await eventIterator.next()
        XCTAssertEqual(refreshEvent, .refreshRequested)

        await model.stop()
        let stoppedEvent = await eventIterator.next()
        XCTAssertEqual(stoppedEvent, .stopped)
        withExtendedLifetime(cancellable) {}
    }

    func testRefreshProfileSaveLoginDeleteAndQuitActionsUseProtocols() async {
        let initial = populatedSnapshot(activeProfileID: "profile-1")
        let selected = populatedSnapshot(activeProfileID: "profile-2")
        let dependencies = makeDependencies(snapshot: initial, actionResult: selected)
        let model = dependencies.model
        let actionEvents = await dependencies.actions.eventChanges()
        var actionIterator = actionEvents.makeAsyncIterator()
        let coordinatorEvents = await dependencies.coordinator.eventChanges()
        var coordinatorIterator = coordinatorEvents.makeAsyncIterator()
        model.apply(.current(initial))

        await model.refreshNow()
        let refreshEvent = await coordinatorIterator.next()
        XCTAssertEqual(refreshEvent, .refreshRequested)

        await model.selectCodexProfile(id: "profile-2")
        let selectedEvent = await actionIterator.next()
        XCTAssertEqual(selectedEvent, .selected("profile-2"))
        XCTAssertEqual(model.selectedCodexProfileID, "profile-2")
        XCTAssertEqual(model.activeCodexProfileName, "codex2")
        XCTAssertEqual(model.codexQuotaRows.filter(\.isActive).map(\.profileID), ["profile-2"])
        XCTAssertEqual(model.codexQuotaRows.count, 2)
        print("TASK6_QA switch_success rows=2 active_count=1 active_id=profile-2")

        XCTAssertEqual(model.profileName, "codex2")
        await model.saveCurrentProfile()
        let savedEvent = await actionIterator.next()
        XCTAssertEqual(savedEvent, .saved("codex2"))

        model.profileName = "work"
        await model.addAccount()
        let addedEvent = await actionIterator.next()
        XCTAssertEqual(addedEvent, .added("work"))

        await model.deleteSelectedProfile()
        let deletedEvent = await actionIterator.next()
        XCTAssertEqual(deletedEvent, .deleted("profile-2"))

        model.quit()
        XCTAssertEqual(dependencies.quitSpy.count, 1)
    }

    func testDeletingAProfileThatCannotBeActivatedNeverGoesThroughSelection() async {
        let initial = populatedSnapshot(activeProfileID: "profile-1")
        let dependencies = makeDependencies(
            snapshot: initial,
            actionResult: initial,
            actionError: CodexProfileManagerError.accountValidationFailed
        )
        let model = dependencies.model
        let actionEvents = await dependencies.actions.eventChanges()
        var actionIterator = actionEvents.makeAsyncIterator()
        model.apply(.current(initial))

        // The signed-out profile refuses activation, so it can never become the selected one.
        await model.selectCodexProfile(id: "profile-2")
        let selectionAttempt = await actionIterator.next()
        XCTAssertEqual(selectionAttempt, .selected("profile-2"))
        XCTAssertEqual(model.selectedCodexProfileID, "profile-1")

        await model.deleteCodexProfile(id: "profile-2")

        let deletedEvent = await actionIterator.next()
        XCTAssertEqual(deletedEvent, .deleted("profile-2"))
    }

    func testMalformedActionErrorIsSanitizedAndSelectionRollsBack() async {
        let sentinel = "GENERATED-MALFORMED-ACTION-SENTINEL"
        let initial = populatedSnapshot(activeProfileID: "profile-1")
        let dependencies = makeDependencies(
            snapshot: initial,
            actionResult: initial,
            actionError: MalformedProviderError(payload: sentinel)
        )
        let model = dependencies.model
        model.apply(.current(initial))

        await model.selectCodexProfile(id: "profile-2")

        XCTAssertEqual(model.selectedCodexProfileID, "profile-1")
        XCTAssertEqual(model.errorText, "Codex profile could not be selected.")
        assertDoesNotExpose(sentinel, model: model)
    }

    func testTypedSwitchFailureRestoresSelectionAndShowsOnlySafeReason() async {
        let initial = populatedSnapshot(activeProfileID: "profile-1")
        let dependencies = makeDependencies(
            snapshot: initial,
            actionResult: initial,
            actionError: CodexProfileManagerError.profileNotFound
        )
        let model = dependencies.model
        model.apply(.current(initial))

        await model.selectCodexProfile(id: "profile-2")

        XCTAssertEqual(model.selectedCodexProfileID, "profile-1")
        XCTAssertEqual(
            model.errorText,
            "Codex profile could not be selected. The Codex profile was not found."
        )
        print("TASK6_QA switch_failure restored=profile-1 reason=profile-not-found-safe")
    }

    func testLoginPresentationAndActionsStayGenericWithoutURLOrSecret() {
        let sentinel = "GENERATED-LOGIN-SECRET"
        let rawURL = "https://auth.openai.com/device?token=\(sentinel)"
        let snapshot = populatedSnapshot(activeProfileID: "profile-1")
        let spy = LoginPresentationSpy()
        let model = AppViewModel(
            coordinator: MockCoordinator(),
            profileActions: MockProfileActions(result: snapshot, error: nil),
            loginAttemptState: { CodexLoginAttemptState(isActive: true, canReopen: true) },
            reopenCodexSignIn: { spy.recordReopen(); return true },
            cancelCodexSignIn: { spy.recordCancel() }
        )

        model.updateCodexLoginAttemptPresentation()
        model.reopenCodexSignIn()
        model.cancelCodexSignIn()

        XCTAssertEqual(model.codexLoginStatusText, "Sign-in is in progress.")
        XCTAssertEqual(model.reopenCodexSignInTitle, "Reopen sign-in")
        XCTAssertEqual(model.cancelCodexSignInTitle, "Cancel")
        XCTAssertEqual(spy.counts, [1, 1])
        let visible = [
            model.codexLoginStatusText,
            model.reopenCodexSignInTitle,
            model.cancelCodexSignInTitle,
            model.errorText,
        ].compactMap { $0 }.joined(separator: " ")
        XCTAssertFalse(visible.contains(rawURL))
        XCTAssertFalse(visible.contains(sentinel))
        XCTAssertFalse(visible.localizedCaseInsensitiveContains("token="))
        print("TASK6_QA login_controls status=generic reopen=generic cancel=generic raw_url_matches=0 secret_matches=0")
    }

    func testTypedBrowserLoginFailureShowsSafeReasonWithoutDiagnosticPayload() async {
        let snapshot = populatedSnapshot(activeProfileID: "profile-1")
        let dependencies = makeDependencies(
            snapshot: snapshot,
            actionResult: snapshot,
            actionError: CodexProfileManagerError.loginBrowserOpenFailed
        )
        let model = dependencies.model
        model.profileName = "Work"

        await model.addAccount()

        XCTAssertEqual(
            model.errorText,
            "Codex account could not be added. The Codex sign-in browser could not be opened."
        )
        XCTAssertFalse(model.errorText?.contains("http") ?? true)
        XCTAssertFalse(model.errorText?.localizedCaseInsensitiveContains("token") ?? true)
    }

    func testPopoverSurfaceBuildsAtCompactDesignSystemWidth() {
        let snapshot = populatedSnapshot(activeProfileID: "profile-2")
        let dependencies = makeDependencies(snapshot: snapshot)
        dependencies.model.apply(.current(snapshot))

        let surface = UsagePopoverView(model: dependencies.model)

        XCTAssertEqual(String(describing: type(of: surface)), "UsagePopoverView")
        XCTAssertEqual(PopoverDesignSystem.Size.popoverWidth, 384)
        XCTAssertLessThan(PopoverDesignSystem.Size.popoverWidth, 400)
    }

    func testRendersProductionUsagePopoverOffscreen() async throws {
        let snapshot = populatedSnapshot(activeProfileID: "profile-2")
        let dependencies = makeDependencies(snapshot: snapshot)
        dependencies.model.apply(.current(snapshot))

        let controller = UsagePopoverHostingController(model: dependencies.model)
        let view = controller.view
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let canvas = NSView(frame: view.bounds)
        canvas.appearance = view.appearance
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.white.cgColor
        canvas.addSubview(view)

        let bitmap = try XCTUnwrap(
            canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)
        )
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let png = try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:])
        )
        let rendered = try XCTUnwrap(NSBitmapImageRep(data: png))

        XCTAssertEqual(
            view.bounds.width,
            PopoverDesignSystem.Size.popoverWidth,
            accuracy: 0.5
        )
        XCTAssertGreaterThan(rendered.pixelsWide, 300)
        XCTAssertGreaterThan(rendered.pixelsHigh, 200)
        XCTAssertGreaterThan(png.count, 1_000)

        if let path = ProcessInfo.processInfo.environment["TOKEN_USAGE_QA_RENDER_PATH"] {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: url, options: .atomic)
        }

        await dependencies.model.stop()
    }

    func testPaceReflectsHowMuchOfTheWindowIsLeftNotJustTheRemainingPercent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let week: TimeInterval = 7 * 24 * 60 * 60
        func claude(remaining: Double, resetsIn: TimeInterval) -> UsageState {
            .fresh(
                UsageSnapshot(
                    capturedAt: now,
                    weekly: QuotaWindow(
                        remainingPercent: remaining,
                        resetsAt: now.addingTimeInterval(resetsIn),
                        windowDuration: week
                    )
                )
            )
        }
        func snapshot(_ state: UsageState) -> AppUsageSnapshot {
            AppUsageSnapshot(
                claude: state,
                codexUsage: [],
                codexProfiles: [],
                activeCodexProfileID: nil
            )
        }

        // Same 20% left reads as trouble early in the week and as fine at the very end of it.
        let early = makeDependencies(
            snapshot: snapshot(claude(remaining: 20, resetsIn: week * 0.9)),
            now: now
        ).model
        early.apply(.current(snapshot(claude(remaining: 20, resetsIn: week * 0.9))))
        XCTAssertEqual(early.claudeWeekly.pace, .overspending)
        XCTAssertEqual(early.claudeWeekly.paceText, "과속")

        let late = makeDependencies(
            snapshot: snapshot(claude(remaining: 20, resetsIn: week * 0.15)),
            now: now
        ).model
        late.apply(.current(snapshot(claude(remaining: 20, resetsIn: week * 0.15))))
        XCTAssertEqual(late.claudeWeekly.pace, .onTrack)
        XCTAssertEqual(late.claudeWeekly.paceText, "적정")
        XCTAssertTrue(late.claudeWeekly.accessibilityLabel.contains("사용 속도 적정"))

        let exhausted = makeDependencies(
            snapshot: snapshot(claude(remaining: 0, resetsIn: week / 2)),
            now: now
        ).model
        exhausted.apply(.current(snapshot(claude(remaining: 0, resetsIn: week / 2))))
        XCTAssertEqual(exhausted.claudeWeekly.pace, .exhausted)
        XCTAssertEqual(exhausted.claudeWeekly.remaining, "0% 남음")
    }

    private func makeDependencies(
        snapshot: AppUsageSnapshot,
        actionResult: AppUsageSnapshot? = nil,
        actionError: (any Error)? = nil,
        now: Date = Date()
    ) -> Dependencies {
        let coordinator = MockCoordinator()
        let actions = MockProfileActions(
            result: actionResult ?? snapshot,
            error: actionError
        )
        let quitSpy = QuitSpy()
        let model = AppViewModel(
            coordinator: coordinator,
            profileActions: actions,
            locale: Locale(identifier: "ko_KR"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            now: { now },
            quitAction: { quitSpy.count += 1 }
        )
        return Dependencies(
            model: model,
            coordinator: coordinator,
            actions: actions,
            quitSpy: quitSpy
        )
    }

    private func populatedSnapshot(activeProfileID: String) -> AppUsageSnapshot {
        let claude = UsageSnapshot(
            capturedAt: date("2026-08-03T22:00:00Z"),
            fiveHour: QuotaWindow(
                remainingPercent: 75,
                resetsAt: date("2026-08-04T09:00:00Z")
            ),
            weekly: QuotaWindow(
                remainingPercent: 42,
                resetsAt: date("2026-08-10T17:30:00Z")
            ),
            fableWeekly: QuotaWindow(
                remainingPercent: 84,
                resetsAt: date("2026-08-11T12:15:00Z")
            )
        )
        let codex = UsageSnapshot(
            capturedAt: date("2026-08-03T23:05:00Z"),
            weekly: QuotaWindow(
                remainingPercent: 63,
                resetsAt: date("2026-08-09T07:45:00Z")
            )
        )
        return AppUsageSnapshot(
            claude: .fresh(claude),
            codexUsage: [
                CodexProfileUsage(profileID: "profile-1", state: .fresh(codex)),
                CodexProfileUsage(profileID: "profile-2", state: .fresh(codex)),
            ],
            codexProfiles: [
                CodexProfileMetadata(id: "profile-1", name: "Personal"),
                CodexProfileMetadata(id: "profile-2", name: "codex2")
            ],
            activeCodexProfileID: activeProfileID,
            openRouter: .fresh(
                OpenRouterUsageSnapshot(
                    capturedAt: date("2026-08-03T23:10:00Z"),
                    usage: 574.18,
                    totalCredits: 600,
                    totalUsage: 574.18,
                    limit: nil,
                    isFreeTier: false,
                    rateLimit: "-1/10s"
                )
            )
        )
    }

    private func codexSnapshot(remaining: Double) -> UsageSnapshot {
        UsageSnapshot(
            capturedAt: date("2026-08-03T23:05:00Z"),
            weekly: QuotaWindow(remainingPercent: remaining, resetsAt: nil)
        )
    }

    private func usageSnapshot(from state: UsageState) -> UsageSnapshot? {
        switch state {
        case .fresh(let snapshot), .stale(let snapshot, _): snapshot
        case .unavailable: nil
        }
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func assertDoesNotExpose(
        _ secret: String,
        model: AppViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let visibleText = [
            model.claudeFiveHour.remaining,
            model.claudeFiveHour.reset,
            model.claudeWeekly.remaining,
            model.claudeWeekly.reset,
            model.claudeFableWeekly.remaining,
            model.claudeFableWeekly.reset,
            model.codexWeekly.remaining,
            model.codexWeekly.reset,
            model.lastRefreshText,
            model.statusText,
            model.errorText ?? ""
        ].joined(separator: " ")
        XCTAssertFalse(
            visibleText.localizedCaseInsensitiveContains(secret),
            "Visible UI exposed forbidden provider content",
            file: file,
            line: line
        )
    }
}

private struct Dependencies {
    let model: AppViewModel
    let coordinator: MockCoordinator
    let actions: MockProfileActions
    let quitSpy: QuitSpy
}

private enum CoordinatorEvent: Equatable, Sendable {
    case subscribed
    case started
    case refreshRequested
    case profileOperation
    case stopped
}

private actor MockCoordinator: AppUsageCoordinating {
    private let states: AsyncStream<RefreshState<AppUsageSnapshot>>
    private let stateContinuation: AsyncStream<RefreshState<AppUsageSnapshot>>.Continuation
    private let events: AsyncStream<CoordinatorEvent>
    private let eventContinuation: AsyncStream<CoordinatorEvent>.Continuation

    init() {
        (states, stateContinuation) = AsyncStream.makeStream()
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    func start() {
        eventContinuation.yield(.started)
    }

    func stateChanges() -> AsyncStream<RefreshState<AppUsageSnapshot>> {
        eventContinuation.yield(.subscribed)
        return states
    }

    func requestRefresh() {
        eventContinuation.yield(.refreshRequested)
    }

    func performProfileOperation(
        _ operation: @escaping @Sendable () async throws -> AppUsageSnapshot
    ) async throws -> AppUsageSnapshot {
        eventContinuation.yield(.profileOperation)
        let snapshot = try await operation()
        stateContinuation.yield(.current(snapshot))
        return snapshot
    }

    func stop() {
        eventContinuation.yield(.stopped)
        stateContinuation.finish()
    }

    func send(_ state: RefreshState<AppUsageSnapshot>) {
        stateContinuation.yield(state)
    }

    func eventChanges() -> AsyncStream<CoordinatorEvent> {
        events
    }
}

private enum ProfileActionEvent: Equatable, Sendable {
    case selected(String)
    case saved(String)
    case added(String)
    case deleted(String)
}

private actor MockProfileActions: CodexProfileActionHandling {
    private let result: AppUsageSnapshot
    private let error: (any Error)?
    private let events: AsyncStream<ProfileActionEvent>
    private let eventContinuation: AsyncStream<ProfileActionEvent>.Continuation

    init(result: AppUsageSnapshot, error: (any Error)?) {
        self.result = result
        self.error = error
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    func selectProfile(id: String) throws -> AppUsageSnapshot {
        eventContinuation.yield(.selected(id))
        if let error { throw error }
        return result
    }

    func saveCurrentProfile(named name: String) throws -> AppUsageSnapshot {
        eventContinuation.yield(.saved(name))
        if let error { throw error }
        return result
    }

    func addAccount(named name: String) throws -> AppUsageSnapshot {
        eventContinuation.yield(.added(name))
        if let error { throw error }
        return result
    }

    func deleteProfile(id: String) throws -> AppUsageSnapshot {
        eventContinuation.yield(.deleted(id))
        if let error { throw error }
        return result
    }

    func eventChanges() -> AsyncStream<ProfileActionEvent> {
        events
    }
}

@MainActor
private final class QuitSpy {
    var count = 0
}

private struct MalformedProviderError: Error, CustomStringConvertible {
    let payload: String

    var description: String {
        "Malformed response body: {\"access_token\":\"\(payload)\"}"
    }
}

private final class LoginPresentationSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var reopenCount = 0
    private var cancelCount = 0

    var counts: [Int] { lock.withLock { [reopenCount, cancelCount] } }
    func recordReopen() { lock.withLock { reopenCount += 1 } }
    func recordCancel() { lock.withLock { cancelCount += 1 } }
}
