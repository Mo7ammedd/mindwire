import XCTest
import Darwin
import NIOCore
@testable import Mindwire

@MainActor
final class ConnectionPortForwardTests: XCTestCase {
    private func fixture() throws -> (Stores, String, Connection, ComputerNetworkMonitor) {
        let suite = "forward-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let stores = Stores(defaults: defaults)
        let connection = Connection.ssh(.init(id: "server", name: "My server", type: .ssh,
            host: "example.invalid", port: 22, username: "developer",
            auth: .password(secretRef: "secret-stays-in-keychain"), createdAt: isoNow()))
        stores.connections.save(connection)
        let network = ComputerNetworkMonitor(observeSystem: false)
        network.update(.init(reachable: true, interfaces: ["wifi"]))
        return (stores, suite, connection, network)
    }

    private func manager(_ stores: Stores, network: ComputerNetworkMonitor, factory: ForwardListenerFixture,
                         active: Bool = true) -> ConnectionPortForwards {
        ConnectionPortForwards(stores: stores, network: network, initiallyActive: active) { connection, port, local in
            ConnectionPortForward(connection: connection, port: port, network: network, stores: stores,
                localPort: local, makeListener: { try await factory.open($0) })
        }
    }

    func testBackgroundAndForegroundRestoreTheSameAddressWithoutDuplicateListeners() async throws {
        let (stores, suite, connection, network) = try fixture()
        defer { stores.defaults.removePersistentDomain(forName: suite) }
        let factory = ForwardListenerFixture()
        let manager = manager(stores, network: network, factory: factory)
        let forward = manager.open(connection: connection, port: 3000)
        defer { manager.close(forward) }
        let port = try await forward.ready()
        XCTAssertTrue(manager.open(connection: connection, port: 3000) === forward)
        XCTAssertEqual(factory.listeners.count, 1)
        XCTAssertEqual(forward.connectionRevision, 1)
        manager.setActive(false)
        XCTAssertNil(forward.url)
        XCTAssertFalse(factory.listeners[0].isActive)
        manager.setActive(true)
        manager.setActive(true)
        let reopenedPort = try await forward.ready()
        XCTAssertEqual(reopenedPort, port)
        XCTAssertEqual(factory.listeners.count, 2)
        XCTAssertEqual(forward.connectionRevision, 2, "A preview can reload even when the restored address stays the same")
        XCTAssertEqual(factory.requestedPorts, [0, port])
    }

