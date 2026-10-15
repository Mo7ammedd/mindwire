import SwiftUI

/// A project's chats first, followed by labeled tools, location, and repository sections.
/// Agents belong to its workspace.
/// Files, Source Control, and Terminal reuse the workspace services scoped to the project path.
/// Manage menu: rename, remove from projects (keep folder), or delete the folder from the workspace.
struct ProjectDetailScreen: View {
    let projectId: String
    var repository: WorkspaceRepository = .shared

    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var project: Project?
    @State private var workspace: Workspace?
    @State private var workspaceImages: [WorkspaceImage] = []
    @State private var backend: Backend?
    @State private var agents: [Agent] = []
    @State private var chats: [Chat] = []
    @State private var activity = ChatActivityStore.shared

    @State private var renaming = false
    @State private var renameText = ""
    @State private var removal = ProjectRemovalActions()
    @State private var showTerminal = false
    @State private var activeSheet: ProjectSheet?
    @State private var switchedProjectId: String?
    @State private var loaded = false
    @State private var isVisible = false
    @State private var actions = WorkspaceActions()

    /// One sheet driver — multiple `.sheet(isPresented:)` on one view don't reliably coexist.
    private enum ProjectSheet: Int, Identifiable { case newAgent, chats, files, sourceControl, icon, transfer, desktop; var id: Int { rawValue } }

    private var gitChangeCount: Int { project.flatMap { stores.projectPresentation.git(for: $0)?.changedFiles } ?? 0 }
    private var gitCountLoading: Bool {
        stores.projectPresentation.loading.contains(projectId) && project.flatMap { stores.projectPresentation.git(for: $0) } == nil
    }

