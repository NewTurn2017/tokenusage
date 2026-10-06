import Darwin
import Foundation
import XCTest
@testable import TokenUsageCore

final class CodexAppServerClientTests: XCTestCase {
    func testBaselineUsageAndValidationDecodeResponsesAndReapFixtureChildren() async throws {
        let usageFixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1776038400},"secondary":null}}}
        """)
        defer { usageFixture.remove() }

        let usage = try await client(for: usageFixture).usage()

        XCTAssertEqual(usage.weekly, QuotaWindow(
            remainingPercent: 88,
            resetsAt: Date(timeIntervalSince1970: 1_776_038_400),
            windowDuration: QuotaWindowKind.weekly.duration
        ))
        let usageReaped = assertProcessAbsent(try usageFixture.processID())

        let validationFixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"baseline@example.test","planType":"pro"},"requiresOpenaiAuth":true}}
        """)
        defer { validationFixture.remove() }
        validationFixture.rateLimitsResponse = """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1776038400},"secondary":null}}}
        """

        let account = try await client(for: validationFixture).validate(
            authData: Data(#"{"fixture":true}"#.utf8)
        )

        XCTAssertEqual(account, CodexAccount(
            type: "chatgpt",
            email: "baseline@example.test",
            planType: "pro"
        ))
        let validationReaped = assertProcessAbsent(try validationFixture.processID())
        print("TASK2_BASELINE weekly_remaining=88 account_type=chatgpt usage_reaped=\(usageReaped) validation_reaped=\(validationReaped)")
    }

    func testRateLimitsReadReturnsAuthoritativeResetCouponCount() async throws {
        let fixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":null,"secondary":null},"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"capped-detail"}]}}}
        """)
        defer { fixture.remove() }

        let snapshot = try await client(for: fixture).usage()

        XCTAssertEqual(snapshot.rateLimitResetCreditsAvailableCount, 3)
        try assertProtocolCapture(fixture, method: "account/rateLimits/read")
        assertProcessAbsent(try fixture.processID())
    }

    func testReadsWeeklyPrimaryAfterVersionedInitializeAndMatchingResponseID() async throws {
        let fixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":16,"windowDurationMins":10080,"resetsAt":1776038400},"secondary":{"usedPercent":90,"windowDurationMins":300,"resetsAt":1775500000}}}}
        """)
        defer { fixture.remove() }
        fixture.versionOutput = "codex-cli 0.146.0"
        fixture.extraResponse = #"{"jsonrpc":"2.0","id":72,"result":{"ignored":true}}"#
        fixture.keepAlive = true

        let snapshot = try await client(for: fixture).usage()

        XCTAssertEqual(snapshot.capturedAt, Date(timeIntervalSince1970: 1_700_000_008))
        XCTAssertEqual(snapshot.weekly, QuotaWindow(
            remainingPercent: 84,
            resetsAt: Date(timeIntervalSince1970: 1_776_038_400),
            windowDuration: QuotaWindowKind.weekly.duration
        ))
        try assertProtocolCapture(fixture, method: "account/rateLimits/read")
        assertProcessAbsent(try fixture.processID())
    }

    func testHomeSpecificUsageKeepsConcurrentReadsIsolated() async throws {
        let firstFixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":21,"windowDurationMins":10080,"resetsAt":1776038400},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"125.5"}}}}
        """)
        let secondFixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":64,"windowDurationMins":10080,"resetsAt":1776038500},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"}}}}
        """)
        defer {
            firstFixture.remove()
            secondFixture.remove()
        }
        let firstHome = firstFixture.root.appendingPathComponent("profile-home", isDirectory: true)
        let secondHome = secondFixture.root.appendingPathComponent("profile-home", isDirectory: true)
        try FileManager.default.createDirectory(at: firstHome, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondHome, withIntermediateDirectories: false)

        let firstClient = client(for: firstFixture)
        let secondClient = client(for: secondFixture)
        async let first = firstClient.usage(codexHome: firstHome)
        async let second = secondClient.usage(codexHome: secondHome)
        let (firstUsage, secondUsage) = try await (first, second)

        XCTAssertEqual(firstUsage.weekly?.remainingPercent, 79)
        XCTAssertEqual(secondUsage.weekly?.remainingPercent, 36)
        XCTAssertEqual(firstUsage.codexCredits?.balance, 125.5)
        XCTAssertEqual(secondUsage.codexCredits?.balance, 0)
        XCTAssertEqual(try firstFixture.capturedCodexHomes(), [firstHome.path])
        XCTAssertEqual(try secondFixture.capturedCodexHomes(), [secondHome.path])
        let firstReaped = assertProcessAbsent(try firstFixture.processID())
        let secondReaped = assertProcessAbsent(try secondFixture.processID())
        print("TASK2_HOME first=\(firstHome.path) second=\(secondHome.path) first_weekly=79 second_weekly=36 first_reaped=\(firstReaped) second_reaped=\(secondReaped)")
    }

    func testReadsWeeklySecondary() async throws {
        let fixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":300,"resetsAt":1775500000},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":null}}}}
        """)
        defer { fixture.remove() }

        let snapshot = try await client(for: fixture).usage()

        XCTAssertEqual(
            snapshot.weekly,
            QuotaWindow(
                remainingPercent: 0,
                resetsAt: nil,
                windowDuration: QuotaWindowKind.weekly.duration
            )
        )
        assertProcessAbsent(try fixture.processID())
    }

    func testPrefersCodexWeeklyWindowInMultiLimitMap() async throws {
        let fixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":null,"secondary":null},"rateLimitsByLimitId":{"alpha":{"primary":{"usedPercent":99,"windowDurationMins":10080,"resetsAt":1770000000}},"codex":{"primary":{"usedPercent":8,"windowDurationMins":300,"resetsAt":1771000000},"secondary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1772000000}}}}}
        """)
        defer { fixture.remove() }

        let snapshot = try await client(for: fixture).usage()

        XCTAssertEqual(snapshot.weekly, QuotaWindow(
            remainingPercent: 75,
            resetsAt: Date(timeIntervalSince1970: 1_772_000_000),
            windowDuration: QuotaWindowKind.weekly.duration
        ))
    }

    func testOnly300MinuteWindowLeavesWeeklyUnavailable() async throws {
        let fixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":16,"windowDurationMins":300,"resetsAt":1775500000},"secondary":null}}}
        """)
        defer { fixture.remove() }

        let snapshot = try await client(for: fixture).usage()

        XCTAssertNil(snapshot.weekly)
        XCTAssertNil(snapshot.fiveHour)
    }

    func testMethodErrorIsTypedAndDoesNotExposeServerMessage() async throws {
        let secret = "server-secret-sentinel"
        let fixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"method missing \(secret)"}}
        """)
        defer { fixture.remove() }

        do {
            _ = try await client(for: fixture).usage()
            XCTFail("expected method error")
        } catch let error as CodexAppServerClient.Error {
            XCTAssertEqual(error, .methodFailed(code: -32601))
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
        assertProcessAbsent(try fixture.processID())
    }

    func testMalformedResponseIsTypedAndReapsFixtureChild() async throws {
        let fixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":[]}
        """)
        defer { fixture.remove() }

        do {
            _ = try await client(for: fixture).usage()
            XCTFail("expected malformed response")
        } catch let error as CodexAppServerClient.Error {
            XCTAssertEqual(error, .malformedResponse)
        }
        let reaped = assertProcessAbsent(try fixture.processID())
        print("TASK2_MALFORMED typed=malformedResponse child_reaped=\(reaped)")
    }

    func testProcessFailureIsTypedAndReapsFixtureChild() async throws {
        let fixture = try CodexAppServerFixture(response: "")
        defer { fixture.remove() }
        fixture.omitResponse = true

        do {
            _ = try await client(for: fixture).usage()
            XCTFail("expected process failure")
        } catch let error as CodexAppServerClient.Error {
            XCTAssertEqual(error, .processFailed)
        }
        let reaped = assertProcessAbsent(try fixture.processID())
        print("TASK2_PROCESS_FAILURE typed=processFailed child_reaped=\(reaped)")
    }

    func testValidationRequiresAccountAndRateLimitsReadsInSamePrivateTemporaryCodexHomeAndRemovesIt() async throws {
        let fixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"person@example.test","planType":"pro"},"requiresOpenaiAuth":true}}
        """)
        defer { fixture.remove() }
        fixture.rateLimitsResponse = """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":16,"windowDurationMins":10080,"resetsAt":1776038400},"secondary":null}}}
        """
        fixture.verifyAuthFile = true
        let authData = Data(#"{"fixture":true}"#.utf8)

        let account = try await client(for: fixture).validate(authData: authData)

        XCTAssertEqual(account, CodexAccount(
            type: "chatgpt",
            email: "person@example.test",
            planType: "pro"
        ))
        try assertValidationProtocolCapture(fixture)
        let request = try XCTUnwrap(
            fixture.capturedMessages().first { $0["method"] as? String == "account/read" }
        )
        let parameters = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(parameters["refreshToken"] as? Bool, false)
        XCTAssertEqual(try fixture.authMode(), "600")
        let homes = try fixture.capturedCodexHomes()
        XCTAssertEqual(homes.count, 2)
        let isolatedHome = try XCTUnwrap(homes.first)
        XCTAssertEqual(Set(homes), [isolatedHome])
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolatedHome))
        assertProcessAbsent(try fixture.processID())
    }

    func testAccountReadAcceptsCodexResponseWithoutJSONRPCVersion() async throws {
        let fixture = try CodexAppServerFixture(response: """
        {"id":2,"result":{"account":{"type":"chatgpt","email":null,"planType":"pro"},"requiresOpenaiAuth":true}}
        """)
        defer { fixture.remove() }

        let account = try await client(for: fixture).validate(
            authData: Data(#"{"fixture":true}"#.utf8)
        )

        XCTAssertEqual(account, CodexAccount(type: "chatgpt", email: nil, planType: "pro"))
    }

    func testValidationRejectsAccountReadFailureBeforeRateLimitsRead() async throws {
        let fixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"account":null,"requiresOpenaiAuth":true}}
        """)
        defer { fixture.remove() }
        fixture.rateLimitsResponse = """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":null,"secondary":null}}}
        """

        do {
            _ = try await client(for: fixture).validate(authData: Data(#"{"fixture":true}"#.utf8))
            XCTFail("expected authentication failure")
        } catch let error as CodexAppServerClient.Error {
            XCTAssertEqual(error, .notAuthenticated)
        }
        XCTAssertEqual(try fixture.capturedMethods(), ["initialize", "initialized", "account/read"])
    }

    func testValidationRejectsRateLimitsFailureInSameDefaultCodexHome() async throws {
        let fixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":null,"planType":"pro"},"requiresOpenaiAuth":true}}
        """)
        defer { fixture.remove() }
        fixture.rateLimitsResponse = """
        {"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"quota unavailable"}}
        """
        let defaultHome = fixture.root.appendingPathComponent("default-home", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: false)

        do {
            _ = try await client(for: fixture).validate(codexHome: defaultHome)
            XCTFail("expected rate-limits failure")
        } catch let error as CodexAppServerClient.Error {
            XCTAssertEqual(error, .methodFailed(code: -32000))
        }

        try assertValidationProtocolCapture(fixture)
        XCTAssertEqual(try fixture.capturedCodexHomes(), [defaultHome.path, defaultHome.path])
    }

    func testCancellationTerminatesAndReapsAppServer() async throws {
        let ready = try CodexFIFOPath()
        let fixture = try CodexAppServerFixture(response: "")
        defer {
            ready.remove()
            fixture.remove()
        }
        fixture.readyPath = ready.path
        fixture.omitResponse = true
        fixture.keepAlive = true
        let readiness = ready.waiter(deadline: .now() + .seconds(2))
        let client = client(for: fixture, timeout: .seconds(5))
        let task = Task {
            try await client.usage()
        }

        guard await readiness.value else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("fixture did not receive the quota request")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        assertProcessAbsent(try fixture.processID())
    }

    func testResolverPrefersInjectedExecutableOverEnvironmentOverrideAndPath() throws {
        let fixture = try CodexResolverFixture()
        defer { fixture.remove() }
        let injected = try fixture.makeExecutable(at: "injected/codex")
        let environmentOverride = try fixture.makeExecutable(at: "override/codex")
        let pathExecutable = try fixture.makeExecutable(at: "path/codex")
        let resolver = InstalledCodexExecutableResolver(explicitExecutableURL: injected)

        let resolved = try resolver.resolve(environment: [
            "TOKENUSAGE_CODEX_PATH": environmentOverride.path,
            "PATH": pathExecutable.deletingLastPathComponent().path,
        ])

        XCTAssertEqual(resolved.path, injected.path)
        print("TASK2_RESOLVER injected_candidate=\(resolved.path)")
    }

    func testResolvedCodexExecutableDirectoryIsPrependedOnlyOnce() throws {
        let fixture = try CodexResolverFixture()
        defer { fixture.remove() }
        let executable = try fixture.makeExecutable(at: "fnm/bin/codex")
        let executableDirectory = executable.deletingLastPathComponent().standardizedFileURL.path
        let otherDirectory = fixture.root.appendingPathComponent("other/bin", isDirectory: true).path
        let originalEnvironment = [
            "PATH": [otherDirectory, executableDirectory, executableDirectory, otherDirectory]
                .joined(separator: ":"),
            "CODEX_HOME": fixture.root.appendingPathComponent("home", isDirectory: true).path,
        ]
        let resolver = InstalledCodexExecutableResolver(explicitExecutableURL: executable)

        let resolution = try resolver.resolveProcess(environment: originalEnvironment)

        let path = try XCTUnwrap(resolution.environment["PATH"])
            .split(separator: ":")
            .map(String.init)
        XCTAssertEqual(resolution.executable, executable)
        XCTAssertEqual(path.first, executableDirectory)
        XCTAssertEqual(path.filter { $0 == executableDirectory }.count, 1)
        XCTAssertEqual(path, [executableDirectory, otherDirectory, otherDirectory])
        XCTAssertEqual(originalEnvironment["PATH"], [otherDirectory, executableDirectory, executableDirectory, otherDirectory].joined(separator: ":"))

        let emptyPathResolution = try resolver.resolveProcess(environment: ["PATH": ""])
        XCTAssertEqual(emptyPathResolution.environment["PATH"], executableDirectory)

        let missingPathResolution = try resolver.resolveProcess(environment: [:])
        XCTAssertEqual(missingPathResolution.environment["PATH"], executableDirectory)
    }

    func testAppServerReceivesResolvedExecutableDirectoryInChildPATH() async throws {
        let fixture = try CodexResolverFixture()
        defer { fixture.remove() }
        let executable = try fixture.makeExecutable(at: "fnm/bin/codex")
        let codexHome = fixture.root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
        let environment = [
            "PATH": "",
            "HOME": fixture.root.appendingPathComponent("home", isDirectory: true).path,
        ]
        let recorder = JSONRPCEnvironmentRecorder()
        let client = CodexAppServerClient(
            runner: recorder,
            executableResolver: InstalledCodexExecutableResolver(explicitExecutableURL: executable),
            environment: environment,
            now: { Date(timeIntervalSince1970: 1_700_000_008) }
        )

        _ = try await client.usage(codexHome: codexHome)

        let childEnvironment = try XCTUnwrap(recorder.environment)
        XCTAssertEqual(
            childEnvironment["PATH"],
            executable.deletingLastPathComponent().standardizedFileURL.path
        )
        XCTAssertEqual(childEnvironment["CODEX_HOME"], codexHome.path)
        XCTAssertEqual(environment["PATH"], "")
    }

    func testResolverUsesDefaultFNMHomeAliasBeforeVersionInstallWhenPathIsEmpty() throws {
        let fixture = try CodexResolverFixture()
        defer { fixture.remove() }
        let alias = try fixture.makeExecutable(
            at: "home/.local/share/fnm/aliases/default/bin/codex"
        )
        _ = try fixture.makeExecutable(
            at: "home/.local/share/fnm/node-versions/v99.0.0/installation/bin/codex"
        )

        let resolved = try InstalledCodexExecutableResolver().resolve(environment: [
            "PATH": "",
            "HOME": fixture.root.appendingPathComponent("home", isDirectory: true).path,
        ])

        XCTAssertEqual(resolved.path, alias.path)
        print("TASK2_RESOLVER home_alias_candidate=\(resolved.path)")
    }

    func testResolverUsesEnvironmentOverrideBeforePath() throws {
        let fixture = try CodexResolverFixture()
        defer { fixture.remove() }
        let environmentOverride = try fixture.makeExecutable(at: "override/codex")
        let pathExecutable = try fixture.makeExecutable(at: "path/codex")

        let resolved = try InstalledCodexExecutableResolver(fallbackDirectories: []).resolve(
            environment: [
                "TOKENUSAGE_CODEX_PATH": environmentOverride.path,
                "PATH": pathExecutable.deletingLastPathComponent().path,
            ]
        )

        XCTAssertEqual(resolved.path, environmentOverride.path)
    }

    func testResolverUsesFNMDirectoryDefaultAliasBeforeAllVersionInstalls() throws {
        let fixture = try CodexResolverFixture()
        defer { fixture.remove() }
        let alias = try fixture.makeExecutable(at: "custom-fnm/aliases/default/bin/codex")
        _ = try fixture.makeExecutable(
            at: "custom-fnm/node-versions/v99.0.0/installation/bin/codex"
        )

        let resolved = try InstalledCodexExecutableResolver(fallbackDirectories: []).resolve(
            environment: [
                "PATH": "",
                "FNM_DIR": fixture.root.appendingPathComponent("custom-fnm", isDirectory: true).path,
            ]
        )

        XCTAssertEqual(resolved.path, alias.path)
    }

    func testResolverSearchesPathThenHomeBinsBeforeFNM() throws {
        let fixture = try CodexResolverFixture()
        defer { fixture.remove() }
        let pathExecutable = try fixture.makeExecutable(at: "path/codex")
        let homeExecutable = try fixture.makeExecutable(at: "home/.local/bin/codex")
        _ = try fixture.makeExecutable(at: "home/.local/share/fnm/aliases/default/bin/codex")
        let home = fixture.root.appendingPathComponent("home", isDirectory: true).path
        let resolver = InstalledCodexExecutableResolver(fallbackDirectories: [])

        XCTAssertEqual(try resolver.resolve(environment: [
            "PATH": pathExecutable.deletingLastPathComponent().path,
            "HOME": home,
        ]).path, pathExecutable.path)
        XCTAssertEqual(try resolver.resolve(environment: [
            "PATH": "",
            "HOME": home,
        ]).path, homeExecutable.path)
    }

    func testResolverUsesFNMDirectoryAndDescendingSemanticNodeVersions() throws {
        let fixture = try CodexResolverFixture()
        defer { fixture.remove() }
        let expected = try fixture.makeExecutable(
            at: "custom-fnm/node-versions/v24.10.0/installation/bin/codex"
        )
        _ = try fixture.makeExecutable(
            at: "custom-fnm/node-versions/v24.2.0/installation/bin/codex"
        )
        _ = try fixture.makeExecutable(
            at: "custom-fnm/node-versions/v23.99.0/installation/bin/codex"
        )
        _ = try fixture.makeExecutable(
            at: "custom-fnm/node-versions/not-semver/installation/bin/codex"
        )

        let resolved = try InstalledCodexExecutableResolver(fallbackDirectories: []).resolve(
            environment: [
                "PATH": "",
                "HOME": fixture.root.appendingPathComponent("empty-home", isDirectory: true).path,
                "FNM_DIR": fixture.root.appendingPathComponent("custom-fnm", isDirectory: true).path,
            ]
        )

        XCTAssertEqual(
            resolved.resolvingSymlinksInPath().path,
            expected.resolvingSymlinksInPath().path
        )
        print("TASK2_RESOLVER semantic_candidate=\(resolved.path)")
    }

    func testResolverInvalidExplicitOverrideFailsClosedWithoutPathFallback() throws {
        let fixture = try CodexResolverFixture()
        defer { fixture.remove() }
        let pathExecutable = try fixture.makeExecutable(at: "path/codex")
        let invalidOverride = fixture.root.appendingPathComponent("missing/codex", isDirectory: false)

        XCTAssertThrowsError(try InstalledCodexExecutableResolver(
            explicitExecutableURL: invalidOverride
        ).resolve(environment: [
            "PATH": pathExecutable.deletingLastPathComponent().path,
        ])) { error in
            XCTAssertEqual(error as? CodexAppServerClient.Error, .invalidExecutableOverride)
        }
    }

    func testResolverRejectsDirectoryAndNonExecutableEnvironmentOverrides() throws {
        let fixture = try CodexResolverFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("directory-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let nonExecutable = try fixture.makeFile(at: "non-executable-codex", permissions: 0o600)
        let pathExecutable = try fixture.makeExecutable(at: "path/codex")
        let resolver = InstalledCodexExecutableResolver(fallbackDirectories: [])

        for invalidPath in [directory.path, nonExecutable.path, ""] {
            XCTAssertThrowsError(try resolver.resolve(environment: [
                "TOKENUSAGE_CODEX_PATH": invalidPath,
                "PATH": pathExecutable.deletingLastPathComponent().path,
            ])) { error in
                XCTAssertEqual(error as? CodexAppServerClient.Error, .invalidExecutableOverride)
            }
        }
    }

    func testResolverDoesNotSourceConfiguredShellAndFailsWhenPathAndFNMAreMissing() throws {
        let fixture = try CodexResolverFixture()
        defer { fixture.remove() }
        let shellMarker = fixture.root.appendingPathComponent("shell-started", isDirectory: false)
        let fakeShell = try fixture.makeExecutable(
            at: "shell/zsh",
            script: "#!/bin/sh\nprintf started > \"$SHELL_MARKER\"\n"
        )

        XCTAssertThrowsError(try InstalledCodexExecutableResolver(fallbackDirectories: []).resolve(
            environment: [
                "PATH": "",
                "HOME": fixture.root.appendingPathComponent("empty-home", isDirectory: true).path,
                "FNM_DIR": fixture.root.appendingPathComponent("missing-fnm", isDirectory: true).path,
                "SHELL": fakeShell.path,
                "SHELL_MARKER": shellMarker.path,
            ]
        )) { error in
            XCTAssertEqual(error as? CodexAppServerClient.Error, .executableNotFound)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: shellMarker.path))
        print("TASK2_RESOLVER empty_path_missing_fnm=executableNotFound shell_started=false")
    }

    func testHomeSpecificUsageRejectsMissingAndNonDirectoryHomesBeforeProcessStart() async throws {
        let fixture = try CodexAppServerFixture(response: """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":null,"secondary":null}}}
        """)
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing-home", isDirectory: true)
        let regularFile = fixture.root.appendingPathComponent("not-a-home", isDirectory: false)
        try Data().write(to: regularFile)

        for invalidHome in [missing, regularFile] {
            do {
                _ = try await client(for: fixture).usage(codexHome: invalidHome)
                XCTFail("expected invalid Codex home")
            } catch let error as CodexAppServerClient.Error {
                XCTAssertEqual(error, .invalidCodexHome)
            }
        }
        XCTAssertFalse(fixture.didStartProcess)
        print("TASK2_CODEX_HOME invalid_home=invalidCodexHome process_started=false")
    }

    private func client(
        for fixture: CodexAppServerFixture,
        timeout: Duration = .seconds(2)
    ) -> CodexAppServerClient {
        CodexAppServerClient(
            runner: JSONRPCProcessRunner(
                timeout: timeout,
                terminationGracePeriod: .milliseconds(10)
            ),
            executableResolver: InstalledCodexExecutableResolver(),
            environment: fixture.environment,
            now: { Date(timeIntervalSince1970: 1_700_000_008) }
        )
    }

    private func assertProtocolCapture(
        _ fixture: CodexAppServerFixture,
        method: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let messages = try fixture.capturedMessages()
        XCTAssertEqual(messages.count, 3, file: file, line: line)
        assertProtocolMessages(messages, method: method, file: file, line: line)
    }

    private func assertValidationProtocolCapture(
        _ fixture: CodexAppServerFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let messages = try fixture.capturedMessages()
        XCTAssertEqual(messages.count, 6, file: file, line: line)
        guard messages.count == 6 else { return }
        assertProtocolMessages(Array(messages[0...2]), method: "account/read", file: file, line: line)
        assertProtocolMessages(
            Array(messages[3...5]),
            method: "account/rateLimits/read",
            file: file,
            line: line
        )
    }

    private func assertProtocolMessages(
        _ messages: [[String: Any]],
        method: String,
        file: StaticString,
        line: UInt
    ) {
        guard messages.count == 3 else { return }
        XCTAssertEqual(messages[0]["method"] as? String, "initialize", file: file, line: line)
        XCTAssertEqual((messages[0]["id"] as? NSNumber)?.intValue, 1, file: file, line: line)
        XCTAssertEqual(messages[1]["method"] as? String, "initialized", file: file, line: line)
        XCTAssertNil(messages[1]["id"], file: file, line: line)
        XCTAssertEqual(messages[2]["method"] as? String, method, file: file, line: line)
        XCTAssertEqual((messages[2]["id"] as? NSNumber)?.intValue, 2, file: file, line: line)
    }

    @discardableResult
    private func assertProcessAbsent(
        _ processID: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let result = kill(processID, 0)
        let capturedErrno = errno
        XCTAssertEqual(result, -1, file: file, line: line)
        XCTAssertEqual(capturedErrno, ESRCH, file: file, line: line)
        return result == -1 && capturedErrno == ESRCH
    }
}

