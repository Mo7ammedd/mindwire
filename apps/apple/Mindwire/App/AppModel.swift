import SwiftUI
import Observation

/// App-level navigation state. Injected via `@Environment(AppModel.self)`.
@MainActor
@Observable
final class AppModel {
    var selectedTab: AppTab = ApplePlatform.isDesktop ? .agents : .projects { didSet { navigationDidChange?() } }
    var assistantChatID: String? { didSet { navigationDidChange?() } }
    var assistantBotID: String? { didSet { navigationDidChange?() } }
    var assistantAppsVisible = false
    var presentedAppShortcut: AppShortcut?
    private var pendingAppShortcutID: String?

    var usesAssistant: Bool {
        stores.experience.mode == .general
    }

    /// Desktop modes share the same conversation surface; Developer adds workspace navigation.
    var usesChatShell: Bool { usesAssistant || ApplePlatform.isDesktop }
    var desktopProjectID: String? { didSet { navigationDidChange?() } }
    var desktopWorkspaceID: String? { didSet { navigationDidChange?() } }
    var desktopSidebarVisible = true
    var desktopToolSidebarVisible = true
    var desktopBrowserWidth: CGFloat = 300
    var desktopProjectIsOpen: Bool {
        ApplePlatform.isDesktop && !usesAssistant && selectedTab == .projects
            && desktopProjectID != nil
    }
    var desktopNavigationVisible: Bool {
        desktopProjectIsOpen ? desktopToolSidebarVisible : desktopSidebarVisible
    }
    var desktopBotRailVisible: Bool {
        ApplePlatform.isDesktop && !desktopSidebarVisible && !desktopProjectIsOpen
            && (usesAssistant || selectedTab == .agents)
    }

    func showDesktopTool(_ tool: ProjectTool?) {
        if desktopProjectIsOpen { desktopToolSidebarVisible = true; return }
        if tool == .files || tool == .sourceControl {
            desktopSidebarVisible = false
            desktopToolSidebarVisible = true
        } else if tool == nil {
            desktopSidebarVisible = true
        }
    }

    func toggleDesktopSidebar() {
        if desktopProjectIsOpen { desktopToolSidebarVisible.toggle(); return }
        desktopSidebarVisible.toggle()
        if !desktopSidebarVisible { desktopToolSidebarVisible = false }
    }

    var desktopHasUnsavedFileEdits = false
    var pendingDesktopNavigation: (() -> Void)?

    /// Inline file editing gets the same discard protection as the shared file sheet.
    @discardableResult func navigateDesktop(_ action: @escaping () -> Void) -> Bool {
        if ApplePlatform.isDesktop && desktopHasUnsavedFileEdits {
            pendingDesktopNavigation = action
            return false
        }
        action()
        return true
    }

    func confirmDesktopNavigation() {
        let action = pendingDesktopNavigation
        pendingDesktopNavigation = nil
        desktopHasUnsavedFileEdits = false
        action?()
    }

    func selectDesktopSection(_ tab: AppTab) {
        guard selectedTab != tab else { return }
        navigateDesktop { self.selectedTab = tab }
    }

    private func enterDeveloper() {
        if usesAssistant { stores.experience.mode = .developer }
    }

    // One navigation path per tab.
    var agentsPath = NavigationPath() { didSet { navigationDidChange?() } }
    var projectsPath = NavigationPath() { didSet { navigationDidChange?() } }
    var workspacesPath = NavigationPath() { didSet { navigationDidChange?() } }
    var settingsPath = NavigationPath() { didSet { navigationDidChange?() } }
    var sidebarPaths: [AppTab: NavigationPath] = [:] { didSet { navigationDidChange?() } }
    var hiddenSidebars: Set<AppTab> = [] { didSet { navigationDidChange?() } }
    @ObservationIgnored var navigationDidChange: (() -> Void)?

    /// Remember the path as well as the chat: popping/pushing elsewhere makes a saved location
    /// ineligible. A notification can reuse a chat in any tab without stacking duplicate screens.
    @ObservationIgnored private var chatLocations: [AppTab: (id: String, path: NavigationPath)] = [:]

    let stores: Stores

    init(stores: Stores) {
        self.stores = stores
    }

    // Cross-tab jumps: deep links (push) + post-creation "go to the thing you just made". These
    // intentionally switch tabs and land on the entity's canonical tab. In-app drill-down does NOT
    // use these — it pushes within the current stack via `NavigationLink(value: AppRoute…)`.
    func openAgent(_ id: String) {
        if ApplePlatform.isDesktop && desktopHasUnsavedFileEdits {
            pendingDesktopNavigation = { self.openAgent(id) }; return
        }
        enterDeveloper()
        selectedTab = .agents
        agentsPath.append(AppRoute.agentDetail(agentId: id))
    }

