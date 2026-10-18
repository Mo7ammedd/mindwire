import SwiftUI

/// Shared by the Projects tab and workspace detail, including accepted and failed creations.
struct ProjectListRows: View {
    let entries: [ProjectListEntry]
    var showWorkspace = false
    var separateSections = false
    var layout: ProjectLibraryLayout = .list
    var nativeListReordering = true
    var repository: WorkspaceRepository = .shared
    @Binding var selectedOperation: ProjectOperationReference?
    var onMove: ((IndexSet, Int) -> Void)? = nil
    var onMoveToFolder: ((Project) -> Void)? = nil
    @Environment(\.stores) private var stores
    @Environment(\.sidebarNavigation) private var sidebar
    @State private var removal = ProjectRemovalActions()
    @State private var iconProject: Project?
    @State private var activity = ChatActivityStore.shared

    var body: some View {
        let running = runningAgents
        Group {
            if layout == .grid || (onMove != nil && !nativeListReordering) {
                ForEach(entries) { entry in
                    if onMove != nil, entry.project != nil, entry.operation == nil {
                        link(entry, agents: running[entry.projectId] ?? [])
                            .projectLibraryCardReorder(id: entry.id, kind: .project,
                                earlier: neighborMove(entry, direction: -1), later: neighborMove(entry, direction: 1)) {
                                    move($0, to: entry.id)
                                }
                    } else { link(entry, agents: running[entry.projectId] ?? []) }
                }
                .buttonStyle(.plain)
            } else if let onMove {
                ForEach(entries) { entry in
                    link(entry, agents: running[entry.projectId] ?? [])
                        .projectLibraryCardRow()
                        .moveDisabled(entry.project == nil || entry.operation != nil)
                }
                .onMove(perform: onMove)
            } else {
                ForEach(entries) { entry in
                    if separateSections { Section { link(entry, agents: running[entry.projectId] ?? []) } }
                    else { link(entry, agents: running[entry.projectId] ?? []) }
                }
            }
        }
        .projectRemovalAlerts(removal, repository: repository)
        .sheet(item: $iconProject) { ProjectIconSheet(projectId: $0.id, repository: repository) }
    }

    private var runningAgents: [String: [AgentID]] {
        let profiles = Dictionary(stores.agents.list().map { ($0.id, $0.agentType) }, uniquingKeysWith: { _, last in last })
        var result: [String: [AgentID]] = [:]
        for chat in stores.chats.list() where activity.status(chat.id) == .running {
            guard let harness = profiles[chat.agentId], result[chat.projectId]?.contains(harness) != true else { continue }
            result[chat.projectId, default: []].append(harness)
        }
        return result
    }

    @ViewBuilder private func link(_ entry: ProjectListEntry, agents: [AgentID]) -> some View {
        if let reference = entry.reference {
            Button { selectedOperation = reference } label: { row(entry, agents: agents) }
                .tint(.primary)
        } else if let project = entry.project {
            RootNavigationLink(value: AppRoute.projectDetail(id: project.id),
                               usesDefaultRowBackground: onMove == nil && layout == .list) {
                row(entry, agents: agents)
            }
                .accessibilityIdentifier("project.row.\(project.id)")
                .appContextMenu {
                    if let onMoveToFolder {
                        Button { onMoveToFolder(project) } label: {
                            Label(t("projects.folder.move"), icon: .folder)
                        }
                    }
                    if stores.projectLibrary.folderId(for: project) != nil {
                        Button { stores.projectLibrary.move([stores.projects.get(project.id) ?? project], to: nil) } label: {
                            Label(t("projects.folder.removeProject"), icon: .minusCircle)
                        }
                    }
                    if !repository.requiresSignIn(for: project.workspaceId) {
                        Divider()
                        Button { iconProject = project } label: {
                            Label(t("project.icon.change"), icon: .filePicture)
                        }
                        Divider()
                        ProjectRemovalMenuItems(project: project, actions: removal, repository: repository)
                    }
                }
        }
    }

