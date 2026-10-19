import SwiftUI

/// A saved persona and a plain harness share the same chat creation path and workspace checks.
enum ChatAgentChoice: Identifiable {
    case bot(AssistantBot), plain(Agent)

    var id: String {
        switch self {
        case .bot(let bot): "bot:" + bot.id
        case .plain(let agent): "agent:" + agent.id
        }
    }
    var agentId: String {
        switch self {
        case .bot(let bot): bot.agentId
        case .plain(let agent): agent.id
        }
    }
    var botId: String? { if case .bot(let bot) = self { bot.id } else { nil } }
}

/// One acknowledged creation per sheet, including its dismissal animation. The repository
/// retains the request identity across connection retries; opening never sends a message.
@MainActor @Observable
final class NewChatModel {
    let actions = WorkspaceActions()
    private(set) var selectedAgentId: String?
    private(set) var selectedChoiceID: String?
    private(set) var completed = false
    var isBusy: Bool { actions.running || completed }

    func perform(id: String, agentId: String, operation: @escaping () async throws -> Chat,
                 onReady: @escaping (Chat) -> Void) {
        guard !isBusy else { return }
        selectedAgentId = agentId
        selectedChoiceID = id
        actions.run {
            let chat = try await operation()
            self.completed = true
            onReady(chat)
        }
    }

    func select(_ choice: ChatAgentChoice, projectId: String, title: String = "New chat",
                repository: WorkspaceDataRepository, onReady: @escaping (Chat) -> Void) {
        perform(id: choice.id, agentId: choice.agentId, operation: {
            try await repository.createChat(agentId: choice.agentId, projectId: projectId,
                                            title: title, botId: choice.botId)
        }, onReady: onReady)
    }

    // Preserve the selection entry point used by file/diff drafts.
    func select(_ agent: Agent, projectId: String, selection: SendToAgentPayload,
                repository: WorkspaceDataRepository, onReady: @escaping (ChatDraftRoute) -> Void) {
        select(.plain(agent), projectId: projectId, title: (selection.path as NSString).lastPathComponent,
               repository: repository) { onReady(.init(chatId: $0.id, draft: selection.draft)) }
    }
}

struct ChatAgentPicker: View {
    var projectId: String? = nil
    var workspaceId: String? = nil
    var initialBotId: String? = nil
    var initialWorkspaceId: String? = nil
    var repository: WorkspaceRepository = .shared
    var title: String = t("assistant.newChat")
    var chatTitle = "New chat"
    let onReady: (Chat) -> Void
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var model = NewChatModel()
    @State private var bots: [AssistantBot] = []
    @State private var agents: [Agent] = []
    @State private var search = ""
    @State private var creating = false
    @State private var createdBot: AssistantBot?
    @State private var configureCreatedBot = false
    @State private var pickedProjectID: String?
    @State private var pickedWorkspaceID: String?

