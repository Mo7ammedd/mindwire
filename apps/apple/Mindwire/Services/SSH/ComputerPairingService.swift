import Foundation
import Crypto
import NIOSSH

@MainActor
enum ComputerPairingService {
    struct Result {
        var invitation: ComputerInvitation? = nil
        let computer: PairedComputer
        let host: ComputerHost
        var health: DaemonHealth? = nil
        var pairingRequestId: String? = nil
    }
    private struct Pending: Codable {
        let pairingId: String
        let computerId: String
        let requestId: String
        let name: String
        let seed: String
    }
    private struct Response: Decodable {
        struct Device: Decodable { let id: String; let publicKey: String }
        let status: String
        let requestId: String
        var computerId: String?
        var registryId: String?
        var fingerprint: String?
        var routes: [ComputerRoute]?
        var daemonToken: String?
        var apiPort: Int?
        var device: Device?
    }
    private static var confirmations: [String: Task<Void, Never>] = [:]

    static func pair(_ text: String, deviceName: String, stores: Stores = .shared,
                     onStatus: @escaping @MainActor @Sendable (String) -> Void) async throws -> Result {
        let code = try ComputerConnectionCode.parse(text)
        if case .reconnect(let code) = code {
            return try await reconnect(code, stores: stores, onStatus: onStatus)
        }
        guard case .pairing(let invitation) = code else { throw ComputerConnectionError.invalidInvitation }
        let savedComputer = stores.connections.list().compactMap(\.pairedComputer).first {
            $0.computerId == invitation.computerId
        }
        if let savedComputer, savedComputer.fingerprint != invitation.fingerprint {
            throw ComputerConnectionError.identityChanged
        }
        let pendingRef = "computer.\(invitation.computerId).pending-pairing"
        let keyRef = "computer.\(invitation.computerId).key"
        let tokenRef = "computer.\(invitation.computerId).token"
        let previous = self.pending(at: pendingRef) ?? self.pending(at: "computer.pending-pairing")
        let pending: Pending
        if let saved = previous,
           saved.pairingId == invitation.pairingId, saved.computerId == invitation.computerId {
            pending = saved
        } else {
            // Persist the identity before contacting the computer. A new QR, a
            // cancelled screen, or a lost acknowledgement must reuse that key.
            let seed = Keychain.get(keyRef)
                ?? (previous?.computerId == invitation.computerId ? previous?.seed : nil)
                ?? SSHKey.generate(comment: "mindwire").privateSeedBase64
            var name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .controlCharacters).joined()
            while name.utf8.count > 100 { name.removeLast() }
            if name.isEmpty { name = "iPhone" }
            pending = Pending(pairingId: invitation.pairingId, computerId: invitation.computerId,
                requestId: UUID().uuidString, name: name, seed: seed)
        }
        let json = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        guard Keychain.set(json, for: pendingRef) else { throw ComputerConnectionError.keyStorage }
        guard let seed = Data(base64Encoded: pending.seed),
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
              let key = SSHKey.privateKey(from: pending.seed),
              Keychain.set(pending.seed, for: keyRef) else { throw ComputerConnectionError.keyStorage }
        let publicKey = String(openSSHPublicKey: key.publicKey)
        let proof = "mindwire-computer-pairing-v1\n\(invitation.pairingId)\n\(pending.requestId)\n\(pending.name)\n\(publicKey)"
        let signature = try signingKey.signature(for: Data(proof.utf8)).base64EncodedString()
        let request = try JSONSerialization.data(withJSONObject: ["id": pending.requestId, "name": pending.name,
            "publicKey": publicKey, "signature": signature])
        onStatus("Connecting securely…")
        var link: ComputerSSHLink?
        defer { link?.ssh.close() }
        var response: Response?
        var transportFailures = 0
        while Date() < (invitation.expiry ?? .distantPast) {
            try Task.checkCancellation()
            do {
                if link == nil {
                    link = try await ComputerSSHLink.open(routes: invitation.routes, username: "pair:\(invitation.pairingId)",
                        auth: .password(invitation.secret), fingerprint: invitation.fingerprint, port: 8793, token: nil)
                }
                let result = try await link!.channel.perform(method: "POST", path: "/pair", jsonBody: request)
                if result.status != 200 {
                    struct Failure: Decodable { let error: String }
                    let failure = result.body.data(using: .utf8).flatMap { try? JSONDecoder().decode(Failure.self, from: $0) }
                    switch failure?.error {
                    case "this invitation already has a different device request": throw ComputerConnectionError.codeInUse
                    case "pairing expired; create a new QR code on the computer": throw ComputerConnectionError.expired
                    case "invalid device pairing proof": throw ComputerConnectionError.invalidInvitation
                    default: throw ComputerConnectionError.declined
                    }
                }
                // Never pass the pairing body (which may contain a daemon credential) to logs.
                guard let data = result.body.data(using: .utf8), let value = try? JSONDecoder().decode(Response.self, from: data),
                      value.requestId == pending.requestId else { throw ComputerConnectionError.invalidInvitation }
                transportFailures = 0
                response = value
                if value.status == "approved" { break }
                if value.status == "rejected" { throw ComputerConnectionError.declined }
                guard value.status == "pending" else { throw ComputerConnectionError.invalidInvitation }
                let fingerprint = PinnedSSHHostKey.fingerprint(key.publicKey) ?? ""
                onStatus("Approve \(pending.name) on your computer.\nDevice key: \(fingerprint)")
            } catch {
                link?.ssh.close(); link = nil
                try Task.checkCancellation()
                if let connectionError = error as? ComputerConnectionError {
                    guard connectionError.canRetryConnection else { throw connectionError }
                }
                transportFailures += 1
                guard transportFailures < 3 else { throw error }
                onStatus("Connection interrupted. Retrying…")
            }
            try await Task.sleep(for: .seconds(1))
        }
        guard let response, response.status == "approved" else { throw ComputerConnectionError.expired }
        guard response.computerId == invitation.computerId, response.fingerprint == invitation.fingerprint,
              response.apiPort == 8790, let device = response.device, device.publicKey == publicKey,
              let registry = response.registryId, !registry.isEmpty,
              let routes = response.routes, !routes.isEmpty, routes.count <= 12, routes.allSatisfy(\.isValid),
              let token = response.daemonToken, !token.isEmpty, token.count <= 4096,
              !token.contains(where: \.isWhitespace) else { throw ComputerConnectionError.invalidInvitation }
        if let savedComputer, savedComputer.registryId != registry { throw ComputerConnectionError.identityChanged }
        guard Keychain.set(pending.seed, for: keyRef), Keychain.set(token, for: tokenRef) else { throw ComputerConnectionError.keyStorage }
        var computer = PairedComputer(computerId: invitation.computerId, registryId: registry, deviceId: device.id,
            fingerprint: invitation.fingerprint, routes: routes, keyRef: keyRef, tokenRef: tokenRef)
        let verified = try await verifiedLink(computer)
        defer { verified.ssh.close() }
        do {
            onStatus("Opening your workspace…")
            let http = DaemonHTTP(channel: verified.channel, agentType: "")
            let info: ComputerConnectionInfo = try await http.decode("GET", "/computer", quiet: true)
            guard info.matches(computer) else { throw ComputerConnectionError.identityChanged }
            let host: ComputerHost = try await http.decode("GET", "/workspace/host", quiet: true)
            let health: DaemonHealth = try await http.decode("GET", "/healthz", quiet: true)
            guard health.ok else { throw ComputerConnectionError.unreachable }
            computer.operatingSystem = host.os
            computer.connection = info.connection
            computer.discovery = try await ComputerDirectoryService.learn(info, over: verified.channel,
                computer: computer, stores: stores, allowUnsaved: true)
            // Keep the receipt for rescanning this QR. The next invitation
            // replaces it; removing the computer also removes this key material.
            if self.pending(at: "computer.pending-pairing")?.requestId == pending.requestId { Keychain.delete("computer.pending-pairing") }
            return Result(invitation: invitation, computer: computer, host: host, health: health,
                pairingRequestId: pending.requestId)
        } catch { throw error }
    }

    private static func pending(at reference: String) -> Pending? {
        Keychain.get(reference)?.data(using: .utf8).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) }
    }

    static func forgetPendingPairing(for computerId: String) {
        Keychain.delete("computer.\(computerId).pending-pairing")
        if pending(at: "computer.pending-pairing")?.computerId == computerId { Keychain.delete("computer.pending-pairing") }
    }

    /// Called only after the connection and workspace have been persisted. The
    /// terminal must never report success merely because the owner pressed Allow.
    static func confirmSaved(_ result: Result, stores: Stores) {
        guard let invitation = result.invitation, let requestId = result.pairingRequestId,
              confirmations[invitation.pairingId] == nil else { return }
        confirmations[invitation.pairingId] = Task { @MainActor in
            defer { confirmations[invitation.pairingId] = nil }
            for _ in 0..<3 {
                guard (invitation.expiry ?? .distantPast) > Date(), stores.connections.list().contains(where: {
                    $0.pairedComputer?.samePairing(as: result.computer) == true
                }) else { return }
                do {
                    let link = try await verifiedLink(result.computer)
                    defer { link.ssh.close() }
                    let http = DaemonHTTP(channel: link.channel, agentType: "")
                    let info: ComputerConnectionInfo = try await http.decode("GET", "/computer", quiet: true)
                    _ = try await ComputerDirectoryService.learn(info, over: link.channel, computer: result.computer, stores: stores)
                    _ = try await http.run("POST", "/computer/pairings/\(http.encQuery(invitation.pairingId))/complete",
                        json: ["requestId": requestId], quiet: true)
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private static func reconnect(_ code: ComputerReconnectCode, stores: Stores,
                                  onStatus: @escaping @MainActor @Sendable (String) -> Void) async throws -> Result {
        guard let saved = stores.connections.list().compactMap(\.pairedComputer).first(where: {
            $0.computerId == code.computerId
        }) else { throw ComputerConnectionError.notPaired }
        guard code.matches(saved) else { throw ComputerConnectionError.identityChanged }
        return try await verifySavedComputer(saved, routes: code.routes, stores: stores, onStatus: onStatus)
    }

    static func resume(_ saved: PairedComputer, stores: Stores = .shared,
                       onStatus: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async throws -> Result {
        try await verifySavedComputer(saved, routes: stores.computerRoutes(for: saved), stores: stores, reuseConnection: true, onStatus: onStatus)
    }

    private static func verifySavedComputer(_ saved: PairedComputer, routes: [ComputerRoute], stores: Stores, reuseConnection: Bool = false,
                                             onStatus: @escaping @MainActor @Sendable (String) -> Void) async throws -> Result {
        var updated = saved
        updated.routes = routes
        onStatus("Verifying your saved computer…")
        // Use the candidate routes directly, never a channel which prefers cached routes.
        // SSH verifies the SAVED host pin and authenticates with the SAVED phone key.
        let link = reuseConnection ? nil : try await verifiedLink(updated, onStatus: onStatus)
        let shared = reuseConnection ? ComputerDaemonChannel(computer: updated, stores: stores) : nil
        defer { link?.ssh.close(); if let shared { Task { await shared.close() } } }
        let channel: DaemonChannel = (shared as DaemonChannel?) ?? link!.channel
        let http = DaemonHTTP(channel: channel, agentType: "")
        let info: ComputerConnectionInfo = try await http.decode("GET", "/computer", quiet: true)
        guard info.matches(saved), !info.routes.isEmpty else { throw ComputerConnectionError.identityChanged }
        onStatus("Opening your workspace…")
        let host: ComputerHost = try await http.decode("GET", "/workspace/host", quiet: true)
        let health: DaemonHealth = try await http.decode("GET", "/healthz", quiet: true)
        guard health.ok else { throw ComputerConnectionError.unreachable }
        try Task.checkCancellation()
        // Removing the computer during a slow connection must not restore it again.
        guard stores.connections.list().contains(where: {
            guard let current = $0.pairedComputer else { return false }
            return current.computerId == saved.computerId && current.registryId == saved.registryId
                && current.fingerprint == saved.fingerprint && current.deviceId == saved.deviceId
                && current.keyRef == saved.keyRef && current.tokenRef == saved.tokenRef
        }) else {
            throw ComputerConnectionError.notPaired
        }
        updated.routes = info.routes
        updated.connection = info.connection
        updated.discovery = try await ComputerDirectoryService.learn(info, over: channel, computer: saved, stores: stores)
        updated.operatingSystem = host.os
        return Result(computer: updated, host: host, health: health)
    }

    private static func verifiedLink(_ computer: PairedComputer,
                                    onStatus: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async throws -> ComputerSSHLink {
        guard let key = SSHKey.loadPrivateKey(computer.keyRef),
              let token = Keychain.get(computer.tokenRef), !token.isEmpty else { throw ComputerConnectionError.notPaired }
        return try await ComputerSSHLink.open(routes: computer.routes, username: "device", auth: .privateKey(key),
            fingerprint: computer.fingerprint, port: 8790, token: token, attempts: 3) { attempt, total in
                await onStatus(attempt == 1 ? "Checking your saved addresses…" : "Retrying secure connection (\(attempt) of \(total))…")
            }
    }
}
