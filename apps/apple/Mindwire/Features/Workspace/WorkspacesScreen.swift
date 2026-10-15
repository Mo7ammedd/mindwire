import SwiftUI

/// Workspaces tab root — native List with one Section-card per workspace (most-recent
/// first), or an empty hero. Each row pushes the workspace detail; the toolbar + button
/// presents the create wizard.
struct WorkspacesScreen: View {
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sidebarNavigation) private var sidebar
    @Environment(AppModel.self) private var app

    @State private var showNew = false
    @State private var showLogin = false
    @State private var catalog: [WorkspaceImage] = []
    @State private var actions = WorkspaceActionState()
    @State private var newProjectWorkspace: Workspace?
    private var workspaces: [Workspace] { repository.all }

    var body: some View {
        let _ = stores.workspaceData.revision
        list
        .overlay {
            if workspaces.isEmpty {
                if !repository.hasRefreshed {
                    ProgressView(t("workspaces.loading"))
                        .accessibilityIdentifier("workspaces-loading")
                } else if repository.refreshError != nil {
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
        .principalBrand()
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
            }
        }
        .task { await repository.refreshIfNeeded() }
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
        .sheet(isPresented: $showNew) {
            NewWorkspaceScreen { _ in Task { await repository.refresh() } }
        }
        .sheet(item: $newProjectWorkspace) { workspace in
            NewProjectScreen(presetWorkspaceId: workspace.id, repository: repository)
        }
        .workspaceActionPresentation(actions, repository: repository)
        .oblienLoginSheet(isPresented: $showLogin) {
            Task { await repository.refresh() }
        }
    }

    private var list: some View {
        List {
            if !workspaces.isEmpty, repository.requiresSignIn {
                Section {
                    OblienSignInRow(bodyKey: "workspaces.signIn.body") { showLogin = true }
                }
            }
            if !workspaces.isEmpty, repository.refreshError != nil {
                Section {
                    HStack {
                        Label(t("workspaces.refreshFailed"), icon: .wifiOff)
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: Spacing.sm)
                        retryButton
                    }
                }
            }
            // Each workspace is its own card (separate Section), not one unified block.
            ForEach(workspaces) { workspace in
                Section {
                    RootNavigationLink(value: AppRoute.workspaceDetail(id: workspace.id), usesDefaultRowBackground: false) {
                        WorkspaceRow(workspace: workspace, catalog: catalog)
                    }
                    .entityCardRow(selected: sidebar?.selected == .app(.workspaceDetail(id: workspace.id)))
                    .appContextMenu {
                        Button("Open Workspace", icon: Icon.workspace) {
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
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(EntityCardStyle.spacing)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(t("workspaces.empty.title"), icon: Icon.workspace)
        } description: {
            Text(t("workspaces.empty.body"))
        } actions: {
            Button(t("workspaces.empty.cta")) { showNew = true }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(Palette.accent)
            if repository.requiresSignIn {
                Button(t("auth.required.cta")) { showLogin = true }
            }
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
