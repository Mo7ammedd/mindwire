import SwiftUI
import UserNotifications

/// Presentation is local to this device; persistent mutes belong to the workspace.
/// Each visible view owns a token so a disappearing view cannot clear its replacement.
@MainActor
final class PushPresentation {
    static let shared = PushPresentation()
    private var visibleChats: [UUID: String] = [:]

    func setVisibleChat(_ chatID: String?, owner: UUID) {
        visibleChats[owner] = chatID
    }

    func options(for target: PushTarget?, appIsActive: Bool, stores: Stores?) -> UNNotificationPresentationOptions {
        if case .app(let id) = target, let app = stores?.apps.get(id), app.notificationsMuted == true || app.archived { return [] }
        if case .chat(let id) = target {
            if appIsActive && visibleChats.values.contains(id) { return [] }
            if let stores, NotificationScope.chat(id).isMuted(in: stores) { return [] }
        } else if case .agent(let id) = target,
                  let stores, NotificationScope.agent(id).isMuted(in: stores) {
            return []
        }
        return [.banner, .sound, .badge]
    }
}

private struct VisibleChatForNotifications: ViewModifier {
    let chatID: String
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var app
    @State private var owner = UUID()
    @State private var appeared = false
    @State private var tab: AppTab?

    func body(content: Content) -> some View {
        content
            .onAppear {
                appeared = true
                tab = app.selectedTab
                update()
            }
            .onDisappear {
                appeared = false
                PushPresentation.shared.setVisibleChat(nil, owner: owner)
            }
            .onChange(of: chatID) { _, _ in update() }
            .onChange(of: scenePhase) { _, _ in update() }
            .onChange(of: app.selectedTab) { _, _ in update() }
    }

    private func update() {
        let visible = appeared && scenePhase == .active && tab == app.selectedTab
        PushPresentation.shared.setVisibleChat(visible ? chatID : nil, owner: owner)
    }
}

extension View {
    func visibleChatForNotifications(_ chatID: String) -> some View {
        modifier(VisibleChatForNotifications(chatID: chatID))
    }
}
