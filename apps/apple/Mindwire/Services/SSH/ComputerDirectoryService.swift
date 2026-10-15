import Foundation
import Crypto
import NIOSSH

struct ComputerDirectoryDescriptor: Codable, Hashable {
    let version: Int
    let url: String
    let directoryId: String

    var isValid: Bool {
        guard version == 1, url.count <= 2048, !url.hasSuffix("/"),
              directoryId.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let address = URL(string: url), let host = address.host, !host.isEmpty,
              address.user == nil, address.password == nil, address.query == nil, address.fragment == nil else { return false }
        if address.scheme == "https" { return true }
        #if DEBUG
        return address.scheme == "http" && ["127.0.0.1", "localhost", "[::1]"].contains(host)
        #else
        return false
        #endif
    }
}

struct ComputerDirectoryStatus: Decodable {
    let version: Int
    let enabled: Bool
    let directoryId: String
    var url: String?
}

struct ComputerDirectoryCredential: Codable {
    let descriptor: ComputerDirectoryDescriptor
    let deviceId: String
    let secret: String
    var sequence: Int64 = 0
    var digest: String?
    var acknowledged = false
}

enum ComputerDirectoryError: LocalizedError, Equatable {
    case invalidRecord, unavailable, unchanged
    var errorDescription: String? {
        switch self {
        case .invalidRecord: "The computer’s address update could not be verified. Try reconnecting."
        case .unavailable: "Address recovery is temporarily unavailable. Mindwire will retry."
        case .unchanged: "The computer has not published a new address yet. Mindwire will retry."
        }
    }
}

enum ComputerDirectoryCodec {
    struct Envelope: Codable { let publicKey: String; let payload: String; let signature: String }
    struct Record: Decodable {
        let version: Int; let audience: String; let directoryId: String; let computerId: String
        let registryId: String; let deviceId: String; let sequence: Int64
        let issuedAt: Int64; let expiresAt: Int64; let ciphertext: String
    }
    struct Addresses: Codable { let routes: [ComputerRoute]; var connection: ComputerConnectionPolicy? }
    struct Resolved {
        let addresses: Addresses
        let sequence: Int64
        let digest: String
    }

    static func keyDigest(_ rawKey: Data) -> Data {
        var wire = Data([0, 0, 0, 11])
        wire.append(Data("ssh-ed25519".utf8)); wire.append(Data([0, 0, 0, 32])); wire.append(rawKey)
        return Data(SHA256.hash(data: wire))
    }
    static func urlEncoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func base64(_ text: String, maximum: Int) throws -> Data {
        guard text.utf8.count <= maximum * 2, let data = Data(base64Encoded: text), data.count <= maximum,
              data.base64EncodedString() == text else { throw ComputerDirectoryError.invalidRecord }
        return data
    }
    static func verify(_ data: Data, for computer: PairedComputer, credential: ComputerDirectoryCredential,
                       now: Date = Date()) throws -> Resolved {
        guard data.count <= 128 * 1024, credential.descriptor.isValid,
              credential.deviceId == computer.deviceId else { throw ComputerDirectoryError.invalidRecord }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let rawKey = try base64(envelope.publicKey, maximum: 32)
        let signature = try base64(envelope.signature, maximum: 64)
        let payload = try base64(envelope.payload, maximum: 64 * 1024)
        let pin = keyDigest(rawKey)
        guard rawKey.count == 32, signature.count == 64,
              computer.fingerprint == "SHA256:" + pin.base64EncodedString().replacingOccurrences(of: "=", with: ""),
              credential.descriptor.directoryId == urlEncoded(pin),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
              key.isValidSignature(signature, for: Data(("mindwire-directory-record-v1\n" + envelope.payload).utf8)) else {
            throw ComputerDirectoryError.invalidRecord
        }
        let record = try JSONDecoder().decode(Record.self, from: payload)
        let current = Int64(now.timeIntervalSince1970)
        let digest = Data(SHA256.hash(data: payload)).base64EncodedString()
        guard record.version == 1, record.audience == credential.descriptor.url,
              record.directoryId == credential.descriptor.directoryId, record.computerId == computer.computerId,
              record.registryId == computer.registryId, record.deviceId == computer.deviceId,
              record.sequence > 0, record.sequence <= 9_007_199_254_740_991,
              record.sequence >= credential.sequence,
              record.sequence != credential.sequence || credential.digest == nil || credential.digest == digest,
              record.issuedAt >= 0, record.issuedAt <= current + 120,
              record.expiresAt > current, record.expiresAt > record.issuedAt,
              record.expiresAt - record.issuedAt <= 86_400 else { throw ComputerDirectoryError.invalidRecord }
        let secret = try base64(credential.secret, maximum: 32)
        guard secret.count == 32 else { throw ComputerDirectoryError.invalidRecord }
        let encrypted = try base64(record.ciphertext, maximum: 32 * 1024 + 28)
        let aad = "mindwire-directory-address-v1\n\(record.audience)\n\(record.directoryId)\n\(record.deviceId)\n\(record.sequence)"
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: secret),
                                         authenticating: Data(aad.utf8))
        let addresses = try JSONDecoder().decode(Addresses.self, from: plaintext)
        guard addresses.routes.count <= 12, addresses.routes.allSatisfy(\.isValid) else { throw ComputerDirectoryError.invalidRecord }
        return Resolved(addresses: addresses, sequence: record.sequence, digest: digest)
    }
}

