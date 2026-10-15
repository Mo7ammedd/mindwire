import XCTest
@testable import Mindwire

@MainActor
final class MacDesktopTests: XCTestCase {
    private func stores() throws -> Stores {
        let suite = "mac-desktop-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func workspace() -> Workspace {
        .init(id: "mac-desktop", name: "My Mac", runtime: .server(serverId: "mac-connection"), createdAt: "2026-10-02T00:00:00Z")
    }

    func testNavigationCachesStatusAndConcurrentExplicitChecksShareOneRequest() async throws {
        let provider = MacDesktopStatusFixture()
        let model = DesktopModel(workspace: workspace(), stores: try stores(), provider: provider)
        let first = Task { await model.load() }
        await provider.waitForCalls(1)
        let second = Task { await model.load(force: true) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.checkingStatus)
        XCTAssertEqual(provider.calls, 1)
        provider.finish(0, enabled: false)
        await first.value; await second.value
        XCTAssertFalse(model.checkingStatus)
        XCTAssertTrue(model.needsLocalSetup)
        await model.load()
        XCTAssertEqual(provider.calls, 1, "Reopening the screen reuses its cached setup status")
        let refresh = Task { await model.load(force: true) }
        await provider.waitForCalls(2)
        provider.finish(1, enabled: true)
        await refresh.value
        XCTAssertFalse(model.needsLocalSetup)
        XCTAssertEqual(model.providerStatus?.enabled, true)
        XCTAssertEqual(provider.authorizationCalls, 0, "Checking status must never enable desktop access")
    }

    func testLateCancelledStatusCannotOverwriteANewerCheck() async throws {
        let provider = MacDesktopStatusFixture()
        let model = DesktopModel(workspace: workspace(), stores: try stores(), provider: provider)
        let old = Task { await model.load() }
        await provider.waitForCalls(1)
        model.disconnect()
        XCTAssertFalse(model.checkingStatus)
        let current = Task { await model.load(force: true) }
        await provider.waitForCalls(2)
        provider.finish(1, enabled: true)
        await current.value
        provider.finish(0, enabled: false)
        await old.value
        XCTAssertEqual(model.providerStatus?.enabled, true)
        XCTAssertFalse(model.checkingStatus)
        XCTAssertNil(model.error)
    }

    func testMacStatusAndAuthorizationNeverWriteSetupOrFetchMacCredentials() async throws {
        let channel = MacDesktopReadFixture()
        let api = DaemonHTTP(channel: channel, agentType: "")
        let store = try stores()
        let connection = store.savePairedComputer(.init(computer: computer(os: "darwin"),
            host: .init(hostname: "Mac", os: "darwin", arch: "arm64", home: "/test", directory: "/test", pid: 1),
            health: .init(ok: true, agent: nil, version: "test", workspaceMetadataVersion: 1)), name: "My Mac")
        let provider = ComputerDesktopProvider(workspace: workspace(), connection: connection, stores: store, api: { api })
        let status = try await provider.status()
        XCTAssertFalse(status.enabled)
        XCTAssertEqual(status.setup?.command, "mindwire desktop enable")
        for resuming in [true, false] {
            do {
                _ = try await provider.authorize(api: api, status: status, resuming: resuming)
                XCTFail("A phone cannot opt its Mac into desktop control")
            } catch { XCTAssertEqual((error as? DesktopProblem)?.code, "desktop_setup_required") }
        }
        do { _ = try await provider.credentials(); XCTFail("The Mac password must remain on the Mac") } catch {}
        try await provider.prepareSession()
        let calls = await channel.calls
        XCTAssertEqual(calls, ["GET /surfaces/desktop?refresh=true"])
        store.deleteServer(connection.id)
    }

    func testRetryOnlyRecoversTransportFailuresAndExpiredSessions() {
        for code in ["disconnected", "restarted", "desktop_session_expired", "session_expired"] {
            XCTAssertTrue(DesktopReconnectPolicy.shouldRetry(DesktopProblem(code: code, message: "test")))
        }
        for code in ["desktop_setup_required", "screen_sharing_off", "desktop_authentication", "desktop_credentials", "desktop_auth_protocol", "forbidden", "update_required"] {
            XCTAssertFalse(DesktopReconnectPolicy.shouldRetry(DaemonHTTPError(status: 428, message: "test", code: code)))
        }
        XCTAssertFalse(DesktopReconnectPolicy.shouldRetry(CancellationError()))
        XCTAssertTrue(DesktopReconnectPolicy.shouldRetry(URLError(.networkConnectionLost)))
        XCTAssertEqual((1...6).map { DesktopReconnectPolicy.delay(attempt: $0) }, [1, 2, 4, 8, 15, 15])
    }