    func openChat(_ chatId: String) {
        if ApplePlatform.isDesktop && desktopHasUnsavedFileEdits {
            pendingDesktopNavigation = { self.openChat(chatId) }; return
        }
        if usesChatShell {
            if ApplePlatform.isDesktop { selectedTab = .agents; agentsPath = NavigationPath() }
            assistantBotID = stores.chats.get(chatId)?.botId
            assistantChatID = chatId
            return
        }
        selectedTab = .agents
        agentsPath.append(AppRoute.chat(chatId: chatId))
        rememberChatLocation(chatId)
    }

    func openBot(_ botId: String) {
        if ApplePlatform.isDesktop && desktopHasUnsavedFileEdits {
            pendingDesktopNavigation = { self.openBot(botId) }; return
        }
        guard usesChatShell, let bot = stores.bots.get(botId), !bot.archived else { return }
        if ApplePlatform.isDesktop { selectedTab = .agents; agentsPath = NavigationPath() }
        assistantBotID = botId
        assistantChatID = stores.chatsByRecency().first { $0.botId == botId }?.id
    }

    func rememberChatLocation(_ chatId: String) {
        if usesChatShell { return }
        let path = path(in: selectedTab)
        guard chatLocations[selectedTab]?.id != chatId
                || chatLocations[selectedTab]?.path.hasSameDestinations(as: path) != true else { return }
        chatLocations[selectedTab] = (chatId, path)
        navigationDidChange?()
    }

    private func path(in tab: AppTab) -> NavigationPath {
        switch tab {
        case .agents: agentsPath
        case .projects: projectsPath
        case .workspaces: workspacesPath
        case .settings: settingsPath
        }
    }

    var navigationSnapshot: AppNavigationSnapshot {
        .init(selectedTab: selectedTab, tabs: AppTab.allCases.map { tab in
            let path = path(in: tab)
            let representation = path.codable
            let chat = chatLocations[tab].flatMap { $0.path.hasSameDestinations(as: path) && !path.isEmpty ? $0.id : nil }
            return .init(tab: tab, path: representation, sidebar: sidebarPaths[tab]?.codable,
                         sidebarHidden: hiddenSidebars.contains(tab), chatId: representation == nil ? nil : chat)
        }, assistantChatID: assistantChatID, assistantBotID: assistantBotID,
           desktopProjectID: desktopProjectID, desktopWorkspaceID: desktopWorkspaceID)
    }

    /// Applied once before the window starts normal routing. A notification may then replace
    /// this location; returning from background never replays the saved path over newer work.
    func restoreNavigation(_ snapshot: AppNavigationSnapshot) {
        guard snapshot.version == AppNavigationSnapshot.currentVersion else { return }
        assistantChatID = snapshot.assistantChatID
        assistantBotID = snapshot.assistantBotID
        desktopProjectID = snapshot.desktopProjectID
        desktopWorkspaceID = snapshot.desktopWorkspaceID
        chatLocations.removeAll()
        sidebarPaths.removeAll()
        hiddenSidebars.removeAll()
        for state in snapshot.tabs {
            let path = state.path.map(NavigationPath.init) ?? NavigationPath()
            switch state.tab {
            case .agents: agentsPath = path
            case .projects: projectsPath = path
            case .workspaces: workspacesPath = path
            case .settings: settingsPath = path
            }
            if let sidebar = state.sidebar { sidebarPaths[state.tab] = NavigationPath(sidebar) }
            if state.sidebarHidden { hiddenSidebars.insert(state.tab) }
            if let id = state.chatId, !path.isEmpty { chatLocations[state.tab] = (id, path) }
        }
        selectedTab = snapshot.selectedTab
        if ApplePlatform.isDesktop, assistantChatID == nil,
           let chat = chatLocations[selectedTab]?.id {
            openChat(chat)
        }
    }

    private func openNotifiedChat(_ chatId: String, notificationID: String?) {
        stores.chatSessions.model(for: chatId).openFromNotification(id: notificationID)
        if usesChatShell { openChat(chatId); return }
        for tab in [selectedTab, .agents, .projects, .workspaces, .settings] {
            if let location = chatLocations[tab], location.id == chatId,
               location.path.hasSameDestinations(as: path(in: tab)) {
                selectedTab = tab
                return
            }
        }
        openChat(chatId)
    }