/// Addresses are learned only from a pinned SSH connection or a signed and
/// encrypted directory record. They never change pairing keys or replay writes.
@MainActor
enum ComputerDirectoryService {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func credential(for computer: PairedComputer) -> ComputerDirectoryCredential? {
        guard let data = Keychain.get(computer.directoryKeyRef)?.data(using: .utf8),
              let credential = try? JSONDecoder().decode(ComputerDirectoryCredential.self, from: data),
              credential.deviceId == computer.deviceId else { return nil }
        return credential
    }
    private static func save(_ credential: ComputerDirectoryCredential, for computer: PairedComputer) throws {
        let encoded = try JSONEncoder().encode(credential)
        guard Keychain.set(String(decoding: encoded, as: UTF8.self), for: computer.directoryKeyRef) else {
            throw ComputerConnectionError.keyStorage
        }
    }

    static func learn(_ info: ComputerConnectionInfo, over channel: DaemonChannel, computer: PairedComputer,
                      stores: Stores = .shared, allowUnsaved: Bool = false) async throws -> ComputerDirectoryDescriptor? {
        guard info.matches(computer) else { throw ComputerConnectionError.identityChanged }
        guard let status = info.discovery else { return computer.discovery }
        guard status.enabled, let url = status.url else {
            if !allowUnsaved { stores.updateComputerDiscovery(nil, for: computer) }
            return nil
        }
        let descriptor = ComputerDirectoryDescriptor(version: status.version, url: url, directoryId: status.directoryId)
        let expected = computer.fingerprint.replacingOccurrences(of: "SHA256:", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        guard descriptor.isValid, descriptor.directoryId == expected else { throw ComputerDirectoryError.invalidRecord }
        var saved = credential(for: computer)
        if saved?.descriptor != descriptor {
            struct Response: Decodable { let version: Int; let url: String; let directoryId: String; let deviceId: String; let secret: String; let sequence: Int64 }
            let response = try await channel.perform(method: "GET", path: "/computer/discovery/devices/\(computer.deviceId)", jsonBody: nil)
            guard response.status == 200, response.body.utf8.count <= 8192,
                  let value = try? JSONDecoder().decode(Response.self, from: Data(response.body.utf8)),
                  value.version == descriptor.version, value.url == descriptor.url,
                  value.directoryId == descriptor.directoryId, value.deviceId == computer.deviceId,
                  value.sequence > 0, value.sequence <= 9_007_199_254_740_991,
                  let key = Data(base64Encoded: value.secret), key.count == 32 else { throw ComputerDirectoryError.invalidRecord }
            try Task.checkCancellation()
            guard allowUnsaved || stores.savedComputer(matching: computer) != nil else { throw CancellationError() }
            saved = ComputerDirectoryCredential(descriptor: descriptor, deviceId: computer.deviceId, secret: value.secret, sequence: value.sequence)
            try save(saved!, for: computer)
        }
        try Task.checkCancellation()
        if !allowUnsaved {
            guard stores.savedComputer(matching: computer) != nil else { throw CancellationError() }
            stores.updateComputerDiscovery(descriptor, for: computer)
            if let saved, !saved.acknowledged {
                let body = try JSONSerialization.data(withJSONObject: ["url": descriptor.url])
                let response = try await channel.perform(method: "POST", path: "/computer/discovery/devices/\(computer.deviceId)/ready", jsonBody: body)
                try Task.checkCancellation()
                guard response.status == 200 else { throw ComputerDirectoryError.unavailable }
                if stores.savedComputer(matching: computer)?.discovery == descriptor {
                    // A lookup may advance the high-water mark while this
                    // receipt is in flight. Never save the earlier snapshot.
                    if var latest = credential(for: computer), latest.descriptor == descriptor, latest.secret == saved.secret {
                        latest.acknowledged = true; try save(latest, for: computer)
                    }
                }
            }
        }
        return descriptor
    }

    static func fetch(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= 128 * 1024 else { throw ComputerDirectoryError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 128 * 1024 else { throw ComputerDirectoryError.invalidRecord }
            data.append(byte)
        }
        return data
    }

    static func lookup(_ computer: PairedComputer, stores: Stores = .shared,
                       transport: (URLRequest) async throws -> Data = fetch) async throws -> [ComputerRoute] {
        guard let current = stores.savedComputer(matching: computer), let descriptor = current.discovery,
              var credential = credential(for: current), credential.descriptor == descriptor,
              descriptor.isValid, let seed = Keychain.get(current.keyRef).flatMap({ Data(base64Encoded: $0) }),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { throw ComputerDirectoryError.unavailable }
        let timestamp = Int64(Date().timeIntervalSince1970)
        let nonce = ComputerDirectoryCodec.urlEncoded(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        let message = "mindwire-directory-lookup-v1\n\(descriptor.url)\n\(descriptor.directoryId)\n\(current.deviceId)\n\(timestamp)\n\(nonce)"
        let signature = try key.signature(for: Data(message.utf8)).base64EncodedString()
        guard let url = URL(string: descriptor.url + "/records/\(descriptor.directoryId)/lookup") else { throw ComputerDirectoryError.invalidRecord }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceId": current.deviceId, "timestamp": timestamp,
            "nonce": nonce, "signature": signature])
        let data = try await transport(request)
        let resolved = try ComputerDirectoryCodec.verify(data, for: current, credential: credential)
        try Task.checkCancellation()
        guard stores.savedComputer(matching: current)?.discovery == descriptor else { throw CancellationError() }
        // Preserve the anti-rollback high-water mark even if the signed address
        // cannot be reached yet. Only a successful SSH handshake saves routes.
        if let latest = self.credential(for: current), latest.descriptor == descriptor {
            guard resolved.sequence >= latest.sequence,
                  resolved.sequence != latest.sequence || latest.digest == nil || resolved.digest == latest.digest else { throw ComputerDirectoryError.invalidRecord }
            credential = latest
        }
        credential.sequence = resolved.sequence; credential.digest = resolved.digest
        try save(credential, for: current)
        return resolved.addresses.routes
    }

