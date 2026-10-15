/// Keeps the project choice through optional workspace setup. Only cloning has a details
/// page; an existing folder goes straight to the shared folder picker.
struct ProjectStartFlow {
    enum Source: Hashable { case clone, folder }
    enum Step: Hashable { case clone }
    enum Presentation: Equatable { case workspace, folder }
    var path: [Step] = []
    var source: Source = .clone
    private var pendingSource: Source?
    private var workspaceCreated = false

    init(presetSource: Source? = nil) {
        if let presetSource {
            source = presetSource
            if presetSource == .clone { path = [.clone] }
        }
    }

    mutating func choose(_ source: Source, hasWorkspace: Bool) -> Presentation? {
        self.source = source
        if hasWorkspace { return advance(source) }
        pendingSource = source
        workspaceCreated = false
        return .workspace
    }

    mutating func didCreateWorkspace() { workspaceCreated = true }

    @discardableResult
    mutating func workspaceSheetDismissed() -> Presentation? {
        defer { pendingSource = nil; workspaceCreated = false }
        guard workspaceCreated, let pendingSource else { return nil }
        return advance(pendingSource)
    }

    private mutating func advance(_ source: Source) -> Presentation? {
        self.source = source
        if source == .folder { return .folder }
        if path.last != .clone { path.append(.clone) }
        return nil
    }
}

/// Keeps the accepted workspace and operation fixed while the user sets up an agent.
/// Creation reconciles the daemon registry before returning, so this uses its latest agent list.
struct ProjectStartResult {
    let workspaceId: String
    let operation: ProjectOperation

    @MainActor
    func needsAgent(in stores: Stores) -> Bool {
        let latest = current(in: stores)
        return !latest.removesFiles && ["queued", "running", "succeeded"].contains(latest.status)
            && stores.availableAgents(forWorkspaceId: workspaceId).isEmpty
    }

    @MainActor
    func routes(in stores: Stores) -> [AppRoute] {
        let latest = current(in: stores)
        guard latest.status == "succeeded", !latest.removesFiles, let id = latest.projectId,
              let project = stores.projects.get(id),
              project.workspaceId == workspaceId else { return [] }
        return [.projectDetail(id: project.id)]
    }

    /// Folder-scoped creation returns to that folder, including after optional agent setup.
    /// Unscoped creation retains the usual jump to the newly created project.
    @MainActor
    func navigate(in app: AppModel, libraryFolderId: String?) {
        guard libraryFolderId == nil else { return }
        app.showProjects()
        for route in routes(in: app.stores) { app.push(route) }
    }

    @MainActor
    private func current(in stores: Stores) -> ProjectOperation {
        guard let cached = stores.workspaceData.cachedProjectOperation(operation.id, workspaceId: workspaceId),
              cached.sequence >= operation.sequence else { return operation }
        return cached
    }
}
