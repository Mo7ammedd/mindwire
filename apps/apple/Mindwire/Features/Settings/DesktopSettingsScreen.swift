#if targetEnvironment(macCatalyst)
import SwiftUI
import Observation
import UIKit

enum DesktopSettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, connections, account, notifications, backup, github, updates, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: t("experience.general")
        case .appearance: t("settings.appearance")
        case .connections: "AI Connections"
        case .account: t("account.title")
        case .notifications: t("notifications.title")
        case .backup: "Backup & Sync"
        case .github: "GitHub"
        case .updates: "Software Updates"
        case .about: t("settings.about")
        }
    }

    var icon: AppIconName {
        switch self {
        case .general: .settings
        case .appearance: .moon
        case .connections: .laptop
        case .account: .userCircle
        case .notifications: .bell
        case .backup: .cloud
        case .github: .gitBranch
        case .updates: .refresh
        case .about: .info
        }
    }
}

/// One preferences window, regardless of which chat window opened it.
@MainActor @Observable
final class DesktopSettingsNavigation {
    static let shared = DesktopSettingsNavigation()
    static let windowID = "mindwire-settings"
    var pane: DesktopSettingsPane? = .general
    var notificationChatID: String?
}

extension OpenWindowAction {
    func openMindwireSettings(_ pane: DesktopSettingsPane = .general, chatID: String? = nil) {
        DesktopSettingsNavigation.shared.pane = pane
        DesktopSettingsNavigation.shared.notificationChatID = chatID
        self(id: DesktopSettingsNavigation.windowID, value: DesktopSettingsNavigation.windowID)
    }
}

struct DesktopSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow.openMindwireSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .appSettings) {
            DesktopConnectPhoneButton()
        }
    }
}

/// Owns navigation only. Preferences, account, connections and notifications use shared stores.
struct DesktopSettingsWindow: View {
    let stores: Stores
    @State private var app: AppModel
    @AppStorage("mindwire.appearance") private var appearance = "system"

    init(stores: Stores) {
        self.stores = stores
        _app = State(initialValue: AppModel(stores: stores))
    }

    var body: some View {
        DesktopSettingsScreen()
            .environment(app)
            .environment(\.stores, stores)
            .environment(\.appExperienceMode, stores.experience.mode ?? .general)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .tint(Palette.accent)
            .frame(minWidth: 700, minHeight: 460)
            .background { SettingsWindowConfiguration().frame(width: 0, height: 0) }
    }
}

struct DesktopSettingsScreen: View {
    @Environment(\.appExperienceMode) private var experienceMode
    @State private var navigation = DesktopSettingsNavigation.shared

    private var panes: [DesktopSettingsPane] {
        DesktopSettingsPane.allCases.filter { experienceMode == .developer || $0 != .github }
    }

    var body: some View {
        NavigationSplitView {
            List(panes, selection: Binding(get: { navigation.pane }, set: {
                navigation.pane = $0
                navigation.notificationChatID = nil
            })) { pane in
                Label { Text(pane.title) } icon: { AppIcon(pane.icon, size: 16, decorative: true) }
                    .font(.system(size: 13))
                    .accessibilityIdentifier("settings.category.\(pane.id)")
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .contentMargins(.top, 12, for: .scrollContent)
            .contentMargins(.bottom, 12, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 32)
            .navigationTitle(t("tabs.settings"))
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 210)
        } detail: {
            NavigationStack {
                detail(navigation.pane ?? .general)
                    .navigationTitle((navigation.pane ?? .general).title)
                    .navigationBarTitleDisplayMode(.inline)
                    .withAppRoutes()
            }
            .id(navigation.pane)
            .modifier(DesktopSettingsDetailStyle())
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .onChange(of: experienceMode) { _, _ in
            if let pane = navigation.pane, !panes.contains(pane) { navigation.pane = .general }
        }
    }

    @ViewBuilder private func detail(_ pane: DesktopSettingsPane) -> some View {
        switch pane {
        case .general:
            DesktopSettingsPage {
                DesktopSettingsGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(t("experience.mode"))
                            Spacer(minLength: 16)
                            SettingsModePicker().labelsHidden().pickerStyle(.segmented)
                                .controlSize(.regular).frame(width: 212)
                        }
                        Text(experienceMode.detail)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
                DesktopSettingsGroup {
                    HStack {
                        Text(t("settings.language"))
                        Spacer()
                        Text("English").foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
            }
        case .appearance:
            SettingsAppearanceControls(expanded: true)
        case .connections: DesktopSettingsConnections()
        case .account: AccountScreen()
        case .notifications:
            if let chatID = navigation.notificationChatID {
                NotificationPreferencesScreen(scope: .chat(chatID)).id(chatID)
            } else { NotificationSettingsScreen() }
        case .backup: BackupSyncScreen()
        case .github: GitHubAccountsScreen()
        case .updates:
            List { ServiceUpdatesSettingsSection() }.serviceUpdatePresentation()
        case .about:
            DesktopSettingsPage {
                DesktopSettingsGroup {
                    SettingsAboutLinks().buttonStyle(.plain).tint(.primary).padding(16)
                }
            }
        }
    }
}

private struct DesktopSettingsDetailStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .controlSize(.small)
            .pickerStyle(.menu)
            .listStyle(.inset)
            .listSectionSpacing(16)
            .environment(\.defaultMinListRowHeight, 34)
            .scrollContentBackground(.hidden)
            .background(AssistantDesktopStyle.canvas)
    }
}

