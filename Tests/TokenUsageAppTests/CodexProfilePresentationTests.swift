import AppKit
import XCTest
@testable import TokenUsageApp
import TokenUsageCore

@MainActor
final class CodexProfilePresentationTests: XCTestCase {
    func testFiveMixedRowsKeepOrderDistinctDuplicateNamesAndStableAccessibilityIDs() {
        let profiles = (1...5).map {
            CodexProfileMetadata(id: "profile-\($0)", name: $0 < 3 ? "Duplicate" : "Profile \($0)")
        }
        let snapshot = AppUsageSnapshot(
            claude: .unavailable(message: "synthetic"),
            codexUsage: [
                usage("profile-1", .fresh(snapshot(remaining: 91))),
                usage("profile-2", .stale(lastGood: snapshot(remaining: 52), message: "synthetic")),
                usage("profile-3", .unavailable(message: "synthetic")),
                usage("profile-4", .fresh(snapshot(remaining: .nan))),
            ],
            codexProfiles: profiles,
            activeCodexProfileID: "profile-2"
        )
        let model = makeModel()

        model.apply(.current(snapshot))

        XCTAssertEqual(model.codexQuotaRows.map(\.profileID), profiles.map(\.id))
        XCTAssertEqual(model.codexQuotaRows.prefix(2).map(\.name), ["Duplicate", "Duplicate"])
        XCTAssertEqual(
            model.codexQuotaRows.map(\.accessibilityIdentifier),
            profiles.map { "codex-profile-quota-\($0.id)" }
        )
        XCTAssertEqual(model.codexQuotaRows.map(\.freshnessText), [
            "최신", "이전 값", "조회 실패", "최신", "조회 실패",
        ])
        XCTAssertEqual(model.codexQuotaRows.map(\.quota.remaining), [
            "91% 남음", "52% 남음", "--", "--", "--",
        ])
        XCTAssertEqual(model.codexQuotaRows.map(\.quota.reset), ["--", "--", "--", "--", "--"])
        // Rebuilding the row presentation must not drop the pace the window already computed.
        XCTAssertEqual(
            model.codexQuotaRows.map(\.quota.pace),
            model.codexQuotaRows.map { row in
                row.quota.remainingFraction == 0 ? QuotaPace.exhausted : .unknown
            }
        )
        XCTAssertEqual(model.codexQuotaRows.filter(\.isActive).count, 1)
        XCTAssertEqual(model.codexQuotaRows.first(where: \.isActive)?.profileID, "profile-2")
        XCTAssertEqual(model.statusItemPresentation.codexWeeklyTexts, ["91%", "52%", "--", "--", "--"])
        XCTAssertTrue(model.statusItemPresentation.isStale)
        print(
            "TASK6_QA five_rows ids=profile-1,profile-2,profile-3,profile-4,profile-5 "
                + "states=Fresh,Stale,Unavailable,Fresh,Unavailable "
                + "values=91,52,--,--,-- active_count=1 active_id=profile-2 "
                + "active_metric=52% stale_indicator=on"
        )
    }

    func testResetCouponCountIsPresentedPerAccountWithoutFabricatingMissingData() {
        let profiles = [
            CodexProfileMetadata(id: "available", name: "Available"),
            CodexProfileMetadata(id: "zero", name: "Zero"),
            CodexProfileMetadata(id: "missing", name: "Missing"),
        ]
        let usage = { (count: Int?) in
            UsageSnapshot(
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                weekly: QuotaWindow(remainingPercent: 50, resetsAt: nil),
                rateLimitResetCreditsAvailableCount: count
            )
        }
        let snapshot = AppUsageSnapshot(
            claude: .unavailable(message: "synthetic"),
            codexUsage: [
                self.usage("available", .fresh(usage(2))),
                self.usage("zero", .fresh(usage(0))),
                self.usage("missing", .fresh(usage(nil))),
            ],
            codexProfiles: profiles,
            activeCodexProfileID: "available"
        )
        let model = makeModel()

        model.apply(.current(snapshot))

        XCTAssertEqual(
            model.codexQuotaRows.map(\.resetCouponText),
            ["초기화 쿠폰 2개", "초기화 쿠폰 0개", nil]
        )
        XCTAssertTrue(model.codexQuotaRows[0].accessibilityLabel.contains("초기화 쿠폰 2개"))
        XCTAssertTrue(model.codexQuotaRows[1].accessibilityLabel.contains("초기화 쿠폰 0개"))
        XCTAssertFalse(model.codexQuotaRows[2].accessibilityLabel.contains("초기화 쿠폰"))
    }

    func testInvalidActiveProfileUsesStatusDashAndNoActiveMarker() {
        let snapshot = AppUsageSnapshot(
            claude: .fresh(self.snapshot(remaining: 70)),
            codexUsage: [usage("profile-1", .fresh(self.snapshot(remaining: 91)))],
            codexProfiles: [CodexProfileMetadata(id: "profile-1", name: "One")],
            activeCodexProfileID: "missing-profile"
        )
        let model = makeModel()

        model.apply(.current(snapshot))

        XCTAssertEqual(model.statusItemPresentation.codexWeeklyTexts, ["91%"])
        XCTAssertFalse(model.statusItemPresentation.isStale)
        XCTAssertEqual(model.codexQuotaRows.filter(\.isActive).count, 0)
        print("TASK6_QA invalid_active codex_metric=-- active_count=0")
    }

