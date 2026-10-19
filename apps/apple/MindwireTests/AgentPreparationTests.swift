import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class AgentPreparationTests: XCTestCase {
    private let workspace = Workspace(id: "setup-workspace", name: "Workspace",
        runtime: .server(serverId: "fixture"), createdAt: "2026-09-16T00:00:00Z")

    private func stores() throws -> Stores {
        let suite = "agent-preparation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Preparation did not reach the expected state")
    }

    private func queue(_ stores: Stores, channel: InstallationChannel,
                       coordinator: DaemonWorkCoordinator) -> PreparationQueue {
        PreparationQueue(stores: stores, canResolve: { _ in true }) { agent in
            let key = DaemonWorkKey(workspaceId: agent.workspaceId!, agentType: agent.agentType.rawValue)
            try await coordinator.perform(key) { work in
                try await AgentInstallation.ensure(
                    transport: ExecDaemonTransport(channel: channel, agentType: agent.agentType.rawValue), work: work)
            }
        }
    }

    private func remote(in stores: Stores) -> WorkspaceRemoteFixture {
        let remote = WorkspaceRemoteFixture()
        remote.onPut = { [weak remote] kind, _, data, _ in
            let remote = try XCTUnwrap(remote)
            XCTAssertEqual(kind, "agents")
            var agent = try JSONDecoder().decode(Agent.self, from: data)
            agent.revision = remote.current.revision + 1
            remote.current = .init(version: 1, workspaceId: "database", revision: agent.revision!, full: true,
                agents: remote.current.agents + [agent], projects: [], chats: [], deleted: [])
            return remote.current
        }
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
            resolveWorkspace: { [workspace] id in id == workspace.id ? workspace : nil })
        return remote
    }

    func testCreateStartsInstallationWithoutOpeningAgentAndRepeatedCreationJoinsIt() async throws {
        let stores = try stores()
        _ = remote(in: stores)
        let channel = InstallationChannel()
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let queue = queue(stores, channel: channel, coordinator: coordinator)
        stores.preparation = queue
        let model = NewAgentModel(workspaceId: workspace.id, agentType: .codex)
        model.name = "Builder"
        let agent = try await model.create(stores: stores)
        XCTAssertEqual(model.createdAgent, agent, "Creation must continue to the connection screen")
        let key = DaemonWorkKey(workspaceId: workspace.id, agentType: "codex")
        XCTAssertEqual(stores.agents.get(agent.id), agent, "Create returns the saved profile while setup continues")
        XCTAssertTrue(queue.pendingIDs.contains(agent.id))
        try await eventually { coordinator.states[key]?.message == "node" }
        XCTAssertEqual(coordinator.states[key]?.activity, .installingTools)

        model.name = "Reviewer"
        let other = try await model.create(stores: stores)
        XCTAssertEqual(other.id, agent.id, "The same workspace and coding tool reuse their existing profile")
        XCTAssertTrue(queue.pendingIDs.contains(other.id))
        let reopened = Task {
            try await coordinator.perform(key) { work in
                try await AgentInstallation.ensure(
                    transport: ExecDaemonTransport(channel: channel, agentType: "codex"), work: work)
            }
        }
        reopened.cancel() // Leaving the new profile must not cancel workspace preparation.
        await channel.advance(to: "codex")
        try await eventually { coordinator.states[key]?.message == "codex" }
        XCTAssertEqual(coordinator.states[key]?.steps.first?.name, "node")
        await channel.finish()
        try await reopened.value
        try await eventually { queue.active.isEmpty }
        let posts = await channel.posts
        XCTAssertEqual(posts, 1, "Repeated creation and reopening must share one /setup")
        XCTAssertTrue(queue.pendingIDs.isEmpty)
        XCTAssertEqual(stores.agents.list().count, 1)
        XCTAssertEqual(coordinator.states[key]?.installedVersion, "1.2.3")
        XCTAssertEqual(coordinator.states[key]?.running, false)
        XCTAssertNil(coordinator.states[key]?.error)
    }

    func testUnavailableComputerCannotUnlockOnboardingOrCreateAnAgent() async throws {
        for failure: Error in [URLError(.notConnectedToInternet), URLError(.cannotConnectToHost),
                               WorkspaceRegistryError.updateRequired] {
            let stores = try stores()
            let remote = remote(in: stores)
            remote.prepareError = failure
            let preparation = AssistantComputerPreparation()
            let ready = await preparation.prepare(workspace.id) {
                try await stores.workspaceData.prepareDaemon(workspaceId: $0)
            }
            XCTAssertFalse(ready)
            XCTAssertNil(preparation.readyWorkspaceID)
            XCTAssertNotNil(preparation.error)
            let model = NewAgentModel(workspaceId: workspace.id, agentType: .codex)
            do {
                _ = try await model.create(stores: stores)
                XCTFail("An unavailable computer must not accept a new profile")
            } catch {}
            XCTAssertNil(model.createdAgent)
            XCTAssertTrue(stores.agents.list().isEmpty)
            XCTAssertTrue(stores.projects.list().isEmpty)
            XCTAssertTrue(stores.chats.list().isEmpty)
            XCTAssertTrue(stores.preparation.pendingIDs.isEmpty)
            XCTAssertTrue(remote.putIDs.isEmpty)
            XCTAssertTrue(remote.imports.isEmpty)
        }
    }

    func testOnboardingWaitsForAuthoritativeSyncAndRetryReusesTheComputer() async throws {
        let stores = try stores()
        let remote = remote(in: stores)
        remote.snapshotError = URLError(.networkConnectionLost)
        let preparation = AssistantComputerPreparation()
        let failed = await preparation.prepare(workspace.id) {
            try await stores.workspaceData.prepareDaemon(workspaceId: $0)
        }
        XCTAssertFalse(failed, "A healthy service with a failed workspace sync is not ready")
        XCTAssertNotNil(preparation.error)
        XCTAssertTrue(stores.agents.list().isEmpty)
        remote.snapshotError = nil
        remote.holdSnapshot = true
        let retry = Task {
            await preparation.prepare(workspace.id) {
                try await stores.workspaceData.prepareDaemon(workspaceId: $0)
            }
        }
        try await eventually { remote.snapshotGate != nil }
        XCTAssertNil(preparation.readyWorkspaceID, "Accounts stay locked while synchronization is in flight")
        XCTAssertNil(preparation.error)
        remote.releaseSnapshot()
        let ready = await retry.value
        XCTAssertTrue(ready)
        XCTAssertEqual(preparation.readyWorkspaceID, workspace.id)
        XCTAssertNil(stores.workspaceData.errors[workspace.id])
        XCTAssertTrue(remote.prepareAllowInstall.allSatisfy { $0 })
        XCTAssertTrue(remote.putIDs.isEmpty, "Preparing a computer alone creates no profiles or chats")
        XCTAssertTrue(stores.agents.list().isEmpty)
        XCTAssertTrue(stores.chats.list().isEmpty)
    }

    func testLeavingOrChangingComputerDiscardsLatePreparation() async throws {
        let preparation = AssistantComputerPreparation()
        var finish: CheckedContinuation<Void, Never>?
        let oldComputer = Task {
            await preparation.prepare("old") { _ in
                await withCheckedContinuation { finish = $0 }
            }
        }
        try await eventually { finish != nil }
        preparation.reset()
        let newReady = await preparation.prepare("new") { _ in }
        XCTAssertTrue(newReady)
        finish?.resume()
        let oldReady = await oldComputer.value
        XCTAssertFalse(oldReady)
        XCTAssertEqual(preparation.readyWorkspaceID, "new")
        XCTAssertNil(preparation.error)
    }

    func testOfflineOrOutdatedDaemonCannotCreateLocalOnlyChats() async throws {
        for failure: Error in [URLError(.cannotConnectToHost), WorkspaceRegistryError.updateRequired] {
            let stores = try stores()
            let remote = remote(in: stores)
            let agent = stores.createAgent(.init(name: "Existing", agentType: .codex, workspaceId: workspace.id))
            let project = stores.createProject(.init(name: "Existing", workspaceId: workspace.id, path: "/work"))
            remote.prepareError = failure
            do {
                _ = try await stores.workspaceData.createChat(agentId: agent.id, projectId: project.id)
                XCTFail("An unavailable service must not create a local-only chat")
            } catch {}
            XCTAssertTrue(stores.chats.list().isEmpty)
            XCTAssertEqual(stores.agents.list().count, 1)
            XCTAssertEqual(stores.projects.list().count, 1)
            XCTAssertTrue(remote.putIDs.isEmpty)
        }
    }

    func testAlreadyInstalledCodexAndClaudeSkipSetupWithoutRequiringAuthentication() async throws {
        for harness in ["codex", "claude-code"] {
            let channel = InstallationChannel(harness: harness, installedVersion: "1.2.3")
            let work = DaemonWorkState()
            try await AgentInstallation.ensure(
                transport: ExecDaemonTransport(channel: channel, agentType: harness), work: work)
            let posts = await channel.posts
            XCTAssertEqual(posts, 0)
            XCTAssertEqual(work.installedVersion, "1.2.3")
        }
    }

    func testOldDaemonCanReuseCLIButCannotStartAnUnrestrictedFreshInstall() async throws {
        for installed in ["", "1.2.3"] {
            let channel = InstallationChannel(installedVersion: installed, supportsPolicy: false)
            let transport = ExecDaemonTransport(channel: channel, agentType: "codex")
            do {
                try await AgentInstallation.ensure(transport: transport, work: DaemonWorkState())
                XCTAssertFalse(installed.isEmpty)
            } catch {
                XCTAssertTrue(installed.isEmpty)
                XCTAssertEqual(error.localizedDescription, t("agentUpdates.policyRequired"))
            }
            let posts = await channel.posts
            XCTAssertEqual(posts, 0)
        }
    }

    func testRelaunchResumesPendingRequestByJoiningServiceJobWithoutPostingAgain() async throws {
        let stores = try stores()
        let agent = stores.createAgent(.init(name: "Claude", agentType: .claudeCode, workspaceId: workspace.id))
        let first = PreparationQueue(stores: stores, canResolve: { _ in false }) { _ in
            XCTFail("An unavailable workspace must not start setup")
        }
        first.enqueue(agent)
        let channel = InstallationChannel(harness: "claude-code", alreadyRunning: true)
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let relaunched = queue(stores, channel: channel, coordinator: coordinator)
        XCTAssertEqual(relaunched.pendingIDs, [agent.id])
        XCTAssertTrue(relaunched.active.isEmpty, "Persisted intent is not a claim that the service is running")
        relaunched.resume()
        let key = DaemonWorkKey(workspaceId: workspace.id, agentType: "claude-code")
        try await eventually { coordinator.states[key]?.message == "node" }
        await channel.finish()
        try await eventually { relaunched.active.isEmpty }
        XCTAssertTrue(relaunched.pendingIDs.isEmpty)
        let posts = await channel.posts
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(coordinator.states[key]?.installedVersion, "1.2.3")
        let nextLaunch = queue(stores, channel: channel, coordinator: coordinator)
        XCTAssertTrue(nextLaunch.pendingIDs.isEmpty)
    }

    func testFailedInstallKeepsProfileButOnlyExplicitRetryRestartsIt() async throws {
        let stores = try stores()
        let agent = stores.createAgent(.init(name: "Codex", agentType: .codex, workspaceId: workspace.id))
        let channel = InstallationChannel(failInstall: true)
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let first = queue(stores, channel: channel, coordinator: coordinator)
        first.enqueue(agent)
        try await eventually { first.active.isEmpty }
        let key = DaemonWorkKey(workspaceId: workspace.id, agentType: "codex")
        XCTAssertNotNil(stores.agents.get(agent.id))
        XCTAssertTrue(first.pendingIDs.isEmpty)
        XCTAssertTrue(coordinator.states[key]?.error?.contains("Registry unavailable") == true)
        XCTAssertEqual(coordinator.states[key]?.running, false)

        await channel.allowRetry()
        first.resume()
        let relaunched = queue(stores, channel: channel, coordinator: coordinator)
        relaunched.resume()
        XCTAssertTrue(relaunched.pendingIDs.isEmpty)
        let beforeRetry = await channel.posts
        XCTAssertEqual(beforeRetry, 1, "Foreground/relaunch must not retry a failed installation")
        relaunched.enqueue(agent)
        try await eventually { coordinator.states[key]?.message == "node" }
        await channel.finish()
        try await eventually { relaunched.active.isEmpty }
        XCTAssertNil(coordinator.states[key]?.error)
        XCTAssertTrue(relaunched.pendingIDs.isEmpty)
        let posts = await channel.posts
        XCTAssertEqual(posts, 2)
    }

    func testFailedAgentCheckDoesNotSilentlySucceedOrPostSetup() async throws {
        let channel = InstallationChannel(failInfo: true)
        let work = DaemonWorkState()
        do {
            try await AgentInstallation.ensure(
                transport: ExecDaemonTransport(channel: channel, agentType: "codex"), work: work)
            XCTFail("A failed CLI check must not be marked ready")
        } catch { XCTAssertNil(work.installedVersion) }
        let posts = await channel.posts
        XCTAssertEqual(posts, 0)
    }

    func testSuccessfulSetupResponseStillRequiresAnInstalledExecutable() async throws {
        let channel = InstallationChannel(alreadyRunning: true)
        let work = DaemonWorkState()
        let task = Task {
            try await AgentInstallation.ensure(
                transport: ExecDaemonTransport(channel: channel, agentType: "codex"), work: work)
        }
        try await eventually { work.message == "node" }
        await channel.finish(installedVersion: "")
        do { try await task.value; XCTFail("An ok setup response without a CLI must fail verification") }
        catch { XCTAssertEqual(error.localizedDescription, t("agentUpdates.verifyFailed")) }
        XCTAssertNil(work.installedVersion)
    }

    func testFailedProfileCreationNeverInstallsAndDeletedProfilesAreNotResumed() async throws {
        let stores = try stores()
        let remote = remote(in: stores)
        stores.preparation = PreparationQueue(stores: stores, canResolve: { _ in false }) { _ in
            XCTFail("No installation was requested")
        }
        remote.prepareError = URLError(.notConnectedToInternet)
        let model = NewAgentModel(workspaceId: workspace.id)
        do { _ = try await model.create(stores: stores); XCTFail("An offline create must fail") } catch {}
        XCTAssertNil(model.createdAgent)
        XCTAssertTrue(stores.preparation.pendingIDs.isEmpty)
        remote.prepareError = nil
        let agent = try await model.create(stores: stores)
        XCTAssertTrue(stores.preparation.pendingIDs.contains(agent.id))
        remote.current = .init(version: 1, workspaceId: "database", revision: remote.current.revision + 1,
            full: true, agents: [], projects: [], chats: [], deleted: [])
        try await stores.workspaceData.removeAgent(agent.id)
        XCTAssertTrue(stores.preparation.pendingIDs.isEmpty)
        let relaunched = PreparationQueue(stores: stores)
        XCTAssertTrue(relaunched.pendingIDs.isEmpty)
    }

    func testWorkspaceDeletionForgetsPendingInstallEvenAfterItsCacheWasPruned() throws {
        let stores = try stores()
        let agent = stores.createAgent(.init(name: "Codex", agentType: .codex, workspaceId: workspace.id))
        stores.preparation = PreparationQueue(stores: stores, canResolve: { _ in false })
        stores.preparation.enqueue(agent)
        stores.cascadeProjects(forWorkspaceId: workspace.id)
        stores.workspaceData.forget(workspace.id)
        XCTAssertTrue(stores.preparation.pendingIDs.isEmpty)
    }

    func testAgentRowKeepsInstallationCompactAndClearsStatusAfterCompletion() async throws {
        let stores = try stores()
        let agent = stores.createAgent(.init(name: "App builder", agentType: .codex,
                                            workspaceId: UUID().uuidString, catalogName: "Codex"))
        let key = DaemonWorkKey(workspaceId: agent.workspaceId!, agentType: "codex")
        let coordinator = DaemonWorkCoordinator.shared
        defer { coordinator.forget(workspaceId: key.workspaceId) }
        await coordinator.refresh(key, interval: 0) {
            .setup(.init(ok: false, running: true, started: true, current: "codex",
                         steps: [.init(name: "node", status: "installed")], operation: "setup"))
        }
        let host = UIHostingController(rootView: NavigationStack {
            List {
                EntityRow {
                    Text(agent.displayName)
                } subtitle: {
                    Text(agent.typeDisplayName)
                } icon: {
                    AgentLogo(id: agent.agentType, size: 22)
                } accessory: {
                    AgentRowStatus(agent: agent)
                }
            }
            .navigationTitle("Agents")
        }.environment(\.stores, stores).environment(\.scenePhase, .inactive))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let image = ChatFeedSnapshot.image(host)
        let text = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertFalse(text.contains("Installing agent"), text)
        XCTAssertTrue(text.contains("App builder"), text)
        XCTAssertTrue(text.lowercased().contains("codex"), text)
        let attachment = XCTAttachment(image: image)
        attachment.name = "mindwire-agent-install-row"
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mindwire-agent-install-row.png")
        try image.pngData()?.write(to: path)
        print("AGENT_SETUP_SNAPSHOT_PATH=\(path.path)")

        await coordinator.refresh(key, interval: 0) {
            .setup(.init(ok: true, running: false, started: true,
                         steps: [.init(name: "codex", status: "installed")], operation: "setup"))
        }
        try await Task.sleep(for: .milliseconds(100))
        let finished = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertFalse(finished.contains("Installing agent"), finished)
        XCTAssertTrue(finished.contains("App builder"), finished)
    }
}

