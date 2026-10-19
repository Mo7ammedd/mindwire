import Foundation

/// A named bot saved by its computer, shared by General and Developer experiences.
/// The engine profile owns authentication; multiple bots can reuse it.
struct AssistantBot: Codable, Identifiable, Hashable {
    let id: String
    var workspaceId: String
    var agentId: String
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
    var skills: [String]? = nil
    var raw: Bool? = nil
    var isRaw: Bool { raw == true }
    var isAppBuilder: Bool { id == AssistantBotPresets.appBuilderID(projectId: projectId) }
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
    var skills: [String]? = nil
    var raw: Bool? = nil
}

struct AssistantBotEdit: Encodable {
    let expectedRevision: Int64
    var agentId: String? = nil
    var icon: String? = nil
    var name: String? = nil
    var purpose: String? = nil
    var instructions: String? = nil
    var memory: String? = nil
    var knowledge: [AssistantBotKnowledge]? = nil
    var archived: Bool? = nil
    var notificationsMuted: Bool? = nil
    var skills: [String]? = nil
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
        MindwireToolResult.decode(Self.self, key: "mindwireBot", output: output)
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
        let builders = bots.filter { $0.isAppBuilder && !$0.archived }
        let builder = builders.first { $0.projectId == preferred?.projectId }
            ?? builders.first { $0.agentId == preferredAgentId }
            ?? builders.sorted { $0.createdAt < $1.createdAt }.first
        return bots.filter { (!$0.isMaster || $0.id == preferred?.id) && (!$0.isAppBuilder || $0.id == builder?.id || $0.archived) }
    }
}


/// Shared bounded decoding for native tool cards across every harness.
enum MindwireToolResult {
    enum Card { case bot(AssistantBotToolResult), app(AppShortcut), publish(AppPublishRequest) }

    static func card(_ output: String?) -> Card? {
        guard let (marker, data) = payload(output, markers: ["mindwirePublish", "mindwireApp", "mindwireBot"]) else { return nil }
        if marker == "mindwirePublish", let value = try? JSONDecoder().decode(AppPublishRequest.self, from: data) { return .publish(value) }
        if marker == "mindwireApp", let value = try? JSONDecoder().decode(AppShortcut.self, from: data) { return .app(value) }
        if marker == "mindwireBot", let value = try? JSONDecoder().decode(AssistantBotToolResult.self, from: data) { return .bot(value) }
        return nil
    }

    static func decode<T: Decodable>(_ type: T.Type, key marker: String, output: String?) -> T? {
        guard let (_, data) = payload(output, markers: [marker]) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func payload(_ output: String?, markers: [String]) -> (String, Data)? {
        guard let output, output.utf8.count <= 1_048_576, let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func find(_ value: Any, depth: Int) -> (String, Data)? {
            guard depth < 6 else { return nil }
            if let object = value as? [String: Any] {
                for marker in markers {
                    if let result = object[marker], let data = try? JSONSerialization.data(withJSONObject: result) { return (marker, data) }
                }
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

extension DaemonToolCall {
    var mindwireCard: MindwireToolResult.Card? {
        guard isError != true,
              action?.mcp?.server == "mindwire_bots" || name?.hasPrefix("mcp__mindwire_bots__") == true
                || action?.shell?.command?.contains("--bot-tool") == true else { return nil }
        return MindwireToolResult.card(output)
    }
}
