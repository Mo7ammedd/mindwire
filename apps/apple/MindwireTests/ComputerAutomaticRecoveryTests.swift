import XCTest
@testable import Mindwire

@MainActor
final class ComputerAutomaticRecoveryTests: XCTestCase {
    private func connection() -> Connection {
        let id = UUID().uuidString
        let computer = PairedComputer(computerId: id, registryId: "registry", deviceId: "phone",
            fingerprint: "SHA256:fixture", routes: [.init(kind: "websocket", url: "wss://laptop.example/ssh")],
            keyRef: "key-" + id, tokenRef: "token-" + id,
            connection: .init(provider: "oblien", address: "persistent"))
        return .local(.init(id: id, name: "Laptop", deviceName: "Laptop", pairingId: "old",
                            computer: computer, createdAt: isoNow()))
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Recovery condition did not complete", file: file, line: line)
    }

    func testHealthyConnectionsAreCachedAndPathChangesTriggerOneAttempt() async {
        let connection = connection(), network = ComputerNetworkMonitor(observeSystem: false)
        network.update(.init(reachable: true, interfaces: ["wifi"]))
        var calls = 0
        let recovery = ComputerRecoveryCoordinator(network: network, connections: { [connection] }, attempt: { _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(20))
        }, cancelAttempt: { _ in })
        recovery.setActive(true)
        for _ in 0..<10 { recovery.synchronize() }
        await until { calls == 1 && recovery.states.isEmpty }
        for _ in 0..<10 { recovery.synchronize() }
        XCTAssertEqual(calls, 1, "Navigation/reconcile must keep a successful check cached")
        network.update(.init(reachable: false))
        await until { recovery.states[connection.id] == .offline }
        XCTAssertEqual(calls, 1)
        network.update(.init(reachable: true, interfaces: ["cellular"]))
        await until { calls == 2 && recovery.states.isEmpty }
        recovery.setActive(false)
    }

    func testRetriesAreSharedAndBackoffIsBounded() async {
        let connection = connection(), network = ComputerNetworkMonitor(observeSystem: false)
        var calls = 0, delays: [Duration] = []
        let recovery = ComputerRecoveryCoordinator(network: network, connections: { [connection] }, attempt: { _ in
            calls += 1
            if calls < 4 { throw ComputerConnectionError.unreachable }
        }, cancelAttempt: { _ in }, sleep: { duration in
            delays.append(duration)
            try await Task.sleep(for: .milliseconds(5))
        })
        recovery.setActive(true)
        for _ in 0..<10 { recovery.failed(connection.id, error: ComputerConnectionError.unreachable) }
        await until { calls == 4 && recovery.states.isEmpty }
        XCTAssertEqual(delays, [.seconds(1), .seconds(2), .seconds(4)])
        XCTAssertEqual(ComputerRecoveryCoordinator.retryDelay(100), .seconds(60))
        recovery.setActive(false)
    }

    func testIdentityOrAuthenticationFailureRequiresAnExplicitRetry() async {
        let connection = connection(), network = ComputerNetworkMonitor(observeSystem: false)
        var calls = 0
        let recovery = ComputerRecoveryCoordinator(network: network, connections: { [connection] }, attempt: { _ in
            calls += 1
            throw ComputerConnectionError.identityChanged
        }, cancelAttempt: { _ in })
        recovery.setActive(true)
        await until { calls == 1 && recovery.states[connection.id] == .needsAttention(ComputerConnectionError.identityChanged.localizedDescription) }
        recovery.synchronize()
        network.update(.init(reachable: false))
        network.update(.init(reachable: true, interfaces: ["cellular"]))
        recovery.setActive(false); recovery.setActive(true)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(calls, 1, "Network changes cannot clear an identity failure")
        recovery.manualRetry(connection.id)
        recovery.synchronize()
        await until { calls == 2 }
        recovery.setActive(false)
        XCTAssertFalse(ComputerRecoveryCoordinator.canRetry(DaemonHTTPError(status: 401, message: "Unauthorized")))
    }

    func testRemovingOrBackgroundingCancelsAndIgnoresDelayedSuccess() async {
        let connection = connection(), network = ComputerNetworkMonitor(observeSystem: false)
        var connections = [connection], cancelled = 0
        var finish: CheckedContinuation<Void, Never>?
        let recovery = ComputerRecoveryCoordinator(network: network, connections: { connections }, attempt: { _ in
            await withCheckedContinuation { finish = $0 }
        }, cancelAttempt: { _ in cancelled += 1 })
        recovery.setActive(true)
        await until { finish != nil }
        connections = []
        recovery.synchronize()
        XCTAssertEqual(cancelled, 1)
        finish?.resume(); finish = nil
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(recovery.states.isEmpty)
        recovery.setActive(false); recovery.setActive(true)
        XCTAssertTrue(recovery.states.isEmpty)
        recovery.setActive(false)
    }

    func testManualRetryBypassesDelayAndPauseIsRespectedUntilForeground() async {
        let connection = connection(), network = ComputerNetworkMonitor(observeSystem: false)
        var calls = 0, sleeping = false
        let recovery = ComputerRecoveryCoordinator(network: network, connections: { [connection] }, attempt: { _ in
            calls += 1
            if calls == 1 { throw ComputerConnectionError.unreachable }
        }, cancelAttempt: { _ in }, sleep: { _ in
            sleeping = true
            try await Task.sleep(for: .seconds(30))
        })
        recovery.setActive(true)
        await until { sleeping }
        recovery.manualRetry(connection.id)
        recovery.synchronize()
        await until { calls == 2 && recovery.states.isEmpty }
        recovery.pause(connection.id)
        recovery.failed(connection.id, error: ComputerConnectionError.unreachable)
        recovery.synchronize()
        XCTAssertEqual(recovery.states[connection.id], .paused)
        XCTAssertEqual(calls, 2)
        recovery.setActive(false); recovery.setActive(true)
        await until { calls == 3 && recovery.states.isEmpty }
        recovery.setActive(false)
    }

    func testConnectionPolicyIsBackwardCompatibleAndContainsNoCredential() throws {
        let computer = try XCTUnwrap(connection().pairedComputer)
        let restored = try JSONDecoder().decode(PairedComputer.self, from: JSONEncoder().encode(computer))
        XCTAssertEqual(restored.connectionPolicy, .init(provider: "oblien", address: "persistent"))
        XCTAssertEqual(ComputerConnectionPolicy.inferred(from: [.init(kind: "websocket", url: "wss://temporary.trycloudflare.com/ssh")]).address, "temporary")
        XCTAssertEqual(ComputerConnectionPolicy.inferred(from: [.init(kind: "ssh", host: "192.168.1.2", port: 8791)]).address, "network")
    }

    func testRecoveredTransportCancelsBackoffAndRetiredPhoneKeysCannotInvalidateIt() async throws {
        let connection = connection(), network = ComputerNetworkMonitor(observeSystem: false)
        let computer = try XCTUnwrap(connection.pairedComputer)
        var calls = 0
        let recovery = ComputerRecoveryCoordinator(network: network, connections: { [connection] }, attempt: { _ in
            calls += 1
            throw ComputerConnectionError.unreachable
        }, cancelAttempt: { _ in }, sleep: { _ in try await Task.sleep(for: .seconds(30)) })
        recovery.setActive(true)
        await until { recovery.states[connection.id] == .waiting }
        NotificationCenter.default.post(name: .computerTransportRecovered, object: nil, userInfo: ["computer": computer])
        await until { recovery.states.isEmpty }
        recovery.synchronize()
        XCTAssertEqual(calls, 1, "An already recovered file/chat connection must cancel the scheduled retry")
        let retired = PairedComputer(computerId: computer.computerId, registryId: computer.registryId, deviceId: "retired-phone",
            fingerprint: computer.fingerprint, routes: computer.routes, keyRef: "retired-key", tokenRef: "retired-token")
        NotificationCenter.default.post(name: .computerTransportFailed, object: nil,
            userInfo: ["computer": retired, "error": ComputerConnectionError.notPaired])
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(recovery.states.isEmpty, "A late failure from a replaced pairing cannot block the current phone key")
        recovery.synchronize()
        XCTAssertEqual(calls, 1)
        recovery.setActive(false)
    }
}
