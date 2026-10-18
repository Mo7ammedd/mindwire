import Foundation

/// Both shells use the same registry and composer draft when starting a bot conversation.
enum BotConversationActions {
    @MainActor static func createChat(for bot: AssistantBot, stores: Stores) async throws -> Chat {
        try await stores.workspaceData.createChat(agentId: bot.agentId, projectId: bot.projectId, botId: bot.id)
    }

    /// General has one preferred master, including when the target runs on another computer.
    /// Developer's first use can create a local master before General setup is configured.
    /// The draft stays editable; opening setup never sends an instruction without the user.
    @MainActor static func configurationChat(for bot: AssistantBot, stores: Stores) async throws -> Chat {
        let master: AssistantBot
        let bots = stores.bots.list()
        if let preferred = stores.experience.assistantAgentID.flatMap(stores.agents.get),
           let workspaceId = preferred.workspaceId, WorkspaceRepository.shared.get(workspaceId) != nil,
           let projectId = stores.experience.projectIDs[workspaceId] {
            if let existing = bots.first(where: { $0.isMaster && !$0.archived && $0.agentId == preferred.id && $0.projectId == projectId }) {
                master = existing
            } else {
                master = try await stores.workspaceData.ensureGeneralBots(agentId: preferred.id, projectId: projectId)
            }
        } else if let existing = bots.first(where: { $0.isMaster && !$0.archived && $0.workspaceId == bot.workspaceId }) {
            master = existing
        } else {
            master = try await stores.workspaceData.ensureGeneralBots(agentId: bot.agentId, projectId: bot.projectId)
        }
        var draft = t("bots.create.masterDraft", ["name": bot.name, "id": bot.id])
        if master.workspaceId != bot.workspaceId {
            guard let identity = stores.workspaceData.identity(workspaceId: bot.workspaceId) else {
                throw BackendError.message(t("bots.connections.unknownComputer"))
            }
            draft += "\n\n" + t("bots.create.masterTarget", ["workspaceId": identity,
                "name": WorkspaceRepository.shared.get(bot.workspaceId)?.name ?? bot.workspaceId])
        }
        let chat = try await createChat(for: master, stores: stores)
        stores.chatDrafts.draft(for: chat.id).text = draft
        stores.chatDrafts.persist(chat.id)
        return chat
    }
}

