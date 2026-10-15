import XCTest
import Crypto
@testable import Mindwire

@MainActor
final class ComputerDirectoryTests: XCTestCase {
    @MainActor private struct Fixture {
        let stores: Stores
        let defaults: UserDefaults
        let suite: String
        let host: Curve25519.Signing.PrivateKey
        let phone: Curve25519.Signing.PrivateKey
        let computer: PairedComputer
        let credential: ComputerDirectoryCredential
        func record(sequence: Int64 = 1, route: String = "wss://new.example/ssh", audience: String? = nil,
                    issuedAt: Int64? = nil, expiresAt: Int64? = nil) throws -> Data {
            let descriptor = credential.descriptor
            let now = Int64(Date().timeIntervalSince1970)
            let aad = "mindwire-directory-address-v1\n\(descriptor.url)\n\(descriptor.directoryId)\n\(computer.deviceId)\n\(sequence)"
            let plaintext = try JSONEncoder().encode(ComputerDirectoryCodec.Addresses(routes: [ComputerRoute(kind: "websocket", url: route)]))
            let encrypted = try AES.GCM.seal(plaintext, using: SymmetricKey(data: Data(base64Encoded: credential.secret)!), authenticating: Data(aad.utf8))
            let payload = try JSONSerialization.data(withJSONObject: [
                "version": 1, "audience": audience ?? descriptor.url, "directoryId": descriptor.directoryId,
                "computerId": computer.computerId, "registryId": computer.registryId, "deviceId": computer.deviceId,
                "sequence": sequence, "issuedAt": issuedAt ?? now, "expiresAt": expiresAt ?? now + 86_400,
                "ciphertext": encrypted.combined!.base64EncodedString()
            ]).base64EncodedString()
            return try JSONEncoder().encode(ComputerDirectoryCodec.Envelope(publicKey: host.publicKey.rawRepresentation.base64EncodedString(),
                payload: payload, signature: try host.signature(for: Data(("mindwire-directory-record-v1\n" + payload).utf8)).base64EncodedString()))
        }
        func cleanup() {
            stores.deleteServer("fixture")
            defaults.removePersistentDomain(forName: suite)
        }
    }
    private func fixture() throws -> Fixture {
        let suite = "directory-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let stores = Stores(defaults: defaults)
        let host = Curve25519.Signing.PrivateKey(), phone = Curve25519.Signing.PrivateKey()
        let hostDigest = ComputerDirectoryCodec.keyDigest(host.publicKey.rawRepresentation)
        let descriptor = ComputerDirectoryDescriptor(version: 1, url: "https://api.example/directory/v1",
            directoryId: ComputerDirectoryCodec.urlEncoded(hostDigest))
        let computer = PairedComputer(computerId: suite, registryId: "registry", deviceId: ComputerDirectoryCodec.urlEncoded(ComputerDirectoryCodec.keyDigest(phone.publicKey.rawRepresentation)),
            fingerprint: "SHA256:" + hostDigest.base64EncodedString().replacingOccurrences(of: "=", with: ""),
            routes: [ComputerRoute(kind: "websocket", url: "wss://old.example/ssh")], keyRef: suite + ".key", tokenRef: suite + ".token", discovery: descriptor)
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        let credential = ComputerDirectoryCredential(descriptor: descriptor, deviceId: computer.deviceId, secret: secret)
        XCTAssertTrue(Keychain.set(phone.rawRepresentation.base64EncodedString(), for: computer.keyRef))
        XCTAssertTrue(Keychain.set("fixture", for: computer.tokenRef))
        XCTAssertTrue(Keychain.set(String(decoding: try JSONEncoder().encode(credential), as: UTF8.self), for: computer.directoryKeyRef))
        stores.connections.save(.local(LocalConnection(id: "fixture", name: "Fixture", deviceName: "Fixture", pairingId: "", computer: computer, createdAt: isoNow())))
        return Fixture(stores: stores, defaults: defaults, suite: suite, host: host, phone: phone, computer: computer, credential: credential)
    }

