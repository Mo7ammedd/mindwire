import XCTest
import CloudKit
@testable import Mindwire

@MainActor final class ConnectionSyncLiveTests: XCTestCase {
    func testPhysicalDeviceCloudKitBackupReinstallAndNewPhoneRecovery() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MINDWIRE_LIVE_ICLOUD"] == "1",
                          "Opt-in live check uses a disposable private CloudKit zone.")
        let zone = "MindwireSyncValidation" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let cloud = CloudKitConnectionCloud(zoneName: zone)
        _ = try await cloud.accountID()
        let stores = Stores(defaults: ConnectionSyncTests.defaults())
        let vault = SyncTestSecrets()
        let sync = ConnectionSyncService(stores: stores, cloud: cloud, secrets: vault)
        let connection = ConnectionSyncTests.computer()
        stores.connections.save(connection)
        _ = stores.createWorkspace(name: "Recovery validation", runtime: .server(serverId: connection.id))
        vault.setLocal("test key", key: "computer.mac.key")
        vault.setLocal("test token", key: "computer.mac.token")
        stores.defaults.set("light", forKey: "mindwire.appearance")
        var otherCloud: CloudKitConnectionCloud?
        do {
            await sync.setEnabled(true)
            XCTAssertNil(sync.error)
            try XCTUnwrap(sync.lastSyncedAt)
            XCTAssertEqual(sync.pendingCount, 0)

            let restoredStores = Stores(defaults: ConnectionSyncTests.defaults())
            let restoredCloud = CloudKitConnectionCloud(zoneName: zone)
            otherCloud = restoredCloud
            let restored = ConnectionSyncService(stores: restoredStores, cloud: restoredCloud, secrets: vault)
            await restored.foreground()
            XCTAssertNil(restored.error)
            XCTAssertEqual(restoredStores.connections.get(connection.id)?.pairedComputer?.deviceId, "phone-approval")
            XCTAssertEqual(restoredStores.workspaces.list().count, 1)
            XCTAssertEqual(restoredStores.defaults.string(forKey: "mindwire.appearance"), "light")
            await restoredCloud.stop()

            let newPhoneStores = Stores(defaults: ConnectionSyncTests.defaults())
            let newPhoneCloud = CloudKitConnectionCloud(zoneName: zone)
            otherCloud = newPhoneCloud
            let newPhone = ConnectionSyncService(stores: newPhoneStores, cloud: newPhoneCloud, secrets: SyncTestSecrets())
            await newPhone.foreground()
            XCTAssertNil(newPhone.error)
            XCTAssertEqual(newPhoneStores.connections.get(connection.id)?.pairedComputer?.needsDeviceApproval, true)
            XCTAssertTrue(newPhone.enabled)
            await newPhoneCloud.stop()

            // Actual Keychain writes use a disposable, account-scoped reference.
            let keychain = KeychainConnectionSyncSecrets()
            let ref = "mindwire.server." + UUID().uuidString + ".secret"
            try keychain.setSynced("disposable validation credential", reference: ref, account: zone)
            XCTAssertEqual(keychain.synced(ref, account: zone), "disposable validation credential")
            try keychain.removeSynced(reference: ref, account: zone)
            XCTAssertNil(keychain.synced(ref, account: zone))
        } catch {
            await otherCloud?.stop()
            await cloud.stop()
            try? await cloud.erase()
            throw error
        }
        await otherCloud?.stop()
        await cloud.stop()
        try await cloud.erase()
    }
}
