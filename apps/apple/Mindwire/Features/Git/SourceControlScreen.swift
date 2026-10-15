import SwiftUI

private enum GitRepositoryRoute: Hashable { case history }

enum GitReviewMode: String, CaseIterable, Identifiable {
    case files, review
    var id: String { rawValue }
    var title: String { t("git.view.\(rawValue)") }
}

/// Review comes first. Both modes share the same file groups, actions, and daemon-owned status.
struct SourceControlScreen: View {
    let workspaceId: String
    var path: String? = nil

    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var resources = PresentationResources()
    @State private var model: GitModel?
    @State private var mode: GitReviewMode
    @State private var search = ""
    @State private var searching = false
    @State private var stagedExpanded = true
    @AppStorage("mindwire.git.fileLayout") private var fileLayout: GitFileLayout = .list
    @State private var collapsedFolders: [String: Set<String>] = [:]
    @State private var searchCollapsedFolders: [String: Set<String>] = [:]
    @State private var commitMessage = ""
    @State private var showingCommit = false
    @State private var showingBranches = false
    @State private var showingIdentity = false
    @State private var showingTreeSettings = false
    @State private var showingSync = false
    @State private var showingPullRequest = false
    @State private var discardTarget: GitFileChange?
    @State private var workspaceMissing = false
    @State private var navigationPath = NavigationPath()
    @State private var detailPath = NavigationPath()
    @State private var selectedDiff: GitDiffRoute?
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollBreadcrumb = GitScrollBreadcrumb()

