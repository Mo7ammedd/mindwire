import XCTest
@testable import Mindwire

@MainActor
final class ComputerPersistentConnectionTests: XCTestCase {
    private struct Fixture: Decodable { let invitation: ComputerInvitation; let directory: String; let pid: Int }
    private struct Terminal: Decodable { let id: String; let running: Bool; let createdAt: String }
    private struct FileContents: Decodable { let content: String }
    private struct Execution: Decodable { let stdout: String; let exitCode: Int }
    private struct Host: Decodable { let pid: Int }

    func testNativeSSHOverPersistentInternetTunnelPreservesFilesTerminalsAndPairing() async throws {
        guard let file = ProcessInfo.processInfo.environment["MINDWIRE_PERSISTENT_FIXTURE"] else {
            throw XCTSkip("Requires the disposable persistent tunnel fixture.")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        var completed = false
        defer {
            if !completed { try? Data().write(to: URL(fileURLWithPath: fixture.directory + "/failed")) }
        }
        XCTAssertTrue(fixture.invitation.routes.allSatisfy { $0.kind == "websocket" && $0.url?.hasPrefix("wss://") == true }, "Live test must not bypass the relay using LAN SSH")
        let suite = "persistent-computer-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let stores = Stores(defaults: defaults)
        let code = String(decoding: try JSONEncoder().encode(fixture.invitation), as: UTF8.self)
        let result = try await ComputerPairingService.pair(code, deviceName: "Mindwire persistent test iPhone", stores: stores) { _ in }
        let saved = stores.savePairedComputer(result, name: "Persistent test computer")
        defer {
            stores.deleteServer(saved.id)
            defaults.removePersistentDomain(forName: suite)
        }
        let seed = try XCTUnwrap(Keychain.get(result.computer.keyRef))
        XCTAssertEqual(result.computer.connectionPolicy, .init(provider: "oblien", address: "persistent"))
        let network = ComputerNetworkMonitor(observeSystem: false)
        network.update(.init(reachable: true, interfaces: ["wifi"]))
        let first = ComputerDaemonChannel(computer: result.computer, network: network)
        let second = ComputerDaemonChannel(computer: result.computer, network: network)
        let firstHTTP = DaemonHTTP(channel: first, agentType: "")
        let http = DaemonHTTP(channel: second, agentType: "")
        async let one: DaemonHealth = firstHTTP.decode("GET", "/healthz", quiet: true)
        async let two: DaemonHealth = http.decode("GET", "/healthz", quiet: true)
        let (health1, health2) = try await (one, two)
        XCTAssertTrue(health1.ok && health2.ok)
        await first.close()
        let filename = fixture.directory + "/native.txt"
        _ = try await http.run("PUT", "/workspace/file", json: ["path": filename, "content": "Persistent native SSH ✓"], quiet: true)
        let terminal: Terminal = try await http.decode("POST", "/workspace/terminals",
            json: ["id": "persistent-native", "directory": fixture.directory, "columns": 80, "rows": 24], quiet: true)
        XCTAssertTrue(terminal.running)
        // Closing one UI lease must not disconnect another; a new network closes
        // the carrier only. The daemon still owns the shell and written files.
        network.update(.init(reachable: false))
        try Data().write(to: URL(fileURLWithPath: fixture.directory + "/restart"))
        let deadline = Date().addingTimeInterval(95)
        while !FileManager.default.fileExists(atPath: fixture.directory + "/restarted"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory + "/restarted"))
        network.update(.init(reachable: true, interfaces: ["cellular"]))
        let after: Terminal = try await http.decode("GET", "/workspace/terminals/persistent-native", quiet: true)
        XCTAssertTrue(after.running)
        XCTAssertEqual(after.createdAt, terminal.createdAt)
        let content: FileContents = try await http.decode("GET", "/workspace/file?path=\(http.encQuery(filename))", quiet: true)
        XCTAssertEqual(content.content, "Persistent native SSH ✓")
        let host: Host = try await http.decode("GET", "/workspace/host", quiet: true)
        XCTAssertEqual(host.pid, fixture.pid)
        let command: Execution = try await http.decode("POST", "/workspace/exec", json: ["argv": ["/usr/bin/printf", "%s", "NATIVE_RECONNECTED"], "directory": fixture.directory], quiet: true)
        XCTAssertEqual(command.exitCode, 0); XCTAssertEqual(command.stdout, "NATIVE_RECONNECTED")
        XCTAssertEqual(Keychain.get(result.computer.keyRef), seed)
        XCTAssertEqual(stores.connections.list().count, 1)
        _ = try await http.run("DELETE", "/workspace/terminals/persistent-native", json: nil, quiet: true)
        await second.close()
        guard testRun?.failureCount == 0 else { return }
        try Data().write(to: URL(fileURLWithPath: fixture.directory + "/done"))
        completed = true
    }
}
