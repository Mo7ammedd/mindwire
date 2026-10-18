import Foundation

/// A named bot saved by its computer, shared by General and Developer experiences.
/// The engine profile owns authentication; multiple bots can reuse it.
struct AssistantBot: Codable, Identifiable, Hashable {
    let id: String
    var workspaceId: String
    let agentId: String
    let projectId: String
    var name: String
    var purpose: String
    var instructions: String
    var memory: String
    var knowledge: [AssistantBotKnowledge]
    let isMaster: Bool
    var archived: Bool
    let createdAt: String
    var revision: Int64
    var icon: String? = nil
    var notificationsMuted: Bool? = nil
}

struct AssistantBotKnowledge: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var content: String
}

struct AssistantBotMutation: Codable {
    let bot: AssistantBot
    let snapshot: WorkspaceMetadata
}

struct AssistantBotCreate: Encodable {
    let agentId: String
    let projectId: String
    let name: String
    var id: String? = nil
    var icon: String? = nil
    var purpose: String = ""
    var instructions: String = ""
    var memory: String = ""
    var knowledge: [AssistantBotKnowledge] = []
}

struct AssistantBotEdit: Encodable {
    let expectedRevision: Int64
    var icon: String? = nil
    var name: String? = nil
    var purpose: String? = nil
    var instructions: String? = nil
    var memory: String? = nil
    var knowledge: [AssistantBotKnowledge]? = nil
    var archived: Bool? = nil
    var notificationsMuted: Bool? = nil
}

/// A successful first-party tool result, preserved in the native transcript.
struct AssistantBotToolResult: Decodable, Hashable {
    let operation: String
    let botId: String
    let name: String
    var purpose: String?
    var revision: Int64?
    var archived: Bool?
    var chatId: String?
    var workspaceId: String?
    var icon: String?

    static func parse(_ output: String?) -> Self? {
        guard let output, let data = output.data(using: .utf8), data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func find(_ value: Any, depth: Int) -> Self? {
            guard depth < 6 else { return nil }
            if let object = value as? [String: Any] {
                if let result = object["mindwireBot"], let data = try? JSONSerialization.data(withJSONObject: result),
                   let parsed = try? JSONDecoder().decode(Self.self, from: data) { return parsed }
                for key in ["structuredContent", "content", "result", "output", "text"] {
                    if let nested = object[key], let result = find(nested, depth: depth + 1) { return result }
                }
            } else if let array = value as? [Any] {
                for item in array { if let result = find(item, depth: depth + 1) { return result } }
            } else if let text = value as? String, let data = text.data(using: .utf8),
                      let nested = try? JSONSerialization.jsonObject(with: data) {
                return find(nested, depth: depth + 1)
            }
            return nil
        }
        return find(object, depth: 0)
    }
}

/// One visible Mindwire across the two modes. Other saved masters retain their conversations
/// and backend identity, while every ordinary bot remains visible regardless of its computer.
enum BotPresentation {
    static func visibleBots(_ bots: [AssistantBot], preferredAgentId: String?, projectIDs: [String: String]) -> [AssistantBot] {
        let masters = bots.filter { $0.isMaster && !$0.archived }
        let preferred = masters.first { $0.agentId == preferredAgentId && projectIDs[$0.workspaceId] == $0.projectId }
            ?? masters.first { $0.agentId == preferredAgentId }
            ?? masters.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }.first
        return bots.filter { !$0.isMaster || $0.id == preferred?.id }
    }
}
