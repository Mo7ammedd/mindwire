import SwiftUI

private struct ProjectCreationDestination: Identifiable {
    let id = UUID()
    var folderId: String?
}

private struct ProjectLibraryContents {
    let entries: [ProjectListEntry]
    let folders: [ProjectFolder]
    let counts: [String: Int]
    let previews: [String: [UIImage]]
}

/// Project home reads the shared workspace cache; a toolbar indicator opens status details.
struct ProjectsScreen: View {
    var repository: WorkspaceRepository = .shared
    var workspaceId: String? = nil
    var folderId: String? = nil
    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var projects: [Project] = []
    @State private var newProject: ProjectCreationDestination?
    @State private var pendingProject: ProjectCreationDestination?
    @State private var showOptions = false
    @State private var optionsAction: ProjectLibraryAction?
    @State private var showLogin = false
    @State private var selectedOperation: ProjectOperationReference?
    @State private var showWorkspaceStatus = false
    @State private var showLibrarySync = false
    @State private var folderActions = ProjectFolderActions()
    @State private var managingFolder: ProjectFolder?
    @State private var movingProject: Project?

    private var library: ProjectLibrary { stores.projectLibrary }
    private var folder: ProjectFolder? { folderId.flatMap { library.folder($0) } }
    private var showsFolders: Bool { folderId == nil && library.view == .folders }
    private var showsSignIn: Bool { workspaceId == nil && folderId == nil && repository.requiresSignIn }

    /// Sort once per update and count groups in one pass, rather than scanning the inventory
    /// for every folder row. No file, Git, or daemon reads are needed to build this list.
    private var contents: ProjectLibraryContents {
        let operations = stores.workspaceData.projectOperations.filter { workspaceId == nil || $0.key == workspaceId }
        let all = library.sorted(ProjectListEntry.merge(projects: projects, operations: operations))
        var counts: [String: Int] = [:]
        var previews: [String: [UIImage]] = [:]
        var visible: [ProjectListEntry] = []
        for entry in all {
            let parent = library.folderId(for: entry)
            if let parent {
                counts[parent, default: 0] += 1
                if let project = entry.project, previews[parent, default: []].count < 4,
                   let image = stores.projectPresentation.icon(for: project) {
                    previews[parent, default: []].append(image)
                }
            }
            if let folderId {
                if parent == folderId { visible.append(entry) }
            } else if !showsFolders || parent == nil { visible.append(entry) }
        }
        return .init(entries: visible,
                     folders: library.folders.filter { workspaceId == nil || counts[$0.id, default: 0] > 0 },
                     counts: counts, previews: previews)
    }

