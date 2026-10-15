import XCTest
@testable import Mindwire

@MainActor final class ConnectionFileBackupTests: XCTestCase {
    func testEncryptedFileRestoresConnectionsAndOptionalCredentialsAfterReinstall() throws {
        let stores = Stores(defaults: ConnectionSyncTests.defaults())
        let secrets = SyncTestSecrets()
        let server = ConnectionSyncTests.server()
        let computer = ConnectionSyncTests.computer()
        stores.connections.save(server)
        stores.connections.save(computer)
        _ = stores.createWorkspace(name: "Server", runtime: .server(serverId: server.id))
        _ = stores.createWorkspace(name: "Mac", runtime: .server(serverId: computer.id))
        let ref = try XCTUnwrap(server.remote?.auth.secretReference)
        secrets.setLocal("saved server password", key: ref)
        secrets.setLocal("private phone key", key: "computer.mac.key")
        secrets.setLocal("phone token", key: "computer.mac.token")
        stores.connectionSync = ConnectionSyncService(stores: stores, cloud: SyncTestCloud(server: .init()), secrets: secrets)
        stores.defaults.set("light", forKey: "mindwire.appearance")
        let backup = try ConnectionFileBackup.capture(stores: stores, secrets: secrets, includeCredentials: true)
        let password = "My long backup password"
        let bytes = try ConnectionFileEncryption.encrypt(backup, password: password)
        let encoded = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(encoded.contains("saved server password"))
        XCTAssertFalse(encoded.contains("example.invalid"))
        XCTAssertFalse(encoded.contains("private phone key"))
        let plaintext = try ConnectionFileEncryption.decrypt(bytes, password: password)
        XCTAssertEqual(plaintext.credentials, [ref: "saved server password"])

        // A normal file survives outside the deleted app's data container.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mindwirebackup")
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.write(to: url, options: .atomic)
        let fromDisk = try ConnectionFileEncryption.decrypt(ConnectionFileEncryption.read(url), password: password)
        let reinstall = Stores(defaults: ConnectionSyncTests.defaults())
        XCTAssertEqual(try fromDisk.restore(to: reinstall, secrets: secrets, restorePreferences: true), 2)
        XCTAssertEqual(reinstall.connections.get(computer.id)?.pairedComputer?.deviceId, "phone-approval")
        XCTAssertEqual(reinstall.workspaces.list().count, 2)
        XCTAssertEqual(reinstall.defaults.string(forKey: "mindwire.appearance"), "light")

        let newPhone = Stores(defaults: ConnectionSyncTests.defaults())
        let newSecrets = SyncTestSecrets()
        XCTAssertEqual(try fromDisk.restore(to: newPhone, secrets: newSecrets, restorePreferences: true), 2)
        XCTAssertTrue(newPhone.connections.get(computer.id)?.pairedComputer?.needsDeviceApproval == true)
        XCTAssertNil(newSecrets.local("computer.mac.key"))
        XCTAssertEqual(newSecrets.local(ref), "saved server password")
    }

    func testRestoreKeepsNewerConnectionsAndRepeatedImportDoesNotDuplicateThem() throws {
        let source = Stores(defaults: ConnectionSyncTests.defaults())
        let sourceSecrets = SyncTestSecrets()
        source.connections.save(ConnectionSyncTests.server(name: "Old name"))
        source.connections.save(ConnectionSyncTests.server(id: "another", name: "Another server"))
        let backup = try ConnectionFileBackup.capture(stores: source, secrets: sourceSecrets, includeCredentials: false)
        let target = Stores(defaults: ConnectionSyncTests.defaults())
        target.connections.save(ConnectionSyncTests.server(name: "Current name"))
        target.defaults.set("dark", forKey: "mindwire.appearance")
        let secrets = SyncTestSecrets()
        let ref = KeychainKey.serverSecret("server")
        secrets.setLocal("new credential", key: ref)
        XCTAssertEqual(try backup.restore(to: target, secrets: secrets, restorePreferences: false), 1)
        XCTAssertEqual(try backup.restore(to: target, secrets: secrets, restorePreferences: false), 0)
        XCTAssertEqual(target.connections.list().count, 2)
        XCTAssertEqual(target.connections.get("server")?.name, "Current name")
        XCTAssertEqual(secrets.local(ref), "new credential")
        XCTAssertEqual(target.defaults.string(forKey: "mindwire.appearance"), "dark")
    }

