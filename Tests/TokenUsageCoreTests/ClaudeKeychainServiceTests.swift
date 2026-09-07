import Foundation
import XCTest
@testable import TokenUsageCore

final class ClaudeKeychainServiceTests: XCTestCase {
    /// Claude Code derives the item name from the configuration directory, so these values are a
    /// contract with it rather than a choice of ours. A drift here means an isolated sign-in
    /// silently cannot be read back.
    func testTheItemNameMatchesTheOneClaudeCodeDerivesForADirectory() {
        XCTAssertEqual(
            ClaudeKeychainService.service(
                forConfigurationDirectory: URL(fileURLWithPath: "/tmp/tokenusage-claude-example")
            ),
            "Claude Code-credentials-5cc8a6e5"
        )
        XCTAssertEqual(
            ClaudeKeychainService.service(
                forConfigurationDirectory: URL(fileURLWithPath: "/Users/example/.claude")
            ),
            "Claude Code-credentials-402b469b"
        )
    }

    func testTheDefaultDirectoryGetsNoSuffix() {
        XCTAssertEqual(
            ClaudeKeychainService.service(forConfigurationDirectory: nil),
            "Claude Code-credentials"
        )
        XCTAssertEqual(
            ClaudeKeychainService.defaultService,
            SecurityCLIClaudeLiveCredentialOperator.service
        )
    }

    func testTheDirectoryPathIsHashedInItsComposedForm() {
        // A decomposed and a composed spelling of the same directory are the same directory.
        let composed = URL(fileURLWithPath: "/tmp/\u{d55c}\u{ae00}")
        let decomposed = URL(fileURLWithPath: "/tmp/\u{1112}\u{1161}\u{11ab}\u{1100}\u{1173}\u{11af}")

        XCTAssertEqual(
            ClaudeKeychainService.service(forConfigurationDirectory: composed),
            ClaudeKeychainService.service(forConfigurationDirectory: decomposed)
        )
    }

    func testIsolationEnvironmentMovesBothTheSettingsAndTheCredentialStore() {
        let isolated = ClaudeCLIEnvironment.isolating(
            ["HOME": "/Users/example", "PATH": "/usr/bin"],
            configurationDirectory: URL(fileURLWithPath: "/tmp/throwaway")
        )

        XCTAssertEqual(isolated["CLAUDE_CONFIG_DIR"], "/tmp/throwaway")
        XCTAssertEqual(isolated["CLAUDE_SECURESTORAGE_CONFIG_DIR"], "/tmp/throwaway")
        XCTAssertEqual(isolated["HOME"], "/Users/example")
    }

    func testWithoutADirectoryTheEnvironmentIsLeftExactlyAsItWas() {
        let environment = ["HOME": "/Users/example"]

        XCTAssertEqual(
            ClaudeCLIEnvironment.isolating(environment, configurationDirectory: nil),
            environment
        )
    }
}