private struct DesktopSettingsConnections: View {
    @Environment(\.stores) private var stores
    @State private var repository = WorkspaceRepository.shared
    @State private var configuring: Workspace?

    var body: some View {
        List {
            Section("This Mac") {
                if let workspace = repository.all.first(where: { $0.runtime.isLocal }) {
                    workspaceRow(workspace)
                } else {
                    ProgressView(t("assistant.setup.preparing"))
                    if let error = LocalComputer.shared.error { Text(error).foregroundStyle(.secondary) }
                    Button(t("common.retry")) { Task { await prepareLocal() } }
                }
            }
            Section("Remote computers") {
                ForEach(repository.all.filter { !$0.runtime.isLocal && !$0.isCloud }) { workspace in
                    workspaceRow(workspace)
                }
                NavigationLink("Mindwire Cloud") {
                    List {
                        ForEach(repository.all.filter(\.isCloud)) { workspace in workspaceRow(workspace) }
                        NavigationLink("Add cloud computer") {
                            NewWorkspaceScreen(assistantCloud: true, embedded: true) { workspace in configuring = workspace }
                        }
                    }
                    .navigationTitle("Mindwire Cloud")
                }
            }
            Section {
                NavigationLink(t("bots.connections.title")) { BotConnectionsScreen(embedded: true) }
            }
        }
        .navigationDestination(item: $configuring) { workspace in
            AssistantAIConnectionsScreen(workspaceID: workspace.id)
        }
        .task { await prepareLocal() }
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        Button { configuring = workspace } label: {
            HStack(spacing: 10) {
                AppIcon(workspace.isCloud ? .cloud : .laptop, size: 16, decorative: true)
                Text(workspace.name)
                Spacer()
                if let agent = stores.experience.assistantAgentID.flatMap(stores.agents.get),
                   agent.workspaceId == workspace.id {
                    Text(AssistantAIService(agentType: agent.agentType)?.name ?? agent.displayName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func prepareLocal() async {
        await LocalComputer.shared.prepare(stores: stores, repository: repository)
    }
}

private struct SettingsWindowConfiguration: UIViewRepresentable {
    func makeUIView(context: Context) -> Observer { Observer() }
    func updateUIView(_ view: Observer, context: Context) {}

    final class Observer: UIView {
        private weak var configuredScene: UIWindowScene?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene, scene !== configuredScene else { return }
            configuredScene = scene
            scene.title = t("tabs.settings")
            scene.sizeRestrictions?.minimumSize = CGSize(width: 700, height: 500)
            scene.titlebar?.titleVisibility = .visible
            scene.titlebar?.separatorStyle = .automatic
            scene.titlebar?.toolbarStyle = .unifiedCompact

            // Resize the old oversized preferences window once; preserve later user resizing.
            let key = "mindwire.desktop.settingsWindow.layout"
            guard UserDefaults.standard.integer(forKey: key) < 2 else { return }
            let screen = scene.screen.bounds
            let size = CGSize(width: 800, height: 560)
            let frame = CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                               width: size.width, height: size.height)
            scene.requestGeometryUpdate(.Mac(systemFrame: frame)) { error in
                APILog.note("settings: preferred window size unavailable — \(error.localizedDescription)")
            }
            UserDefaults.standard.set(2, forKey: key)
        }
    }
}
#endif
