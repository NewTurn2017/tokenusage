import Darwin
import Foundation

final class SecurityCLIFIFOReadOperation: @unchecked Sendable {
    private let jobRunner: any LaunchdJobRunning
    private let lock = NSLock()
    private let removalFinished = DispatchSemaphore(value: 0)
    private let cancellationReadDescriptor: Int32
    private let cancellationWriteDescriptor: Int32
    private var label: String?
    private var submitted = false
    private var cancellationRequested = false
    private var removalStarted = false
    private var removalCompleted = false
    private var removalSucceeded = false

    init(jobRunner: any LaunchdJobRunning) throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw SystemSecurityCLIProcessRunnerError.transportUnavailable
        }
        cancellationReadDescriptor = descriptors[0]
        cancellationWriteDescriptor = descriptors[1]
        _ = fcntl(cancellationReadDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(cancellationWriteDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(cancellationWriteDescriptor, F_SETFL, O_NONBLOCK)
        self.jobRunner = jobRunner
    }

    deinit {
        close(cancellationReadDescriptor)
        close(cancellationWriteDescriptor)
    }

    func execute(
        executable: URL,
        arguments: [String],
        label: String,
        temporaryDirectory: URL,
        readTimeoutMilliseconds: Int32,
        maxPayloadBytes: Int
    ) throws -> SecurityCLIProcessResult {
        let directory = temporaryDirectory.appendingPathComponent(
            "tokenusage-credential-\(UUID().uuidString)", isDirectory: true
        )
        let fifo = directory.appendingPathComponent("credential.fifo")
        let descriptor = try openFIFO(at: fifo, in: directory)
        defer {
            close(descriptor)
            unlink(fifo.path)
            rmdir(directory.path)
        }

        register(label: label)
        let result: Result<SecurityCLIProcessResult, any Error>
        if isCancellationRequested {
            result = .failure(CancellationError())
        } else {
            result = runJob(
                executable: executable,
                arguments: arguments,
                label: label,
                fifo: fifo,
                descriptor: descriptor,
                timeoutMilliseconds: readTimeoutMilliseconds,
                maxPayloadBytes: maxPayloadBytes
            )
        }
        try finish(result: result)
        return try result.get()
    }

    func cancel() {
        let shouldRemove = lock.withLock {
            cancellationRequested = true
            guard submitted, !removalStarted else { return false }
            removalStarted = true
            return true
        }
        shouldRemove ? performRemoval() : signalCancellation()
    }

    private func openFIFO(at fifo: URL, in directory: URL) throws -> Int32 {
        var descriptor: Int32 = -1
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard mkfifo(fifo.path, 0o600) == 0 else {
                throw SystemSecurityCLIProcessRunnerError.transportUnavailable
            }
            descriptor = open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw SystemSecurityCLIProcessRunnerError.transportUnavailable
            }
            return descriptor
        } catch {
            if descriptor >= 0 { close(descriptor) }
            unlink(fifo.path)
            rmdir(directory.path)
            throw SystemSecurityCLIProcessRunnerError.transportUnavailable
        }
    }

    private func runJob(
        executable: URL,
        arguments: [String],
        label: String,
        fifo: URL,
        descriptor: Int32,
        timeoutMilliseconds: Int32,
        maxPayloadBytes: Int
    ) -> Result<SecurityCLIProcessResult, any Error> {
        do {
            let status = try jobRunner.submit(
                label: label,
                standardOutputPath: fifo.path,
                executable: executable,
                arguments: arguments
            )
            didSubmit()
            guard status == 0 else {
                return .success(.init(terminationStatus: status, stdout: Data()))
            }
            let payload = try readPayload(
                from: descriptor, timeoutMilliseconds: timeoutMilliseconds,
                maxPayloadBytes: maxPayloadBytes
            )
            return .success(.init(
                terminationStatus: payload.isEmpty ? 1 : 0, stdout: payload))
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch let error as SystemSecurityCLIProcessRunnerError {
            return .failure(error)
        } catch {
            return .failure(SystemSecurityCLIProcessRunnerError.transportUnavailable)
        }
    }
    private var isCancellationRequested: Bool { lock.withLock { cancellationRequested } }
    private func register(label: String) {
        lock.withLock { self.label = label }
    }
    private func didSubmit() {
        let shouldRemove = lock.withLock {
            submitted = true
            guard cancellationRequested, !removalStarted else { return false }
            removalStarted = true
            return true
        }
        if shouldRemove { performRemoval() }
    }

    private func finish(result: Result<SecurityCLIProcessResult, any Error>) throws {
        if lock.withLock({ submitted }), !removeSubmittedJob() {
            throw SystemSecurityCLIProcessRunnerError.jobRemovalFailed
        }
        if isCancellationRequested { throw CancellationError() }
        if case .failure(let error) = result { throw error }
    }

    private func removeSubmittedJob() -> Bool {
        let action: RemovalAction = lock.withLock {
            if removalCompleted { return .completed(removalSucceeded) }
            if removalStarted { return .wait }
            removalStarted = true
            return .remove
        }
        switch action {
        case .remove:
            performRemoval()
        case .wait:
            guard removalFinished.wait(timeout: .now() + .seconds(2)) == .success else {
                return false
            }
        case .completed(let succeeded):
            return succeeded
        }
        return lock.withLock { removalCompleted && removalSucceeded }
    }

    private func performRemoval() {
        let currentLabel = lock.withLock { label }
        let succeeded: Bool
        do {
            guard let currentLabel else {
                throw SystemSecurityCLIProcessRunnerError.jobRemovalFailed
            }
            try jobRunner.remove(label: currentLabel)
            succeeded = true
        } catch {
            succeeded = false
        }
        lock.withLock {
            removalSucceeded = succeeded
            removalCompleted = true
        }
        removalFinished.signal()
        signalCancellation()
    }

    private func signalCancellation() {
        var byte: UInt8 = 1
        _ = withUnsafePointer(to: &byte) {
            Darwin.write(cancellationWriteDescriptor, $0, 1)
        }
    }

    private func readPayload(
        from descriptor: Int32, timeoutMilliseconds: Int32,
        maxPayloadBytes: Int
    ) throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutMilliseconds) * 1_000_000
        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw transportError }
            let remaining = max(1, min(UInt64(Int32.max), (deadline - now) / 1_000_000))
            var descriptors = [
                pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: cancellationReadDescriptor, events: Int16(POLLIN), revents: 0)
            ]
            let result = poll(&descriptors, nfds_t(descriptors.count), Int32(remaining))
            if result == 0 { throw transportError }
            if result < 0 {
                if errno == EINTR { continue }
                throw transportError
            }
            if descriptors[1].revents & Int16(POLLIN) != 0 { throw CancellationError() }
            guard descriptors[0].revents & Int16(POLLIN) != 0 else { continue }
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw transportError
            }
            if count == 0 { continue }
            payload.append(contentsOf: buffer.prefix(Int(count)))
            guard payload.count <= maxPayloadBytes else { throw transportError }
            if let newline = payload.firstIndex(of: 0x0A) {
                return payload.prefix(through: newline)
            }
        }
    }
    private var transportError: SystemSecurityCLIProcessRunnerError { .transportUnavailable }
    private enum RemovalAction {
        case remove, wait, completed(Bool)
    }
}