    /// Context-menu actions follow the same stack as a row's NavigationLink.
    func push(_ route: AppRoute) {
        if ApplePlatform.isDesktop {
            if case .projectDetail(let id) = route { openProject(id); return }
            if case .workspaceDetail(let id) = route { openWorkspace(id); return }
        }
        if ApplePlatform.isDesktop && desktopHasUnsavedFileEdits {
            pendingDesktopNavigation = { self.push(route) }; return
        }
        if usesChatShell, case .chat(let id) = route { openChat(id); return }
        if usesAssistant {
            if case .chat(let id) = route { assistantChatID = id; return }
            enterDeveloper()
        }
        switch selectedTab {
        case .agents: agentsPath.append(route)
        case .projects: projectsPath.append(route)
        case .workspaces: workspacesPath.append(route)
        case .settings: settingsPath.append(route)
        }
    }

    func openProject(_ id: String) {
        if ApplePlatform.isDesktop && desktopHasUnsavedFileEdits {
            pendingDesktopNavigation = { self.openProject(id) }; return
        }
        enterDeveloper()
        selectedTab = .projects
        if ApplePlatform.isDesktop {
            desktopProjectID = id
            desktopToolSidebarVisible = true
            projectsPath = NavigationPath()
            return
        }
        projectsPath.append(AppRoute.projectDetail(id: id))
    }

    func replaceTop(_ route: AppRoute) {
        if ApplePlatform.isDesktop {
            if case .projectDetail(let id) = route { openProject(id); return }
            if case .workspaceDetail(let id) = route { openWorkspace(id); return }
        }
        if ApplePlatform.isDesktop && desktopHasUnsavedFileEdits {
            pendingDesktopNavigation = { self.replaceTop(route) }; return
        }
        if usesChatShell, case .chat(let id) = route { openChat(id); return }
        if usesAssistant {
            if case .chat(let id) = route { assistantChatID = id; return }
            enterDeveloper()
        }
        switch selectedTab {
        case .agents: if !agentsPath.isEmpty { agentsPath.removeLast() }; agentsPath.append(route)
        case .projects: if !projectsPath.isEmpty { projectsPath.removeLast() }; projectsPath.append(route)
        case .workspaces: if !workspacesPath.isEmpty { workspacesPath.removeLast() }; workspacesPath.append(route)
        case .settings: if !settingsPath.isEmpty { settingsPath.removeLast() }; settingsPath.append(route)
        }
    }

    func showProjects() {
        if ApplePlatform.isDesktop && desktopHasUnsavedFileEdits {
            pendingDesktopNavigation = { self.showProjects() }; return
        }
        enterDeveloper()
        selectedTab = .projects
        desktopProjectID = nil
        desktopSidebarVisible = true
        projectsPath = NavigationPath()
    }

    func showComputers() {
        navigateDesktop {
            self.selectedTab = .workspaces
            self.desktopWorkspaceID = nil
            self.desktopSidebarVisible = true
            self.workspacesPath = NavigationPath()
        }
    }

    func openWorkspace(_ id: String) {
        if ApplePlatform.isDesktop && desktopHasUnsavedFileEdits {
            pendingDesktopNavigation = { self.openWorkspace(id) }; return
        }
        enterDeveloper()
        selectedTab = .workspaces
        if ApplePlatform.isDesktop {
            desktopWorkspaceID = id
            workspacesPath = NavigationPath()
            return
        }
        workspacesPath.append(AppRoute.workspaceDetail(id: id))
    }

    /// Route a tapped push notification to the thing it's about (see `PushTarget`).
    func open(_ target: PushTarget, notificationID: String? = nil) {
        switch target {
        case .app(let id):
            pendingAppShortcutID = id
            assistantAppsVisible = true
            resolvePendingAppShortcut()
            Task {
                await stores.workspaceData.refreshAll(WorkspaceRepository.shared.all)
                resolvePendingAppShortcut()
            }
        case .chat(let id):    openNotifiedChat(id, notificationID: notificationID)
        case .project(let id): openProject(id)
        case .agent(let id):   openAgent(id)
        case .workspace(let id): openWorkspace(id)
        }
    }

    func resolvePendingAppShortcut() {
        guard let id = pendingAppShortcutID, let app = stores.apps.get(id) else { return }
        guard !app.archived else { pendingAppShortcutID = nil; return }
        presentedAppShortcut = app
        pendingAppShortcutID = nil
    }
}
