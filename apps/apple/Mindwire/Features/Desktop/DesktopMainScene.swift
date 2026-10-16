#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

enum DesktopDestination: Hashable {
    case newChat, chat(String), projects, agents, workspaces, settings

    var storageKey: String {
        switch self {
        case .newChat: "new"
        case .chat(let id): "chat:" + id
        case .projects: "projects"
        case .agents: "agents"
        case .workspaces: "workspaces"
        case .settings: "settings"
        }
    }

    init(storageKey: String) {
        if storageKey.hasPrefix("chat:") { self = .chat(String(storageKey.dropFirst(5))); return }
        switch storageKey {
        case "projects": self = .projects
        case "agents": self = .agents
        case "workspaces": self = .workspaces
        case "settings": self = .settings
        default: self = .newChat
        }
    }
}

struct DesktopSubmission {
    let chatID: String
    let revision: UInt64
}

private struct DesktopChatGroup: Identifiable {
    let title: String
    let chats: [Chat]
    var id: String { title }
}

/// The desktop owns navigation and presentation. All work stays in the shared services and screens.
struct DesktopMainScene: View {
    var repository: WorkspaceRepository = .shared
    @Environment(AppModel.self) private var app
    @Environment(\.stores) private var stores
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var search = ""
    @State private var showingSearch = false
    @State private var chats: [Chat] = []
    @State private var chatGroups: [DesktopChatGroup] = []
    @State private var rowSnapshots: [String: ChatListRowSnapshot] = [:]
    @State private var restored = false
    @State private var computer = DesktopComputer.shared
    @FocusState private var searching: Bool
    @SceneStorage("mindwire.desktop.destination") private var savedDestination = "new"
    @AppStorage("mindwire.desktop.developerTools") private var developerTools = false

