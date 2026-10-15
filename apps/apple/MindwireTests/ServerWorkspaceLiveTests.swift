import XCTest
@testable import Mindwire

/// A disposable Linux SSH server, with no preinstalled Mindwire service and no
/// model or cloud account. Never point this fixture at a personal server.
@MainActor
final class ServerWorkspaceLiveTests: XCTestCase {
    func testAddServerInstallsServiceAndReopensAWorkingWorkspace() async throws {
        guard let path = ProcessInfo.processInfo.environment["MINDWIRE_SERVER_LIVE_FIXTURE"] else {
            throw XCTSkip("Set MINDWIRE_SERVER_LIVE_FIXTURE to a disposable SSH server fixture.")
        }
        struct Fixture: Decodable {
            let host: String
            let port: Int
            let username: String
            let password: String
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let suite = "mindwire-server-live-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let stores = Stores(defaults: defaults)
        addTeardownBlock { @MainActor in
            for workspace in stores.workspaces.list() { Keychain.delete(KeychainKey.runtimeToken(workspace.id)) }
            for connection in stores.connections.list() { stores.deleteServer(connection.id) }
            defaults.removePersistentDomain(forName: suite)
        }
        let hostKey = "ssh.host." + Data("\(fixture.host):\(fixture.port)".utf8).base64EncodedString()
        Keychain.delete(hostKey)
        addTeardownBlock { Keychain.delete(hostKey) }
        let draft = ServerDraft(name: "Linux test server", host: " \(fixture.host)\n", port: String(fixture.port),
                                username: " \(fixture.username) ", secret: fixture.password)
        var stages: [String] = []
        let connection = try await stores.connectServer(from: draft, generateKey: true) { stages.append($0.title) }
        let remote = try XCTUnwrap(connection.remote)
        guard case .key(let ref) = remote.auth else { return XCTFail("Generated key was not saved") }
        XCTAssertNotNil(SSHKey.loadPrivateKey(ref))
        XCTAssertEqual(stages.count, 3)
        print("SERVER_CHECK verified password, installed key, authenticated new key and saved one connection")

        let runtime = try await SelfHostedProvisioner(connection: connection).provision(WorkspaceSpecs.selfHostedDefault, onStage: nil)
        let workspace = stores.createWorkspace(name: "Linux workspace", runtime: runtime)
        let backend = SelfHostedBackend(connection: connection)
        let coordinator = DaemonWorkCoordinator()
        let client = WorkspaceRegistryClient(workspace: workspace, stores: stores, coordinator: coordinator, backend: backend)
        addTeardownBlock { await client.dispose() }

        // This is the same registry preparation queued by New Workspace. It downloads
        // the released service, starts it and uses native SSH forwarding for HTTP/SSE.
        try await client.prepare(allowInstall: true)
        let http = try await client.gitHTTP()
        let health: DaemonHealth = try await http.decode("GET", "/healthz", quiet: true)
        XCTAssertTrue(health.ok)
        XCTAssertGreaterThanOrEqual(health.workspaceMetadataVersion ?? 0, 1)
        print("SERVER_CHECK installed and reached Mindwire \(health.version ?? "unknown") through SSH")

        let root = "/home/\(fixture.username)/server-workspace-" + UUID().uuidString
        let mkdir = try await backend.workspace.exec(["mkdir", "-p", root])
        XCTAssertEqual(mkdir.exitCode, 0)
        let gitInit = try await backend.workspace.exec(["git", "-C", root, "init", "-b", "main"])
        XCTAssertEqual(gitInit.exitCode, 0)
        let content = "Server workspace ✓\n"
        try await backend.workspace.writeFile(root + "/example.txt", content: content)
        let file = try await backend.workspace.readFile(root + "/example.txt")
        XCTAssertEqual(file.content, content)
        let files = try await backend.workspace.listFiles(root)
        XCTAssertTrue(files.contains { $0.name == "example.txt" })
        let resources = try await backend.workspace.getResources()
        XCTAssertGreaterThan(resources.cpus, 0)
        XCTAssertGreaterThan(resources.memoryMb, 0)

        let request = ProjectCreateRequest(id: UUID().uuidString, source: "folder", name: "SSH project", path: root)
        let started = try await client.startProject(request)
        let stream = try XCTUnwrap(client.projectOperationStream(started.id))
        var completed: ProjectOperation?
        for try await event in stream {
            if !event.isActive { completed = event; break }
        }
        XCTAssertEqual(completed?.status, "succeeded", completed?.error ?? "Project stream did not finish")
        let snapshot = try await client.snapshot()
        try stores.workspaceData.apply(snapshot, workspaceId: workspace.id)
        let projectID = try XCTUnwrap(completed?.projectId)
        let project = try XCTUnwrap(stores.projects.get(projectID))
        let git = try await client.projectGitStatus(project)
        XCTAssertEqual(git?.branch, "main")
        XCTAssertEqual(git?.files.map(\.path), ["example.txt"])

        // The same durable operations used by Source Control stage and unstage the file.
        let operations = GitOperationClient(http: http, workspaceId: workspace.id, registryId: snapshot.workspaceId,
            projectId: projectID, receipts: GitOperationClient.receipts(defaults: defaults))
        for action in [GitAction.stage, .unstage] {
            let operation = try await operations.start(.init(action: action, paths: ["example.txt"])) { nil }
            let result = try await operations.wait(operation) { _ in }
            XCTAssertEqual(result.status, "succeeded", result.error ?? "Git operation failed")
            let index = try await backend.workspace.exec(["git", "-C", root, "diff", "--cached", "--name-only"])
            XCTAssertEqual(index.stdout.trimmingCharacters(in: .whitespacesAndNewlines), action == .stage ? "example.txt" : "")
        }

        let terminal = SSHConnection.make(for: remote)
        defer { terminal.close() }
        let output = expectation(description: "Native terminal works on the saved server")
        var terminalText = ""
        var fulfilled = false
        let handle = try await terminal.startShell(cols: 80, rows: 24) { data in
            Task { @MainActor in
                terminalText += String(decoding: data, as: UTF8.self)
                if !fulfilled, terminalText.contains("MINDWIRE_SERVER_TERMINAL_OK") {
                    fulfilled = true; output.fulfill()
                }
            }
        }
        handle.send(Data("printf '\\nMINDWIRE_%s\\n' SERVER_TERMINAL_OK\n".utf8))
        await fulfillment(of: [output], timeout: 15)
        terminal.close()
        print("SERVER_CHECK file reads/writes, resources, project SSE, source control and native terminal passed")

        await client.dispose()
        let reopened = WorkspaceRegistryClient(workspace: workspace, stores: stores, coordinator: DaemonWorkCoordinator())
        addTeardownBlock { await reopened.dispose() }
        try await reopened.prepare(allowInstall: false)
        let restored = try await reopened.snapshot()
        XCTAssertEqual(restored.workspaceId, snapshot.workspaceId)
        XCTAssertEqual(restored.projects.map(\.id), snapshot.projects.map(\.id))
        XCTAssertEqual(stores.createWorkspace(name: "Retry", runtime: runtime).id, workspace.id)
        print("SERVER_CHECK fresh connection reused the running service, workspace and project without duplication")
    }
}
