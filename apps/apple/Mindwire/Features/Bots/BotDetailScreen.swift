import SwiftUI

struct BotDetailScreen: View {
    let botId: String
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @Environment(\.appExperienceMode) private var experienceMode
    @Environment(AppModel.self) private var app
    @State private var bot: AssistantBot?
    @State private var chats: [Chat] = []
    @State private var snapshots: [String: ChatListRowSnapshot] = [:]
    @State private var editing = false
    @State private var iconPicker = false
    @State private var showingConnections = false
    @State private var running = false
    @State private var error: String?

    var body: some View {
        Group {
            if let bot { content(bot) }
            else { ContentUnavailableView(t("bots.missing"), icon: Icon.agents) }
        }
        .onAppear(perform: reload)
        .observeWorkspaceCache(reload)
        .onChange(of: stores.bots.revision) { reload() }
        .observeChatActivity(agentIds: bot.map { [$0.agentId] } ?? [])
        .task(id: bot?.workspaceId) {
            if let id = bot?.workspaceId, let workspace = repository.get(id) {
                await stores.workspaceData.refreshIfNeeded(workspace)
            }
        }
        .sheet(isPresented: $editing, onDismiss: reload) { if let bot { BotEditorScreen(bot: bot) } }
        .sheet(isPresented: $iconPicker, onDismiss: reload) { if let bot { AssistantBotIconPicker(bot: bot) } }
        .sheet(isPresented: $showingConnections) { BotConnectionsScreen(repository: repository) }
        .alert(t("assistant.bots.saveFailed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(t("common.ok"), role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func content(_ bot: AssistantBot) -> some View {
        List {
            Section {
                VStack(spacing: 12) {
                    AssistantBotAvatar(botId: bot.id, icon: bot.icon, size: 66)
                    Text(bot.name).font(.title2.weight(.semibold))
                    if !bot.purpose.isEmpty { Text(bot.purpose).font(.subheadline).foregroundStyle(.secondary) }
                    if let workspace = repository.get(bot.workspaceId) {
                        Text(workspace.name).font(.caption).foregroundStyle(.tertiary)
                    }
                    if bot.archived {
                        Button(t("assistant.bots.restore")) { archive(bot, false) }
                    } else {
                        Button { openChat(bot) } label: { Label(t("assistant.newChat"), systemImage: "plus") }
                            .buttonStyle(.borderedProminent).tint(Palette.accent)
                    }
                }
                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical, 20)
            }
            .listRowBackground(Color.clear)
            if !chats.isEmpty {
                Section(t("assistant.history")) {
                    ForEach(chats) { chat in
                        ChatListRow(chat: chat, snapshot: snapshots[chat.id], onChanged: reload)
                    }
                }
            }
            Section {
                Button { editing = true } label: { Label(t("bots.edit.title"), systemImage: "pencil") }
                NavigationLink {
                    NotificationPreferencesScreen(scope: .bot(bot.id))
                } label: { Label(t("notifications.title"), icon: .bell) }
                Button { openChat(bot, assisted: true) } label: { Label(t("bots.edit.withMindwire"), systemImage: "bubble.left.and.bubble.right") }
                if bot.isMaster {
                    Button { showingConnections = true } label: { Label(t("bots.connections.title"), systemImage: "network") }
                }
                if experienceMode == .developer {
                    NavigationLink(value: AppRoute.agentDetail(agentId: bot.agentId)) {
                        Label(t("bots.engineSettings"), systemImage: "slider.horizontal.3")
                    }
                }
            }
            .tint(.primary)
        }
        .listStyle(.insetGrouped)
        .disabled(running)
        .navigationTitle(bot.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { iconPicker = true } label: { Label(t("assistant.icons.change"), systemImage: "face.smiling") }
                    if !bot.isMaster {
                        Button { archive(bot, !bot.archived) } label: {
                            Label(t(bot.archived ? "assistant.bots.restore" : "assistant.bots.archive"), systemImage: "archivebox")
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .refreshable {
            if let workspace = repository.get(bot.workspaceId) { await stores.workspaceData.refresh(workspace) }
            reload()
        }
    }

    private func reload() {
        bot = stores.bots.get(botId)
        chats = stores.chatsByRecency().filter { $0.botId == botId }
        snapshots = Dictionary(uniqueKeysWithValues: chats.map {
            ($0.id, ChatListRowSnapshot(notificationsMuted: NotificationScope.chat($0.id).isMuted(in: stores)))
        })
    }

    private func openChat(_ bot: AssistantBot, assisted: Bool = false) {
        guard !running else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            do {
                let chat = try await (assisted
                    ? BotConversationActions.configurationChat(for: bot, stores: stores)
                    : BotConversationActions.createChat(for: bot, stores: stores))
                app.push(.chat(chatId: chat.id))
            } catch { if !error.isRequestCancellation { self.error = error.localizedDescription } }
        }
    }

    private func archive(_ bot: AssistantBot, _ value: Bool) {
        guard !running else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            do {
                try await stores.workspaceData.editBot(bot, edit: .init(expectedRevision: bot.revision, archived: value))
                reload()
            } catch { self.error = error.localizedDescription }
        }
    }
}
