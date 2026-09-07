import Foundation
import XCTest
@testable import TokenUsageCore

/// Exercises the real `/usr/bin/security` round trip that account switching depends on.
///
/// It mutates the login Keychain, so it only runs when explicitly asked for:
/// `TOKENUSAGE_KEYCHAIN_INTEGRATION=1 swift test --filter SecurityCLIKeychainIntegrationTests`.
/// Its service name is unique per run and removed afterwards, so it never touches Claude Code's
/// own item.
final class SecurityCLIKeychainIntegrationTests: XCTestCase {
    func testACredentialSurvivesAWriteAndReadBackThroughTheSecurityCLI() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TOKENUSAGE_KEYCHAIN_INTEGRATION"] == "1",
            "Set TOKENUSAGE_KEYCHAIN_INTEGRATION=1 to run against the login Keychain."
        )
        let service = "tokenusage-integration-\(UUID().uuidString)"
        let account = NSUserName()
        addTeardownBlock { Self.deleteItem(service: service, account: account) }

        let credentials = SecurityCLIClaudeLiveCredentialOperator(
            runner: SystemSecurityCLIProcessRunner(),
            writer: SystemSecurityCLIPasswordWriter(),
            service: service,
            account: account
        )
        let seeded = ClaudeCredentialFixture.envelope(accessToken: "seeded")
        let replacement = ClaudeCredentialFixture.envelope(accessToken: "replacement")

        // The CLI transport reports a missing item as a failed read rather than an empty one,
        // so the item is created first and every assertion below runs against a real item.
        try SystemSecurityCLIPasswordWriter().writeGenericPassword(
            service: service,
            account: account,
            password: seeded
        )
        XCTAssertEqual(try credentials.readEnvelope(), seeded)

        try credentials.replaceEnvelope(with: replacement, ifCurrentMatches: seeded)

        XCTAssertEqual(try credentials.readEnvelope(), replacement)
        XCTAssertThrowsError(
            try credentials.replaceEnvelope(with: seeded, ifCurrentMatches: seeded)
        ) { error in
            XCTAssertEqual(error as? ClaudeLiveCredentialError, .conflict)
        }
        print("CLAUDE_QA keychain_roundtrip service=redacted bytes=\(replacement.count) conflict_detected=true")
    }

    private static func deleteItem(service: String, account: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-s", service, "-a", account]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
