import Foundation

extension Stores {
    /// The agents available in this project = every agent on the project's workspace (agents are
    /// workspace-owned, so there's no per-project assignment).
    @MainActor func agents(forProjectId id: String) -> [Agent] {
        guard let p = projects.get(id) else { return [] }
        return availableAgents(forWorkspaceId: p.workspaceId)
    }

    /// Projects an agent can work in = the projects on the agent's workspace.
    func projects(forAgentId id: String) -> [Project] {
        guard let workspaceId = agents.get(id)?.workspaceId else { return [] }
        return projects(forWorkspaceId: workspaceId)
            .sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
    }

    func projects(forWorkspaceId id: String) -> [Project] {
        projects.list().filter { $0.workspaceId == id }
    }

    func projectsByRecency() -> [Project] {
        let preferred = defaults.dictionary(forKey: "mindwire:project-replicas:selected") as? [String: String] ?? [:]
        let sorted = projects.list().sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
        let groups = Dictionary(grouping: sorted) { $0.syncId ?? $0.id }
        return groups.values.compactMap { copies in
            guard let first = copies.first else { return nil }
            return copies.first(where: { $0.id == preferred[first.syncId ?? first.id] }) ?? first
        }.sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
    }

    @discardableResult
    func createProject(_ input: CreateProjectInput) -> Project {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = input.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(
            id: newId(),
            name: name.isEmpty ? "Project" : name,
            workspaceId: input.workspaceId,
            path: path.isEmpty ? "~" : path,
            repoUrl: input.repoUrl?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            createdAt: isoNow(),
            lastUsedAt: nil
        )
        projects.save(project)
        return project
    }

    func renameProject(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var p = projects.get(id) else { return }
        p.name = trimmed
        projects.save(p)
    }

    func touchProject(_ id: String) {
        guard var p = projects.get(id) else { return }
        p.lastUsedAt = isoNow()
        if let syncId = p.syncId {
            var preferred = defaults.dictionary(forKey: "mindwire:project-replicas:selected") as? [String: String] ?? [:]
            preferred[syncId] = p.id
            defaults.set(preferred, forKey: "mindwire:project-replicas:selected")
        }
        projects.save(p)
    }

    /// Remove this device's cached project/chat links after authoritative workspace removal.
    @MainActor func forgetProject(_ id: String) {
        deleteChats(forProjectId: id)
        bots.replaceAll(bots.list().filter { $0.projectId != id })
        projects.remove(id)
    }

}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
