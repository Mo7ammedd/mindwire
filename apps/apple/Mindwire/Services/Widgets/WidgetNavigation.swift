import SwiftUI

/// Widget links enter the same catalog, app browser and bot conversation actions as the UI.
struct WidgetNavigation: ViewModifier {
    var onOtherURL: ((URL) -> Void)? = nil
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingCatalog = false
    @State private var conversationTask: Task<Void, Never>?
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                guard let link = WidgetLink(url: url) else { onOtherURL?(url); return }
                switch link {
                case .app(let id): app.open(.app(id))
                case .chat(let id):
                    app.presentedAppShortcut = nil
                    showingCatalog = false
                    app.assistantAppsVisible = false
                    app.open(.chat(id))
                case .apps:
                    app.presentedAppShortcut = nil
                    if app.usesAssistant { app.assistantAppsVisible = true }
                    else if !stores.experience.needsInitialSetup { showingCatalog = true }
                case .ask: openAssistant()
                }
            }
            .task(id: publication) {
                await WidgetCatalogPublisher.publish(stores: stores, workspaces: repository.all,
                                                     activity: publication.activity)
            }
            .sheet(isPresented: $showingCatalog) {
                NavigationStack {
                    AppsCatalogScreen()
                        .navigationTitle("Apps").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            AppToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingCatalog = false }.tint(.primary)
                            }
                        }
                }
            }
            .alert("Couldn’t open Mindwire", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Try again", action: openAssistant)
                Button("Cancel", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .onDisappear { conversationTask?.cancel(); conversationTask = nil }
    }

    private var publication: Publication {
        Publication(revisions: [stores.apps.revision, stores.workspaces.revision, stores.bots.revision, stores.chats.revision],
                    workspaceRevision: repository.revision, agentID: stores.experience.assistantAgentID,
                    active: scenePhase != .background, activity: WidgetActivityProjection.read(stores: stores))
    }

    private struct Publication: Equatable {
        let revisions: [UInt64]
        let workspaceRevision: Int
        let agentID: String?
        let active: Bool
        let activity: [WidgetChatActivity]
    }

    private func openAssistant() {
        guard conversationTask == nil, !stores.experience.needsInitialSetup else { return }
        conversationTask = Task {
            defer { conversationTask = nil }
            do {
                let bot: AssistantBot
                if let saved = stores.bots.list().first(where: {
                    $0.isMaster && !$0.archived && $0.agentId == stores.experience.assistantAgentID
                }) { bot = saved }
                else {
                    guard let agent = stores.experience.assistantAgentID.flatMap(stores.agents.get),
                          let workspaceID = agent.workspaceId,
                          let projectID = stores.experience.projectIDs[workspaceID] else {
                        throw BackendError.message("Set up your Mindwire bot in the app first.")
                    }
                    bot = try await stores.workspaceData.ensureGeneralBots(agentId: agent.id, projectId: projectID)
                }
                let chat: Chat
                if let existing = stores.chats.list().filter({ $0.botId == bot.id })
                    .max(by: { $0.lastActivityAt < $1.lastActivityAt }) { chat = existing }
                else { chat = try await BotConversationActions.createChat(for: bot, stores: stores) }
                try Task.checkCancellation()
                app.presentedAppShortcut = nil
                showingCatalog = false
                app.assistantAppsVisible = false
                app.openChat(chat.id)
            } catch {
                if !error.isRequestCancellation { self.error = error.localizedDescription }
            }
        }
    }
}
