import Foundation

enum NotificationScope: Hashable {
    case bot(String)
    case agent(String)
    case chat(String)
}

@MainActor
extension NotificationScope {
    func workspaceID(in stores: Stores) -> String? {
        switch self {
        case .bot(let id): return stores.bots.get(id)?.workspaceId
        case .agent(let id): return stores.agents.get(id)?.workspaceId
        case .chat(let id):
            return stores.chats.get(id).flatMap { stores.agents.get($0.agentId)?.workspaceId }
        }
    }

    func title(in stores: Stores) -> String? {
        switch self {
        case .bot(let id): return stores.bots.get(id)?.name
        case .agent(let id): return stores.agents.get(id)?.displayName
        case .chat(let id): return stores.chats.get(id)?.title
        }
    }

    func savedMute(in stores: Stores) -> Bool? {
        switch self {
        case .bot(let id): return stores.bots.get(id)?.notificationsMuted
        case .agent(let id): return stores.agents.get(id)?.notificationsMuted
        case .chat(let id): return stores.chats.get(id)?.notificationsMuted
        }
    }

    func parent(in stores: Stores) -> NotificationScope? {
        guard case .chat(let id) = self, let chat = stores.chats.get(id) else { return nil }
        if let botID = chat.botId { return .bot(botID) }
        return .agent(chat.agentId)
    }

    func isMuted(in stores: Stores) -> Bool {
        savedMute(in: stores) == true || parent(in: stores)?.savedMute(in: stores) == true
    }
}
