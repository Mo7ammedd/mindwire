import SwiftUI

/// A workspace as its OWN page (pushed from the Workspaces tab or an agent). Resources, ports,
/// files, the terminal, and the agents attached to it live here. Built from the workspace's
/// `runtime` (not an agent), it reads a WorkspaceCapabilities descriptor — never branches on
/// runtime — and shows only the panels the backend declares it supports. Modals
/// (terminal/files) are presented from this page level (not from inside a parent list),
/// which is why they open/close cleanly.
struct WorkspaceDetailScreen: View {
    let workspaceId: String
    var repository: WorkspaceRepository = .shared
    var releaseCatalog: ReleaseCatalog = .shared

    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: WorkspaceModel?
    @State private var selectedTab: WorkspaceDetailTab = .overview
    @State private var showTerminal = false
    @State private var showDesktop = false
    @State private var showFiles = false
    @State private var showChats = false
    @State private var showNewAgent = false
    @State private var showBackups = false
    @State private var showServiceDetails = false
    @State private var desktopTool: ProjectTool?
    @State private var visitedDesktopTools: Set<ProjectTool> = []
    @State private var actions = WorkspaceActionState()
    @State private var isVisible = false
    @State private var modelTask: Task<Void, Never>?

    private var workspace: Workspace? { repository.get(workspaceId) }
    private var computerConnection: Connection? {
        guard let workspace, workspace.runtime.sandbox == nil,
              let id = workspace.runtime.serverId, let connection = stores.connections.get(id),
              connection.pairedComputer != nil else { return nil }
        return connection
    }

