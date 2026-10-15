import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class AgentReadinessTests: XCTestCase {
    private func stores() throws -> Stores {
        let suite = "agent-readiness-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Agent did not reach the expected readiness")
    }

    private func host<V: View>(_ view: V, stores: Stores) throws -> (UIViewController, UIWindow) {
        let host = UIHostingController(rootView: NavigationStack { view }
            .environment(\.stores, stores).environment(AppModel(stores: stores))
            .environment(\.scenePhase, .inactive))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (host, window)
    }

    private func text(_ view: UIViewController, name: String? = nil) async throws -> String {
        try await Task.sleep(for: .milliseconds(200))
        let image = ChatFeedSnapshot.image(view)
        if let name {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".png")
            try image.pngData()?.write(to: path)
            print("AGENT_READINESS_SNAPSHOT_PATH=\(path.path)")
        }
        return try ChatFeedSnapshot.visibleText(in: image)
    }

    func testClosingCreationThenReopeningAgentKeepsLiveSetupAndLoginGate() async throws {
        for harness in [AgentID.codex, .claudeCode] {
            let stores = try stores()
            let workspaceId = UUID().uuidString
            let agent = stores.createAgent(.init(name: "Builder", agentType: harness, workspaceId: workspaceId))
            stores.createProject(.init(name: "Demo", workspaceId: workspaceId, path: "/demo"))
            let channel = ReadinessChannel(harness: harness.rawValue, running: true, configured: false)
            let session = DaemonSession(agentId: agent.id,
                transport: ExecDaemonTransport(channel: channel, agentType: harness.rawValue),
                workspaceId: workspaceId, agentType: harness.rawValue)
            defer { DaemonWorkCoordinator.shared.forget(workspaceId: workspaceId) }

            let (_, creation) = try host(AgentSetupScreen(agent: agent, session: session) {}, stores: stores)
            try await eventually { session.toolsWork?.message == t("agentUpdates.step.installing", ["name": "node"]) }
            creation.isHidden = true
            creation.rootViewController = nil // dismiss while the service's job is still running

            let (installingView, installingWindow) = try host(
                AgentDetailScreen(agentId: agent.id, session: session), stores: stores)
            defer { installingWindow.isHidden = true }
            let installingText = try await text(installingView, name: "mindwire-agent-installing-\(harness.rawValue)")
            XCTAssertTrue(installingText.contains(t("agentAuth.work.toolchain")), installingText)
            XCTAssertTrue(installingText.contains(t("agentUpdates.stepsReady", ["done": "1", "total": "3"])), installingText)
            XCTAssertFalse(installingText.contains(t("agentDetail.newChat")), installingText)
            _ = try AgentManagementTestUI.button(in: installingView)

            await channel.advance(stage: "verifying")
            try await eventually {
                session.toolsWork?.message == t("agentUpdates.step.verifying", ["name": harness.rawValue])
            }
            let (detailView, detailWindow) = try host(AgentDetailScreen(agentId: agent.id, session: session), stores: stores)
            defer { detailWindow.isHidden = true }
            let detailText = try await text(detailView, name: "mindwire-agent-verifying-\(harness.rawValue)")
            XCTAssertTrue(detailText.contains("Verifying"), detailText)
            XCTAssertFalse(detailText.contains(t("agentDetail.newChat")), detailText)
            XCTAssertEqual(session.phase, .checking)
            _ = try AgentManagementTestUI.button(in: detailView)

            await channel.finish()
            try await eventually { session.phase == .needsAuth }
            let authText = try await text(detailView)
            XCTAssertTrue(authText.contains(t("agentAuth.gate.title")), authText)
            XCTAssertFalse(authText.contains(t("agentDetail.newChat")), authText)
            _ = try AgentManagementTestUI.button(in: detailView)
            let infoReads = await channel.infoReads
            XCTAssertEqual(infoReads, 1, "Use the installation's verified response for auth instead of probing the CLI again")

            let method = try XCTUnwrap(session.methods.first { $0.id == "apiKey" })
            let accepted = await session.submit(method: method, values: ["apiKey": "fixture"])
            XCTAssertTrue(accepted)
            try await eventually { session.phase == .ready }
            let readyText = try await text(detailView)
            XCTAssertTrue(readyText.contains(t("agentDetail.newChat")), readyText)
            _ = try AgentManagementTestUI.button(in: detailView)
            detailWindow.isHidden = true
            installingWindow.makeKeyAndVisible()
            let readyReopenedText = try await text(installingView)
            XCTAssertTrue(readyReopenedText.contains(t("agentDetail.newChat")), readyReopenedText)
            let posts = await channel.setupPosts
            XCTAssertEqual(posts, 0, "Every reopened page must attach to the daemon's existing job")
        }
    }

    func testAuthenticationPageKeepsManagementAndDeleteConfirmationWithoutLogin() async throws {
        for harness in [AgentID.codex, .claudeCode] {
            let stores = try stores()
            let agent = stores.createAgent(.init(name: "Builder", agentType: harness, workspaceId: UUID().uuidString))
            let channel = ReadinessChannel(harness: harness.rawValue, running: false, configured: false)
            let session = DaemonSession(agentId: agent.id,
                transport: ExecDaemonTransport(channel: channel, agentType: harness.rawValue))
            defer { DaemonWorkCoordinator.shared.forget(workspaceId: agent.id) }
            let (view, window) = try host(AgentAuthenticationScreen(agentId: agent.id, session: session), stores: stores)
            defer { window.isHidden = true; window.rootViewController = nil }
            try await eventually { session.phase == .needsAuth }
            _ = try await text(view)

            let button = try AgentManagementTestUI.button(in: view)
            button.performPrimaryAction()
            let interaction = try XCTUnwrap(button.contextMenuInteraction)
            var menu: UIMenu?
            try await eventually {
                interaction.updateVisibleMenu { menu = $0; return $0 }
                return menu.map { !AgentManagementTestUI.actions(in: $0).isEmpty } ?? false
            }
            let actions = AgentManagementTestUI.actions(in: try XCTUnwrap(menu))
            let titles = Set(actions.filter { !$0.attributes.contains(.disabled) }.map(\.title))
            for title in [t("common.rename"), t("workspace.terminal.open"), t("agentSettings.title"), t("agentSettings.delete")] {
                XCTAssertTrue(titles.contains(title), "Missing management action: \(title); found \(titles)")
            }
            XCTAssertFalse(actions.contains { $0.title == t("agentAuth.section") }, "Do not push authentication from itself")
            let delete = try XCTUnwrap(actions.first { $0.title == t("agentSettings.delete") })
            XCTAssertTrue(delete.attributes.contains(.destructive))
            interaction.dismissMenu()
            try await Task.sleep(for: .milliseconds(300))
            button.sendAction(delete)
            try await eventually { AgentManagementTestUI.alert(in: view)?.view.window != nil }
            let confirmation = try XCTUnwrap(AgentManagementTestUI.alert(in: view))
            XCTAssertEqual(confirmation.title, t("agentDetail.delete.title"))
            XCTAssertTrue(confirmation.actions.contains { $0.style == .cancel })
            XCTAssertTrue(confirmation.actions.contains { $0.style == .destructive })
            XCTAssertNotNil(stores.agents.get(agent.id), "Opening the confirmation must not delete anything")
        }
    }

    func testUnreachableAgentStillHasManagementAndShowsActionFailures() async throws {
        let stores = try stores()
        let agent = stores.createAgent(.init(name: "Builder", agentType: .claudeCode, workspaceId: UUID().uuidString))
        let channel = ReadinessChannel(harness: "claude-code", running: false, configured: false, installedVersion: "")
        let session = DaemonSession(agentId: agent.id,
            transport: ExecDaemonTransport(channel: channel, agentType: "claude-code"))
        defer { DaemonWorkCoordinator.shared.forget(workspaceId: agent.id) }
        let (view, window) = try host(AgentDetailScreen(agentId: agent.id, session: session), stores: stores)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await eventually { if case .unreachable = session.phase { return true }; return false }
        let unavailable = try await text(view)
        XCTAssertFalse(unavailable.contains(t("agentDetail.newChat")), unavailable)
        _ = try AgentManagementTestUI.button(in: view)

        let actions = WorkspaceActions()
        let (errorView, errorWindow) = try host(AgentReadinessView(agent: agent, session: session) { EmptyView() }
            .agentManagement(agent: agent, session: session, actions: actions), stores: stores)
        defer { errorWindow.isHidden = true; errorWindow.rootViewController = nil }
        _ = try await text(errorView)
        actions.run { throw BackendError.message("Could not remove agent") }
        try await eventually { AgentManagementTestUI.alert(in: errorView)?.view.window != nil }
        let alert = try XCTUnwrap(AgentManagementTestUI.alert(in: errorView))
        XCTAssertEqual(alert.message, "Could not remove agent")
        XCTAssertNotNil(stores.agents.get(agent.id))
    }

    func testSignedOutRemovalHonorsNativeChatFailuresBeforeRemovingProfile() async throws {
        let stores = try stores()
        let workspace = Workspace(id: UUID().uuidString, name: "Workspace",
            runtime: .server(serverId: "fixture"), createdAt: isoNow())
        let agent = stores.createAgent(.init(name: "Builder", agentType: .claudeCode, workspaceId: workspace.id))
        let project = stores.createProject(.init(name: "Demo", workspaceId: workspace.id, path: "/demo"))
        let chat = stores.createChat(agentId: agent.id, projectId: project.id)
        let remote = WorkspaceRemoteFixture()
        remote.current = .init(version: 1, workspaceId: "database", revision: 1, full: true,
            agents: [agent], projects: [project], chats: [chat], deleted: [])
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
            resolveWorkspace: { id in id == workspace.id ? workspace : nil })
        var removedProfile = false
        remote.onDelete = { kind, id, _ in
            XCTAssertEqual(kind, "agents")
            XCTAssertEqual(id, agent.id)
            removedProfile = true
            return .init(version: 1, workspaceId: "database", revision: 2, full: true,
                agents: [], projects: [project], chats: [], deleted: [])
        }
        let channel = ReadinessChannel(harness: "claude-code", running: false, configured: false)
        let session = DaemonSession(agentId: agent.id,
            transport: ExecDaemonTransport(channel: channel, agentType: "claude-code"))
        defer { DaemonWorkCoordinator.shared.forget(workspaceId: agent.id) }
        await session.load()
        XCTAssertEqual(session.phase, .needsAuth)

        await channel.setBusyChat(true)
        do {
            try await AgentManagement.remove(agent.id, session: session, stores: stores)
            XCTFail("A running native chat must prevent profile deletion")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Turn already running"), error.localizedDescription)
        }
        XCTAssertFalse(removedProfile)
        XCTAssertNotNil(stores.agents.get(agent.id))
        XCTAssertNotNil(stores.chats.get(chat.id))

        await channel.setBusyChat(false)
        try await AgentManagement.remove(agent.id, session: session, stores: stores)
        XCTAssertTrue(removedProfile)
        XCTAssertNil(stores.agents.get(agent.id))
        XCTAssertNil(stores.chats.get(chat.id))
        XCTAssertNotNil(stores.projects.get(project.id), "Removing an agent must preserve its projects")
        XCTAssertEqual(session.phase, .needsAuth, "Removing a profile must not need a harness login")
        let deletes = await channel.deletedChats
        XCTAssertEqual(deletes, [chat.id, chat.id])
    }

    func testNewProfileCanBeRemovedBeforeItsAuthenticationSessionExists() async throws {
        let stores = try stores()
        let workspace = Workspace(id: UUID().uuidString, name: "Workspace",
            runtime: .server(serverId: "fixture"), createdAt: isoNow())
        let agent = stores.createAgent(.init(name: "Builder", agentType: .claudeCode, workspaceId: workspace.id))
        let remote = WorkspaceRemoteFixture()
        remote.current = .init(version: 1, workspaceId: "database", revision: 1, full: true,
            agents: [agent], projects: [], chats: [], deleted: [])
        remote.onDelete = { _, _, _ in
            .init(version: 1, workspaceId: "database", revision: 2, full: true,
                  agents: [], projects: [], chats: [], deleted: [])
        }
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
            resolveWorkspace: { id in id == workspace.id ? workspace : nil })
        stores.preparation = PreparationQueue(stores: stores, canResolve: { _ in false }) { _ in
            XCTFail("Removing an unconfigured profile must not start its installation")
        }
        stores.preparation.enqueue(agent)
        try await AgentManagement.remove(agent.id, session: nil, stores: stores)
        XCTAssertNil(stores.agents.get(agent.id))
        XCTAssertFalse(stores.preparation.pendingIDs.contains(agent.id))
    }

    func testReadyAgentStaysVisibleDuringServiceChecksAndQueuedUpdateObservation() async throws {
        let workspaceId = UUID().uuidString
        let channel = ReadinessChannel(running: false, configured: true)
        let session = DaemonSession(agentId: "ready-agent",
            transport: ExecDaemonTransport(channel: channel, agentType: "codex"),
            workspaceId: workspaceId, agentType: "codex")
        let coordinator = DaemonWorkCoordinator.shared
        let key = DaemonWorkKey(workspaceId: workspaceId)
        defer { coordinator.forget(workspaceId: workspaceId) }
        await session.load()
        XCTAssertEqual(session.phase, .ready)
        try await coordinator.perform(key) { _ in
            XCTAssertEqual(session.phase, .ready, "A health check cannot replace the agent page")
        }
        try await coordinator.perform(key, activity: .updatingDaemon) { work in
            XCTAssertEqual(session.phase, .ready, "Checking whether an update can start isn't installation")
            work.receive(.downloading(0.25))
            XCTAssertEqual(session.phase, .checking, "Actual replacement progress still gates service actions")
            work.receive(.waiting)
            XCTAssertEqual(session.phase, .ready, "Waiting for automatic update must leave the page usable")
        }
        XCTAssertEqual(session.phase, .ready)
    }

    func testCachedReadyPersonasStayBlockedUntilCompletedJobPassesCLIVerification() async throws {
        let workspaceId = UUID().uuidString
        let channel = ReadinessChannel(running: false, configured: true)
        func session() -> DaemonSession {
            DaemonSession(agentId: UUID().uuidString,
                transport: ExecDaemonTransport(channel: channel, agentType: "codex"),
                workspaceId: workspaceId, agentType: "codex")
        }
        let builder = session(), reviewer = session()
        defer { DaemonWorkCoordinator.shared.forget(workspaceId: workspaceId) }
        await builder.load()
        await reviewer.load()
        XCTAssertEqual(builder.phase, .ready)
        XCTAssertEqual(reviewer.phase, .ready)

        await channel.startUpdate()
        // An external update is learned from the live job observer; navigation reuses its healthy
        // cache until that observation invalidates readiness for every persona.
        await DaemonWorkCoordinator.shared.refresh(.init(workspaceId: workspaceId, agentType: "codex"), interval: 0) {
            .setup(try await ExecDaemonTransport(channel: channel, agentType: "codex").setupStatus())
        }
        let reopen = Task { await builder.load() }
        try await eventually { builder.toolsWork?.running == true }
        XCTAssertEqual(builder.phase, .checking)
        XCTAssertEqual(reviewer.phase, .checking, "Cached auth in another persona cannot bypass a shared install")
        reopen.cancel()
        await channel.finish(holdVerification: true)
        try await eventually { await channel.waitingForInfo }
        XCTAssertEqual(builder.phase, .checking, "A terminal /setup response does not yet verify the CLI")
        XCTAssertEqual(reviewer.phase, .checking)
        await channel.releaseInfo()
        await reopen.value
        XCTAssertEqual(builder.phase, .ready)
        XCTAssertEqual(reviewer.phase, .ready)
        XCTAssertEqual(builder.toolsWork?.requiresVerification, false)
        let posts = await channel.setupPosts
        XCTAssertEqual(posts, 0)
    }

    func testCredentialsWithoutAnInstalledCLICannotUnlockTheAgent() async throws {
        let id = UUID().uuidString
        let channel = ReadinessChannel(running: false, configured: true, installedVersion: "")
        let session = DaemonSession(agentId: id, transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        defer { DaemonWorkCoordinator.shared.forget(workspaceId: id) }
        await session.load()
        XCTAssertTrue(session.isConfigured)
        guard case .unreachable = session.phase else { return XCTFail("Credentials do not install a CLI") }
        XCTAssertEqual(session.loadError, t("agentUpdates.verifyFailed"))
    }

    func testFailedRemoteInstallDoesNotExposeCachedAgentOptions() async throws {
        let id = UUID().uuidString
        let channel = ReadinessChannel(running: false, configured: true)
        let session = DaemonSession(agentId: id, transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        defer { DaemonWorkCoordinator.shared.forget(workspaceId: id) }
        await session.load()
        await channel.startUpdate()
        await DaemonWorkCoordinator.shared.refresh(.init(workspaceId: id, agentType: ""), interval: 0) {
            .setup(try await ExecDaemonTransport(channel: channel, agentType: "codex").setupStatus())
        }
        let reopen = Task { await session.load() }
        try await eventually { session.toolsWork?.running == true }
        await channel.fail()
        await reopen.value
        guard case .unreachable = session.phase else { return XCTFail("A failed update must remain a retry state") }
        XCTAssertTrue(session.toolsWork?.error?.contains("Installer unavailable") == true)
        await session.load()
        var posts = await channel.setupPosts
        XCTAssertEqual(posts, 0, "Reopening a failed job must not restart installation")
        await channel.allowRetry()
        await session.load(force: true)
        posts = await channel.setupPosts
        XCTAssertEqual(posts, 1, "Explicit Retry must start a new native job")
        XCTAssertEqual(session.phase, .ready)
        XCTAssertNil(session.loadError)
    }

    func testNativeStepPhasesDecodeWithoutInventingPercentageOrReadiness() throws {
        let state = DaemonWorkState()
        for stage in ["checking", "waiting", "installing", "resolving", "downloading", "configuring", "verifying"] {
            let data = Data("{\"ok\":false,\"running\":true,\"current\":\"codex\",\"steps\":[],\"stage\":\"\(stage)\"}".utf8)
            state.receive(try JSONDecoder().decode(DaemonSetupResult.self, from: data))
            XCTAssertEqual(state.message, t("agentUpdates.step.\(stage)", ["name": "codex"]))
            XCTAssertTrue(state.requiresVerification)
            XCTAssertEqual(state.progress, 0)
        }
        state.receive(.init(ok: true, running: false, started: true, steps: []))
        XCTAssertTrue(state.requiresVerification)
    }

    func testReopenedSessionUsesNativeStepProgressInsteadOfCompletedServiceDownload() async throws {
        let id = UUID().uuidString
        let coordinator = DaemonWorkCoordinator.shared
        defer { coordinator.forget(workspaceId: id) }
        let serviceKey = DaemonWorkKey(workspaceId: id)
        coordinator.recordHealth(.init(ok: true), for: serviceKey)
        coordinator.states[serviceKey]?.progress = 1
        let toolsKey = DaemonWorkKey(workspaceId: id, agentType: "codex")
        let data = Data(#"{"ok":false,"running":true,"started":true,"operation":"setup","current":"codex","stage":"downloading","plan":["git","node","codex"],"steps":[{"name":"git","status":"satisfied"},{"name":"node","status":"installed"}],"startedAt":"2026-09-23T12:00:00.123456Z"}"#.utf8)
        await coordinator.refresh(toolsKey, interval: 0) {
            .setup(try JSONDecoder().decode(DaemonSetupResult.self, from: data))
        }
        let channel = ReadinessChannel(running: true, configured: false)
        let session = DaemonSession(agentId: "reopened", transport: ExecDaemonTransport(channel: channel, agentType: "codex"),
                                    workspaceId: id, agentType: "codex")
        XCTAssertEqual(session.preparationProgress, 2.0 / 3.0)
        XCTAssertEqual(session.preparationPlan, ["git", "node", "codex"])
        XCTAssertEqual(session.preparationCurrentStep, "codex")
        XCTAssertNotNil(session.preparationStartedAt)
        XCTAssertEqual(session.phase, .checking)

        // Older services have no plan. Their ongoing CLI install must remain indeterminate.
        coordinator.states[toolsKey]?.receive(.init(ok: false, running: true, started: true,
            current: "codex", steps: [], operation: "setup", stage: "installing"))
        XCTAssertNil(session.preparationProgress)
        XCTAssertNil(session.preparationStartedAt)
        XCTAssertEqual(session.phase, .checking)
    }
}

@MainActor
enum AgentManagementTestUI {
    static func button(in controller: UIViewController, file: StaticString = #filePath, line: UInt = #line) throws -> UIButton {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let bars = descendants(controller.view).compactMap { $0 as? UINavigationBar }
        let buttons = bars.flatMap(descendants).compactMap { $0 as? UIButton }
        let button = try XCTUnwrap(buttons.first { $0.menu != nil },
            "Missing agent management button: \(buttons)", file: file, line: line)
        XCTAssertTrue(button.isEnabled, "Management must not require authentication", file: file, line: line)
        XCTAssertNotNil(button.window, file: file, line: line)
        return button
    }

    static func actions(in menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element -> [UIAction] in
            if let submenu = element as? UIMenu { return actions(in: submenu) }
            return (element as? UIAction).map { [$0] } ?? []
        }
    }

    static func alert(in controller: UIViewController) -> UIAlertController? {
        if let alert = controller as? UIAlertController { return alert }
        if let presented = controller.presentedViewController, let alert = alert(in: presented) { return alert }
        return controller.children.compactMap { alert(in: $0) }.first
    }
}

private actor ReadinessChannel: DaemonChannel {
    nonisolated let label = "agent-readiness-fixture"
    private let harness: String
    private var running: Bool
    private var configured: Bool
    private var installedVersion: String
    private var operation = "setup"
    private var stage = "installing"
    private var current = "node"
    private let startedAt = isoNow()
    private var failed = false
    private var holdInfo = false
    private var infoGate: CheckedContinuation<Void, Never>?
    private(set) var setupPosts = 0
    private var retrySucceeds = false
    private(set) var infoReads = 0
    private var busyChat = false
    private(set) var deletedChats: [String] = []
    var waitingForInfo: Bool { infoGate != nil }

    init(harness: String = "codex", running: Bool, configured: Bool, installedVersion: String = "1.2.3") {
        self.harness = harness
        self.running = running
        self.configured = configured
        self.installedVersion = installedVersion
    }

    func advance(stage: String) { self.stage = stage; current = harness }
    func startUpdate() { running = true; operation = "update" }
    func finish(holdVerification: Bool = false) { running = false; holdInfo = holdVerification }
    func fail() { running = false; failed = true }
    func allowRetry() { retrySucceeds = true }
    func setBusyChat(_ busy: Bool) { busyChat = busy }
    func releaseInfo() { holdInfo = false; infoGate?.resume(); infoGate = nil }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        if method == "DELETE", path.hasPrefix("/chats/") {
            deletedChats.append(String(path.dropFirst("/chats/".count).prefix { $0 != "?" }))
            return busyChat ? (409, #"{"error":"Turn already running"}"#) : (200, "{}")
        }
        if path == "/setup?agent=\(harness)" {
            if method == "POST" {
                setupPosts += 1
                if retrySucceeds { failed = false; running = false }
            }
            let plan = ["git", "node", harness]
            let done = running ? Array(plan.prefix(current == "node" ? 1 : 2)) : plan
            let status = DaemonSetupResult(ok: !running && !failed, running: running, started: true,
                current: current, steps: failed ? [.init(name: harness, status: "failed", output: "Installer unavailable")] :
                    done.map { .init(name: $0, status: "satisfied") },
                operation: operation, stage: stage, plan: plan, startedAt: startedAt)
            return (200, String(decoding: try JSONEncoder().encode(status), as: UTF8.self))
        }
        if path == "/agent?agent=\(harness)" {
            infoReads += 1
            if holdInfo { await withCheckedContinuation { infoGate = $0 } }
            let methods = try JSONDecoder().decode([DaemonAuthMethod].self, from: Data(#"[{"id":"apiKey","label":"API key","fields":[{"key":"apiKey","label":"API key","type":"secret"}]},{"id":"login","label":"Sign in","interactive":true}]"#.utf8))
            var info = DaemonAgentInfo(version: "0.1.16", agentType: harness, name: harness, schema: .empty,
                installedVersion: installedVersion, configured: configured, authMethods: methods,
                authStatus: .init(configured: configured))
            info.software = .fixture(installed: installedVersion)
            return (200, String(decoding: try JSONEncoder().encode(info), as: UTF8.self))
        }
        if method == "POST", path == "/auth/step?agent=\(harness)" {
            configured = true
            return (200, #"{"method":"apiKey","status":"complete"}"#)
        }
        if path == "/chats?agent=\(harness)" { return (200, "[]") }
        throw URLError(.unsupportedURL)
    }
}
