import Foundation

enum NotificationScope: Hashable {
    case agent(String)
    case chat(String)
}

@MainActor
extension NotificationScope {
    func workspaceID(in stores: Stores) -> String? {
        switch self {
        case .agent(let id): return stores.agents.get(id)?.workspaceId
        case .chat(let id):
            return stores.chats.get(id).flatMap { stores.agents.get($0.agentId)?.workspaceId }
        }
    }

    func title(in stores: Stores) -> String? {
        switch self {
        case .agent(let id): return stores.agents.get(id)?.displayName
        case .chat(let id): return stores.chats.get(id)?.title
        }
    }

    func savedMute(in stores: Stores) -> Bool? {
        switch self {
        case .agent(let id): return stores.agents.get(id)?.notificationsMuted
        case .chat(let id): return stores.chats.get(id)?.notificationsMuted
        }
    }

    func parentAgent(in stores: Stores) -> Agent? {
        guard case .chat(let id) = self, let chat = stores.chats.get(id) else { return nil }
        return stores.agents.get(chat.agentId)
    }

    func isMuted(in stores: Stores) -> Bool {
        savedMute(in: stores) == true || parentAgent(in: stores)?.notificationsMuted == true
    }
}