    func testRelaunchRestoresSettingsAndAddressAndCloseRemovesTheSavedForward() async throws {
        let (stores, suite, connection, network) = try fixture()
        defer { stores.defaults.removePersistentDomain(forName: suite) }
        let first = manager(stores, network: network, factory: ForwardListenerFixture())
        let forward = first.open(connection: connection, port: 5173)
        let port = try await forward.ready()
        first.setActive(false)
        let data = try XCTUnwrap(stores.defaults.data(forKey: ConnectionPortForwards.storageKey))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(saved[0].keys), ["connectionId", "remotePort", "localPort"])
        let factory = ForwardListenerFixture()
        let second = manager(stores, network: network, factory: factory, active: false)
        XCTAssertEqual(second.sessions.count, 1)
        XCTAssertTrue(factory.listeners.isEmpty, "Restoring preferences must not open sockets in the background")
        second.setActive(true)
        let restored = try XCTUnwrap(second.sessions.first)
        let restoredPort = try await restored.ready()
        XCTAssertEqual(restored.remotePort, 5173)
        XCTAssertEqual(restoredPort, port)
        XCTAssertEqual(factory.requestedPorts, [port])
        second.close(restored)
        XCTAssertNil(stores.defaults.object(forKey: ConnectionPortForwards.storageKey))
        let third = manager(stores, network: network, factory: ForwardListenerFixture(), active: false)
        XCTAssertTrue(third.sessions.isEmpty)
        first.close(forward)
    }

    func testNetworkChangesReconnectOnlyTheOwnedListenerAndKeepItsAddress() async throws {
        let (stores, suite, connection, network) = try fixture()
        defer { stores.defaults.removePersistentDomain(forName: suite) }
        let factory = ForwardListenerFixture()
        let manager = manager(stores, network: network, factory: factory)
        let forward = manager.open(connection: connection, port: 3000)
        defer { manager.close(forward) }
        let port = try await forward.ready()
        network.update(.init(reachable: true, interfaces: ["cellular"]))
        try await eventually { factory.listeners.count == 2 && forward.localPort == port }
        XCTAssertFalse(factory.listeners[0].isActive)
        XCTAssertTrue(factory.listeners[1].isActive)
        network.update(.init(reachable: true, interfaces: ["cellular"]))
        await Task.yield()
        XCTAssertEqual(factory.listeners.count, 2, "An unchanged network must not restart a forward")
    }

    func testLatePausedOpeningCannotReplaceOrCloseTheNewListener() async throws {
        let (stores, suite, connection, network) = try fixture()
        defer { stores.defaults.removePersistentDomain(forName: suite) }
        let factory = ForwardListenerFixture()
        factory.holdFirst = true
        let manager = manager(stores, network: network, factory: factory)
        let forward = manager.open(connection: connection, port: 3000)
        defer { manager.close(forward); factory.releaseFirst() }
        try await eventually { factory.gate != nil }
        manager.setActive(false)
        manager.setActive(true)
        let port = try await forward.ready()
        let current = try XCTUnwrap(factory.listeners.last)
        factory.releaseFirst()
        try await eventually { factory.listeners.count == 2 && !factory.listeners.last!.isActive }
        XCTAssertTrue(current.isActive)
        XCTAssertEqual(forward.localPort, port)
        forward.start()
        await Task.yield()
        XCTAssertEqual(factory.requestedPorts.count, 2, "A late job must not clear the new job's identity")
    }

    func testDeletedConnectionsAreNotRestored() async throws {
        let (stores, suite, connection, network) = try fixture()
        defer { stores.defaults.removePersistentDomain(forName: suite) }
        let first = manager(stores, network: network, factory: ForwardListenerFixture())
        let forward = first.open(connection: connection, port: 3000)
        _ = try await forward.ready()
        first.setActive(false)
        stores.connections.remove(connection.id)
        let restored = manager(stores, network: network, factory: ForwardListenerFixture(), active: false)
        XCTAssertTrue(restored.sessions.isEmpty)
        XCTAssertNil(stores.defaults.object(forKey: ConnectionPortForwards.storageKey))
        first.close(forward)
    }

    func testOccupiedSavedLocalPortFallsBackAndPersistsTheNewAddress() async throws {
        let (stores, suite, connection, network) = try fixture()
        defer { stores.defaults.removePersistentDomain(forName: suite) }
        let first = manager(stores, network: network, factory: ForwardListenerFixture())
        let forward = first.open(connection: connection, port: 3000)
        let previousPort = try await forward.ready()
        first.setActive(false)
        var requested: [Int] = []
        let restored = ConnectionPortForwards(stores: stores, network: network) { connection, port, local in
            ConnectionPortForward(connection: connection, port: port, network: network, stores: stores,
                localPort: local, makeListener: { bound in
                    requested.append(bound)
                    if bound == previousPort { throw IOError(errnoCode: EADDRINUSE, reason: "Fixture address already in use") }
                    return TestPortListener(port: 17343)
                })
        }
        let session = try XCTUnwrap(restored.sessions.first)
        let port = try await session.ready()
        XCTAssertEqual(port, 17343)
        XCTAssertEqual(requested, [previousPort, 0])
        let saved = try XCTUnwrap(stores.defaults.data(forKey: ConnectionPortForwards.storageKey))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        XCTAssertEqual(entries.first?["localPort"] as? Int, port)
        restored.close(session)
        first.close(forward)
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Forward did not settle", file: file, line: line)
        throw NSError(domain: "ForwardTests", code: 1)
    }
}

@MainActor
private final class ForwardListenerFixture {
    var requestedPorts: [Int] = []
    var listeners: [TestPortListener] = []
    var holdFirst = false
    var gate: CheckedContinuation<any LocalPortListener, Never>?
    func open(_ port: Int) async throws -> any LocalPortListener {
        requestedPorts.append(port)
        if holdFirst && requestedPorts.count == 1 {
            return await withCheckedContinuation { gate = $0 }
        }
        let listener = TestPortListener(port: port == 0 ? 17341 : port)
        listeners.append(listener)
        return listener
    }
    func releaseFirst() {
        guard let gate else { return }
        self.gate = nil
        let listener = TestPortListener(port: 17342)
        listeners.append(listener)
        gate.resume(returning: listener)
    }
}

@MainActor
private final class TestPortListener: LocalPortListener {
    let port: Int
    var isActive = true
    init(port: Int) { self.port = port }
    func close() { isActive = false }
}