private final class JSONRPCEnvironmentRecorder: JSONRPCProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEnvironment: [String: String]?

    var environment: [String: String]? { lock.withLock { recordedEnvironment } }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        request: Data
    ) async throws -> Data {
        lock.withLock { recordedEnvironment = environment }
        return Data(#"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1776038400},"secondary":null}}}"#.utf8)
    }
}

private final class CodexResolverFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsage-CodexResolverFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func makeExecutable(
        at relativePath: String,
        script: String = "#!/bin/sh\nexit 0\n"
    ) throws -> URL {
        try makeFile(at: relativePath, contents: Data(script.utf8), permissions: 0o700)
    }

    func makeFile(
        at relativePath: String,
        contents: Data = Data(),
        permissions: Int
    ) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class CodexAppServerFixture: @unchecked Sendable {
    let root: URL
    let executable: URL
    private let captureURL: URL
    private let pidURL: URL
    private let homeCaptureURL: URL
    private let authModeURL: URL
    private let response: String

    var versionOutput = ""
    var extraResponse = ""
    var rateLimitsResponse = ""
    var keepAlive = false
    var omitResponse = false
    var verifyAuthFile = false
    var readyPath = ""

    init(response: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsage-CodexFixture-\(UUID().uuidString)", isDirectory: true)
        executable = root.appendingPathComponent("codex", isDirectory: false)
        captureURL = root.appendingPathComponent("capture.jsonl", isDirectory: false)
        pidURL = root.appendingPathComponent("pid", isDirectory: false)
        homeCaptureURL = root.appendingPathComponent("codex-home", isDirectory: false)
        authModeURL = root.appendingPathComponent("auth-mode", isDirectory: false)
        self.response = response

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let script = """
        #!/bin/sh
        set -eu
        test "$1" = "app-server"
        test "$2" = "--stdio"
        printf '%s' "$$" > "$PID_PATH"
        if test -n "$VERSION_OUTPUT"; then
          printf '%s\\n' "$VERSION_OUTPUT" >&2
        fi
        IFS= read -r initialize
        printf '%s\\n' "$initialize" >> "$CAPTURE_PATH"
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"codex-app-server","version":"0.146.0"}}}'
        IFS= read -r initialized
        printf '%s\\n' "$initialized" >> "$CAPTURE_PATH"
        IFS= read -r request
        printf '%s\\n' "$request" >> "$CAPTURE_PATH"
        if test "$VERIFY_AUTH_FILE" = "1"; then
          test -s "$CODEX_HOME/auth.json"
          /usr/bin/stat -f '%Lp' "$CODEX_HOME/auth.json" > "$AUTH_MODE_PATH"
        fi
        if test -n "${CODEX_HOME:-}"; then
          printf '%s\\n' "$CODEX_HOME" >> "$HOME_CAPTURE_PATH"
        fi
        if test -n "$READY_PATH"; then
          printf 'ready' > "$READY_PATH"
        fi
        if test -n "$EXTRA_RESPONSE"; then
          printf '%s\\n' "$EXTRA_RESPONSE"
        fi
        if test "$OMIT_RESPONSE" != "1"; then
          if test -n "$RATE_LIMITS_RESPONSE" && printf '%s' "$request" | /usr/bin/grep -q 'account/rateLimits/read'; then
            printf '%s\\n' "$RATE_LIMITS_RESPONSE"
          else
            printf '%s\\n' "$RESPONSE"
          fi
        fi
        if test "$KEEP_ALIVE" = "1"; then
          trap '' TERM
          exec /usr/bin/tail -f /dev/null
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    var environment: [String: String] {
        [
            "PATH": root.path,
            "CAPTURE_PATH": captureURL.path,
            "PID_PATH": pidURL.path,
            "HOME_CAPTURE_PATH": homeCaptureURL.path,
            "AUTH_MODE_PATH": authModeURL.path,
            "RESPONSE": response,
            "VERSION_OUTPUT": versionOutput,
            "EXTRA_RESPONSE": extraResponse,
            "RATE_LIMITS_RESPONSE": rateLimitsResponse,
            "KEEP_ALIVE": keepAlive ? "1" : "0",
            "OMIT_RESPONSE": omitResponse ? "1" : "0",
            "VERIFY_AUTH_FILE": verifyAuthFile ? "1" : "0",
            "READY_PATH": readyPath,
        ]
    }

    func capturedMessages() throws -> [[String: Any]] {
        try String(contentsOf: captureURL, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
                return try XCTUnwrap(value as? [String: Any])
            }
    }

    func processID() throws -> Int32 {
        let text = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int32(text))
    }

    var didStartProcess: Bool {
        FileManager.default.fileExists(atPath: pidURL.path)
    }

    func capturedMethods() throws -> [String] {
        try capturedMessages().compactMap { $0["method"] as? String }
    }

    func capturedCodexHomes() throws -> [String] {
        try String(contentsOf: homeCaptureURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    func authMode() throws -> String {
        try String(contentsOf: authModeURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class CodexFIFOPath: @unchecked Sendable {
    let path: String
    private let fileDescriptor: Int32
    private let readiness = DispatchSemaphore(value: 0)
    private let source: DispatchSourceFileSystemObject
    private let lock = NSLock()
    private var removed = false

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsage-CodexReady-\(UUID().uuidString)")
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
        source.setEventHandler { [readiness] in readiness.signal() }
        source.resume()
    }

    func waiter(deadline: DispatchTime) -> Task<Bool, Never> {
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
