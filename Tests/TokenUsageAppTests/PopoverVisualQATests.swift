import AppKit
import SwiftUI
import XCTest
@testable import TokenUsageApp
import TokenUsageCore

/// Exercises the shipped SwiftUI surface rather than a web facsimile or hand-built mock.
@MainActor
final class PopoverVisualQATests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_788_000_000)

    func testRendersLightDarkManyAccountAndErrorSurfaces() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try render(snapshot: manyAccountSnapshot(), appearance: aqua)
        let dark = try render(snapshot: manyAccountSnapshot(), appearance: darkAqua)
        let common = try render(snapshot: commonUnconfiguredSnapshot(), appearance: aqua)
        let errors = try render(snapshot: errorSnapshot(), appearance: darkAqua)

        for rendering in [light, dark, common, errors] {
            XCTAssertEqual(
                rendering.size.width,
                PopoverDesignSystem.Size.popoverWidth,
                accuracy: 0.5
            )
            XCTAssertLessThan(rendering.size.height, 800)
            XCTAssertGreaterThan(rendering.png.count, 10_000)
        }
        XCTAssertNotEqual(light.png, dark.png, "semantic colours must adapt to macOS appearance")

        let couponModel = model(for: manyAccountSnapshot())
        XCTAssertEqual(
            couponModel.codexQuotaRows.prefix(3).map(\.resetCouponText),
            ["초기화 쿠폰 2개", "초기화 쿠폰 0개", nil]
        )
        XCTAssertEqual(
            model(for: commonUnconfiguredSnapshot()).openRouterBalance.status,
            .notConfigured
        )
        XCTAssertNotNil(model(for: errorSnapshot()).errorText)

        if let directory = ProcessInfo.processInfo.environment[
            "TOKEN_USAGE_POPOVER_QA_DIRECTORY"
        ] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: output,
                withIntermediateDirectories: true
            )
            try light.png.write(
                to: output.appendingPathComponent("tokenusage-popover-light-many.png"),
                options: .atomic
            )
            try dark.png.write(
                to: output.appendingPathComponent("tokenusage-popover-dark-many.png"),
                options: .atomic
            )
            try common.png.write(
                to: output.appendingPathComponent(
                    "tokenusage-popover-light-common-unconfigured.png"
                ),
                options: .atomic
            )
            try errors.png.write(
                to: output.appendingPathComponent("tokenusage-popover-dark-errors.png"),
                options: .atomic
            )
        }

        print(
            "POPOVER_VISUAL_QA light=\(light.size.width)x\(light.size.height) "
                + "dark=\(dark.size.width)x\(dark.size.height) "
                + "common=\(common.size.width)x\(common.size.height) "
                + "errors=\(errors.size.width)x\(errors.size.height)"
        )
    }

    private func manyAccountSnapshot() -> AppUsageSnapshot {
        let claudeProfiles = (1...4).map { index in
            ClaudeProfileMetadata(
                id: "claude-\(index)",
                name: index == 2
                    ? "국제화 제품 연구팀의 아주 긴 Claude 계정 이름"
                    : "Claude \(index)",
                emailAddress: index == 2
                    ? "very.long.identity.address+product-research@example.com"
                    : "claude\(index)@example.com"
            )
        }
        let codexProfiles = (1...5).map { index in
            CodexProfileMetadata(
                id: "codex-\(index)",
                name: index == 1
                    ? "Production Automation and Reliability Workspace"
                    : "Codex \(index)"
            )
        }
        let codexRemaining: [Double] = [88, 24, 8, 0, 51]
        let couponCounts: [Int?] = [2, 0, nil, 1, nil]

        return AppUsageSnapshot(
            claude: .unavailable(message: "synthetic"),
            codexUsage: codexProfiles.enumerated().map { index, profile in
                CodexProfileUsage(
                    profileID: profile.id,
                    state: .fresh(usage(
                        fiveHour: nil,
                        weekly: codexRemaining[index],
                        fable: nil,
                        couponCount: couponCounts[index]
                    ))
                )
            },
            codexProfiles: codexProfiles,
            activeCodexProfileID: codexProfiles.first?.id,
            openRouter: .fresh(OpenRouterUsageSnapshot(
                capturedAt: capturedAt,
                usage: 41.25,
                totalCredits: 100,
                totalUsage: 68.40,
                limit: nil,
                isFreeTier: false,
                rateLimit: "20/10s"
            )),
            claudeUsage: claudeProfiles.enumerated().map { index, profile in
                ClaudeProfileUsage(
                    profileID: profile.id,
                    state: .fresh(usage(
                        fiveHour: [72, 21, 9, 0][index],
                        weekly: [84, 64, 18, 4][index],
                        fable: index == 0 ? 43 : nil,
                        couponCount: nil
                    ))
                )
            },
            claudeProfiles: claudeProfiles,
            activeClaudeProfileID: claudeProfiles.first?.id
        )
    }

    private func commonUnconfiguredSnapshot() -> AppUsageSnapshot {
        let populated = manyAccountSnapshot()
        let profiles = Array(populated.codexProfiles.prefix(3))
        let profileIDs = Set(profiles.map(\.id))
        return AppUsageSnapshot(
            claude: .fresh(usage(
                fiveHour: 72,
                weekly: 84,
                fable: 43,
                couponCount: nil
            )),
            codexUsage: populated.codexUsage.filter { profileIDs.contains($0.profileID) },
            codexProfiles: profiles,
            activeCodexProfileID: profiles.first?.id,
            openRouter: .notConfigured(message: OpenRouterUsageState.notConfiguredHint)
        )
    }

    private func errorSnapshot() -> AppUsageSnapshot {
        let previous = usage(
            fiveHour: 13,
            weekly: 7,
            fable: 0,
            couponCount: nil
        )
        let codexProfiles = [
            CodexProfileMetadata(id: "stale", name: "Stale team account"),
            CodexProfileMetadata(id: "missing", name: "Unavailable account"),
            CodexProfileMetadata(id: "fresh", name: "Healthy account"),
        ]
        return AppUsageSnapshot(
            claude: .stale(lastGood: previous, message: "synthetic stale state"),
            codexUsage: [
                CodexProfileUsage(
                    profileID: "stale",
                    state: .stale(lastGood: previous, message: "synthetic stale state")
                ),
                CodexProfileUsage(
                    profileID: "missing",
                    state: .unavailable(message: "synthetic unavailable state")
                ),
                CodexProfileUsage(
                    profileID: "fresh",
                    state: .fresh(usage(
                        fiveHour: nil,
                        weekly: 74,
                        fable: nil,
                        couponCount: 0
                    ))
                ),
            ],
            codexProfiles: codexProfiles,
            activeCodexProfileID: "stale",
            openRouter: .unavailable(message: "synthetic unavailable state")
        )
    }

    private func usage(
        fiveHour: Double?,
        weekly: Double,
        fable: Double?,
        couponCount: Int?
    ) -> UsageSnapshot {
        UsageSnapshot(
            capturedAt: capturedAt,
            fiveHour: fiveHour.map {
                QuotaWindow(
                    remainingPercent: $0,
                    resetsAt: capturedAt.addingTimeInterval(3 * 60 * 60),
                    windowDuration: QuotaWindowKind.fiveHour.duration
                )
            },
            weekly: QuotaWindow(
                remainingPercent: weekly,
                resetsAt: capturedAt.addingTimeInterval(5 * 24 * 60 * 60),
                windowDuration: QuotaWindowKind.weekly.duration
            ),
            fableWeekly: fable.map {
                QuotaWindow(
                    remainingPercent: $0,
                    resetsAt: capturedAt.addingTimeInterval(4 * 24 * 60 * 60),
                    windowDuration: QuotaWindowKind.fableWeekly.duration
                )
            },
            rateLimitResetCreditsAvailableCount: couponCount
        )
    }

    private func model(for snapshot: AppUsageSnapshot) -> AppViewModel {
        let model = AppViewModel(
            coordinator: PopoverVisualQACoordinator(),
            profileActions: PopoverVisualQAActions(),
            locale: Locale(identifier: "ko_KR"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            now: { Date(timeIntervalSince1970: 1_788_000_000) },
            quitAction: {}
        )
        model.apply(.current(snapshot))
        return model
    }

    private func render(
        snapshot: AppUsageSnapshot,
        appearance: NSAppearance
    ) throws -> (png: Data, size: NSSize) {
        let controller = UsagePopoverHostingController(model: model(for: snapshot))
        let view = controller.view
        view.appearance = appearance
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        let canvas = NSView(frame: view.bounds)
        canvas.appearance = appearance
        canvas.wantsLayer = true
        canvas.addSubview(view)
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        appearance.performAsCurrentDrawingAppearance {
            canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return (png, size)
    }
}

private actor PopoverVisualQACoordinator: AppUsageCoordinating {
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

private struct PopoverVisualQAActions: CodexProfileActionHandling {
    func selectProfile(id: String) async throws -> AppUsageSnapshot { fatalError() }
    func saveCurrentProfile(named name: String) async throws -> AppUsageSnapshot { fatalError() }
    func addAccount(named name: String) async throws -> AppUsageSnapshot { fatalError() }
    func deleteProfile(id: String) async throws -> AppUsageSnapshot { fatalError() }
}
