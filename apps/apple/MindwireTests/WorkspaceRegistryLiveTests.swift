import XCTest
@testable import Mindwire

/// Opt-in, loopback-only fixture. Start a disposable daemon on port 18791 with this test credential.
@MainActor
final class WorkspaceRegistryLiveTests: XCTestCase {
    func testRealProjectClientClonesAndFreshClientRestoresItsOperation() async throws {
        guard ProcessInfo.processInfo.environment["MINDWIRE_REGISTRY_E2E"] == "1",
              let root = ProcessInfo.processInfo.environment["MINDWIRE_PROJECT_FIXTURE"] else {
            throw XCTSkip("Start the disposable project fixture daemon and provide MINDWIRE_PROJECT_FIXTURE.")
        }
        let channel = URLSessionDaemonChannel(label: "project-fixture") { method, path, body, _ in
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18791" + path)!)
            request.httpMethod = method; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer mindwire-registry-fixture-only", forHTTPHeaderField: "Authorization")
            return request
        }
        let http = DaemonHTTP(channel: channel, agentType: "")
        let workspace = Workspace(id: "project-fixture", name: "Fixture", runtime: .server(serverId: "unused"), createdAt: "2026-09-16T00:00:00Z")
        let first = try cache(), second = try cache()
        let firstRemote = WorkspaceRegistryClient(workspace: workspace, stores: first, http: http)
        let secondRemote = WorkspaceRegistryClient(workspace: workspace, stores: second, http: http)
        let a = WorkspaceDataRepository(stores: first, makeRemote: { _ in firstRemote }, resolveWorkspace: { _ in workspace })
        let b = WorkspaceDataRepository(stores: second, makeRemote: { _ in secondRemote }, resolveWorkspace: { _ in workspace })
        let id = UUID().uuidString
        let request = ProjectCreateRequest(id: id, source: "clone", name: "Swift clone", path: root + "/swift-" + id, repoUrl: root + "/source")
        let started = try await a.startProject(request, workspaceId: workspace.id)
        var observed: [ProjectOperation] = []
        let completed = try await a.observeProject(started.id, workspaceId: workspace.id) { observed.append($0) }
        XCTAssertEqual(completed.status, "succeeded", completed.error ?? "")
        XCTAssertFalse(observed.isEmpty)
        let project = try await a.projectResult(completed, workspaceId: workspace.id)
        await b.refresh(workspace)
        XCTAssertNil(b.errors[workspace.id])
        XCTAssertEqual(second.projects.get(project.id), project)
        XCTAssertEqual(b.cachedProjectOperation(id, workspaceId: workspace.id)?.status, "succeeded")
        let same = try await b.startProject(request, workspaceId: workspace.id)
        XCTAssertEqual(same.sequence, completed.sequence)
        XCTAssertEqual(same.projectId, completed.projectId)
        let removal = try await b.removeProjectFiles(project.id)
        let removed = try await b.observeProject(removal.id, workspaceId: workspace.id) { _ in }
        XCTAssertEqual(removed.status, "succeeded", removed.error ?? "")
        XCTAssertTrue(removed.removesFiles)
        XCTAssertNil(second.projects.get(project.id))
        await a.refresh(workspace)
        XCTAssertNil(first.projects.get(project.id))
    }

    func testRealDaemonJSONRestoresTwoAppCachesAndAppliesCascadeDeletion() async throws {
        guard ProcessInfo.processInfo.environment["MINDWIRE_REGISTRY_E2E"] == "1" else {
            throw XCTSkip("Set MINDWIRE_REGISTRY_E2E=1 with the disposable local registry daemon running.")
        }
        let channel = URLSessionDaemonChannel(label: "registry-fixture") { method, path, body, _ in
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18791" + path)!)
            request.timeoutInterval = 5
            request.httpMethod = method
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer mindwire-registry-fixture-only", forHTTPHeaderField: "Authorization")
            return request
        }
        let http = DaemonHTTP(channel: channel, agentType: "")
        let health: DaemonHealth = try await http.decode("GET", "/healthz")
        XCTAssertEqual(health.workspaceMetadataVersion, 1)
        let prefix = UUID().uuidString
        let agentID = prefix + "-agent", projectID = prefix + "-project", chatID = prefix + "-chat"
        let _: WorkspaceMetadata = try await http.decode("PUT", "/workspace/agents/" + agentID,
            json: ["record": ["name": "Codex", "agentType": "codex"]])
        let root = ProcessInfo.processInfo.environment["MINDWIRE_PROJECT_FIXTURE"] ?? "/tmp"
        var operation: ProjectOperation = try await http.decode("POST", "/workspace/projects",
            json: ["id": projectID, "source": "create", "name": "Live fixture", "path": root + "/mindwire-project-fixture-" + projectID])
        for _ in 0..<100 where operation.isActive {
            try await Task.sleep(for: .milliseconds(20))
            operation = try await http.decode("GET", "/workspace/operations/" + operation.id)
        }
        XCTAssertEqual(operation.status, "succeeded")
        let snapshot: WorkspaceMetadata = try await http.decode("PUT", "/workspace/chats/" + chatID,
            json: ["record": ["agentId": agentID, "projectId": projectID, "title": "Build fixture"]])
        let first = try cache(), second = try cache()
        let firstData = WorkspaceDataRepository(stores: first), secondData = WorkspaceDataRepository(stores: second)
        try firstData.apply(snapshot, workspaceId: "local-connection")
        let restored: WorkspaceMetadata = try await http.decode("GET", "/workspace")
        try secondData.apply(restored, workspaceId: "local-connection")
        XCTAssertEqual(first.agents.list(), second.agents.list())
        XCTAssertEqual(first.projects.list(), second.projects.list())
        XCTAssertEqual(first.chats.list(), second.chats.list())
        XCTAssertEqual(second.projects.get(projectID)?.workspaceId, "local-connection")
        XCTAssertEqual(second.chats.get(chatID)?.agentId, agentID)
        XCTAssertEqual(second.chats.get(chatID)?.projectId, projectID)

        let projectRevision = try XCTUnwrap(first.projects.get(projectID)?.revision)
        let _: WorkspaceMetadata = try await http.decode("DELETE", "/workspace/projects/\(projectID)?revision=\(projectRevision)")
        let delta: WorkspaceMetadata = try await http.decode("GET",
            "/workspace/changes?since=\(snapshot.revision)&workspaceId=\(snapshot.workspaceId)")
        XCTAssertFalse(delta.full)
        try firstData.apply(delta, workspaceId: "local-connection")
        try secondData.apply(delta, workspaceId: "local-connection")
        XCTAssertNil(second.projects.get(projectID))
        XCTAssertNil(second.chats.get(chatID))
        XCTAssertNotNil(second.agents.get(agentID))
        XCTAssertEqual(first.chats.list(), second.chats.list())
        let revision = try XCTUnwrap(second.agents.get(agentID)?.revision)
        let _: WorkspaceMetadata = try await http.decode("DELETE", "/workspace/agents/\(agentID)?revision=\(revision)")
    }

    private func cache() throws -> Stores {
        let suite = "workspace-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }
}