    init(workspaceId: String, path: String? = nil, model: GitModel? = nil, mode: GitReviewMode = .files,
         selection: GitDiffRoute? = nil) {
        self.workspaceId = workspaceId
        self.path = path
        _model = State(initialValue: model)
        _mode = State(initialValue: mode)
        _selectedDiff = State(initialValue: selection)
        _preferredColumn = State(initialValue: selection == nil ? .sidebar : .detail)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            repositoryNavigation
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 440)
        } detail: {
            NavigationStack(path: $detailPath) {
                Group {
                    if let model, let selectedDiff {
                        GitDiffScreen(model: model, change: selectedDiff.change, staged: selectedDiff.staged,
                                      commit: selectedDiff.commit, comparison: selectedDiff.comparison,
                                      onReviewFinished: reviewFinished, onOpenChat: { id, draft in
                            detailPath.append(ChatDraftRoute(chatId: id, draft: draft))
                        })
                        .id(selectedDiff.selectionID)
                    } else {
                        ContentUnavailableView("Choose a change", icon: .code,
                                               description: Text("Review a file while keeping your changes in view."))
                            .navigationTitle(t("git.sourceControl"))
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .navigationDestination(for: ChatDraftRoute.self) { route in
                    ChatScreen(chatId: route.chatId, draft: route.draft)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .workspaceToolPresentation()
        .serviceUpdatePresentation()
        .onAppear(perform: ensureModel)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let model { Task { await model.refresh() } }
        }
        .onChange(of: searchQuery) { _, _ in searchCollapsedFolders.removeAll() }
        .sheet(isPresented: $showingTreeSettings) { FileTreeSettingsSheet() }
    }

    private var repositoryNavigation: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let model { content(model) }
                else if workspaceMissing {
                    ContentUnavailableView(t("workspace.missing.title"), icon: .hardDrive,
                                           description: Text(t("workspace.missing.body")))
                } else { ProgressView(t("git.loading")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .navigationTitle(t("git.sourceControl"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.done")) { dismiss() }.tint(.primary)
                }
                if let model, model.isRepo {
                    if model.projectId != nil {
                        AppToolbarItem(placement: .topBarTrailing) {
                            Button { showingSync = true } label: {
                                if model.activeAction?.isRemote == true {
                                    ProgressView().controlSize(.small)
                                } else { AppIcon(.arrowsUpDown) }
                            }
                            .tint(.primary)
                            .accessibilityLabel(t("git.remote.actions"))
                            .accessibilityIdentifier("git.openSync")
                        }
                    }
                    AppToolbarItem(placement: .topBarTrailing) {
                        GitRepositoryActionsMenu(model: model, showingIdentity: $showingIdentity,
                                                 showingTreeSettings: $showingTreeSettings,
                                                 chooseBranch: { showingBranches = true },
                                                 showHistory: { navigationPath.append(GitRepositoryRoute.history) })
                    }
                }
            }
        }
    }

    @ViewBuilder private func content(_ model: GitModel) -> some View {
        Group {
            if model.loading {
                ProgressView(t("git.loading")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.status == nil {
                ContentUnavailableView {
                    Label(t("git.loadFailed"), icon: .warning)
                } description: {
                    if let error = model.error { Text(error) }
                } actions: {
                    Button(t("common.retry")) { Task { await model.load() } }.buttonStyle(.glass)
                }
            } else if !model.isRepo {
                ContentUnavailableView(t("git.notARepo"), icon: Icon.repo,
                                       description: Text(t("git.notARepo.body")))
            } else {
                changesContent(model)
                    .safeAreaBar(edge: .top, spacing: 0) {
                        if fileLayout == .tree {
                            GitRepositoryContextBar(model: model, breadcrumb: scrollBreadcrumb.current,
                                sections: changeSections(model), expanded: $stagedExpanded,
                                showActions: searchQuery.isEmpty,
                                chooseBranch: { showingBranches = true },
                                showHistory: { navigationPath.append(GitRepositoryRoute.history) })
                        }
                    }
                    .toolbar {
                        if !model.isClean {
                            DefaultToolbarItem(kind: .search, placement: .bottomBar)
                            if sizeClass != .regular {
                                ToolbarSpacer(.flexible, placement: .bottomBar)
                                if !searching {
                                    ToolbarItem(placement: .bottomBar) {
                                        stagedCount(model)
                                    }
                                    .sharedBackgroundVisibility(.hidden)
                                    ToolbarSpacer(.flexible, placement: .bottomBar)
                                }
                                ToolbarItem(placement: .bottomBar) {
                                    commitButton(model)
                                }
                            }
                        }
                    }
                    .toolbarBackground(sizeClass == .regular ? .automatic : .visible, for: .bottomBar)
                    .safeAreaBar(edge: .bottom, spacing: 0) {
                        if sizeClass == .regular, !model.isClean {
                            HStack {
                                stagedCount(model)
                                Spacer(minLength: Spacing.md)
                                commitButton(model)
                            }
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.sm)
                        }
                    }
            }
        }
        .navigationDestination(for: GitDiffRoute.self) { route in
            GitDiffScreen(model: model, change: route.change, staged: route.staged, commit: route.commit,
                          comparison: route.comparison, onOpenChat: { chatId, draft in
                navigationPath.append(ChatDraftRoute(chatId: chatId, draft: draft))
            })
        }
        .navigationDestination(for: ChatDraftRoute.self) { route in
            ChatScreen(chatId: route.chatId, draft: route.draft)
        }
        .navigationDestination(for: GitRepositoryRoute.self) { _ in
            GitHistoryScreen(model: model)
        }
        .navigationDestination(for: GitCommit.self) { commit in
            GitCommitScreen(model: model, commit: commit) {
                mode = .files
                navigationPath = NavigationPath()
            }
        }
        .sheet(isPresented: $showingCommit) {
            GitCommitSheet(model: model, message: $commitMessage) { chatId, draft in
                showingCommit = false
                navigationPath.append(ChatDraftRoute(chatId: chatId, draft: draft))
            }
        }
        .sheet(isPresented: $showingBranches) { GitBranchSheet(model: model) }
        .onChange(of: model.isMutating) { _, busy in if !busy { reconcileSelection(model) } }
        .onChange(of: model.revision) { _, _ in if !model.isMutating { reconcileSelection(model) } }
        .sheet(isPresented: $showingSync) { GitSyncSheet(model: model) }
        .sheet(isPresented: $showingPullRequest) { GitPullRequestSheet(model: model) }
        .sheet(isPresented: $showingIdentity) {
            NavigationStack {
                GitAuthorScreen(model: model) { showingIdentity = false }
                    .toolbar {
                        AppToolbarItem(placement: .cancellationAction) {
                            Button(t("common.cancel")) { showingIdentity = false }.tint(.primary)
                                .disabled(model.savingAuthor)
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(model.savingAuthor)
        }
        .alert(t("git.discard.title"), isPresented: Binding(
            get: { discardTarget != nil }, set: { if !$0 { discardTarget = nil } }
        )) {
            Button(t("git.discard"), role: .destructive) {
                if let target = discardTarget { Task { await model.discard([target.path]) } }
                discardTarget = nil
            }
            Button(t("common.cancel"), role: .cancel) { discardTarget = nil }
        } message: { Text(t("git.discard.body", ["name": discardTarget?.name ?? ""])) }
    }

    private func stagedCount(_ model: GitModel) -> some View {
        Text(t("git.stagedCount", ["count": "\(model.staged.count)"]))
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize()
    }

    private func commitButton(_ model: GitModel) -> some View {
        Button { showingCommit = true } label: { Text(t("git.commit")).fixedSize() }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isMutating)
            .accessibilityIdentifier("git.openCommit")
    }

    @ViewBuilder private func changesContent(_ model: GitModel) -> some View {
        if model.isClean {
            changesList(model)
        } else {
            changesList(model)
                .searchable(text: $search, isPresented: $searching, prompt: t("git.search"))
                .searchToolbarBehavior(.minimize)
                .searchPresentationToolbarBehavior(.avoidHidingContent)
        }
    }

    private func changesList(_ model: GitModel) -> some View {
        let isClean = model.isClean
        return List {
            if fileLayout == .tree {
                if !model.isClean || model.canCreatePullRequest {
                    Section {
                        VStack(spacing: Spacing.md) {
                            if !model.isClean {
                                GitRepositoryChangeSummary(model: model)
                                fileControls(model)
                            }
                            if model.canCreatePullRequest {
                                GitPullRequestButton(model: model, spacing: Spacing.sm) { showingPullRequest = true }
                            }
                        }
                        .padding(.vertical, Spacing.sm)
                        .accessibilityIdentifier("git.overview")
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.lg, bottom: 0, trailing: Spacing.lg))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listSectionSeparator(.hidden)
                }
            } else {
                Section {
                    GitRepositorySummary(model: model, chooseBranch: { showingBranches = true },
                                         showHistory: { navigationPath.append(GitRepositoryRoute.history) })
                        .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.lg,
                                                 bottom: Spacing.xs, trailing: Spacing.lg))
                    if model.canCreatePullRequest {
                        GitPullRequestButton(model: model, spacing: Spacing.sm) { showingPullRequest = true }
                    }
                } footer: {
                    if !model.isClean { GitRepositoryChangeSummary(model: model) }
                }
                .listSectionSeparator(.hidden)
                if !model.isClean {
                    Section { fileControls(model) }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listSectionSeparator(.hidden)
                }
            }
            GitOperationSections(model: model)
            if model.identityRequired {
                Section {
                    Button(t("git.identity.title")) { showingIdentity = true }
                } footer: { Text(t("git.identity.required")) }
            }
            if let notice = model.authorNotice {
                Section { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                    .listRowBackground(Color.clear)
            }
            GitAuthorSyncSection(defaults: model.authorDefaults)
            if model.isClean {
                Section {
                    VStack(spacing: Spacing.lg) {
                        GitEmptyState(title: t(model.hasUnpushedCommits ? "git.clean.pushTitle"
                            : model.status?.head == nil ? "git.history.empty" : "git.clean"),
                            message: t(model.hasUnpushedCommits ? "git.clean.pushBody"
                                : model.status?.head == nil ? "git.clean.firstCommit" : "git.clean.body"))
                        if model.hasUnpushedCommits, model.projectId != nil {
                            Button(t("git.remote.push")) { Task { await model.runRemote(.push) } }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(model.isMutating || model.hasPendingOperation)
                                .accessibilityIdentifier("git.clean.push")
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .frame(maxWidth: .infinity, minHeight: max(220, viewportHeight * 0.45))
                    .accessibilityIdentifier("git.cleanState")
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else if filtered(model.allChanges).isEmpty {
                Section {
                    GitEmptyState(title: t("git.search.empty"), message: t("git.search.empty.body"))
                        .padding(.vertical, Spacing.xl)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                changeSection(model, title: t("git.conflicts"), items: model.conflicts, staged: false, bulkAction: false)
                changeSection(model, title: t("git.staged"), items: model.staged, staged: true)
                changeSection(model, title: t("git.changes"), items: model.unstaged, staged: false)
            }
        }
        .modifier(SourceControlListStyle(tree: fileLayout == .tree))
        .listSectionSpacing(fileLayout == .tree ? .custom(Spacing.sm) : .compact)
        .contentMargins(.top, Spacing.sm, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.refresh() }
        // Only the empty state needs this measurement; scrolling never changes list geometry.
        .onGeometryChange(for: CGFloat.self) { isClean ? $0.size.height : 0 } action: { viewportHeight = $0 }
#if DEBUG
        .background {
            if ProcessInfo.processInfo.environment["MINDWIRE_GIT_SCROLL_FIXTURE"] == "1" {
                GitScrollMetricsProbe(tracker: scrollBreadcrumb).frame(width: 1, height: 1)
            }
        }
#endif
    }

    private func fileControls(_ model: GitModel) -> some View {
        HStack(spacing: Spacing.sm) {
            Picker(t("git.view"), selection: $mode) {
                ForEach(GitReviewMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("git.reviewMode")
            layoutMenu(model)
        }
    }

    private func changeSections(_ model: GitModel) -> [GitChangeSectionInfo] {
        [GitChangeSectionInfo(scope: "conflicts", title: t("git.conflicts"),
                              count: filtered(model.conflicts).count, staged: false, bulkAction: false),
         GitChangeSectionInfo(scope: "staged", title: t("git.staged"),
                              count: filtered(model.staged).count, staged: true, bulkAction: true),
         GitChangeSectionInfo(scope: "working", title: t("git.changes"),
                              count: filtered(model.unstaged).count, staged: false, bulkAction: true)]
    }

    @ViewBuilder private func changeSection(_ model: GitModel, title: String, items: [GitFileChange],
                                            staged: Bool, bulkAction: Bool = true) -> some View {
        let visible = filtered(items)
        let scope = staged ? "staged" : bulkAction ? "working" : "conflicts"
        let section = GitChangeSectionInfo(scope: scope, title: title, count: visible.count,
                                           staged: staged, bulkAction: bulkAction)
        if !visible.isEmpty {
            Section {
                if fileLayout == .tree {
                    GitChangeSectionControls(model: model, section: section, expanded: $stagedExpanded,
                                             showActions: searchQuery.isEmpty)
                        .padding(.vertical, Spacing.xs)
                        .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.lg,
                                                 bottom: Spacing.xs, trailing: Spacing.lg))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .background(GitBreadcrumbMarker(tracker: scrollBreadcrumb, scope: scope, header: true))
                }
                // Search reveals matches without changing the user's collapsed state.
                if !staged || stagedExpanded || !searchQuery.isEmpty {
                    if fileLayout == .tree {
                        GitFileTreeRows(model: model, files: visible, staged: staged, scope: scope, review: mode == .review,
                                        collapsed: treeExpansion(scope), selected: selectedDiff,
                                        onOpen: { openDiff(GitDiffRoute(change: $0, staged: staged)) },
                                        onDiscard: { discardTarget = $0 }, breadcrumb: scrollBreadcrumb)
                    } else {
                        ForEach(visible) { change in
                            GitFileRow(model: model, change: change, staged: staged, review: mode == .review,
                                       onDiscard: { discardTarget = change },
                                       onOpen: { openDiff(GitDiffRoute(change: change, staged: staged)) },
                                       isSelected: selectedDiff?.change.path == change.path && selectedDiff?.staged == staged)
                        }
                    }
                }
            } header: {
                if fileLayout != .tree {
                    GitChangeSectionControls(model: model, section: section, expanded: $stagedExpanded,
                                             showActions: searchQuery.isEmpty)
                }
            }
        }
    }

    private var searchQuery: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func treeExpansion(_ scope: String) -> Binding<Set<String>> {
        Binding(get: { (searchQuery.isEmpty ? collapsedFolders : searchCollapsedFolders)[scope] ?? [] }, set: {
            if searchQuery.isEmpty { collapsedFolders[scope] = $0 }
            else { searchCollapsedFolders[scope] = $0 }
        })
    }

    private func layoutMenu(_ model: GitModel) -> some View {
        AppMenu {
            Picker(t("files.viewMode"), selection: $fileLayout) {
                ForEach(GitFileLayout.allCases, id: \.self) { layout in
                    Label(layout.title, icon: layout.icon).tag(layout)
                }
            }
            if fileLayout == .tree {
                Divider()
                Button(t("git.tree.expandAll"), icon: .chevronDown) {
                    if searchQuery.isEmpty { collapsedFolders.removeAll() }
                    else { searchCollapsedFolders.removeAll() }
                }
                Button(t("git.tree.collapseAll"), icon: .chevronRight) {
                    for (scope, files) in [("staged", model.staged), ("working", model.unstaged), ("conflicts", model.conflicts)] {
                        treeExpansion(scope).wrappedValue = GitChangeTree(files: filtered(files)).folders
                    }
                }
                Divider()
                Button(t("files.tree.customize"), icon: .folderTree) { showingTreeSettings = true }
            }
        } label: {
            AppIcon(fileLayout.icon, size: 20).frame(width: 40, height: 36)
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityLabel(t("files.viewOptions"))
        .accessibilityValue(fileLayout.title)
        .accessibilityIdentifier("git.fileLayout")
    }

    private func filtered(_ files: [GitFileChange]) -> [GitFileChange] {
        let query = searchQuery
        return query.isEmpty ? files : files.filter {
            $0.path.localizedStandardContains(query) || $0.origPath?.localizedStandardContains(query) == true
        }
    }

    private func ensureModel() {
        guard model == nil else { return }
        guard let workspace = WorkspaceRepository.shared.get(workspaceId) else { workspaceMissing = true; return }
        let model = GitModel(workspace: workspace, stores: stores, path: path)
        self.model = model
        resources.cleanup = { await model.dispose() }
        Task { await model.load() }
    }

    private func openDiff(_ route: GitDiffRoute) {
        selectedDiff = route
        detailPath = NavigationPath()
        preferredColumn = .detail
    }

    private func reviewFinished() {
        guard let model else { return }
        reconcileSelection(model)
    }

    private func reconcileSelection(_ model: GitModel) {
        guard let selectedDiff, selectedDiff.commit == nil else { return }
        // Stage/unstage moves the file between groups while the editor follows that same file.
        if let current = model.allChanges.first(where: { $0.path == selectedDiff.change.path }) {
            let stillOnSelectedSide = selectedDiff.staged ? current.isStaged
                : current.hasUnstagedChange || current.isUntracked || current.isConflicted
            if !stillOnSelectedSide {
                openDiff(GitDiffRoute(change: current, staged: current.isStaged && !current.hasUnstagedChange))
            }
        } else {
            self.selectedDiff = nil
            preferredColumn = .sidebar
        }
    }
}

private struct SourceControlListStyle: ViewModifier {
    let tree: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if tree {
            content.modifier(FileTreeListStyle())
                .environment(\.defaultMinListHeaderHeight, 0)
                .scrollEdgeEffectStyle(.soft, for: .top)
        }
        else { content.listStyle(.insetGrouped) }
    }
}

/// Observe only menu state here. File-list and diff updates must not reconstruct an
/// open native menu and restart its presentation transitions.
private struct GitRepositoryActionsMenu: View {
    let model: GitModel
    @Binding var showingIdentity: Bool
    @Binding var showingTreeSettings: Bool
    let chooseBranch: () -> Void
    let showHistory: () -> Void

    var body: some View {
        AppMenu {
            Section {
                Button(t("git.branches.title"), icon: Icon.repo, action: chooseBranch)
                Button(t("git.history.title"), icon: Icon.history, action: showHistory)
            }
            Button { Task { await model.refresh() } } label: {
                Label(t("git.refresh"), icon: .refresh)
            }
            .disabled(model.isMutating)
            Button { showingIdentity = true } label: {
                Label(t("git.identity.title"), icon: .userCircle)
            }
            .disabled(model.isMutating)
            Button { showingTreeSettings = true } label: {
                Label(t("files.tree.customize"), icon: .folderTree)
            }
            if let projectId = model.projectId {
                Section {
                    NavigationLink {
                        GitAccessSettingsScreen(workspaceId: model.workspaceId, projectId: projectId)
                    } label: {
                        Label(t("github.access.title"), icon: .key)
                    }
                }
            }
        } label: { AppIcon(.more) }
        .tint(.primary)
        .accessibilityLabel(t("git.repository.actions"))
        .accessibilityIdentifier("git.repository.actions")
    }
}
