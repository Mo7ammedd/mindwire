import Foundation

/// A chat thread = an agent working in a project (workspace registry, cached in `mindwire:chats`). The project supplies
/// the running context (workspace + cwd), so `projectId` is required.
struct Chat: Codable, Identifiable, Hashable {
    let id: String
    let agentId: String
    let projectId: String
    var title: String
    let createdAt: String
    var sessionId: String?
    /// True once the USER manually renamed this chat. It protects that rename from being overwritten
    /// by the agent's own auto-generated title (`syncChatTitle`) — the agent owns titles otherwise.
    /// Optional for back-compat: chats stored before this field decode as nil (= not user-set, so the
    /// agent title may be adopted).
    var titleIsUserSet: Bool?
    var revision: Int64? = nil
    /// Clearing this mute does not override a muted parent agent.
    var notificationsMuted: Bool? = nil
    /// Native activity travels with workspace metadata, including conversations
    /// that have never been opened or run from this phone.
    var updatedAt: String? = nil
    var syncId: String? = nil
    var botId: String? = nil

    var lastActivityAt: String { max(createdAt, updatedAt ?? createdAt) }
}