    var body: some View {
        let status = WorkspaceStatusOverview(repository: repository, stores: stores)
        let contents = contents
        let empty = contents.entries.isEmpty && (!showsFolders || contents.folders.isEmpty)
        GeometryReader { geometry in
            if empty {
                ScrollView {
                    VStack(spacing: Spacing.lg) {
                        Spacer(minLength: Spacing.xl)
                        emptyState
                        Spacer(minLength: Spacing.xl)
                        if showsSignIn { signInFooter.padding(.bottom, Spacing.md) }
                    }
                    .frame(minHeight: geometry.size.height)
                    .padding(.horizontal, Spacing.lg)
                }
                .background(Palette.bg)
            } else if library.layout == .grid || showsFolders {
                cards(contents, minimumHeight: geometry.size.height)
            } else {
                List {
                    if !contents.entries.isEmpty {
                        Section {
                            projectRows(contents)
                        }
                    }
                    if showsSignIn { Section { signInFooter } }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(.compact)
            }
        }
        .navigationTitle(folder?.name ?? t("tabs.projects"))
        .navigationSubtitle(workspaceId.flatMap { repository.get($0)?.name } ?? "")
        .principalBrand(visible: workspaceId == nil && folderId == nil)
        .toolbar {
            if workspaceId == nil, folderId == nil, status.hasIssues {
                AppToolbarItem(placement: .topBarLeading) {
                    WorkspaceStatusButton(overview: status) { showWorkspaceStatus = true }
                }
            }
            AppToolbarItem(placement: .topBarTrailing) {
                Button { showOptions = true } label: { AppIcon(.more) }
                    .tint(.primary)
                    .accessibilityLabel(t("projects.options"))
                    .accessibilityIdentifier("projects.options")
            }
        }
        .onAppear(perform: reload)
        .observeWorkspaceCache(reload)
        .observeChatActivity(agentIds: stores.agents.list().filter { workspaceId == nil || $0.workspaceId == workspaceId }.map(\.id))
        .task {
            // The app lifecycle owns synchronization. Navigation only loads a cold inventory.
            if !repository.hasRefreshed { await repository.refreshIfNeeded() }
            reload()
        }
        .refreshable { await refresh() }
        .onChange(of: repository.revision) { reload() }
        .onChange(of: folder?.id) { _, id in if folderId != nil && id == nil { dismiss() } }
        .sheet(isPresented: $showWorkspaceStatus, onDismiss: reload) {
            WorkspaceStatusSheet(repository: repository)
        }
        .sheet(item: $newProject, onDismiss: reload) { destination in
            NewProjectScreen(presetWorkspaceId: workspaceId, libraryFolderId: destination.folderId, repository: repository)
        }
        .sheet(isPresented: $showOptions, onDismiss: performOptionsAction) {
            ProjectLibraryOptionsSheet(folder: folder) { action in
                guard optionsAction == nil else { return }
                optionsAction = action
                showOptions = false
            }
        }
        .sheet(item: $managingFolder, onDismiss: startPendingProject) { folder in
            ProjectFolderMembersSheet(folderId: folder.id, workspaceId: workspaceId, repository: repository) {
                pendingProject = .init(folderId: folder.id)
                managingFolder = nil
            }
        }
        .sheet(item: $movingProject) { ProjectMoveToFolderSheet(project: $0) }
        .sheet(isPresented: $showLibrarySync) {
            ProjectLibrarySyncSheet(workspaceId: workspaceId, repository: repository)
        }
        .projectFolderPrompts(folderActions) { folder in
            library.setView(.folders)
            if !projects.isEmpty { managingFolder = folder }
        }
        .sheet(item: $selectedOperation, onDismiss: reload) { ProjectOperationScreen(reference: $0, repository: repository) }
        .mindwireSignIn(isPresented: $showLogin) {
            Task { await repository.refresh(); reload() }
        }
    }

    private func projectRows(_ contents: ProjectLibraryContents, nativeListReordering: Bool = true) -> some View {
        ProjectListRows(entries: contents.entries, showWorkspace: workspaceId == nil, layout: library.layout,
                        nativeListReordering: nativeListReordering,
                        repository: repository, selectedOperation: $selectedOperation, onMove: moveProjects,
                        onMoveToFolder: { movingProject = $0 })
    }

    private var signInFooter: some View {
        MindwireSignInRow(bodyKey: "projects.signIn.body") { showLogin = true }
            .padding(16)
            .background(Palette.surface, in: .rect(cornerRadius: 20))
    }

    private func cards(_ contents: ProjectLibraryContents, minimumHeight: CGFloat) -> some View {
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if showsFolders && !contents.folders.isEmpty {
                    cardLayout {
                        ForEach(contents.folders) { folder in
                            folderLink(folder, contents: contents)
                        }
                    }
                }
                if !contents.entries.isEmpty {
                    if showsFolders && !contents.folders.isEmpty {
                        Text(t("projects.folder.none")).font(.subheadline).foregroundStyle(.secondary)
                            .padding(.top, Spacing.sm)
                    }
                    cardLayout { projectRows(contents, nativeListReordering: false) }
                }
                if showsSignIn {
                    Spacer(minLength: 0)
                    signInFooter
                }
            }
            .frame(minHeight: max(0, minimumHeight - Spacing.sm - Spacing.md), alignment: .top)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.md)
        }
        .background(Palette.bg)
        .accessibilityIdentifier(library.layout == .grid ? "projects.grid" : "projects.folders")
    }

    /// Grouped cards share their drag interaction in both layouts. Keeping them in the
    /// scroll view avoids List swallowing a folder's drop after its context menu closes.
    @ViewBuilder private func cardLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if library.layout == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 140), spacing: Spacing.md)],
                      spacing: Spacing.md, content: content)
        } else {
            LazyVStack(spacing: EntityCardStyle.spacing, content: content)
        }
    }

    @ViewBuilder private func folderLink(_ folder: ProjectFolder, contents: ProjectLibraryContents) -> some View {
        NavigationLink(value: AppRoute.projectFolder(id: folder.id, workspaceId: workspaceId)) {
            folderLabel(folder, contents: contents)
        }
        .appContextMenu { folderMenu(folder) }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projectFolder.row.\(folder.id)")
        .projectLibraryCardReorder(id: folder.id, kind: .folder,
            earlier: neighborFolderMove(folder, direction: -1),
            later: neighborFolderMove(folder, direction: 1)) { moveFolder($0, to: folder.id) }
    }

    @ViewBuilder private func folderLabel(_ folder: ProjectFolder, contents: ProjectLibraryContents) -> some View {
        if library.layout == .grid {
            ProjectFolderTile(folder: folder, count: contents.counts[folder.id, default: 0],
                              iconImages: contents.previews[folder.id, default: []])
        } else {
            ProjectFolderLabel(folder: folder, count: contents.counts[folder.id, default: 0],
                               iconImages: contents.previews[folder.id, default: []])
                .projectLibraryCard()
        }
    }

    private func moveProjects(from: IndexSet, to: Int) {
        var entries = contents.entries
        entries.move(fromOffsets: from, toOffset: to)
        withAnimation(.snappy) {
            library.reorderProjects(entries.compactMap(\.project), allProjects: stores.projectsByRecency())
        }
    }

    private func moveFolders(from: IndexSet, to: Int) {
        var folders = contents.folders
        folders.move(fromOffsets: from, toOffset: to)
        withAnimation(.snappy) { library.reorderFolders(folders.map(\.id)) }
    }

    private func moveFolder(_ id: String, to target: String) {
        let folders = contents.folders
        guard let from = folders.firstIndex(where: { $0.id == id }),
              let to = folders.firstIndex(where: { $0.id == target }), from != to else { return }
        moveFolders(from: IndexSet(integer: from), to: from < to ? to + 1 : to)
    }

    private func neighborFolderMove(_ folder: ProjectFolder, direction: Int) -> (() -> Void)? {
        let folders = contents.folders
        guard let index = folders.firstIndex(where: { $0.id == folder.id }), folders.indices.contains(index + direction) else { return nil }
        return { moveFolder(folder.id, to: folders[index + direction].id) }
    }

    private func performOptionsAction() {
        guard let action = optionsAction else { return }
        optionsAction = nil
        switch action {
        case .newProject: newProject = .init(folderId: folderId)
        case .newFolder: folderActions.create()
        case .chooseProjects: managingFolder = folder
        case .renameFolder: if let folder { folderActions.rename(folder) }
        case .deleteFolder: folderActions.deleting = folder
        case .sync: showLibrarySync = true
        }
    }

    @ViewBuilder private func folderMenu(_ folder: ProjectFolder) -> some View {
        Button { managingFolder = folder } label: { Label(t("projects.folder.chooseProjects"), icon: .folderPlus) }
        Button { folderActions.rename(folder) } label: { Label(t("projects.folder.rename"), icon: .edit) }
        Divider()
        DestructiveButton(t("projects.folder.delete"), icon: .trash) { folderActions.deleting = folder }
    }

    private func startPendingProject() {
        guard let destination = pendingProject else { return }
        pendingProject = nil
        guard let id = destination.folderId, library.folder(id) != nil else { return }
        // Wait for the membership sheet to close, retaining the folder selected there.
        // The picker can also open from the library root or another folder's menu.
        newProject = destination
    }

    private var emptyState: some View {
        let isFolder = folder != nil
        let canChoose = isFolder && projects.contains { library.folderId(for: $0) == nil }
        return ProjectLibraryEmptyState(
            title: t(isFolder ? "projects.folder.emptyTitle" : "projects.empty.title"),
            message: t(isFolder ? (canChoose ? "projects.folder.emptyBody" : "projects.folder.createFirst") : "projects.empty.body")
        ) {
            VStack(spacing: Spacing.sm) {
                Button {
                    if canChoose { managingFolder = folder }
                    else { newProject = .init(folderId: folderId) }
                } label: {
                    Text(t(canChoose ? "projects.folder.chooseProjects" : "projects.empty.cta"))
                        .padding(.horizontal, Spacing.md)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier(canChoose ? "projectFolder.chooseProjects" : "projects.newProject")
                if canChoose {
                    Button { newProject = .init(folderId: folderId) } label: {
                        Text(t("projects.empty.cta")).frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("projects.newProject")
                }
            }
        }
    }

    private func refresh() async {
        if let workspaceId, let workspace = repository.get(workspaceId) {
            await stores.workspaceData.refresh(workspace)
        } else if workspaceId == nil {
            await repository.refreshChecks()
        }
        reload()
    }

    private func reload() {
        projects = workspaceId.map { stores.projects(forWorkspaceId: $0) } ?? stores.projectsByRecency()
        library.reconcile(projects: stores.projects.list())
    }
}
