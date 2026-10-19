import Foundation

/// Both shells use the same registry and composer draft when starting a bot conversation.
enum BotConversationActions {
    @MainActor static func createChat(for bot: AssistantBot, projectId: String? = nil, title: String = "New chat", stores: Stores) async throws -> Chat {
        let project: Project
        if let requested = projectId ?? bot.projectId.nilIfEmpty, let saved = stores.projects.get(requested) {
            project = saved
        } else {
            guard projectId == nil, let agent = stores.agents.get(bot.agentId) else { throw WorkspaceRegistryError.missing }
            project = try await AssistantContext.prepare(agent: agent, stores: stores)
        }
        guard project.workspaceId == bot.workspaceId else { throw WorkspaceRegistryError.missing }
        return try await stores.workspaceData.createChat(agentId: bot.agentId, projectId: project.id, title: title, botId: bot.id)
    }

    /// General has one preferred master, including when the target runs on another computer.
    /// Developer's first use can create a local master before General setup is configured.
    /// The draft stays editable; opening setup never sends an instruction without the user.
    @MainActor static func configurationChat(for bot: AssistantBot, stores: Stores) async throws -> Chat {
        guard !bot.isRaw else { throw BackendError.message(t("bots.raw.settingsHint")) }
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
            guard let agent = stores.agents.get(bot.agentId) else { throw WorkspaceRegistryError.missing }
            let project = try await AssistantContext.prepare(agent: agent, stores: stores)
            master = try await stores.workspaceData.ensureGeneralBots(agentId: bot.agentId, projectId: project.id)
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

