import SwiftUI

/// Manual editing shares revision checks with Mindwire's bot tools. Authentication remains
/// owned by the engine profile, so changing a bot's instructions cannot replace credentials.
struct BotEditorScreen: View {
    let bot: AssistantBot
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appExperienceMode) private var experienceMode
    @State private var name: String
    @State private var purpose: String
    @State private var instructions: String
    @State private var memory: String
    @State private var knowledge: [AssistantBotKnowledge]
    @State private var agentId: String
    @State private var showingEngineSettings = false
    @State private var saving = false
    @State private var error: String?

    init(bot: AssistantBot) {
        self.bot = bot
        _name = State(initialValue: bot.name)
        _purpose = State(initialValue: bot.purpose)
        _instructions = State(initialValue: bot.instructions)
        _memory = State(initialValue: bot.memory)
        _knowledge = State(initialValue: bot.knowledge)
        _agentId = State(initialValue: bot.agentId)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AssistantBotAvatar(botId: bot.id, icon: bot.icon, size: 42)
                        TextField(t("bots.create.namePlaceholder"), text: $name)
                            .font(.headline).textInputAutocapitalization(.words)
                    }
                }
                Section(t("assistant.bots.purpose")) {
                    TextField(t("bots.edit.purposePlaceholder"), text: $purpose, axis: .vertical).lineLimit(2...4)
                }
                if bot.isRaw {
                    Section { Text(t("bots.raw.settingsHint")).font(.footnote).foregroundStyle(.secondary) }
                } else {
                    Section(t("assistant.bots.instructions")) {
                        TextField(t("bots.create.instructionsPlaceholder"), text: $instructions, axis: .vertical).lineLimit(5...12)
                    }
                    Section(t("assistant.bots.memory")) {
                        TextField(t("bots.edit.memoryPlaceholder"), text: $memory, axis: .vertical).lineLimit(3...10)
                    }
                    Section(t("assistant.bots.knowledge")) {
                        ForEach($knowledge) { $source in
                            VStack(alignment: .leading, spacing: 10) {
                                TextField(t("bots.edit.knowledgeTitle"), text: $source.title).font(.headline)
                                TextField(t("bots.edit.knowledgeContent"), text: $source.content, axis: .vertical).lineLimit(3...10)
                                Button(t("common.delete"), role: .destructive) { knowledge.removeAll { $0.id == source.id } }
                                    .font(.subheadline)
                            }
                            .padding(.vertical, 6)
                        }
                        Button(t("bots.edit.addKnowledge")) {
                            knowledge.append(.init(id: UUID().uuidString.lowercased(), title: "", content: ""))
                        }
                        .disabled(knowledge.count >= 32)
                    }
                }
                if experienceMode == .developer {
                    Section {
                        BotRuntimeRows(bot: bot, navigates: false)
                        if let agent = stores.agents.get(agentId) {
                            Picker(t("bots.create.engine"), selection: $agentId) {
                                ForEach(availableAgents) { candidate in
                                    Label { Text(candidate.typeDisplayName) } icon: { AgentLogo(id: candidate.agentType, size: 20) }
                                        .tag(candidate.id)
                                }
                            }
                            Button { showingEngineSettings = true } label: { BotBaseAgentLabel(agent: agent) }
                        }
                    } header: { Text(t("bots.detail.runtime")) }
                      footer: { Text(t("bots.edit.engineHint")) }
                    .tint(.primary)
                }
            }
            .disabled(saving)
            .navigationTitle(t("bots.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button(t("common.cancel")) { dismiss() }.disabled(saving) }
                AppToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text(t("common.save")) }
                    }
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .alert(t("assistant.bots.saveFailed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(t("common.ok"), role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .frame(width: ApplePlatform.isDesktop ? 580 : nil, height: ApplePlatform.isDesktop ? 640 : nil)
        .sheet(isPresented: $showingEngineSettings) { AgentSettingsScreen(agentId: agentId) }
    }

    private var availableAgents: [Agent] {
        stores.agents(forWorkspaceId: bot.workspaceId).filter {
            $0.id == bot.agentId || bot.isRaw || BotEngineSupport.supports($0.agentType)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            // Use the revision at the start of editing: a concurrent master edit must conflict,
            // rather than silently overwriting newer memory with this screen's old draft.
            try await stores.workspaceData.editBot(bot, edit: .init(expectedRevision: bot.revision,
                agentId: agentId == bot.agentId ? nil : agentId,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), purpose: purpose,
                instructions: bot.isRaw ? nil : instructions, memory: bot.isRaw ? nil : memory,
                knowledge: bot.isRaw ? nil : knowledge))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
