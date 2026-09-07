import AppKit
import SwiftUI
import XCTest
@testable import TokenUsageApp
import TokenUsageCore

/// Measures the real rendered popover, because the account lists are capped by a height in points
/// and a row that quietly grows would start hiding accounts behind a scroll bar.
@MainActor
final class PopoverAccountListLayoutTests: XCTestCase {
    /// Visible height of the smallest display this app has to sit on - a 14-inch MacBook Pro,
    /// menu bar already excluded.
    private static let laptopVisibleHeight: CGFloat = 1_085

    func testEveryCodexAccountUpToTheLimitIsVisibleWithoutScrolling() {
        let heights = (1...4).map { popoverHeight(codexCount: $0, claudeCount: 1) }

        // Each added account grows the popover by exactly one row, so none of them is clipped.
        let cardStride = CodexProfileQuotaListLayout.maximumHeight(rowCount: 2)
            - CodexProfileQuotaListLayout.maximumHeight(rowCount: 1)
        XCTAssertEqual(heights[1] - heights[0], cardStride, accuracy: 1)
        XCTAssertEqual(heights[2] - heights[1], cardStride, accuracy: 1)
        XCTAssertEqual(
            CodexProfileQuotaListLayout.unscrolledRowLimit,
            3,
            "three is what the menu bar shows too"
        )
        // Past the limit the list scrolls instead of pushing the popover off the screen.
        XCTAssertEqual(heights[3], heights[2], accuracy: 1)
    }

    func testEveryClaudeAccountUpToTheLimitIsVisibleWithoutScrolling() {
        // Every saved account is visible and directly switchable from its row.
        let two = popoverHeight(codexCount: 1, claudeCount: 2)
        let three = popoverHeight(codexCount: 1, claudeCount: 3)
        let four = popoverHeight(codexCount: 1, claudeCount: 4)

        let rowStride = ClaudeProfileQuotaListLayout.maximumHeight(rowCount: 3)
            - ClaudeProfileQuotaListLayout.maximumHeight(rowCount: 2)
        XCTAssertEqual(three - two, rowStride, accuracy: 2)
        XCTAssertEqual(four, three, accuracy: 1)
    }

    func testTheFullyPopulatedPopoverStillFitsALaptopDisplay() {
        let height = popoverHeight(
            codexCount: CodexProfileQuotaListLayout.unscrolledRowLimit,
            claudeCount: 2
        )

        XCTAssertLessThan(height, Self.laptopVisibleHeight)
        print("POPOVER_QA claude=2 codex=3 height=\(height) limit=\(Self.laptopVisibleHeight)")
    }
    func testCommonThreeCodexAccountStateIsRoughlyFortyPercentShorterThanProductionBaseline() {
        let redesignedHeight = popoverHeight(codexCount: 3, claudeCount: 0)
        let productionBaselineHeight: CGFloat = 962

        XCTAssertLessThan(redesignedHeight, productionBaselineHeight * 0.65)
        print(
            "POPOVER_COMPACT_QA baseline=\(productionBaselineHeight) "
                + "redesigned=\(redesignedHeight)"
        )
    }


    // MARK: - Fixtures

    private func popoverHeight(codexCount: Int, claudeCount: Int) -> CGFloat {
        let model = AppViewModel(
            coordinator: LayoutNoopCoordinator(),
            profileActions: LayoutNoopCodexActions()
        )
        model.apply(.current(snapshot(codexCount: codexCount, claudeCount: claudeCount)))
        let controller = NSHostingController(rootView: UsagePopoverView(model: model))
        return controller.view.fittingSize.height
    }

    private func snapshot(codexCount: Int, claudeCount: Int) -> AppUsageSnapshot {
        let codexProfiles = (1...max(1, codexCount)).map {
            CodexProfileMetadata(id: "codex-\($0)", name: "codex-\($0)")
        }
        let claudeProfiles = claudeCount == 0 ? [] : (1...claudeCount).map {
            ClaudeProfileMetadata(
                id: "claude-\($0)",
                name: "claude-\($0)",
                emailAddress: "account\($0)@example.com"
            )
        }
        return AppUsageSnapshot(
            claude: .fresh(usage()),
            codexUsage: codexProfiles.map {
                CodexProfileUsage(profileID: $0.id, state: .fresh(usage()))
            },
            codexProfiles: codexProfiles,
            activeCodexProfileID: codexProfiles.first?.id,
            claudeUsage: claudeProfiles.map {
                ClaudeProfileUsage(profileID: $0.id, state: .fresh(usage()))
            },
            claudeProfiles: claudeProfiles,
            activeClaudeProfileID: claudeProfiles.first?.id
        )
    }

    private func usage() -> UsageSnapshot {
        UsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_787_000_000),
            fiveHour: QuotaWindow(remainingPercent: 91, resetsAt: nil),
            weekly: QuotaWindow(remainingPercent: 78, resetsAt: nil),
            fableWeekly: QuotaWindow(remainingPercent: 89, resetsAt: nil)
        )
    }
}

private actor LayoutNoopCoordinator: AppUsageCoordinating {
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

private struct LayoutNoopCodexActions: CodexProfileActionHandling {
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
