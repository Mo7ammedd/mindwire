#if targetEnvironment(macCatalyst)
import Foundation
import Observation

/// This Mac is the runtime by default. Reuse the existing registry, authentication cache,
/// and assistant project; no phone pairing or second local connection implementation.
@MainActor @Observable
final class DesktopAssistantBootstrap {
    private(set) var preparing = true
    private(set) var workspace: Workspace?
    private(set) var bot: AssistantBot?
    private(set) var catalog: [AgentDescriptor] = []
    private(set) var error: String?
    private var running = false

    func prepare(stores: Stores, repository: WorkspaceRepository) async {
        guard !running, bot == nil else { return }
        running = true; preparing = true; error = nil
        defer { running = false; preparing = false }
        await LocalComputer.shared.prepare(stores: stores, repository: repository)
        guard !Task.isCancelled else { return }
        guard let id = LocalComputer.shared.workspaceId, let local = repository.get(id) else {
            error = LocalComputer.shared.error ?? t("assistant.desktop.unavailable")
            return
        }
        workspace = local
        if let failure = LocalComputer.shared.error ?? stores.workspaceData.errors[id] {
            error = failure
            return
        }
        do {
            catalog = (try? await stores.workspaceData.agentCatalog(workspaceId: id).agents) ?? []
            try Task.checkCancellation()
            let saved = stores.experience.assistantAgentID.flatMap(stores.agents.get)
            if let saved, saved.workspaceId == id,
               let projectId = stores.experience.projectIDs[id],
               let project = stores.projects.get(projectId), project.workspaceId == id {
                guard BotEngineSupport.supports(saved.agentType, catalog: catalog),
                      saved.installation != "missing", saved.installation != "repair" else { return }
                // Already configured: opening a window does not probe native logins again.
                try await finish(agent: saved, project: project, stores: stores)
                return
            }
            if let master = stores.bots.list().first(where: { $0.isMaster && !$0.archived && $0.workspaceId == id }),
               let agent = stores.agents.get(master.agentId), let project = stores.projects.get(master.projectId) {
                guard BotEngineSupport.supports(agent.agentType, catalog: catalog),
                      agent.installation != "missing", agent.installation != "repair" else { return }
                try await finish(agent: agent, project: project, stores: stores)
                return
            }
            // First use offers the discovered accounts for confirmation in the shared
            // connection picker. Existing, explicitly chosen accounts still open immediately.
        } catch {
            if !error.isRequestCancellation { self.error = error.localizedDescription }
        }
    }

    func complete(agent: Agent, project: Project, stores: Stores) async {
        guard !running else { return }
        running = true; preparing = true; error = nil
        defer { running = false; preparing = false }
        do { try await finish(agent: agent, project: project, stores: stores) }
        catch { if !error.isRequestCancellation { self.error = error.localizedDescription } }
    }

    private func finish(agent: Agent, project: Project, stores: Stores) async throws {
        guard let workspace, agent.workspaceId == workspace.id, project.workspaceId == workspace.id else {
            throw WorkspaceRegistryError.missing
        }
        let master: AssistantBot
        if let existing = stores.bots.list().first(where: {
            $0.isMaster && !$0.archived && $0.agentId == agent.id && $0.projectId == project.id && !$0.instructions.isEmpty &&
                ($0.skills != nil || !stores.workspaceData.supportsBotSkills(workspaceId: workspace.id))
        }), stores.bots.get(AssistantBotPresets.appBuilderID(projectId: project.id)) != nil { master = existing }
        else { master = try await stores.workspaceData.ensureGeneralBots(agentId: agent.id, projectId: project.id) }
        try Task.checkCancellation()
        stores.experience.use(agent: agent, project: project)
        bot = master
    }

}
#endif
