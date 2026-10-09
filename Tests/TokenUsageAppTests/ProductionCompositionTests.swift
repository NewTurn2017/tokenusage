import AppKit
import XCTest
@testable import TokenUsageApp
import TokenUsageCore

final class ProductionCompositionTests: XCTestCase {
    func testProductionCodexDependenciesDeriveInjectedApplicationSupportAndEnvironmentHomes() {
        let fixtureRoot = URL(fileURLWithPath: "/private/tmp/tokenusage-production-fixture", isDirectory: true)
        let applicationSupport = fixtureRoot.appendingPathComponent("Application Support", isDirectory: true)
        let home = fixtureRoot.appendingPathComponent("home", isDirectory: true)

        let dependencies = ProductionCodexDependencies(
            environment: ["HOME": home.path, "PATH": ""],
            applicationSupportDirectory: applicationSupport,
            browserOpener: { _ in XCTFail("Production composition opened a live browser"); return false }
        )

        XCTAssertEqual(
            dependencies.profileHomesRoot,
            applicationSupport.appendingPathComponent("TokenUsage/CodexProfiles", isDirectory: true)
        )
        XCTAssertEqual(
            dependencies.defaultCodexHome,
            home.appendingPathComponent(".codex", isDirectory: true)
        )
    }

    @MainActor
    func testTheClaudeAccountIsReadFromTheDefaultConfigEvenWhenLaunchedFromAProfileTerminal() {
        // The app reads the default Keychain item, so its config file must be the default one too;
        // a terminal's CLAUDE_CONFIG_DIR names a different account.
        let url = MenuBarController.claudeConfigFileURL(environment: [
            "HOME": "/Users/example",
            "CLAUDE_CONFIG_DIR": "/Users/example/.claude-profiles/cc4",
        ])

        XCTAssertEqual(url.path, "/Users/example/.claude.json")
    }

    func testProductionCodexDependenciesShareInjectedResolverAndUseInjectedBrowserOpener() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenusage-production-\(UUID().uuidString)", isDirectory: true)
        let codexHome = fixtureRoot.appendingPathComponent("codex-home", isDirectory: true)
        let executable = fixtureRoot.appendingPathComponent("codex", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf '%s\\n' 'https://auth.openai.com/device'\nexit 0\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let environment = ["HOME": fixtureRoot.path, "PATH": ""]
        let resolver = ProductionResolverRecorder(executable: executable)
        let opener = ProductionBrowserOpenerRecorder()
        let dependencies = ProductionCodexDependencies(
            environment: environment,
            applicationSupportDirectory: fixtureRoot.appendingPathComponent("Application Support"),
            resolver: resolver,
            browserOpener: opener.open
        )

        _ = try await dependencies.makeCodexClient(
            runner: ProductionJSONRPCRunnerStub()
        ).usage(codexHome: codexHome)
        let outcome = try await dependencies.makeLoginRunner(
            attemptController: CodexLoginAttemptController()
        ).runCodexLogin(codexHome: codexHome)

        XCTAssertTrue(outcome.isCompleted)
        XCTAssertEqual(resolver.environments, [
            environment.merging(["CODEX_HOME": codexHome.path]) { _, new in new },
            environment,
        ])
        XCTAssertEqual(opener.openCount, 1)
        XCTAssertEqual(opener.lastHost, "auth.openai.com")
        print("TASK7_COMPOSITION shared_resolver_calls=2 injected_opener_calls=1 live_browser=false")
    }

    func testFinderSparseEnvironmentResolvesFNMDefaultAndInvalidExplicitOverrideFailsClosed() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenusage-finder-\(UUID().uuidString)", isDirectory: true)
        let fnmRoot = fixtureRoot.appendingPathComponent("fnm", isDirectory: true)
        let executable = fnmRoot.appendingPathComponent("aliases/default/bin/codex", isDirectory: false)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let sparseEnvironment = [
            "PATH": "",
            "HOME": fixtureRoot.appendingPathComponent("home").path,
            "FNM_DIR": fnmRoot.path,
        ]
        let sparseDependencies = ProductionCodexDependencies(
            environment: sparseEnvironment,
            applicationSupportDirectory: fixtureRoot.appendingPathComponent("Application Support"),
            browserOpener: { _ in XCTFail("Sparse launch opened a live browser"); return false }
        )
        XCTAssertEqual(try sparseDependencies.resolveCodexExecutable(), executable)