    var body: some View {
        let _ = stores.workspaceData.revision
        let agents = repository.agents(workspaceId: workspaceId)
        ZStack {
            if workspace != nil {
                if ApplePlatform.isDesktop {
                    desktopWorkspace(agents: agents)
                } else {
                    List { workspaceSections(agents: agents) }.readablePane()
                }
            } else {
                WorkspaceUnavailableView(workspaceId: workspaceId, repository: repository)
            }
        }
        .serviceUpdatePresentation(repository: repository)
        .navigationTitle(workspace?.name ?? t("workspace.tab"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaBar(edge: .top) {
            if !ApplePlatform.isDesktop, workspace != nil {
                Picker("Workspace section", selection: $selectedTab) {
                    ForEach(WorkspaceDetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: AdaptiveLayout.readableWidth)
                .padding(.horizontal).padding(.bottom, Spacing.xs)
            }
        }
        .toolbar(ApplePlatform.isDesktop ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if !ApplePlatform.isDesktop, let workspace {
                AppToolbarItem(placement: .topBarTrailing) {
                    AppMenu {
                        WorkspaceMenuActions(workspace: workspace, actions: actions)
                    } label: {
                        AppIcon(Icon.ellipsis).foregroundStyle(.primary)
                    }
                    .disabled(actions.deleting)
                }
            }
        }
        .onAppear { isVisible = true; ensureModel() }
        .onDisappear {
            isVisible = false
            if ApplePlatform.isDesktop { app.desktopHasUnsavedFileEdits = false }
        }
        .task { await repository.refreshIfNeeded(); ensureModel() }
        .observeWorkspaceCache(ensureModel)
        .refreshable {
            async let release = stores.serviceUpdates.refreshRelease(force: true)
            await repository.refresh()
            ensureModel()
            if let workspace { await stores.workspaceData.refresh(workspace) }
            await model?.load(force: true)
            if let controls = model?.management { await controls.refresh(.settings, force: true) }
            _ = await release
        }
        .onChange(of: repository.revision) { ensureModel() }
        .onChange(of: repository.requiresSignIn) { ensureModel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isVisible { Task { await repository.refreshIfNeeded(); ensureModel() } }
        }
        .observeChatActivity(agentIds: workspace == nil ? [] : stores.agents(forWorkspaceId: workspaceId).map(\.id))
        .fullScreenCover(isPresented: $showDesktop) {
            if workspace?.isCloud == true {
                DesktopSessionsScreen(workspaceId: workspaceId, repository: repository)
            } else {
                DesktopScreen(workspaceId: workspaceId, repository: repository)
            }
        }
        .fullScreenCover(isPresented: $showTerminal) {
            TerminalScreen(title: workspace?.name ?? t("workspace.terminal.title")) {
                TerminalSessionFactory.provider(for: repository.get(workspaceId), stores: stores)
            }
        }
        .sheet(isPresented: $showServiceDetails) {
            if let workspace { ServiceUpdateInfoSheet(workspace: workspace) }
        }
        .sheet(isPresented: $showFiles) {
            if let model { FilesSheet(workspace: model.workspace, basePath: "/", startPath: "~") }
        }
        .sheet(isPresented: $showChats) {
            ChatHistorySheet(workspaceId: workspaceId)
        }
        .onChange(of: DaemonWorkCoordinator.shared.states[.init(workspaceId: workspaceId)]?.reachable) { _, reachable in
            // Background transport recovery must replace an old offline view.
            if reachable == true, model?.available == false {
                Task { await model?.load(force: true) }
            }
        }
        .sheet(isPresented: $showNewAgent) {
            NewAgentScreen(workspaceId: workspaceId, releaseCatalog: releaseCatalog)
        }
        .sheet(isPresented: $showBackups) {
            if let controls = model?.management {
                NavigationStack {
                    WorkspaceArchivesScreen(model: controls)
                        .toolbar { AppToolbarItem(placement: .cancellationAction) { Button("Done") { showBackups = false }.tint(.primary) } }
                }
            }
        }
        .workspaceActionPresentation(actions, repository: repository, onDeleted: {
            if ApplePlatform.isDesktop { app.showComputers() } else { dismiss() }
        },
            onBackup: model?.management?.features.contains(.archives) == true ? { showBackups = true } : nil)
    }

    @ViewBuilder private func workspaceSections(agents: [Agent]) -> some View {

                    if selectedTab == .overview {
                    if let model, model.available { overviewSummary(model) }
                    if let model, let preparation = model.status?.provisioning, preparation.isPending || preparation.isFailed {
                        Section {
                            if preparation.isPending {
                                ProgressView("Creating Workspace")
                                if let stage = preparation.stage ?? preparation.phase {
                                    Text(WorkspaceControlFormat.status(stage)).font(.footnote).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Workspace setup needs attention").font(.headline)
                                Text(preparation.error ?? "Oblien could not finish preparing this workspace.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Button("Retry Creation") {
                                    Task {
                                        if await model.management?.execute(.retryCreation, title: "Retrying creation…", refresh: [.settings]) != nil {
                                            stores.preparation.enqueue(workspaceId: workspaceId)
                                        }
                                    }
                                }.tint(.primary).disabled(model.management?.isBusy == true)
                            }
                        }
                        if preparation.isFailed, let controls = model.management { WorkspaceControlFeedback(model: controls) }
                    } else if let workspace {
                        WorkspaceDaemonSection(workspace: workspace)
                    }
                    if agents.isEmpty {
                        WorkspaceFirstAgentSection(workspaceId: workspaceId, releaseCatalog: releaseCatalog) {
                            showNewAgent = true
                        }
                    }
                    if let error = stores.workspaceData.errors[workspaceId],
                       DaemonWorkCoordinator.shared.states[.init(workspaceId: workspaceId)]?.canCreateProjects == true {
                        Section(t("workspace.sync.title")) {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                            Button(t("workspace.sync.retry")) {
                                if let workspace { Task { await stores.workspaceData.refresh(workspace) } }
                            }
                        }
                    }
                    if let model {
                        if model.status?.provisioning?.isPending != true, model.status?.provisioning?.isFailed != true { content(model) }
                    } else { loadingSection }
                    projectsSection
                    if !agents.isEmpty { agentsSection }
                    } else if let workspace, let model {
                        WorkspaceManageLinks(workspace: workspace, model: model, repository: repository,
                                             openDesktop: { showDesktop = true }, openFiles: { showFiles = true },
                                             openTerminal: { showTerminal = true }, onDelete: { actions.remove(workspace) })
                    }
                    }

    private func desktopWorkspace(agents: [Agent]) -> some View {
        VStack(spacing: 0) {
            if let workspace {
                DesktopWorkspaceHeader(title: workspace.runtime.isLocal ? "This Mac" : workspace.name,
                                       subtitle: workspace.runtime.isLocal ? "Local workspace" : workspace.isCloud ? "Mindwire Cloud" : "Remote computer",
                                       icon: workspace.runtime.isLocal ? .laptop : workspace.isCloud ? .cloud : .server) {
                    if workspace.runtime.isLocal {
                        DesktopConnectPhoneButton().buttonStyle(DesktopActionButtonStyle())
                    }
                    AppMenu { WorkspaceMenuActions(workspace: workspace, actions: actions) } label: {
                        AppIcon(Icon.ellipsis, size: 18).frame(width: 32, height: 32)
                    }.disabled(actions.deleting)
                }
            }
            HStack(spacing: 6) {
                DesktopWorkspaceTab(title: "Overview", icon: .laptop, selected: desktopTool == nil && selectedTab == .overview) {
                    DesktopWorkspaceFocus.leaveTool()
                    desktopTool = nil; selectedTab = .overview; app.showDesktopTool(nil)
                }
                if let model, model.available {
                    if model.caps.files { desktopToolTab(.files) }
                    if model.caps.terminal { desktopToolTab(.terminal) }
                }
                Spacer()
                DesktopWorkspaceTab(title: "Manage", icon: .sliders, selected: desktopTool == nil && selectedTab == .manage) {
                    DesktopWorkspaceFocus.leaveTool()
                    desktopTool = nil; selectedTab = .manage; app.showDesktopTool(nil)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(AssistantDesktopStyle.separator).frame(height: 0.5) }
            ZStack {
                desktopOverviewNavigation(agents: agents)
                    .opacity(desktopTool == nil ? 1 : 0)
                    .disabled(desktopTool != nil)
                    .allowsHitTesting(desktopTool == nil).accessibilityHidden(desktopTool != nil)
                ForEach(ProjectTool.allCases.filter { visitedDesktopTools.contains($0) }) { tool in
                    Group {
                        if tool == .files, let model {
                            FilesSheet(workspace: model.workspace, basePath: "/", startPath: "~", embedded: true,
                                       onDirtyChange: { app.desktopHasUnsavedFileEdits = $0 })
                        } else if tool == .terminal {
                            TerminalScreen(title: workspace?.name ?? "Terminal", embedded: true) {
                                TerminalSessionFactory.provider(for: repository.get(workspaceId), stores: stores)
                            }
                        }
                    }
                    .opacity(desktopTool == tool ? 1 : 0)
                    .disabled(desktopTool != tool)
                    .allowsHitTesting(desktopTool == tool).accessibilityHidden(desktopTool != tool)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AssistantDesktopStyle.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .font(.system(size: 13)).controlSize(.small)
        .onAppear {
            if app.desktopWorkspaceID != workspaceId { app.openWorkspace(workspaceId) }
        }
    }

    private func desktopOverviewNavigation(agents: [Agent]) -> some View {
        @Bindable var app = app
        return NavigationStack(path: $app.workspacesPath) {
            Group {
                    if selectedTab == .overview, let model, model.available,
                       model.status?.provisioning?.isPending != true, model.status?.provisioning?.isFailed != true {
                        desktopOverview(model, agents: agents)
                    } else {
                        Form { workspaceSections(agents: agents) }
                            .formStyle(.grouped).scrollContentBackground(.hidden)
                            .environment(\.defaultMinListRowHeight, 32)
                            .contentMargins(.top, 16, for: .scrollContent)
                            .frame(maxWidth: 860).frame(maxWidth: .infinity)
                    }

            }
            .withAppRoutes(repository: repository)
            .toolbar(app.workspacesPath.isEmpty ? .hidden : .visible, for: .navigationBar)
        }
    }

    private func desktopToolTab(_ tool: ProjectTool) -> some View {
        DesktopWorkspaceTab(title: tool == .terminal ? "Terminal" : tool.title, icon: tool.icon, selected: desktopTool == tool) {
            DesktopWorkspaceFocus.leaveTool()
            visitedDesktopTools.insert(tool); desktopTool = tool; app.showDesktopTool(tool)
        }
        .accessibilityIdentifier("desktop.computer.tab.\(tool.rawValue)")
    }

    private func desktopOverview(_ model: WorkspaceModel, agents: [Agent]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DesktopWorkspaceCard {
                    HStack {
                        Label(WorkspaceControlFormat.status(model.status?.detail ?? model.status?.power.rawValue), systemImage: "circle.fill")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button { showServiceDetails = true } label: {
                            WorkspaceDaemonStatusLabel(workspaceId: workspaceId, showsLatestVersion: true)
                        }.buttonStyle(.plain).help(t("workspace.daemon.title"))
                    }
                    if let resources = model.resources {
                        Divider()
                        HStack(spacing: 28) {
                            desktopResource("CPU", value: "\(resources.cpus) cores")
                            desktopResource("Memory", value: WorkspaceControlFormat.capacity(resources.memoryMb))
                            desktopResource("Storage", value: WorkspaceControlFormat.capacity(resources.diskMb))
                        }.padding(.vertical, 6)
                    }
                    if let error = stores.workspaceData.errors[workspaceId] {
                        Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                        Button(t("workspace.sync.retry")) {
                            if let workspace { Task { await stores.workspaceData.refresh(workspace) } }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Base connections").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add connection") { showNewAgent = true }.buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(Palette.accent)
                    }
                    DesktopWorkspaceCard {
                        ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                            if index > 0 { Divider() }
                            NavigationLink(value: AppRoute.agentDetail(agentId: agent.id)) {
                                HStack(spacing: 12) {
                                    AgentLogo(id: agent.agentType, size: 24)
                                    Text(agent.displayName).font(.system(size: 13))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                                }.padding(.vertical, 4).contentShape(.rect)
                            }.buttonStyle(.plain)
                        }
                        if agents.isEmpty { Text("Connect a subscription to start creating agents.").foregroundStyle(.secondary) }
                    }
                }
                HStack(spacing: 12) {
                    Button { app.selectDesktopSection(.projects) } label: {
                        Label("\(stores.developerProjects(workspaceId: workspaceId).count) projects", icon: .folder)
                    }
                    Button { showChats = true } label: { Label(t("agentDetail.chats"), icon: Icon.history) }
                }.buttonStyle(.bordered).controlSize(.regular)
            }
            .frame(maxWidth: 860, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }
    }

    private func desktopResource(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Overview only shows the cached count. Project rows are rendered after opening the list.
    private var projectsSection: some View {
        let entries = ProjectListEntry.merge(projects: stores.developerProjects(workspaceId: workspaceId),
            operations: [workspaceId: stores.workspaceData.projectOperations[workspaceId] ?? []])
        return Section {
            Button { showChats = true } label: {
                HStack {
                    Label(t("agentDetail.chats"), icon: Icon.history)
                    Spacer()
                    Text(t("chat.all.folders")).foregroundStyle(.secondary)
                    AppIcon(Icon.chevron).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)
            .accessibilityIdentifier("workspace.chats")
            NavigationLink(value: AppRoute.workspaceProjects(workspaceId: workspaceId)) {
                LabeledContent {
                    Text(entries.count, format: .number).monospacedDigit()
                } label: {
                    Label(t("workspace.detail.section.projects"), icon: Icon.folder)
                }
            }
            .tint(.primary)
            .accessibilityIdentifier("workspace.projects")
        }
    }

    /// Agents owned by this workspace (shared by all its projects) + a shortcut to create one.
    private var agentsSection: some View {
        let agents = repository.agents(workspaceId: workspaceId)
        return Section("Base agents") {
            ForEach(agents) { agent in
                NavigationLink(value: AppRoute.agentDetail(agentId: agent.id)) {
                    AgentCompactLabel(agent: agent)
                }
                .tint(.primary)
            }
            Button { showNewAgent = true } label: {
                Label("Add base connection", icon: Icon.plus)
            }
            .tint(.primary)
        }
    }

    private func ensureModel() {
        guard isVisible else { return }
        guard let workspace else {
            clearModel()
            showTerminal = false
            showFiles = false
            showNewAgent = false
            return
        }
        let m = repository.model(for: workspace)
        if model !== m {
            // A repaired address replaces the backend. An older load must not
            // block this one or clear its task when it eventually finishes.
            modelTask?.cancel()
            modelTask = nil
            model = m
        }
        guard modelTask == nil else { return }
        modelTask = Task {
            await m.load()
            if model === m { modelTask = nil }
        }
    }

    private func clearModel() {
        modelTask?.cancel()
        modelTask = nil
        model = nil
    }

    @ViewBuilder
    private func content(_ model: WorkspaceModel) -> some View {
        if model.loading {
            loadingSection
        } else if model.available {
            toolsSection(model)
        } else {
            unavailableSection(model)
        }
    }

    /// Files (full modal — lists can be long) and the terminal entry. Source control is NOT here:
    /// git is per-project (needs a `.git` at a specific path), so it lives on the project screen.
    @ViewBuilder
    private func toolsSection(_ model: WorkspaceModel) -> some View {
        if model.caps.files || model.caps.terminal {
            Section {
                if model.caps.files {
                    Button { showFiles = true } label: {
                        HStack {
                            Label(t("workspace.files.title"), icon: Icon.folder)
                            Spacer()
                            AppIcon(Icon.chevron)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }
                if model.caps.terminal {
                    Button { showTerminal = true } label: {
                        Label(t("workspace.terminal.open"), icon: Icon.terminal)
                    }
                    .tint(.primary)
                }
                if let id = workspace?.runtime.serverId, workspace?.runtime.sandbox == nil,
                   let connection = stores.connections.get(id), connection.remote != nil || connection.pairedComputer != nil {
                    NavigationLink {
                        ConnectionPortsScreen(connection: connection)
                    } label: { Label("Port Forwarding", icon: .arrowsLeftRight) }
                }
                if let controls = model.management, controls.features.contains(.desktop) {
                    NavigationLink {
                        WorkspaceDesktopSettingsScreen(model: controls, workspaceModel: model) { showDesktop = true }
                    } label: { Label("Desktop", icon: .monitor) }
                } else if workspace?.isCloud == false, repository.supportsDesktop(workspaceId) {
                    Button { showDesktop = true } label: { Label("Desktop", icon: .monitor) }.tint(.primary)
                }
            }
        }
    }

    private func overviewSummary(_ model: WorkspaceModel) -> some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: Spacing.sm) {
                    if model.status?.power.isTransitioning == true || model.powerAction != nil { ProgressView().controlSize(.small) }
                    Text(WorkspaceControlFormat.status(model.status?.detail ?? model.status?.power.rawValue))
                        .foregroundStyle(.secondary)
                    if model.caps.power {
                        AppMenu {
                            if model.status?.power == .stopped, model.status?.provisioning?.isFailed != true {
                                Button("Start Workspace", icon: .play) { Task { await model.power(.start) } }
                            }
                            Button("Power & Resources", icon: .sliders) { selectedTab = .manage }
                        } label: { AppIcon(.power).tint(.primary) }
                        .disabled(model.powerAction != nil || model.management?.isBusy == true)
                    }
                }
            }
            if let resources = model.resources {
                LabeledContent("Resources", value: "\(resources.cpus) vCPU · \(WorkspaceControlFormat.capacity(resources.memoryMb)) · \(WorkspaceControlFormat.capacity(resources.diskMb))")
                    .font(.subheadline)
            }
        }
    }

    private var loadingSection: some View {
        Section {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func unavailableSection(_ model: WorkspaceModel) -> some View {
        // Prefer the backend's real health reason (e.g. the SSH error, or "transport not
        // implemented"); fall back to a generic message.
        let text: String = {
            if let detail = model.health?.detail, !detail.isEmpty { return detail }
            if model.runtime.isLocal { return "Mindwire on this Mac is unavailable. Try starting it again." }
            if model.runtime.isServer { return t("workspace.unavailable.server") }
            return t("workspace.unavailable.cloud")
        }()
        if let computerConnection {
            Section {
                Label("Computer Offline", icon: .laptop)
                    .foregroundStyle(.secondary)
                Button("Reconnect Computer", icon: .refresh) { actions.recoveringComputer = computerConnection }
                    .tint(.primary)
                    .accessibilityIdentifier("computer-reconnect")
                DestructiveButton("Remove from This iPhone", icon: Icon.trash) {
                    if let workspace { actions.remove(workspace) }
                }
            } header: {
                Text("Computer connection")
            } footer: {
                Text("Mindwire retries while the app is open. If the computer’s address changed, open Reconnect Computer to scan its new code.")
            }
        } else {
            Section {
                Label {
                    Text(text).foregroundStyle(.secondary)
                } icon: {
                    AppIcon(Icon.cloud).foregroundStyle(.secondary)
                }
            }
        }
    }
}
