import AppKit
import Foundation
import XCTest
@testable import TokenUsageApp

final class AssetContractTests: XCTestCase {
    func testAppIconSourceAndPackageContract() throws {
        let root = repositoryRoot
        let sourceURL = root.appendingPathComponent("Resources/AppIcon/TokenUsage-source.png")
        let iconURL = root.appendingPathComponent("Resources/AppIcon/TokenUsage.icns")
        let plistURL = root.appendingPathComponent("Resources/Info.plist")
        let packageScriptURL = root.appendingPathComponent("scripts/package-app.sh")

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: iconURL.path))

        if FileManager.default.fileExists(atPath: sourceURL.path) {
            let representation = try XCTUnwrap(
                NSBitmapImageRep(data: Data(contentsOf: sourceURL))
            )
            XCTAssertTrue(representation.hasAlpha)
            XCTAssertTrue(hasSampledTransparentPixel(in: representation))
        }

        if FileManager.default.fileExists(atPath: iconURL.path) {
            let icon = try XCTUnwrap(NSImage(contentsOf: iconURL))
            let pixelWidths = Set(icon.representations.map(\.pixelsWide))
            XCTAssertTrue(Set([16, 32, 128, 256, 512, 1024]).isSubset(of: pixelWidths))
        }

        let plistData = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "TokenUsage.icns")

        let packageScript = try String(contentsOf: packageScriptURL, encoding: .utf8)
        XCTAssertTrue(packageScript.contains("Resources/AppIcon/TokenUsage.icns"))
        XCTAssertTrue(packageScript.contains("Contents/Resources/TokenUsage.icns"))
    }

    func testProviderSVGResourcesAndHeaderAssociations() throws {
        let resourceRoot = repositoryRoot
            .appendingPathComponent("Sources/TokenUsageApp/Resources/ProviderIcons")
        let anthropicURL = resourceRoot.appendingPathComponent("Anthropic.svg")
        let openAIURL = resourceRoot.appendingPathComponent("OpenAI.svg")
        let attributionURL = resourceRoot.appendingPathComponent("ATTRIBUTION.md")

        for assetURL in [anthropicURL, openAIURL] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
            guard FileManager.default.fileExists(atPath: assetURL.path) else { continue }
            let source = try String(contentsOf: assetURL, encoding: .utf8)
            XCTAssertTrue(source.hasPrefix("<svg"))
            XCTAssertTrue(source.contains("viewBox="))
            XCTAssertTrue(source.contains("<path"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: attributionURL.path))
        if FileManager.default.fileExists(atPath: attributionURL.path) {
            let attribution = try String(contentsOf: attributionURL, encoding: .utf8)
            XCTAssertTrue(attribution.contains("https://cdn.simpleicons.org/anthropic"))
            XCTAssertTrue(attribution.contains("CC0 1.0"))
            XCTAssertTrue(attribution.contains("openai/openai-realtime-console"))
            XCTAssertTrue(attribution.contains("MIT License"))
            XCTAssertTrue(attribution.contains("https://openai.com/brand/"))
        }

        let packageManifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(packageManifest.contains(#".process("Resources")"#))

        let packageScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/package-app.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(packageScript.contains("Resources/ProviderIcons/Anthropic.svg"))
        XCTAssertTrue(packageScript.contains("Resources/ProviderIcons/OpenAI.svg"))
        XCTAssertTrue(packageScript.contains("Contents/Resources/ProviderIcons"))

        let popoverSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/TokenUsageApp/UsagePopoverView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(popoverSource.contains("ProviderMarkView(mark: .anthropic)"))
        XCTAssertTrue(popoverSource.contains("ProviderMarkView(mark: .openAI)"))
        XCTAssertTrue(popoverSource.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(popoverSource.contains(#""provider-anthropic-icon""#))
        XCTAssertTrue(popoverSource.contains(#""provider-openai-icon""#))
        XCTAssertFalse(popoverSource.contains(#".accessibilityLabel("Anthropic, Claude service")"#))
        XCTAssertFalse(popoverSource.contains(#".accessibilityLabel("OpenAI, Codex service")"#))
    }

    func testPackageScriptShipsSwiftPMResourceBundle() throws {
        let packageScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/package-app.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(packageScript.contains("TokenUsage_TokenUsageApp.bundle"))
        XCTAssertTrue(packageScript.contains("cp -R"))
        XCTAssertTrue(packageScript.contains("ATTRIBUTION.md"))

        let statusItemSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/TokenUsageApp/StatusItemView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(statusItemSource.contains("image(in: .main) ?? image(in: .module)"))

        let popoverSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/TokenUsageApp/UsagePopoverView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(popoverSource.contains("mark.image() ?? mark.image(in: .module)"))
    }

    func testLocalReleaseScriptsValidateArchiveAndChecksum() throws {
        let scripts = repositoryRoot.appendingPathComponent("scripts")
        let releaseURL = scripts.appendingPathComponent("create-release.sh")
        let validationURL = scripts.appendingPathComponent("validate-release.sh")
        let relocationURL = scripts.appendingPathComponent("validate-relocated-app.sh")

        for url in [releaseURL, validationURL, relocationURL] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        }

        let release = try String(contentsOf: releaseURL, encoding: .utf8)
        XCTAssertTrue(release.contains("ditto -c -k"))
        XCTAssertTrue(release.contains("shasum -a 256"))
        XCTAssertTrue(release.contains("validate-release.sh"))
        XCTAssertTrue(release.contains("validate-relocated-app.sh"))
        XCTAssertTrue(release.contains("NOT publicly notarized"))

        let validation = try String(contentsOf: validationURL, encoding: .utf8)
        XCTAssertTrue(validation.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(validation.contains("lipo -archs"))
        XCTAssertTrue(validation.contains("binary embeds the builder checkout path"))

        let relocation = try String(contentsOf: relocationURL, encoding: .utf8)
        XCTAssertTrue(relocation.contains("sandbox-exec"))
        XCTAssertTrue(relocation.contains("deny network*"))
        XCTAssertTrue(relocation.contains("deny process-exec"))
    }

    @MainActor
    func testProviderMarksLoadAsTemplateImages() throws {
        for mark in [ProviderMark.anthropic, .openAI] {
            let sourceURL = repositoryRoot
                .appendingPathComponent("Sources/TokenUsageApp/Resources/ProviderIcons")
                .appendingPathComponent("\(mark.resourceName).svg")
            let image = try XCTUnwrap(mark.image(at: sourceURL))
            XCTAssertTrue(image.isTemplate)
            XCTAssertFalse(image.representations.isEmpty)
        }
    }

    @MainActor
    func testMenuBarIconResourcesAndPackageScriptContract() throws {
        let menuBarIconRoot = repositoryRoot
            .appendingPathComponent("Sources/TokenUsageApp/Resources/MenuBarIcons")
        let packageScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/package-app.sh"),
            encoding: .utf8
        )

        for name in ["anthropic", "codex"] {
            let url = menuBarIconRoot.appendingPathComponent("\(name).png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let icon = try XCTUnwrap(StatusItemIcon(rawValue: name))
            let image = try XCTUnwrap(icon.image())
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(
                image.size,
                NSSize(
                    width: StatusItemDesignSystem.Layout.providerIconPointSize,
                    height: StatusItemDesignSystem.Layout.providerIconPointSize
                )
            )
            let expectedPixels = 64
            XCTAssertTrue(image.representations.contains { $0.pixelsWide == expectedPixels })
            XCTAssertFalse(image.representations.isEmpty)
            XCTAssertTrue(packageScript.contains("Resources/MenuBarIcons/\(name).png"))
            XCTAssertTrue(packageScript.contains("Contents/Resources/MenuBarIcons"))
        }

        if let packagedAppPath = ProcessInfo.processInfo.environment["TOKEN_USAGE_PACKAGED_APP"] {
            let bundle = try XCTUnwrap(Bundle(url: URL(fileURLWithPath: packagedAppPath)))
            for icon in StatusItemIcon.allCases {
                let image = try XCTUnwrap(icon.image(in: bundle))
                XCTAssertTrue(image.isTemplate)
                XCTAssertEqual(
                    image.size,
                    NSSize(
                        width: StatusItemDesignSystem.Layout.providerIconPointSize,
                        height: StatusItemDesignSystem.Layout.providerIconPointSize
                    )
                )
            }
        }
    }

    @MainActor
    func testMenuBarIconImagesAreCachedPerProvider() throws {
        for icon in StatusItemIcon.allCases {
            let first = try XCTUnwrap(icon.image())
            let second = try XCTUnwrap(icon.image())

            XCTAssertTrue(first === second)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func hasSampledTransparentPixel(in representation: NSBitmapImageRep) -> Bool {
        let xStep = max(1, representation.pixelsWide / 64)
        let yStep = max(1, representation.pixelsHigh / 64)

        for y in stride(from: 0, to: representation.pixelsHigh, by: yStep) {
            for x in stride(from: 0, to: representation.pixelsWide, by: xStep) {
                if representation.colorAt(x: x, y: y)?.alphaComponent ?? 1 < 0.99 {
                    return true
                }
            }
        }
        return false
    }
}