        var invalidEnvironment = sparseEnvironment
        invalidEnvironment["TOKENUSAGE_CODEX_PATH"] = fixtureRoot
            .appendingPathComponent("missing-explicit-codex")
            .path
        let invalidDependencies = ProductionCodexDependencies(
            environment: invalidEnvironment,
            applicationSupportDirectory: fixtureRoot.appendingPathComponent("Application Support"),
            browserOpener: { _ in XCTFail("Invalid launch opened a live browser"); return false }
        )
        XCTAssertThrowsError(try invalidDependencies.resolveCodexExecutable()) { error in
            XCTAssertEqual(error as? CodexAppServerClient.Error, .invalidExecutableOverride)
        }
        print("TASK7_FINDER path_empty=true fnm_default=true invalid_explicit=fails_closed live_home=false live_browser=false")
    }

    func testImmediateRefreshImportsOnlyAValidCurrentAccountAsEditableCodex2() async throws {
        let profiles = ProfileManagerFixture(currentAccountIsValid: true)
        let claude = usage(remaining: 71)
        let codex = usage(remaining: 62)
        let service = ProductionAppService(
            loadClaude: { claude },
            loadCodex: { _ in codex },
            profileManager: profiles
        )

        let snapshot = await service.refresh()
        let savedNames = await profiles.savedNames()

        XCTAssertEqual(savedNames, ["codex2"])
        XCTAssertEqual(snapshot.codexProfiles.map(\.name), ["codex2"])
        XCTAssertEqual(snapshot.activeCodexProfileID, "generated-1")
        XCTAssertEqual(snapshot.claude, .fresh(claude))
        XCTAssertEqual(
            snapshot.codexUsage,
            [CodexProfileUsage(profileID: "generated-1", state: .fresh(codex))]
        )
    }

    func testRefreshLoadsOpenRouterConcurrentlyAndKeepsClaudeCodexIndependent() async {
        let profiles = ProfileManagerFixture(
            currentAccountIsValid: true,
            initialProfiles: [CodexProfileMetadata(id: "codex", name: "Codex")],
            activeID: "codex"
        )
        let claude = usage(remaining: 71)
        let codex = usage(remaining: 62)
        let gate = RefreshGate()
        let claudeStarted = expectation(description: "Claude refresh started")
        let openRouterStarted = expectation(description: "OpenRouter refresh started")
        let service = ProductionAppService(
            loadClaude: {
                claudeStarted.fulfill()
                await gate.wait()
                return claude
            },
            loadCodex: { _ in codex },
            loadOpenRouter: {
                openRouterStarted.fulfill()
                await gate.wait()
                throw OpenRouterUsageClientError.timeout
            },
            profileManager: profiles
        )

        let refresh = Task { await service.refresh() }
        await fulfillment(of: [claudeStarted, openRouterStarted], timeout: 1)
        await gate.release()
        let snapshot = await refresh.value

        XCTAssertEqual(snapshot.claude, .fresh(claude))
        XCTAssertEqual(snapshot.codexUsage, [
            CodexProfileUsage(profileID: "codex", state: .fresh(codex)),
        ])
        guard case .unavailable = snapshot.openRouter else {
            return XCTFail("OpenRouter failure must remain local to OpenRouter")
        }
        print("OPENROUTER_QA concurrent_start=true isolated_failure=timeout claude=fresh codex=fresh")
    }

    func testTwoProfileRefreshStartsBothOperationsBeforeEitherCompletesAndKeepsProfileOrder() async {
        let profiles = ProfileManagerFixture(
            currentAccountIsValid: true,
            initialProfiles: [
                CodexProfileMetadata(id: "one", name: "One"),
                CodexProfileMetadata(id: "two", name: "Two"),
            ],
            activeID: "two"
        )
        let barrier = ConcurrentUsageBarrier(values: ["one": 11, "two": 22])
        let claude = usage(remaining: 90)
        let service = ProductionAppService(
            loadClaude: { claude },
            loadCodex: { home in try await barrier.load(profileID: home.lastPathComponent) },
            profileManager: profiles
        )

        let refresh = Task { await service.refresh() }
        await barrier.waitUntilStarted(count: 2)
        let overlap = await barrier.metrics()
        XCTAssertEqual(overlap.started.sorted(), ["one", "two"])
        XCTAssertEqual(overlap.maximumInFlight, 2)

        await barrier.release(profileID: "two")
        await barrier.release(profileID: "one")
        let snapshot = await refresh.value

        XCTAssertEqual(snapshot.codexUsage.map(\.profileID), ["one", "two"])
        XCTAssertEqual(snapshot.codexUsage.compactMap(freshRemaining), [11, 22])
        XCTAssertEqual(snapshot.activeCodexProfileID, "two")
        print("TASK4_QA two_profiles started=one,two max_in_flight=\(overlap.maximumInFlight) ordered_ids=one,two keyed_values=11,22 active_id=two")
    }

    func testFiveProfileRefreshSchedulesEveryProfileWithAtMostFourInFlight() async {
        let metadata = (1...5).map { CodexProfileMetadata(id: "p\($0)", name: "P\($0)") }
        let profiles = ProfileManagerFixture(
            currentAccountIsValid: true,
            initialProfiles: metadata,
            activeID: "p3"
        )
        let barrier = ConcurrentUsageBarrier(
            values: Dictionary(uniqueKeysWithValues: (1...5).map { ("p\($0)", Double($0 * 10)) })
        )
        let claude = usage(remaining: 90)
        let service = ProductionAppService(
            loadClaude: { claude },
            loadCodex: { home in try await barrier.load(profileID: home.lastPathComponent) },
            profileManager: profiles
        )

        let refresh = Task { await service.refresh() }
        await barrier.waitUntilStarted(count: 4)
        var metrics = await barrier.metrics()
        XCTAssertEqual(metrics.started.count, 4)
        XCTAssertEqual(metrics.maximumInFlight, 4)

        await barrier.release(profileID: "p2")
        await barrier.waitUntilStarted(count: 5)
        metrics = await barrier.metrics()
        XCTAssertEqual(Set(metrics.started), Set(metadata.map(\.id)))
        XCTAssertEqual(metrics.maximumInFlight, 4)

        for id in ["p5", "p4", "p3", "p1"] {
            await barrier.release(profileID: id)
        }
        let snapshot = await refresh.value

        XCTAssertEqual(snapshot.codexUsage.map(\.profileID), metadata.map(\.id))
        XCTAssertEqual(snapshot.codexUsage.compactMap(freshRemaining), [10, 20, 30, 40, 50])
        XCTAssertEqual(snapshot.activeCodexProfileID, "p3")
        print("TASK4_QA five_profiles scheduled=5 max_in_flight=\(metrics.maximumInFlight) ordered_ids=p1,p2,p3,p4,p5 keyed_values=10,20,30,40,50 active_id=p3")
    }

    func testProfileFailuresRecoverIndependentlyAndRemovedLastGoodStateIsPruned() async {
        let p1 = CodexProfileMetadata(id: "p1", name: "P1")
        let p2 = CodexProfileMetadata(id: "p2", name: "P2")
        let profiles = ProfileManagerFixture(
            currentAccountIsValid: true,
            initialProfiles: [p1, p2],
            activeID: "p2"
        )
        let loader = ScriptedUsageLoader(outcomes: [
            "p1": [.value(11), .failure, .failure, .value(15)],
            "p2": [.failure, .value(22), .value(23), .failure, .failure],
        ])
        let claude = usage(remaining: 90)
        let service = ProductionAppService(
            loadClaude: { claude },
            loadCodex: { try await loader.load(profileID: $0.lastPathComponent) },
            profileManager: profiles
        )

        let first = await service.refresh()
        XCTAssertEqual(first.codexUsage[0].state, .fresh(usage(remaining: 11)))
        XCTAssertEqual(first.codexUsage[1].state, .unavailable(message: "Codex usage refresh failed."))

        let second = await service.refresh()
        XCTAssertEqual(
            second.codexUsage[0].state,
            .stale(lastGood: usage(remaining: 11), message: "Codex usage refresh failed.")
        )
        XCTAssertEqual(second.codexUsage[1].state, .fresh(usage(remaining: 22)))
        XCTAssertEqual(second.activeCodexProfileID, "p2")

        await profiles.replaceProfiles([p2], activeID: "p2")
        let pruned = await service.refresh()
        XCTAssertEqual(pruned.codexUsage.map(\.profileID), ["p2"])
        XCTAssertEqual(pruned.codexUsage[0].state, .fresh(usage(remaining: 23)))

        await profiles.replaceProfiles([p1, p2], activeID: "p1")
        let readded = await service.refresh()
        XCTAssertEqual(readded.codexUsage[0].state, .unavailable(message: "Codex usage refresh failed."))
        XCTAssertEqual(readded.activeCodexProfileID, "p1")

        let recovered = await service.refresh()
        XCTAssertEqual(recovered.codexUsage[0].state, .fresh(usage(remaining: 15)))
        print("TASK4_QA state fresh=p1:11 unavailable=p2 stale=p1:lastGood11 recovery=p1:15 pruning=p1_removed readded=p1_unavailable active_id=p1")
    }

    func testRefreshUsesMaterializedHomesWritesBackMatchingBaselinesAndLeavesDefaultAuthUntouched() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenusage-task4-\(UUID().uuidString)", isDirectory: true)
        let defaultAuth = fixtureRoot.appendingPathComponent("default/.codex/auth.json")
        let profileRoot = fixtureRoot.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: defaultAuth.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let untouched = Data("default-auth-sentinel".utf8)
        try untouched.write(to: defaultAuth)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let profiles = ProfileManagerFixture(
            currentAccountIsValid: true,
            initialProfiles: [
                CodexProfileMetadata(id: "one", name: "One"),
                CodexProfileMetadata(id: "two", name: "Two"),
            ],
            activeID: "one",
            homeRoot: profileRoot
        )
        let claude = usage(remaining: 90)
        let service = ProductionAppService(
            loadClaude: { claude },
            loadCodex: { home in
                let profileID = home.lastPathComponent
                try Data("rotated-\(profileID)".utf8)
                    .write(to: home.appendingPathComponent("auth.json"))
                return UsageSnapshot(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    weekly: QuotaWindow(
                        remainingPercent: profileID == "one" ? 11 : 22,
                        resetsAt: nil
                    )
                )
            },
            profileManager: profiles
        )

        let snapshot = await service.refresh()
        let writeBacks = await profiles.writeBacks()

        XCTAssertEqual(snapshot.codexUsage.compactMap(freshRemaining), [11, 22])
        XCTAssertEqual(writeBacks.map(\.profileID).sorted(), ["one", "two"])
        XCTAssertTrue(writeBacks.allSatisfy { $0.baseline == Data("baseline-\($0.profileID)".utf8) })
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: writeBacks.map { ($0.profileID, $0.updatedCredential) }),
            ["one": Data("rotated-one".utf8), "two": Data("rotated-two".utf8)]
        )
        XCTAssertEqual(try Data(contentsOf: defaultAuth), untouched)
        print("TASK4_QA auth materialized_homes=2 keychain_cas_baselines=2 writebacks=2 default_auth_untouched=true")
    }

    func testInvalidCurrentAccountNeverBecomesAnActiveProfile() async {
        let profiles = ProfileManagerFixture(currentAccountIsValid: false)
        let service = ProductionAppService(
            loadClaude: { throw ProviderFailure.unavailable },
            loadCodex: { _ in throw ProviderFailure.unavailable },
            profileManager: profiles
        )

        let snapshot = await service.refresh()
        let savedNames = await profiles.savedNames()

        XCTAssertEqual(savedNames, ["codex2"])
        XCTAssertTrue(snapshot.codexProfiles.isEmpty)
        XCTAssertNil(snapshot.activeCodexProfileID)
        XCTAssertTrue(snapshot.codexUsage.isEmpty)
    }

    func testRefreshDeletesCodexProfilesCodexReportsAsSignedOut() async {
        let profiles = ProfileManagerFixture(
            currentAccountIsValid: true,
            initialProfiles: [
                CodexProfileMetadata(id: "p1", name: "Personal"),
                CodexProfileMetadata(id: "p2", name: "Expired"),
            ],
            activeID: "p2"
        )
        let claude = usage(remaining: 90)
        let codex = usage(remaining: 44)
        let service = ProductionAppService(
            loadClaude: { claude },
            loadCodex: { home in
                guard home.lastPathComponent == "p1" else {
                    throw CodexAppServerClient.Error.methodFailed(code: 401)
                }
                return codex
            },
            validateCodexAccount: { home in
                guard home.lastPathComponent == "p1" else {
                    throw CodexAppServerClient.Error.notAuthenticated
                }
                return CodexAccount(type: "chatgpt")
            },
            profileManager: profiles
        )

        let snapshot = await service.refresh()
        let removedIDs = await profiles.removedIDs()

        XCTAssertEqual(removedIDs, ["p2"])
        XCTAssertEqual(snapshot.codexProfiles.map(\.id), ["p1"])
        XCTAssertEqual(snapshot.codexUsage.map(\.profileID), ["p1"])
        XCTAssertEqual(snapshot.removedCodexProfileNames, ["Expired"])
        XCTAssertNil(snapshot.activeCodexProfileID)
    }

    func testRefreshKeepsCodexProfilesWhoseFailureIsNotASignOut() async {
        let profiles = ProfileManagerFixture(
            currentAccountIsValid: true,
            initialProfiles: [CodexProfileMetadata(id: "p1", name: "Personal")],
            activeID: "p1"
        )
        let claude = usage(remaining: 90)
        let service = ProductionAppService(
            loadClaude: { claude },
            loadCodex: { _ in throw CodexAppServerClient.Error.processFailed },
            validateCodexAccount: { _ in throw CodexAppServerClient.Error.processFailed },
            profileManager: profiles
        )

        let snapshot = await service.refresh()
        let removedIDs = await profiles.removedIDs()

        XCTAssertTrue(removedIDs.isEmpty)
        XCTAssertEqual(snapshot.codexProfiles.map(\.id), ["p1"])
        XCTAssertEqual(snapshot.codexUsage[0].state, .unavailable(message: "Codex usage refresh failed."))
        XCTAssertTrue(snapshot.removedCodexProfileNames.isEmpty)
        XCTAssertEqual(snapshot.activeCodexProfileID, "p1")
    }

    func testRefreshDeletesCodexProfilesWhoseStoredCredentialIsGone() async {
        let profiles = MissingCredentialProfileManagerFixture(
            profiles: [CodexProfileMetadata(id: "p1", name: "Ghost")]
        )
        let claude = usage(remaining: 90)
        let unused = usage(remaining: 0)
        let service = ProductionAppService(
            loadClaude: { claude },
            loadCodex: { _ in
                XCTFail("Refresh loaded usage without a credential")
                return unused
            },
            validateCodexAccount: { _ in
                XCTFail("Refresh validated an absent credential")
                return CodexAccount(type: "chatgpt")
            },
            profileManager: profiles
        )

        let snapshot = await service.refresh()
        let removedIDs = await profiles.removedIDs()

        XCTAssertEqual(removedIDs, ["p1"])
        XCTAssertTrue(snapshot.codexProfiles.isEmpty)
        XCTAssertEqual(snapshot.removedCodexProfileNames, ["Ghost"])
    }

    func testProfileActionsComposeManagerAndRefreshWithoutExposingCredentials() async throws {
        let profiles = ProfileManagerFixture(
            currentAccountIsValid: true,
            initialProfiles: [CodexProfileMetadata(id: "one", name: "Personal")],
            activeID: "one"
        )
        let claude = usage(remaining: 51)
        let codex = usage(remaining: 41)
        let service = ProductionAppService(
            loadClaude: { claude },
            loadCodex: { _ in codex },
            profileManager: profiles
        )

        let selected = try await service.selectProfile(id: "one")
        let activatedIDs = await profiles.activatedIDs()
        XCTAssertEqual(selected.activeCodexProfileID, "one")
        XCTAssertEqual(activatedIDs, ["one"])

        let saved = try await service.saveCurrentProfile(named: "Edited")
        XCTAssertEqual(saved.codexProfiles.last?.name, "Edited")

        let added = try await service.addAccount(named: "Work")
        let addedNames = await profiles.addedNames()
        XCTAssertEqual(addedNames, ["Work"])

        let addedID = try XCTUnwrap(added.codexProfiles.last?.id)
        _ = try await service.deleteProfile(id: addedID)
        let removedIDs = await profiles.removedIDs()
        XCTAssertEqual(removedIDs, [addedID])
    }

    @MainActor
    func testPopoverIsCreatedOnlyAfterStatusClickAndReleasedAfterClose() {
        _ = NSApplication.shared
        let model = AppViewModel(coordinator: NoopCoordinator(), profileActions: NoopProfileActions())
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let controller = MenuBarController(model: model, statusItem: statusItem)

        XCTAssertNil(mirroredObject(NSPopover.self, named: "popover", in: controller))
        XCTAssertNil(mirroredObject(UsagePopoverHostingController.self, named: "popoverHostingController", in: controller))

        controller.togglePopover()
        XCTAssertNotNil(mirroredObject(NSPopover.self, named: "popover", in: controller))
        XCTAssertNotNil(mirroredObject(UsagePopoverHostingController.self, named: "popoverHostingController", in: controller))

        let popover = try! XCTUnwrap(mirroredObject(NSPopover.self, named: "popover", in: controller))
        XCTAssertFalse(popover.animates)
        XCTAssertEqual(popover.behavior, .transient)
        popover.close()
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertNil(mirroredObject(NSPopover.self, named: "popover", in: controller))
        XCTAssertNil(mirroredObject(UsagePopoverHostingController.self, named: "popoverHostingController", in: controller))
    }

    @MainActor
    func testStatusItemUsesRenderedImageWithoutLiveCustomSubviews() {
        _ = NSApplication.shared
        let model = AppViewModel(coordinator: NoopCoordinator(), profileActions: NoopProfileActions())
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        let controller = MenuBarController(model: model, statusItem: statusItem)

        XCTAssertNotNil(statusItem.button?.image)
        XCTAssertFalse(statusItem.button?.subviews.contains { $0 is StatusItemView } == true)
        XCTAssertTrue(statusItem.button?.accessibilityLabel()?.contains("Claude") == true)
        XCTAssertTrue(statusItem.button?.accessibilityLabel()?.contains("Codex") == true)
        withExtendedLifetime(controller) {}
    }

    @MainActor
    func testPopoverHostingViewExposesAccessibilityGroupLabelAndIdentifier() {
        _ = NSApplication.shared
        let model = AppViewModel(coordinator: NoopCoordinator(), profileActions: NoopProfileActions())
        let hostingController = UsagePopoverHostingController(model: model)
        let contentView = hostingController.view

        XCTAssertTrue(contentView.isAccessibilityElement())
        XCTAssertEqual(contentView.accessibilityRole(), .group)
        XCTAssertEqual(contentView.accessibilityLabel(), "Token Usage 사용량 창")
        XCTAssertEqual(contentView.accessibilityIdentifier(), "usage-popover-window")
    }

    @MainActor
    func testMenuBarLifecycleStartsImmediateRefreshAndStopsOwnedWorkExactlyOnce() async throws {
        _ = NSApplication.shared
        let started = expectation(description: "menu controller started coordinator")
        let stopped = expectation(description: "menu controller stopped coordinator")
        let coordinator = LifecycleCoordinator(started: started, stopped: stopped)
        let actions = NoopProfileActions()
        let model = AppViewModel(coordinator: coordinator, profileActions: actions)
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let removal = RemovalSpy()
        let controller = MenuBarController(
            model: model,
            statusItem: statusItem,
            removeStatusItem: { item in
                removal.record(item)
                NSStatusBar.system.removeStatusItem(item)
            }
        )

        XCTAssertEqual(MenuBarController.refreshInterval, .seconds(300))
        print("TASK4_LIFECYCLE before_start")
        controller.start()
        controller.start()
        print("TASK4_LIFECYCLE before_started_fulfillment")
        await fulfillment(of: [started], timeout: 2)
        print("TASK4_LIFECYCLE after_started_fulfillment")

        await controller.stop()
        print("TASK4_LIFECYCLE after_first_stop")
        await controller.stop()
        print("TASK4_LIFECYCLE before_stopped_fulfillment")
        await fulfillment(of: [stopped], timeout: 2)
        print("TASK4_LIFECYCLE after_stopped_fulfillment")

        let startCount = await coordinator.startCount()
        let stopCount = await coordinator.stopCount()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(removal.count, 1)
        XCTAssertTrue(removal.item === statusItem)
    }

    private func mirroredObject<T>(_ type: T.Type, named name: String, in object: Any) -> T? {
        guard let child = Mirror(reflecting: object).children.first(where: { $0.label == name }) else {
            return nil
        }
        let optional = Mirror(reflecting: child.value)
        guard optional.displayStyle == .optional,
              let wrapped = optional.children.first?.value
        else { return nil }
        return wrapped as? T
    }

    private func usage(remaining: Double) -> UsageSnapshot {
        UsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            weekly: QuotaWindow(remainingPercent: remaining, resetsAt: nil)
        )
    }

    private func freshRemaining(_ usage: CodexProfileUsage) -> Double? {
        guard case let .fresh(snapshot) = usage.state else { return nil }
        return snapshot.weekly?.remainingPercent
    }
}

