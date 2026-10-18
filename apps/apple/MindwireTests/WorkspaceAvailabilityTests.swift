import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class WorkspaceAvailabilityTests: XCTestCase {
    private func stores() throws -> Stores {
        let suite = "workspace-availability-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func workspace() -> Workspace {
        Workspace(id: "workspace", name: "Test workspace", runtime: .server(serverId: "missing-connection"),
                  spec: nil, createdAt: "2026-09-16T00:00:00Z", lastUsedAt: nil)
    }

    private func project(in stores: Stores) -> Project {
        stores.createProject(.init(name: "Test project", workspaceId: "workspace", path: "/projects/demo"))
    }

    func testAgentsDisappearOnCloudSignOutWithoutDeletingTheirNativeReferences() async throws {
        let stores = try stores()
        let cloudAgent = stores.createAgent(.init(name: "Cloud coding", agentType: .codex, workspaceId: "workspace"))
        let cloudProject = project(in: stores)
        let chat = stores.createChat(agentId: cloudAgent.id, projectId: cloudProject.id)
        let local = stores.createWorkspace(name: "Personal Mac", runtime: .server(serverId: "local-fixture"))
        let localAgent = stores.createAgent(.init(name: "Local coding", agentType: .claudeCode, workspaceId: local.id))
        let orphan = Agent(id: "old-orphan", name: "Old orphan", agentType: .codex, workspaceId: nil, createdAt: cloudAgent.createdAt)
        stores.agents.save(orphan)
        var status = AuthStatus(authenticated: true, user: AuthUser(id: "42", name: "Owner"))
        let auth = MindwireAuth { status }
        await auth.refresh()
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [workspace()])
        adapter.auth = auth
        let repository = WorkspaceRepository(stores: stores, adapters: [LocalWorkspaceAdapter(stores: stores), adapter])
        await repository.refresh()
        XCTAssertEqual(Set(repository.agents().map(\.id)), [cloudAgent.id, localAgent.id])

        let (view, window) = host(AgentsListScreen(repository: repository), stores: stores)
        defer { window.isHidden = true }
        let before = try await visibleText(view)
        XCTAssertTrue(before.contains("Cloud coding"), before)
        XCTAssertTrue(before.contains("Local coding"), before)
        XCTAssertFalse(before.contains("Old orphan"), before)

        // Sign-out must remove the card immediately, without waiting for a network refresh.
        status = AuthStatus(authenticated: false)
        await auth.refresh()
        let signedOut = try await visibleText(view)
        XCTAssertFalse(signedOut.contains("Cloud coding"), signedOut)
        XCTAssertTrue(signedOut.contains("Local coding"), signedOut)
        XCTAssertFalse(signedOut.contains(t("agent.noWorkspace")), signedOut)
        XCTAssertEqual(repository.agents().map(\.id), [localAgent.id])
        XCTAssertNotNil(stores.agents.get(cloudAgent.id))
        XCTAssertNotNil(stores.chats.get(chat.id))

        status = AuthStatus(authenticated: true, user: AuthUser(id: "42", name: "Owner"))
        await auth.refresh()
        adapter.failRefresh = true
        await repository.refresh()
        XCTAssertEqual(Set(repository.agents().map(\.id)), [cloudAgent.id, localAgent.id], "An outage retains the signed-in account's cached inventory")
        let restored = try await visibleText(view)
        XCTAssertTrue(restored.contains("Cloud coding"), restored)
    }

    func testUninstalledHarnessKeepsHistoryAndExplicitSetupCanShowItAgain() throws {
        let stores = try stores()
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [workspace()])
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        var agent = stores.createAgent(.init(name: "Codex", agentType: .codex, workspaceId: "workspace"))
        let project = project(in: stores)
        let chat = stores.createChat(agentId: agent.id, projectId: project.id)
        agent.installation = "installed"
        stores.agents.save(agent)
        XCTAssertEqual(repository.agents().map(\.id), [agent.id])
        agent.installation = "missing"
        stores.agents.save(agent)
        XCTAssertTrue(repository.agents().isEmpty)
        XCTAssertTrue(stores.agents(forProjectId: project.id).isEmpty)
        XCTAssertNotNil(stores.agents.get(agent.id))
        XCTAssertNotNil(stores.chats.get(chat.id))
        stores.preparation.enqueue(agent)
        XCTAssertEqual(repository.agents().map(\.id), [agent.id], "An explicitly requested setup stays visible")
        stores.preparation.forget(agentId: agent.id)
        agent.installation = "repair"
        stores.agents.save(agent)
        XCTAssertEqual(repository.agents().map(\.id), [agent.id], "A broken managed CLI must remain accessible for repair")
    }

    func testFailedRefreshPreservesCacheAndRecordsThenRetryReconcilesExternalDeletion() async throws {
        let stores = try stores()
        let project = project(in: stores)
        let chat = stores.createChat(agentId: "agent", projectId: project.id)
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [workspace()])
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        adapter.remote = []
        adapter.failRefresh = true
        await repository.refresh()
        XCTAssertNotNil(repository.get("workspace"), "An offline refresh must preserve the last good workspace list")
        XCTAssertNotNil(repository.refreshError)
        XCTAssertNotNil(stores.projects.get(project.id))
        XCTAssertNotNil(stores.chats.get(chat.id))

        adapter.failRefresh = false
        await repository.refresh()
        XCTAssertNil(repository.get("workspace"))
        XCTAssertNil(repository.refreshError)
        XCTAssertNotNil(stores.projects.get(project.id), "List absence alone is not proof of deletion")
        XCTAssertNotNil(stores.chats.get(chat.id))

        adapter.remote = [workspace()]
        await repository.refresh()
        XCTAssertNotNil(repository.get("workspace"), "Retry must restore a workspace when access returns")
    }

    func testFailedWorkspaceDeleteKeepsLinkedDataUntilAcknowledged() async throws {
        let stores = try stores()
        let project = project(in: stores)
        let chat = stores.createChat(agentId: "agent", projectId: project.id)
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [workspace()])
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        adapter.failDelete = true
        do { try await repository.delete("workspace"); XCTFail("Expected failed delete") } catch {}
        XCTAssertNotNil(repository.get("workspace"))
        XCTAssertNotNil(stores.projects.get(project.id))
        XCTAssertNotNil(stores.chats.get(chat.id))

        adapter.failDelete = false
        try await repository.delete("workspace")
        XCTAssertNil(repository.get("workspace"))
        XCTAssertNil(stores.projects.get(project.id))
        XCTAssertNil(stores.chats.get(chat.id))
    }

    func testAuthoritativeExternalDeletionPrunesCachedAgentsProjectsAndChats() async throws {
        let stores = try stores()
        let project = project(in: stores)
        let agent = stores.createAgent(.init(name: "Codex", agentType: .codex, workspaceId: "workspace"))
        let chat = stores.createChat(agentId: agent.id, projectId: project.id)
        let other = stores.createProject(.init(name: "Keep", workspaceId: "other", path: "/keep"))
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [workspace()])
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        adapter.remote = []
        await repository.refresh()
        XCTAssertNotNil(stores.agents.get(agent.id), "An unavailable or filtered workspace is retained")
        adapter.deletedIDs = ["workspace"]
        await repository.refresh()
        XCTAssertNil(stores.agents.get(agent.id))
        XCTAssertNil(stores.projects.get(project.id))
        XCTAssertNil(stores.chats.get(chat.id))
        XCTAssertEqual(stores.projects.get(other.id), other)
    }

    func testConcurrentRefreshesShareOneRequest() async throws {
        let stores = try stores()
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [])
        adapter.holdRefresh = true
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        let first = Task { await repository.refresh() }
        try await waitForRefresh(adapter)
        let second = Task { await repository.refresh() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(repository.isRefreshing)
        XCTAssertFalse(repository.hasRefreshed)
        XCTAssertEqual(adapter.refreshCalls, 1)
        adapter.releaseRefresh()
        await first.value
        await second.value
        XCTAssertEqual(adapter.refreshCalls, 1)
        XCTAssertEqual(repository.revision, 1)
        XCTAssertTrue(repository.hasRefreshed)
        XCTAssertFalse(repository.isRefreshing)
    }

    func testNavigationReusesSuccessfulInventoryWhileManualRefreshAndExpiryCheckAgain() async throws {
        let stores = try stores()
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [])
        var now = Date()
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter], now: { now })
        await repository.refreshIfNeeded()
        await repository.refreshIfNeeded()
        XCTAssertEqual(adapter.refreshCalls, 1)
        XCTAssertFalse(repository.isRefreshing)

        await repository.refresh()
        XCTAssertEqual(adapter.refreshCalls, 2, "Pull-to-refresh must bypass a recent success")
        now.addTimeInterval(61)
        adapter.holdRefresh = true
        let background = Task { await repository.refreshIfNeeded() }
        try await waitForRefresh(adapter)
        XCTAssertEqual(adapter.refreshCalls, 3)
        XCTAssertFalse(repository.isRefreshing, "Periodic checks preserve the ready UI")
        adapter.releaseRefresh()
        await background.value
    }

    func testFailedInventoryCheckHasShortCooldownButExplicitRetryNeverWaits() async throws {
        let stores = try stores()
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [])
        adapter.failRefresh = true
        var now = Date()
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter], now: { now })
        await repository.refreshIfNeeded()
        await repository.refreshIfNeeded()
        XCTAssertEqual(adapter.refreshCalls, 1)
        XCTAssertNotNil(repository.refreshError)
        now.addTimeInterval(11)
        await repository.refreshIfNeeded()
        XCTAssertEqual(adapter.refreshCalls, 2)
        adapter.failRefresh = false
        await repository.refresh()
        XCTAssertEqual(adapter.refreshCalls, 3)
        XCTAssertNil(repository.refreshError)
    }

    func testWorkspaceControlModelSurvivesNavigationButNotWorkspaceDeletion() async throws {
        let stores = try stores()
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [workspace()])
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        let first = repository.model(for: workspace())
        let reopened = repository.model(for: workspace())
        XCTAssertTrue(first === reopened, "Two routes share the same backend and cached status")
        stores.connections.save(.local(.init(id: "missing-connection", name: "Connected Mac", deviceName: "Mac",
                                             pairingId: "fixture", createdAt: workspace().createdAt)))
        XCTAssertFalse(first === repository.model(for: workspace()), "Changed connection inputs invalidate the model")
        try await repository.delete(workspace().id)
        XCTAssertFalse(first === repository.model(for: workspace()), "A removed workspace cannot retain a live model")
    }

    func testOpenProjectReplacesStaleToolsWithRecoveryAfterWorkspaceDisappears() async throws {
        let stores = try stores()
        let project = project(in: stores)
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [workspace()])
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        // Settle the initial inventory before simulating an external deletion.
        await repository.refresh()
        let (host, window) = host(ProjectDetailScreen(projectId: project.id, repository: repository), stores: stores)
        defer { window.isHidden = true }
        let before = try await visibleText(host)
        XCTAssertTrue(before.contains("Source Control"), before)

        adapter.remote = []
        await repository.refresh()
        let after = try await visibleText(host, snapshot: "mindwire-workspace-unavailable")
        XCTAssertTrue(after.contains("Workspace unavailable"), after)
        XCTAssertTrue(after.contains("Retry"), after)
        XCTAssertTrue(after.contains("View workspaces"), after)
        XCTAssertTrue(after.contains(t("project.removeFromProjects")), after)
        XCTAssertFalse(after.contains("Source Control"), after)
        XCTAssertNotNil(stores.projects.get(project.id))

        adapter.remote = [workspace()]
        await repository.refresh()
        let restored = try await visibleText(host)
        XCTAssertTrue(restored.contains("Source Control"), restored)
        XCTAssertFalse(restored.contains("Workspace unavailable"), restored)
    }

    func testColdProjectWaitsForWorkspaceListAndExplainsOfflineFailure() async throws {
        let stores = try stores()
        let project = project(in: stores)
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [])
        adapter.holdRefresh = true
        adapter.failRefresh = true
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        let (host, window) = host(ProjectDetailScreen(projectId: project.id, repository: repository), stores: stores)
        defer { adapter.releaseRefresh(); window.isHidden = true }
        try await waitForRefresh(adapter)
        let loading = try await visibleText(host)
        XCTAssertTrue(loading.contains("Checking workspace"), loading)
        XCTAssertFalse(loading.contains("Workspace unavailable"), loading)
        adapter.releaseRefresh()
        await repository.refresh()
        let offline = try await visibleText(host)
        XCTAssertTrue(offline.contains("Check your connection"), offline)
        XCTAssertTrue(offline.contains("Retry"), offline)
        XCTAssertNotNil(stores.projects.get(project.id))
    }

    func testWorkspaceListShowsLoadingThenRetryAndRecoversWithoutReopening() async throws {
        let stores = try stores()
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [])
        adapter.holdRefresh = true
        adapter.failRefresh = true
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        let (view, window) = host(WorkspacesScreen(repository: repository), stores: stores)
        defer { adapter.releaseRefresh(); window.isHidden = true }
        try await waitForRefresh(adapter)
        let loading = try await visibleText(view)
        XCTAssertTrue(loading.contains("Loading workspaces"), loading)
        XCTAssertFalse(loading.contains("No workspaces yet"), loading)

        adapter.releaseRefresh()
        await repository.refresh()
        let failed = try await visibleText(view, snapshot: "mindwire-workspace-list-retry")
        XCTAssertTrue(failed.contains("load workspaces"), failed)
        XCTAssertTrue(failed.contains("Retry"), failed)
        XCTAssertFalse(failed.contains("No workspaces yet"), failed)

        adapter.failRefresh = false
        adapter.remote = [workspace()]
        await repository.refresh()
        let restored = try await visibleText(view)
        XCTAssertTrue(restored.contains("Test workspace"), restored)
        XCTAssertFalse(restored.contains("Retry"), restored)
    }

    func testWorkspaceListKeepsCachedRowsVisibleWhenRefreshFails() async throws {
        let stores = try stores()
        var ubuntu = workspace()
        ubuntu.image = "ubuntu:24.04"
        let mac = Workspace(id: "workspace-mac", name: "Mac Studio", runtime: ubuntu.runtime,
            createdAt: "2026-09-17T00:00:00Z", image: "oblien/macos-tahoe:26.6.2-20260916-r18")
        let stopped = Workspace(id: "workspace-stopped", name: "Production", runtime: ubuntu.runtime,
            createdAt: "2026-09-15T00:00:00Z", image: "ubuntu:24.04")
        let setup = Workspace(id: "workspace-setup", name: "New workspace", runtime: ubuntu.runtime,
            createdAt: "2026-09-14T00:00:00Z", image: "ubuntu:24.04")
        let workspaces = [mac, ubuntu, stopped, setup]
        let remote = WorkspaceRemoteFixture()
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
            resolveWorkspace: { id in workspaces.first { $0.id == id } })
        let coordinator = DaemonWorkCoordinator.shared
        defer { for workspace in workspaces { coordinator.forget(workspaceId: workspace.id) } }
        for workspace in workspaces {
            coordinator.recordHealth(.init(ok: true, version: "0.1.14", workspaceMetadataVersion: 1,
                projectOperationsVersion: 1), for: .init(workspaceId: workspace.id),
                latest: workspace.id == ubuntu.id ? "0.1.15" : "0.1.14")
        }
        coordinator.recordWorkspaceStatus(.init(power: .stopped), for: .init(workspaceId: stopped.id))
        let installation = coordinator.states[.init(workspaceId: setup.id)]
        installation?.begin(.installingDaemon)
        installation?.progress = 0.42
        installation?.message = "Downloading Mindwire…"
        let adapter = WorkspaceAvailabilityAdapter(workspaces: workspaces)
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        await repository.refresh()
        for (scheme, size, name) in [(ColorScheme.light, DynamicTypeSize.large, "light"),
                                     (.dark, .large, "dark"), (.light, .accessibility2, "large-type")] {
            let (preview, previewWindow) = host(WorkspacesScreen(repository: repository)
                .environment(\.dynamicTypeSize, size), stores: stores, colorScheme: scheme)
            _ = try await visibleText(preview, snapshot: "mindwire-workspace-cards-\(name)")
            previewWindow.isHidden = true
        }
        let (view, window) = host(WorkspacesScreen(repository: repository), stores: stores)
        defer { window.isHidden = true }
        adapter.failRefresh = true
        await repository.refresh()
        let failed = try await visibleText(view)
        XCTAssertTrue(failed.contains("Test workspace"), failed)
        XCTAssertTrue(failed.contains("refresh workspaces"), failed)
        XCTAssertTrue(failed.contains("Retry"), failed)
        XCTAssertFalse(failed.contains("No workspaces yet"), failed)
    }

    func testStaleRouteShowsProjectRemovedAfterConfirmedWorkspaceDeletion() async throws {
        let stores = try stores()
        let project = project(in: stores)
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [workspace()])
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        let (host, window) = host(ProjectDetailScreen(projectId: project.id, repository: repository), stores: stores)
        defer { window.isHidden = true }
        _ = try await visibleText(host)
        try await repository.delete("workspace")
        let text = try await visibleText(host)
        XCTAssertTrue(text.contains("Project unavailable"), text)
        XCTAssertTrue(text.contains("Back"), text)
        XCTAssertFalse(text.contains("Source Control"), text)
    }

    func testWorkspaceDetailReconcilesMissingFreshAndPopulatedStates() async throws {
        let stores = try stores()
        let project = project(in: stores)
        let workspace = workspace()
        let remote = WorkspaceRemoteFixture()
        remote.current = .init(version: 1, workspaceId: "database", revision: 0, full: true,
                               agents: [], projects: [project], chats: [], deleted: [])
        remote.onPut = { [weak remote] kind, _, data, _ in
            let remote = try XCTUnwrap(remote)
            XCTAssertEqual(kind, "agents")
            var agent = try JSONDecoder().decode(Agent.self, from: data)
            agent.revision = remote.current.revision + 1
            remote.current = .init(version: 1, workspaceId: "database", revision: agent.revision!, full: true,
                                   agents: [agent], projects: [project], chats: [], deleted: [])
            return remote.current
        }
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
            resolveWorkspace: { id in id == workspace.id ? workspace : nil })
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [])
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        let catalog = DaemonCatalog(version: "1.2.3", agents: [
            .init(id: .codex, name: "Codex", tagline: "Build with OpenAI's coding agent"),
            .init(id: .claudeCode, name: "Claude Code", tagline: "Code with Claude"),
            .init(id: .grok, name: "Grok", tagline: "Build with Grok"),
            .init(id: .opencode, name: "OpenCode", tagline: "Your choice of models")
        ])
        let source = ReleaseCatalog(defaults: stores.defaults, fetch: { catalog })
        let (detail, detailWindow) = host(WorkspaceDetailScreen(workspaceId: "workspace", repository: repository,
                                                              releaseCatalog: source), stores: stores)
        defer { detailWindow.isHidden = true }
        let detailText = try await visibleText(detail)
        XCTAssertTrue(detailText.contains("Workspace unavailable"), detailText)
        XCTAssertTrue(detailText.contains("Retry"), detailText)
        detailWindow.isHidden = true

        let (list, listWindow) = host(ProjectsScreen(repository: repository), stores: stores)
        defer { listWindow.isHidden = true }
        let listText = try await visibleText(list)
        XCTAssertTrue(listText.contains("Test project"), listText)
        XCTAssertTrue(listText.contains("Workspace unavailable"), listText)
        listWindow.isHidden = true
        detailWindow.makeKeyAndVisible()

        DaemonWorkCoordinator.shared.recordHealth(.init(ok: true, version: "1.2.3", workspaceMetadataVersion: 1,
            projectOperationsVersion: 1), for: .init(workspaceId: workspace.id))
        defer { DaemonWorkCoordinator.shared.forget(workspaceId: workspace.id) }
        adapter.remote = [workspace]
        await repository.refresh()
        let fresh = try await visibleText(detail, snapshot: "mindwire-workspace-first-agent")
        XCTAssertTrue(fresh.localizedCaseInsensitiveContains(t("workspace.agents.first.title")), fresh)
        XCTAssertTrue(fresh.localizedCaseInsensitiveContains(t("workspace.agents.first.body")), fresh)
        XCTAssertFalse(fresh.contains(project.name), "Overview should show the project count, not expand the project list: \(fresh)")
        XCTAssertTrue(stores.agents(forWorkspaceId: workspace.id).isEmpty, "Showing the entry card must not create an agent")

        _ = try await stores.workspaceData.createAgent(.init(name: "My Codex", agentType: .codex, workspaceId: workspace.id))
        let populated = try await visibleText(detail, snapshot: "mindwire-workspace-with-agent")
        XCTAssertFalse(populated.localizedCaseInsensitiveContains(t("workspace.agents.first.title")), populated)
        XCTAssertEqual(stores.agents(forWorkspaceId: workspace.id).count, 1)
    }

    func testWorkspaceProjectsUsesTheSharedListWithoutHidingItsLocalReplica() async throws {
        let stores = try stores()
        let workspace = workspace()
        let other = Workspace(id: "other-workspace", name: "Other workspace", runtime: workspace.runtime,
                              createdAt: workspace.createdAt)
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [workspace, other])
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        await repository.refresh()

        var local = project(in: stores)
        local.name = "Laptop project"
        local.syncId = "shared-project"
        stores.projects.save(local)
        let replica = Project(id: "other-copy", name: "Cloud replica", workspaceId: other.id,
                              path: local.path, createdAt: local.createdAt, syncId: local.syncId)
        stores.projects.save(replica)
        stores.defaults.set(["shared-project": replica.id], forKey: "mindwire:project-replicas:selected")
        XCTAssertEqual(stores.projectsByRecency().map(\.id), [replica.id])

        let (view, window) = host(ProjectsScreen(repository: repository, workspaceId: workspace.id), stores: stores)
        defer { window.isHidden = true }
        let text = try await visibleText(view, snapshot: "mindwire-workspace-projects")
        XCTAssertTrue(text.contains(local.name), text)
        XCTAssertFalse(text.contains(replica.name), text)
        XCTAssertEqual(stores.projects.get(replica.id), replica, "Opening the list must preserve other copies")
        XCTAssertEqual(adapter.refreshCalls, 1, "Opening a cached list must not check the workspace again")
    }

    func testSignedOutProjectsOfferLoginAlongsideLocalProjectsAndRestoreAfterSignIn() async throws {
        let stores = try stores()
        let remoteProject = project(in: stores)
        let chat = stores.createChat(agentId: "agent", projectId: remoteProject.id)
        let local = stores.createWorkspace(name: "Local Mac", runtime: .server(serverId: "local-connection"))
        let localProject = stores.createProject(.init(name: "Local project", workspaceId: local.id, path: "/projects/local"))
        var status = AuthStatus(authenticated: false)
        let auth = MindwireAuth { status }
        await auth.refresh()
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [workspace()])
        adapter.auth = auth
        let repository = WorkspaceRepository(stores: stores, adapters: [LocalWorkspaceAdapter(stores: stores), adapter])
        await repository.refresh()

        let (list, listWindow) = host(ProjectsScreen(repository: repository), stores: stores)
        let listText = try await visibleText(list, snapshot: "mindwire-projects-signed-out")
        XCTAssertTrue(listText.contains("Test project"), listText)
        XCTAssertTrue(listText.contains("Local project"), listText)
        XCTAssertTrue(listText.contains("Sign in to Mindwire"), listText)
        XCTAssertFalse(listText.contains("Workspace unavailable"), listText)
        listWindow.isHidden = true

        let (localView, localWindow) = host(ProjectDetailScreen(projectId: localProject.id, repository: repository), stores: stores)
        let localText = try await visibleText(localView)
        XCTAssertTrue(localText.contains("Source Control"), localText)
        XCTAssertFalse(localText.contains("Sign in"), localText)
        localWindow.isHidden = true

        let (detail, detailWindow) = host(ProjectDetailScreen(projectId: remoteProject.id, repository: repository), stores: stores)
        defer { detailWindow.isHidden = true; listWindow.isHidden = true; localWindow.isHidden = true }
        let signedOut = try await visibleText(detail, snapshot: "mindwire-project-sign-in")
        XCTAssertTrue(signedOut.contains("Sign in to Mindwire"), signedOut)
        XCTAssertFalse(signedOut.contains("Workspace unavailable"), signedOut)
        XCTAssertFalse(signedOut.contains(t("project.removeFromProjects")), signedOut)
        XCTAssertFalse(signedOut.contains("Source Control"), signedOut)

        status = AuthStatus(authenticated: true, user: AuthUser(id: "42", name: "Test owner"))
        await auth.refresh()
        await repository.refresh()
        let signedIn = try await visibleText(detail)
        XCTAssertTrue(signedIn.contains("Source Control"), signedIn)
        XCTAssertFalse(signedIn.contains("Sign in to Mindwire"), signedIn)

        status = AuthStatus(authenticated: false)
        await auth.refresh()
        let signedOutAgain = try await visibleText(detail)
        XCTAssertTrue(signedOutAgain.contains("Sign in to Mindwire"), signedOutAgain)
        XCTAssertFalse(signedOutAgain.contains("Source Control"), signedOutAgain)
        XCTAssertNotNil(stores.projects.get(remoteProject.id))
        XCTAssertNotNil(stores.projects.get(localProject.id))
        XCTAssertNotNil(stores.chats.get(chat.id))
    }

    func testSignedOutWorkspaceAndPendingProjectUseLoginRecovery() async throws {
        let stores = try stores()
        let auth = MindwireAuth { AuthStatus(authenticated: false) }
        let adapter = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" }) {
            XCTFail("Cloud inventory must wait for sign-in"); return []
        }
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        await repository.refresh()

        let (workspaceView, workspaceWindow) = host(WorkspaceDetailScreen(workspaceId: "cloud-workspace", repository: repository), stores: stores)
        let workspaceText = try await visibleText(workspaceView)
        XCTAssertTrue(workspaceText.contains("Sign in to Mindwire"), workspaceText)
        XCTAssertFalse(workspaceText.contains("Workspace unavailable"), workspaceText)
        workspaceWindow.isHidden = true

        let (operationView, operationWindow) = host(ProjectOperationScreen(reference:
            .init(workspaceId: "cloud-workspace", operationId: "pending"), repository: repository), stores: stores)
        defer { workspaceWindow.isHidden = true; operationWindow.isHidden = true }
        let operationText = try await visibleText(operationView)
        XCTAssertTrue(operationText.contains("Sign in to Mindwire"), operationText)
        XCTAssertFalse(operationText.contains("Workspace unavailable"), operationText)
        XCTAssertFalse(operationText.contains("Reconnecting"), operationText)
        XCTAssertTrue(stores.workspaceData.projectObservationErrors.isEmpty)
    }

    func testWorkspaceWithOnlyAPendingProjectIsForgottenAfterConfirmedDeletion() async throws {
        let stores = try stores(), workspace = workspace(), remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        remote.operations = [.init(id: "pending", source: "clone", name: "Pending", path: "/work/pending",
            status: "running", phase: "cloning", createdAt: workspace.createdAt, updatedAt: workspace.createdAt, sequence: 1, attempt: 1)]
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote }, resolveWorkspace: { _ in workspace })
        stores.workspaceData = data
        await data.refresh(workspace)
        XCTAssertNotNil(data.cachedProjectOperation("pending", workspaceId: workspace.id))
        let adapter = WorkspaceAvailabilityAdapter(workspaces: [workspace])
        adapter.remote = []
        adapter.deletedIDs = [workspace.id]
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        await repository.refresh()
        XCTAssertTrue(data.projectOperations.isEmpty)
        XCTAssertTrue(WorkspaceDataRepository(stores: stores).projectOperations.isEmpty)
    }

    func testWorkspaceDaemonShowsUpdateActionAndBecomesReadyAfterVerifiedHealth() async throws {
        let stores = try stores(), workspace = workspace()
        let key = DaemonWorkKey(workspaceId: workspace.id)
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        coordinator.recordHealth(.init(ok: true, version: "0.1.12"), for: key, latest: "0.1.13")
        let (view, window) = host(Form { WorkspaceDaemonDetailsSection(workspace: workspace, coordinator: coordinator) }, stores: stores)
        defer { window.isHidden = true }
        let old = try await visibleText(view, snapshot: "mindwire-workspace-daemon-update")
        XCTAssertTrue(old.contains("Update required"), old)
        XCTAssertTrue(old.contains(t("workspace.daemon.update")), old)
        // Vision can read the zero after "v" as an O in the compact version line.
        XCTAssertNotNil(old.range(of: "[vV][0O]\\.1\\.12", options: .regularExpression), old)
        coordinator.recordHealth(.init(ok: true, version: "0.1.13", workspaceMetadataVersion: 1, projectOperationsVersion: 1), for: key)
        let ready = try await visibleText(view)
        XCTAssertTrue(ready.contains(t("workspace.daemon.ready")), ready)
        XCTAssertFalse(ready.contains(t("workspace.daemon.update")), ready)
    }

    func testUnreachableCloudServiceStillOffersUpdateAndStartActions() async throws {
        let stores = try stores()
        let workspace = Workspace(id: "cloud", name: "Azure AI", runtime: .cloud(workspaceId: "cloud"), createdAt: isoNow())
        let key = DaemonWorkKey(workspaceId: workspace.id)
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        coordinator.recordWorkspaceStatus(.init(power: .running), for: key)
        coordinator.recordHealth(.init(ok: true, version: "0.1.36", workspaceMetadataVersion: 1), for: key, latest: "0.1.38")
        coordinator.recordFailure(DaemonHTTPError(status: 502, message: "proxy cannot reach service"),
            for: key, revision: coordinator.probeRevision(key))
        let (view, window) = host(Form { WorkspaceDaemonDetailsSection(workspace: workspace, coordinator: coordinator) }, stores: stores)
        defer { window.isHidden = true }
        let text = try await visibleText(view, snapshot: "mindwire-cloud-service-recovery")
        XCTAssertTrue(text.contains(t("workspace.daemon.offline")), text)
        XCTAssertTrue(text.contains(t("workspace.daemon.update")), text)
        XCTAssertTrue(text.contains(t("workspace.daemon.start")), text)
        XCTAssertTrue(text.contains(t("common.retry")), text)
        XCTAssertFalse(text.contains(t("workspace.daemon.queueUpdate")), text)
    }

    func testServiceControlsReadCachedInfoAndKeepSharedProgressWhenReopened() async throws {
        let stores = try stores(), workspace = workspace()
        let repository = WorkspaceRepository(stores: stores, adapters: [WorkspaceAvailabilityAdapter(workspaces: [workspace])])
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let key = DaemonWorkKey(workspaceId: workspace.id)
        coordinator.recordHealth(.init(ok: true, version: "0.1.21", workspaceMetadataVersion: 1,
            projectOperationsVersion: 1, serviceUpdateVersion: 1), for: key)
        var releaseReads = 0, workspaceReads = 0
        var finish: CheckedContinuation<Void, Never>?
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true },
            update: { _, _, _ in
                try await coordinator.perform(key, activity: .updatingDaemon) { state in
                    state.receive(.downloading(0.5))
                    await withCheckedContinuation { finish = $0 }
                    state.receive(.verifying)
                    coordinator.recordHealth(.init(ok: true, version: "0.1.22", workspaceMetadataVersion: 1,
                        projectOperationsVersion: 1, serviceUpdateVersion: 1), for: key)
                }
            }, fetchCatalog: {
                releaseReads += 1
                return .init(version: "0.1.22", agents: [.init(id: .codex, name: "Codex", tagline: "Coding")])
            }, readWorkspace: { _ in workspaceReads += 1 })
        stores.serviceUpdates = queue
        await queue.refreshRelease()
        let (page, window) = host(Form {
            WorkspaceDaemonSection(workspace: workspace, coordinator: coordinator)
        }.serviceUpdatePresentation(repository: repository, coordinator: coordinator)
            .navigationTitle(workspace.name), stores: stores, colorScheme: .dark)
        defer { window.isHidden = true }
        let compact = try await visibleText(page, snapshot: "mindwire-service-compact")
        XCTAssertFalse(compact.contains(t("workspace.daemon.latestRelease")), compact)
        XCTAssertFalse(compact.contains(t("settings.serviceUpdates.help")), compact)
        let (info, infoWindow) = host(ServiceUpdateInfoSheet(workspace: workspace, repository: repository, coordinator: coordinator),
            stores: stores, colorScheme: .dark)
        defer { infoWindow.isHidden = true }
        let details = try await visibleText(info, snapshot: "mindwire-service-info")
        XCTAssertTrue(details.contains(t("workspace.daemon.releaseNotes")), details)
        XCTAssertEqual(releaseReads, 1, "Opening service details must only read cached release information")
        XCTAssertEqual(workspaceReads, 0)
        infoWindow.isHidden = true

        let update = Task { await queue.updateAll([workspace]) }
        for _ in 0..<200 where finish == nil { try await Task.sleep(for: .milliseconds(5)) }
        let gate = try XCTUnwrap(finish)
        let (settings, settingsWindow) = host(Form { ServiceUpdatesSettingsSection(repository: repository) }
            .serviceUpdatePresentation(repository: repository, coordinator: coordinator)
            .navigationTitle(t("tabs.settings")), stores: stores, colorScheme: .dark)
        defer { settingsWindow.isHidden = true }
        let downloading = try await visibleText(settings, snapshot: "mindwire-service-settings-progress")
        XCTAssertTrue(downloading.contains("Downloading"), downloading)
        XCTAssertTrue(downloading.contains("50%"), downloading)
        settingsWindow.isHidden = true
        window.makeKeyAndVisible()
        let reopened = try await visibleText(page, snapshot: "mindwire-service-compact-progress")
        XCTAssertTrue(reopened.contains("Downloading"), reopened)
        XCTAssertTrue(reopened.contains("50%"), reopened)
        XCTAssertEqual(releaseReads, 2)
        XCTAssertEqual(workspaceReads, 1)
        gate.resume()
        _ = await update.value
        XCTAssertFalse(queue.busy)
    }

    func testServiceInfoFirstOpenSurvivesRowReplacementAndHealthRefresh() async throws {
        let stores = try stores(), workspace = workspace()
        let repository = WorkspaceRepository(stores: stores, adapters: [WorkspaceAvailabilityAdapter(workspaces: [workspace])])
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let key = DaemonWorkKey(workspaceId: workspace.id)
        coordinator.recordHealth(.init(ok: true, version: "0.1.21", workspaceMetadataVersion: 1,
            projectOperationsVersion: 1), for: key)
        var releaseReads = 0, workspaceReads = 0
        stores.serviceUpdates = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true },
            fetchCatalog: {
                releaseReads += 1
                return .init(version: "0.1.22", agents: [.init(id: .codex, name: "Codex", tagline: "Coding")])
            }, readWorkspace: { _ in workspaceReads += 1 })

        for settings in [false, true] {
            let presentation = ServiceUpdatePresentation()
            let entry = ServiceInfoEntryFixture()
            let (page, window) = host(ServiceInfoFixtureScreen(workspace: workspace,
                repository: repository, coordinator: coordinator, presentation: presentation,
                entry: entry, settings: settings),
                stores: stores, colorScheme: .dark)
            defer { window.isHidden = true }
            let initial = try await visibleText(page)
            XCTAssertTrue(initial.contains(t("workspace.daemon.title")), initial)

            // This is the same presentation action used by the info buttons. Check the first
            // presentation, without a warm-up open, while the original list row is replaced.
            presentation.show(workspace: settings ? nil : workspace)
            try await waitForServicePresentation { page.presentedViewController?.isBeingPresented == false }
            let original = try XCTUnwrap(page.presentedViewController)
            entry.visible = false
            coordinator.recordHealth(.init(ok: true, version: "0.1.22", workspaceMetadataVersion: 1,
                projectOperationsVersion: 1), for: key)
            await stores.serviceUpdates.refreshRelease()
            presentation.show(workspace: settings ? nil : workspace)
            try await Task.sleep(for: .milliseconds(700))
            let refreshed = try await visibleText(page)
            XCTAssertTrue(refreshed.contains("Workspace status refreshed"),
                "The original service section must actually be replaced during presentation: \(refreshed)")
            XCTAssertTrue(page.presentedViewController === original, "Refreshing a list section must keep its info sheet open")
            XCTAssertFalse(original.isBeingDismissed)
            XCTAssertNotNil(presentation.sheet)
            XCTAssertEqual(workspaceReads, 0, "Opening information must not start a workspace check")
            XCTAssertEqual(releaseReads, 1, "Only the explicit fixture refresh may read the release")

            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let name = "mindwire-service-first-open-\(settings ? "settings" : "workspace")"
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png"))

            presentation.sheet = nil
            try await waitForServicePresentation { page.presentedViewController == nil }
            entry.visible = true
            presentation.show(workspace: settings ? nil : workspace)
            try await waitForServicePresentation { page.presentedViewController?.isBeingPresented == false }
            XCTAssertNotNil(page.presentedViewController)
            presentation.sheet = nil
            try await waitForServicePresentation { page.presentedViewController == nil }
        }
    }

    private func waitForServicePresentation(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The native service information presentation did not settle")
    }

    func testServiceUpdateSheetKeepsWaitingAndFailedComputersVisibleWithActions() async throws {
        let stores = try stores()
        let mac = Workspace(id: "update-mac", name: "My Mac", runtime: .server(serverId: "mac"), createdAt: "now", image: "macos")
        let server = Workspace(id: "update-server", name: "Ubuntu server", runtime: .server(serverId: "server"), createdAt: "now", image: "ubuntu")
        let repository = WorkspaceRepository(stores: stores, adapters: [WorkspaceAvailabilityAdapter(workspaces: [mac, server])])
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let macKey = DaemonWorkKey(workspaceId: mac.id)
        for workspace in [mac, server] {
            coordinator.recordHealth(.init(ok: true, version: "0.1.25", workspaceMetadataVersion: 1,
                projectOperationsVersion: 1, serviceUpdateVersion: 1), for: .init(workspaceId: workspace.id))
        }
        coordinator.recordUpdateOperation(.init(id: "remote-update", version: "0.1.26", status: "waiting",
            activity: .init(idle: false, updating: false, activeOperations: 1, openTerminals: 1)),
            for: macKey, revision: coordinator.probeRevision(macKey))
        coordinator.recordOperationFailure(BackendError.message("The release checksum did not match."),
            for: .init(workspaceId: server.id), activity: .updatingDaemon)
        var reads = 0
        stores.serviceUpdates = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true },
            fetchCatalog: { .init(version: "0.1.26", agents: [.init(id: .codex, name: "Codex", tagline: "Coding")]) },
            readWorkspace: { _ in reads += 1 })
        await stores.serviceUpdates.refreshRelease()

        let (all, allWindow) = host(ServiceUpdateInfoSheet(repository: repository, coordinator: coordinator),
                                  stores: stores, colorScheme: .dark)
        defer { allWindow.isHidden = true }
        let summary = try await visibleText(all, snapshot: "mindwire-computer-update-results")
        XCTAssertTrue(summary.contains(t("workspace.daemon.updateAll")), summary)
        XCTAssertTrue(summary.contains("My Mac"), summary)
        XCTAssertTrue(summary.contains(t("workspace.daemon.waitingTerminalStatus")), summary)
        XCTAssertTrue(summary.contains("Ubuntu server"), summary)
        XCTAssertTrue(summary.contains(t("agentUpdates.failed")), summary)

        let (details, detailWindow) = host(ServiceUpdateInfoSheet(workspace: mac, repository: repository, coordinator: coordinator),
                                          stores: stores, colorScheme: .dark)
        defer { detailWindow.isHidden = true }
        let waiting = try await visibleText(details, snapshot: "mindwire-computer-update-waiting")
        XCTAssertTrue(waiting.contains(t("workspace.daemon.openTerminals")), waiting)
        XCTAssertTrue(waiting.contains(t("workspace.daemon.waitingTerminal")), waiting)
        XCTAssertTrue(waiting.contains(t("workspace.daemon.update")), "A queued automatic update must keep manual restart available: \(waiting)")

        let state = try XCTUnwrap(coordinator.states[macKey])
        state.updateOperation = nil
        state.updateWaiting = false
        state.reachable = nil
        let cached = try await visibleText(details, snapshot: "mindwire-computer-update-action")
        XCTAssertTrue(cached.contains(t("workspace.daemon.update")), cached)
        XCTAssertEqual(reads, 0, "Opening update information must not repeat checks or start an update")
    }

    func testProjectsListShowsCreatingRowThenOneReadyProject() async throws {
        let stores = try stores(), workspace = workspace(), remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        remote.operations = [.init(id: "new-project", source: "folder", name: "My test project", path: "/work/new-project",
            status: "running", phase: "preparing", createdAt: workspace.createdAt, updatedAt: workspace.createdAt, sequence: 1, attempt: 1)]
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote }, resolveWorkspace: { _ in workspace })
        stores.workspaceData = data
        await data.refresh(workspace)
        DaemonWorkCoordinator.shared.recordHealth(.init(ok: true, version: "0.1.13", workspaceMetadataVersion: 1, projectOperationsVersion: 1),
                                                  for: .init(workspaceId: workspace.id))
        defer { DaemonWorkCoordinator.shared.forget(workspaceId: workspace.id) }
        let repository = WorkspaceRepository(stores: stores, adapters: [WorkspaceAvailabilityAdapter(workspaces: [workspace])])
        let (view, window) = host(ProjectsScreen(repository: repository), stores: stores)
        defer { window.isHidden = true }
        let pending = try await visibleText(view, snapshot: "mindwire-project-creating-row")
        XCTAssertTrue(pending.contains("My test project"), pending)
        XCTAssertTrue(pending.contains("Creating project"), pending)
        remote.operations[0].status = "succeeded"
        remote.operations[0].phase = "complete"
        remote.operations[0].sequence = 2
        remote.operations[0].projectId = "new-project"
        remote.current = .init(version: 1, workspaceId: "database", revision: 1, full: true, agents: [],
            projects: [.init(id: "new-project", name: "My test project", workspaceId: "database",
                            path: "/work/new-project", createdAt: workspace.createdAt, revision: 1)], chats: [], deleted: [])
        await data.refresh(workspace)
        let ready = try await visibleText(view, snapshot: "mindwire-project-ready-row")
        XCTAssertEqual(ready.components(separatedBy: "My test project").count - 1, 1, ready)
        XCTAssertFalse(ready.contains("Creating project"), ready)
    }

    func testServiceProxyFailureShowsReadableRecoveryThenLiveSetupAndReadyState() async throws {
        let stores = try stores(), workspace = workspace()
        let key = DaemonWorkKey(workspaceId: workspace.id)
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let proxyError = #"{"error":"proxy_unavailable","message":"proxy cannot reach service","details":"dial tcp 127.0.0.1:8790: connect: connection refused"}"#
        coordinator.recordFailure(DaemonHTTPError(status: 502, message: proxyError), for: key,
                                  revision: coordinator.probeRevision(key))
        let (view, window) = host(Form { WorkspaceDaemonDetailsSection(workspace: workspace, coordinator: coordinator) }, stores: stores)
        defer { window.isHidden = true }
        let offline = try await visibleText(view, snapshot: "mindwire-service-unavailable")
        XCTAssertTrue(offline.contains(t("workspace.daemon.offline")), offline)
        XCTAssertTrue(offline.contains("Check the workspace connection"), offline)
        XCTAssertTrue(offline.contains(t("workspace.daemon.errorDetails")), offline)
        XCTAssertTrue(offline.contains(t("workspace.daemon.install")), offline)
        XCTAssertFalse(offline.contains("dial tcp"), offline)
        XCTAssertFalse(offline.contains("127.0.0.1"), offline)
        XCTAssertFalse(offline.contains("proxy_unavailable"), offline)

        var finish: CheckedContinuation<Void, Never>?
        let setup = Task {
            try await coordinator.perform(key, activity: .installingDaemon) { work in
                work.message = t("agentAuth.stage.installing")
                work.progress = 0.5
                await withCheckedContinuation { finish = $0 }
                coordinator.recordHealth(.init(ok: true, version: "0.1.13", workspaceMetadataVersion: 1,
                                               projectOperationsVersion: 1), for: key)
            }
        }
        defer { finish?.resume() }
        for _ in 0..<100 {
            if finish != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let installing = try await visibleText(view, snapshot: "mindwire-workspace-service-installing")
        XCTAssertTrue(installing.contains("Setting up service"), installing)
        XCTAssertFalse(installing.contains(t("workspace.daemon.errorDetails")), installing)
        finish?.resume(); finish = nil
        try await setup.value
        let ready = try await visibleText(view)
        XCTAssertTrue(ready.contains(t("workspace.daemon.ready")), ready)
        XCTAssertFalse(ready.contains(t("workspace.daemon.errorDetails")), ready)
        XCTAssertFalse(ready.contains(t("workspace.daemon.offline")), ready)
    }

    func testStoppedWorkspaceShowsStartThenConnectingAndVerifiedReadyWithoutProxyError() async throws {
        let stores = try stores(), workspace = workspace()
        let key = DaemonWorkKey(workspaceId: workspace.id)
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        coordinator.recordFailure(URLError(.cannotConnectToHost), for: key, revision: coordinator.probeRevision(key))
        coordinator.recordWorkspaceStatus(.init(power: .stopped), for: key)
        let (view, window) = host(Form { WorkspaceDaemonDetailsSection(workspace: workspace, coordinator: coordinator) }, stores: stores)
        defer { window.isHidden = true }
        let stopped = try await visibleText(view, snapshot: "mindwire-workspace-stopped")
        XCTAssertTrue(stopped.contains(t("workspace.power.stopped")), stopped)
        XCTAssertTrue(stopped.contains(t("workspace.power.startAction")), stopped)
        XCTAssertFalse(stopped.contains(t("workspace.daemon.offline")), stopped)
        XCTAssertFalse(stopped.contains(t("workspace.daemon.install")), stopped)
        coordinator.beginPowerAction(.start, for: key)
        coordinator.recordWorkspaceStatus(.init(power: .running), for: key)
        let starting = try await visibleText(view, snapshot: "mindwire-workspace-connecting")
        XCTAssertTrue(starting.contains("Connecting to service"), starting)
        XCTAssertFalse(starting.contains(t("workspace.daemon.offline")), starting)
        coordinator.recordHealth(.init(ok: true, version: "0.1.13", workspaceMetadataVersion: 1, projectOperationsVersion: 1), for: key)
        coordinator.finishPowerAction(for: key)
        let ready = try await visibleText(view)
        XCTAssertTrue(ready.contains(t("workspace.daemon.ready")), ready)
        XCTAssertFalse(ready.contains(t("workspace.power.startAction")), ready)
    }

    func testProjectRemovalPresentsNativeCancelAndExplicitKeepOrDeleteConfirmation() async throws {
        let stores = try stores(), project = project(in: stores)
        let other = stores.createProject(.init(name: "Another project", workspaceId: "workspace", path: "/projects/other"))
        let repository = WorkspaceRepository(stores: stores, adapters: [WorkspaceAvailabilityAdapter(workspaces: [workspace()])])
        for deleteFiles in [false, true] {
            let actions = ProjectRemovalActions()
            let (view, window) = host(List {
                ForEach([project, other]) { project in
                    Text(project.name).contextMenu {
                        ProjectRemovalMenuItems(project: project, actions: actions, repository: repository)
                    }
                }
                .projectRemovalAlerts(actions, repository: repository)
            }, stores: stores)
            defer { actions.confirmation = nil; view.dismiss(animated: false); window.isHidden = true }
            try await Task.sleep(for: .milliseconds(150))
            actions.confirm(project, deleteFiles: deleteFiles, repository: repository)
            for _ in 0..<100 {
                if view.presentedViewController is UIAlertController { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let alert = try XCTUnwrap(view.presentedViewController as? UIAlertController)
            XCTAssertEqual(alert.preferredStyle, .alert, "Project removal requires a centered native confirmation")
            XCTAssertEqual(alert.actions.count, 2)
            XCTAssertTrue(alert.actions.contains { $0.style == .cancel })
            let confirmation = try XCTUnwrap(alert.actions.first { $0.style == .destructive })
            XCTAssertEqual(confirmation.title, t(deleteFiles ? "project.deleteFolder" : "project.removeFromProjects"))
            XCTAssertTrue(alert.message?.contains(project.name) == true)
            if deleteFiles { XCTAssertTrue(alert.message?.contains(project.path) == true) }
            else { XCTAssertTrue(alert.message?.contains("all files will stay in place") == true) }
            try await Task.sleep(for: .milliseconds(400))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let text = try ChatFeedSnapshot.visibleText(in: image)
            XCTAssertTrue(text.contains(project.name), text)
            XCTAssertTrue(text.contains(t("common.cancel")), text)
            let name = deleteFiles ? "mindwire-project-delete-files" : "mindwire-project-keep-files"
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let snapshot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
            try image.pngData()?.write(to: snapshot)
            print("PROJECT_REMOVAL_SNAPSHOT_PATH=\(snapshot.path)")
            XCTAssertNotNil(stores.projects.get(project.id), "Opening a confirmation must never remove the project")
        }
    }

    private func waitForRefresh(_ adapter: WorkspaceAvailabilityAdapter) async throws {
        for _ in 0..<100 {
            if adapter.isWaiting { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Workspace refresh did not start")
    }

    private func host<V: View>(_ view: V, stores: Stores, colorScheme: ColorScheme? = nil) -> (UIViewController, UIWindow) {
        let host = UIHostingController(rootView: NavigationStack { view }
            .environment(\.stores, stores).environment(AppModel(stores: stores))
            .labelIconToTitleSpacing(Spacing.md)
            .preferredColorScheme(colorScheme))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow() }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (host, window)
    }

    private func visibleText(_ host: UIViewController, snapshot: String? = nil) async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        let image = ChatFeedSnapshot.image(host)
        if let snapshot {
            let attachment = XCTAttachment(image: image)
            attachment.name = snapshot
            attachment.lifetime = .keepAlways
            add(attachment)
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(snapshot).png")
            try image.pngData()?.write(to: url)
            print("WORKSPACE_SNAPSHOT_PATH=\(url.path)")
        }
        return try ChatFeedSnapshot.visibleText(in: image)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

@MainActor @Observable
private final class ServiceInfoEntryFixture {
    var visible = true
}

@MainActor
private struct ServiceInfoFixtureScreen: View {
    let workspace: Workspace
    let repository: WorkspaceRepository
    let coordinator: DaemonWorkCoordinator
    let presentation: ServiceUpdatePresentation
    let entry: ServiceInfoEntryFixture
    let settings: Bool

    var body: some View {
        Form {
            if entry.visible {
                if settings { ServiceUpdatesSettingsSection(repository: repository) }
                else { WorkspaceDaemonSection(workspace: workspace, coordinator: coordinator) }
            } else {
                Section { Text("Workspace status refreshed") }
            }
        }
        .serviceUpdatePresentation(repository: repository, coordinator: coordinator, presentation: presentation)
    }
}

/// The sync cache mirrors the production adapter; the gate simulates a slow cloud list.
private final class WorkspaceAvailabilityAdapter: WorkspaceAdapter {
    @MainActor var auth: MindwireAuth?
    @MainActor var requiresSignIn: Bool { auth?.isSignedOut == true }
    private let lock = NSLock()
    private var cache: [Workspace]
    private var next: [Workspace]
    private var refreshFails = false
    private var deleteFails = false
    private var held = false
    private var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    var deletedIDs: Set<String> = []

    init(workspaces: [Workspace]) { cache = workspaces; next = workspaces }
    var remote: [Workspace] { get { lock.withLock { next } } set { lock.withLock { next = newValue } } }
    var failRefresh: Bool { get { lock.withLock { refreshFails } } set { lock.withLock { refreshFails = newValue } } }
    var failDelete: Bool { get { lock.withLock { deleteFails } } set { lock.withLock { deleteFails = newValue } } }
    var holdRefresh: Bool { get { lock.withLock { held } } set { lock.withLock { held = newValue } } }
    var refreshCalls: Int { lock.withLock { calls } }
    var isWaiting: Bool { lock.withLock { gate != nil } }

    func owns(_ workspace: Workspace) -> Bool { true }
    func confirmsDeletion(_ id: String) async -> Bool { deletedIDs.contains(id) }
    func current() -> [Workspace] { lock.withLock { cache } }
    func refresh() async throws {
        lock.withLock { calls += 1 }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if held { gate = continuation } else { continuation.resume() }
            }
        }
        try lock.withLock {
            if refreshFails { throw URLError(.notConnectedToInternet) }
            cache = next
        }
    }
    func releaseRefresh() {
        let continuation = lock.withLock { let pending = gate; gate = nil; held = false; return pending }
        continuation?.resume()
    }
    func adopt(name: String, runtime: AgentRuntime, spec: WorkspaceSpec?) async -> Workspace? { nil }
    func rename(_ id: String, to name: String) async {}
    func delete(_ id: String) async throws {
        try lock.withLock {
            if deleteFails { throw URLError(.notConnectedToInternet) }
            cache.removeAll { $0.id == id }
            next.removeAll { $0.id == id }
        }
    }
}
