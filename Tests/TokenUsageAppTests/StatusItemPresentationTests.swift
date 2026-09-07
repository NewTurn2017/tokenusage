import AppKit
import Foundation
import XCTest
@testable import TokenUsageApp
@testable import TokenUsageCore

final class StatusItemPresentationTests: XCTestCase {
    func testFreshPresentationShowsClaudeStackAndCodexWeek() {
        let presentation = StatusItemPresentation(
            claude: .fresh(snapshot(fiveHour: 84, weekly: 52)),
            codexProfiles: codex(.fresh(snapshot(weekly: 27)))
        )

        XCTAssertEqual(StatusItemPresentation.claudeMark, "✳")
        XCTAssertEqual(presentation.claudeFiveHourText, "84%")
        XCTAssertEqual(presentation.claudeWeeklyText, "52%")
        XCTAssertEqual(StatusItemPresentation.codexMark, "◎")
        XCTAssertEqual(presentation.codexWeeklyTexts, ["27%"])
        XCTAssertFalse(presentation.isStale)
    }

    func testStalePresentationRetainsLastGoodLabelsAndAddsCompactIndicator() {
        let presentation = StatusItemPresentation(
            claude: .stale(
                lastGood: snapshot(fiveHour: 84, weekly: 52),
                message: "offline"
            ),
            codexProfiles: codex(.fresh(snapshot(weekly: 27)))
        )

        XCTAssertEqual(presentation.visibleLabels, ["84%", "52%", "27%"])
        XCTAssertEqual(presentation.staleIndicatorText, "•")
        XCTAssertTrue(presentation.isStale)
    }

    func testUnavailableAndMissingWindowsUseDashesWithoutFabricatingZero() {
        let unavailable = StatusItemPresentation(
            claude: .unavailable(message: "not signed in"),
            codexProfiles: codex(.unavailable(message: "not signed in"))
        )
        let missing = StatusItemPresentation(
            claude: .fresh(snapshot()),
            codexProfiles: codex(.fresh(snapshot()))
        )

        for presentation in [unavailable, missing] {
        XCTAssertEqual(presentation.visibleLabels, ["--", "--", "--"])
            XCTAssertFalse(presentation.visibleLabels.joined().contains("0%"))
        }
    }

    func testRealZeroRemainsDistinguishableFromUnavailable() {
        let presentation = StatusItemPresentation(
            claude: .fresh(snapshot(fiveHour: 0)),
            codexProfiles: codex(.unavailable(message: "offline"))
        )

        XCTAssertEqual(presentation.claudeFiveHourText, "0%")
        XCTAssertEqual(presentation.codexWeeklyTexts, ["--"])
    }

    @MainActor
    func testStatusItemPresentationIncludesEveryCodexProfileInMetadataOrder() {
        let cases: [[(id: String, remaining: Double)]] = [
            [],
            [("p1", 11)],
            [("p1", 11), ("p2", 22)],
            [("p1", 11), ("p2", 22), ("p3", 33)],
        ]

        for profileValues in cases {
            let profiles = profileValues.map {
                CodexProfileMetadata(id: $0.id, name: "Profile \($0.id)")
            }
            let appSnapshot = AppUsageSnapshot(
                claude: .fresh(snapshot(fiveHour: 94, weekly: 86)),
                codexUsage: profileValues.map {
                    CodexProfileUsage(
                        profileID: $0.id,
                        state: .fresh(snapshot(weekly: $0.remaining))
                    )
                },
                codexProfiles: profiles,
                activeCodexProfileID: profileValues.first?.id
            )
            let model = makeModel()

            model.apply(.current(appSnapshot))

            XCTAssertEqual(
                model.statusItemPresentation.visibleLabels,
                ["94%", "86%"] + profileValues.map { "\(Int($0.remaining))%" },
                "profileCount=\(profileValues.count)"
            )
        }
    }

