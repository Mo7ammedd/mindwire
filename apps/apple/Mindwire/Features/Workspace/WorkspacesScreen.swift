import SwiftUI

/// Saved hosts without a runtime remain manageable; represented hosts expose controls on their workspace.
struct ComputerInventory {
    let workspaces: [Workspace]
    let connections: [Connection]

    var unassignedConnections: [Connection] {
        let represented = Set(workspaces.compactMap { connection(for: $0)?.id })
        return connections.filter { !represented.contains($0.id) }
    }

    func connection(for workspace: Workspace) -> Connection? {
        if let serverID = workspace.runtime.serverId {
            return connections.first { $0.id == serverID }
        }
        if case .local(let computerID) = workspace.runtime {
            return connections.first { $0.pairedComputer?.computerId == computerID }
        }
        return nil
    }
}

/// Computers tab root. Runtime identity and connection state stay in their existing stores.
struct WorkspacesScreen: View {
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sidebarNavigation) private var sidebar
    @Environment(AppModel.self) private var app

    @State private var showNew = false
    @State private var catalog: [WorkspaceImage] = []
    @State private var actions = WorkspaceActionState()
    @State private var newProjectWorkspace: Workspace?
    @State private var connections: [Connection] = []
    @State private var search = ""
    private var workspaces: [Workspace] { repository.all }
    private var inventory: ComputerInventory { ComputerInventory(workspaces: workspaces, connections: connections) }
    private var unassignedConnections: [Connection] { inventory.unassignedConnections }
    private var isEmpty: Bool { workspaces.isEmpty && unassignedConnections.isEmpty }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matchingWorkspaces: [Workspace] {
        workspaces.filter { query.isEmpty || $0.name.localizedStandardContains(query)
            || $0.computerKind(in: stores).localizedStandardContains(query) }
    }
    private var matchingConnections: [Connection] {
        unassignedConnections.filter { query.isEmpty || $0.name.localizedStandardContains(query)
            || $0.displayAddress.localizedStandardContains(query) }
    }

    var body: some View {
        let _ = stores.workspaceData.revision
        list
        .overlay {
            if !query.isEmpty && matchingWorkspaces.isEmpty && matchingConnections.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if isEmpty {
                if !repository.requiresSignIn, !repository.hasRefreshed {
                    ProgressView(t("workspaces.loading"))
                        .accessibilityIdentifier("workspaces-loading")
                } else if !repository.requiresSignIn, repository.refreshError != nil {
                    ContentUnavailableView {
                        Label(t("workspaces.loadFailed"), icon: .wifiOff)
                    } description: {
                        Text(t("workspaces.retryBody"))
                    } actions: {
                        retryButton.buttonStyle(.borderedProminent)
                    }
                    .accessibilityIdentifier("workspaces-load-failed")
                } else {
                    emptyState
                }
            }
        }
        .navigationTitle(t("tabs.workspaces"))
        .principalBrand(visible: false)
        .searchable(text: $search, prompt: "Search computers")
        .toolbar {
            if !workspaces.isEmpty {
                AppToolbarItem(placement: .topBarLeading) {
                    ServiceUpdatesMenu(workspaces: workspaces)
                }
            }
            AppToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { AppIcon(Icon.plus) }
                    .tint(.primary)
                    .accessibilityLabel(t("workspaces.empty.cta"))
                    .accessibilityIdentifier("computers.add")
            }
        }
        .task { await repository.refreshIfNeeded() }
        .onAppear { connections = stores.connections.list() }
        .onChange(of: stores.connections.revision) { connections = stores.connections.list() }
        .task(id: workspaces.compactMap(\.image)) {
            guard workspaces.contains(where: { $0.runtime.isCloud && $0.image != nil }) else { return }
            catalog = await CloudImages.cached()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await repository.refreshIfNeeded() } }
        }
        .refreshable {
            async let release = stores.serviceUpdates.refreshRelease(force: true)
            await repository.refreshChecks()
            _ = await release
        }
        .serviceUpdatePresentation(repository: repository)
        .sheet(isPresented: $showNew, onDismiss: { Task { await repository.refreshIfNeeded() } }) {
            AddComputerScreen(repository: repository)
        }
        .sheet(item: $newProjectWorkspace) { workspace in
            NewProjectScreen(presetWorkspaceId: workspace.id, repository: repository)
        }
        .workspaceActionPresentation(actions, repository: repository)
    }

    private var list: some View {
        List {
            if !isEmpty, repository.refreshError != nil {
                Section {
                    HStack {
                        Label(t("workspaces.refreshFailed"), icon: .wifiOff)
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: Spacing.sm)
                        retryButton
                    }
                }
            }
            // Keep runtime cards and their existing navigation stable.
            ForEach(matchingWorkspaces) { workspace in
                Section {
                    RootNavigationLink(value: AppRoute.workspaceDetail(id: workspace.id), usesDefaultRowBackground: false) {
                        WorkspaceRow(workspace: workspace, catalog: catalog)
                    }
                    .entityCardRow(selected: sidebar?.selected == .app(.workspaceDetail(id: workspace.id)))
                    .appContextMenu {
                        Button("Open computer", icon: Icon.computer) {
                            let route = AppRoute.workspaceDetail(id: workspace.id)
                            if let sidebar { sidebar.select(.app(route)) }
                            else { app.push(route) }
                        }
                        Button(t("newProject.title"), icon: .plus) { newProjectWorkspace = workspace }
                        Divider()
                        WorkspaceMenuActions(workspace: workspace, actions: actions)
                    }
                    .accessibilityIdentifier("workspace.card.\(workspace.id)")
                }
            }
            ForEach(matchingConnections) { connection in
                Section {
                    RootNavigationLink(value: SettingsRoute.serverDetail(id: connection.id), usesDefaultRowBackground: false) {
                        EntityRow(style: .card) {
                            Text(connection.name)
                        } subtitle: {
                            Text(connection.displayAddress)
                        } icon: {
                            EntityCardIcon { ModeIcon(type: connection.type, size: 28) }
                        }
                    }
                    .entityCardRow(selected: sidebar?.selected == .settings(.serverDetail(id: connection.id)))
                    .accessibilityIdentifier("computer.connection.\(connection.id)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(EntityCardStyle.spacing)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(t("workspaces.empty.title"), icon: Icon.computer)
        } description: {
            Text("Connect a computer or use Mindwire Cloud.")
        } actions: {
            Button(t("workspaces.empty.cta")) { showNew = true }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(Palette.accent)
        }
    }

    private var retryButton: some View {
        Button {
            Task { await repository.refreshChecks() }
        } label: {
            HStack {
                if repository.isRefreshing { ProgressView().controlSize(.small) }
                Text(t("common.retry"))
            }
        }
        .disabled(repository.isRefreshing)
    }

}

/// The desktop sidebar reuses the existing connection manager.
struct ComputerConnectionSheet: View {
    let connection: Connection
    var repository: WorkspaceRepository = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ServerDetailScreen(serverId: connection.id, repository: repository)
                .withAppRoutes(repository: repository, onRouteAppear: { route in
                    if ApplePlatform.isDesktop {
                        switch route {
                        case .workspaceDetail, .projectDetail: dismiss()
                        default: break
                        }
                    }
                })
                .toolbar {
                    AppToolbarItem(placement: .confirmationAction) {
                        Button(t("common.done")) { dismiss() }.tint(.primary)
                    }
                }
        }
        .modifier(ComputerConnectionSheetSize())
    }
}

private struct ComputerConnectionSheetSize: ViewModifier {
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.frame(width: 640, height: 580).font(.system(size: 13)).controlSize(.small)
        #else
        content
        #endif
    }
}
