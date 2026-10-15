import Foundation

enum AgentStatus: String, Codable, Hashable, CaseIterable {
    case provisioning, ready, running, idle
    case awaitingInput = "awaiting_input"
    case error, archived
}

/// A workspace-owned agent profile (CLI choice + name), cached in UserDefaults `mindwire:agents`.
/// Harness configuration stays on the workspace in native files. `workspaceId` is Optional so legacy agents
/// (created before scoping) still decode. Only profiles whose workspace is in the current
/// account/connection inventory are shown. The running cwd comes from the chat's project.
struct Agent: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var agentType: AgentID
    /// Snapshot of the daemon catalog label for offline rendering; never used as capability data.
    var agentTypeName: String?
    var workspaceId: String?
    let createdAt: String
    var lastUsedAt: String?
    var revision: Int64? = nil
    /// Workspace-owned mute for this profile and all of its chats.
    var notificationsMuted: Bool? = nil
    /// Observed by the daemon, independent of this device's saved setup requests.
    var installation: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, name, agentType, agentTypeName, workspaceId, createdAt, lastUsedAt, revision, notificationsMuted, installation
    }
    private enum LegacyCodingKeys: String, CodingKey { case sandboxId }
}

extension Agent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        agentType = try c.decode(AgentID.self, forKey: .agentType)
        agentTypeName = try c.decodeIfPresent(String.self, forKey: .agentTypeName)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
            ?? legacy.decodeIfPresent(String.self, forKey: .sandboxId)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(String.self, forKey: .lastUsedAt)
        revision = try c.decodeIfPresent(Int64.self, forKey: .revision)
        notificationsMuted = try c.decodeIfPresent(Bool.self, forKey: .notificationsMuted)
        installation = try c.decodeIfPresent(String.self, forKey: .installation)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(agentType, forKey: .agentType)
        try c.encodeIfPresent(agentTypeName, forKey: .agentTypeName)
        try c.encodeIfPresent(workspaceId, forKey: .workspaceId)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try c.encodeIfPresent(revision, forKey: .revision)
        try c.encodeIfPresent(notificationsMuted, forKey: .notificationsMuted)
        try c.encodeIfPresent(installation, forKey: .installation)
    }
}

struct CreateAgentInput {
    var name: String
    var agentType: AgentID
    var workspaceId: String
    var catalogName: String? = nil
}

extension Agent {
    /// `name.trim()` || catalog name || "Agent" — matches `agentName()`.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return agentTypeName ?? agentType.rawValue
    }

    var typeDisplayName: String { agentTypeName ?? agentType.rawValue }
}
