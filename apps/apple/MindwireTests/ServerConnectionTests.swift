import XCTest
@testable import Mindwire

@MainActor
final class ServerConnectionTests: XCTestCase {
    func testInvalidAddressesAndCredentialsNeverCreateSavedServers() throws {
        let stores = makeStores()
        let valid = ServerDraft(host: "server.example", username: "node", secret: "password")
        var invalid: [ServerDraft] = []
        for host in ["", "https://server.example", "node@server.example", "server example"] {
            var draft = valid; draft.host = host; invalid.append(draft)
        }
        for port in ["0", "65536", "ssh"] {
            var draft = valid; draft.port = port; invalid.append(draft)
        }
        var key = valid; key.authMethod = .key; key.secret = "not a private key"; invalid.append(key)
        var missing = valid; missing.secret = ""; invalid.append(missing)
        for draft in invalid { XCTAssertThrowsError(try stores.saveServer(from: draft)) }
        XCTAssertTrue(stores.connections.list().isEmpty)

        let ipv6 = try ServerDraft(host: " [::1]\n", username: " node ", secret: " keep spaces ").normalizedRemote()
        XCTAssertEqual(ipv6.host, "::1")
        XCTAssertEqual(ipv6.username, "node")
        XCTAssertEqual(ipv6.secret, " keep spaces ")
    }

    func testVerifiedServerSavesTheSameNormalizedAddressItTestedWithoutInlineSecrets() async throws {
        let fixture = try await fixture()
        let stores = makeStores()
        var draft = draft(for: fixture)
        draft.host = " \(draft.host)\n"; draft.username = " fixture "; draft.port = " \(draft.port)\n"
        let connection = try await stores.connectServer(from: draft)
        let remote = try XCTUnwrap(connection.remote)
        XCTAssertEqual(remote.host, "127.0.0.1")
        XCTAssertEqual(remote.username, "fixture")
        XCTAssertEqual(remote.port, fixture.route.port)
        XCTAssertEqual(stores.connections.list().map(\.id), [connection.id])
        guard case .password(let ref) = remote.auth else { return XCTFail("Expected password authentication") }
        XCTAssertEqual(Keychain.get(ref), draft.secret)
        let saved = String(decoding: try JSONEncoder().encode(connection), as: UTF8.self)
        XCTAssertFalse(saved.contains("\"secret\":\"fixture\""))
        XCTAssertEqual(fixture.connections, 1)
        XCTAssertEqual(fixture.shellRequests, 1)

        let runtime = try await SelfHostedProvisioner(connection: connection).provision(WorkspaceSpecs.selfHostedDefault, onStage: nil)
        let workspace = stores.createWorkspace(name: "Server", runtime: runtime)
        let reopened = stores.createWorkspace(name: "Server again", runtime: runtime)
        XCTAssertEqual(runtime, .server(serverId: connection.id))
        XCTAssertEqual(workspace.id, reopened.id)
        XCTAssertEqual(stores.workspaces.list().count, 1)
    }

    func testRejectedPasswordDoesNotSaveNewConnectionOrReplaceExistingCredential() async throws {
        let fixture = try await fixture()
        let stores = makeStores()
        var draft = draft(for: fixture)
        let original = try stores.saveServer(from: draft)
        draft.secret = "incorrect-password"
        for editingId in [nil, original.id] {
            do {
                _ = try await stores.connectServer(from: draft, editingId: editingId)
                XCTFail("Rejected credentials must not be saved")
            } catch { XCTAssertTrue(error is SSHAuthenticationError, "\(error)") }
        }
        XCTAssertEqual(stores.connections.list(), [original])
        guard case .password(let ref) = original.remote?.auth else { return XCTFail("Expected password") }
        XCTAssertEqual(Keychain.get(ref), "fixture")
    }

