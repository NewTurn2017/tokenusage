import Darwin
import Foundation
import XCTest
@testable import TokenUsageCore

final class AtomicAuthFileOperatorTests: XCTestCase {
    private var testRoot: URL!
    private var authURL: URL!

    override func setUpWithError() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicAuthFileOperatorTests-\(UUID().uuidString)", isDirectory: true)
        authURL = testRoot
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
            XCTAssertFalse(FileManager.default.fileExists(atPath: testRoot.path))
        }
        testRoot = nil
        authURL = nil
    }

    func testCreatesPrivateDirectoryAndMode0600AuthFile() throws {
        let operatorUnderTest = AtomicAuthFileOperator(authFileURL: authURL)

        try operatorUnderTest.replaceAuthFile(with: Data("new-auth".utf8), ifCurrentMatches: nil)

        XCTAssertEqual(permissions(at: authURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(permissions(at: authURL), 0o600)
        XCTAssertEqual(try Data(contentsOf: authURL), Data("new-auth".utf8))
        XCTAssertEqual(try temporaryArtifacts(), [])
    }

    func testExternalMutationAbortsWithoutOverwrite() throws {
        try createAuthFile(Data("original-auth".utf8))
        let operatorUnderTest = AtomicAuthFileOperator(authFileURL: authURL)
        let expected = try operatorUnderTest.snapshot()
        let external = Data("external-auth".utf8)
        try external.write(to: authURL, options: .atomic)

        XCTAssertThrowsError(
            try operatorUnderTest.replaceAuthFile(
                with: Data("candidate-auth".utf8),
                ifCurrentMatches: expected
            )
        ) { error in
            XCTAssertEqual(error as? AtomicAuthFileError, .conflict)
        }
        XCTAssertEqual(try Data(contentsOf: authURL), external)
        XCTAssertEqual(try temporaryArtifacts(), [])
    }

    func testMetadataMutationWithSameBytesAborts() throws {
        let original = Data("original-auth".utf8)
        try createAuthFile(original)
        let operatorUnderTest = AtomicAuthFileOperator(authFileURL: authURL)
        let expected = try operatorUnderTest.snapshot()
        XCTAssertEqual(chmod(authURL.path, 0o640), 0)

        XCTAssertThrowsError(
            try operatorUnderTest.replaceAuthFile(
                with: Data("candidate-auth".utf8),
                ifCurrentMatches: expected
            )
        ) { error in
            XCTAssertEqual(error as? AtomicAuthFileError, .conflict)
        }
        XCTAssertEqual(try Data(contentsOf: authURL), original)
        XCTAssertEqual(permissions(at: authURL), 0o640)
    }

    func testVerificationFailureRestoresOriginalBytesAndPreservesCodexBackup() throws {
        let original = Data([0x00, 0xff, 0x10, 0x42])
        let backup = Data("codex-owned-backup".utf8)
        try createAuthFile(original)
        let backupURL = authURL.appendingPathExtension("bak")
        try backup.write(to: backupURL)
        let operatorUnderTest = AtomicAuthFileOperator(authFileURL: authURL)
        let expected = try operatorUnderTest.snapshot()

        XCTAssertThrowsError(
            try operatorUnderTest.replaceAuthFile(
                with: Data("candidate-auth".utf8),
                ifCurrentMatches: expected,
                verify: { throw VerificationSecretError(secret: "sentinel-secret") }
            )
        ) { error in
            XCTAssertEqual(error as? AtomicAuthFileError, .verificationFailed)
            XCTAssertFalse(error.localizedDescription.contains("sentinel-secret"))
        }
        XCTAssertEqual(try Data(contentsOf: authURL), original)
        XCTAssertEqual(try Data(contentsOf: backupURL), backup)
        XCTAssertEqual(permissions(at: authURL), 0o600)
        XCTAssertEqual(try temporaryArtifacts(), [])
    }

    func testSameProfileIsNoOp() throws {
        let original = Data("same-profile".utf8)
        try createAuthFile(original)
        let operatorUnderTest = AtomicAuthFileOperator(authFileURL: authURL)
        let expected = try operatorUnderTest.snapshot()
        let identityBefore = fileIdentity(at: authURL)
        let verifier = LockedCounter()

        try operatorUnderTest.replaceAuthFile(
            with: original,
            ifCurrentMatches: expected,
            verify: { verifier.increment() }
        )

        XCTAssertEqual(verifier.value, 0)
        XCTAssertEqual(fileIdentity(at: authURL), identityBefore)
        XCTAssertEqual(try temporaryArtifacts(), [])
    }

    func testProtocolPreconditionDetectsChangedBytes() throws {
        let original = Data("protocol-original".utf8)
        try createAuthFile(original)
        let operatorUnderTest: any AuthFileOperating = AtomicAuthFileOperator(authFileURL: authURL)
        let expected = try operatorUnderTest.readAuthFile()
        let external = Data("protocol-external".utf8)
        try external.write(to: authURL, options: .atomic)

        XCTAssertThrowsError(
            try operatorUnderTest.replaceAuthFile(
                with: Data("candidate".utf8),
                ifCurrentMatches: expected
            )
        )
        XCTAssertEqual(try Data(contentsOf: authURL), external)
    }

    private func createAuthFile(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: authURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: authURL)
        XCTAssertEqual(chmod(authURL.path, 0o600), 0)
    }

    private func permissions(at url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & mode_t(0o7777)
    }

    private func fileIdentity(at url: URL) -> UInt64 {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return UInt64(info.st_ino)
    }

    private func temporaryArtifacts() throws -> [String] {
        guard FileManager.default.fileExists(atPath: authURL.deletingLastPathComponent().path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            atPath: authURL.deletingLastPathComponent().path
        ).filter { $0.hasPrefix(".tokenusage-auth-") }
    }
}

private struct VerificationSecretError: LocalizedError {
    let secret: String
    var errorDescription: String? { "failed with \(secret)" }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