    var body: some View {
        ZStack {
            if let project, let workspace, !repository.requiresSignIn(for: project.workspaceId) {
                GeometryReader { geometry in
                    if geometry.size.width >= 900 && !typeSize.isAccessibilitySize {
                        HStack(spacing: 0) {
                            List { chatsSection }
                            List {
                                toolsSection
                                locationSection(project, workspace)
                                repositorySection(project)
                            }
                            .frame(width: min(380, geometry.size.width * 0.39))
                        }
                        .background(Color(.systemGroupedBackground))
                    } else {
                        List {
                            chatsSection
                            toolsSection
                            locationSection(project, workspace)
                            repositorySection(project)
                        }
                    }
                }
            } else if let project {
                WorkspaceUnavailableView(workspaceId: project.workspaceId, repository: repository, projectPath: project.path,
                                         removeProject: confirmForget)
            } else if loaded {
                ContentUnavailableView {
                    Label(t("project.missing.title"), icon: .folder)
                } description: {
                    Text(t("project.missing.body"))
                } actions: {
                    Button(t("common.back")) { dismiss() }.buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(project?.name ?? t("tabs.projects"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let project, !repository.requiresSignIn(for: project.workspaceId) {
                AppToolbarItem(placement: .topBarTrailing) { manageMenu }
            }
        }
        .onAppear { isVisible = true; stores.touchProject(projectId); reload() }
        .observeWorkspaceCache(reload)
        .workspaceActionAlerts(actions)
        .projectRemovalAlerts(removal, repository: repository)
        .onChange(of: removal.removedProjectId) { _, id in
            if id == projectId, isVisible { dismiss() }
        }
        .task {
            await repository.refreshIfNeeded(); reload()
            if let project, stores.projectPresentation.git(for: project) == nil {
                await stores.workspaceData.refreshProjectPresentation(workspaceId: project.workspaceId, projectId: projectId)
            }
        }
        .refreshable { await repository.refreshChecks(); reload() }
        .onChange(of: repository.revision) { reload() }
        .onChange(of: repository.requiresSignIn) { reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isVisible { Task { await repository.refreshIfNeeded(); reload() } }
        }
        .observeChatActivity(agentIds: agents.map(\.id))
        .onDisappear { isVisible = false; clearBackend() }
        .disabled(removal.running)
        .inputDialog(
            titleKey: "projectDetail.rename.title",
            isPresented: $renaming,
            text: $renameText,
            placeholder: t("projectDetail.rename.label"),
            confirmKey: "common.save"
        ) {
            actions.run { try await stores.workspaceData.renameProject(projectId, name: renameText); reload() }
        }
        .sheet(item: $activeSheet, onDismiss: {
            reload()
            if let id = switchedProjectId { switchedProjectId = nil; app.replaceTop(.projectDetail(id: id)) }
        }) { sheet in
            switch sheet {
            case .transfer:
                ProjectSyncSheet(projectId: projectId, repository: repository) { id in
                    switchedProjectId = id; activeSheet = nil
                }
            case .icon:
                ProjectIconSheet(projectId: projectId, repository: repository)
            case .newAgent:
                if let project { NewAgentScreen(workspaceId: project.workspaceId) }
            case .chats:
                ChatHistorySheet(projectId: projectId)
            case .desktop:
                if let project { ProjectToolDestination(tool: .desktop, project: project, repository: repository) }
            case .sourceControl:
                if let project {
                    ProjectToolDestination(tool: .sourceControl, project: project, repository: repository)
                }
            case .files:
                if let project {
                    ProjectToolDestination(tool: .files, project: project, files: backend?.workspace,
                                           repository: repository)
                }
            }
        }
        .fullScreenCover(isPresented: $showTerminal) {
            if let project {
                ProjectToolDestination(tool: .terminal, project: project, repository: repository)
            }
        }
    }

    private func confirmForget() {
        if let project { removal.confirm(project, repository: repository) }
    }

    private var manageMenu: some View {
        AppMenu {
            Button { renameText = project?.name ?? ""; renaming = true } label: {
                Label(t("common.rename"), icon: Icon.edit)
            }
            Button { activeSheet = .icon } label: {
                Label(t("project.icon.change"), icon: .filePicture)
            }
            Button { activeSheet = .transfer } label: {
                Label(t("project.transfer.title"), icon: .arrowsLeftRight)
            }
            .accessibilityIdentifier("project.transfer.menu")
            if let project {
                ProjectRemovalMenuItems(project: project, actions: removal, repository: repository)
            }
        } label: {
            if removal.running { ProgressView() }
            else { AppIcon(Icon.ellipsis).foregroundStyle(.primary) }
        }
        .disabled(removal.running)
    }

    // MARK: Sections

    private func locationSection(_ project: Project, _ workspace: Workspace) -> some View {
        Section(t("project.section.location")) {
            // Tap the workspace to jump to it (pushed within the Projects stack).
            NavigationLink(value: AppRoute.workspaceDetail(id: project.workspaceId)) {
                LabeledContent {
                    Text(workspace.name)
                } label: {
                    Label {
                        Text(t("project.workspace"))
                    } icon: {
                        WorkspaceImageIcon(image: workspace.image, catalog: workspaceImages, size: 22)
                            .accessibilityHidden(true)
                    }
                }
            }
            .tint(.primary)
            .task(id: workspace.image) {
                guard workspace.runtime.isCloud, workspace.image != nil else { return }
                workspaceImages = await CloudImages.cached()
            }
            LabeledContent(t("project.path"), value: project.path)
            if let transfer = stores.projectSync.transfer(for: project), transfer.active || transfer.canResume {
                Button { activeSheet = .transfer } label: {
                    Label(t("project.transfer.title"), icon: transfer.active ? .refresh : .alertCircle)
                }
            }
        }
    }

    private func repositorySection(_ project: Project) -> some View {
        Section(t("project.section.repository")) {
            if let repo = project.repoUrl, !repo.isEmpty {
                Button {
                    if let url = repoWebURL(repo) { openURL(url) }
                } label: {
                    HStack {
                        Text(t("projectDetail.section.repo")).foregroundStyle(.primary)
                        Spacer()
                        Text(repoDisplay(repo)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        AppIcon(.arrowUpRight).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .tint(.primary)
            }
            NavigationLink {
                GitAccessSettingsScreen(workspaceId: project.workspaceId, projectId: project.id)
            } label: { Label(t("github.access.title"), icon: .key) }
        }
    }

    /// Browser URL for the repo (normalizes a `git@…` clone URL to https, drops `.git`).
    private func repoWebURL(_ repo: String) -> URL? {
        var s = repo
        if s.hasPrefix("git@") {
            s = s.replacingOccurrences(of: "git@", with: "https://").replacingOccurrences(of: "github.com:", with: "github.com/")
        }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        return URL(string: s)
    }

    /// Clean repo label — no scheme, no `.git` (e.g. `github.com/owner/repo`).
    private func repoDisplay(_ repo: String) -> String {
        var s = repo
        for prefix in ["https://", "http://", "git@"] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        return s.replacingOccurrences(of: "github.com:", with: "github.com/")
    }

    private var toolsSection: some View {
        Section(t("project.section.tools")) {
            ForEach(ProjectTool.available(workspaceId: project?.workspaceId ?? "", repository: repository)) { tool in
                ProjectToolButton(tool: tool, badge: tool == .sourceControl ? gitChangeCount : 0,
                                  loading: tool == .sourceControl && gitCountLoading) {
                    switch tool {
                    case .sourceControl: activeSheet = .sourceControl
                    case .files: activeSheet = .files
                    case .terminal: showTerminal = true
                    case .desktop: activeSheet = .desktop
                    }
                }
            }
        }
    }

    private static let inlineChatLimit = 3

    /// Recent chats across the workspace's agents, with access to the full project history.
    @ViewBuilder
    private var chatsSection: some View {
        Section {
            newChatAction
            ForEach(activity.ordered(chats, limit: Self.inlineChatLimit)) { chat in
                ChatListRow(chat: chat, subtitle: agentName(chat.agentId), onChanged: reload)
            }
            if chats.count > Self.inlineChatLimit {
                Button { activeSheet = .chats } label: {
                    Label(t("agentDetail.viewAllChats"), icon: Icon.ellipsis)
                }
                .tint(.primary)
            }
        } header: {
            Text(t("agentDetail.chats"))
        } footer: {
            if let workspace, let issue = stores.workspaceData.sessionDiscoveryIssues[workspace.id]?.first(where: { $0.projectId == projectId }) {
                Text(issue.message)
            } else if chats.isEmpty { Text(t("agentDetail.noChats")) }
        }
    }

    private func agentName(_ id: String) -> String {
        stores.agents.get(id)?.displayName ?? t("projectDetail.section.agents")
    }

    // MARK: New chat (needs an agent — the chat runs as that agent in this project)

    private var newChatAction: some View {
        Group {
            if agents.count > 1 {
                AppMenu {
                    Section(t("projectDetail.section.agents")) {
                        ForEach(agents) { agent in
                            Button(agent.displayName) { openNewChat(agentId: agent.id) }
                        }
                    }
                } label: {
                    Label(t("agentDetail.newChat"), icon: Icon.plus)
                }
            } else {
                Button {
                    guard project.flatMap({ repository.get($0.workspaceId) }) != nil else { reload(); return }
                    if let agent = agents.first { openNewChat(agentId: agent.id) }
                    else { activeSheet = .newAgent }
                } label: {
                    Label(t("agentDetail.newChat"), icon: Icon.plus)
                }
            }
        }
        .tint(.primary)
        .disabled(actions.running)
    }

    private func openNewChat(agentId: String) {
        guard project.flatMap({ repository.get($0.workspaceId) }) != nil else { reload(); return }
        actions.run {
            let chat = try await stores.workspaceData.createChat(agentId: agentId, projectId: projectId)
            reload()
            app.push(.chat(chatId: chat.id))
        }
    }

    // MARK: Data

    private func reload() {
        guard isVisible else { return }
        project = stores.projects.get(projectId)
        loaded = true
        let current = project.flatMap { repository.get($0.workspaceId) }
        if current?.id != workspace?.id || current?.runtime != workspace?.runtime { clearBackend() }
        workspace = current
        guard let project, let workspace else {
            clearBackend()
            agents = []
            chats = []
            activeSheet = nil
            showTerminal = false
            return
        }
        agents = stores.agents(forProjectId: projectId)
        chats = stores.chats(forProjectId: projectId)
        if backend == nil { backend = BackendFactory.make(forRuntime: workspace.runtime, stores: stores) }
    }

    private func clearBackend() {
        let previous = backend
        backend = nil
        if let previous { Task { await previous.dispose() } }
    }
}
