import XCTest
@testable import Mindwire

@MainActor
final class ComputerConnectionTests: XCTestCase {
    private func invitation(expires: String = "2099-01-01T00:00:00Z", route: [String: Any]? = nil) throws -> String {
        let value: [String: Any] = ["version": 1, "computerId": "computer-test", "name": "My Mac", "pairingId": "pairing-test",
            "fingerprint": "SHA256:" + String(repeating: "a", count: 43), "secret": String(repeating: "b", count: 43),
            "routes": [route ?? ["kind": "ssh", "host": "computer.local", "port": 8791]], "expiresAt": expires]
        let data = try JSONSerialization.data(withJSONObject: value)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "mindwire://pair?v=1#" + encoded
    }

    func testInvitationRequiresExpiryPinAndSafeRoutes() throws {
        let valid = try ComputerInvitation.parse(invitation())
        XCTAssertEqual(valid.computerId, "computer-test")
        XCTAssertEqual(valid.routes.first?.host, "computer.local")
        XCTAssertThrowsError(try ComputerInvitation.parse(invitation(expires: "2000-01-01T00:00:00Z")))
        XCTAssertThrowsError(try ComputerInvitation.parse(invitation(route: ["kind": "websocket", "url": "http://computer.example/ssh"])))
        XCTAssertThrowsError(try ComputerInvitation.parse(invitation(route: ["kind": "websocket", "url": "wss://password@computer.example/ssh"])))
        XCTAssertThrowsError(try ComputerInvitation.parse("mindwire://pair#not-a-valid-invitation"))
        XCTAssertThrowsError(try ComputerInvitation.parse("old-placeholder-code"))
    }

    func testCompactQRUsesExistingJSONParserWithTheSameIdentityAndSecurityChecks() throws {
        let linked = try ComputerInvitation.parse(invitation())
        let compact = ComputerInvitation(version: 1, computerId: linked.computerId, name: "كمبيوتر — Mac",
            fingerprint: linked.fingerprint,
            routes: linked.routes + [ComputerRoute(kind: "websocket", url: "wss://computer.example/ssh")],
            pairingId: linked.pairingId, secret: linked.secret, expiresAt: linked.expiresAt)
        let data = try JSONEncoder().encode(compact)
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(try ComputerInvitation.parse(raw), compact)
        var unsafe = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in ["fingerprint", "secret", "expiresAt"] {
            var changed = unsafe
            changed[field] = field == "expiresAt" ? "2000-01-01T00:00:00Z" : "invalid"
            let text = String(decoding: try JSONSerialization.data(withJSONObject: changed), as: UTF8.self)
            XCTAssertThrowsError(try ComputerInvitation.parse(text))
        }
        unsafe["routes"] = [["kind": "websocket", "url": "http://computer.example/ssh"]]
        XCTAssertThrowsError(try ComputerInvitation.parse(String(decoding: JSONSerialization.data(withJSONObject: unsafe), as: UTF8.self)))
    }

