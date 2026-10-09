import Foundation
import XCTest
@testable import TokenUsageApp
import TokenUsageCore

final class MobileUsageServerTests: XCTestCase {
    private let key = "k3y-with-enough-entropy-for-tests-000000"
    private let baseURL = URL(string: "http://100.101.102.103:8787")!

    func testParsesTheRequestLineQueryAndAuthorizationHeader() throws {
        let request = try XCTUnwrap(MobileUsageRequest.parse(Data(
            "GET /usage.json?k=abc%2Bdef&k=second HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer token\r\n\r\n".utf8
        )))

        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/usage.json")
        XCTAssertEqual(request.query["k"], "abc+def", "the first value wins")
        XCTAssertEqual(request.authorization, "Bearer token")
    }

    func testIncompleteOrNonHTTPHeadsAreNotParsed() {
        XCTAssertNil(MobileUsageRequest.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)))
        XCTAssertNil(MobileUsageRequest.parse(Data("GET / SPDY/3\r\n\r\n".utf8)))
        XCTAssertNil(MobileUsageRequest.parse(Data("GET http://evil/ HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(MobileUsageRequest.parse(Data("hello\r\n\r\n".utf8)))
    }

    func testEveryRouteRequiresTheKey() async {
        let router = makeRouter()

        for path in ["/", "/usage.json", "/widget.js"] {
            let missing = await router.response(for: request(path))
            let wrong = await router.response(for: request(path, query: ["k": key + "x"]))
            let wrongBearer = await router.response(for: request(path, authorization: "Bearer nope"))
            XCTAssertEqual(missing.status, 401, path)
            XCTAssertEqual(wrong.status, 401, path)
            XCTAssertEqual(wrongBearer.status, 401, path)
        }
    }

    func testTheKeyUnlocksThePageJSONAndWidget() async throws {
        let router = makeRouter()

        let page = await router.response(for: request("/", query: ["k": key]))
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.contentType, "text/html; charset=utf-8")
        XCTAssertFalse(String(decoding: page.body, as: UTF8.self).contains(key), "the page never embeds the key")

        let json = await router.response(for: request("/usage.json", authorization: "Bearer \(key)"))
        XCTAssertEqual(json.status, 200)
        XCTAssertEqual(String(decoding: json.body, as: UTF8.self), #"{"ok":true}"#)

        let widget = await router.response(for: request("/widget.js", query: ["k": key]))
        let source = String(decoding: widget.body, as: UTF8.self)
        XCTAssertEqual(widget.status, 200)
        XCTAssertTrue(source.contains(#"const ENDPOINT = "http:\/\/100.101.102.103:8787\/usage.json";"#), source)
        XCTAssertTrue(source.contains("const KEY = \"\(key)\";"))
        XCTAssertFalse(source.contains("__"), "every placeholder is filled")
    }

    func testOtherMethodsAndPathsAreRejected() async {
        let router = makeRouter()

        let post = await router.response(for: request("/usage.json", method: "POST", query: ["k": key]))
        let unknown = await router.response(for: request("/secrets", query: ["k": key]))
        XCTAssertEqual(post.status, 405)
        XCTAssertEqual(unknown.status, 404)
    }

    func testResponsesForbidCachingAndReferrers() {
        let head = String(decoding: MobileUsageResponse.text(200, "hi").serialized(), as: UTF8.self)

        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(head.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(head.contains("Referrer-Policy: no-referrer\r\n"))
        XCTAssertTrue(head.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(head.hasSuffix("\r\n\r\nhi"))
    }

    func testOnlyTheCGNATRangeCountsAsTailscale() {
        XCTAssertTrue(TailscaleAddress.isTailscale("100.64.0.1"))
        XCTAssertTrue(TailscaleAddress.isTailscale("100.115.102.6"))
        XCTAssertTrue(TailscaleAddress.isTailscale("100.127.255.254"))
        XCTAssertFalse(TailscaleAddress.isTailscale("100.63.0.1"))
        XCTAssertFalse(TailscaleAddress.isTailscale("100.128.0.1"))
        XCTAssertFalse(TailscaleAddress.isTailscale("192.168.0.10"))
        XCTAssertFalse(TailscaleAddress.isTailscale("fd7a:115c:a1e0::1"))
    }

    func testTheAccessKeyIsCreatedOnceReusedAndOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("TokenUsage/mobile-access-key")

        let first = try MobileAccessKey.loadOrCreate(fileURL: file)
        let second = try MobileAccessKey.loadOrCreate(fileURL: file)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]

        XCTAssertEqual(first, second)
        XCTAssertEqual((permissions as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(first.count, 32)
        XCTAssertNil(first.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")), "URL-safe")
        XCTAssertNotEqual(MobileAccessKey.generate(), MobileAccessKey.generate())
    }

    func testTheServerAnswersOverARealSocket() async throws {
        let server = try MobileUsageServer(host: "127.0.0.1", port: 18787, router: makeRouter())
        server.start {}
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:18787/usage.json")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ok":true}"#)

        let (_, denied) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:18787/usage.json")!
        )
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 401)
    }

    @MainActor
    func testTheDocumentCarriesUsageButNoAccountIdentity() throws {
        let model = AppViewModel(coordinator: MobileNoopCoordinator(), profileActions: MobileNoopActions())
        model.apply(.current(AppUsageSnapshot(
            claude: .unavailable(message: ""),
            codexUsage: [],
            codexProfiles: [],
            activeCodexProfileID: nil,
            openRouter: .notConfigured(message: ""),
            removedCodexProfileNames: [],
            claudeUsage: [
                ClaudeProfileUsage(profileID: "claude-1", state: .fresh(UsageSnapshot(
                    capturedAt: Date(timeIntervalSince1970: 1_787_000_000),
                    fiveHour: QuotaWindow(remainingPercent: 99, resetsAt: nil),
                    weekly: QuotaWindow(remainingPercent: 2, resetsAt: nil),
                    rateLimitResetCreditsAvailableCount: 1
                ))),
            ],
            claudeProfiles: [
                ClaudeProfileMetadata(id: "claude-1", name: "personal", emailAddress: "me@example.com"),
            ],
            activeClaudeProfileID: "claude-1"
        )))

        let document = model.mobileUsageDocument()
        let json = String(decoding: try document.jsonData(), as: UTF8.self)

        XCTAssertEqual(document.claude.map(\.name), ["personal"])
        XCTAssertEqual(document.claude.first?.fiveHour.percent, 99)
        XCTAssertEqual(document.claude.first?.weekly.percent, 2)
        XCTAssertEqual(document.claude.first?.coupon?.text, "쿠폰 1개")
        XCTAssertEqual(document.refreshedAt, Date(timeIntervalSince1970: 1_787_000_000))
        XCTAssertNil(document.openRouter, "an unconfigured provider is left out")
        XCTAssertFalse(json.contains("example.com"), json)
        XCTAssertFalse(json.contains("claude-1"), json)
    }

    @MainActor
    func testATeamAccountSendsItsFableLimitAndAnExplicitNullWeekly() throws {
        let model = AppViewModel(coordinator: MobileNoopCoordinator(), profileActions: MobileNoopActions())
        model.apply(.current(AppUsageSnapshot(
            claude: .unavailable(message: ""),
            codexUsage: [],
            codexProfiles: [],
            activeCodexProfileID: nil,
            openRouter: .notConfigured(message: ""),
            removedCodexProfileNames: [],
            claudeUsage: [
                ClaudeProfileUsage(profileID: "max", state: .fresh(UsageSnapshot(
                    capturedAt: Date(timeIntervalSince1970: 1_787_000_000),
                    fiveHour: QuotaWindow(remainingPercent: 96, resetsAt: nil),
                    weekly: QuotaWindow(remainingPercent: 54, resetsAt: nil),
                    fableWeekly: QuotaWindow(remainingPercent: 70, resetsAt: nil)
                ))),
                ClaudeProfileUsage(profileID: "team", state: .fresh(UsageSnapshot(
                    capturedAt: Date(timeIntervalSince1970: 1_787_000_000),
                    fiveHour: QuotaWindow(remainingPercent: 68, resetsAt: nil),
                    fableWeekly: QuotaWindow(remainingPercent: 61, resetsAt: nil)
                ))),
            ],
            claudeProfiles: [
                ClaudeProfileMetadata(id: "max", name: "claude-2020"),
                ClaudeProfileMetadata(id: "team", name: "claude1"),
            ],
            activeClaudeProfileID: "team"
        )))

        let document = model.mobileUsageDocument()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try document.jsonData()) as? [String: Any]
        )
        let accounts = try XCTUnwrap(object["claude"] as? [[String: Any]])
        let team = accounts[1]
        let weekly = try XCTUnwrap(team["weekly"] as? [String: Any])

        XCTAssertEqual(document.claude.map { $0.windows.map(\.label) }, [
            ["5시간", "주간", "Fable"],
            ["5시간", "Fable"],
        ])
        XCTAssertEqual(document.claude.map { $0.fable?.percent }, [70, 61])
        // The page used to print "undefined%" because a nil percent dropped the key entirely.
        XCTAssertTrue(weekly.keys.contains("percent"))
        XCTAssertTrue(weekly["percent"] is NSNull)
        XCTAssertNil(object["fableWeekly"], "Fable now travels with each account")

        if let directory = ProcessInfo.processInfo.environment["TOKEN_USAGE_MOBILE_QA_DIRECTORY"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try document.jsonData().write(to: output.appendingPathComponent("usage.json"))
            try Data(MobileUsagePages.html.utf8).write(to: output.appendingPathComponent("index.html"))
        }
    }

    func testThePageAndWidgetTreatAMissingPercentAsUnknown() throws {
        let page = MobileUsagePages.html
        let widget = MobileUsagePages.widget(baseURL: baseURL, accessKey: key)

        XCTAssertFalse(page.contains("percent === null"), "undefined must not slip past the check")
        XCTAssertTrue(page.contains("a.windows ||"), "accounts draw the windows they report")
        XCTAssertTrue(widget.contains("claude.windows[1]"), "the widget follows the weekly slot")
    }

    private func makeRouter() -> MobileUsageRouter {
        MobileUsageRouter(accessKey: key, baseURL: baseURL) { Data(#"{"ok":true}"#.utf8) }
    }

    private func request(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        authorization: String? = nil
    ) -> MobileUsageRequest {
        MobileUsageRequest(method: method, path: path, query: query, authorization: authorization)
    }
}

private actor MobileNoopCoordinator: AppUsageCoordinating {
    func start() async {}
    func stateChanges() async -> AsyncStream<RefreshState<AppUsageSnapshot>> { AsyncStream { _ in } }
    func requestRefresh() async {}
    func performProfileOperation(
        _ operation: @escaping @Sendable () async throws -> AppUsageSnapshot
    ) async throws -> AppUsageSnapshot { try await operation() }
    func stop() async {}
}

private actor MobileNoopActions: CodexProfileActionHandling {
    func selectProfile(id: String) async throws -> AppUsageSnapshot { fatalError() }
    func saveCurrentProfile(named name: String) async throws -> AppUsageSnapshot { fatalError() }
    func addAccount(named name: String) async throws -> AppUsageSnapshot { fatalError() }
    func deleteProfile(id: String) async throws -> AppUsageSnapshot { fatalError() }
}
