import Foundation

/// Notification management uses the same Mindwire device session as computers.
actor MindwireServicesAPI {
    static let shared = MindwireServicesAPI()
    func send(_ method: String, _ path: String, body: Data? = nil, retrying: Bool = false) async throws -> Data? {
        guard path.hasPrefix("/api/notifications/") else { throw APIError.badURL(path) }
        return try await MindwireAPI.shared.accountRequest(method, path, body: body)
    }
}

struct NotificationSendToken: Decodable, Sendable {
    let id: Int
    var status: String
    let tokenPrefix: String?
    let token: String?
    let workspaceID: String?
    let tag: String?
    enum CodingKeys: String, CodingKey {
        case id, status, token, tag
        case tokenPrefix = "token_prefix", workspaceID = "workspace_id"
    }
}