    func testPairedComputerUsesExistingWorkspaceAndNeverStoresSecretsInCache() throws {
        let suite = "computer-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let invite = try ComputerInvitation.parse(invitation())
        let computer = PairedComputer(computerId: invite.computerId, registryId: "registry", deviceId: "phone-key-id",
            fingerprint: invite.fingerprint, routes: invite.routes, keyRef: "key-reference", tokenRef: "token-reference")
        let host = try JSONDecoder().decode(ComputerHost.self, from: Data(#"{"hostname":"Mac","os":"darwin","arch":"arm64","home":"/Users/test","directory":"/Users/test","pid":123}"#.utf8))
        let result = ComputerPairingService.Result(invitation: invite, computer: computer, host: host)
        let first = stores.savePairedComputer(result, name: "My Mac")
        let second = stores.savePairedComputer(result, name: "My Mac")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(stores.connections.list().count, 1)
        XCTAssertEqual(stores.workspaces(forServerId: first.id).count, 1)
        let cached = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        XCTAssertFalse(cached.contains(invite.secret))
        XCTAssertFalse(cached.contains("mindwire://pair"))
        let backend = BackendFactory.make(for: first)
        XCTAssertTrue(backend.workspace is ComputerWorkspaceService)
        XCTAssertTrue(BackendFactory.daemonChannel(forBackend: backend) is ComputerDaemonChannel)
        XCTAssertTrue(BackendFactory.daemonInstaller(forBackend: backend) is ComputerDaemonInstaller)
        XCTAssertTrue(TerminalSessionFactory.provider(forConnection: first) is DaemonTerminalProvider)
        XCTAssertTrue(TerminalSessionFactory.provider(for: stores.workspaces(forServerId: first.id).first, stores: stores) is DaemonTerminalProvider)
    }

    func testEditingSSHConnectionKeepsWorkspaceIdentityAndSavedCredential() throws {
        let suite = "connection-edit-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let remote = RemoteHostConnection(id: UUID().uuidString, name: "Home server", type: .ssh,
            host: "server.example", port: 22, username: "owner", auth: .key(secretRef: "saved-key"), createdAt: isoNow())
        stores.connections.save(.ssh(remote))
        let workspace = stores.createWorkspace(name: "My work", runtime: .server(serverId: remote.id))
        var draft = ServerDraft(editing: remote)
        XCTAssertTrue(draft.secret.isEmpty, "Editing must not load a saved secret into the form")
        draft.name = "Renamed server"; draft.host = "server.tailnet"; draft.port = "2222"
        let edited = try stores.updateServer(remote.id, from: draft)
        XCTAssertEqual(edited.id, remote.id)
        XCTAssertEqual(edited.remote?.auth, remote.auth)
        XCTAssertEqual(edited.remote?.port, 2222)
        XCTAssertEqual(stores.connections.list().count, 1)
        XCTAssertEqual(stores.workspaces(forServerId: remote.id).map(\.id), [workspace.id])
        draft.authMethod = .password
        XCTAssertThrowsError(try stores.updateServer(remote.id, from: draft))
        XCTAssertEqual(stores.connections.get(remote.id), edited, "A rejected auth change must leave the connection intact")
        draft.authMethod = .key; draft.port = "70000"
        XCTAssertThrowsError(try stores.updateServer(remote.id, from: draft))
        XCTAssertEqual(stores.connections.get(remote.id), edited)
    }

    func testReconnectCodePreservesIdentityAndRejectsWrongKindExpiredAndUnsafeRoutes() throws {
        let invite = try ComputerInvitation.parse(invitation())
        let code = ComputerReconnectCode(version: 1, mode: "reconnect", computerId: invite.computerId,
            registryId: "registry", name: invite.name, fingerprint: invite.fingerprint,
            routes: [ComputerRoute(kind: "websocket", url: "wss://new-laptop.example/ssh")], expiresAt: invite.expiresAt)
        let data = try JSONEncoder().encode(code)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(try ComputerConnectionCode.parse(text), .reconnect(code))
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(try ComputerConnectionCode.parse("mindwire://reconnect?v=1#" + encoded), .reconnect(code))
        XCTAssertThrowsError(try ComputerInvitation.parse(text), "An address refresh must never become a pairing invitation")
        XCTAssertThrowsError(try ComputerConnectionCode.parse("mindwire://pair?v=1#" + encoded))
        for (field, value) in [("expiresAt", "2000-01-01T00:00:00Z"), ("mode", "other"), ("fingerprint", "wrong"), ("registryId", "")] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object[field] = value
            XCTAssertThrowsError(try ComputerConnectionCode.parse(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)))
        }
    }

    func testReconnectRejectsUnknownAndChangedIdentityWithoutReplacingSavedWorkspace() async throws {
        let suite = "reconnect-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let invite = try ComputerInvitation.parse(invitation())
        let computer = PairedComputer(computerId: invite.computerId, registryId: "registry", deviceId: "saved-device",
            fingerprint: invite.fingerprint, routes: invite.routes, keyRef: "saved-key", tokenRef: "saved-token")
        let code = ComputerReconnectCode(version: 1, mode: "reconnect", computerId: computer.computerId,
            registryId: "wrong-registry", name: "Renamed", fingerprint: computer.fingerprint,
            routes: [ComputerRoute(kind: "websocket", url: "wss://new-laptop.example/ssh")], expiresAt: invite.expiresAt)
        let text = String(decoding: try JSONEncoder().encode(code), as: UTF8.self)
        do {
            _ = try await ComputerPairingService.pair(text, deviceName: "phone", stores: stores) { _ in }
            XCTFail("An unpaired phone accepted an address-only code")
        } catch ComputerConnectionError.notPaired {} catch { XCTFail("Unexpected error: \(error)") }
        let host = try JSONDecoder().decode(ComputerHost.self, from: Data(#"{"hostname":"Laptop","os":"linux","arch":"amd64","home":"/home/me","directory":"/home/me","pid":12}"#.utf8))
        let first = stores.savePairedComputer(.init(invitation: invite, computer: computer, host: host), name: "My laptop")
        let workspace = try XCTUnwrap(stores.workspaces(forServerId: first.id).first)
        do {
            _ = try await ComputerPairingService.pair(text, deviceName: "phone", stores: stores) { _ in }
            XCTFail("Changed registry was accepted")
        } catch ComputerConnectionError.identityChanged {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(stores.connections.get(first.id), first)
        var updated = computer
        updated.routes = code.routes
        let refreshed = stores.savePairedComputer(.init(computer: updated, host: host), name: "")
        XCTAssertEqual(refreshed.id, first.id)
        XCTAssertEqual(refreshed.name, first.name)
        XCTAssertEqual(refreshed.pairedComputer?.keyRef, computer.keyRef)
        XCTAssertEqual(refreshed.pairedComputer?.tokenRef, computer.tokenRef)
        XCTAssertEqual(refreshed.pairedComputer?.deviceId, computer.deviceId)
        XCTAssertEqual(stores.connections.list().count, 1)
        XCTAssertEqual(stores.workspaces(forServerId: first.id).map(\.id), [workspace.id])
    }
}

/// Uses only a disposable daemon on the development Mac. The host-side fixture
/// approves this exact invitation; no production credentials or model calls.
@MainActor
final class ComputerConnectionLiveTests: XCTestCase {
    override class func tearDown() {
        // Only the development fixture copied into the phone's Documents folder
        // is owned by this suite. Leave host-supplied fixture paths to the runner.
        if ProcessInfo.processInfo.environment["MINDWIRE_COMPUTER_FIXTURE"] == "computer-fixture.json",
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent("computer-fixture.json"))
        }
        super.tearDown()
    }

    func testDirectPairingWorkspaceAndTerminalRecovery() async throws { try await exercise("direct") }
    func testWebSocketPairingWorkspaceAndTerminalRecovery() async throws { try await exercise("websocket") }

    private func exercise(_ route: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["MINDWIRE_COMPUTER_FIXTURE"] else {
            throw XCTSkip("Start the disposable computer fixture and set MINDWIRE_COMPUTER_FIXTURE.")
        }
        let fixtureURL = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first).appendingPathComponent(path)
        let fixtures = try JSONDecoder().decode([String: ComputerInvitation].self, from: Data(contentsOf: fixtureURL))
        let invitation = try XCTUnwrap(fixtures[route])
        let text = String(decoding: try JSONEncoder().encode(invitation), as: UTF8.self)
        let result = try await ComputerPairingService.pair(text, deviceName: "Mindwire integration iPhone") { status in
            print("Computer fixture (\(route)): \(status.components(separatedBy: "\n").first ?? status)")
        }
        print("Computer fixture (\(route)): paired; checking workspace")
        defer { Keychain.delete(result.computer.keyRef); Keychain.delete(result.computer.tokenRef) }
        XCTAssertEqual(result.computer.computerId, invitation.computerId)
        try await verifyAddressRefresh(result, routes: invitation.routes)
        // Keep this test on only the route it is exercising, even if the daemon
        // returned other saved routes after the approval handshake.
        var computer = result.computer
        computer.routes = invitation.routes
        if route == "websocket" {
            let key = try XCTUnwrap(SSHKey.loadPrivateKey(computer.keyRef))
            let started = Date()
            let selected = try await ComputerSSHLink.open(
                routes: [ComputerRoute(kind: "ssh", host: "192.0.2.1", port: 8791)] + computer.routes,
                username: "device", auth: .privateKey(key), fingerprint: computer.fingerprint,
                port: 8790, token: Keychain.get(computer.tokenRef))
            selected.ssh.close()
            XCTAssertLessThan(Date().timeIntervalSince(started), 4,
                "A successful internet connection must not wait for an unreachable LAN route")
        }
        let workspace = ComputerWorkspaceService(computer: computer)
        addTeardownBlock { await workspace.channel.close() }
        let http = DaemonHTTP(channel: workspace.channel, agentType: "")
        let health: DaemonHealth = try await http.decode("GET", "/healthz", quiet: true)
        XCTAssertEqual(health.computerConnectionVersion, 1)
        XCTAssertEqual(health.terminalProtocolVersion, 1)
        XCTAssertTrue(workspace.capabilities.terminal)
        let id = UUID().uuidString
        let directory = result.host.directory + "/swift-computer-" + id
        let created = try await workspace.exec(["mkdir", "-p", directory])
        XCTAssertEqual(created.exitCode, 0)
        try await workspace.writeFile(directory + "/hello.txt", content: "Native file ✓\nمرحبا")
        let read = try await workspace.readFile(directory + "/hello.txt")
        XCTAssertEqual(read.content, "Native file ✓\nمرحبا")
        let files = try await workspace.listFiles(directory)
        XCTAssertEqual(files.map(\.name), ["hello.txt"])
        let resources = try await workspace.getResources()
        XCTAssertGreaterThan(resources.cpus, 0)
        print("Computer fixture (\(route)): files and resources passed")

        // Workspace metadata uses the existing durable project operation and SSE.
        let started: ProjectOperation = try await http.decode("POST", "/workspace/projects", json: [
            "id": id, "source": "folder", "name": "Computer fixture", "path": directory
        ], quiet: true)
        let stream = try await workspace.channel.stream(method: "GET", path: "/workspace/operations/\(started.id)/stream", jsonBody: nil)
        var finished: ProjectOperation?
        for try await bytes in stream {
            let value = try JSONDecoder().decode(ProjectOperation.self, from: bytes)
            if !value.isActive { finished = value; break }
        }
        XCTAssertEqual(finished?.status, "succeeded", finished?.error ?? "")
        let metadata: WorkspaceMetadata = try await http.decode("GET", "/workspace", quiet: true)
        XCTAssertTrue(metadata.projects.contains { $0.id == finished?.projectId && $0.path.hasSuffix("/swift-computer-" + id) },
            "The durable operation must register the project, including canonicalized host paths")
        var output = ""
        for try await event in workspace.execStream(["/bin/sh", "-c", "printf 'first'; sleep .1; printf 'second'"]) {
            if case .output(let bytes) = event { output += String(decoding: bytes, as: UTF8.self) }
        }
        XCTAssertEqual(output, "firstsecond")
        print("Computer fixture (\(route)): project metadata and streaming exec passed")

        try await verifyPrivateForward(workspace: workspace, computer: computer)

        let network = ComputerNetworkMonitor(observeSystem: false)
        network.update(.init(reachable: true, interfaces: ["wifi"]))
        let firstProvider = DaemonTerminalProvider(computer: computer, workdir: directory, network: network)
        let first = firstProvider.newSession()
        let ready = expectation(description: "Live terminal output")
        let handoff = expectation(description: "Live terminal survives a network handoff")
        var firstOutput = "", didReady = false, didHandoff = false
        first.onOutput = { bytes in
            firstOutput += String(decoding: bytes, as: UTF8.self)
            if !didReady, firstOutput.contains("NATIVE_READY") { didReady = true; ready.fulfill() }
            if !didHandoff, firstOutput.contains("NETWORK_RECOVERED") { didHandoff = true; handoff.fulfill() }
        }
        first.resize(cols: 80, rows: 24); first.start()
        first.send(Data("printf 'NATIVE_%s\\n' 'READY'\n".utf8))
        await fulfillment(of: [ready], timeout: 20)
        network.update(.init(reachable: false))
        first.send(Data("printf x >> handoff-count; printf 'NETWORK_%s\\n' 'RECOVERED'\n".utf8))
        try await Task.sleep(for: .milliseconds(150))
        network.update(.init(reachable: true, interfaces: ["cellular"]))
        await fulfillment(of: [handoff], timeout: 15)
        let count = try await workspace.readFile(directory + "/handoff-count")
        XCTAssertEqual(count.content, "x", "An interrupted input acknowledgement must not execute the command twice")
        let terminals: [DaemonTerminalState] = try await http.decode("GET", "/workspace/terminals?directory=\(http.encQuery(directory))", quiet: true)
        XCTAssertEqual(terminals.count, 1)
        first.stop(); firstProvider.teardown()

        let secondProvider = DaemonTerminalProvider(computer: computer, workdir: directory)
        let restored = await secondProvider.restoreSessions()
        XCTAssertEqual(restored.count, 1)
        let second = try XCTUnwrap(restored.first)
        let replayed = expectation(description: "Restored terminal screen")
        let resumed = expectation(description: "Reconnected live input")
        var secondOutput = "", didReplay = false, didResume = false
        second.onOutput = { bytes in
            secondOutput += String(decoding: bytes, as: UTF8.self)
            if !didReplay, secondOutput.contains("NATIVE_READY") { didReplay = true; replayed.fulfill() }
            if !didResume, secondOutput.contains("NATIVE_RESUMED") { didResume = true; resumed.fulfill() }
        }
        second.resize(cols: 92, rows: 30); second.start()
        await fulfillment(of: [replayed], timeout: 15)
        second.send(Data("printf 'NATIVE_%s\\n' 'RESUMED'\n".utf8))
        await fulfillment(of: [resumed], timeout: 15)
        let after: [DaemonTerminalState] = try await http.decode("GET", "/workspace/terminals?directory=\(http.encQuery(directory))", quiet: true)
        XCTAssertEqual(after.map(\.id), terminals.map(\.id), "Reconnect must attach to the original shell")
        second.kill(); secondProvider.teardown()
        for _ in 0..<50 {
            let remaining: [DaemonTerminalState] = try await http.decode("GET", "/workspace/terminals?directory=\(http.encQuery(directory))", quiet: true)
            if remaining.isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Closing the terminal tab did not terminate its PTY")
    }

    private func verifyAddressRefresh(_ result: ComputerPairingService.Result, routes: [ComputerRoute]) async throws {
        let suite = "live-computer-refresh-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let original = stores.savePairedComputer(result, name: "Saved laptop")
        let workspaceIDs = stores.workspaces(forServerId: original.id).map(\.id)
        defer { for id in workspaceIDs { DaemonWorkCoordinator.shared.forget(workspaceId: id) } }
        let repository = WorkspaceRepository(stores: stores, adapters: [LocalWorkspaceAdapter(stores: stores)])
        let key = Keychain.get(result.computer.keyRef), token = Keychain.get(result.computer.tokenRef)
        stores.updateComputerRoutes([ComputerRoute(kind: "ssh", host: "192.0.2.1", port: 1)], for: result.computer)
        let code = ComputerReconnectCode(version: 1, mode: "reconnect", computerId: result.computer.computerId,
            registryId: result.computer.registryId, name: result.host.hostname, fingerprint: result.computer.fingerprint,
            routes: routes, expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(120)))
        let saved = try await repository.reconnectComputer(original.id,
            code: String(decoding: JSONEncoder().encode(code), as: UTF8.self))
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.name, original.name)
        XCTAssertEqual(saved.pairedComputer?.deviceId, result.computer.deviceId)
        XCTAssertEqual(Keychain.get(result.computer.keyRef), key)
        XCTAssertEqual(Keychain.get(result.computer.tokenRef), token)
        XCTAssertEqual(stores.workspaces(forServerId: original.id).map(\.id), workspaceIDs)
        XCTAssertEqual(stores.connections.list().count, 1)
        XCTAssertTrue(saved.pairedComputer?.routes.contains(where: { $0.kind == routes[0].kind }) == true)
        let resumed = try await repository.reconnectComputer(original.id)
        XCTAssertEqual(resumed.id, saved.id, "Retrying a saved address must not require another code or workspace")
        XCTAssertEqual(resumed.pairedComputer?.deviceId, result.computer.deviceId)
        print("Computer fixture: address refreshed with original keys and workspace")
    }

    private func verifyPrivateForward(workspace: ComputerWorkspaceService, computer: PairedComputer) async throws {
        let ready = expectation(description: "Temporary preview server")
        var port: Int?
        let server = Task { @MainActor in
            var output = ""
            for try await event in workspace.execStream(["node", "-e", "const s=require('http').createServer((q,r)=>r.end('mindwire-private-preview'));s.listen(0,'127.0.0.1',()=>console.log(s.address().port));setTimeout(()=>s.close(),90000)"]) {
                if case .output(let bytes) = event {
                    output += String(decoding: bytes, as: UTF8.self)
                    if port == nil, let value = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        port = value; ready.fulfill()
                    }
                }
            }
        }
        defer { server.cancel() }
        await fulfillment(of: [ready], timeout: 20)
        let remotePort = try XCTUnwrap(port)
        let connection = Connection.local(LocalConnection(id: UUID().uuidString, name: "Preview fixture", deviceName: "Mac",
            pairingId: "fixture", computer: computer, createdAt: isoNow()))
        let network = ComputerNetworkMonitor(observeSystem: false)
        network.update(.init(reachable: true, interfaces: ["wifi"]))
        let manager = ConnectionPortForwards(network: network)
        let forward = manager.open(connection: connection, port: remotePort)
        defer { manager.close(forward) }
        XCTAssertTrue(manager.open(connection: connection, port: remotePort) === forward, "Repeated taps must reuse one forward")
        for _ in 0..<200 {
            if forward.url != nil || forward.error != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let url = try XCTUnwrap(forward.url, forward.error ?? "Forward did not become ready")
        let (body, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "mindwire-private-preview")
        network.update(.init(reachable: true, interfaces: ["cellular"]))
        for _ in 0..<100 {
            if forward.url == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(forward.url, "A path change must close the old forward promptly")
        for _ in 0..<150 {
            if forward.url != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(forward.url, url, "Recovery must retain the preview's local address")
        let (recoveredBody, _) = try await URLSession.shared.data(from: url)
        XCTAssertEqual(String(decoding: recoveredBody, as: UTF8.self), "mindwire-private-preview")
        manager.close(forward)
        XCTAssertNil(forward.url)
        XCTAssertTrue(manager.sessions.isEmpty)
        struct Grant: Decodable { let id: String }
        let http = DaemonHTTP(channel: workspace.channel, agentType: "")
        for _ in 0..<50 {
            let grants: [Grant] = try await http.decode("GET", "/computer/forwards", quiet: true)
            if !grants.contains(where: { $0.id == forward.id }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Closing the forward did not revoke its daemon grant")
    }
}