    func testNegativeRemainingIsClampedToZeroWhileNaNAndMissingRemainUnavailable() {
        let negative = StatusItemPresentation(
            claude: .unavailable(message: "offline"),
            codexProfiles: codex(.fresh(snapshot(weekly: -1)))
        )
        let nan = StatusItemPresentation(
            claude: .unavailable(message: "offline"),
            codexProfiles: codex(.fresh(snapshot(weekly: .nan)))
        )
        let missing = StatusItemPresentation(
            claude: .unavailable(message: "offline"),
            codexProfiles: codex(.fresh(snapshot()))
        )

        XCTAssertEqual(negative.codexWeeklyTexts, ["0%"])
        XCTAssertEqual(nan.codexWeeklyTexts, ["--"])
        XCTAssertEqual(missing.codexWeeklyTexts, ["--"])
    }

    @MainActor
    func testStaleCodexProfileKeepsAllRowsAndStaleIndicator() {
        let profiles = [
            CodexProfileMetadata(id: "hyuni", name: "codex-hyuni"),
            CodexProfileMetadata(id: "genie", name: "codex-genie"),
        ]
        let appSnapshot = AppUsageSnapshot(
            claude: .fresh(snapshot(fiveHour: 94, weekly: 86)),
            codexUsage: [
                CodexProfileUsage(
                    profileID: "hyuni",
                    state: .stale(lastGood: snapshot(weekly: 12), message: "offline")
                ),
                CodexProfileUsage(
                    profileID: "genie",
                    state: .fresh(snapshot(weekly: 0))
                ),
            ],
            codexProfiles: profiles,
            activeCodexProfileID: "genie"
        )
        let model = makeModel()

        model.apply(.current(appSnapshot))

        XCTAssertEqual(model.statusItemPresentation.visibleLabels, ["94%", "86%", "12%", "0%"])
        XCTAssertEqual(model.statusItemPresentation.staleIndicatorText, "•")
        XCTAssertTrue(model.statusItemPresentation.isStale)
    }

    @MainActor
    func testMenuBarIconsAreTemplateSizedAndFallbackToGlyphsWhenMissing() throws {
        for icon in StatusItemIcon.allCases {
            let image = try XCTUnwrap(icon.image())
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(
                image.size,
                NSSize(
                    width: StatusItemDesignSystem.Layout.providerIconPointSize,
                    height: StatusItemDesignSystem.Layout.providerIconPointSize
                )
            )
            XCTAssertFalse(image.representations.isEmpty)
        }

        let missingBundle = Bundle(for: StatusItemPresentationTests.self)
        let fallback = StatusItemIcon.anthropic.makeView(in: missingBundle)
        XCTAssertEqual((fallback as? NSTextField)?.stringValue, StatusItemPresentation.claudeMark)
    }

    @MainActor
    func testOffscreenTwoProfileMenuBarSurfaceKeepsFourRowsAndNamedAccessibility() throws {
        let presentation = StatusItemPresentation(
            claude: .fresh(snapshot(fiveHour: 94, weekly: 86)),
            codexProfiles: [
                StatusItemCodexProfileState(
                    profileID: "hyuni",
                    name: "codex-hyuni",
                    state: .fresh(snapshot(weekly: 12))
                ),
                StatusItemCodexProfileState(
                    profileID: "genie",
                    name: "codex-genie",
                    state: .fresh(snapshot(weekly: 0))
                ),
            ]
        )
        let view = StatusItemView(presentation: presentation)
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let png = try renderedPNG(of: view, appearance: appearance)

        XCTAssertEqual(presentation.visibleLabels, ["94%", "86%", "12%", "0%"])
        XCTAssertEqual(presentation.codexProfiles.count, 2)
        XCTAssertTrue(view.accessibilityLabel()?.contains("codex-hyuni") == true)
        XCTAssertTrue(view.accessibilityLabel()?.contains("codex-genie") == true)
        XCTAssertGreaterThan(png.count, 1_000)
        if let renderPath = ProcessInfo.processInfo.environment["TOKEN_USAGE_STATUS_QA_RENDER_PATH"] {
            try png.write(to: URL(fileURLWithPath: renderPath), options: .atomic)
        }
    }