    private var effectiveWorkspaceID: String? {
        if let projectId { return stores.projects.get(projectId)?.workspaceId }
        return workspaceId
            ?? pickedWorkspaceID
            ?? initialBotId.flatMap(stores.bots.get)?.workspaceId
            ?? initialWorkspaceId
            ?? stores.experience.assistantAgentID.flatMap(stores.agents.get)?.workspaceId
            ?? repository.all.first?.id
    }
    private var projects: [Project] {
        effectiveWorkspaceID.map { stores.projects(forWorkspaceId: $0) } ?? []
    }
    private var project: Project? {
        if let projectId { return stores.projects.get(projectId) }
        let preferred = pickedProjectID
            ?? initialBotId.flatMap(stores.bots.get)?.projectId.nilIfEmpty
            ?? effectiveWorkspaceID.flatMap { stores.experience.projectIDs[$0] }
        return preferred.flatMap { id in projects.first { $0.id == id } }
            ?? projects.sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }.first
    }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matchingBots: [AssistantBot] {
        bots.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.purpose.localizedStandardContains(query) }
    }
    private var matchingAgents: [Agent] {
        agents.filter { query.isEmpty || $0.typeDisplayName.localizedStandardContains(query) }
    }

    var body: some View {
        presentation
            .onAppear(perform: reload)
            .observeWorkspaceCache(reload)
            .onChange(of: stores.bots.revision) { reload() }
            .workspaceActionAlerts(model.actions)
            .interactiveDismissDisabled(model.isBusy)
            .sheet(isPresented: $creating, onDismiss: finishCreation) {
                if let workspaceId = effectiveWorkspaceID {
                    BotCreationScreen(repository: repository, workspaceId: workspaceId, onCreated: { bot in
                        createdBot = bot; configureCreatedBot = false
                    }, onAskMindwire: { bot in
                        createdBot = bot; configureCreatedBot = true
                    })
                }
            }
            .task(id: effectiveWorkspaceID) {
                if let id = effectiveWorkspaceID, let workspace = repository.get(id) {
                    await stores.workspaceData.refreshIfNeeded(workspace)
                    reload()
                }
            }
            .onChange(of: pickedWorkspaceID) { pickedProjectID = nil; reload() }
            .accessibilityIdentifier("chat.agentPicker")
    }

    @ViewBuilder private var presentation: some View {
        #if targetEnvironment(macCatalyst)
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    if let project { Text(project.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
            }.padding(20)
            NavigationStack { choices.toolbar(.hidden, for: .navigationBar) }
            Divider()
            HStack {
                Spacer()
                Button(t("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
            }.buttonStyle(.bordered).controlSize(.regular).padding(16)
        }
        .background(AssistantDesktopStyle.canvas).frame(width: 560, height: 560)
        .presentationSizing(.fitted)
        #else
        NavigationStack {
            choices
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .cancellationAction) {
                        Button(t("common.cancel")) { dismiss() }.tint(.primary).disabled(model.isBusy)
                    }
                }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        #endif
    }

    private var choices: some View {
        Group {
            if ApplePlatform.isDesktop {
                choiceList.listStyle(.plain).scrollContentBackground(.hidden).background(AssistantDesktopStyle.canvas)
            } else { choiceList.listStyle(.insetGrouped).listSectionSpacing(.compact) }
        }
        .searchable(text: $search, prompt: t("chat.agents.search"))
        .tint(.primary)
    }

    private var choiceList: some View {
        List {
            if projectId == nil, workspaceId == nil, repository.all.count > 1 {
                Section {
                    Picker(t("bots.detail.workspace"), selection: Binding(get: { effectiveWorkspaceID ?? "" }, set: { pickedWorkspaceID = $0 })) {
                        ForEach(repository.all) { workspace in
                            Text(workspace.runtime.isLocal && ApplePlatform.isDesktop ? "This Mac" : workspace.name)
                                .lineLimit(2).truncationMode(.tail).tag(workspace.id)
                        }
                    }
                    .disabled(model.isBusy)
                }
            }
            if projectId == nil, !projects.isEmpty {
                Section {
                    Picker(t("bots.detail.project"), selection: Binding(get: { project?.id ?? "" }, set: { pickedProjectID = $0 })) {
                        ForEach(projects) { project in
                            Text(project.name).lineLimit(2).truncationMode(.tail).tag(project.id)
                        }
                    }
                    .disabled(model.isBusy)
                }
            }
            if !matchingBots.isEmpty {
                Section(t("chat.agents.saved")) {
                    ForEach(matchingBots) { bot in
                        choice(.bot(bot)) {
                            AssistantBotAvatar(botId: bot.id, icon: bot.icon, size: 36)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bot.name).fontWeight(.medium).lineLimit(2).truncationMode(.tail)
                                if !bot.purpose.isEmpty {
                                    Text(bot.purpose).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
                                }
                            }
                        }
                    }
                }
            }
            if !matchingAgents.isEmpty {
                Section(t("chat.agents.plain")) {
                    ForEach(matchingAgents) { agent in
                        choice(.plain(agent)) { AgentLogo(id: agent.agentType, size: 26).frame(width: 36, height: 36) }
                            label: { Text(agent.typeDisplayName).lineLimit(2).truncationMode(.tail) }
                    }
                }
            }
            if matchingBots.isEmpty && matchingAgents.isEmpty {
                Text(t("chat.agents.empty")).foregroundStyle(.secondary)
            }
            Section {
                Button { creating = true } label: { Label(t("chat.agents.create"), icon: Icon.plus) }
                    .disabled(effectiveWorkspaceID == nil || model.isBusy).accessibilityIdentifier("chat.agentPicker.create")
            }
        }
    }

    private func choice<Artwork: View, Content: View>(_ choice: ChatAgentChoice,
                @ViewBuilder artwork: () -> Artwork, @ViewBuilder label: () -> Content) -> some View {
        Button { select(choice) } label: {
            HStack(spacing: 13) {
                artwork().accessibilityHidden(true)
                label().frame(maxWidth: .infinity, alignment: .leading)
                if model.actions.running && model.selectedChoiceID == choice.id { ProgressView().controlSize(.small) }
            }.padding(.vertical, 5).contentShape(.rect)
        }
        .disabled(model.isBusy).accessibilityIdentifier("chat.agentPicker.\(choice.id)")
    }

    private func select(_ choice: ChatAgentChoice) {
        if let project {
            model.select(choice, projectId: project.id, title: chatTitle, repository: stores.workspaceData, onReady: onReady)
        } else if let agent = stores.agents.get(choice.agentId) {
            model.perform(id: choice.id, agentId: agent.id, operation: {
                let project = try await AssistantContext.prepare(agent: agent, stores: stores)
                return try await stores.workspaceData.createChat(agentId: agent.id, projectId: project.id,
                                                                title: chatTitle, botId: choice.botId)
            }, onReady: onReady)
        }
    }

    private func finishCreation() {
        reload()
        guard let bot = createdBot else { return }
        createdBot = nil
        if configureCreatedBot {
            configureCreatedBot = false
            model.perform(id: "bot:" + bot.id, agentId: bot.agentId, operation: {
                try await BotConversationActions.configurationChat(for: bot, stores: stores)
            }, onReady: onReady)
        } else { select(.bot(bot)) }
    }

    private func reload() {
        guard let workspaceId = effectiveWorkspaceID else { bots = []; agents = []; return }
        let local = stores.bots.list().filter { $0.workspaceId == workspaceId && !$0.archived }
        bots = BotPresentation.visibleBots(local, preferredAgentId: stores.experience.assistantAgentID,
            projectIDs: stores.experience.projectIDs).sorted {
                if $0.isMaster != $1.isMaster { return $0.isMaster }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        var seen = Set<AgentID>()
        agents = stores.agents(forWorkspaceId: workspaceId).filter { seen.insert($0.agentType).inserted }
    }
}