private enum ProviderFailure: Error {
    case unavailable
}

private final class ProductionResolverRecorder: CodexExecutableResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let executable: URL
    private var recordedEnvironments: [[String: String]] = []

    init(executable: URL) {
        self.executable = executable
    }

    var environments: [[String: String]] { lock.withLock { recordedEnvironments } }

    func resolve(environment: [String: String]) throws -> URL {
        lock.withLock { recordedEnvironments.append(environment) }
        return executable
    }
}

private final class ProductionBrowserOpenerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []

    var openCount: Int { lock.withLock { hosts.count } }
    var lastHost: String? { lock.withLock { hosts.last } }

    func open(_ url: URL) -> Bool {
        lock.withLock { hosts.append(url.host ?? "") }
        return true
    }
}

private struct ProductionJSONRPCRunnerStub: JSONRPCProcessRunning {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        request: Data
    ) async throws -> Data {
        Data(#"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1776038400},"secondary":null}}}"#.utf8)
    }
}

private actor ConcurrentUsageBarrier {
    private let values: [String: Double]
    private var started: [String] = []
    private var inFlight = 0
    private var maximumInFlight = 0
    private var releases: [String: CheckedContinuation<Void, Never>] = [:]
    private var releasedBeforeWaiting: Set<String> = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(values: [String: Double]) {
        self.values = values
    }

    func load(profileID: String) async throws -> UsageSnapshot {
        started.append(profileID)
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        let ready = startWaiters.filter { started.count >= $0.0 }
        startWaiters.removeAll { started.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { continuation in
            if releasedBeforeWaiting.remove(profileID) != nil {
                continuation.resume()
            } else {
                releases[profileID] = continuation
            }
        }
        inFlight -= 1
        guard let value = values[profileID] else { throw ProviderFailure.unavailable }
        return UsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + value),
            weekly: QuotaWindow(remainingPercent: value, resetsAt: nil)
        )
    }

    func waitUntilStarted(count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func release(profileID: String) {
        if let continuation = releases.removeValue(forKey: profileID) {
            continuation.resume()
        } else {
            releasedBeforeWaiting.insert(profileID)
        }
    }

    func metrics() -> (started: [String], maximumInFlight: Int) {
        (started, maximumInFlight)
    }
}