    func testPinnedSignatureEncryptionExpiryAndRollbackAreRequired() throws {
        let fixture = try fixture(); defer { fixture.cleanup() }
        let record = try fixture.record(sequence: 8)
        let value = try ComputerDirectoryCodec.verify(record, for: fixture.computer, credential: fixture.credential)
        XCTAssertEqual(value.addresses.routes.first?.url, "wss://new.example/ssh")
        var saved = fixture.credential; saved.sequence = value.sequence; saved.digest = value.digest
        XCTAssertNoThrow(try ComputerDirectoryCodec.verify(record, for: fixture.computer, credential: saved))
        XCTAssertThrowsError(try ComputerDirectoryCodec.verify(fixture.record(sequence: 7), for: fixture.computer, credential: saved))
        XCTAssertThrowsError(try ComputerDirectoryCodec.verify(fixture.record(sequence: 8, route: "wss://different.example/ssh"), for: fixture.computer, credential: saved))
        XCTAssertThrowsError(try ComputerDirectoryCodec.verify(fixture.record(audience: "https://attacker.example"), for: fixture.computer, credential: fixture.credential))
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertThrowsError(try ComputerDirectoryCodec.verify(fixture.record(issuedAt: now - 60, expiresAt: now - 1), for: fixture.computer, credential: fixture.credential))
        XCTAssertThrowsError(try ComputerDirectoryCodec.verify(fixture.record(issuedAt: now + 300), for: fixture.computer, credential: fixture.credential))
        XCTAssertThrowsError(try ComputerDirectoryCodec.verify(fixture.record(route: "http://unsafe.example"), for: fixture.computer, credential: fixture.credential))
        var envelope = try JSONSerialization.jsonObject(with: record) as! [String: Any]
        envelope["publicKey"] = fixture.phone.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try ComputerDirectoryCodec.verify(JSONSerialization.data(withJSONObject: envelope), for: fixture.computer, credential: fixture.credential))
        let wrongKey = ComputerDirectoryCredential(descriptor: fixture.credential.descriptor, deviceId: fixture.computer.deviceId,
            secret: Data(repeating: 0, count: 32).base64EncodedString())
        XCTAssertThrowsError(try ComputerDirectoryCodec.verify(record, for: fixture.computer, credential: wrongKey))
    }

    func testLookupUsesPhoneProofAndCannotOverwriteAConcurrentNewerRecord() async throws {
        let fixture = try fixture(); defer { fixture.cleanup() }
        let old = try fixture.record(sequence: 2), new = try fixture.record(sequence: 3)
        let delayed = Task { try await ComputerDirectoryService.lookup(fixture.computer, stores: fixture.stores) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "A phone must not require the computer owner's account")
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
            let timestamp = (body["timestamp"] as! NSNumber).int64Value
            let proof = "mindwire-directory-lookup-v1\n\(fixture.credential.descriptor.url)\n\(fixture.credential.descriptor.directoryId)\n\(fixture.computer.deviceId)\n\(timestamp)\n\(body["nonce"] as! String)"
            XCTAssertTrue(fixture.phone.publicKey.isValidSignature(Data(base64Encoded: body["signature"] as! String)!, for: Data(proof.utf8)))
            try await Task.sleep(for: .milliseconds(150))
            return old
        } }
        try await Task.sleep(for: .milliseconds(30))
        _ = try await ComputerDirectoryService.lookup(fixture.computer, stores: fixture.stores) { _ in new }
        do { _ = try await delayed.value; XCTFail("A delayed older response replaced the new high-water mark") }
        catch ComputerDirectoryError.invalidRecord {} catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(ComputerDirectoryService.credential(for: fixture.computer)?.sequence, 3)
        XCTAssertEqual(fixture.stores.savedComputer(matching: fixture.computer)?.routes, fixture.computer.routes,
            "Only a successful SSH handshake may replace the working route cache")
    }

    func testRemovingComputerDuringLookupCannotRestoreKeysOrConnection() async throws {
        let fixture = try fixture(); defer { fixture.cleanup() }
        let record = try fixture.record()
        do {
            _ = try await ComputerDirectoryService.lookup(fixture.computer, stores: fixture.stores) { _ in
                fixture.stores.deleteServer("fixture")
                return record
            }
            XCTFail("Deleted computer accepted a late lookup")
        } catch is CancellationError {} catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertNil(Keychain.get(fixture.computer.directoryKeyRef))
        XCTAssertTrue(fixture.stores.connections.list().isEmpty)
    }

    private struct ReceiptChannel: DaemonChannel {
        let label = "directory-receipt-fixture"
        let duringReceipt: @MainActor () async throws -> Void
        func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
            XCTAssertEqual(method, "POST"); XCTAssertTrue(path.hasSuffix("/ready"))
            try await duringReceipt()
            return (200, "{\"ok\":true}")
        }
    }

    func testDelayedReadyReceiptPreservesNewerLookupHighWaterMark() async throws {
        let fixture = try fixture(); defer { fixture.cleanup() }
        let record = try fixture.record(sequence: 9)
        let channel = ReceiptChannel {
            _ = try await ComputerDirectoryService.lookup(fixture.computer, stores: fixture.stores) { _ in record }
        }
        let info = ComputerConnectionInfo(computerId: fixture.computer.computerId, registryId: fixture.computer.registryId,
            fingerprint: fixture.computer.fingerprint, routes: fixture.computer.routes,
            discovery: ComputerDirectoryStatus(version: 1, enabled: true, directoryId: fixture.credential.descriptor.directoryId, url: fixture.credential.descriptor.url))
        _ = try await ComputerDirectoryService.learn(info, over: channel, computer: fixture.computer, stores: fixture.stores)
        let saved = try XCTUnwrap(ComputerDirectoryService.credential(for: fixture.computer))
        XCTAssertTrue(saved.acknowledged)
        XCTAssertEqual(saved.sequence, 9)
        XCTAssertNotNil(saved.digest)
    }
}
