import SwiftUI

/// Each tab is an independent `NavigationStack` bound to its path in `AppModel`. The three content
/// tabs share one set of destinations (`withAppRoutes`) so any entity drills down within the
/// current stack — the bottom tab only changes for deep links / post-creation jumps.

extension View {
    /// Resolve every `AppRoute` to its screen. Applied to each content tab's stack so a pushed
    /// project/workspace/agent opens in-place (back returns naturally; no tab jump).
    @MainActor @ViewBuilder
    func withAppRoutes(hideBackButton: Bool = false, repository: WorkspaceRepository = .shared,
                       sidebarControls: SidebarControls? = nil,
                       onRouteAppear: ((AppRoute) -> Void)? = nil) -> some View {
        navigationDestination(for: AppRoute.self) { route in
            Group {
                switch route {
                case .botDetail(let id): BotDetailScreen(botId: id, repository: repository)
                case .agentDetail(let id): AgentDetailScreen(agentId: id)
                case .agentAuthentication(let id): AgentAuthenticationScreen(agentId: id).readablePane()
                case .chat(let id): AppChatDestination(chatId: id)
                case .workspaceDetail(let id):
                    if ApplePlatform.isDesktop { DesktopWorkspaceRoute(route: route) }
                    else { WorkspaceDetailScreen(workspaceId: id, repository: repository) }
                case .workspaceProjects(let id): ProjectsScreen(repository: repository, workspaceId: id)
                case .projectFolder(let id, let workspaceId):
                    ProjectsScreen(repository: repository, workspaceId: workspaceId, folderId: id)
                case .projectDetail(let id):
                    if ApplePlatform.isDesktop { DesktopWorkspaceRoute(route: route) }
                    else { ProjectDetailScreen(projectId: id, repository: repository) }
                }
            }
            .navigationBarBackButtonHidden(hideBackButton)
            .sidebarToolbar(sidebarControls)
            .onAppear { onRouteAppear?(route) }
        }
        .navigationDestination(for: SettingsRoute.self) { route in
            Group {
                switch route {
                case .account: AccountScreen().readablePane()
                case .backupSync: BackupSyncScreen().readablePane()
                case .notifications: NotificationSettingsScreen().readablePane()
                case .servers: ServersScreen(repository: repository).readablePane()
                case .serverDetail(let id): ServerDetailScreen(serverId: id, repository: repository).readablePane()
                case .github: GitHubAccountsScreen().readablePane()
                }
            }
            .navigationBarBackButtonHidden(hideBackButton)
            .sidebarToolbar(sidebarControls)
        }
    }
}

/// Desktop workspaces are selections, not nested navigation stacks. This also upgrades saved
/// mobile-style routes without mounting another explorer inside an existing tool's navigation.
private struct DesktopWorkspaceRoute: View {
    let route: AppRoute
    @Environment(AppModel.self) private var app
    var body: some View {
        Color.clear.onAppear {
            switch route {
            case .projectDetail(let id): app.openProject(id)
            case .workspaceDetail(let id): app.openWorkspace(id)
            default: break
            }
        }
    }
}

/// Only chats in a tab's own NavigationPath can be restored by that path. Files/Source Control
/// also present chats, but in local stacks which disappear when their tool sheet closes.
struct AppChatDestination: View {
    let chatId: String
    @Environment(AppModel.self) private var app

    var body: some View {
        ChatScreen(chatId: chatId)
            .onAppear { app.rememberChatLocation(chatId) }
    }
}

struct AgentsTab: View {
    var repository: WorkspaceRepository = .shared
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var app = app
        AdaptiveTabNavigation(path: $app.agentsPath, tab: .agents, title: t("assistant.bots.title"), selectionPrompt: t("bots.choose"), repository: repository) {
            AgentsListScreen(repository: repository)
        }
    }
}

struct ProjectsTab: View {
    var repository: WorkspaceRepository = .shared
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var app = app
        AdaptiveTabNavigation(path: $app.projectsPath, tab: .projects, title: t("tabs.projects"), selectionPrompt: "Choose a project", repository: repository) {
            ProjectsScreen(repository: repository)
        }
    }
}

struct WorkspacesTab: View {
    var repository: WorkspaceRepository = .shared
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var app = app
        AdaptiveTabNavigation(path: $app.workspacesPath, tab: .workspaces, title: t("tabs.workspaces"), selectionPrompt: "Choose a computer", repository: repository) {
            WorkspacesScreen(repository: repository)
        }
    }
}

struct SettingsTab: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        #if targetEnvironment(macCatalyst)
        DesktopSettingsScreen()
        #else
        @Bindable var app = app
        NavigationStack(path: $app.settingsPath) {
            SettingsScreen()
                .frame(maxWidth: AdaptiveLayout.readableWidth)
                .frame(maxWidth: .infinity)
                .background(Color(.systemGroupedBackground))
                .withAppRoutes()
        }
        #endif
    }
}
