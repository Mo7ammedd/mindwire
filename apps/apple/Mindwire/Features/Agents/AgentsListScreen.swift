import SwiftUI

/// Saved bots and used plain agents share one inventory across connected computers.
/// A harness used only by bots remains a base connection, rather than another persona.
struct AgentsListScreen: View {
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @Environment(\.appExperienceMode) private var experienceMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var app
    @Environment(\.sidebarNavigation) private var sidebar
    @State private var entries: [Entry] = []
    @State private var search = ""
    @State private var showCreation = false
    @State private var showHistory = false
    @State private var showArchived = false
    @State private var showConnections = false
    @State private var schedulingBot: AssistantBot?
    @State private var historyAgent: Agent?
    @State private var pendingBot: AssistantBot?
    @State private var pendingAssistance = false
    @State private var error: String?
    @State private var opening = false
    @State private var activity = ChatActivityStore.shared

    private typealias Entry = AgentListEntry

    private var visible: [Entry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter {
            $0.identity.archived == showArchived && (query.isEmpty || $0.identity.name.localizedStandardContains(query)
                || $0.identity.purpose.localizedStandardContains(query) || $0.workspace.name.localizedStandardContains(query))
        }
    }

    var body: some View {
        Group {
            if usesCards {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 150),
                                                 spacing: EntityCardStyle.spacing)],
                              spacing: EntityCardStyle.spacing) {
                        ForEach(visible) { entry in destination(entry) }
                    }
                    .padding(EntityCardStyle.padding)
                }
                .accessibilityIdentifier("bots.grid")
            } else {
                List {
                    ForEach(visible) { entry in
                        destination(entry)
                            .listRowInsets(.init(top: 3, leading: 14, bottom: 3, trailing: 14))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .background(Palette.bg)
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
        .principalBrand(visible: !usesCards)
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
        .onChange(of: stores.chats.revision) { reload() }
        .onChange(of: experienceMode) { reload() }
        .onChange(of: repository.revision) { reload() }
        .task { await repository.refreshIfNeeded(); await stores.workspaceData.refreshAll(repository.all); reload() }
        .refreshable { await repository.refreshChecks(); await stores.workspaceData.refreshAll(repository.all, force: true); reload() }
        .observeChatActivity(agentIds: Array(Set(entries.map(\.identity.agentId))))
        .sheet(isPresented: $showCreation, onDismiss: finishCreation) {
            BotCreationScreen(repository: repository, onCreated: { bot in
                pendingBot = bot; pendingAssistance = false
            }, onAskMindwire: { bot in
                pendingBot = bot; pendingAssistance = true
            })
        }
        .sheet(isPresented: $showHistory, onDismiss: reload) { ChatHistorySheet() }
        .sheet(isPresented: $showConnections) { BotConnectionsScreen(repository: repository) }
        .sheet(item: $schedulingBot) { bot in BotSchedulesScreen(bot: bot) }
        .sheet(item: $historyAgent) { agent in ChatHistorySheet(agentId: agent.id, plainOnly: true) }
        .alert(t("assistant.bots.saveFailed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(t("common.ok"), role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var usesCards: Bool { experienceMode == .developer && !ApplePlatform.isDesktop && sidebar == nil }

    private func isWorking(_ entry: Entry) -> Bool {
        entry.chatIDs.contains { activity.status($0) == .running }
    }

    private func destination(_ entry: Entry) -> some View {
        let route = entry.identity.bot.map { AppRoute.botDetail(botId: $0.id) }
            ?? .agentDetail(agentId: entry.identity.agentId)
        let selected = sidebar?.selected == .app(route)
        return RootNavigationLink(value: route, usesDefaultRowBackground: false) {
            if usesCards { card(entry) }
            else {
                label(entry)
                    .padding(14)
                    .background(selected ? Palette.accentSoft : Color.clear, in: .rect(cornerRadius: 22))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let bot = entry.identity.bot {
                Button("Schedules", icon: .calendar) { schedulingBot = bot }
                    .accessibilityIdentifier("bot.schedules")
            } else if let agent = entry.identity.agent {
                Button(t("assistant.history"), icon: Icon.history) { historyAgent = agent }
                Button(t("tabs.settings"), icon: Icon.settings) { app.openAgent(agent.id) }
            }
        }
        .accessibilityIdentifier(entry.identity.bot.map { "bots.bot." + $0.id } ?? "agents.plain." + entry.identity.agentId)
        .accessibilityValue(isWorking(entry) ? t("chat.running") : "")
    }

    private func card(_ entry: Entry) -> some View {
        let working = isWorking(entry)
        let tint = entry.identity.bot.map { AssistantBotIcon.resolve(botId: $0.id, icon: $0.icon).color.fill } ?? Palette.accent
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                AgentIdentityAvatar(identity: entry.identity, size: 40, isWorking: working)
                Spacer(minLength: 8)
                if entry.identity.bot != nil, let agent = stores.agents.get(entry.identity.agentId) {
                    AgentLogo(id: agent.agentType, size: 18)
                        .padding(6)
                        .background(Palette.surface.opacity(0.8), in: .circle)
                        .accessibilityLabel(agent.typeDisplayName)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.identity.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text(entry.identity.purpose)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 64, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                AppIcon(entry.workspace.isCloud ? .cloud : .laptop, size: 12, decorative: true)
                Text(entry.workspace.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if working {
                    Circle().fill(tint).frame(width: 5, height: 5).accessibilityHidden(true)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 210 : 168, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.surface)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [tint.opacity(colorScheme == .dark ? 0.10 : 0.08), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .clipShape(.rect(cornerRadius: 22))
                }
        }
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }

    private func label(_ entry: Entry) -> some View {
        HStack(spacing: 14) {
            AgentIdentityAvatar(identity: entry.identity, size: 46, isWorking: isWorking(entry))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.identity.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let chat = entry.latest {
                        if activity.status(chat.id) == .running { ChatRunStatusLabel(status: .running, startedAt: activity.runStartedAt(chat.id)) }
                        else if let date = activity.lastActivity(chat) { RelativeTimestamp(date: date) }
                    }
                }
                Text(entry.latest.map { activity.title($0) } ?? entry.identity.purpose.nilIfEmpty ?? entry.workspace.name)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if experienceMode == .developer {
                    HStack(spacing: 5) {
                        if entry.identity.bot != nil, let agent = stores.agents.get(entry.identity.agentId) {
                            AgentLogo(id: agent.agentType, size: 13).accessibilityHidden(true)
                            Text(agent.typeDisplayName)
                            Text("·")
                        }
                        Text(entry.workspace.name)
                    }
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .contentShape(.rect)
    }

    private func reload() {
        entries = AgentListEntry.make(bots: stores.bots.list(), agents: stores.agents.list(),
            chats: stores.chats.list(), workspaces: repository.all,
            preferredAgentId: stores.experience.assistantAgentID, projectIDs: stores.experience.projectIDs,
            includePlain: experienceMode == .developer)
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
