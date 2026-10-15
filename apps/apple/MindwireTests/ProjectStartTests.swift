import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class ProjectStartTests: XCTestCase {
    func testProjectChoiceContinuesAfterWorkspaceCreationButNotAfterCancellation() {
        for source in [ProjectStartFlow.Source.clone, .folder] {
            var flow = ProjectStartFlow()
            XCTAssertEqual(flow.choose(source, hasWorkspace: false), .workspace)
            XCTAssertTrue(flow.path.isEmpty)
            XCTAssertNil(flow.workspaceSheetDismissed()) // Cancel the optional workspace setup.
            XCTAssertTrue(flow.path.isEmpty)

            XCTAssertEqual(flow.choose(source, hasWorkspace: false), .workspace)
            flow.didCreateWorkspace()
            XCTAssertTrue(flow.path.isEmpty, "Wait for workspace dismissal before presenting another screen")
            let next = flow.workspaceSheetDismissed()
            let expectedPath: [ProjectStartFlow.Step] = source == .clone ? [.clone] : []
            XCTAssertEqual(next, source == .folder ? .folder : nil)
            XCTAssertEqual(flow.path, expectedPath)
            XCTAssertEqual(flow.source, source)
            XCTAssertNil(flow.workspaceSheetDismissed(), "Cancelling a folder picker must not reopen it")
            XCTAssertEqual(flow.path, expectedPath, "Other picker dismissals must not push another details page")
        }
    }

    func testExistingWorkspaceAndPresetRepositoryKeepDirectProjectFlow() {
        var flow = ProjectStartFlow()
        XCTAssertEqual(flow.choose(.folder, hasWorkspace: true), .folder)
        XCTAssertTrue(flow.path.isEmpty, "An existing folder needs only the picker, not another workspace/details page")
        XCTAssertNil(flow.workspaceSheetDismissed())
        XCTAssertEqual(flow.choose(.folder, hasWorkspace: true), .folder, "The picker can be reopened after cancellation")
        XCTAssertTrue(flow.path.isEmpty)

        var preset = ProjectStartFlow(presetSource: .clone)
        XCTAssertEqual(preset.path, [.clone])
        preset.didCreateWorkspace()
        preset.workspaceSheetDismissed()
        XCTAssertEqual(preset.path, [.clone], "Adding a workspace from details preserves the existing repository flow")
    }

    func testFirstAgentStepUsesAcknowledgedWorkspaceAgentsInsteadOfStaleCache() async throws {
        for daemonHasAgent in [false, true] {
            let stores = try stores()
            let workspace = Workspace(id: UUID().uuidString, name: "Workspace", runtime: .server(serverId: "fixture"), createdAt: isoNow())
            let remote = WorkspaceRemoteFixture()
            remote.supportsProjectOperations = true
            let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
                                               resolveWorkspace: { $0 == workspace.id ? workspace : nil })
            stores.workspaceData = data
            let agent = Agent(id: "codex", name: "Codex", agentType: .codex, workspaceId: "database",
                              createdAt: workspace.createdAt, revision: 1)
            let cached = WorkspaceMetadata(version: 1, workspaceId: "database", revision: 1, full: true,
                                           agents: daemonHasAgent ? [] : [agent], projects: [], chats: [], deleted: [])
            try data.apply(cached, workspaceId: workspace.id)
            let other = stores.createAgent(.init(name: "Other", agentType: .claudeCode, workspaceId: "other-workspace"))
            remote.current = WorkspaceMetadata(version: 1, workspaceId: "database", revision: 2, full: true,
                                               agents: daemonHasAgent ? [agent] : [], projects: [], chats: [], deleted: [])
            remote.onStart = { request in
                let operation = ProjectOperation(id: request.id, source: request.source, name: request.name, path: request.path,
                    status: "running", phase: "registering", createdAt: workspace.createdAt, updatedAt: workspace.createdAt,
                    sequence: 1, attempt: 1)
                remote.operations = [operation]
                return operation
            }
            let creation = ProjectCreationModel()
            let accepted = await creation.createFolder(name: "App", workspaceId: workspace.id, path: "/work/app", stores: stores)
            let result = ProjectStartResult(workspaceId: workspace.id, operation: try XCTUnwrap(accepted, creation.errorMessage ?? ""))
            XCTAssertEqual(result.needsAgent(in: stores), !daemonHasAgent)
            XCTAssertTrue(result.routes(in: stores).isEmpty, "A pending operation must not open a project that does not exist yet")
            XCTAssertNotNil(stores.agents.get(other.id))
            XCTAssertTrue(stores.projects.list().isEmpty)
            XCTAssertTrue(stores.chats.list().isEmpty)
        }
    }

    func testFirstAgentContinuationOpensCanonicalProjectOnlyAfterReconciliation() async throws {
        let stores = try stores()
        let workspace = Workspace(id: UUID().uuidString, name: "Workspace", runtime: .server(serverId: "fixture"), createdAt: isoNow())
        let remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
                                           resolveWorkspace: { $0 == workspace.id ? workspace : nil })
        stores.workspaceData = data
        remote.onStart = { request in
            let operation = ProjectOperation(id: request.id, source: "clone", name: request.name, path: request.path,
                status: "running", phase: "cloning", createdAt: workspace.createdAt, updatedAt: workspace.createdAt,
                sequence: 1, attempt: 1)
            remote.operations = [operation]
            return operation
        }
        let operation = try await data.startProject(.init(id: "clone-operation", source: "clone", name: "App", path: "/work/app"),
                                                    workspaceId: workspace.id)
        let result = ProjectStartResult(workspaceId: workspace.id, operation: operation)
        XCTAssertTrue(result.needsAgent(in: stores))
        XCTAssertTrue(result.routes(in: stores).isEmpty)
        remote.current = WorkspaceMetadata(version: 1, workspaceId: "database", revision: 1, full: true,
                                           agents: [], projects: [], chats: [], deleted: [])
        remote.current.projects = [Project(id: "canonical-project", name: "App", workspaceId: "database", path: "/work/app",
                                           createdAt: workspace.createdAt, revision: 1)]
        remote.current.agents = [Agent(id: "chosen-agent", name: "Codex", agentType: .codex, workspaceId: "database",
                                       createdAt: workspace.createdAt, revision: 1)]
        remote.operations[0].status = "succeeded"
        remote.operations[0].phase = "complete"
        remote.operations[0].sequence = 2
        remote.operations[0].projectId = "canonical-project"
        let completed = try await data.observeProject(operation.id, workspaceId: workspace.id) { _ in }
        _ = try await data.projectResult(completed, workspaceId: workspace.id)
        let agent = try XCTUnwrap(stores.agents.get("chosen-agent"))
        XCTAssertFalse(result.needsAgent(in: stores))
        XCTAssertEqual(agent.workspaceId, workspace.id, "Setup creates a workspace-owned agent")
        XCTAssertEqual(result.routes(in: stores), [.projectDetail(id: "canonical-project")],
                       "Finishing agent setup returns to the project's chats")
        stores.agents.remove(agent.id)
        XCTAssertEqual(result.routes(in: stores), [.projectDetail(id: "canonical-project")],
                       "Skipping or removing the agent still opens the project")
        XCTAssertTrue(stores.chats.list().isEmpty, "Finishing setup must not create an empty chat")
        XCTAssertEqual(remote.cancelCalls, 0)
        XCTAssertEqual(remote.startIDs.count, 1, "Agent setup must not resubmit the clone")
    }

    func testUnsuccessfulProjectDoesNotAdvanceToAnAgentOrCachedFolder() throws {
        let stores = try stores()
        let project = stores.createProject(.init(name: "App", workspaceId: "workspace", path: "/work/app"))
        for status in ["failed", "cancelled", "interrupted", "cancelling"] {
            let result = ProjectStartResult(workspaceId: project.workspaceId, operation: .init(
                id: project.id, source: "folder", name: project.name, path: project.path, status: status,
                phase: "registering", projectId: project.id, createdAt: project.createdAt,
                updatedAt: project.createdAt, sequence: 1, attempt: 1))
            XCTAssertFalse(result.needsAgent(in: stores), status)
            XCTAssertTrue(result.routes(in: stores).isEmpty, status)
        }
    }

    func testAcceptedFolderCreationPreservesNavigationAndUnscopedCreationOpensTheProject() throws {
        let stores = try stores()
        let app = AppModel(stores: stores)
        let folder = try XCTUnwrap(stores.projectLibrary.createFolder(name: "Client work"))
        app.projectsPath.append(folder.id)
        let originalPath = app.projectsPath
        let project = stores.createProject(.init(name: "New app", workspaceId: "workspace", path: "/work/new-app"))
        let operation = ProjectOperation(id: "new-operation", source: "folder", name: project.name, path: project.path,
            status: "succeeded", phase: "complete", projectId: project.id, createdAt: project.createdAt,
            updatedAt: project.createdAt, sequence: 1, attempt: 1)
        stores.projectLibrary.placeCreation(operation, workspaceId: project.workspaceId,
            in: folder.id, projects: stores.projects.list())
        let result = ProjectStartResult(workspaceId: project.workspaceId, operation: operation)
        result.navigate(in: app, libraryFolderId: folder.id)
        XCTAssertEqual(app.selectedTab, .projects)
        XCTAssertEqual(app.projectsPath, originalPath, "Creating from a folder must not return home or push a different screen")

        app.selectedTab = .workspaces
        result.navigate(in: app, libraryFolderId: nil)
        var expected = NavigationPath()
        expected.append(AppRoute.projectDetail(id: project.id))
        XCTAssertEqual(app.selectedTab, .projects)
        XCTAssertEqual(app.projectsPath, expected, "Workspace/global creation still opens the accepted project")
    }

    func testEmptyProjectsHomeOffersProjectCreationWithoutWorkspaceGate() async throws {
        let stores = try stores()
        let repository = WorkspaceRepository(stores: stores, adapters: [])
        let appearances: [(ColorScheme, DynamicTypeSize, String)] = [
            (.light, .large, "light"), (.dark, .large, "dark"),
            (.light, .accessibility2, "large-type")
        ]
        for (scheme, size, name) in appearances {
            let (view, window) = try host(projectHome(repository: repository)
                .preferredColorScheme(scheme).environment(\.dynamicTypeSize, size), stores: stores)
            defer { window.isHidden = true }
            let text = try await visibleText(view, snapshot: "mindwire-project-home-\(name)")
            XCTAssertTrue(text.contains(t("projects.empty.cta")), text)
            XCTAssertFalse(text.contains(t("workspaces.empty.title")), text)
            XCTAssertFalse(text.contains(t("workspaces.empty.cta")), text)
            XCTAssertTrue(repository.all.isEmpty, "Opening Projects must not provision a workspace")
            window.isHidden = true
        }
    }

    func testProjectChoicesAreAvailableWithoutAnyWorkspace() async throws {
        let stores = try stores()
        let repository = WorkspaceRepository(stores: stores, adapters: [])
        let (view, window) = try host(NewProjectScreen(repository: repository), stores: stores)
        defer { window.isHidden = true }
        let text = try await visibleText(view, snapshot: "mindwire-project-start-no-workspace")
        XCTAssertTrue(text.contains(t("newProject.choice.clone.title")), text)
        XCTAssertTrue(text.contains(t("newProject.choice.folder.title")), text)
        XCTAssertFalse(text.contains(t("workspaces.empty.title")), text)
        XCTAssertFalse(text.contains(t("workspaces.empty.cta")), text)
    }



    func testEmptyProjectsActionRemainsVisibleWhileStatusAppearsAndRecovers() async throws {
        let stores = try stores()
        let adapter = ProjectWorkspaceFixture()
        adapter.error = URLError(.notConnectedToInternet)
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        await repository.refresh()
        let (view, window) = try host(projectHome(repository: repository).preferredColorScheme(.light), stores: stores)
        defer { window.isHidden = true }
        let failed = try await visibleText(view, snapshot: "mindwire-project-home-status")
        XCTAssertFalse(failed.contains(t("workspace.status.refreshFailed")), "Status details belong in the sheet: \(failed)")
        XCTAssertTrue(failed.contains(t("projects.empty.cta")), failed)
        XCTAssertEqual(WorkspaceStatusOverview(repository: repository, stores: stores).attentionCount, 1)

        let (statusView, statusWindow) = try host(WorkspaceStatusSheet(repository: repository).preferredColorScheme(.light), stores: stores)
        let details = try await visibleText(statusView, snapshot: "mindwire-workspace-status-inventory-error")
        XCTAssertTrue(details.contains(t("workspace.status.refreshFailed")), details)
        XCTAssertTrue(details.contains(t("workspace.status.refreshFailedBody")), details)
        XCTAssertEqual(adapter.refreshCalls, 1, "Opening status details must not retry automatically")
        statusWindow.isHidden = true
        window.makeKeyAndVisible()

        adapter.error = nil
        await repository.refresh()
        let recovered = try await visibleText(view, snapshot: "mindwire-project-home-recovered")
        XCTAssertTrue(recovered.contains(t("projects.empty.cta")), recovered)
        XCTAssertFalse(recovered.contains(t("workspace.status.refreshFailed")), recovered)
        XCTAssertEqual(WorkspaceStatusOverview(repository: repository, stores: stores).attentionCount, 0)
    }

    func testReopeningProjectsAndStatusReusesSettledChecksUntilExplicitRefresh() async throws {
        let stores = try stores()
        let workspace = Workspace(id: UUID().uuidString, name: "Design Mac", runtime: .server(serverId: "fixture-mac"),
                                  createdAt: isoNow(), image: "macos")
        let key = DaemonWorkKey(workspaceId: workspace.id)
        let coordinator = DaemonWorkCoordinator.shared
        coordinator.recordHealth(.init(ok: true, version: "1.2.3", workspaceMetadataVersion: 1, projectOperationsVersion: 1), for: key)
        defer { coordinator.forget(workspaceId: workspace.id) }
        let remote = WorkspaceRemoteFixture()
        remote.current.projects = [Project(id: "app", name: "My app", workspaceId: "database", path: "/workspace/app",
                                           createdAt: workspace.createdAt, revision: 1)]
        var now = Date()
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
            resolveWorkspace: { $0 == workspace.id ? workspace : nil }, now: { now })
        let adapter = ProjectWorkspaceFixture(workspaces: [workspace])
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter], now: { now })
        await repository.refreshIfNeeded()
        await stores.workspaceData.refreshAll([workspace])
        let probes = remote.prepareCalls
        XCTAssertEqual(adapter.refreshCalls, 1)
        XCTAssertEqual(probes, 1)
        now.addTimeInterval(3600) // Navigation must not take over the app's background refresh policy.
        for index in 0..<2 {
            let (view, window) = try host(projectHome(repository: repository).preferredColorScheme(index == 0 ? .light : .dark), stores: stores)
            let text = try await visibleText(view, snapshot: "mindwire-project-status-indicator-\(index)")
            XCTAssertTrue(text.contains("My app"), text)
            XCTAssertFalse(text.contains(t("workspace.status.checking")), text)
            window.isHidden = true
        }
        let (status, window) = try host(WorkspaceStatusSheet(repository: repository), stores: stores)
        defer { window.isHidden = true }
        let details = try await visibleText(status, snapshot: "mindwire-workspace-status-ready")
        XCTAssertTrue(details.contains(workspace.name), details)
        XCTAssertEqual(adapter.refreshCalls, 1)
        XCTAssertEqual(remote.prepareCalls, probes, "Returning to Projects or opening status must only read the shared cache")
        await repository.refreshChecks()
        XCTAssertEqual(adapter.refreshCalls, 2, "Explicit refresh still checks the workspace inventory")
        XCTAssertGreaterThan(remote.prepareCalls, probes)
        XCTAssertEqual(remote.invalidateCalls, 1, "Explicit refresh bypasses cached service health")
    }

    func testWorkspaceIssueCountDistinguishesStoppedWorkingAndFailedWorkspaces() throws {
        let stores = try stores()
        let workspaces = (0..<3).map {
            Workspace(id: UUID().uuidString, name: "Workspace \($0)", runtime: .server(serverId: "fixture"), createdAt: isoNow())
        }
        let repository = WorkspaceRepository(stores: stores, adapters: [ProjectWorkspaceFixture(workspaces: workspaces)])
        let coordinator = DaemonWorkCoordinator.shared
        defer { for workspace in workspaces { coordinator.forget(workspaceId: workspace.id) } }
        for workspace in workspaces { coordinator.recordHealth(.init(ok: false), for: .init(workspaceId: workspace.id)) }
        coordinator.recordWorkspaceStatus(.init(power: .stopped), for: .init(workspaceId: workspaces[0].id))
        let preparing = try XCTUnwrap(coordinator.states[.init(workspaceId: workspaces[1].id)])
        preparing.begin(.installingDaemon)
        let first = WorkspaceStatusOverview(repository: repository, stores: stores)
        XCTAssertEqual(first.attentionCount, 1, "Stopped and installing workspaces are not failures")
        XCTAssertEqual(first.preparingCount, 1)
        let stopped = try XCTUnwrap(coordinator.states[.init(workspaceId: workspaces[0].id)])
        stopped.powerError = "Start failed"
        XCTAssertEqual(WorkspaceStatusOverview(repository: repository, stores: stores).attentionCount, 2)
        coordinator.recordHealth(.init(ok: true, version: "1.2.3", workspaceMetadataVersion: 1, projectOperationsVersion: 1),
                                 for: .init(workspaceId: workspaces[2].id))
        stopped.powerError = nil
        XCTAssertEqual(WorkspaceStatusOverview(repository: repository, stores: stores).attentionCount, 0)
    }

    func testWorkspacePickerShowsSharedCardsAndReusesFreshInventory() async throws {
        let stores = try stores()
        let mac = Workspace(id: UUID().uuidString, name: "Design Mac", runtime: .server(serverId: "fixture-mac"),
                            createdAt: "2026-09-22T10:00:00Z", image: "macos")
        let linux = Workspace(id: UUID().uuidString, name: "Web development", runtime: .server(serverId: "fixture-linux"),
                              createdAt: "2026-09-22T09:00:00Z", image: "ubuntu:24.04")
        let rows = [mac, linux]
        stores.createProject(.init(name: "Website", workspaceId: mac.id, path: "/workspace/website"))
        let remote = WorkspaceRemoteFixture()
        remote.prepareError = URLError(.notConnectedToInternet)
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
                                                       resolveWorkspace: { id in rows.first { $0.id == id } })
        let adapter = ProjectWorkspaceFixture(workspaces: rows)
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        await repository.refresh()
        await stores.workspaceData.refreshAll(rows)
        let probes = remote.prepareCalls
        defer { for workspace in rows { DaemonWorkCoordinator.shared.forget(workspaceId: workspace.id) } }
        let coordinator = DaemonWorkCoordinator.shared
        let key = DaemonWorkKey(workspaceId: linux.id)
        coordinator.recordHealth(.init(ok: false), for: key)
        let setup = try XCTUnwrap(coordinator.states[key])
        setup.begin(.installingDaemon)
        setup.progress = 0.42
        setup.message = "Downloading Mindwire…"
        let (view, window) = try host(WorkspacePickerSheet(repository: repository, selectedWorkspaceId: mac.id) { _ in
            XCTFail("Opening the picker must not select a workspace")
        }.preferredColorScheme(.light), stores: stores)
        defer { window.isHidden = true }
        let text = try await visibleText(view, snapshot: "mindwire-project-workspace-picker")
        for title in [mac.name, linux.name, "macOS", "Ubuntu", t("workspaces.oneProject"), t("workspacePicker.title")] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains(title), text)
        }
        XCTAssertEqual(adapter.refreshCalls, 1, "Opening a picker reuses the shared inventory cache")
        XCTAssertEqual(remote.prepareCalls, probes, "Browsing existing workspace cards must not repeat service setup")

        let repo = GitHubRepo(owner: "fixture", name: "website", fullName: "fixture/website", isPrivate: false,
                              cloneUrl: "https://github.com/fixture/website.git", sshUrl: "git@github.com:fixture/website.git")
        for (preset, name) in [(nil as GitHubRepo?, "choice"), (repo, "details")] {
            let (form, formWindow) = try host(NewProjectScreen(presetWorkspaceId: mac.id, presetRepo: preset,
                                                              repository: repository), stores: stores)
            let selection = try await visibleText(form, snapshot: "mindwire-project-workspace-\(name)")
            XCTAssertTrue(selection.contains(mac.name), selection)
            XCTAssertTrue(selection.contains(t("workspacePicker.change")), selection)
            formWindow.isHidden = true
        }

        let catalog = ReleaseCatalog(defaults: stores.defaults, fetch: {
            DaemonCatalog(version: "1.2.3", agents: [
                AgentDescriptor(id: .claudeCode, name: "Claude Code", tagline: "Coding agent"),
                AgentDescriptor(id: .codex, name: "Codex", tagline: "Coding agent")
            ])
        })
        let (agentForm, agentWindow) = try host(NewAgentScreen(releaseCatalog: catalog, repository: repository), stores: stores)
        defer { agentWindow.isHidden = true }
        let selection = try await visibleText(agentForm, snapshot: "mindwire-agent-workspace-selection")
        XCTAssertTrue(selection.contains(mac.name), selection)
        XCTAssertTrue(selection.contains(t("workspacePicker.change")), selection)
        XCTAssertTrue(selection.contains(t("workspacePicker.add")), selection)
        XCTAssertEqual(adapter.refreshCalls, 1, "Project and agent creation share the same fresh inventory")
        XCTAssertEqual(remote.prepareCalls, probes, "Opening either creation form must not repeat service setup")
        XCTAssertTrue(stores.agents.list().isEmpty, "Browsing agent choices must not create an agent")
    }

    func testWorkspaceSetupKeepsItsProjectContext() async throws {
        let stores = try stores()
        let hint = t("newProject.workspace.setupHint")
        let (view, window) = try host(NewWorkspaceScreen(contextMessage: hint) { _ in
            XCTFail("Showing the workspace form must not create anything")
        }, stores: stores)
        defer { window.isHidden = true }
        let text = try await visibleText(view, snapshot: "mindwire-project-workspace-step")
        XCTAssertTrue(text.contains("project"), text)
        XCTAssertTrue(text.contains("files and agents"), text)
    }

    private func stores() throws -> Stores {
        let suite = "project-start-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    /// Include the tab bar in the existing visual check so the empty state uses the
    /// same available space as the real first tab, without loading other tabs' data.
    private func projectHome(repository: WorkspaceRepository) -> some View {
        TabView {
            Tab {
                NavigationStack { ProjectsScreen(repository: repository) }
            } label: { Label(t("tabs.projects"), icon: .project) }
            Tab { Color.clear } label: { Label(t("tabs.agents"), icon: Icon.agents) }
            Tab { Color.clear } label: { Label(t("tabs.workspaces"), icon: Icon.workspace) }
            Tab { Color.clear } label: { Label(t("tabs.settings"), icon: Icon.settings) }
        }
        .tint(Palette.accent)
    }

    private func host<V: View>(_ view: V, stores: Stores) throws -> (UIViewController, UIWindow) {
        let host = UIHostingController(rootView: view.environment(\.stores, stores).environment(AppModel(stores: stores))
            .labelIconToTitleSpacing(Spacing.md))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (host, window)
    }

    private func visibleText(_ host: UIViewController, snapshot: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(600))
        let image = ChatFeedSnapshot.image(host)
        let attachment = XCTAttachment(image: image)
        attachment.name = snapshot
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(snapshot).png")
        try image.pngData()?.write(to: url)
        print("PROJECT_START_SNAPSHOT_PATH=\(url.path)")
        return try ChatFeedSnapshot.visibleText(in: image).components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private final class ProjectWorkspaceFixture: WorkspaceAdapter {
    let workspaces: [Workspace]
    var error: Error?
    var refreshCalls = 0

    init(workspaces: [Workspace] = []) { self.workspaces = workspaces }
    func owns(_ workspace: Workspace) -> Bool { workspaces.contains { $0.id == workspace.id } }
    func current() -> [Workspace] { workspaces }
    func refresh() async throws {
        refreshCalls += 1
        if let error { throw error }
    }
    func adopt(name: String, runtime: AgentRuntime, spec: WorkspaceSpec?) async -> Workspace? { nil }
    func rename(_ id: String, to name: String) async {}
    func delete(_ id: String) async throws {}
}