    @ViewBuilder private func row(_ entry: ProjectListEntry, agents: [AgentID]) -> some View {
        let git = entry.project.flatMap { stores.projectPresentation.git(for: $0) }
        let icon = entry.project.flatMap { stores.projectPresentation.icon(for: $0) }
        let requiresSignIn = repository.requiresSignIn(for: entry.workspaceId)
        let workspace = repository.get(entry.workspaceId)
        let checkingWorkspace = workspace == nil && (!repository.hasRefreshed || repository.isRefreshing)
        let connected = !requiresSignIn && DaemonWorkCoordinator.shared.states[.init(workspaceId: entry.workspaceId)]?.reachable == true
            && stores.workspaceData.errors[entry.workspaceId] == nil
        let lastKnown = entry.operation?.isActive == true && !connected
        let label = ProjectLibraryEntryLabel(name: entry.name, layout: layout, selected: isSelected(entry)) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.xs) {
                    if showWorkspace, let workspace {
                        Text(workspace.name)
                    }
                    if let git, git.isRepo, (sidebar == nil || !showWorkspace) && (layout == .list || !showWorkspace) {
                        if showWorkspace && workspace != nil { Text("·").accessibilityHidden(true) }
                        AppIcon(.gitBranch).font(.caption).accessibilityHidden(true)
                        Text(git.branch ?? t("git.detached"))
                    } else if !showWorkspace {
                        Text(t("project.card.folder"))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                // Keep one readable identity when artwork and live status share a narrow card.
                if showWorkspace, let workspace {
                    Text(workspace.name).lineLimit(1)
                } else if let git, git.isRepo {
                    HStack(spacing: Spacing.xs) {
                        AppIcon(.gitBranch).font(.caption).accessibilityHidden(true)
                        Text(git.branch ?? t("git.detached")).lineLimit(1).truncationMode(.middle)
                    }
                } else if !showWorkspace {
                    Text(t("project.card.folder"))
                }
            }
            if requiresSignIn {
                Text(t("auth.required.title")).font(.caption)
            } else if let status = entry.statusLabel {
                Text(lastKnown ? t("project.operation.cached", ["status": status]) : status).font(.caption)
                    .foregroundStyle(entry.operation?.canRetry == true ? Palette.warning : .secondary)
            }
            if !requiresSignIn && workspace == nil && !checkingWorkspace {
                Text(t("workspace.missing.title")).font(.caption)
            }
        } icon: {
            ProjectIconArtwork(image: icon)
        } accessory: {
            if requiresSignIn {
                AppIcon(.userCircle).foregroundStyle(.secondary)
            } else if entry.operation?.isActive == true {
                if let progress = entry.operation?.progress {
                    Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(.secondary)
                }
                if connected { ProgressView().controlSize(.small) }
                else { AppIcon(.clock).foregroundStyle(.secondary) }
            } else if entry.operation?.canRetry == true {
                AppIcon(.alertCircle).foregroundStyle(Palette.warning)
            } else if checkingWorkspace {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(t("workspace.checking"))
            } else {
                VStack(alignment: .trailing, spacing: Spacing.xs) {
                    if !agents.isEmpty {
                        HStack(spacing: Spacing.xs) {
                            ForEach(Array(agents.prefix(2))) {
                                AgentActivityGlyph(agentType: $0, size: 32, isAnimating: connected)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(t(connected ? "project.card.working" : "project.card.lastWorking"))
                        .accessibilityIdentifier("project.activity.\(entry.projectId)")
                    }
                    if let git, git.changedFiles > 0 {
                        if git.additions > 0 || git.deletions > 0 {
                            GitDiffStats(additions: git.additions, deletions: git.deletions)
                                .accessibilityHint(t("project.card.cachedChanges"))
                        } else {
                            Text(t(git.changedFiles == 1 ? "git.changedFile" : "git.changedFiles", ["count": "\(git.changedFiles)"]))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if layout == .list && onMove != nil {
            label.projectLibraryCard(selected: isSelected(entry), showsDisclosure: entry.reference == nil)
        } else {
            label
        }
    }

    private func isSelected(_ entry: ProjectListEntry) -> Bool {
        sidebar?.selected == .app(.projectDetail(id: entry.projectId))
    }

    private func move(_ id: String, to target: String) {
        guard let from = entries.firstIndex(where: { $0.id == id }),
              let to = entries.firstIndex(where: { $0.id == target }), from != to else { return }
        onMove?(IndexSet(integer: from), from < to ? to + 1 : to)
    }

    private func neighborMove(_ entry: ProjectListEntry, direction: Int) -> (() -> Void)? {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), entries.indices.contains(index + direction) else { return nil }
        return { move(entry.id, to: entries[index + direction].id) }
    }
}
