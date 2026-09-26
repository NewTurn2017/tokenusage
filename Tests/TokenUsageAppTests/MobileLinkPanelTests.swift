import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import TokenUsageApp

@MainActor
final class MobileLinkPanelTests: XCTestCase {
    private let link = URL(string: "http://100.115.102.6:8787/?k=abcDEF_123-xyz")!

    func testTheQRCodeDecodesBackToTheExactLink() throws {
        let image = try XCTUnwrap(QRCodeImage.make(from: link.absoluteString, side: 188))
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))

        let features = detector.features(in: CIImage(cgImage: cgImage)).compactMap {
            ($0 as? CIQRCodeFeature)?.messageString
        }

        XCTAssertEqual(features, [link.absoluteString])
        XCTAssertEqual(image.size.width, image.size.height)
        XCTAssertGreaterThanOrEqual(image.size.width, 150, "big enough for a phone camera")
    }

    func testTheWidgetTabPointsAtTheWidgetSourceWithTheSameKey() {
        XCTAssertEqual(MobileLinkPanel(link: link, target: .page).targetLink, link)
        XCTAssertEqual(
            MobileLinkPanel(link: link, target: .widget).targetLink.absoluteString,
            "http://100.115.102.6:8787/widget.js?k=abcDEF_123-xyz"
        )
    }

    func testRendersThePanelForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["TOKEN_USAGE_POPOVER_QA_DIRECTORY"] else {
            return
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: MobileLinkPanel(link: link))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let canvas = NSView(frame: view.bounds)
            canvas.appearance = view.appearance
            canvas.wantsLayer = true
            canvas.addSubview(view)
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.appearance?.performAsCurrentDrawingAppearance {
                canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            }
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("mobile-link-\(name).png")
            )
        }
    }
}
