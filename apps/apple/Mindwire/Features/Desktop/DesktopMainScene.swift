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

/// The desktop owns navigation and presentation. All work stays in the shared services and screens.
struct DesktopMainScene: View {
    var repository: WorkspaceRepository = .shared
    @Environment(AppModel.self) private var app
    @Environment(\.stores) private var stores
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var search = ""
    @State private var chats: [Chat] = []
    @State private var restored = false
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
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            NavigationStack(path: $app.desktopPath) {
                detail
                    .withAppRoutes(repository: repository)
            }
            .id(app.desktopDestination)
            .background(.background)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.primary)
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
        .onChange(of: app.desktopDestination) { _, destination in savedDestination = destination.storageKey }
        .onChange(of: stores.chats.revision) { reloadSidebar() }
        .onChange(of: stores.projects.revision) { reloadSidebar() }
        .onChange(of: repository.all.map(\.id)) { reloadSidebar() }
        .observeWorkspaceCache {
            reloadSidebar()
            if case .chat(let id) = app.desktopDestination, stores.chats.get(id) == nil { app.selectDesktop(.newChat) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    destination(.newChat, title: "New chat", symbol: "square.and.pencil")
                        .accessibilityIdentifier("desktop.newChat")
                    TextField("Search conversations", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .focused($searching)
                        .accessibilityIdentifier("desktop.search")
                        .listRowBackground(Color.clear)
                }
                Section(search.isEmpty ? "Recent chats" : "Search results") {
                    if visibleChats.isEmpty {
                        Text(search.isEmpty ? "Your conversations will appear here." : "No matching conversations")
                            .font(.caption).foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(visibleChats) { chat in
                        Button { app.openChat(chat.id) } label: {
                            HStack(spacing: 8) {
                                Text(chat.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                if ChatActivityStore.shared.status(chat.id) == .running {
                                    ProgressView().controlSize(.mini).accessibilityLabel("Working")
                                }
                            }
                            .padding(.vertical, 3)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(app.desktopDestination == .chat(chat.id) ? Color.primary.opacity(0.08) : Color.clear)
                        .accessibilityAddTraits(app.desktopDestination == .chat(chat.id) ? .isSelected : [])
                        .accessibilityIdentifier("desktop.chat.\(chat.id)")
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 34)
            .listRowSpacing(2)
            .scrollContentBackground(.hidden)
            VStack(spacing: 0) {
                destination(.workspaces, title: "Computers", symbol: "desktopcomputer")
                if developerTools {
                    destination(.projects, title: "Projects", symbol: "folder")
                    destination(.agents, title: "Agent settings", symbol: "slider.horizontal.3")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider().opacity(0.4)
            HStack {
                Button { app.selectDesktop(.settings) } label: {
                    Label("Settings", systemImage: "gearshape").font(.callout)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Menu {
                    Toggle("Developer tools", isOn: $developerTools)
                    Button("Connect a computer", systemImage: "plus") { app.selectDesktop(.workspaces) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mindwire options")
            }
            .padding(16)
        }
        .background(.ultraThinMaterial)
        .navigationTitle("Mindwire")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { searching = true } label: { Image(systemName: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Search conversations (⌘F)")
                Button { app.selectDesktop(.newChat) } label: { Image(systemName: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New chat (⌘N)")
            }
        }
    }

    private func reloadSidebar() {
        let workspaces = Set(repository.all.map(\.id))
        let projects = Set(stores.projects.list().filter { workspaces.contains($0.workspaceId) }.map(\.id))
        // Decode each metadata list once per change, never once per row or typed search character.
        chats = stores.chatsByRecency().filter { projects.contains($0.projectId) }
    }

    private func destination(_ destination: DesktopDestination, title: String, symbol: String) -> some View {
        Button { app.selectDesktop(destination) } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(app.desktopDestination == destination ? Color.primary.opacity(0.08) : Color.clear)
        .accessibilityAddTraits(app.desktopDestination == destination ? .isSelected : [])
    }

    @ViewBuilder private var detail: some View {
        switch app.desktopDestination {
        case .newChat: DesktopNewChatScreen(repository: repository)
        case .chat(let id): ChatScreen(chatId: id).id(id)
        case .projects: ProjectsScreen(repository: repository)
        case .agents: AgentsListScreen(repository: repository)
        case .workspaces: WorkspacesScreen(repository: repository)
        case .settings: SettingsScreen().readablePane()
        }
    }
}

/// Catalyst's Mac idiom uses native control sizes and a normal resizable Mac window.
private struct DesktopWindowConfiguration: UIViewRepresentable {
    func makeUIView(context: Context) -> WindowView { WindowView() }
    func updateUIView(_ uiView: WindowView, context: Context) { uiView.configure() }

    final class WindowView: UIView {
        override func didMoveToWindow() { super.didMoveToWindow(); configure() }
        func configure() {
            guard let scene = window?.windowScene else { return }
            scene.sizeRestrictions?.minimumSize = CGSize(width: 850, height: 620)
            scene.titlebar?.titleVisibility = .hidden
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }
    }
}
#endif