    func testDesktopCapabilityRequiresThePairedMacHost() throws {
        let store = try stores()
        for os in ["darwin", "linux", "windows"] {
            let connection = store.savePairedComputer(.init(computer: computer(os: os),
                host: .init(hostname: os, os: os, arch: "arm64", home: "/test", directory: "/test", pid: 1),
                health: .init(ok: true, agent: nil, version: "test", workspaceMetadataVersion: 1)), name: os)
            let workspace = try XCTUnwrap(store.workspaces(forServerId: connection.id).first)
            XCTAssertEqual(WorkspaceDesktopProviders.supports(workspace, stores: store), os == "darwin")
            store.deleteServer(connection.id)
        }
        XCTAssertFalse(WorkspaceDesktopProviders.supports(workspace(), stores: store))
    }

    func testDisplayCleanupRunsOnlyOnce() {
        var closes = 0
        let connection = DesktopDisplayConnection(port: 1234) { closes += 1 }
        connection.close(); connection.close()
        XCTAssertEqual(closes, 1)
    }

    func testVerifiedAddressChangesPreserveTheDesktopContextButIdentityChangesDoNot() async throws {
        let store = try stores(), provider = MacDesktopStatusFixture()
        let paired = computer(os: "darwin")
        var connection = LocalConnection(id: "mac-connection", name: "Mac", deviceName: "Mac", pairingId: "test",
            computer: paired, workspace: "/test", createdAt: "2026-10-02T00:00:00Z")
        store.connections.save(.local(connection))
        let model = DesktopModel(workspace: workspace(), stores: store, provider: provider)
        let original = WorkspaceConnectionContext(workspace(), stores: store)
        let load = Task { await model.load() }
        await provider.waitForCalls(1)
        store.updateComputerRoutes([.init(kind: "ssh", host: "127.0.0.1", port: 2)], for: paired)
        provider.finish(0, enabled: true)
        await load.value
        XCTAssertEqual(model.providerStatus?.enabled, true)
        XCTAssertEqual(original, WorkspaceConnectionContext(workspace(), stores: store))
        connection.computer = computer(os: "darwin")
        store.connections.save(.local(connection))
        XCTAssertNotEqual(original, WorkspaceConnectionContext(workspace(), stores: store))
    }

    private func computer(os: String) -> PairedComputer {
        let id = UUID().uuidString
        return .init(computerId: id, registryId: "registry-" + id, deviceId: "phone-" + id,
            fingerprint: "SHA256:" + String(repeating: "a", count: 43), routes: [.init(kind: "ssh", host: "127.0.0.1", port: 1)],
            keyRef: "desktop-key-" + id, tokenRef: "desktop-token-" + id, operatingSystem: os)
    }
}

@MainActor
private final class MacDesktopStatusFixture: WorkspaceDesktopProvider {
    let usesLocalSetup = true
    private(set) var calls = 0
    private(set) var authorizationCalls = 0
    private var pending: [Int: CheckedContinuation<DesktopProviderStatus, Error>] = [:]
    func status() async throws -> DesktopProviderStatus {
        let index = calls; calls += 1
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, enabled: Bool) {
        pending.removeValue(forKey: index)?.resume(returning: .init(supported: true, enabled: enabled, available: enabled,
            credentials: false, setup: enabled ? nil : .init(reason: "disabled", command: "mindwire desktop enable")))
    }
    func waitForCalls(_ count: Int) async {
        let deadline = Date().addingTimeInterval(3)
        while calls < count, Date() < deadline { await Task.yield() }
        XCTAssertEqual(calls, count)
    }
    func authorize(api: DaemonHTTP, status: DesktopProviderStatus, resuming: Bool) async throws -> DesktopSnapshot {
        authorizationCalls += 1
        throw DesktopProblem(code: "unexpected", message: "Only status should have been requested")
    }
    func openDisplay(api: DaemonHTTP, session: DesktopSession) async throws -> DesktopDisplayConnection {
        throw DesktopProblem(code: "unexpected", message: "Only status should have been requested")
    }
}

private actor MacDesktopReadFixture: DaemonChannel {
    nonisolated var label: String { "mac-desktop-test" }
    private(set) var calls: [String] = []
    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        calls.append("\(method) \(path)")
        guard method == "GET", path == "/surfaces/desktop?refresh=true" else { return (403, "{}") }
        return (200, #"{"id":"desktop","workspaceId":"registry","version":1,"revision":1,"instanceId":"test","state":"needs_setup","supported":true,"enabled":false,"available":false,"os":"darwin","capabilities":{"view":true,"capture":true,"pointer":true,"keyboard":true,"text":true,"clipboardRead":false,"clipboardWrite":false},"provider":"macos","setup":{"reason":"disabled","command":"mindwire desktop enable"}}"#)
    }
}