    private var visibleChats: [Chat] {
        search.isEmpty ? chats : chats.filter { $0.title.localizedStandardContains(search) }
    }

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            NavigationStack(path: $app.desktopPath) {
                detail
                    .withAppRoutes(repository: repository)
                    .toolbar {
                        if columns == .detailOnly {
                            AppToolbarItem(placement: .primaryAction) {
                                Button { app.selectDesktop(.newChat) } label: { AppIcon(.edit) }
                                    .keyboardShortcut("n", modifiers: .command)
                                    .accessibilityLabel("New chat")
                                    .help("New chat (⌘N)")
                                    .tint(.primary)
                            }
                        }
                    }
            }
            .id(app.desktopDestination)
            .background(.background)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .background(DesktopWindowConfiguration())
        .onAppear {
            reloadSidebar()
            guard !restored else { return }
            restored = true
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--app-store-preview") { return }
            #endif
            guard app.desktopDestination == .newChat, app.desktopPath.isEmpty else { return }
            let destination = DesktopDestination(storageKey: savedDestination)
            if case .chat(let id) = destination, stores.chats.get(id) == nil { return }
            app.selectDesktop(destination)
        }
        .task { await computer.prepare(stores: stores, repository: repository) }
        .onChange(of: app.desktopDestination) { _, destination in savedDestination = destination.storageKey }
        .onChange(of: stores.chats.revision) { reloadSidebar() }
        .onChange(of: stores.projects.revision) { reloadSidebar() }
        .onChange(of: stores.agents.revision) { reloadSidebar() }
        .onChange(of: repository.revision) { reloadSidebar() }
        .onChange(of: stores.workspaces.revision) { reloadSidebar() }
        .observeWorkspaceCache {
            reloadSidebar()
            if case .chat(let id) = app.desktopDestination, stores.chats.get(id) == nil { app.selectDesktop(.newChat) }
        }
    }

    private var selection: Binding<DesktopDestination?> {
        Binding(get: { app.desktopDestination == .newChat ? nil : app.desktopDestination }, set: {
            if let destination = $0, destination != app.desktopDestination { select(destination) }
        })
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            newChatAction
            conversationList
            navigationTools
        }
        .searchable(text: $search, isPresented: $showingSearch, placement: .sidebar, prompt: "Search conversations")
        .searchFocused($searching)
        .navigationTitle("Mindwire")
        .toolbar {
            AppToolbarItemGroup(placement: .primaryAction) {
                Button { showingSearch = true; searching = true } label: { AppIcon(.search) }
                    .keyboardShortcut("f", modifiers: .command)
                    .accessibilityLabel("Search conversations")
                    .help("Search conversations (⌘F)")
                    .tint(.primary)
            }
        }
    }

    /// Stay outside the lazy history so New Chat and its shortcut remain available while scrolling.
    private var newChatAction: some View {
        Button { app.selectDesktop(.newChat) } label: {
            Label("New chat", icon: .edit)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityIdentifier("desktop.newChat")
        .help("New chat (⌘N)")
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var conversationList: some View {
        List(selection: selection) {
            if !search.isEmpty {
                Section("Search results") {
                    if visibleChats.isEmpty {
                        Text("No matching conversations")
                            .font(.caption).foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    conversationRows(visibleChats)
                }
            } else if chatGroups.isEmpty {
                Section("Chats") {
                    Text("No chats yet")
                        .font(.callout).foregroundStyle(.tertiary)
                        .selectionDisabled()
                }
            } else {
                ForEach(chatGroups) { group in
                    Section(group.title) { conversationRows(group.chats) }
                }
            }
        }
        .listStyle(.sidebar)
        .listSectionSpacing(16)
        .tint(Color(uiColor: .systemGray4))
        .environment(\.defaultMinListRowHeight, 36)
    }

    private func conversationRows(_ items: [Chat]) -> some View {
        ForEach(items) { chat in
            ChatListRow(chat: chat, snapshot: rowSnapshots[chat.id], compact: true, onOpen: { app.openChat(chat.id) },
                        onChanged: reloadSidebar)
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Color(uiColor: .label))
                .listItemTint(.monochrome)
                .tag(DesktopDestination.chat(chat.id))
                .accessibilityIdentifier("desktop.chat.\(chat.id)")
        }
    }

    /// The same destinations and artwork as the phone, pinned below the conversation list.
    private var navigationTools: some View {
        List(selection: selection) {
            Section {
                destination(.workspaces, title: "This Mac", icon: .monitor)
                if developerTools {
                    destination(.projects, title: "Projects", icon: .project)
                }
                destination(.agents, title: "Subscriptions", icon: .key)
                destination(.settings, title: "Settings", icon: Icon.settings)
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        .listStyle(.sidebar)
        .tint(Color(uiColor: .systemGray4))
        .environment(\.defaultMinListRowHeight, 36)
        .scrollDisabled(true)
        .frame(height: developerTools ? 178 : 140)
    }

    private func reloadSidebar() {
        let workspaces = Set(repository.all.map(\.id))
        let projects = Set(stores.projects.list().filter { workspaces.contains($0.workspaceId) }.map(\.id))
        let agents = Dictionary(stores.agents.list().map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        // Decode each metadata list once per change, never once per row or typed search character.
        chats = stores.chatsByRecency().filter { projects.contains($0.projectId) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? yesterday
        let grouped = Dictionary(grouping: chats) { chat -> Int in
            guard let date = ChatActivityStore.shared.lastActivity(chat) else { return 3 }
            if date >= today { return 0 }
            if date >= yesterday { return 1 }
            if date >= week { return 2 }
            return 3
        }
        chatGroups = ["Today", "Yesterday", "Previous 7 days", "Earlier"].enumerated().compactMap { index, title in
            guard let items = grouped[index], !items.isEmpty else { return nil }
            return DesktopChatGroup(title: title, chats: items)
        }
        rowSnapshots = Dictionary(uniqueKeysWithValues: chats.map { chat in
            (chat.id, ChatListRowSnapshot(notificationsMuted: chat.notificationsMuted == true || agents[chat.agentId]?.notificationsMuted == true))
        })
    }

    private func destination(_ destination: DesktopDestination, title: String, icon: AppIconName) -> some View {
        Button { select(destination) } label: {
            Label(title, icon: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(Color(uiColor: .label))
        .listItemTint(.monochrome)
        .tag(destination)
    }

    private func select(_ destination: DesktopDestination) {
        if destination == .workspaces, let id = computer.workspaceId { app.openWorkspace(id) }
        else { app.selectDesktop(destination) }
    }

    @ViewBuilder private var detail: some View {
        switch app.desktopDestination {
        case .newChat: DesktopNewChatScreen(repository: repository)
        case .chat(let id): ChatScreen(chatId: id).id(id)
        case .projects: ProjectsScreen(repository: repository)
        case .agents: AgentsListScreen(repository: repository).navigationTitle("Subscriptions")
        case .workspaces: WorkspacesScreen(repository: repository)
        case .settings: SettingsScreen().readablePane()
        }
    }
}

#endif
