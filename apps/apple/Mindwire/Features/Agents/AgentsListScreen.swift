import SwiftUI

/// Bot identities are flat across connected computers. Engine profiles remain available in
/// each computer's controls, without making the same engine appear as several personas.
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
    @State private var pendingBot: AssistantBot?
    @State private var pendingAssistance = false
    @State private var error: String?
    @State private var opening = false
    @State private var activity = ChatActivityStore.shared

    private struct Entry: Identifiable {
        let bot: AssistantBot
        let computer: String
        let latest: Chat?
        let chatIDs: [String]
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
        .sheet(item: $schedulingBot) { bot in BotSchedulesScreen(bot: bot) }
        .alert(t("assistant.bots.saveFailed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(t("common.ok"), role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var usesCards: Bool { experienceMode == .developer && !ApplePlatform.isDesktop && sidebar == nil }

    private func isWorking(_ entry: Entry) -> Bool {
        entry.chatIDs.contains { activity.status($0) == .running }
    }

    private func destination(_ entry: Entry) -> some View {
        let selected = sidebar?.selected == .app(.botDetail(botId: entry.id))
        return RootNavigationLink(value: AppRoute.botDetail(botId: entry.id), usesDefaultRowBackground: false) {
            if usesCards { card(entry) }
            else {
                label(entry)
                    .padding(14)
                    .background(selected ? Palette.accentSoft : Color.clear, in: .rect(cornerRadius: 22))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Schedules", icon: .calendar) { schedulingBot = entry.bot }
                .accessibilityIdentifier("bot.schedules")
        }
        .accessibilityIdentifier("bots.bot.\(entry.id)")
        .accessibilityValue(isWorking(entry) ? t("chat.running") : "")
    }

    private func card(_ entry: Entry) -> some View {
        let working = isWorking(entry)
        let tint = AssistantBotIcon.resolve(botId: entry.id, icon: entry.bot.icon).color.fill
        let computer = repository.all.first { $0.id == entry.bot.workspaceId }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                AssistantBotAvatar(botId: entry.id, icon: entry.bot.icon, size: 40, isWorking: working)
                Spacer(minLength: 8)
                if let agent = stores.agents.get(entry.bot.agentId) {
                    AgentLogo(id: agent.agentType, size: 18)
                        .padding(6)
                        .background(Palette.surface.opacity(0.8), in: .circle)
                        .accessibilityLabel(agent.typeDisplayName)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.bot.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text(entry.bot.purpose)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 64, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                AppIcon(computer?.isCloud == true ? .cloud : .laptop, size: 12, decorative: true)
                Text(entry.computer).lineLimit(1).truncationMode(.middle)
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
            AssistantBotAvatar(botId: entry.id, icon: entry.bot.icon, size: 46, isWorking: isWorking(entry))
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
                if experienceMode == .developer {
                    HStack(spacing: 5) {
                        if let agent = stores.agents.get(entry.bot.agentId) {
                            AgentLogo(id: agent.agentType, size: 13).accessibilityHidden(true)
                            Text(agent.typeDisplayName)
                            Text("·")
                        }
                        Text(entry.computer)
                    }
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .contentShape(.rect)
    }

    private func reload() {
        let workspaces = Dictionary(repository.all.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
        var latest: [String: Chat] = [:]
        var chatIDs: [String: [String]] = [:]
        for chat in stores.chatsByRecency() {
            if let id = chat.botId {
                if latest[id] == nil { latest[id] = chat }
                chatIDs[id, default: []].append(chat.id)
            }
        }
        let connected = stores.bots.list().filter { workspaces[$0.workspaceId] != nil }
        let bots = BotPresentation.visibleBots(connected, preferredAgentId: stores.experience.assistantAgentID,
                                              projectIDs: stores.experience.projectIDs)
        entries = bots.compactMap { bot in
            guard let computer = workspaces[bot.workspaceId] else { return nil }
            return Entry(bot: bot, computer: computer, latest: latest[bot.id], chatIDs: chatIDs[bot.id] ?? [])
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
