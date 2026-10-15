#if DEBUG
import SwiftUI

/// Test-only entry point to the production screens; opt in with --app-store-preview.
struct AppStorePreviewScene: View {
    @State private var fixture: AppStoreFixture?
    @State private var git: GitModel?
    @State private var desktop: DesktopModel?
    @State private var showTransfer = false
    @State private var showSource = false
    @State private var showNotificationIntro = false
    @State private var notificationReminderOwner = UUID()
    @State private var error: String?
    @State private var previousIdleTimerDisabled: Bool?
    private let scenario = ProcessInfo.processInfo.environment["MINDWIRE_STORE_SCENE"] ?? "projects"
    private let theme = ProcessInfo.processInfo.environment["MINDWIRE_STORE_THEME"] ?? "dark"

    var body: some View {
        Group {
            if let fixture, let git {
                content(fixture, git: git)
                    .restoringNavigation(fixture.app, store: fixture.navigationStore)
                    .environment(fixture.app)
                    .environment(\.stores, fixture.stores)
                    .tint(Palette.accent)
                    .labelIconToTitleSpacing(Spacing.md)
                    .accessibilityIdentifier("store.ready")
                    .overlay(alignment: .bottomLeading) {
                        if scenario == "library", ProcessInfo.processInfo.environment["MINDWIRE_LIBRARY_NAVIGATION_PROBE"] == "1" {
                            Color.clear.frame(width: 1, height: 1)
                                .accessibilityElement(children: .ignore)
                                .accessibilityIdentifier("library.navigationDepth")
                                .accessibilityLabel("Project navigation depth")
                                .accessibilityValue(String(fixture.app.projectsPath.count))
                                .allowsHitTesting(false)
                        }
                    }
            } else if let error { Text(error).accessibilityIdentifier("store.error") }
            else { ProgressView() }
        }
        .preferredColorScheme(theme == "dark" ? .dark : .light)
        .onAppear {
            // Real-device captures must survive iOS waiting for a menu animation to settle.
            if previousIdleTimerDisabled == nil { previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            if let previousIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }
            previousIdleTimerDisabled = nil
        }
        .task {
            guard fixture == nil else { return }
            do {
                #if targetEnvironment(simulator)
                UserDefaults.standard.set(UIDevice.current.userInterfaceIdiom == .pad ? 16 : 14, forKey: "mindwire.editor.fontSize")
                UserDefaults.standard.set("tree", forKey: "mindwire.files.layout")
                #endif
                let data = try await AppStoreFixture(suiteName: (scenario == "library" || scenario == "source")
                    ? ProcessInfo.processInfo.environment["MINDWIRE_LIBRARY_TEST_SUITE"] : nil,
                    usesDefaultProjectIcon: scenario == "library", preloadChat: scenario != "chat-loading",
                    chatAgentType: ProcessInfo.processInfo.environment["MINDWIRE_CHAT_AGENT"] == "claude-code" ? .claudeCode : .codex)
                #if targetEnvironment(macCatalyst)
                if scenario == "desktop-chat" { data.app.openChat(data.chatID) }
                #endif
                if scenario == "chat" || scenario == "chat-loading" {
                    data.app.projectsPath = NavigationPath([AppRoute.projectDetail(id: data.projects[0].id), .chat(chatId: data.chatID)])
                } else if (scenario == "projects" && UIDevice.current.userInterfaceIdiom == .pad) || scenario == "switch" {
                    data.app.openProject(data.projects[0].id)
                } else if scenario == "workspaces" { data.app.selectedTab = .workspaces }
                else if scenario == "agents" { data.app.selectedTab = .agents }
                else if scenario == "backup" {
                    data.app.selectedTab = .settings
                    data.app.settingsPath = NavigationPath([SettingsRoute.backupSync])
                }
                if scenario == "desktop" {
                    #if targetEnvironment(simulator)
                    UserDefaults.standard.set(DesktopPointerMode.touchpad.rawValue, forKey: "mindwire.desktop.pointerMode")
                    UserDefaults.standard.set(false, forKey: "mindwire.desktop.alignTop")
                    #endif
                    let page = AppStoreDesktopPage()
                    let image = try await page.image()
                    desktop = DesktopModel(workspace: data.workspaces[1], stores: data.stores, provider: StoreDesktopProvider(),
                                           makeViewer: { StoreDesktopViewer(image: image) })
                }
                if scenario == "source", ProcessInfo.processInfo.environment["MINDWIRE_GIT_SCROLL_FIXTURE"] == "1" {
                    await data.git.useScrollFixture()
                }
                git = await data.gitModel()
                fixture = data
                showTransfer = scenario == "switch"
                showSource = scenario == "source" && ProcessInfo.processInfo.environment["MINDWIRE_GIT_MODAL_FIXTURE"] == "1"
                if scenario == "notification-intro" {
                    showNotificationIntro = data.stores.notificationSignInReminder.claim(owner: notificationReminderOwner,
                        signedOut: true, active: true, canPresent: true)
                }
                if scenario == "chat-loading" { await data.stores.chatSessions.model(for: data.chatID).load() }
            } catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private func content(_ data: AppStoreFixture, git: GitModel) -> some View {
        switch scenario {
        case "notification-intro":
            MainScene(repository: data.repository)
                .sheet(isPresented: $showNotificationIntro, onDismiss: {
                    data.stores.notificationSignInReminder.finish(.notNow, owner: notificationReminderOwner)
                }) {
                    NotificationConnectionSheet {
                        data.stores.notificationSignInReminder.finish(.signIn, owner: notificationReminderOwner)
                        showNotificationIntro = false
                    } onLater: {
                        data.stores.notificationSignInReminder.finish(.later, owner: notificationReminderOwner)
                        showNotificationIntro = false
                    } onCancel: {
                        data.stores.notificationSignInReminder.finish(.notNow, owner: notificationReminderOwner)
                        showNotificationIntro = false
                    }
                }
        case "notification-settings":
            NavigationStack {
                Form {
                    NotificationDeviceSection(push: data.push, refreshAccount: {})
                }
                .navigationTitle("Notifications")
            }
        case "review":
            SourceControlScreen(workspaceId: data.workspaces[0].id, path: "/projects/orbit", model: git,
                                selection: .init(change: StoreGitService.primary, staged: false))
        case "source":
            let screen = SourceControlScreen(workspaceId: data.workspaces[0].id, path: "/projects/orbit", model: git)
                .defaultAppStorage(data.stores.defaults)
            if ProcessInfo.processInfo.environment["MINDWIRE_GIT_MODAL_FIXTURE"] == "1" {
                NavigationStack {
                    Color(.systemGroupedBackground).navigationTitle("Orbit")
                }
                .sheet(isPresented: $showSource) { screen }
            } else { screen }
        case "files":
            FilesSheet(workspace: data.files, basePath: "/projects/orbit", title: "Orbit",
                       startPath: "/projects/orbit/src/components", projectId: data.projects[0].id,
                       initialFile: ProcessInfo.processInfo.environment["MINDWIRE_FILE_TEST_PATH"]
                            ?? "/projects/orbit/src/components/ActivityFeed.tsx")
        case "server-files":
            FilesSheet(workspace: data.files, basePath: "/", startPath: "~")
        case "desktop":
            DesktopScreen(workspaceId: data.workspaces[1].id, desktopName: "Orbit · Desktop",
                          repository: data.repository, initialModel: desktop)
        case "switch":
            MainScene(repository: data.repository)
                .sheet(isPresented: $showTransfer) {
                    ProjectSyncSheet(projectId: data.projects[0].id, repository: data.repository) { _ in }
                }
        default:
            MainScene(repository: data.repository)
        }
    }
}
#endif
