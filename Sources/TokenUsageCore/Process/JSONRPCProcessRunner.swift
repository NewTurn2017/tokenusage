import Darwin
import Foundation

public final class JSONRPCProcessRunner: JSONRPCProcessRunning, @unchecked Sendable {
    public enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case invalidRequest
        case failedToLaunch(String)
        case timedOut(stderr: String)
        case unexpectedEOF(stderr: String)
        case malformedResponse(stderr: String)
        case noMatchingResponse(expectedID: String, stderr: String)
        case processExited(status: Int32, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .invalidRequest:
                return "The JSON-RPC request is invalid."
            case let .failedToLaunch(message):
                return "The JSON-RPC process could not be launched: \(message)"
            case let .timedOut(stderr):
                return "The JSON-RPC process timed out.\(Self.stderrSuffix(stderr))"
            case let .unexpectedEOF(stderr):
                return "The JSON-RPC process ended before a matching response.\(Self.stderrSuffix(stderr))"
            case let .malformedResponse(stderr):
                return "The JSON-RPC process emitted a malformed response.\(Self.stderrSuffix(stderr))"
            case let .noMatchingResponse(expectedID, stderr):
                return "The JSON-RPC process emitted no response for ID \(expectedID).\(Self.stderrSuffix(stderr))"
            case let .processExited(status, stderr):
                return "The JSON-RPC process exited with status \(status).\(Self.stderrSuffix(stderr))"
            }
        }

        private static func stderrSuffix(_ stderr: String) -> String {
            stderr.isEmpty ? "" : " Stderr: \(stderr)"
        }
    }

    private let timeout: Duration
    private let terminationGracePeriod: Duration

    public init(
        timeout: Duration = .seconds(10),
        terminationGracePeriod: Duration = .milliseconds(250)
    ) {
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        request: Data
    ) async throws -> Data {
        guard let parsedRequest = ParsedRequest(request) else {
            throw Error.invalidRequest
        }

        let secrets = Self.secrets(in: request, environment: environment)
        let session = ProcessSession(stderrCaptureLimit: Self.stderrCaptureLimit(for: secrets))
        do {
            try session.start(
                executable: executable,
                arguments: arguments,
                environment: environment
            )
        } catch {
            throw Error.failedToLaunch(Self.sanitize(String(describing: error), secrets: secrets))
        }

        return try await withTaskCancellationHandler {
            do {
                let response = try await raceExchange(
                    session: session,
                    request: request,
                    requestID: parsedRequest.id
                )
                _ = await session.terminateAndReap(gracePeriod: terminationGracePeriod)
                return response
            } catch {
                let completion = await session.terminateAndReap(gracePeriod: terminationGracePeriod)
                if error is CancellationError {
                    throw CancellationError()
                }
                let stderr = Self.sanitize(completion.stderr, secrets: secrets)
                guard let failure = error as? ProtocolFailure else {
                    if !completion.wasRunningAtCleanup, completion.status != 0 {
                        throw Error.processExited(status: completion.status, stderr: stderr)
                    }
                    throw Error.unexpectedEOF(stderr: stderr)
                }
                switch failure {
                case .timedOut:
                    throw Error.timedOut(stderr: stderr)
                case .unexpectedEOF:
                    if !completion.wasRunningAtCleanup, completion.status != 0 {
                        throw Error.processExited(status: completion.status, stderr: stderr)
                    }
                    throw Error.unexpectedEOF(stderr: stderr)
                case .malformedResponse:
                    throw Error.malformedResponse(stderr: stderr)
                case let .noMatchingResponse(expectedID):
                    throw Error.noMatchingResponse(expectedID: expectedID, stderr: stderr)
                }
            }
        } onCancel: {
            session.requestTermination()
        }
    }

    private func raceExchange(
        session: ProcessSession,
        request: Data,
        requestID: RPCID
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await Self.exchange(session: session, request: request, requestID: requestID)
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw ProtocolFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ProtocolFailure.unexpectedEOF
            }
            return result
        }
    }

    private static func exchange(
        session: ProcessSession,
        request: Data,
        requestID: RPCID
    ) async throws -> Data {
        try session.send(Self.initializeRequest)

        var waitingForInitialize = true
        var sawMismatchedResponse = false
        for await event in session.outputEvents {
            try Task.checkCancellation()
            switch event {
            case let .line(line):
                let responseID = try responseID(in: line)
                guard let responseID else {
                    continue
                }
                if waitingForInitialize, responseID == .number(1) {
                    try session.send(Self.initializedNotification)
                    try session.send(request)
                    waitingForInitialize = false
                } else if !waitingForInitialize, responseID == requestID {
                    return line
                } else {
                    sawMismatchedResponse = true
                }
            case .eof:
                if sawMismatchedResponse {
                    let expectedID = waitingForInitialize ? "1" : requestID.displayValue
                    throw ProtocolFailure.noMatchingResponse(expectedID: expectedID)
                }
                throw ProtocolFailure.unexpectedEOF
            }
        }
        try Task.checkCancellation()
        throw ProtocolFailure.unexpectedEOF
    }

    private static func responseID(in line: Data) throws -> RPCID? {
        guard
            let value = try? JSONSerialization.jsonObject(with: line),
            let object = value as? [String: Any]
        else {
            throw ProtocolFailure.malformedResponse
        }
        if let version = object["jsonrpc"], version as? String != "2.0" {
            throw ProtocolFailure.malformedResponse
        }

        guard let rawID = object["id"] else {
            guard object["method"] is String else {
                throw ProtocolFailure.malformedResponse
            }
            return nil
        }
        guard object["result"] != nil || object["error"] != nil,
              let id = RPCID(rawID) else {
            throw ProtocolFailure.malformedResponse
        }
        return id
    }

    private static let initializeRequest = Data(
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"TokenUsage","version":"1.0"}}}"#.utf8
    )
    private static let initializedNotification = Data(
        #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#.utf8
    )

    private static func secrets(in request: Data, environment: [String: String]) -> [String] {
        var values = Set(environment.values.filter { !$0.isEmpty })
        if let requestString = String(data: request, encoding: .utf8), !requestString.isEmpty {
            values.insert(requestString)
        }
        if let object = try? JSONSerialization.jsonObject(with: request) {
            collectScalarStrings(from: object, into: &values)
        }
        return values.sorted { $0.count > $1.count }
    }

    private static func collectScalarStrings(from value: Any, into values: inout Set<String>) {
        switch value {
        case let string as String where !string.isEmpty:
            values.insert(string)
        case let number as NSNumber:
            values.insert(number.stringValue)
        case let array as [Any]:
            array.forEach { collectScalarStrings(from: $0, into: &values) }
        case let object as [String: Any]:
            object.values.forEach { collectScalarStrings(from: $0, into: &values) }
        default:
            break
        }
    }

    private static func sanitize(_ stderr: Data, secrets: [String]) -> String {
        sanitize(String(decoding: stderr, as: UTF8.self), secrets: secrets)
    }

    private static func sanitize(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        let scalars = result.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.value >= 0x20
        }
        return String(String.UnicodeScalarView(scalars).prefix(maximumReportedStderrCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stderrCaptureLimit(for secrets: [String]) -> Int {
        let longestSecret = secrets.lazy.map { $0.utf8.count }.max() ?? 0
        guard longestSecret <= maximumSecretRedactionBytes else { return 0 }
        return maximumReportedStderrCharacters + longestSecret
    }

    private static let maximumReportedStderrCharacters = 64 * 1024
    private static let maximumSecretRedactionBytes = 1024 * 1024
}

private enum ProtocolFailure: Swift.Error {
    case timedOut
    case unexpectedEOF
    case malformedResponse
    case noMatchingResponse(expectedID: String)
}

private enum RPCID: Equatable, Sendable {
    case string(String)
    case number(Decimal)

    init?(_ value: Any) {
        if let string = value as? String {
            self = .string(string)
            return
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        self = .number(number.decimalValue)
    }

    var displayValue: String {
        switch self {
        case .string:
            return "[REDACTED]"
        case let .number(number):
            return NSDecimalNumber(decimal: number).stringValue
        }
    }
}

private struct ParsedRequest: Sendable {
    let id: RPCID

    init?(_ data: Data) {
        guard
            !data.isEmpty,
            !data.contains(0x0A),
            !data.contains(0x0D),
            let value = try? JSONSerialization.jsonObject(with: data),
            let object = value as? [String: Any],
            object["jsonrpc"] as? String == "2.0",
            object["method"] is String,
            let rawID = object["id"],
            let id = RPCID(rawID)
        else {
            return nil
        }
        self.id = id
    }
}

private final class ProcessSession: @unchecked Sendable {
    enum OutputEvent: Sendable {
        case line(Data)
        case eof
    }

    struct Completion: Sendable {
        let status: Int32
        let wasRunningAtCleanup: Bool
        let stderr: Data
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorOutput = Pipe()
    private let outputContinuation: AsyncStream<OutputEvent>.Continuation
    let outputEvents: AsyncStream<OutputEvent>

    private let exitSignal = DispatchSemaphore(value: 0)
    private let outputFinished = DispatchSemaphore(value: 0)
    private let errorOutputFinished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var launched = false
    private var inputClosed = false
    private var terminationRequested = false
    private var capturedStderr = Data()
    private let stderrCaptureLimit: Int

    init(stderrCaptureLimit: Int) {
        self.stderrCaptureLimit = stderrCaptureLimit
        var continuation: AsyncStream<OutputEvent>.Continuation!
        outputEvents = AsyncStream { continuation = $0 }
        outputContinuation = continuation
    }

    func start(executable: URL, arguments: [String], environment: [String: String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        process.terminationHandler = { [exitSignal] _ in
            exitSignal.signal()
        }
        try process.run()
        lock.withLock { launched = true }
        startReaders()
    }

    func send(_ message: Data) throws {
        var framed = message
        framed.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: framed)
    }

    func closeInput() {
        let shouldClose = lock.withLock {
            guard !inputClosed else { return false }
            inputClosed = true
            return true
        }
        if shouldClose {
            try? input.fileHandleForWriting.close()
        }
    }

    func requestTermination() {
        let shouldTerminate = lock.withLock {
            guard launched, !terminationRequested else { return false }
            terminationRequested = true
            return true
        }
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func terminateAndReap(gracePeriod: Duration) async -> Completion {
        await Task.detached(priority: .userInitiated) {
            self.terminateAndReapBlocking(gracePeriod: gracePeriod)
        }.value
    }

    private func terminateAndReapBlocking(gracePeriod: Duration) -> Completion {
        closeInput()
        let wasRunningAtCleanup = process.isRunning
        if wasRunningAtCleanup {
            requestTermination()
            if process.isRunning,
               exitSignal.wait(timeout: .now() + gracePeriod.dispatchInterval) == .timedOut,
               process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        outputFinished.wait()
        errorOutputFinished.wait()
        let stderr = lock.withLock { capturedStderr }
        return Completion(
            status: process.terminationStatus,
            wasRunningAtCleanup: wasRunningAtCleanup,
            stderr: stderr
        )
    }

    private func startReaders() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var buffered = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { break }
                buffered.append(chunk)
                while let newline = buffered.firstIndex(of: 0x0A) {
                    var line = Data(buffered[..<newline])
                    buffered.removeSubrange(...newline)
                    if line.last == 0x0D {
                        line.removeLast()
                    }
                    outputContinuation.yield(.line(line))
                }
            }
            if !buffered.isEmpty {
                if buffered.last == 0x0D {
                    buffered.removeLast()
                }
                outputContinuation.yield(.line(buffered))
            }
            outputContinuation.yield(.eof)
            outputContinuation.finish()
            outputFinished.signal()
        }

        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let chunk = errorOutput.fileHandleForReading.availableData
                guard !chunk.isEmpty else { break }
                lock.withLock {
                    let remaining = stderrCaptureLimit - capturedStderr.count
                    if remaining > 0 {
                        capturedStderr.append(chunk.prefix(remaining))
                    }
                }
            }
            errorOutputFinished.signal()
        }
    }
}

private extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let components = self.components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        let nanosecondsFromSeconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !nanosecondsFromSeconds.overflow else { return .never }
        let nanoseconds = nanosecondsFromSeconds.partialValue + attoseconds / 1_000_000_000
        guard nanoseconds <= Int64(Int.max) else { return .never }
        return .nanoseconds(Int(nanoseconds))
    }
}

public typealias JSONRPCProcessRunnerError = JSONRPCProcessRunner.Error
