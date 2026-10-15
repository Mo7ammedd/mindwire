import SwiftUI
import Observation

/// App-level navigation state. Injected via `@Environment(AppModel.self)`.
@MainActor
@Observable
final class AppModel {
    var selectedTab: AppTab = .projects { didSet { navigationDidChange?() } }

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

    #if targetEnvironment(macCatalyst)
    var desktopDestination: DesktopDestination = .newChat
    var desktopPath = NavigationPath()
    /// A welcome-screen send is consumed by the existing chat composer, once it is ready.
    var desktopSubmission: DesktopSubmission?

    func takeDesktopSubmission(chatID: String, revision: UInt64) -> Bool {
        guard let submission = desktopSubmission, submission.chatID == chatID else { return false }
        desktopSubmission = nil
        return submission.revision == revision
    }

    func selectDesktop(_ destination: DesktopDestination) {
        desktopPath = NavigationPath()
        desktopDestination = destination
        selectedTab = switch destination {
        case .newChat, .chat, .agents: .agents
        case .projects: .projects
        case .workspaces: .workspaces
        case .settings: .settings
        }
    }
    #endif

    init(stores: Stores) {
        self.stores = stores
    }

    // Cross-tab jumps: deep links (push) + post-creation "go to the thing you just made". These
    // intentionally switch tabs and land on the entity's canonical tab. In-app drill-down does NOT
    // use these — it pushes within the current stack via `NavigationLink(value: AppRoute…)`.
    func openAgent(_ id: String) {
        #if targetEnvironment(macCatalyst)
        selectDesktop(.agents)
        desktopPath.append(AppRoute.agentDetail(agentId: id))
        return
        #endif
        selectedTab = .agents
        agentsPath.append(AppRoute.agentDetail(agentId: id))
    }

    func openChat(_ chatId: String) {
        #if targetEnvironment(macCatalyst)
        selectDesktop(.chat(chatId))
        return
        #endif
        selectedTab = .agents
        agentsPath.append(AppRoute.chat(chatId: chatId))
        rememberChatLocation(chatId)
    }

    func rememberChatLocation(_ chatId: String) {
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
        })
    }

    /// Applied once before the window starts normal routing. A notification may then replace
    /// this location; returning from background never replays the saved path over newer work.
    func restoreNavigation(_ snapshot: AppNavigationSnapshot) {
        guard snapshot.version == AppNavigationSnapshot.currentVersion else { return }
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
    }

    private func openNotifiedChat(_ chatId: String, notificationID: String?) {
        stores.chatSessions.model(for: chatId).openFromNotification(id: notificationID)
        #if targetEnvironment(macCatalyst)
        openChat(chatId)
        return
        #endif
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
        #if targetEnvironment(macCatalyst)
        if case .chat(let id) = route { openChat(id) }
        else { desktopPath.append(route) }
        return
        #endif
        switch selectedTab {
        case .agents: agentsPath.append(route)
        case .projects: projectsPath.append(route)
        case .workspaces: workspacesPath.append(route)
        case .settings: settingsPath.append(route)
        }
    }

    func openProject(_ id: String) {
        #if targetEnvironment(macCatalyst)
        selectDesktop(.projects)
        desktopPath.append(AppRoute.projectDetail(id: id))
        return
        #endif
        selectedTab = .projects
        projectsPath.append(AppRoute.projectDetail(id: id))
    }

    func replaceTop(_ route: AppRoute) {
        #if targetEnvironment(macCatalyst)
        if !desktopPath.isEmpty { desktopPath.removeLast() }
        desktopPath.append(route)
        return
        #endif
        switch selectedTab {
        case .agents: if !agentsPath.isEmpty { agentsPath.removeLast() }; agentsPath.append(route)
        case .projects: if !projectsPath.isEmpty { projectsPath.removeLast() }; projectsPath.append(route)
        case .workspaces: if !workspacesPath.isEmpty { workspacesPath.removeLast() }; workspacesPath.append(route)
        case .settings: if !settingsPath.isEmpty { settingsPath.removeLast() }; settingsPath.append(route)
        }
    }

    func showProjects() {
        #if targetEnvironment(macCatalyst)
        selectDesktop(.projects)
        return
        #endif
        selectedTab = .projects
        projectsPath = NavigationPath()
    }

    func openWorkspace(_ id: String) {
        #if targetEnvironment(macCatalyst)
        selectDesktop(.workspaces)
        desktopPath.append(AppRoute.workspaceDetail(id: id))
        return
        #endif
        selectedTab = .workspaces
        workspacesPath.append(AppRoute.workspaceDetail(id: id))
    }

    /// Route a tapped push notification to the thing it's about (see `PushTarget`).
    func open(_ target: PushTarget, notificationID: String? = nil) {
        switch target {
        case .chat(let id):    openNotifiedChat(id, notificationID: notificationID)
        case .project(let id): openProject(id)
        case .agent(let id):   openAgent(id)
        case .workspace(let id): openWorkspace(id)
        }
    }
}
