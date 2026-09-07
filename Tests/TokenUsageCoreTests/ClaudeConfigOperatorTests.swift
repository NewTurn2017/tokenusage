import Foundation
import XCTest
@testable import TokenUsageCore

final class ClaudeConfigOperatorTests: XCTestCase {
    func testApplyingAnAccountKeepsEveryUnrelatedSettingIntact() throws {
        let file = MemoryAuthFile(json: [
            "oauthAccount": ["emailAddress": "personal@example.com"],
            "projects": ["/Users/me/app": ["allowedTools": ["Bash"]]],
            "numStartups": 1_720,
        ])
        let configOperator = FileClaudeConfigOperator(fileOperator: file)

        try configOperator.applyAccountJSON(#"{"emailAddress":"work@example.com"}"#)

        let root = try file.root()
        let account = try XCTUnwrap(root["oauthAccount"] as? [String: Any])
        XCTAssertEqual(account["emailAddress"] as? String, "work@example.com")
        XCTAssertEqual(root["numStartups"] as? Int, 1_720)
        XCTAssertNotNil(root["projects"], "session history must survive an account switch")
    }

    func testApplyingAnAccountDropsCachesBelongingToThePreviousAccount() throws {
        let file = MemoryAuthFile(json: [
            "oauthAccount": ["emailAddress": "personal@example.com"],
            "modelAccessCache": ["opus": true],
            "hasAvailableSubscription": true,
            "tipsHistory": ["tip": 1],
        ])
        let configOperator = FileClaudeConfigOperator(fileOperator: file)

        try configOperator.applyAccountJSON(#"{"emailAddress":"work@example.com"}"#)

        let root = try file.root()
        XCTAssertNil(root["modelAccessCache"])
        XCTAssertNil(root["hasAvailableSubscription"])
        XCTAssertNotNil(root["tipsHistory"], "unrelated preferences are not account state")
    }

    func testReadingReturnsTheAccountBlockAndNilWhenThereIsNone() throws {
        let withAccount = FileClaudeConfigOperator(
            fileOperator: MemoryAuthFile(json: [
                "oauthAccount": ["emailAddress": "personal@example.com"],
            ])
        )
        let withoutAccount = FileClaudeConfigOperator(
            fileOperator: MemoryAuthFile(json: ["numStartups": 3])
        )

        XCTAssertEqual(
            try withAccount.readAccountJSON(),
            #"{"emailAddress":"personal@example.com"}"#
        )
        XCTAssertNil(try withoutAccount.readAccountJSON())
    }

    func testAMissingConfigFileIsLeftForClaudeCodeToRecreate() throws {
        let file = MemoryAuthFile(data: nil)
        let configOperator = FileClaudeConfigOperator(fileOperator: file)

        try configOperator.applyAccountJSON(#"{"emailAddress":"work@example.com"}"#)

        XCTAssertNil(file.currentData)
    }

    func testAFileThatKeepsChangingUnderneathReportsAConflictInsteadOfClobbering() throws {
        let file = MemoryAuthFile(json: ["oauthAccount": ["emailAddress": "a@example.com"]])
        file.rejectEveryReplacement = true
        let configOperator = FileClaudeConfigOperator(fileOperator: file)

        XCTAssertThrowsError(
            try configOperator.applyAccountJSON(#"{"emailAddress":"work@example.com"}"#)
        ) { error in
            XCTAssertEqual(error as? ClaudeConfigError, .conflict)
        }
        let root = try file.root()
        let account = try XCTUnwrap(root["oauthAccount"] as? [String: Any])
        XCTAssertEqual(account["emailAddress"] as? String, "a@example.com")
    }
}

private final class MemoryAuthFile: AuthFileOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var rejectEveryReplacement = false

    init(data: Data?) {
        self.data = data
    }

    convenience init(json: [String: Any]) {
        self.init(data: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
    }

    func readAuthFile() throws -> Data? {
        lock.withLock { data }
    }

    func replaceAuthFile(with data: Data, ifCurrentMatches expectedData: Data?) throws {
        try lock.withLock {
            if rejectEveryReplacement { throw AtomicAuthFileError.conflict }
            guard self.data == expectedData else { throw AtomicAuthFileError.conflict }
            self.data = data
        }
    }

    func restoreAuthFile(to data: Data?, ifCurrentMatches expectedData: Data?) throws {
        try lock.withLock {
            guard self.data == expectedData else { throw AtomicAuthFileError.conflict }
            self.data = data
        }
    }

    var currentData: Data? {
        lock.withLock { data }
    }

    func root() throws -> [String: Any] {
        let current = try XCTUnwrap(currentData)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
    }
}
