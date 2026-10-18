import Foundation

extension Stores {
    func workspacesByRecency() -> [Workspace] {
        workspaces.list().sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
    }

    @discardableResult
    func createWorkspace(name: String, runtime: AgentRuntime, spec: WorkspaceSpec? = nil) -> Workspace {
        if let existing = workspaces.list().first(where: { $0.runtime == runtime && runtime.isServer }) { return existing }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = Workspace(
            id: runtime.sandbox?.id ?? newId(),
            name: trimmed.isEmpty ? defaultWorkspaceName(for: runtime) : trimmed,
            runtime: runtime,
            spec: spec,
            createdAt: isoNow(),
            lastUsedAt: nil,
            image: runtime.sandbox == nil ? nil : "docker"
        )
        workspaces.save(workspace)
        return workspace
    }

    func renameWorkspace(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var s = workspaces.get(id) else { return }
        s.name = trimmed
        workspaces.save(s)
    }

    func touchWorkspace(_ id: String) {
        guard var s = workspaces.get(id) else { return }
        s.lastUsedAt = isoNow()
        workspaces.save(s)
    }

    /// Deleting a workspace removes everything that lives on it — its projects and its agents (each
    /// cascades their chats). Agents are workspace-owned now. Destructive; the UI confirms (and offers
    /// a backup) first.
    @MainActor func deleteWorkspace(_ id: String) {
        cascadeProjects(forWorkspaceId: id)
        workspaces.remove(id)
    }

    /// Remove everything bound to a workspace: its projects (each cascades chats) AND its agents (each
    /// cascades chats + config). Used by `deleteWorkspace` and by `WorkspaceRepository.delete` for cloud
    /// workspaces (whose display snapshot belongs to the cloud adapter).
    @MainActor func cascadeProjects(forWorkspaceId id: String) {
        for p in projects.list() where p.workspaceId == id {
            forgetProject(p.id) // deletes the project's chats; record removed
        }
        for a in agents.list() where a.workspaceId == id {
            deleteAgent(a.id)   // deletes the agent's chats + config; record removed
        }
    }

    /// Drop legacy cloud rows without an account scope. The cloud adapter keeps its display cache
    /// separately, bound to the active session; local/server rows remain authoritative here.
    func purgePersistedCloudWorkspaces() {
        let all = workspaces.list()
        let local = all.filter { $0.runtime.isServer }
        if local.count != all.count { workspaces.replaceAll(local) }
    }

    private func defaultWorkspaceName(for runtime: AgentRuntime) -> String {
        switch runtime {
        case .cloud:
            return "Mindwire Cloud"
        case .server(let serverId), .container(let serverId, _):
            return connections.get(serverId)?.name ?? "Workspace"
        }
    }
}
