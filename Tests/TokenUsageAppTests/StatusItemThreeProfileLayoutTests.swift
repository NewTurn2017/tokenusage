import AppKit
import XCTest
@testable import TokenUsageApp
@testable import TokenUsageCore

@MainActor
final class StatusItemThreeProfileLayoutTests: XCTestCase {
    func testThreeCodexProfilesFitWithinMenuBarHeight() throws {
        let presentation = StatusItemPresentation(
            claude: .fresh(snapshot(fiveHour: 56, weekly: 2)),
            codexProfiles: [
                profile(id: "one", weekly: 2),
                profile(id: "two", weekly: 3),
                profile(id: "three", weekly: 100),
            ],
            openRouter: .fresh(
                OpenRouterUsageSnapshot(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usage: 6.02,
                    totalCredits: 50,
                    totalUsage: 6.02,
                    limit: nil,
                    isFreeTier: false,
                    rateLimit: nil
                )
            )
        )

        let view = StatusItemView(presentation: presentation)
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let png = try renderedPNG(of: view, appearance: appearance)

        XCTAssertEqual(presentation.codexProfiles.count, 3)
        XCTAssertLessThanOrEqual(
            view.intrinsicContentSize.height,
            NSStatusBar.system.thickness
        )
        XCTAssertTrue(view.accessibilityLabel()?.contains("Codex three 100%") == true)
        let codexLabels = try ["one", "two", "three"].map { profileID in
            try XCTUnwrap(
                descendant(
                    in: view,
                    accessibilityIdentifier: "token-usage-codex-\(profileID)-quota"
                ) as? NSTextField
            )
        }
        let baselines = codexLabels.map { label in
            let frame = label.convert(label.bounds, to: view)
            return frame.maxY - label.firstBaselineOffsetFromTop
        }
        for (upper, lower) in zip(baselines, baselines.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                abs(upper - lower),
                view.valueFont.capHeight + 0.5
            )
        }
        XCTAssertGreaterThan(png.count, 1_000)
        if let renderPath = ProcessInfo.processInfo.environment["TOKEN_USAGE_STATUS_QA_RENDER_PATH"] {
            try png.write(to: URL(fileURLWithPath: renderPath), options: .atomic)
        }
    }

    private func profile(id: String, weekly: Double) -> StatusItemCodexProfileState {
        StatusItemCodexProfileState(
            profileID: id,
            name: "Codex \(id)",
            state: .fresh(snapshot(weekly: weekly))
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

    private func descendant(
        in view: NSView,
        accessibilityIdentifier: String
    ) -> NSView? {
        if view.accessibilityIdentifier() == accessibilityIdentifier {
            return view
        }
        return view.subviews.lazy.compactMap {
            self.descendant(in: $0, accessibilityIdentifier: accessibilityIdentifier)
        }.first
    }
}