private actor RefreshGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func release() {
        isReleased = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor ProfileManagerFixture: CodexProfileManaging {
    private let currentAccountIsValid: Bool
    private var profiles: [CodexProfileMetadata]
    private var activeID: String?
    private var saveEvents: [String] = []
    private var addEvents: [String] = []
    private var removeEvents: [String] = []
    private var activateEvents: [String] = []
    private let homeRoot: URL
    private var writeBackEvents: [ProfileWriteBack] = []

    init(
        currentAccountIsValid: Bool,
        initialProfiles: [CodexProfileMetadata] = [],
        activeID: String? = nil,
        homeRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenusage-profile-fixture-\(UUID().uuidString)", isDirectory: true)
    ) {
        self.currentAccountIsValid = currentAccountIsValid
        profiles = initialProfiles
        self.activeID = activeID
        self.homeRoot = homeRoot
    }

    deinit {
        try? FileManager.default.removeItem(at: homeRoot)
    }

    func saveCurrent(named name: String) throws -> CodexProfileMetadata {
        saveEvents.append(name)
        guard currentAccountIsValid else { throw ProviderFailure.unavailable }
        let profile = CodexProfileMetadata(id: "generated-\(profiles.count + 1)", name: name)
        profiles.append(profile)
        activeID = profile.id
        return profile
    }

    func addAccount(named name: String) -> CodexProfileMetadata? {
        addEvents.append(name)
        let profile = CodexProfileMetadata(id: "added-\(profiles.count + 1)", name: name)
        profiles.append(profile)
        return profile
    }

    func removeProfile(id: String) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw ProviderFailure.unavailable }
        removeEvents.append(id)
        profiles.removeAll { $0.id == id }
        if activeID == id {
            activeID = nil
        }
    }

    func listProfiles() -> [CodexProfileMetadata] { profiles }
    func activeProfileID() -> String? { activeID }

    func activateProfile(id: String) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw ProviderFailure.unavailable }
        activateEvents.append(id)
        activeID = id
    }

    func materializeProfileHome(id: String) throws -> CodexProfileHomeMaterialization {
        guard profiles.contains(where: { $0.id == id }) else { throw ProviderFailure.unavailable }
        let homeURL = homeRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let baseline = Data("baseline-\(id)".utf8)
        try baseline.write(to: homeURL.appendingPathComponent("auth.json"))
        return CodexProfileHomeMaterialization(
            homeURL: homeURL,
            credentialBaseline: baseline
        )
    }

    func writeBackProfileCredential(id: String, baseline: Data) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw ProviderFailure.unavailable }
        guard baseline == Data("baseline-\(id)".utf8) else { throw ProviderFailure.unavailable }
        let updated = try Data(contentsOf: homeRoot
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("auth.json"))
        writeBackEvents.append(ProfileWriteBack(
            profileID: id,
            baseline: baseline,
            updatedCredential: updated
        ))
    }

    func replaceProfiles(_ profiles: [CodexProfileMetadata], activeID: String?) {
        self.profiles = profiles
        self.activeID = activeID
    }

    func savedNames() -> [String] { saveEvents }
    func addedNames() -> [String] { addEvents }
    func removedIDs() -> [String] { removeEvents }
    func activatedIDs() -> [String] { activateEvents }
    func writeBacks() -> [ProfileWriteBack] { writeBackEvents }
}

