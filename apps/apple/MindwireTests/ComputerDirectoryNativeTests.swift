import XCTest
@testable import Mindwire

@MainActor
final class ComputerDirectoryNativeTests: XCTestCase {
    private struct Fixture: Decodable { let invitation: ComputerInvitation; let directory: String; let pid: Int }
    private struct Terminal: Decodable { let id: String; let running: Bool; let createdAt: String }
    private struct FileContents: Decodable { let content: String }
    private struct Host: Decodable { let pid: Int }

    func testChangedTunnelAddressReconnectsWithoutQRCodeAndDirectoryOutageKeepsCachedRoutes() async throws {
        guard let file = ProcessInfo.processInfo.environment["MINDWIRE_DIRECTORY_FIXTURE"] else {
            throw XCTSkip("Requires the disposable computer-directory-fixture.ts server.")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        var completed = false
        defer { if !completed { try? Data().write(to: URL(fileURLWithPath: fixture.directory + "/failed")) } }
        func mark(_ name: String) throws { try Data().write(to: URL(fileURLWithPath: fixture.directory + "/" + name)) }
        func wait(_ name: String) async throws {
            let end = Date().addingTimeInterval(40)
            while !FileManager.default.fileExists(atPath: fixture.directory + "/" + name), Date() < end { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory + "/" + name))
        }
        let suite = "native-directory-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), stores = Stores(defaults: defaults)
        let code = String(decoding: try JSONEncoder().encode(fixture.invitation), as: UTF8.self)
        let paired = try await ComputerPairingService.pair(code, deviceName: "Mindwire directory test iPhone", stores: stores) { _ in }
        XCTAssertNotNil(paired.computer.discovery)
        let saved = stores.savePairedComputer(paired, name: "Directory fixture")
        defer { stores.deleteServer(saved.id); defaults.removePersistentDomain(forName: suite) }
        let seed = try XCTUnwrap(Keychain.get(paired.computer.keyRef))
        let network = ComputerNetworkMonitor(observeSystem: false)
        network.update(.init(reachable: true, interfaces: ["wifi"]))
        let first = ComputerDaemonChannel(computer: paired.computer, network: network, stores: stores)
        let second = ComputerDaemonChannel(computer: paired.computer, network: network, stores: stores)
        let http = DaemonHTTP(channel: first, agentType: ""), other = DaemonHTTP(channel: second, agentType: "")
        let filename = fixture.directory + "/native-file.txt"
        _ = try await http.run("PUT", "/workspace/file", json: ["path": filename, "content": "Address changed; work preserved ✓"], quiet: true)
        let terminal: Terminal = try await http.decode("POST", "/workspace/terminals",
            json: ["id": "directory-native", "directory": fixture.directory, "columns": 80, "rows": 24], quiet: true)
        XCTAssertTrue(terminal.running)
        let oldRoutes = stores.savedComputer(matching: paired.computer)?.routes
        network.update(.init(reachable: false))
        try mark("rotate"); try await wait("rotated")
        network.update(.init(reachable: true, interfaces: ["cellular"]))
        async let resumed: Terminal = http.decode("GET", "/workspace/terminals/directory-native", quiet: true)
        async let fileValue: FileContents = other.decode("GET", "/workspace/file?path=\(other.encQuery(filename))", quiet: true)
        let (after, contents) = try await (resumed, fileValue)
        XCTAssertTrue(after.running); XCTAssertEqual(after.createdAt, terminal.createdAt)
        XCTAssertEqual(contents.content, "Address changed; work preserved ✓")
        XCTAssertNotEqual(stores.savedComputer(matching: paired.computer)?.routes, oldRoutes)
        XCTAssertGreaterThan(ComputerDirectoryService.credential(for: paired.computer)?.sequence ?? 0, 0)
        XCTAssertEqual(stores.connections.list().count, 1)
        XCTAssertEqual(Keychain.get(paired.computer.keyRef), seed)
        // Opening after a network change must still work with the directory down
        // when the last verified route remains reachable.
        network.update(.init(reachable: false))
        try mark("directory-offline"); try await wait("directory-down")
        network.update(.init(reachable: true, interfaces: ["wifi-again"]))
        let host: Host = try await http.decode("GET", "/workspace/host", quiet: true)
        XCTAssertEqual(host.pid, fixture.pid)
        _ = try await http.run("DELETE", "/workspace/terminals/directory-native", json: nil, quiet: true)
        await first.close(); await second.close()
        let credential = try XCTUnwrap(ComputerDirectoryService.credential(for: paired.computer))
        try mark("restart-service"); try await wait("service-restarted")
        let restarted = ComputerDaemonChannel(computer: paired.computer, network: network, stores: stores)
        let restartedHTTP = DaemonHTTP(channel: restarted, agentType: "")
        let newHost: Host = try await restartedHTTP.decode("GET", "/workspace/host", quiet: true)
        XCTAssertNotEqual(newHost.pid, fixture.pid)
        let preserved: FileContents = try await restartedHTTP.decode("GET", "/workspace/file?path=\(restartedHTTP.encQuery(filename))", quiet: true)
        XCTAssertEqual(preserved.content, "Address changed; work preserved ✓")
        XCTAssertEqual(stores.connections.list().map(\.id), [saved.id])
        XCTAssertEqual(Keychain.get(paired.computer.keyRef), seed)
        XCTAssertTrue(ComputerDirectoryService.credential(for: paired.computer)?.secret == credential.secret)
        XCTAssertTrue(ComputerDirectoryService.credential(for: paired.computer)?.acknowledged == true)
        await restarted.close()
        guard testRun?.failureCount == 0 else { return }
        try mark("done"); completed = true
    }
}

