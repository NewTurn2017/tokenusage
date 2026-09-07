import Darwin
import Foundation
import XCTest
@testable import TokenUsageCore

final class JSONRPCProcessRunnerTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private let python = URL(fileURLWithPath: "/usr/bin/python3")

    func testSendsInitializeNotificationAndRequestAndMatchesRequestID() async throws {
        let capture = try TemporaryPath()
        let pidPath = try TemporaryPath()
        defer {
            capture.remove()
            pidPath.remove()
        }

        let request = Data(#"{"jsonrpc":"2.0","id":42,"method":"usage/read","params":{}}"#.utf8)
        let script = """
        set -eu
        printf '%s' "$$" > "$PID_PATH"
        IFS= read -r initialize
        printf '%s\\n' "$initialize" >> "$CAPTURE"
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"ready":true}}'
        IFS= read -r initialized
        printf '%s\\n' "$initialized" >> "$CAPTURE"
        IFS= read -r request
        printf '%s\\n' "$request" >> "$CAPTURE"
        printf '%s\\n' '{"jsonrpc":"2.0","id":42,"result":{"usage":7}}'
        """

        let result = try await runner().run(
            executable: shell,
            arguments: ["-c", script],
            environment: ["CAPTURE": capture.path, "PID_PATH": pidPath.path],
            request: request
        )

        XCTAssertEqual(String(decoding: result, as: UTF8.self), #"{"jsonrpc":"2.0","id":42,"result":{"usage":7}}"#)
        assertProcessAbsent(try processID(at: pidPath.path))
        let lines = try String(contentsOfFile: capture.path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains(#""method":"initialize"#))
        XCTAssertTrue(lines[0].contains(#""id":1"#))
        XCTAssertTrue(lines[1].contains(#""method":"initialized"#))
        XCTAssertFalse(lines[1].contains(#""id"#))
        XCTAssertEqual(String(lines[2]), String(decoding: request, as: UTF8.self))
    }

    func testIgnoresCodexNotificationWithoutJSONRPCVersion() async throws {
        let script = """
        IFS= read -r initialize
        printf '%s\\n' '{"id":1,"result":{"ready":true}}'
        printf '%s\\n' '{"emittedAtMs":1,"method":"remoteControl/status/changed","params":{"status":"idle"}}'
        IFS= read -r initialized
        IFS= read -r request
        printf '%s\\n' '{"id":42,"result":{"usage":7}}'
        """

        let result = try await runner().run(
            executable: shell,
            arguments: ["-c", script],
            environment: [:],
            request: request(id: 42)
        )

        XCTAssertEqual(String(decoding: result, as: UTF8.self), #"{"id":42,"result":{"usage":7}}"#)
    }

    func testKeepsInputOpenUntilMatchingResponse() async throws {
        let script = """
        import json
        import select
        import sys

        sys.stdin.readline()
        print(json.dumps({"id": 1, "result": {"ready": True}}), flush=True)
        sys.stdin.readline()
        sys.stdin.readline()
        print(json.dumps({"method": "server/request-consumed", "params": {}}), flush=True)
        if select.select([sys.stdin], [], [], 0)[0]:
            sys.exit(0)
        print(json.dumps({"id": 42, "result": {"usage": 7}}), flush=True)
        """

        let result = try await runner().run(
            executable: python,
            arguments: ["-c", script],
            environment: [:],
            request: request(id: 42)
        )

        XCTAssertEqual(String(decoding: result, as: UTF8.self), #"{"id": 42, "result": {"usage": 7}}"#)
    }

    func testMalformedResponseFails() async throws {
        let script = "printf '%s\\n' 'not-json'"

        do {
            _ = try await runner().run(
                executable: shell,
                arguments: ["-c", script],
                environment: [:],
                request: request(id: 42)
            )
            XCTFail("expected malformed response")
        } catch let error as JSONRPCProcessRunner.Error {
            guard case .malformedResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testWrongResponseIDFailsAfterEOF() async throws {
        let script = """
        IFS= read -r initialize
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r request
        printf '%s\\n' '{"jsonrpc":"2.0","id":999,"result":{}}'
        """

        do {
            _ = try await runner().run(
                executable: shell,
                arguments: ["-c", script],
                environment: [:],
                request: request(id: 42)
            )
            XCTFail("expected no matching response")
        } catch let error as JSONRPCProcessRunner.Error {
            guard case let .noMatchingResponse(expectedID, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expectedID, "42")
        }
    }

    func testTimeoutTerminatesAndReaps() async throws {
        let signal = try FIFOPath()
        let pidPath = try TemporaryPath()
        defer {
            signal.remove()
            pidPath.remove()
        }
        let ready = signal.readinessWaiter(deadline: .now() + .seconds(2))
        let script = """
        printf '%s' "$$" > "$PID_PATH"
        printf '%s' ready > "$READY_PATH"
        trap '' TERM
        exec /usr/bin/tail -f /dev/null
        """
        let child = shell
        let invocation = runner(timeout: .seconds(1), grace: .milliseconds(10))
        let environment = ["PID_PATH": pidPath.path, "READY_PATH": signal.path]
        let request = request(id: 42)
        let task = Task {
            do {
                return Result<Data, Swift.Error>.success(try await invocation.run(
                    executable: child,
                    arguments: ["-c", script],
                    environment: environment,
                    request: request
                ))
            } catch {
                return Result<Data, Swift.Error>.failure(error)
            }
        }

        guard await ready.value else {
            task.cancel()
            _ = await task.value
            return XCTFail("child did not signal readiness")
        }
        let result = await task.value
        guard case let .failure(error as JSONRPCProcessRunner.Error) = result,
              case .timedOut = error else {
            return XCTFail("expected timeout, got \(result)")
        }
        assertProcessAbsent(try processID(at: pidPath.path))
    }

    func testCancellationEscalatesAndReapsIgnoringChild() async throws {
        let signal = try FIFOPath()
        let pidPath = try TemporaryPath()
        defer {
            signal.remove()
            pidPath.remove()
        }
        let ready = signal.readinessWaiter(deadline: .now() + .seconds(2))
        let script = """
        printf '%s' "$$" > "$PID_PATH"
        printf '%s' ready > "$READY_PATH"
        trap '' TERM
        exec /usr/bin/tail -f /dev/null
        """
        let child = shell
        let invocation = runner(timeout: .seconds(5), grace: .milliseconds(10))
        let environment = ["PID_PATH": pidPath.path, "READY_PATH": signal.path]
        let request = request(id: 42)
        let task = Task {
            do {
                return Result<Data, Swift.Error>.success(try await invocation.run(
                    executable: child,
                    arguments: ["-c", script],
                    environment: environment,
                    request: request
                ))
            } catch {
                return Result<Data, Swift.Error>.failure(error)
            }
        }

        guard await ready.value else {
            task.cancel()
            _ = await task.value
            return XCTFail("child did not signal readiness")
        }
        task.cancel()
        let result = await task.value
        guard case let .failure(error) = result else {
            return XCTFail("expected cancellation")
        }
        XCTAssertTrue(error is CancellationError)
        assertProcessAbsent(try processID(at: pidPath.path))
    }

    func testUnexpectedEOFFails() async throws {
        do {
            _ = try await runner().run(
                executable: shell,
                arguments: ["-c", "exit 0"],
                environment: [:],
                request: request(id: 42)
            )
            XCTFail("expected EOF")
        } catch let error as JSONRPCProcessRunner.Error {
            guard case .unexpectedEOF = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testStderrIsSanitized() async throws {
        let environmentSecret = "environment-secret-7f9a"
        let requestSecret = "request-secret-2e4b"
        let script = "printf 'token=%s request=%s\\n' \"$TOKEN\" \"\(requestSecret)\" >&2; exit 0"
        let request = Data("{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"usage/read\",\"token\":\"\(requestSecret)\"}".utf8)

        do {
            _ = try await runner().run(
                executable: shell,
                arguments: ["-c", script],
                environment: ["TOKEN": environmentSecret],
                request: request
            )
            XCTFail("expected process failure")
        } catch {
            let description = String(describing: error)
            XCTAssertFalse(description.contains(environmentSecret))
            XCTAssertFalse(description.contains(requestSecret))
            XCTAssertTrue(description.contains("[REDACTED]"))
        }
    }

    private func request(id: Int) -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"usage/read\",\"params\":{}}".utf8)
    }

    private func runner(
        timeout: Duration = .seconds(2),
        grace: Duration = .milliseconds(50)
    ) -> JSONRPCProcessRunner {
        JSONRPCProcessRunner(timeout: timeout, terminationGracePeriod: grace)
    }

    private func processID(at path: String) throws -> Int32 {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int32(contents))
    }

    private func assertProcessAbsent(
        _ processID: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(kill(processID, 0), -1, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }
}

private final class TemporaryPath: @unchecked Sendable {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenusage-\(UUID().uuidString)")
            .path
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private final class FIFOPath: @unchecked Sendable {
    let path: String
    private let fileDescriptor: Int32
    private let readiness = DispatchSemaphore(value: 0)
    private let source: DispatchSourceFileSystemObject
    private let lock = NSLock()
    private var removed = false

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenusage-\(UUID().uuidString)")
            .path
        guard mkfifo(path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        fileDescriptor = open(path, O_RDONLY | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            try? FileManager.default.removeItem(atPath: path)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler { [readiness] in
            readiness.signal()
        }
        source.resume()
    }

    func readinessWaiter(deadline: DispatchTime) -> Task<Bool, Never> {
        let readiness = readiness
        return Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: readiness.wait(timeout: deadline) == .success)
                }
            }
        }
    }

    func remove() {
        let shouldRemove = lock.withLock {
            guard !removed else { return false }
            removed = true
            return true
        }
        guard shouldRemove else { return }
        source.cancel()
        close(fileDescriptor)
        try? FileManager.default.removeItem(atPath: path)
    }

    deinit {
        remove()
    }
}