    func testKeyInstallSuccessAloneCannotReplaceWorkingPassword() async throws {
        // This SSH server reports install success but refuses the newly generated key.
        let fixture = try await fixture()
        let stores = makeStores()
        let original = try stores.saveServer(from: draft(for: fixture))
        do {
            try await stores.setUpServerKey(original.id)
            XCTFail("The generated key must authenticate before replacing the password")
        } catch { XCTAssertTrue(error.localizedDescription.contains("SSH key setup failed")) }
        XCTAssertEqual(fixture.keyRequests, 1)
        XCTAssertEqual(stores.connections.get(original.id), original)
        let ssh = SSHConnection.make(for: try XCTUnwrap(original.remote))
        defer { ssh.close() }
        try await ssh.authenticate()
    }

    func testCancellingAddClosesItsSSHWorkAndLeavesNoSavedConnection() async throws {
        let fixture = try await fixture(pending: true)
        let stores = makeStores()
        let draft = draft(for: fixture)
        let operation = Task { try await stores.connectServer(from: draft) }
        try await eventually { fixture.activeStreams == 1 }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled setup must not finish") }
        catch {}
        try await eventually { fixture.activeStreams == 0 }
        XCTAssertTrue(stores.connections.list().isEmpty)
    }

    func testEditCannotOverwriteConnectionChangedWhileItWasChecking() async throws {
        let fixture = try await fixture(pending: true)
        let stores = makeStores()
        let original = try stores.saveServer(from: draft(for: fixture))
        let edit = ServerDraft(editing: try XCTUnwrap(original.remote))
        let operation = Task { try await stores.connectServer(from: edit, editingId: original.id) }
        try await eventually { fixture.activeStreams == 1 }
        stores.renameServer(original.id, name: "Changed elsewhere")
        fixture.finish()
        do { _ = try await operation.value; XCTFail("The newer connection must be preserved") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed during setup")) }
        XCTAssertEqual(stores.connections.get(original.id)?.name, "Changed elsewhere")
    }

    func testNonzeroRemoteExitCannotReportHealthyOrProvisionWorkspace() async throws {
        let fixture = try await fixture(exitCode: 1)
        let stores = makeStores()
        let saved = try stores.saveServer(from: draft(for: fixture))
        let backend = SelfHostedBackend(connection: saved)
        let health = await backend.healthCheck()
        XCTAssertFalse(health.ok)
        do { _ = try await backend.workspace.status(); XCTFail("Failed shell is not a running workspace") }
        catch {}
        await backend.dispose()
        do {
            _ = try await SelfHostedProvisioner(connection: saved).provision(WorkspaceSpecs.selfHostedDefault, onStage: nil)
            XCTFail("Failed shell cannot provision a workspace")
        } catch {}
    }

    func testRemovedServerExplainsWhyWorkspaceCreationCannotContinue() async {
        let model = NewWorkspaceModel()
        model.selectedServerId = "removed-server"
        let runtime = await model.provision(servers: [])
        XCTAssertNil(runtime)
        XCTAssertFalse(model.isProvisioning)
        XCTAssertTrue(model.errorMessage?.contains("no longer saved") == true)
    }

    private func makeStores() -> Stores {
        let suite = "mindwire-server-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let stores = Stores(defaults: defaults)
        addTeardownBlock { @MainActor in
            for connection in stores.connections.list() { stores.deleteServer(connection.id) }
            defaults.removePersistentDomain(forName: suite)
        }
        return stores
    }

    private func fixture(pending: Bool = false, exitCode: Int = 0) async throws -> SSHHTTPFixture {
        let fixture = try await SSHHTTPFixture.start(commandResult: { _ in
            pending ? nil : ExecResult(exitCode: exitCode, stdout: "", stderr: "")
        })
        let key = "ssh.host." + Data("127.0.0.1:\(fixture.route.port!)".utf8).base64EncodedString()
        Keychain.delete(key)
        addTeardownBlock { await fixture.stop(); Keychain.delete(key) }
        return fixture
    }

    private func draft(for fixture: SSHHTTPFixture) -> ServerDraft {
        ServerDraft(host: "127.0.0.1", port: String(fixture.route.port!), username: "fixture", secret: "fixture")
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The SSH fixture did not reach the expected state")
    }
}
