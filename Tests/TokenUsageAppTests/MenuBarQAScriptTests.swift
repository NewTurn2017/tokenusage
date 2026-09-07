import Foundation
import XCTest

final class MenuBarQAScriptTests: XCTestCase {
    func testScriptUsesStableAccessibilitySelectorsAndScopeChecks() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repositoryRoot.appendingPathComponent("scripts/qa/menu-bar-qa.applescript")
        let source = try String(contentsOf: script, encoding: .utf8)

        for selector in [
            "Token Usage status",
            "usage-popover-window",
            "claude-5-hour-quota",
            "claude-weekly-quota",
            "claude-fable-weekly-quota",
            "openrouter-section",
            "codex-profile-quota-",
            "codex-profile-quota-scroll",
            "refresh-now",
            "codex-profile-picker",
            "save-current-profile",
            "add-account",
            "quit",
            "statistics",
            "history",
            "cost",
            "token-count",
        ] {
            XCTAssertTrue(source.contains(selector), "missing QA selector: \(selector)")
        }
        XCTAssertFalse(source.contains("Bartender"))
        XCTAssertTrue(source.contains("AXIdentifier"))
        XCTAssertTrue(source.contains("entire contents"))
        XCTAssertTrue(source.contains("attribute \"AXDescription\""))
        XCTAssertTrue(source.contains("attribute \"AXTitle\""))
        XCTAssertTrue(source.contains("set expectedProfiles to {}"))
        XCTAssertTrue(source.contains("\"--expected-profile\""))
        XCTAssertTrue(source.contains("set end of expectedProfiles to expectedProfile"))
        XCTAssertTrue(source.contains("my requireProfileQuotaRows(profileRows, expectedProfiles"))
        XCTAssertTrue(source.contains("my requireExactlyOneActiveProfile(profileRows)"))
        XCTAssertTrue(source.contains("perform action \"AXPress\" of selectedProfileItem"))
        XCTAssertTrue(source.contains("verified selected profile \" & selectedProfile"))
        XCTAssertTrue(source.contains("set quotaDescription to my requireDescription(quotaElement, \"Reset\""))
        XCTAssertTrue(source.contains("my requireDescription(activeProfile, selectedProfile"))
        XCTAssertTrue(source.contains("set originalActiveProfile to my profileNameFromPicker(profilePicker"))
        XCTAssertTrue(source.contains("my restoreOriginalProfile(originalActiveProfile, actionLog)"))
        XCTAssertTrue(source.contains("failed to restore original active profile"))
        XCTAssertTrue(source.contains("my logAction(actionLog, \"requested Quit through native control\")"))
        XCTAssertTrue(source.contains("\"--require-live-quotas\""))
        XCTAssertTrue(source.contains("if requireLive and quotaDescription does not contain \"% remaining\" then"))
        XCTAssertTrue(source.contains("set popoverPosition to position of visiblePopover"))
        XCTAssertTrue(source.contains("/usr/sbin/screencapture -x -R"))
        XCTAssertTrue(source.contains("if popoverContent is missing value then"))
        XCTAssertTrue(source.contains("if visiblePopover is missing value then"))
        XCTAssertFalse(source.contains("delay "))
        XCTAssertFalse(source.contains("delete-selected-profile"))
        XCTAssertFalse(source.contains("perform action \"AXPress\" of delete"))
    }

    func testArgumentParsingRequiresAtLeastOneExpectedProfileBeforeUIAutomation() throws {
        let result = try runMenuBarScript([
            "--action-log", "/tmp/tokenusage-task8-actions.txt",
            "--screenshots", "/tmp/tokenusage-task8-screenshots",
        ])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.message.contains("--expected-profile is required"), result.message)
        XCTAssertFalse(result.message.contains("TokenUsageApp is not running"), result.message)
    }

    func testArgumentParsingRejectsDuplicateExpectedProfileBeforeUIAutomation() throws {
        let result = try runMenuBarScript([
            "--action-log", "/tmp/tokenusage-task8-actions.txt",
            "--screenshots", "/tmp/tokenusage-task8-screenshots",
            "--expected-profile", "Personal",
            "--expected-profile", "Personal",
        ])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.message.contains("duplicate --expected-profile: Personal"),
            result.message
        )
        XCTAssertFalse(result.message.contains("TokenUsageApp is not running"), result.message)
    }

    func testRepeatedExpectedProfileArgumentsUseAStableProfileRowContract() throws {
        let source = try menuBarScriptSource()

        XCTAssertTrue(source.contains("repeat with expectedProfile in expectedProfiles"))
        XCTAssertTrue(source.contains("codex-profile-quota-"))
        XCTAssertTrue(source.contains("candidateIdentifier is not \"codex-profile-quota-scroll\""))
        XCTAssertTrue(source.contains("profileDescription starts with expectedName & \", profile ID \""))
        XCTAssertTrue(source.contains("profile quota row for \" & expectedName"))
        XCTAssertTrue(source.contains("if rowIdentifier is in profileIdentifiers then"))
        XCTAssertTrue(source.contains("set end of profileIdentifiers to rowIdentifier"))
        XCTAssertTrue(source.contains("set rowText to my requireDescription(profileRow, \"Reset\""))
        XCTAssertTrue(source.contains("if requireLive and rowText does not contain \"% remaining\" then"))
        XCTAssertTrue(source.contains("if rowText contains \", Active,\" then"))
        XCTAssertTrue(source.contains("if activeCount is not 1 then"))
        XCTAssertTrue(source.contains("my requireActiveProfileRow(updatedProfileRows, selectedProfile)"))
    }

    func testRestoreFailureAbortsInsteadOfReportingSuccess() throws {
        let source = try menuBarScriptSource()

        XCTAssertTrue(source.contains("on restoreOriginalProfile(originalActiveProfile, actionLog)"))
        XCTAssertTrue(source.contains("error \"failed to restore original active profile"))
        XCTAssertTrue(source.contains("my restoreOriginalProfile(originalActiveProfile, actionLog)"))
        XCTAssertTrue(source.contains("error originalError number originalNumber"))
        XCTAssertFalse(source.contains("ignoring application responses"))
    }

    func testArgumentParsingRejectsUnknownArgumentBeforeStartingUIAutomation() throws {
        let result = try runMenuBarScript(["--unknown"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.message.contains("unknown argument: --unknown"), result.message)
    }

    func testAccountManagementScriptUsesOnlyNonDestructiveAccessibilityActions() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repositoryRoot.appendingPathComponent(
            "scripts/qa/account-management-qa.applescript"
        )
        let source = try String(contentsOf: script, encoding: .utf8)

        for selector in [
            "codex-profile-picker",
            "save-current-profile",
            "codex-profile-name",
            "confirm-save-current-profile",
            "cancel-save-current-profile",
            "add-account",
            "new-codex-profile-name",
            "confirm-new-codex-login",
            "cancel-new-codex-login",
            "codex-profile-actions",
            "delete-selected-profile",
            "quit",
        ] {
            XCTAssertTrue(source.contains(selector), "missing account QA selector: \(selector)")
        }
        XCTAssertTrue(source.contains("verified account picker value"))
        XCTAssertTrue(source.contains("verified save current login editor"))
        XCTAssertTrue(source.contains("verified new login editor"))
        XCTAssertTrue(source.contains("verified delete action"))
        XCTAssertFalse(source.contains("click deleteProfile"))
        XCTAssertFalse(source.contains("perform action \"AXPress\" of deleteProfile"))
        XCTAssertFalse(source.contains("set value of"))
        XCTAssertFalse(source.contains("delay "))
    }

    private func menuBarScriptSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repositoryRoot.appendingPathComponent("scripts/qa/menu-bar-qa.applescript")
        return try String(contentsOf: script, encoding: .utf8)
    }

    private func runMenuBarScript(_ arguments: [String]) throws -> (status: Int32, message: String) {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repositoryRoot.appendingPathComponent("scripts/qa/menu-bar-qa.applescript")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [script.path] + arguments
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