private struct ProfileWriteBack: Sendable {
    let profileID: String
    let baseline: Data
    let updatedCredential: Data
}

private enum ScriptedUsageOutcome: Sendable {
    case value(Double)
    case failure
}

private actor ScriptedUsageLoader {
    private var outcomes: [String: [ScriptedUsageOutcome]]

    init(outcomes: [String: [ScriptedUsageOutcome]]) {
        self.outcomes = outcomes
    }

    func load(profileID: String) throws -> UsageSnapshot {
        guard var profileOutcomes = outcomes[profileID], !profileOutcomes.isEmpty else {
            throw ProviderFailure.unavailable
        }
        let outcome = profileOutcomes.removeFirst()
        outcomes[profileID] = profileOutcomes
        switch outcome {
        case .value(let remaining):
            return UsageSnapshot(
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                weekly: QuotaWindow(remainingPercent: remaining, resetsAt: nil)
            )
        case .failure:
            throw ProviderFailure.unavailable
        }
    }
}

private actor NoopCoordinator: AppUsageCoordinating {
    func start() {}
    func stateChanges() -> AsyncStream<RefreshState<AppUsageSnapshot>> {
        AsyncStream { _ in }
    }
    func requestRefresh() {}
    func performProfileOperation(
        _ operation: @escaping @Sendable () async throws -> AppUsageSnapshot
    ) async throws -> AppUsageSnapshot {
        fatalError("NoopCoordinator does not perform profile operations")
    }
    func stop() {}
}