/// Opt-in check on the owner's iPhone. The host supplies only an expiring address
/// refresh, never a new pairing secret. Existing Keychain identity must match.
@MainActor
final class ComputerHostedRecoveryTests: XCTestCase {
    func testSavedPhoneLearnsRecoveryAndFindsThisMacThroughTheHostedDirectory() async throws {
        guard let code = ProcessInfo.processInfo.environment["MINDWIRE_LIVE_COMPUTER_REPAIR"] else {
            throw XCTSkip("Requires the owner's approved Mac and iPhone.")
        }
        let refresh = try ComputerConnectionCode.parse(code)
        let stores = Stores.shared
        let saved = try XCTUnwrap(stores.connections.list().first { $0.pairedComputer?.computerId == refresh.computerId })
        let original = try XCTUnwrap(saved.pairedComputer)
        let originalKey = try XCTUnwrap(Keychain.get(original.keyRef))
        let ids = stores.connections.list().map(\.id).sorted()
        let updated = try await WorkspaceRepository.shared.reconnectComputer(saved.id, code: code)
        let computer = try XCTUnwrap(updated.pairedComputer)
        let credential = try XCTUnwrap(ComputerDirectoryService.credential(for: computer))
        XCTAssertTrue(credential.acknowledged)
        XCTAssertEqual(credential.descriptor.url, "https://console.mindwire.sh/api/computer-directory/v1")
        let key = try XCTUnwrap(SSHKey.loadPrivateKey(computer.keyRef))
        let token = try XCTUnwrap(Keychain.get(computer.tokenRef))
        // A discarded tunnel URL must recover through the signed directory,
        // using exactly the original phone key and pinned computer identity.
        let recovered = try await ComputerDirectoryService.open(computer,
            routes: [.init(kind: "websocket", url: "wss://expired-mindwire-test.invalid/ssh")],
            key: key, token: token, stores: stores)
        defer { recovered.ssh.close() }
        let http = DaemonHTTP(channel: recovered.channel, agentType: "")
        let info: ComputerConnectionInfo = try await http.decode("GET", "/computer", quiet: true)
        XCTAssertTrue(info.matches(original))
        let addresses = try await ComputerDirectoryService.lookup(computer, stores: stores)
        let internet = addresses.filter { $0.kind == "websocket" }
        XCTAssertFalse(internet.isEmpty)
        let tunneled = try await ComputerSSHLink.open(routes: internet, username: "device", auth: .privateKey(key),
            fingerprint: computer.fingerprint, port: 8790, token: token)
        defer { tunneled.ssh.close() }
        let health: DaemonHealth = try await DaemonHTTP(channel: tunneled.channel, agentType: "").decode("GET", "/healthz", quiet: true)
        XCTAssertTrue(health.ok)
        XCTAssertTrue(Keychain.get(computer.keyRef) == originalKey, "The saved private key must be preserved")
        XCTAssertEqual(stores.connections.list().map(\.id).sorted(), ids)
        print("Hosted directory and Cloudflare reconnect passed; the existing computer and phone key were preserved.")
    }
}