    func testWrongPasswordAndTamperingCannotProduceAnImportableBackup() throws {
        let backup = ConnectionFileBackup(connections: [], preferences: [:], credentials: [:])
        let bytes = try ConnectionFileEncryption.encrypt(backup, password: "Correct backup password")
        XCTAssertThrowsError(try ConnectionFileEncryption.decrypt(bytes, password: "Wrong backup password"))
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var ciphertext = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["sealed"] as? String)))
        ciphertext[ciphertext.count - 1] ^= 1
        envelope["sealed"] = ciphertext.base64EncodedString()
        let modified = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(try ConnectionFileEncryption.decrypt(modified, password: "Correct backup password"))
        envelope["iterations"] = Int.max
        XCTAssertThrowsError(try ConnectionFileEncryption.decrypt(JSONSerialization.data(withJSONObject: envelope), password: "anything"))
    }

    func testFileCanRestoreAMissingCredentialForAnAlreadyRestoredServer() async throws {
        let server = ConnectionSyncTests.server()
        let ref = try XCTUnwrap(server.remote?.auth.secretReference)
        let backup = ConnectionFileBackup(connections: [.init(connection: server, workspaces: [])],
            preferences: [:], credentials: [ref: "restored credential"])
        let stores = Stores(defaults: ConnectionSyncTests.defaults())
        stores.connections.save(server)
        let workspace = stores.createWorkspace(name: "Restored server", runtime: .server(serverId: server.id))
        let repository = WorkspaceRepository(stores: stores, adapters: [LocalWorkspaceAdapter(stores: stores)])
        let cached = repository.model(for: workspace)
        let revision = repository.revision
        let secrets = SyncTestSecrets()
        XCTAssertEqual(backup.credentialsToRestore(in: stores, secrets: secrets).count, 1)
        XCTAssertEqual(try backup.restore(to: stores, secrets: secrets, restorePreferences: false), 0)
        XCTAssertEqual(secrets.local(ref), "restored credential")
        let deadline = Date().addingTimeInterval(3)
        while repository.revision == revision, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(cached === repository.model(for: workspace),
                       "A previously unavailable SSH client must be invalidated when its credential arrives")
        XCTAssertTrue(backup.credentialsToRestore(in: stores, secrets: secrets).isEmpty)
        XCTAssertEqual(stores.connections.list(), [server])

        var moved = try XCTUnwrap(server.remote)
        moved.host = "changed.example.invalid"
        stores.connections.save(.ssh(moved))
        secrets.removeLocal(ref)
        XCTAssertTrue(backup.credentialsToRestore(in: stores, secrets: secrets).isEmpty,
                      "An older credential must not be applied to a different server address")
    }

    func testCredentialOptInCannotExportComputerApprovalsOrOtherAccountTokens() throws {
        let stores = Stores(defaults: ConnectionSyncTests.defaults())
        let secrets = SyncTestSecrets()
        stores.connections.save(ConnectionSyncTests.server())
        secrets.setLocal("session secret", key: KeychainKey.sessionToken)
        secrets.setLocal("server secret", key: KeychainKey.serverSecret("server"))
        let backup = try ConnectionFileBackup.capture(stores: stores, secrets: secrets, includeCredentials: false)
        XCTAssertTrue(backup.credentials.isEmpty)
        var invalid = backup
        invalid.credentials[KeychainKey.sessionToken] = "unrelated token"
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertThrowsError(try ConnectionFileEncryption.encrypt(invalid, password: "Valid long password"))
    }

    func testAConflictingWorkspaceIdentityRejectsImportBeforeChangingTheLibrary() throws {
        let stores = Stores(defaults: ConnectionSyncTests.defaults())
        let current = stores.createWorkspace(name: "Keep", runtime: .server(serverId: "keep"))
        let collision = Workspace(id: current.id, name: "Collision", runtime: .server(serverId: "server"), createdAt: "today")
        let backup = ConnectionFileBackup(connections: [.init(connection: ConnectionSyncTests.server(), workspaces: [collision])],
            preferences: [:], credentials: [:])
        XCTAssertThrowsError(try backup.restore(to: stores, secrets: SyncTestSecrets(), restorePreferences: true))
        XCTAssertTrue(stores.connections.list().isEmpty)
        XCTAssertEqual(stores.workspaces.list(), [current])
    }
}