    static func open(_ computer: PairedComputer, routes: [ComputerRoute], key: NIOSSHPrivateKey, token: String,
                     stores: Stores = .shared) async throws -> ComputerSSHLink {
        guard stores.savedComputer(matching: computer)?.discovery != nil else {
            return try await ComputerSSHLink.open(routes: routes, username: "device", auth: .privateKey(key),
                fingerprint: computer.fingerprint, port: 8790, token: token, attempts: 3)
        }
        return try await withThrowingTaskGroup(of: Result<ComputerSSHLink, Error>.self) { group in
            group.addTask {
                do { return .success(try await ComputerSSHLink.open(routes: routes, username: "device", auth: .privateKey(key),
                    fingerprint: computer.fingerprint, port: 8790, token: token)) }
                catch { return .failure(error) }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .milliseconds(600))
                    let discovered: [ComputerRoute]
                    do { discovered = try await lookup(computer, stores: stores) }
                    catch {
                        try Task.checkCancellation()
                        throw (error as? ComputerDirectoryError) ?? ComputerDirectoryError.unavailable
                    }
                    let candidates = discovered.filter { !routes.contains($0) }
                    guard !candidates.isEmpty else { throw ComputerDirectoryError.unchanged }
                    return .success(try await ComputerSSHLink.open(routes: candidates, username: "device", auth: .privateKey(key),
                        fingerprint: computer.fingerprint, port: 8790, token: token))
                } catch { return .failure(error) }
            }
            var failures: [Error] = []
            for try await result in group {
                switch result {
                case .success(let link): group.cancelAll(); return link
                case .failure(let error): failures.append(error)
                }
            }
            try Task.checkCancellation()
            let error = ComputerSSHLink.connectionFailure(failures)
            // A rotating URL may now belong to someone else. It is never trusted;
            // retry discovery later if the directory was temporarily unavailable.
            if error == .identityChanged, failures.contains(where: {
                if $0 is ComputerDirectoryError { return true }
                return $0 is URLError
            }) {
                throw ComputerConnectionError.unreachable
            }
            throw error
        }
    }
}
