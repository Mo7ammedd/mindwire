import Foundation

/// Where an agent's workspace runs. Discriminated union on `kind` to match the TS wire shape.
/// Design rule: Oblien Cloud is a *runtime*, never a saved server/Connection.
enum AgentRuntime: Codable, Hashable {
    case local(computerId: String)
    case cloud(workspaceId: String?)
    case server(serverId: String)
    case container(serverId: String, sandbox: ServerSandbox)

    private enum CodingKeys: String, CodingKey { case kind, workspaceId, serverId, sandbox, computerId }
    private enum Kind: String, Codable { case local, cloud, server, container }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .local:
            self = .local(computerId: try c.decode(String.self, forKey: .computerId))
        case .cloud:
            self = .cloud(workspaceId: try c.decodeIfPresent(String.self, forKey: .workspaceId))
        case .server:
            self = .server(serverId: try c.decode(String.self, forKey: .serverId))
        case .container:
            self = .container(serverId: try c.decode(String.self, forKey: .serverId),
                              sandbox: try c.decode(ServerSandbox.self, forKey: .sandbox))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let id):
            try c.encode(Kind.local, forKey: .kind)
            try c.encode(id, forKey: .computerId)
        case .cloud(let wid):
            try c.encode(Kind.cloud, forKey: .kind)
            try c.encodeIfPresent(wid, forKey: .workspaceId)
        case .server(let sid):
            try c.encode(Kind.server, forKey: .kind)
            try c.encode(sid, forKey: .serverId)
        case .container(let sid, let sandbox):
            try c.encode(Kind.container, forKey: .kind)
            try c.encode(sid, forKey: .serverId)
            try c.encode(sandbox, forKey: .sandbox)
        }
    }

    // Helpers mirroring runtime.ts
    static let cloud = AgentRuntime.cloud(workspaceId: nil)
    static func cloudRuntimeWith(_ workspaceId: String) -> AgentRuntime { .cloud(workspaceId: workspaceId) }
    static func serverRuntime(_ serverId: String) -> AgentRuntime { .server(serverId: serverId) }

    var isLocal: Bool { if case .local = self { return true }; return false }
    var isCloud: Bool { if case .cloud = self { return true }; return false }
    var isServer: Bool { serverId != nil }
    var serverId: String? {
        switch self { case .server(let id), .container(let id, _): return id; case .cloud, .local: return nil }
    }
    var sandbox: ServerSandbox? { if case .container(_, let sandbox) = self { return sandbox }; return nil }
    var workspaceId: String? { if case .cloud(let w) = self { return w }; return nil }
}

/// Stable, portable identity for one Docker environment on a saved SSH host.
/// The initial image is pinned; later service updates use the shared release installer.
struct ServerSandbox: Codable, Hashable {
    let id: String
    let version: String
    var name: String { "mindwire-" + id }
    var volume: String { "mindwire-home-" + id }
    var image: String { "ghcr.io/oblien/mindwire-runtime:" + version }
    static let home = "/home/node"
    static let minimumServiceVersion = "0.1.17"
    static let ownerLabel = "io.mindwire.workspace"
    static let nameLabel = "io.mindwire.name"

    var isValid: Bool {
        id.count == 32 && id.allSatisfy { "0123456789abcdef".contains($0) }
            && version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil
    }
}