private actor LifecycleCoordinator: AppUsageCoordinating {
    private let states: AsyncStream<RefreshState<AppUsageSnapshot>>
    private let continuation: AsyncStream<RefreshState<AppUsageSnapshot>>.Continuation
    private let started: XCTestExpectation
    private let stopped: XCTestExpectation
    private var starts = 0
    private var stops = 0

    init(started: XCTestExpectation, stopped: XCTestExpectation) {
        (states, continuation) = AsyncStream.makeStream(of: RefreshState<AppUsageSnapshot>.self)
        self.started = started
        self.stopped = stopped
    }

    func start() {
        starts += 1
        continuation.yield(.refreshing(previous: nil))
        started.fulfill()
    }

    func stateChanges() -> AsyncStream<RefreshState<AppUsageSnapshot>> { states }
    func requestRefresh() {}

    func performProfileOperation(
        _ operation: @escaping @Sendable () async throws -> AppUsageSnapshot
    ) async throws -> AppUsageSnapshot {
        try await operation()
    }

    func stop() {
        stops += 1
        continuation.finish()
        stopped.fulfill()
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

private actor NoopProfileActions: CodexProfileActionHandling {
    func selectProfile(id: String) throws -> AppUsageSnapshot { throw ProviderFailure.unavailable }
    func saveCurrentProfile(named name: String) throws -> AppUsageSnapshot { throw ProviderFailure.unavailable }
    func addAccount(named name: String) throws -> AppUsageSnapshot { throw ProviderFailure.unavailable }
    func deleteProfile(id: String) throws -> AppUsageSnapshot { throw ProviderFailure.unavailable }
}

@MainActor
private final class RemovalSpy {
    private(set) var count = 0
    private(set) weak var item: NSStatusItem?

    func record(_ item: NSStatusItem) {
        count += 1
        self.item = item
    }
}

private actor MissingCredentialProfileManagerFixture: CodexProfileManaging {
    private var profiles: [CodexProfileMetadata]
    private var removeEvents: [String] = []

    init(profiles: [CodexProfileMetadata]) {
        self.profiles = profiles
    }

    func saveCurrent(named name: String) throws -> CodexProfileMetadata {
        throw CodexProfileManagerError.currentAccountMissing
    }

    func addAccount(named name: String) throws -> CodexProfileMetadata? {
        throw CodexProfileManagerError.loginFailed
    }

    func removeProfile(id: String) throws {
        guard profiles.contains(where: { $0.id == id }) else {
            throw CodexProfileManagerError.profileNotFound
        }
        removeEvents.append(id)
        profiles.removeAll { $0.id == id }
    }

    func listProfiles() -> [CodexProfileMetadata] { profiles }
    func activeProfileID() -> String? { nil }

    func activateProfile(id: String) throws {
        throw CodexProfileManagerError.credentialMissing
    }

    func materializeProfileHome(id: String) throws -> CodexProfileHomeMaterialization {
        throw CodexProfileManagerError.credentialMissing
    }

    func writeBackProfileCredential(id: String, baseline: Data) throws {
        throw CodexProfileManagerError.credentialMissing
    }

    func removedIDs() -> [String] { removeEvents }
}
