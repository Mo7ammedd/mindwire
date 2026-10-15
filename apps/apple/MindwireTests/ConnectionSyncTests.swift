import XCTest
import CloudKit
@testable import Mindwire

@MainActor final class ConnectionSyncTests: XCTestCase {
    func testOptInRestoresAfterReinstallAndOnAnotherDeviceWithoutCloningComputerApproval() async throws {
        let server = SyncTestCloudServer()
        let secrets = SyncTestSecrets()
        let first = fixture(secrets: secrets, server: server)
        let original = Self.computer()
        first.stores.connections.save(original)
        let workspace = first.stores.createWorkspace(name: "My Mac", runtime: .server(serverId: original.id))
        let computer = try XCTUnwrap(original.pairedComputer)
        secrets.setLocal("private phone key", key: computer.keyRef)
        secrets.setLocal("daemon token", key: computer.tokenRef)
        secrets.setLocal("private discovery key", key: computer.directoryKeyRef)
        first.stores.defaults.set("light", forKey: "mindwire.appearance")
        await first.sync.setEnabled(true)
        XCTAssertNil(first.sync.error)
        XCTAssertEqual(first.sync.pendingCount, 0)

        let encoded = String(decoding: try JSONEncoder().encode(server.records.mapValues(\.value)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private phone key"))
        XCTAssertFalse(encoded.contains("daemon token"))
        XCTAssertFalse(encoded.contains("private discovery key"))
        XCTAssertFalse(encoded.contains("phone-approval"))

        // App data is gone; only this device's Keychain and the private cloud remain.
        let reinstall = fixture(secrets: secrets, server: server)
        await reinstall.sync.foreground()
        XCTAssertNil(reinstall.sync.error)
        XCTAssertTrue(reinstall.sync.enabled)
        XCTAssertEqual(reinstall.stores.connections.list().count, 1)
        XCTAssertEqual(reinstall.stores.connections.get(original.id)?.pairedComputer?.deviceId, "phone-approval")
        XCTAssertEqual(reinstall.stores.workspaces.get(workspace.id)?.runtime, workspace.runtime)
        XCTAssertEqual(reinstall.stores.defaults.string(forKey: "mindwire.appearance"), "light")

        // A new device sees the same saved computer, with no silently inherited access.
        let second = fixture(server: server)
        await second.sync.foreground()
        XCTAssertNil(second.sync.error)
        XCTAssertEqual(second.stores.connections.get(original.id)?.pairedComputer?.needsDeviceApproval, true)
        XCTAssertNil(second.secrets.local(computer.keyRef))
        XCTAssertNil(second.secrets.local(computer.tokenRef))
        XCTAssertNil(second.secrets.local(computer.directoryKeyRef))
        XCTAssertEqual(second.stores.workspaces.list().count, 1)
        XCTAssertTrue(second.stores.projects.list().isEmpty)
        XCTAssertTrue(second.stores.chats.list().isEmpty)
    }

    func testCredentialsAreOptInAccountScopedAndRemovingTheirCloudCopyKeepsTheLocalSecret() async throws {
        let server = SyncTestCloudServer()
        let first = fixture(server: server)
        let connection = Self.server()
        let ref = try XCTUnwrap(connection.remote?.auth.secretReference)
        first.stores.connections.save(connection)
        first.secrets.setLocal("ssh password", key: ref)
        await first.sync.setEnabled(true)
        XCTAssertNil(first.secrets.synced(ref, account: "account-a"))
        await first.sync.setSyncCredentials(true)
        XCTAssertEqual(first.secrets.synced(ref, account: "account-a"), "ssh password")
        XCTAssertNil(first.secrets.synced(ref, account: "account-b"))

        let secondSecrets = SyncTestSecrets(shared: first.secrets.shared)
        let second = fixture(secrets: secondSecrets, server: server)
        await second.sync.foreground()
        XCTAssertNil(second.sync.error)
        XCTAssertEqual(secondSecrets.local(ref), "ssh password")
        let encoded = String(decoding: try JSONEncoder().encode(server.records.mapValues(\.value)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("ssh password"))
        await first.sync.setSyncCredentials(false)
        XCTAssertEqual(first.secrets.local(ref), "ssh password")
        XCTAssertNil(first.secrets.synced(ref, account: "account-a"))
    }

    func testFreshInstallWithoutBackupDoesNotUploadUntilEnabled() async {
        let fixture = fixture()
        fixture.stores.connections.save(Self.server())
        await fixture.sync.foreground()
        XCTAssertFalse(fixture.sync.enabled)
        XCTAssertTrue(fixture.cloud.server.records.isEmpty)
        XCTAssertEqual(fixture.cloud.starts, 0)
        await fixture.sync.setEnabled(true)
        XCTAssertTrue(fixture.sync.enabled)
        XCTAssertNil(fixture.sync.error)
        XCTAssertFalse(fixture.cloud.server.records.isEmpty)
    }

    func testConcurrentDevicesKeepIndependentConnectionsAndTombstonesDoNotResurrectAfterOfflineReturn() async throws {
        let server = SyncTestCloudServer()
        let first = fixture(server: server)
        first.stores.connections.save(Self.server())
        await first.sync.setEnabled(true)
        let second = fixture(server: server)
        await second.sync.foreground()
        second.stores.connections.save(Self.server(id: "two", name: "Another server"))
        await second.sync.syncNow()
        await first.sync.syncNow()
        XCTAssertEqual(first.stores.connections.list().count, 2)

        first.stores.deleteServer("server")
        await first.sync.syncNow()
        XCTAssertNil(first.sync.error)
        // Device two still has its old cache and did not edit that connection.
        await second.sync.syncNow()
        XCTAssertNil(second.sync.error)
        XCTAssertNil(second.stores.connections.get("server"))
        XCTAssertNotNil(second.stores.connections.get("two"))
        await second.sync.syncNow()
        await first.sync.syncNow()
        XCTAssertEqual(first.stores.connections.list().map(\.id), ["two"])
    }

    func testOfflineChangesAreDurableAndRepeatedSyncDoesNotUploadUnchangedData() async throws {
        let fixture = fixture()
        fixture.stores.connections.save(Self.server())
        await fixture.sync.setEnabled(true)
        let writes = fixture.cloud.saves
        await fixture.sync.syncNow()
        XCTAssertEqual(fixture.cloud.saves, writes)
        fixture.cloud.offline = true
        fixture.stores.renameServer("server", name: "Offline edit")
        await fixture.sync.syncNow()
        XCTAssertNotNil(fixture.sync.error)
        XCTAssertGreaterThan(fixture.sync.pendingCount, 0)
        let saved = try JSONDecoder().decode(ConnectionSyncReplica.self,
            from: XCTUnwrap(fixture.stores.defaults.data(forKey: ConnectionSyncService.storageKey)))
        XCTAssertFalse(saved.pending.isEmpty)
        fixture.cloud.offline = false
        await fixture.sync.syncNow()
        XCTAssertNil(fixture.sync.error)
        XCTAssertEqual(fixture.sync.pendingCount, 0)
        let restored = self.fixture(server: fixture.cloud.server)
        await restored.sync.foreground()
        XCTAssertEqual(restored.stores.connections.get("server")?.name, "Offline edit")
    }

    func testChangingAppleAccountDoesNotUploadPreviousUsersConnections() async {
        let fixture = fixture()
        fixture.stores.connections.save(Self.server())
        await fixture.sync.setEnabled(true)
        let previousWrites = fixture.cloud.saves
        fixture.cloud.account = "account-b"
        await fixture.sync.syncNow()
        XCTAssertNotNil(fixture.sync.error)
        XCTAssertEqual(fixture.cloud.saves, previousWrites)
        XCTAssertEqual(fixture.stores.connections.list().count, 1)
    }

    func testDeleteCloudDataKeepsLocalWorkspacesAndSecrets() async throws {
        let fixture = fixture()
        let connection = Self.server()
        fixture.stores.connections.save(connection)
        let workspace = fixture.stores.createWorkspace(name: "Workspace", runtime: .server(serverId: connection.id))
        let ref = try XCTUnwrap(connection.remote?.auth.secretReference)
        fixture.secrets.setLocal("keep locally", key: ref)
        await fixture.sync.setEnabled(true)
        await fixture.sync.setSyncCredentials(true)
        await fixture.sync.deleteCloudData()
        XCTAssertNil(fixture.sync.error)
        XCTAssertFalse(fixture.sync.enabled)
        XCTAssertTrue(fixture.cloud.server.records.isEmpty)
        XCTAssertEqual(fixture.stores.connections.list().count, 1)
        XCTAssertNotNil(fixture.stores.workspaces.get(workspace.id))
        XCTAssertEqual(fixture.secrets.local(ref), "keep locally")
    }

    func testInterruptedRestoreReplaysJournalBeforeDetectingLocalDeletes() async throws {
        let server = SyncTestCloudServer()
        let original = fixture(server: server)
        original.stores.connections.save(Self.server())
        await original.sync.setEnabled(true)
        var replica = ConnectionSyncReplica(accountID: "account-a")
        for record in server.records.values {
            _ = try replica.receive(record.value)
            replica.unapplied.insert(record.value.id)
        }
        let defaults = Self.defaults()
        defaults.set(try JSONEncoder().encode(replica), forKey: ConnectionSyncService.storageKey)
        let recovering = fixture(defaults: defaults, secrets: original.secrets, server: server)
        await recovering.sync.foreground()
        XCTAssertNil(recovering.sync.error)
        XCTAssertNotNil(recovering.stores.connections.get("server"))
        XCTAssertEqual(server.records.values.filter { $0.value.payload == nil }.count, 0)
    }

    func testBackupRejectsCredentialReferenceSubstitutionAndChangedHostIdentity() throws {
        var remote = try XCTUnwrap(Self.server().remote)
        remote.auth = .password(secretRef: KeychainKey.sessionToken)
        XCTAssertThrowsError(try ConnectionBackup(connection: .ssh(remote), workspaces: []).validate())
        let original = Self.computer()
        guard case .local(var local) = original, let old = local.computer else { return XCTFail() }
        local.computer = PairedComputer(computerId: old.computerId, registryId: old.registryId,
            deviceId: "", fingerprint: "SHA256:" + String(repeating: "B", count: 43), routes: old.routes,
            keyRef: old.keyRef, tokenRef: old.tokenRef)
        XCTAssertThrowsError(try ConnectionBackup(connection: .local(local), workspaces: [])
            .restored(existing: original, secrets: SyncTestSecrets()))
    }

    func testCredentialChangeQueuesBehindInFlightRefreshInsteadOfBeingDropped() async throws {
        let fixture = fixture()
        let connection = Self.server()
        let ref = try XCTUnwrap(connection.remote?.auth.secretReference)
        fixture.stores.connections.save(connection)
        fixture.secrets.setLocal("test credential", key: ref)
        await fixture.sync.setEnabled(true)
        fixture.cloud.holdNextFetch = true
        let refresh = Task { await fixture.sync.syncNow() }
        try await waitUntil { fixture.cloud.fetchWaiting }
        let toggle = Task { await fixture.sync.setSyncCredentials(true) }
        await Task.yield()
        fixture.cloud.resumeFetch()
        await refresh.value
        await toggle.value
        XCTAssertTrue(fixture.sync.syncCredentials)
        XCTAssertNil(fixture.sync.error)
        XCTAssertEqual(fixture.secrets.synced(ref, account: "account-a"), "test credential")
        XCTAssertEqual(fixture.cloud.server.records["settings"]?.value.payload, .settings(syncCredentials: true))
    }

    func testTurningOffDuringAccountLookupCannotEnableOrUploadAfterwards() async throws {
        let fixture = fixture()
        fixture.stores.connections.save(Self.server())
        fixture.cloud.holdNextAccount = true
        let enable = Task { await fixture.sync.setEnabled(true) }
        try await waitUntil { fixture.cloud.accountWaiting }
        await fixture.sync.setEnabled(false)
        await enable.value
        XCTAssertFalse(fixture.sync.enabled)
        XCTAssertFalse(fixture.sync.busy)
        XCTAssertTrue(fixture.cloud.server.records.isEmpty)
        await fixture.sync.foreground()
        XCTAssertFalse(fixture.sync.enabled)
    }

    func testBackupDeletedOnAnotherDeviceStopsAnInFlightRefreshWithoutRecreatingIt() async {
        let fixture = fixture()
        fixture.stores.connections.save(Self.server())
        await fixture.sync.setEnabled(true)
        let writes = fixture.cloud.saves
        fixture.cloud.eraseOnFetch = true
        await fixture.sync.syncNow()
        await fixture.sync.foreground()
        XCTAssertFalse(fixture.sync.enabled)
        XCTAssertFalse(fixture.sync.busy)
        XCTAssertEqual(fixture.sync.pendingCount, 0)
        XCTAssertEqual(fixture.cloud.saves, writes)
        XCTAssertTrue(fixture.cloud.server.records.isEmpty)
        XCTAssertNotNil(fixture.stores.connections.get("server"))
    }

    func testICloudQuotaFailureKeepsOutboxAndAutomaticRetryClearsTheError() async throws {
        let fixture = fixture()
        fixture.stores.connections.save(Self.server())
        fixture.cloud.sendFailure = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: ["disposable-record": CKError(.quotaExceeded)]
        ])
        await fixture.sync.setEnabled(true)
        XCTAssertTrue(fixture.sync.error?.contains("storage is full") == true)
        XCTAssertFalse(fixture.sync.busy)
        XCTAssertGreaterThan(fixture.sync.pendingCount, 0)
        XCTAssertNotNil(fixture.stores.connections.get("server"))
        fixture.cloud.sendFailure = nil
        try await fixture.cloud.send() // CKSyncEngine retry, without opening Settings.
        XCTAssertNil(fixture.sync.error)
        XCTAssertEqual(fixture.sync.pendingCount, 0)
        XCTAssertNotNil(fixture.sync.lastSyncedAt)
    }

    func testRetryCompletesAnExplicitEnableAfterICloudBecomesAvailable() async {
        let fixture = fixture()
        fixture.stores.connections.save(Self.server())
        fixture.cloud.accountFailure = ConnectionSyncError.unavailable
        await fixture.sync.setEnabled(true)
        XCTAssertFalse(fixture.sync.enabled)
        XCTAssertNotNil(fixture.sync.error)
        fixture.cloud.accountFailure = nil
        await fixture.sync.retry()
        XCTAssertTrue(fixture.sync.enabled)
        XCTAssertNil(fixture.sync.error)
        XCTAssertEqual(fixture.sync.pendingCount, 0)
    }

    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !ready(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(ready())
    }

    private func fixture(defaults: UserDefaults? = nil, secrets: SyncTestSecrets? = nil,
                         server: SyncTestCloudServer? = nil) -> (stores: Stores, sync: ConnectionSyncService, cloud: SyncTestCloud, secrets: SyncTestSecrets) {
        let stores = Stores(defaults: defaults ?? Self.defaults())
        let secrets = secrets ?? SyncTestSecrets()
        let cloud = SyncTestCloud(server: server ?? SyncTestCloudServer())
        return (stores, ConnectionSyncService(stores: stores, cloud: cloud, secrets: secrets), cloud, secrets)
    }

    static func defaults() -> UserDefaults { UserDefaults(suiteName: "mindwire-sync-test-" + UUID().uuidString)! }
    static func server(id: String = "server", name: String = "Build Server") -> Connection {
        .ssh(RemoteHostConnection(id: id, name: name, type: .ssh, host: "example.invalid", port: 22,
            username: "developer", auth: .password(secretRef: KeychainKey.serverSecret(id)), createdAt: "2026-10-07T12:00:00Z"))
    }
    static func computer() -> Connection {
        .local(LocalConnection(id: "computer-mac", name: "My Mac", deviceName: "Mac", pairingId: "private invitation",
            computer: PairedComputer(computerId: "mac", registryId: "registry", deviceId: "phone-approval",
                fingerprint: "SHA256:" + String(repeating: "A", count: 43),
                routes: [.init(kind: "ssh", host: "192.0.2.1", port: 8791)], keyRef: "computer.mac.key", tokenRef: "computer.mac.token"),
            createdAt: "2026-10-07T12:00:00Z"))
    }
}

final class SyncTestSecrets: ConnectionSyncSecrets {
    final class Shared { var values: [String: String] = [:] }
    let shared: Shared
    var values: [String: String] = [:]
    init(shared: Shared = Shared()) { self.shared = shared }
    func local(_ key: String) -> String? { values[key] }
    @discardableResult func setLocal(_ value: String, key: String) -> Bool { values[key] = value; return true }
    @discardableResult func removeLocal(_ key: String) -> Bool { values[key] = nil; return true }
    func synced(_ reference: String, account: String) -> String? { shared.values[account + ":" + reference] }
    func setSynced(_ value: String, reference: String, account: String) throws { shared.values[account + ":" + reference] = value }
    func removeSynced(reference: String, account: String) throws { shared.values[account + ":" + reference] = nil }
    func removeAllSynced(account: String) throws { shared.values = shared.values.filter { !$0.key.hasPrefix(account + ":") } }
}

@MainActor final class SyncTestCloudServer {
    var records: [String: ConnectionCloudRecord] = [:]
    var serial = 0
}

@MainActor final class SyncTestCloud: ConnectionCloud {
    let server: SyncTestCloudServer
    var account = "account-a"
    var offline = false
    var starts = 0
    var saves = 0
    var holdNextFetch = false
    var holdNextAccount = false
    var eraseOnFetch = false
    var sendFailure: Error?
    var accountFailure: Error?
    var fetchWaiting: Bool { fetchGate != nil }
    var accountWaiting: Bool { accountGate != nil }
    private var fetchGate: CheckedContinuation<Void, Never>?
    private var accountGate: CheckedContinuation<Void, Never>?
    private var pending: Set<String> = []
    private var receive: (@MainActor (ConnectionCloudEvent) -> Void)?
    private var record: (@MainActor (String) -> ConnectionCloudRecord?)?
    init(server: SyncTestCloudServer) { self.server = server }
    func accountID() async throws -> String {
        if let accountFailure { throw accountFailure }
        if holdNextAccount {
            holdNextAccount = false
            await withCheckedContinuation { accountGate = $0 }
        }
        return account
    }
    func hasBackup() async throws -> Bool { server.records["settings"] != nil }
    func start(state: Data?, receive: @escaping @MainActor (ConnectionCloudEvent) -> Void,
               record: @escaping @MainActor (String) -> ConnectionCloudRecord?) throws {
        starts += 1; self.receive = receive; self.record = record
    }
    func schedule(_ ids: Set<String>) { pending.formUnion(ids) }
    func fetch() async throws {
        if offline { throw URLError(.notConnectedToInternet) }
        if holdNextFetch {
            holdNextFetch = false
            await withCheckedContinuation { fetchGate = $0 }
        }
        if eraseOnFetch { eraseOnFetch = false; server.records = [:]; receive?(.erased); return }
        receive?(.received(Array(server.records.values)))
    }
    func send() async throws {
        if offline { throw URLError(.notConnectedToInternet) }
        if !pending.isEmpty, let sendFailure { receive?(.failed(sendFailure)); throw sendFailure }
        for id in Array(pending) {
            guard let value = record?(id) else { pending.remove(id); continue }
            if let saved = server.records[id], saved.systemFields != value.systemFields {
                receive?(.conflict(saved)); continue
            }
            server.serial += 1; saves += 1
            let saved = ConnectionCloudRecord(value: value.value, systemFields: Data(String(server.serial).utf8))
            server.records[id] = saved
            pending.remove(id)
            receive?(.saved([saved]))
        }
    }
    func resumeFetch() { fetchGate?.resume(); fetchGate = nil }
    func stop() async {
        receive = nil; record = nil
        resumeFetch()
        accountGate?.resume(); accountGate = nil
    }
    func erase() async throws { server.records = [:] }
}
