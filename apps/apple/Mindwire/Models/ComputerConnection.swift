import Foundation

/// Routes carry the same SSH protocol. Identity is pinned independently of the address/provider.
struct ComputerRoute: Codable, Hashable {
    let kind: String
    var host: String?
    var port: Int?
    var url: String?

    var isValid: Bool {
        switch kind {
        case "ssh":
            guard let host, !host.isEmpty, host.count <= 255,
                  !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" }),
                  let port, (1...65535).contains(port) else { return false }
            return true
        case "websocket":
            guard let text = url, text.count <= 2048, let url = URL(string: text),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else { return false }
            if url.scheme == "wss" { return true }
            #if DEBUG
            // Local integration tests exercise the same SSH-encrypted carrier without a TLS proxy.
            return url.scheme == "ws" && ["127.0.0.1", "localhost", "[::1]"].contains(host)
            #else
            return false
            #endif
        default: return false
        }
    }
}

struct ComputerInvitation: Codable, Equatable {
    let version: Int
    let computerId: String
    let name: String
    let fingerprint: String
    let routes: [ComputerRoute]
    let pairingId: String
    let secret: String
    let expiresAt: String

    var expiry: Date? {
        ComputerConnectionCode.expiry(expiresAt)
    }

    static func parse(_ text: String, now: Date = Date()) throws -> ComputerInvitation {
        guard case .pairing(let invitation) = try ComputerConnectionCode.parse(text, now: now) else {
            throw ComputerConnectionError.invalidInvitation
        }
        return invitation
    }
}

/// This code only refreshes routes. It cannot authorize a phone or replace a saved host key.
struct ComputerReconnectCode: Codable, Equatable {
    let version: Int
    let mode: String
    let computerId: String
    let registryId: String
    let name: String
    let fingerprint: String
    let routes: [ComputerRoute]
    let expiresAt: String

    func matches(_ saved: PairedComputer) -> Bool {
        computerId == saved.computerId && registryId == saved.registryId && fingerprint == saved.fingerprint
    }
}

enum ComputerConnectionCode: Equatable {
    case pairing(ComputerInvitation)
    case reconnect(ComputerReconnectCode)

    var computerId: String {
        switch self { case .pairing(let code): code.computerId; case .reconnect(let code): code.computerId }
    }

