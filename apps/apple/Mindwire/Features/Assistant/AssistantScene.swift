import SwiftUI

/// Chat is the root, history is flat, and settings/setup are sheets. ChatScreen continues to
/// own the composer and transcript through the existing shared session and draft stores.
struct AssistantScene: View {
    var repository: WorkspaceRepository = .shared
    @Environment(AppModel.self) private var app
    @Environment(\.stores) private var stores
    @State private var sheet: Sheet?
    @State private var nextSheet: Sheet?
    @State private var started = false
    @State private var creating = false
    @State private var createTask: Task<Void, Never>?
    @State private var createAfterDismiss = false
    @State private var error: String?
    @State private var selectedChatWasPresent = false

    private enum Sheet: String, Identifiable {
        case history, settings, setup
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let id = app.assistantChatID {
                    ChatScreen(chatId: id).id(id)
                } else {
                    welcome
                }
            }
            .toolbar {
                AppToolbarItem(placement: .topBarLeading) {
                    Button { sheet = .history } label: { AppIcon(.sidebarOpen) }
                        .tint(.primary)
                        .accessibilityLabel(t("assistant.history"))
                }
                AppToolbarItem(placement: .topBarTrailing) {
                    Button(action: newChat) { AppIcon(Icon.edit) }
                        .tint(.primary)
                        .disabled(creating)
                        .accessibilityLabel(t("assistant.newChat"))
                }
            }
        }
        .sheet(item: $sheet, onDismiss: {
            if let next = nextSheet { nextSheet = nil; sheet = next }
            else if createAfterDismiss { createAfterDismiss = false; newChat() }
        }) { item in
            switch item {
            case .history:
                ChatHistorySheet(onOpenChat: { chat in app.openChat(chat.id) },
                    onNewChat: { createAfterDismiss = true; sheet = nil },
                    onSettings: { nextSheet = .settings; sheet = nil })
            case .settings:
                NavigationStack {
                    SettingsScreen().withAppRoutes(repository: repository)
                        .toolbar {
                            AppToolbarItem(placement: .confirmationAction) {
                                Button(t("common.done")) { sheet = nil }.tint(.primary)
                            }
                        }
                }
            case .setup:
                AssistantSetupScreen(repository: repository) {
                    createAfterDismiss = true
                    sheet = nil
                }
            }
        }
        .alert(t("assistant.chatError"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(t("common.retry"), action: newChat)
            Button(t("common.cancel"), role: .cancel) {}
        } message: { Text(error ?? "") }
        .task {
            guard !started else { return }
            started = true
            selectedChatWasPresent = app.assistantChatID.flatMap(stores.chats.get) != nil
            if app.assistantChatID == nil { newChat() }
        }
        .onChange(of: app.assistantChatID) { _, id in
            selectedChatWasPresent = id.flatMap(stores.chats.get) != nil
        }
        .observeWorkspaceCache {
            if let id = app.assistantChatID {
                if stores.chats.get(id) != nil { selectedChatWasPresent = true }
                else if selectedChatWasPresent { app.assistantChatID = nil }
            }
        }
        .onDisappear { createTask?.cancel(); createTask = nil }
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label { Text(t("assistant.welcome")) } icon: { AppLogo(size: 40) }
        } description: {
            Text(t("assistant.welcome.body"))
        } actions: {
            if creating { ProgressView(t("assistant.opening")) }
            else {
                Button(t(stores.experience.assistantAgentID == nil ? "assistant.setup" : "assistant.newChat"), action: newChat)
                    .buttonStyle(.glassProminent).tint(Palette.accent)
            }
        }
        .navigationTitle("Mindwire")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func newChat() {
        guard !creating else { return }
        guard let agent = stores.experience.assistantAgentID.flatMap(stores.agents.get),
              let workspaceID = agent.workspaceId,
              repository.get(workspaceID) != nil,
              let projectID = stores.experience.projectIDs[workspaceID],
              let project = stores.projects.get(projectID), project.workspaceId == workspaceID else {
            sheet = .setup
            return
        }
        creating = true
        let previousChatID = app.assistantChatID
        createTask = Task {
            defer { creating = false; createTask = nil }
            do {
                let chat = try await stores.workspaceData.createChat(agentId: agent.id, projectId: project.id)
                guard !Task.isCancelled, app.usesAssistant, app.assistantChatID == previousChatID else { return }
                app.openChat(chat.id)
            } catch {
                if !error.isRequestCancellation { self.error = error.localizedDescription }
            }
        }
    }
}
