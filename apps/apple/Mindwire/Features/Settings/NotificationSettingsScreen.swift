import SwiftUI
import UIKit
import UserNotifications

struct NotificationSettingsScreen: View {
    @Environment(\.stores) private var stores
    @State private var bots: [AssistantBot] = []

    var body: some View {
        List {
            NotificationDeviceSection()
            Section {
                ForEach(bots) { bot in
                    NavigationLink {
                        NotificationPreferencesScreen(scope: .bot(bot.id))
                    } label: {
                        HStack(spacing: 12) {
                            AssistantBotAvatar(botId: bot.id, icon: bot.icon, size: ApplePlatform.isDesktop ? 28 : 34)
                            LabeledContent(bot.name,
                                value: t(bot.notificationsMuted == true ? "notifications.muted" : "notifications.on"))
                        }
                    }
                    .accessibilityIdentifier("notifications.bot.\(bot.id)")
                }
                if bots.isEmpty {
                    Text("Your agents will appear here.").foregroundStyle(.secondary)
                }
            } header: {
                Text(t("tabs.agents"))
            } footer: {
                Text(t("notifications.chatHint"))
            }
        }
        .navigationTitle(t("notifications.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .observeWorkspaceCache(reload)
        .onChange(of: stores.bots.revision) { reload() }
    }

    private func reload() {
        let workspaceIDs = Set(WorkspaceRepository.shared.all.map(\.id))
        let connected = stores.bots.list().filter { !$0.archived && workspaceIDs.contains($0.workspaceId) }
        bots = BotPresentation.visibleBots(connected, preferredAgentId: stores.experience.assistantAgentID,
                                          projectIDs: stores.experience.projectIDs).sorted {
            if $0.isMaster != $1.isMaster { return $0.isMaster }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// iOS owns the device-wide switch, sounds and delivery style, including background delivery.
struct NotificationDeviceSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var requesting = false
    @State private var showLogin = false
    private let push: LivePushService
    private let refreshAccount: () async -> Void

    init(push: LivePushService? = nil,
         refreshAccount: @escaping () async -> Void = { await MindwireAuth.shared.refresh() }) {
        self.push = push ?? .shared
        self.refreshAccount = refreshAccount
    }

    var body: some View {
        Section {
            LabeledContent(t("notifications.device"), value: statusLabel)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(t("notifications.device"))
                .accessibilityValue(statusLabel)
                .accessibilityIdentifier("notification-device-permission")
            LabeledContent("Delivery") {
                HStack(spacing: 6) {
                    if push.state == .registering || push.state == .checking { ProgressView().controlSize(.mini) }
                    Text(deliveryLabel).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Delivery")
            .accessibilityValue(deliveryLabel)
            .accessibilityIdentifier("notification-delivery-status")
            if push.state == .signInRequired {
                Button { showLogin = true } label: {
                    Label("Sign in for notifications", icon: .login)
                }
                .accessibilityIdentifier("notification-sign-in")
            } else if push.authorizationStatus == .notDetermined {
                Button(t("notifications.enable")) {
                    Task { await refresh() }
                }
                .disabled(requesting)
            }
            if push.state.needsRetry {
                Button { Task { await refresh() } } label: {
                    Label("Retry connection", icon: .refresh)
                }
                .disabled(requesting)
                .accessibilityIdentifier("notification-retry")
            }
            if push.authorizationStatus != nil, push.authorizationStatus != .notDetermined {
                Button(t("notifications.openSettings")) {
                    guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            if case .failed(let message) = push.state {
                DisclosureGroup("Details") {
                    Text(message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } footer: {
            Text(deliveryHint)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresh()
        }
        .mindwireLoginSheet(isPresented: $showLogin) {
            Task { await refresh() }
        }
    }

    private func refresh() async {
        guard !requesting else { return }
        requesting = true
        defer { requesting = false }
        await refreshAccount()
        await push.start()
    }

    private var statusLabel: String {
        switch push.authorizationStatus {
        case .authorized, .ephemeral: return "Allowed"
        case .provisional: return t("notifications.quiet")
        case .denied: return t("notifications.off")
        case .notDetermined: return t("notifications.notEnabled")
        default: return t("workspace.checking")
        }
    }

    private var deliveryLabel: String {
        switch push.state {
        case .checking: "Checking…"
        case .signInRequired: "Sign in required"
        case .permissionRequired: "Permission required"
        case .permissionDenied: ApplePlatform.isDesktop ? "Off in System Settings" : "Off in iOS Settings"
        case .waitingForToken: "Waiting for this device"
        case .registering: "Connecting…"
        case .ready: "Ready"
        case .failed: "Connection needs attention"
        }
    }

    private var deliveryHint: String {
        switch push.state {
        case .signInRequired:
            "Sign in to Mindwire to receive alerts from your Mac, servers and cloud workspaces. Your SSH connections keep working without this login."
        case .waitingForToken, .failed:
            "Notification setup retries automatically while Mindwire is open. You can retry now."
        default:
            "Alerts for the chat you’re viewing are silenced. Other chats can still notify you."
        }
    }
}

/// Reused from app settings, agent settings, the chat menu and every chat list.
struct NotificationPreferencesScreen: View {
    let scope: NotificationScope
    @Environment(\.stores) private var stores
    @State private var title = ""
    @State private var muted = false
    @State private var parent: NotificationScope?
    @State private var exists = false
    @State private var pending: Bool?
    @State private var error: String?
    @State private var showLogin = false

    private var parentMuted: Bool { parent?.isMuted(in: stores) == true }
    private var requiresSignIn: Bool {
        scope.workspaceID(in: stores).map { WorkspaceRepository.shared.requiresSignIn(for: $0) } ?? false
    }

    var body: some View {
        Form {
            NotificationDeviceSection()
            if requiresSignIn {
                Section { MindwireSignInRow(bodyKey: "workspace.signIn.body") { showLogin = true } }
            }
            Section {
                Toggle(isOn: Binding(get: { !parentMuted && (pending ?? !muted) }, set: save)) {
                    HStack {
                        Text(t("notifications.allow"))
                        if pending != nil { ProgressView().controlSize(.mini).accessibilityLabel(t("notifications.saving")) }
                    }
                }
                .disabled(pending != nil || parentMuted || !exists || requiresSignIn)
                .accessibilityIdentifier("notification-scope-toggle")
            } header: {
                Text(title)
            } footer: {
                Text(t(parentMuted ? "notifications.agentMuted" : (parent == nil ? "notifications.agentHint" : "notifications.chatScopeHint")))
            }
            if let parent {
                Section {
                    NavigationLink {
                        NotificationPreferencesScreen(scope: parent)
                    } label: {
                        Label(parent.title(in: stores) ?? t("notifications.agentSettings"), icon: .bell)
                    }
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(t("notifications.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .observeWorkspaceCache(reload)
        .onChange(of: stores.bots.revision) { reload() }
        .task { await refresh() }
        .refreshable { await refresh(force: true) }
        .mindwireLoginSheet(isPresented: $showLogin) {
            Task { await WorkspaceRepository.shared.refresh(); await refresh() }
        }
    }

    private func reload() {
        let name = scope.title(in: stores)
        exists = name != nil
        title = name ?? t("notifications.unavailable")
        muted = scope.savedMute(in: stores) == true
        parent = scope.parent(in: stores)
    }

    private func refresh(force: Bool = false) async {
        guard let id = scope.workspaceID(in: stores), let workspace = WorkspaceRepository.shared.get(id) else { return }
        if force { await stores.workspaceData.refresh(workspace) }
        else { await stores.workspaceData.refreshIfNeeded(workspace) }
        reload()
    }

    private func save(_ allowed: Bool) {
        guard pending == nil else { return }
        pending = allowed
        error = nil
        Task {
            defer { pending = nil; reload() }
            do { try await stores.workspaceData.setNotificationsMuted(!allowed, for: scope) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct ChatNotificationSettingsSheet: View {
    let chatID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NotificationPreferencesScreen(scope: .chat(chatID))
                .toolbar {
                    AppToolbarItem(placement: .confirmationAction) {
                        Button(t("common.done")) { dismiss() }.tint(.primary)
                    }
                }
        }
    }
}
