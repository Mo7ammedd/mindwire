import Foundation

extension Stores {
    func chatCount(agentId: String) -> Int { chats.list().filter { $0.agentId == agentId }.count }

    /// Agents owned by a workspace (every project on that workspace sees them), most-recent first.
    func agents(forWorkspaceId id: String) -> [Agent] {
        agents.list().filter { $0.workspaceId == id }
            .sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
    }

    /// UI inventory. Retain absent profiles for history/sync, but show installed
    /// harnesses and explicit setup requests, including an actionable setup failure.
    @MainActor func isAgentAvailable(_ agent: Agent) -> Bool {
        guard let workspaceId = agent.workspaceId else { return false }
        guard agent.installation == "missing" else { return true }
        let key = DaemonWorkKey(workspaceId: workspaceId, agentType: agent.agentType.rawValue)
        let work = DaemonWorkCoordinator.shared.states[key]
        return preparation.pendingIDs.contains(agent.id) || preparation.active.contains(key)
            || work?.running == true || work?.error != nil
            || ChatActivityStore.shared.isRunning(agentId: agent.id, stores: self)
    }

    @MainActor func availableAgents(forWorkspaceId id: String) -> [Agent] {
        agents(forWorkspaceId: id).filter(isAgentAvailable)
    }

    @discardableResult
    func createAgent(_ input: CreateAgentInput) -> Agent {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = Agent(
            id: newId(),
            name: name.isEmpty ? (input.catalogName ?? input.agentType.rawValue) : name,
            agentType: input.agentType,
            agentTypeName: input.catalogName,
            workspaceId: input.workspaceId,
            createdAt: isoNow(),
            lastUsedAt: nil
        )
        agents.save(agent)
        return agent
    }

    func renameAgent(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var a = agents.get(id) else { return }
        a.name = trimmed
        agents.save(a)
    }

    /// Cascade app-owned chat/profile data. The daemon's native config and credentials are untouched.
    @MainActor func deleteAgent(_ id: String) {
        deleteChats(forAgentId: id)
        bots.replaceAll(bots.list().filter { $0.agentId != id })
        // Remove values written by versions that incorrectly mirrored daemon configuration locally.
        AgentConfigStore.clear(id)
        agents.remove(id)
    }

    func touchAgent(_ id: String) {
        guard var a = agents.get(id) else { return }
        a.lastUsedAt = isoNow()
        agents.save(a)
    }

    func agentsSortedByRecency() -> [Agent] {
        agents.list().sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
    }
}
