import Foundation
import XCTest
@testable import TokenUsageCore

final class ClaudeRefreshLockTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsage-RefreshLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cc1", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var directory: URL { root.appendingPathComponent("cc1", isDirectory: true) }
    private var currentLock: String { directory.appendingPathComponent(".oauth_refresh.lock").path }
    private var legacyLock: String { root.appendingPathComponent("cc1.lock").path }

    func testTakesBothOfClaudeCodesLocksAndReleasesThem() throws {
        let lease = try XCTUnwrap(DirectoryClaudeRefreshLock().acquire(configurationDirectory: directory))

        XCTAssertTrue(FileManager.default.fileExists(atPath: currentLock))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyLock))
        XCTAssertNil(
            DirectoryClaudeRefreshLock().acquire(configurationDirectory: directory),
            "a second renewal waits for the first"
        )

        lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentLock))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyLock))
    }

    func testALegacyLockHeldByAnOlderClaudeCodeKeepsTheRenewalWaiting() throws {
        try FileManager.default.createDirectory(atPath: legacyLock, withIntermediateDirectories: false)

        XCTAssertNil(DirectoryClaudeRefreshLock().acquire(configurationDirectory: directory))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: currentLock),
            "the lock it did take is given back"
        )
    }

    func testALockItsHolderStoppedRefreshingIsTakenOver() throws {
        try FileManager.default.createDirectory(atPath: currentLock, withIntermediateDirectories: false)
        let modified = Date()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: currentLock)

        XCTAssertNil(
            DirectoryClaudeRefreshLock(now: { modified.addingTimeInterval(30) })
                .acquire(configurationDirectory: directory)
        )
        let lease = DirectoryClaudeRefreshLock(now: { modified.addingTimeInterval(61) })
            .acquire(configurationDirectory: directory)
        XCTAssertNotNil(lease)
        lease?.release()
    }

    func testALockWithContentsIsLeftToClaudeCode() throws {
        try FileManager.default.createDirectory(atPath: currentLock, withIntermediateDirectories: false)
        try Data().write(to: URL(fileURLWithPath: currentLock).appendingPathComponent("holder"))
        let modified = Date()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: currentLock)

        XCTAssertNil(
            DirectoryClaudeRefreshLock(now: { modified.addingTimeInterval(120) })
                .acquire(configurationDirectory: directory)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentLock))
    }
}