    @MainActor
    func testNativeViewHasStableCompactIntrinsicSizeAndTabularNumerals() {
        let fresh = StatusItemPresentation(
            claude: .fresh(snapshot(fiveHour: 100, weekly: 52)),
            codexProfiles: codex(.fresh(snapshot(weekly: 27)))
        )
        let unavailable = StatusItemPresentation(
            claude: .unavailable(message: "offline"),
            codexProfiles: codex(.unavailable(message: "offline"))
        )
        let stale = StatusItemPresentation(
            claude: .stale(lastGood: snapshot(fiveHour: 84, weekly: 52), message: "offline"),
            codexProfiles: codex(.fresh(snapshot(weekly: 27)))
        )
        let view = StatusItemView(presentation: fresh)
        let freshSize = view.intrinsicContentSize

        view.update(with: unavailable)
        let unavailableSize = view.intrinsicContentSize
        view.update(with: stale)
        let staleSize = view.intrinsicContentSize

        XCTAssertEqual(freshSize, unavailableSize)
        XCTAssertEqual(freshSize, staleSize)
        XCTAssertLessThanOrEqual(freshSize.width, StatusItemDesignSystem.Layout.maximumSize.width)
        XCTAssertLessThanOrEqual(freshSize.height, StatusItemDesignSystem.Layout.maximumSize.height)
        XCTAssertGreaterThanOrEqual(
            StatusItemDesignSystem.Typography.symbolPointSize,
            StatusItemDesignSystem.Layout.maximumSize.height * 0.7
        )
        XCTAssertGreaterThan(freshSize.width, 0)
        XCTAssertGreaterThan(freshSize.height, 0)
        print("StatusItemView intrinsic size: \(freshSize.width)x\(freshSize.height) points")
        XCTAssertGreaterThanOrEqual(view.valueFont.pointSize, 8)
        XCTAssertLessThanOrEqual(view.valueFont.pointSize, 10)

        let narrowDigits = ("111" as NSString).size(withAttributes: [.font: view.valueFont]).width
        let wideDigits = ("888" as NSString).size(withAttributes: [.font: view.valueFont]).width
        XCTAssertEqual(narrowDigits, wideDigits, accuracy: 0.01)
    }

    @MainActor
    func testTemplateForegroundResolvesForLightAndDarkAppearances() throws {
        let view = StatusItemView(
            presentation: StatusItemPresentation(
                claude: .fresh(snapshot(fiveHour: 84, weekly: 52)),
                codexProfiles: codex(.fresh(snapshot(weekly: 27)))
            )
        )
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightColor = try XCTUnwrap(
            resolved(view.templateForegroundColor, appearance: light)
        )
        let darkColor = try XCTUnwrap(
            resolved(view.templateForegroundColor, appearance: dark)
        )

        XCTAssertNotEqual(lightColor, darkColor)
        let lightPNG = try renderedPNG(of: view, appearance: light)
        XCTAssertNotEqual(lightPNG, try renderedPNG(of: view, appearance: dark))

        if let renderPath = ProcessInfo.processInfo.environment["TOKEN_USAGE_STATUS_QA_RENDER_PATH"] {
            try lightPNG.write(to: URL(fileURLWithPath: renderPath), options: .atomic)
        }
    }

