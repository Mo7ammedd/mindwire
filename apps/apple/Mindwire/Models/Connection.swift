import Foundation

/// Saved servers only (cloud is excluded by design — it is a runtime, not a server).
enum ConnectionType: String, Codable, Hashable { case local, ssh, vps }

/// SSH auth — secret material is referenced by id (stored in the keychain), never inline.
enum SshAuthMethod: Codable, Hashable {
    case password(secretRef: String)
    case key(secretRef: String)
    case agent

    private enum CodingKeys: String, CodingKey { case kind, secretRef }
    private enum Kind: String, Codable { case password, key, agent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .password: self = .password(secretRef: try c.decode(String.self, forKey: .secretRef))
        case .key: self = .key(secretRef: try c.decode(String.self, forKey: .secretRef))
        case .agent: self = .agent
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .password(let r): try c.encode(Kind.password, forKey: .kind); try c.encode(r, forKey: .secretRef)
        case .key(let r): try c.encode(Kind.key, forKey: .kind); try c.encode(r, forKey: .secretRef)
        case .agent: try c.encode(Kind.agent, forKey: .kind)
        }
    }
}

struct LocalConnection: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var type: ConnectionType = .local
    var deviceName: String
    var pairingId: String
    /// Verified identity/routes; credentials remain in Keychain. Nil migrates old placeholder rows.
    var computer: PairedComputer? = nil
    var workspace: String?
    let createdAt: String
    var lastUsedAt: String?
    var defaultAgent: AgentID? // deprecated
}

/// ssh + vps share the same shape.
struct RemoteHostConnection: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var type: ConnectionType // .ssh | .vps
    var host: String
    var port: Int
    var username: String
    var auth: SshAuthMethod
    var workspace: String?
    let createdAt: String
    var lastUsedAt: String?
    var defaultAgent: AgentID? // deprecated
}

/// Discriminated union on `type` — encodes/decodes flat to match the TS objects.
enum Connection: Codable, Identifiable, Hashable {
    case local(LocalConnection)
    case ssh(RemoteHostConnection)
    case vps(RemoteHostConnection)

    var id: String {
        switch self {
        case .local(let c): return c.id
        case .ssh(let c), .vps(let c): return c.id
        }
    }
    var type: ConnectionType {
        switch self {
        case .local: return .local
        case .ssh: return .ssh
        case .vps: return .vps
        }
    }
    var name: String {
        switch self {
        case .local(let c): return c.name
        case .ssh(let c), .vps(let c): return c.name
        }
    }
    var workspace: String? {
        switch self {
        case .local(let c): return c.workspace
        case .ssh(let c), .vps(let c): return c.workspace
        }
    }
    var lastUsedAt: String? {
        switch self {
        case .local(let c): return c.lastUsedAt
        case .ssh(let c), .vps(let c): return c.lastUsedAt
        }
    }
    /// Non-nil for ssh/vps.
    var remote: RemoteHostConnection? {
        switch self {
        case .ssh(let c), .vps(let c): return c
        case .local: return nil
        }
    }
    var isLocal: Bool { if case .local = self { return true }; return false }
    var isSsh: Bool { if case .ssh = self { return true }; return false }
    var isVps: Bool { if case .vps = self { return true }; return false }

    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        switch try c.decode(ConnectionType.self, forKey: .type) {
        case .local: self = .local(try LocalConnection(from: decoder))
        case .ssh: self = .ssh(try RemoteHostConnection(from: decoder))
        case .vps: self = .vps(try RemoteHostConnection(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .local(let c): try c.encode(to: encoder)
        case .ssh(let c), .vps(let c): try c.encode(to: encoder)
        }
    }
}

/// Add-server form model (mirrors `EMPTY_SERVER`).
/// How the add-server form authenticates; maps to `SshAuthMethod` on save.
enum ServerAuthMethod: String, CaseIterable, Hashable, Identifiable {
    case password, key, agent
    var id: String { rawValue }
}

struct ServerDraft: Equatable {
    var type: ConnectionType = .ssh
    var name: String = ""
    var host: String = ""
    var port: String = "22"
    var username: String = ""
    var authMethod: ServerAuthMethod = .password
    /// The password or private-key text — stored in the Keychain on save, never inline.
    var secret: String = ""
    /// Local pairing code (scanned or typed) for a Mac/PC connection.
    var pairCode: String = ""
}

extension ServerDraft {
    /// Testing and saving use the same address. Password whitespace is intentional
    /// and must never be trimmed along with the visible connection fields.
    func normalizedRemote() throws -> ServerDraft {
        guard type != .local else { throw BackendError.message("Pair your computer using its connection code.") }
        var value = self
        value.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.host.hasPrefix("["), value.host.hasSuffix("]") {
            value.host = String(value.host.dropFirst().dropLast())
        }
        value.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.host.isEmpty, !value.host.contains(where: \.isWhitespace),
              !value.host.contains("/"), !value.host.contains("@"),
              !value.username.isEmpty, !value.username.contains(where: \.isWhitespace) else {
            throw BackendError.message("Enter a hostname or IP address and an SSH username. Put the port in its own field.")
        }
        guard let port = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            throw BackendError.message("Enter a valid SSH port between 1 and 65535.")
        }
        value.port = String(port)
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.name.isEmpty { value.name = value.host }
        return value
    }

    init(editing connection: RemoteHostConnection) {
        self.init(type: connection.type, name: connection.name, host: connection.host,
                  port: String(connection.port), username: connection.username)
        switch connection.auth {
        case .password: authMethod = .password
        case .key: authMethod = .key
        case .agent: authMethod = .agent
        }
    }
}
