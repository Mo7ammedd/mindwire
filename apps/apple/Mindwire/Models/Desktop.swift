import Foundation

struct DesktopSetup: Codable, Equatable {
    let reason: String
    let command: String
}

struct DesktopProviderStatus: Equatable {
    let supported: Bool
    let enabled: Bool
    let available: Bool
    let credentials: Bool?
    var setup: DesktopSetup? = nil
}

struct DesktopCapabilities: Codable, Equatable {
    var view = false
    var capture = false
    var pointer = false
    var keyboard = false
    var text = false
    var clipboardRead = false
    var clipboardWrite = false
    // Optional additions to protocol 1; older services keep working with single keys.
    var keyboardText: Bool?
    var extendedKeys: Bool?
}
struct DesktopGeometry: Codable, Equatable {
    let width: Int
    let height: Int
    let revision: Int64
}
struct DesktopController: Codable, Equatable {
    let sessionId: String
    let actor: String
    let name: String
    let runId: String?
    let chatId: String?
    let generation: Int64
    let expiresAt: String
}
struct DesktopProblem: Codable, Equatable, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}
struct DesktopRemoteCursor: Codable, Equatable {
    let id: String
    let width: Int
    let height: Int
    let hotspotX: Int
    let hotspotY: Int
    let png: Data
}
struct DesktopSnapshot: Codable, Equatable {
    let id: String
    let workspaceId: String
    let version: Int
    var revision: Int64
    let instanceId: String
    let state: String
    let supported: Bool
    let enabled: Bool
    let available: Bool
    let os: String?
    let capabilities: DesktopCapabilities
    let geometry: DesktopGeometry?
    let controller: DesktopController?
    let authorizationExpiresAt: String?
    let error: DesktopProblem?
    var provider: String? = nil
    var setup: DesktopSetup? = nil
    var desktopId: String? = nil
    var cursor: DesktopRemoteCursor? = nil
}
struct DesktopSession: Codable, Equatable {
    let id: String
    let surfaceId: String
    let mode: String
    let controller: DesktopController?
    var desktopId: String? = nil
}
struct DesktopCapture: Codable, Equatable {
    let id: String
    let surfaceId: String
    let artifactId: String
    let mime: String
    let geometry: DesktopGeometry
    let createdAt: String
}
struct DesktopReceipt: Codable, Equatable {
    let id: String
    let sessionId: String
    let surfaceId: String
    let kind: String
    let status: String
    let error: DesktopProblem?
    let text: String?
}
struct DesktopArtifact: Decodable {
    let id: String
    let mime: String
    let width: Int
    let height: Int
    let data: Data
}
struct DesktopInput: Codable, Equatable {
    var kind: String
    var x: Int?
    var y: Int?
    var toX: Int?
    var toY: Int?
    var buttons: Int?
    var button: String?
    var count: Int?
    var deltaX: Int?
    var deltaY: Int?
    var keys: [String]?
    var text: String?
    var textMode: String?
}
struct DesktopActionRequest: Encodable {
    let requestId: String
    let sessionId: String
    let controlGeneration: Int64
    let geometryRevision: Int64
    let action: DesktopInput
}
struct DesktopSSHGrant: Codable, Equatable {
    struct SSH: Codable, Equatable {
        let host: String
        let port: Int
        let username: String
        let password: String
        let host_key_fingerprint: String
    }
    struct VNC: Codable, Equatable {
        let host: String
        let port: Int
        let authentication: String
    }
    let expires_at: String
    let ssh: SSH
    let vnc: VNC
    var session_id: String? = nil
    var expiresAt: Date? {
        let parser = ISO8601DateFormatter()
        if let date = parser.date(from: expires_at) { return date }
        parser.formatOptions.insert(.withFractionalSeconds)
        return parser.date(from: expires_at)
    }
    func validate(workspaceId: String, desktopId: String? = nil) throws {
        guard ssh.host == "ssh.oblien.com", ssh.port == 22, ssh.username.hasPrefix("desktop-"),
              ssh.username.contains(workspaceId), !ssh.password.isEmpty,
              ssh.host_key_fingerprint.hasPrefix("SHA256:"),
              vnc.host == "127.0.0.1", vnc.port == 5900, vnc.authentication == "none",
              let expiresAt, expiresAt > Date(), desktopId == nil || session_id == desktopId else {
            throw DesktopProblem(code: "invalid_grant", message: "Refresh the desktop connection settings and try again.")
        }
    }
}

extension Encodable {
    func desktopJSON() throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) }
}