/// Exercises the real scoped HTTP transport and decoding, including the service's 202 response.
private actor InstallationChannel: DaemonChannel {
    nonisolated let label = "agent-installation-fixture"
    let harness: String
    private var installedVersion: String
    private var running: Bool
    private var started: Bool
    private var failInstall: Bool
    private let failInfo: Bool
    private let supportsPolicy: Bool
    private var current = "node"
    private var steps: [DaemonStepResult] = []
    private(set) var posts = 0

    init(harness: String = "codex", installedVersion: String = "", alreadyRunning: Bool = false,
         failInstall: Bool = false, failInfo: Bool = false, supportsPolicy: Bool = true) {
        self.harness = harness
        self.installedVersion = installedVersion
        self.running = alreadyRunning
        self.started = alreadyRunning
        self.failInstall = failInstall
        self.failInfo = failInfo
        self.supportsPolicy = supportsPolicy
    }

    func advance(to step: String) {
        steps.append(.init(name: current, status: "installed"))
        current = step
    }

    func finish(installedVersion: String = "1.2.3") {
        self.installedVersion = installedVersion
        running = false
        steps.append(.init(name: current, status: "installed"))
        current = ""
    }

    func allowRetry() { failInstall = false; started = false; steps = []; current = "node" }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        if method == "GET", path == "/agent?agent=\(harness)" {
            if failInfo { throw URLError(.networkConnectionLost) }
            var info = DaemonAgentInfo(version: "0.1.16", agentType: harness, name: harness,
                schema: .empty, installedVersion: installedVersion, configured: false)
            if supportsPolicy { info.software = .fixture(installed: installedVersion) }
            return (200, String(decoding: try JSONEncoder().encode(info), as: UTF8.self))
        }
        guard path == "/setup?agent=\(harness)" else { throw URLError(.unsupportedURL) }
        if method == "POST" {
            posts += 1
            started = true
            running = !failInstall
            if failInstall { steps = [.init(name: harness, status: "failed", output: "Registry unavailable")] }
        }
        let status = DaemonSetupResult(ok: started && !running && !failInstall, running: running,
            started: started, current: running ? current : "", steps: steps, operation: started ? "setup" : nil)
        return (method == "POST" ? 202 : 200, String(decoding: try JSONEncoder().encode(status), as: UTF8.self))
    }
}
