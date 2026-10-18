import SwiftUI

/// Bot identities are flat across connected computers. Engine profiles remain available in
/// each computer's controls, without making the same engine appear as several personas.
struct AgentsListScreen: View {
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.sidebarNavigation) private var sidebar
    @State private var entries: [Entry] = []
    @State private var search = ""
    @State private var showCreation = false
    @State private var showHistory = false
    @State private var showArchived = false
    @State private var showConnections = false
    @State private var pendingBot: AssistantBot?
    @State private var pendingAssistance = false
    @State private var error: String?
    @State private var opening = false
    @State private var activity = ChatActivityStore.shared

    private struct Entry: Identifiable {
        let bot: AssistantBot
        let computer: String
        let latest: Chat?
        var id: String { bot.id }
    }

    private var visible: [Entry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter {
            $0.bot.archived == showArchived && (query.isEmpty || $0.bot.name.localizedStandardContains(query)
                || $0.bot.purpose.localizedStandardContains(query) || $0.computer.localizedStandardContains(query))
        }
    }

    var body: some View {
        List {
            ForEach(visible) { entry in
                let selected = sidebar?.selected == .app(.botDetail(botId: entry.id))
                RootNavigationLink(value: AppRoute.botDetail(botId: entry.id), usesDefaultRowBackground: false) {
                    label(entry)
                        .padding(.horizontal, 14).padding(.vertical, 14)
                        .background(selected ? Palette.accentSoft : Color.clear, in: .rect(cornerRadius: 22))
                }
                .buttonStyle(.plain)
                .listRowInsets(.init(top: 3, leading: 14, bottom: 3, trailing: 14))
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                .accessibilityIdentifier("bots.bot.\(entry.id)")
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Palette.bg)
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(t(showArchived ? "assistant.bots.archived" : "bots.empty.title"), icon: Icon.agents)
                } description: {
                    if search.isEmpty && !showArchived { Text(t("bots.empty.body")) }
                } actions: {
                    if search.isEmpty && !showArchived {
                        Button(t("assistant.bots.create")) { showCreation = true }
                            .buttonStyle(.borderedProminent).tint(Palette.accent).controlSize(.large)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: t("bots.search"))
        .navigationTitle(t("assistant.bots.title"))
        .principalBrand()
        .toolbar {
            AppToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button { showConnections = true } label: { Label(t("bots.connections.title"), systemImage: "network") }
                    Button { showHistory = true } label: { Label(t("chat.all.title"), icon: Icon.history) }
                    Toggle(t("assistant.bots.archived"), isOn: $showArchived)
                } label: { AppIcon(Icon.ellipsis) }
                .tint(.primary).accessibilityLabel(t("bots.options"))
            }
            AppToolbarItem(placement: .topBarTrailing) {
                Button { showCreation = true } label: { AppIcon(Icon.plus) }
                    .tint(.primary).accessibilityLabel(t("assistant.bots.create"))
            }
        }
        .onAppear(perform: reload)
        .observeWorkspaceCache(reload)
        .onChange(of: stores.bots.revision) { reload() }
        .onChange(of: repository.revision) { reload() }
        .task { await repository.refreshIfNeeded(); await stores.workspaceData.refreshAll(repository.all); reload() }
        .refreshable { await repository.refreshChecks(); await stores.workspaceData.refreshAll(repository.all, force: true); reload() }
        .observeChatActivity(agentIds: Array(Set(entries.map(\.bot.agentId))))
        .sheet(isPresented: $showCreation, onDismiss: finishCreation) {
            BotCreationScreen(repository: repository, onCreated: { bot in
                pendingBot = bot; pendingAssistance = false
            }, onAskMindwire: { bot in
                pendingBot = bot; pendingAssistance = true
            })
        }
        .sheet(isPresented: $showHistory, onDismiss: reload) { ChatHistorySheet() }
        .sheet(isPresented: $showConnections) { BotConnectionsScreen(repository: repository) }
        .alert(t("assistant.bots.saveFailed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(t("common.ok"), role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func label(_ entry: Entry) -> some View {
        HStack(spacing: 14) {
            AssistantBotAvatar(botId: entry.id, icon: entry.bot.icon, size: 46)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.bot.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let chat = entry.latest {
                        if activity.status(chat.id) == .running { ChatRunStatusLabel(status: .running, startedAt: activity.runStartedAt(chat.id)) }
                        else if let date = activity.lastActivity(chat) { RelativeTimestamp(date: date) }
                    }
                }
                Text(entry.latest.map { activity.title($0) } ?? entry.bot.purpose.nilIfEmpty ?? entry.computer)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(.rect)
    }

    private func reload() {
        let workspaces = Dictionary(repository.all.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
        var latest: [String: Chat] = [:]
        for chat in stores.chatsByRecency() {
            if let id = chat.botId, latest[id] == nil { latest[id] = chat }
        }
        let connected = stores.bots.list().filter { workspaces[$0.workspaceId] != nil }
        let bots = BotPresentation.visibleBots(connected, preferredAgentId: stores.experience.assistantAgentID,
                                              projectIDs: stores.experience.projectIDs)
        entries = bots.compactMap { bot in
            guard let computer = workspaces[bot.workspaceId] else { return nil }
            return Entry(bot: bot, computer: computer, latest: latest[bot.id])
        }.sorted {
            if $0.bot.isMaster != $1.bot.isMaster { return $0.bot.isMaster }
            let left = $0.latest?.lastActivityAt ?? $0.latest?.createdAt ?? $0.bot.createdAt
            let right = $1.latest?.lastActivityAt ?? $1.latest?.createdAt ?? $1.bot.createdAt
            if left != right { return left > right }
            return $0.bot.name.localizedStandardCompare($1.bot.name) == .orderedAscending
        }
    }

    private func finishCreation() {
        reload()
        guard let bot = pendingBot else { return }
        let assisted = pendingAssistance
        pendingBot = nil; pendingAssistance = false
        if !assisted { app.push(.botDetail(botId: bot.id)); return }
        guard !opening else { return }
        opening = true
        Task { @MainActor in
            defer { opening = false }
            do {
                let chat = try await BotConversationActions.configurationChat(for: bot, stores: stores)
                app.openChat(chat.id)
            } catch { if !error.isRequestCancellation { self.error = error.localizedDescription } }
        }
    }
}
