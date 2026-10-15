import XCTest
@testable import Mindwire

@MainActor
final class ComputerPairingRecoveryTests: XCTestCase {
    func testFreshCodeCannotReplaceASavedComputerIdentity() async throws {
        let stores = try isolatedStores()
        let computerId = UUID().uuidString
        let fingerprint = "SHA256:" + String(repeating: "a", count: 43)
        let routes = [ComputerRoute(kind: "ssh", host: "127.0.0.1", port: 1)]
        let computer = PairedComputer(computerId: computerId, registryId: "registry", deviceId: "phone",
            fingerprint: fingerprint, routes: routes, keyRef: "fixture-key", tokenRef: "fixture-token")
        let host = try JSONDecoder().decode(ComputerHost.self,
            from: Data(#"{"hostname":"Laptop","os":"linux","arch":"amd64","home":"/home/me","directory":"/home/me","pid":1}"#.utf8))
        let original = stores.savePairedComputer(.init(computer: computer, host: host), name: "Laptop")
        let invitation = ComputerInvitation(version: 1, computerId: computerId, name: "Laptop",
            fingerprint: "SHA256:" + String(repeating: "b", count: 43), routes: routes,
            pairingId: "new-offer", secret: String(repeating: "s", count: 43), expiresAt: "2099-01-01T00:00:00Z")
        do {
            _ = try await ComputerPairingService.pair(encoded(invitation), deviceName: "iPhone", stores: stores) { _ in }
            XCTFail("A fresh QR replaced the saved host pin")
        } catch ComputerConnectionError.identityChanged {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(stores.connections.get(original.id), original)
        XCTAssertNil(Keychain.get("computer.\(computerId).key"))
        XCTAssertNil(Keychain.get("computer.\(computerId).pending-pairing"))
    }

    /// The fixture approves the first key and explicitly replaces it on "lost".
    /// It rejects any approval request on "resume": the existing key must prove
    /// ownership over real SSH/WebSocket without another computer-side prompt.
    func testOneCodeResumesARetainedKeyAndRepairsARemovedConnection() async throws {
        guard let path = ProcessInfo.processInfo.environment["MINDWIRE_PAIRING_RECOVERY_FIXTURE"] else {
            throw XCTSkip("Requires the disposable pairing recovery fixture.")
        }
        let invitations = try JSONDecoder().decode([String: ComputerInvitation].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let firstCode = try XCTUnwrap(invitations["first"])
        let resumeCode = try XCTUnwrap(invitations["resume"])
        let lostCode = try XCTUnwrap(invitations["lost"])
        let stores = try isolatedStores()
        defer {
            Keychain.delete("computer.\(firstCode.computerId).key")
            Keychain.delete("computer.\(firstCode.computerId).token")
            ComputerPairingService.forgetPendingPairing(for: firstCode.computerId)
            for workspace in stores.workspaces.list() { DaemonWorkCoordinator.shared.forget(workspaceId: workspace.id) }
        }
        func pair(_ invitation: ComputerInvitation) async throws -> ComputerPairingService.Result {
            try await ComputerPairingService.pair(encoded(invitation), deviceName: "Mindwire recovery integration iPhone", stores: stores) { _ in }
        }
        let first = try await pair(firstCode)
        let seed = try XCTUnwrap(Keychain.get(first.computer.keyRef))
        let originalChannel = ComputerDaemonChannel(computer: first.computer)
        let originalHTTP = DaemonHTTP(channel: originalChannel, agentType: "")
        let firstStatus: PairingStatus = try await originalHTTP.decode("GET", "/computer/pairings/\(firstCode.pairingId)", quiet: true)
        XCTAssertEqual(firstStatus.status, "approved")
        XCTAssertNotEqual(firstStatus.completed, true, "Approval alone must not tell the terminal the connection was saved")
        XCTAssertTrue(stores.connections.list().isEmpty)

        // Simulate losing the form before saving. The next QR keeps the identity
        // already retained in Keychain even though no mobile connection exists.
        let resumed = try await pair(resumeCode)
        XCTAssertEqual(resumed.computer.deviceId, first.computer.deviceId)
        XCTAssertEqual(Keychain.get(resumed.computer.keyRef), seed)
        let beforeSave: PairingStatus = try await originalHTTP.decode("GET", "/computer/pairings/\(resumeCode.pairingId)", quiet: true)
        XCTAssertNotEqual(beforeSave.completed, true)
        let saved = stores.savePairedComputer(resumed, name: "My laptop")
        try await waitForSavedReceipt(resumeCode, http: originalHTTP)
        ComputerPairingService.confirmSaved(first, stores: stores)
        try await waitForSavedReceipt(firstCode, http: originalHTTP)

        // Repeated scans of the same still-valid code remain idempotent.
        let pendingText = try XCTUnwrap(Keychain.get("computer.\(first.computer.computerId).pending-pairing"))
        let pending = try JSONDecoder().decode([String: String].self, from: Data(pendingText.utf8))
        XCTAssertEqual(pending["requestId"], resumed.pairingRequestId, "Saving a connection must retain its current QR request")
        XCTAssertEqual(pending["pairingId"], resumeCode.pairingId)
        let repeated = try await pair(resumeCode)
        let repeatedConnection = stores.savePairedComputer(repeated, name: "")
        XCTAssertEqual(repeatedConnection.id, saved.id)
        XCTAssertEqual(repeatedConnection.name, "My laptop")
        XCTAssertEqual(repeated.computer.deviceId, first.computer.deviceId)
        XCTAssertEqual(stores.connections.list().count, 1)
        XCTAssertEqual(stores.workspaces(forServerId: saved.id).count, 1)
        let previousDevices: [DeviceStatus] = try await originalHTTP.decode("GET", "/computer/devices", quiet: true)
        XCTAssertEqual(previousDevices.filter { !$0.revoked }.map(\.id), [first.computer.deviceId])
        await originalChannel.close()

        // This is the reported failure: the computer has an approval, but the
        // phone no longer has a saved workspace, connection, or private key.
        stores.deleteServer(saved.id)
        XCTAssertTrue(stores.connections.list().isEmpty)
        XCTAssertNil(Keychain.get(first.computer.keyRef))
        let repaired = try await pair(lostCode)
        XCTAssertEqual(repaired.computer.computerId, first.computer.computerId)
        XCTAssertNotEqual(repaired.computer.deviceId, first.computer.deviceId)
        let restored = stores.savePairedComputer(repaired, name: "My laptop")
        let restoredChannel = ComputerDaemonChannel(computer: repaired.computer)
        let restoredHTTP = DaemonHTTP(channel: restoredChannel, agentType: "")
        try await waitForSavedReceipt(lostCode, http: restoredHTTP)
        let devices: [DeviceStatus] = try await restoredHTTP.decode("GET", "/computer/devices", quiet: true)
        XCTAssertEqual(devices.map(\.id), [repaired.computer.deviceId], "Replacing a lost phone key must remove the old approval atomically")
        XCTAssertEqual(stores.connections.list().map(\.id), [restored.id])
        XCTAssertEqual(stores.workspaces(forServerId: restored.id).count, 1)
        await restoredChannel.close()

        // A temporary disconnect needs no scan when the address still works.
        // Wait until the real CLI is listening, then authenticate the saved key.
        try await waitForFixtureFile(path + ".automatic.json")
        let automatic = ComputerDaemonChannel(computer: repaired.computer)
        let automaticHTTP = DaemonHTTP(channel: automatic, agentType: "")
        let health: DaemonHealth = try await automaticHTTP.decode("GET", "/healthz", quiet: true)
        XCTAssertTrue(health.ok)
        try await waitForFixtureFile(path + ".results.json")
        await automatic.close()
    }

    private struct PairingStatus: Decodable { let status: String; var completed: Bool? }
    private struct DeviceStatus: Decodable { let id: String; let revoked: Bool }

    private func waitForSavedReceipt(_ invitation: ComputerInvitation, http: DaemonHTTP) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let status: PairingStatus = try await http.decode("GET", "/computer/pairings/\(invitation.pairingId)", quiet: true)
            if status.completed == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The CLI did not receive the saved-connection receipt")
    }

    private func isolatedStores() throws -> Stores {
        let suite = "computer-pairing-recovery-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func waitForFixtureFile(_ path: String) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "The live CLI did not finish the expected connection step")
    }

    private func encoded(_ invitation: ComputerInvitation) throws -> String {
        String(decoding: try JSONEncoder().encode(invitation), as: UTF8.self)
    }
}
