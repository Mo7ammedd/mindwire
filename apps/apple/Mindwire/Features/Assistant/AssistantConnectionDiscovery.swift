import Foundation
import Observation

struct AssistantConnection: Identifiable {
    enum Status { case checking, ready, signIn, unavailable }
    let agent: Agent
    var status: Status = .checking
    var id: String { agent.id }
    var name: String { AssistantAIService.connectionName(for: agent.agentType) }
}

/// Uses the daemon's installed-profile discovery and shared authentication cache. It never
/// installs software or starts login/inference just to populate a connection choice.
@MainActor @Observable
final class AssistantConnectionDiscovery {
    private(set) var connections: [AssistantConnection] = []
    private(set) var loading = false
    private(set) var error: String?
    private var workspaceID: String?
    private var botSupportRequired: Bool?
    private var loaded = false
    private var checkedAt: Date?
    private var requestID = UUID()

    var readyAgentIDs: [String] { connections.filter { $0.status == .ready }.map(\.id) }

    func recordReady(_ agent: Agent) {
        guard agent.workspaceId == workspaceID else { return }
        if let index = connections.firstIndex(where: { $0.id == agent.id }) { connections[index].status = .ready }
        else { connections.append(AssistantConnection(agent: agent, status: .ready)) }
    }

    func load(workspace: Workspace, stores: Stores, force: Bool = false,
              catalog providedCatalog: [AgentDescriptor]? = nil, requiresBotSupport: Bool = true) async {
        if workspaceID == workspace.id, botSupportRequired == requiresBotSupport, loaded, !force,
           let checkedAt, Date().timeIntervalSince(checkedAt) < 30 { return }
        let request = UUID()
        requestID = request
        if workspaceID != workspace.id || botSupportRequired != requiresBotSupport { connections = [] }
        workspaceID = workspace.id
        botSupportRequired = requiresBotSupport
        loading = true; loaded = false; error = nil
        defer {
            if requestID == request {
                loading = false; loaded = !Task.isCancelled
                if loaded { checkedAt = Date() }
            }
        }
        if force { await stores.workspaceData.refresh(workspace) }
        else { await stores.workspaceData.refreshIfNeeded(workspace) }
        guard !Task.isCancelled, requestID == request else { return }
        error = stores.workspaceData.errors[workspace.id]
        let catalog: [AgentDescriptor]
        if let providedCatalog { catalog = providedCatalog }
        else { catalog = (try? await stores.workspaceData.agentCatalog(workspaceId: workspace.id).agents) ?? [] }
        guard !Task.isCancelled, requestID == request else { return }
        let preferred = stores.experience.assistantAgentID
        var seen = Set<AgentID>()
        connections = stores.agents(forWorkspaceId: workspace.id)
            .filter { $0.installation != "missing" && $0.installation != "repair"
                && (!requiresBotSupport || BotEngineSupport.supports($0.agentType, catalog: catalog)) }
            .sorted {
                if ($0.id == preferred) != ($1.id == preferred) { return $0.id == preferred }
                return ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
            }
            .filter { seen.insert($0.agentType).inserted }
            .map { AssistantConnection(agent: $0) }
        let candidates = connections
        guard !candidates.isEmpty else { return }

        await withTaskGroup(of: (String, AssistantConnection.Status).self) { group in
            for candidate in candidates {
                group.addTask { @MainActor in
                    (candidate.id, await Self.status(for: candidate.agent, workspace: workspace, stores: stores, force: force))
                }
            }
            defer { group.cancelAll() }
            for await (id, status) in group {
                guard !Task.isCancelled, requestID == request else { return }
                if let index = connections.firstIndex(where: { $0.id == id }) { connections[index].status = status }
            }
        }
    }

    private static func status(for agent: Agent, workspace: Workspace, stores: Stores, force: Bool) async -> AssistantConnection.Status {
        let key = DaemonWorkKey(workspaceId: workspace.id, agentType: agent.agentType.rawValue)
        let coordinator = DaemonWorkCoordinator.shared
        if !force, let state = coordinator.states[key], let status = state.authentication,
           let checked = state.authenticationCheckedAt, Date().timeIntervalSince(checked) < 30 {
            return status.configured ? .ready : .signIn
        }
        let revision = coordinator.authenticationRevision(for: key)
        let status = try? await stores.workspaceData.authenticationStatus(for: agent)
        guard !Task.isCancelled, let status else { return .unavailable }
        if coordinator.authenticationRevision(for: key) == revision { coordinator.recordAuthentication(status, for: key) }
        guard let current = coordinator.states[key]?.authentication else { return .unavailable }
        return current.configured ? .ready : .signIn
    }

}