    func testAdditionalCreditsStayWithEachAccountIncludingStaleAndUnavailableStates() {
        let credits: [CodexCredits?] = [
            CodexCredits(hasCredits: true, unlimited: false, balance: 52771.115598),
            CodexCredits(hasCredits: false, unlimited: false, balance: 0),
            CodexCredits(hasCredits: false, unlimited: true),
            CodexCredits(hasCredits: true, unlimited: false),
            nil,
            CodexCredits(hasCredits: true, unlimited: false, balance: 125.5),
            nil,
        ]
        let profiles = credits.indices.map {
            CodexProfileMetadata(id: "credits-\($0)", name: "Account \($0)")
        }
        let model = makeModel()
        model.apply(.current(AppUsageSnapshot(
            claude: .unavailable(message: "synthetic"),
            codexUsage: credits.enumerated().map { index, credit in
                let snapshot = UsageSnapshot(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    codexCredits: credit
                )
                let state: UsageState = index == 6
                    ? .unavailable(message: "synthetic")
                    : index == 5
                        ? .stale(lastGood: snapshot, message: "synthetic")
                        : .fresh(snapshot)
                return usage(profiles[index].id, state)
            },
            codexProfiles: profiles,
            activeCodexProfileID: profiles.first?.id
        )))

        XCTAssertEqual(model.codexQuotaRows.map(\.additionalCreditsText), [
            "52,771.12 남음", "0 남음", "무제한", "잔액 미제공", "--", "125.5 남음", "--",
        ])
        XCTAssertEqual(model.codexQuotaRows[5].freshnessText, "이전 값")
        XCTAssertEqual(model.codexQuotaRows[6].freshnessText, "조회 실패")
        XCTAssertTrue(model.codexQuotaRows[0].accessibilityLabel.contains("추가 크레딧 52,771.12"))
    }

    func testOffscreenFiveProfileSurfaceRendersBoundedScrollCards() throws {
        let profiles = (1...5).map { CodexProfileMetadata(id: "p\($0)", name: "P\($0)") }
        let model = makeModel()
        model.apply(.current(AppUsageSnapshot(
            claude: .fresh(snapshot(remaining: 70)),
            codexUsage: profiles.enumerated().map { index, profile in
                usage(
                    profile.id,
                    .fresh(snapshot(remaining: 50, resetCouponCount: index))
                )
            },
            codexProfiles: profiles,
            activeCodexProfileID: "p3"
        )))
        let controller = UsagePopoverHostingController(model: model)
        let view = controller.view
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()

        let canvas = NSView(frame: view.bounds)
        canvas.appearance = view.appearance
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.white.cgColor
        canvas.addSubview(view)
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertEqual(CodexProfileQuotaListLayout.maximumHeight(rowCount: 3), 190)
        XCTAssertLessThan(
            CodexProfileQuotaListLayout.maximumHeight(rowCount: 3),
            view.bounds.height
        )
        XCTAssertEqual(
            model.codexQuotaRows.map(\.accessibilityIdentifier),
            profiles.map { "codex-profile-quota-\($0.id)" }
        )
        XCTAssertGreaterThan(png.count, 1_000)
        if let path = ProcessInfo.processInfo.environment["TOKEN_USAGE_CODEX_PROFILES_QA_RENDER_PATH"] {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func makeModel() -> AppViewModel {
        AppViewModel(
            coordinator: PresentationNoopCoordinator(),
            profileActions: PresentationNoopActions(),
            locale: Locale(identifier: "en_US")
        )
    }

    private func usage(_ id: String, _ state: UsageState) -> CodexProfileUsage {
        CodexProfileUsage(profileID: id, state: state)
    }

    private func snapshot(
        remaining: Double,
        resetCouponCount: Int? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            weekly: QuotaWindow(remainingPercent: remaining, resetsAt: nil),
            rateLimitResetCreditsAvailableCount: resetCouponCount
        )
    }

}

private actor PresentationNoopCoordinator: AppUsageCoordinating {
    func start() async {}
    func stateChanges() async -> AsyncStream<RefreshState<AppUsageSnapshot>> { AsyncStream { _ in } }
    func requestRefresh() async {}
    func performProfileOperation(
        _ operation: @escaping @Sendable () async throws -> AppUsageSnapshot
    ) async throws -> AppUsageSnapshot { try await operation() }
    func stop() async {}
}

private actor PresentationNoopActions: CodexProfileActionHandling {
    func selectProfile(id: String) async throws -> AppUsageSnapshot { fatalError() }
    func saveCurrentProfile(named name: String) async throws -> AppUsageSnapshot { fatalError() }
    func addAccount(named name: String) async throws -> AppUsageSnapshot { fatalError() }
    func deleteProfile(id: String) async throws -> AppUsageSnapshot { fatalError() }
}
