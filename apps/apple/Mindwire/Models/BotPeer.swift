import Foundation

/// Public, pinned daemon identities only. No phone keys or cloud account tokens enter the mesh.
struct BotPeerIdentity: Codable, Hashable {
    let workspaceId: String
    let publicKey: String
    let hostKeyFingerprint: String
    var routes: [ComputerRoute]? = nil
    var port: Int? = nil
    var sshPort: Int? = nil
}

struct BotPeerEndpoint: Hashable {
    let identity: BotPeerIdentity
    let routes: [ComputerRoute]
    var routingIssue: String? = nil
}

struct BotPeerRegistration: Codable, Hashable {
    let name: String
    let publicKey: String
    let hostKeyFingerprint: String
    let routes: [ComputerRoute]
    var enabled = true
}

struct BotPeerCheck: Decodable {
    let workspaceId: String
    let reachable: Bool
    var error: String? = nil
}