    @MainActor
    func testOpenRouterBalanceShowsRemainingDollarsOnlyWhenAvailable() throws {
        let balance = openRouterSnapshot(totalCredits: 20, totalUsage: 7.5)
        let fresh = StatusItemPresentation(
            claude: .fresh(snapshot(fiveHour: 84, weekly: 52)),
            codexProfiles: codex(.fresh(snapshot(weekly: 27))),
            openRouter: .fresh(balance)
        )
        let stale = StatusItemPresentation(
            claude: .fresh(snapshot(fiveHour: 84, weekly: 52)),
            codexProfiles: codex(.fresh(snapshot(weekly: 27))),
            openRouter: .stale(lastGood: balance, message: "offline")
        )
        let missing = StatusItemPresentation(
            claude: .fresh(snapshot(fiveHour: 84, weekly: 52)),
            codexProfiles: codex(.fresh(snapshot(weekly: 27))),
            openRouter: .notConfigured(message: "no key")
        )

        XCTAssertEqual(fresh.openRouterBalanceText, "$12.50")
        XCTAssertEqual(stale.openRouterBalanceText, "$12.50")
        XCTAssertNil(missing.openRouterBalanceText)
        XCTAssertEqual(fresh.visibleLabels, ["84%", "52%", "27%", "$12.50"])
        XCTAssertEqual(missing.visibleLabels, ["84%", "52%", "27%"])

        let view = StatusItemView(presentation: fresh)
        XCTAssertTrue(view.accessibilityLabel()?.contains("$12.50") == true)
        XCTAssertLessThanOrEqual(
            view.intrinsicContentSize.width,
            StatusItemDesignSystem.Layout.maximumSize.width
        )
        if let renderPath = ProcessInfo.processInfo.environment["TOKEN_USAGE_STATUS_QA_RENDER_PATH"] {
            let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
            try renderedPNG(of: view, appearance: appearance)
                .write(to: URL(fileURLWithPath: renderPath), options: .atomic)
        }

        view.update(with: missing)
        XCTAssertFalse(view.accessibilityLabel()?.contains("$") == true)
    }

    private func openRouterSnapshot(
        totalCredits: Double,
        totalUsage: Double
    ) -> OpenRouterUsageSnapshot {
        OpenRouterUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            usage: totalUsage,
            totalCredits: totalCredits,
            totalUsage: totalUsage,
            limit: nil,
            isFreeTier: false,
            rateLimit: nil
        )
    }

    private func snapshot(
        fiveHour: Double? = nil,
        weekly: Double? = nil
    ) -> TokenUsageCore.UsageSnapshot {
        TokenUsageCore.UsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fiveHour: fiveHour.map { QuotaWindow(remainingPercent: $0, resetsAt: nil) },
            weekly: weekly.map { QuotaWindow(remainingPercent: $0, resetsAt: nil) }
        )
    }

    private func codex(_ state: UsageState) -> [StatusItemCodexProfileState] {
        [StatusItemCodexProfileState(profileID: "codex", name: "Codex", state: state)]
    }

    @MainActor
    private func makeModel() -> AppViewModel {
        AppViewModel(
            coordinator: StatusItemPresentationNoopCoordinator(),
            profileActions: StatusItemPresentationNoopActions()
        )
    }

    @MainActor
    private func resolved(_ color: NSColor, appearance: NSAppearance) -> NSColor? {
        var resolvedColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.deviceRGB)
        }
        return resolvedColor
    }

    @MainActor
    private func renderedPNG(of view: NSView, appearance: NSAppearance) throws -> Data {
        view.appearance = appearance
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        let canvas = NSView(frame: view.bounds)
        canvas.appearance = appearance
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.white.cgColor
        canvas.addSubview(view)
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

private actor StatusItemPresentationNoopCoordinator: AppUsageCoordinating {
    func start() async {}
    func stateChanges() async -> AsyncStream<RefreshState<AppUsageSnapshot>> { AsyncStream { _ in } }
    func requestRefresh() async {}
    func performProfileOperation(
        _ operation: @escaping @Sendable () async throws -> AppUsageSnapshot
    ) async throws -> AppUsageSnapshot { try await operation() }
    func stop() async {}
}

private actor StatusItemPresentationNoopActions: CodexProfileActionHandling {
    func selectProfile(id: String) async throws -> AppUsageSnapshot { fatalError() }
    func saveCurrentProfile(named name: String) async throws -> AppUsageSnapshot { fatalError() }
    func addAccount(named name: String) async throws -> AppUsageSnapshot { fatalError() }
    func deleteProfile(id: String) async throws -> AppUsageSnapshot { fatalError() }
}
