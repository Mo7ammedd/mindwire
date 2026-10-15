import XCTest
@testable import Mindwire

final class ComputerNetworkTests: XCTestCase {
    func testOnlyActualPathChangesAndForegroundInvalidateConnections() {
        let monitor = ComputerNetworkMonitor(observeSystem: false)
        var events: [ComputerNetworkMonitor.State] = []
        let observer = monitor.observe { events.append($0) }
        let wifi = ComputerNetworkMonitor.Path(reachable: true, interfaces: ["en0"], gateways: ["router-a"])
        monitor.update(wifi)
        XCTAssertEqual(monitor.state.revision, 0, "Initial discovery isn't a handoff")
        monitor.update(wifi)
        XCTAssertEqual(events.count, 2, "Identical observations must not cause reconnect churn")
        monitor.update(.init(reachable: false))
        XCTAssertEqual(monitor.state, .init(revision: 1, reachable: false))
        monitor.update(.init(reachable: true, interfaces: ["cellular"]))
        XCTAssertEqual(monitor.state.revision, 2)
        monitor.returnedToForeground()
        XCTAssertEqual(monitor.state.revision, 3)
        observer.cancel()
        monitor.update(wifi)
        XCTAssertEqual(events.last?.revision, 3)
    }

    func testChangingWiFiGatewayInvalidatesEvenWhenInterfaceNameStaysTheSame() {
        let monitor = ComputerNetworkMonitor(observeSystem: false)
        monitor.update(.init(reachable: true, interfaces: ["en0"], gateways: ["router-a"]))
        monitor.update(.init(reachable: true, interfaces: ["en0"], gateways: ["router-b"]))
        XCTAssertEqual(monitor.state.revision, 1)
    }

    func testOfflineRequestsWaitForConnectivityAndRemainCancellable() async throws {
        let monitor = ComputerNetworkMonitor(observeSystem: false)
        monitor.update(.init(reachable: false))
        let waiting = Task { try await monitor.waitUntilReachable() }
        try await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        do { try await waiting.value; XCTFail("Cancellation must end the offline wait") }
        catch { XCTAssertTrue(error is CancellationError) }
        let resumed = Task { try await monitor.waitUntilReachable() }
        monitor.update(.init(reachable: true, interfaces: ["cellular"]))
        try await resumed.value
    }

    @MainActor func testOnlyVerifiedRoutesRefreshAnExistingComputer() throws {
        let suite = "computer-routes-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let old = [ComputerRoute(kind: "websocket", url: "wss://old.example/ssh")]
        let computer = PairedComputer(computerId: "computer", registryId: "registry", deviceId: "phone",
            fingerprint: "SHA256:verified", routes: old, keyRef: "private-key-ref", tokenRef: "token-ref")
        let connection = LocalConnection(id: "saved", name: "My Mac", deviceName: "Mac", pairingId: "expired",
            computer: computer, createdAt: isoNow())
        stores.connections.save(.local(connection))
        let new = [ComputerRoute(kind: "websocket", url: "wss://new.example/ssh")]
        let info = ComputerConnectionInfo(computerId: "computer", registryId: "registry", fingerprint: "SHA256:verified", routes: new)
        XCTAssertTrue(info.matches(computer))
        XCTAssertFalse(ComputerConnectionInfo(computerId: "other", registryId: "registry", fingerprint: computer.fingerprint, routes: new).matches(computer))
        stores.updateComputerRoutes(new, for: computer)
        XCTAssertEqual(stores.computerRoutes(for: computer), new)
        XCTAssertEqual(stores.connections.list().count, 1)
        XCTAssertEqual(stores.connections.get("saved")?.pairedComputer?.tokenRef, computer.tokenRef)
        stores.updateComputerRoutes([ComputerRoute(kind: "websocket", url: "http://unsafe.example")], for: computer)
        XCTAssertEqual(stores.computerRoutes(for: computer), new)
        stores.connections.remove("saved")
        stores.updateComputerRoutes(new, for: computer)
        XCTAssertTrue(stores.connections.list().isEmpty, "A late route update must not recreate a removed computer")
    }
}