    static func expiry(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func parse(_ text: String, now: Date = Date()) throws -> ComputerConnectionCode {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 65_536 else { throw ComputerConnectionError.invalidInvitation }
        let data: Data
        var action: String?
        if text.hasPrefix("{") { data = Data(text.utf8) }
        else {
            guard let url = URL(string: text), url.scheme == "mindwire", ["pair", "reconnect"].contains(url.host),
                  url.user == nil, url.password == nil, url.port == nil,
                  var encoded = url.fragment else { throw ComputerConnectionError.invalidInvitation }
            action = url.host
            encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let decoded = Data(base64Encoded: encoded) else { throw ComputerConnectionError.invalidInvitation }
            data = decoded
        }
        struct Header: Decodable {
            let version: Int; let mode: String?; let computerId: String; let name: String
            let fingerprint: String; let routes: [ComputerRoute]; let expiresAt: String
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.version == 1,
              !header.computerId.isEmpty, header.computerId.count <= 128, header.name.count <= 255,
              header.fingerprint.range(of: "^SHA256:[A-Za-z0-9+/]{43}$", options: .regularExpression) != nil,
              !header.routes.isEmpty, header.routes.count <= 12, header.routes.allSatisfy(\.isValid),
              let expiry = expiry(header.expiresAt) else { throw ComputerConnectionError.invalidInvitation }
        guard expiry > now else { throw ComputerConnectionError.expired }
        if header.mode == "reconnect" {
            guard action == nil || action == "reconnect",
                  let code = try? JSONDecoder().decode(ComputerReconnectCode.self, from: data),
                  !code.registryId.isEmpty, code.registryId.count <= 128 else { throw ComputerConnectionError.invalidInvitation }
            return .reconnect(code)
        }
        guard header.mode == nil, action == nil || action == "pair",
              let code = try? JSONDecoder().decode(ComputerInvitation.self, from: data),
              !code.pairingId.isEmpty, code.pairingId.count <= 128,
              code.secret.count >= 32, code.secret.count <= 128 else { throw ComputerConnectionError.invalidInvitation }
        return .pairing(code)
    }
}

struct PairedComputer: Codable, Hashable {
    let computerId: String
    let registryId: String
    let deviceId: String
    let fingerprint: String
    var routes: [ComputerRoute]
    let keyRef: String
    let tokenRef: String
    var operatingSystem: String?
    var connection: ComputerConnectionPolicy?
    var discovery: ComputerDirectoryDescriptor?

    var directoryKeyRef: String { "computer.\(computerId).directory-key" }

    var connectionPolicy: ComputerConnectionPolicy {
        connection ?? ComputerConnectionPolicy.inferred(from: routes)
    }

    func samePairing(as other: PairedComputer) -> Bool {
        computerId == other.computerId && registryId == other.registryId && deviceId == other.deviceId
            && fingerprint == other.fingerprint && keyRef == other.keyRef && tokenRef == other.tokenRef
    }
}

extension Notification.Name {
    static let computerConnectionChanged = Notification.Name("mindwire.computer.connectionChanged")
    static let computerTransportFailed = Notification.Name("mindwire.computer.transportFailed")
    static let computerTransportRecovered = Notification.Name("mindwire.computer.transportRecovered")
}

/// Display metadata comes through the pinned SSH connection. Old services are
/// identified conservatively from their routes, without trusting a QR's claims.
struct ComputerConnectionPolicy: Codable, Hashable {
    let provider: String
    let address: String

    var providerName: String {
        switch provider {
        case "oblien": "Oblien"
        case "cloudflare": "Cloudflare"
        case "ngrok": "ngrok"
        case "direct": "Direct SSH / VPN"
        default: "Your tunnel"
        }
    }
    var isPersistent: Bool { address == "persistent" }
    var summary: String {
        switch address {
        case "persistent": "Persistent address"
        case "temporary": "Temporary address"
        case "network": "Reachable network required"
        default: "Saved address"
        }
    }
    static func inferred(from routes: [ComputerRoute]) -> Self {
        guard let route = routes.first(where: { $0.kind == "websocket" }),
              let host = route.url.flatMap(URL.init(string:))?.host?.lowercased() else {
            return .init(provider: "direct", address: "network")
        }
        if host.hasSuffix(".trycloudflare.com") { return .init(provider: "cloudflare", address: "temporary") }
        if host.hasSuffix(".preview.oblien.com") { return .init(provider: "oblien", address: "persistent") }
        if host.hasSuffix(".ngrok-free.app") || host.hasSuffix(".ngrok.app") || host.hasSuffix(".ngrok.io") {
            return .init(provider: "ngrok", address: "unknown")
        }
        return .init(provider: "custom", address: "unknown")
    }
}

struct ComputerHost: Decodable {
    let hostname: String
    let os: String
    let arch: String
    let home: String
    let directory: String
    let pid: Int
}

struct ComputerConnectionInfo: Decodable {
    let computerId: String
    let registryId: String
    let fingerprint: String
    let routes: [ComputerRoute]
    var connection: ComputerConnectionPolicy?
    var discovery: ComputerDirectoryStatus?

    func matches(_ computer: PairedComputer) -> Bool {
        computerId == computer.computerId && registryId == computer.registryId
            && fingerprint == computer.fingerprint && routes.count <= 12 && routes.allSatisfy(\.isValid)
    }
}

enum ComputerConnectionError: LocalizedError, Equatable {
    case invalidInvitation, expired, codeInUse, codeRejected, notPaired, identityChanged, declined, keyStorage, unreachable
    case internetAddressUnavailable, tunnelUnavailable

    var canRetryConnection: Bool {
        switch self {
        case .unreachable, .internetAddressUnavailable, .tunnelUnavailable: true
        default: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .invalidInvitation: return "This isn't a valid Mindwire connection code. Scan a new code from your computer."
        case .expired: return "This connection code expired. Run mindwire connect on your computer and scan the new code."
        case .codeInUse: return "This code was already used by another connection. Run mindwire connect on your computer and scan the new code."
        case .codeRejected: return "Your computer no longer accepts this connection code. Run mindwire connect and scan its new QR code."
        case .notPaired: return "Pair this phone again: run mindwire connect on your computer and scan its new QR code here."
        case .identityChanged: return "The computer's identity doesn't match your saved connection. Reconnect was cancelled and your saved keys haven't changed."
        case .declined: return "The computer declined this connection."
        case .keyStorage: return "Couldn't save this connection securely. Unlock your iPhone and try again."
        case .unreachable: return "Couldn't reach your computer. Check that it's awake, online, and running Mindwire."
        case .internetAddressUnavailable: return "The saved internet address isn't available. Mindwire can retry it. If you used a temporary address, choose a persistent connection on your computer."
        case .tunnelUnavailable: return "Your computer's internet tunnel isn't responding yet. Mindwire can retry when the computer is awake and online."
        }
    }
}
