import Foundation

/// A list identity, not a new runtime object. Plain chats keep their native profile
/// and nil botId; saved bots keep their own instructions, avatar and history.
enum AgentListIdentity: Identifiable {
    case bot(AssistantBot)
    case plain(Agent)

    var id: String {
        switch self {
        case .bot(let bot): "bot:" + bot.id
        case .plain(let agent): "agent:" + agent.id
        }
    }
    var bot: AssistantBot? { if case .bot(let bot) = self { bot } else { nil } }
    var agent: Agent? { if case .plain(let agent) = self { agent } else { nil } }
    var agentId: String {
        switch self {
        case .bot(let bot): bot.agentId
        case .plain(let agent): agent.id
        }
    }
    var workspaceId: String? { bot?.workspaceId ?? agent?.workspaceId }
    var name: String {
        switch self {
        case .bot(let bot): bot.name
        case .plain(let agent): agent.displayName
        }
    }
    var purpose: String { bot?.purpose ?? t("bots.raw.description") }
    var createdAt: String {
        switch self {
        case .bot(let bot): bot.createdAt
        case .plain(let agent): agent.createdAt
        }
    }
    var archived: Bool { bot?.archived ?? false }
    var isMaster: Bool { bot?.isMaster ?? false }
}

struct AgentListEntry: Identifiable {
    let identity: AgentListIdentity
    let workspace: Workspace
    let latest: Chat?
    let chatIDs: [String]
    var id: String { identity.id }

    /// One pass over cached chats. Only used plain profiles join the list, so an
    /// auto-discovered harness does not become a duplicate of every bot using it.
    static func make(bots: [AssistantBot], agents: [Agent], chats: [Chat], workspaces: [Workspace],
                     preferredAgentId: String?, projectIDs: [String: String], includePlain: Bool) -> [Self] {
        let computers = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var latest: [String: Chat] = [:]
        var chatIDs: [String: [String]] = [:]
        var plainIDs = Set<String>()
        for chat in chats {
            let key = chat.botId.map { "bot:" + $0 } ?? "agent:" + chat.agentId
            if let previous = latest[key] {
                if (chat.lastActivityAt, chat.id) > (previous.lastActivityAt, previous.id) { latest[key] = chat }
            } else { latest[key] = chat }
            chatIDs[key, default: []].append(chat.id)
            if chat.botId == nil { plainIDs.insert(chat.agentId) }
        }
        let connected = bots.filter { computers[$0.workspaceId] != nil }
        var identities = BotPresentation.visibleBots(connected, preferredAgentId: preferredAgentId,
            projectIDs: projectIDs).map(AgentListIdentity.bot)
        if includePlain {
            identities += agents.filter { plainIDs.contains($0.id) }.map(AgentListIdentity.plain)
        }
        return identities.compactMap { identity in
            guard let id = identity.workspaceId, let workspace = computers[id] else { return nil }
            return Self(identity: identity, workspace: workspace, latest: latest[identity.id], chatIDs: chatIDs[identity.id] ?? [])
        }.sorted {
            if $0.identity.isMaster != $1.identity.isMaster { return $0.identity.isMaster }
            let left = $0.latest?.lastActivityAt ?? $0.identity.createdAt
            let right = $1.latest?.lastActivityAt ?? $1.identity.createdAt
            if left != right { return left > right }
            let order = $0.identity.name.localizedStandardCompare($1.identity.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
