import CryptoKit
import Darwin
import Foundation

public enum AtomicAuthFileError: Error, Equatable, LocalizedError {
    case conflict
    case verificationFailed
    case ioFailed
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .conflict:
            "Authentication file changed before it could be replaced."
        case .verificationFailed:
            "Authentication file verification failed."
        case .ioFailed:
            "Authentication file operation failed."
        case .rollbackFailed:
            "Authentication file rollback failed."
        }
    }
}

private struct AuthFileMetadata: Equatable {
    let permissions: UInt16
    let size: UInt64
    let device: UInt64
    let inode: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}

private struct AuthFileSnapshot: Equatable {
    let data: Data
    let digest: Data
    let metadata: AuthFileMetadata
}

public final class AtomicAuthFileOperator: AuthFileOperating, @unchecked Sendable {
    private let authFileURL: URL
    private let lock = NSLock()
    private var lastSnapshot: AuthFileSnapshot?

    public init(authFileURL: URL) {
        self.authFileURL = authFileURL
    }

    public func readAuthFile() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let current = try readSnapshot()
        lastSnapshot = current
        return current?.data
    }

    public func snapshot() throws -> Data? {
        try readAuthFile()
    }

    public func replaceAuthFile(with data: Data, ifCurrentMatches expectedData: Data?) throws {
        try replaceAuthFile(with: data, ifCurrentMatches: expectedData, verify: nil)
    }

    public func restoreAuthFile(to data: Data?, ifCurrentMatches expectedData: Data?) throws {
        lock.lock()
        defer { lock.unlock() }

        let current: AuthFileSnapshot?
        do {
            current = try readSnapshot()
        } catch {
            throw AtomicAuthFileError.ioFailed
        }
        try validatePrecondition(expectedData: expectedData, current: current)

        if current?.data == data {
            lastSnapshot = current
            return
        }

        let parentURL = authFileURL.deletingLastPathComponent()
        do {
            try ensurePrivateDirectory(at: parentURL)
            if let data {
                var didReplace = false
                try writeReplacement(
                    data: data,
                    mode: 0o600,
                    in: parentURL,
                    didReplace: &didReplace
                )
                guard let restored = try readSnapshot(), restored.data == data,
                      restored.metadata.permissions == 0o600 else {
                    throw AtomicAuthFileError.rollbackFailed
                }
                lastSnapshot = restored
            } else {
                let result = authFileURL.path.withCString { path in
                    unlink(path)
                }
                guard result == 0 || errno == ENOENT else {
                    throw AtomicAuthFileError.rollbackFailed
                }
                try fsyncDirectory(at: parentURL)
                lastSnapshot = nil
            }
        } catch let error as AtomicAuthFileError {
            throw error
        } catch {
            throw AtomicAuthFileError.rollbackFailed
        }
    }

    public func replaceAuthFile(
        with data: Data,
        ifCurrentMatches expectedData: Data?,
        verify: (() throws -> Void)?
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let current: AuthFileSnapshot?
        do {
            current = try readSnapshot()
        } catch {
            throw AtomicAuthFileError.ioFailed
        }
        try validatePrecondition(expectedData: expectedData, current: current)

        if let current, current.data == data {
            lastSnapshot = current
            return
        }

        let parentURL = authFileURL.deletingLastPathComponent()
        do {
            try ensurePrivateDirectory(at: parentURL)
        } catch {
            throw AtomicAuthFileError.ioFailed
        }

        var didReplace = false
        do {
            try writeReplacement(
                data: data,
                mode: 0o600,
                in: parentURL,
                didReplace: &didReplace
            )

            guard let written = try readSnapshot(), written.data == data,
                  written.metadata.permissions == 0o600 else {
                throw AtomicAuthFileError.verificationFailed
            }

            do {
                try verify?()
            } catch {
                throw AtomicAuthFileError.verificationFailed
            }

            guard let verified = try readSnapshot(), verified.data == data,
                  verified.metadata.permissions == 0o600 else {
                throw AtomicAuthFileError.verificationFailed
            }
            lastSnapshot = verified
        } catch {
            let failure = (error as? AtomicAuthFileError) ?? .ioFailed
            if didReplace {
                do {
                    try rollback(to: current, in: parentURL)
                } catch {
                    throw AtomicAuthFileError.rollbackFailed
                }
            }
            throw failure
        }
    }

    private func validatePrecondition(
        expectedData: Data?,
        current: AuthFileSnapshot?
    ) throws {
        guard let expectedData else {
            guard current == nil else {
                throw AtomicAuthFileError.conflict
            }
            return
        }

        guard let current, current.data == expectedData else {
            throw AtomicAuthFileError.conflict
        }
        if let lastSnapshot, lastSnapshot.data == expectedData,
           (lastSnapshot.digest != current.digest || lastSnapshot.metadata != current.metadata) {
            throw AtomicAuthFileError.conflict
        }
    }

    private func readSnapshot() throws -> AuthFileSnapshot? {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: authFileURL)
        let metadata = try metadata(at: authFileURL)
        return AuthFileSnapshot(
            data: data,
            digest: Data(SHA256.hash(data: data)),
            metadata: metadata
        )
    }

    private func metadata(at url: URL) throws -> AuthFileMetadata {
        var info = stat()
        let result = url.path.withCString { path in
            lstat(path, &info)
        }
        guard result == 0 else {
            throw AtomicAuthFileError.ioFailed
        }
        return AuthFileMetadata(
            permissions: UInt16(info.st_mode & mode_t(0o7777)),
            size: UInt64(info.st_size),
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private func ensurePrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let result = url.path.withCString { path in
            chmod(path, mode_t(0o700))
        }
        guard result == 0 else {
            throw AtomicAuthFileError.ioFailed
        }
    }

    private func writeReplacement(
        data: Data,
        mode: UInt16,
        in directoryURL: URL,
        didReplace: inout Bool
    ) throws {
        let temporaryURL = directoryURL
            .appendingPathComponent(".tokenusage-auth-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        try writeTemporary(data: data, mode: mode, to: temporaryURL)
        let renameResult = temporaryURL.path.withCString { temporaryPath in
            authFileURL.path.withCString { destinationPath in
                rename(temporaryPath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw AtomicAuthFileError.ioFailed
        }
        didReplace = true
        try fsyncDirectory(at: directoryURL)
    }

    private func writeTemporary(data: Data, mode: UInt16, to url: URL) throws {
        let descriptor = url.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode))
        }
        guard descriptor >= 0 else {
            throw AtomicAuthFileError.ioFailed
        }
        defer { _ = close(descriptor) }

        guard fchmod(descriptor, mode_t(mode)) == 0 else {
            throw AtomicAuthFileError.ioFailed
        }

        let writeError: AtomicAuthFileError? = data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return nil
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else {
                    return .ioFailed
                }
                offset += written
            }
            return nil
        }
        if let writeError {
            throw writeError
        }
        guard fsync(descriptor) == 0 else {
            throw AtomicAuthFileError.ioFailed
        }
    }

    private func fsyncDirectory(at url: URL) throws {
        let descriptor = url.path.withCString { path in
            open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw AtomicAuthFileError.ioFailed
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw AtomicAuthFileError.ioFailed
        }
    }

    private func rollback(to snapshot: AuthFileSnapshot?, in directoryURL: URL) throws {
        if let snapshot {
            var didReplace = false
            try writeReplacement(
                data: snapshot.data,
                mode: snapshot.metadata.permissions,
                in: directoryURL,
                didReplace: &didReplace
            )
            return
        }

        let result = authFileURL.path.withCString { path in
            unlink(path)
        }
        guard result == 0 || errno == ENOENT else {
            throw AtomicAuthFileError.rollbackFailed
        }
        try fsyncDirectory(at: directoryURL)
    }
}
