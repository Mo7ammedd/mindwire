import SwiftUI

struct AssistantBotIconPicker: View {
    let bot: AssistantBot
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var selected: AssistantBotIcon
    @State private var automatic: Bool
    @State private var saving = false
    @State private var error: String?

    init(bot: AssistantBot) {
        self.bot = bot
        _selected = State(initialValue: .resolve(botId: bot.id, icon: bot.icon))
        _automatic = State(initialValue: bot.icon?.isEmpty != false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(spacing: 14) {
                        AssistantBotAvatar(botId: bot.id, icon: selected.id, size: 80)
                        Text(bot.name).font(.title3.weight(.medium))
                        Text(t("assistant.icons.hint")).font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)

                    BotAppearanceEditor(botId: bot.id, selection: $selected) { automatic = false }

                    Button {
                        selected = .resolve(botId: bot.id, icon: nil); automatic = true
                    } label: {
                        HStack {
                            Text(t("assistant.icons.automatic"))
                            Spacer()
                            if automatic { Image(systemName: "checkmark") }
                        }
                        .font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 44)
                    }
                }
                .padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .navigationTitle(t("assistant.icons.change"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.disabled(saving)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text(t("common.save")) }
                    }
                    .disabled(saving).accessibilityIdentifier("assistant.icon.save")
                }
            }
            .interactiveDismissDisabled(saving)
            .alert(t("assistant.bots.saveFailed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(t("common.ok"), role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let current = stores.bots.get(bot.id) ?? bot
            try await stores.workspaceData.editBot(current, edit: AssistantBotEdit(expectedRevision: current.revision, icon: automatic ? "" : selected.id))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Settings entry uses the same editor as a bot's context menu.
struct AssistantBotAppearanceSettings: View {
    @Environment(\.stores) private var stores
    @State private var editing: AssistantBot?

    private var bots: [AssistantBot] {
        _ = stores.bots.revision
        let workspaceIDs = Set(WorkspaceRepository.shared.all.map(\.id))
        let connected = stores.bots.list().filter {
            !$0.archived && workspaceIDs.contains($0.workspaceId)
        }
        return BotPresentation.visibleBots(connected, preferredAgentId: stores.experience.assistantAgentID,
                                          projectIDs: stores.experience.projectIDs).sorted {
            if $0.isMaster != $1.isMaster { return $0.isMaster }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        List(bots) { bot in
            #if targetEnvironment(macCatalyst)
            Button { editing = bot } label: {
                HStack(spacing: 12) {
                    AssistantBotAvatar(botId: bot.id, icon: bot.icon, size: 28)
                    Text(bot.name).lineLimit(1)
                    Spacer()
                    Text(t("assistant.icons.change")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("assistant.icon.options.\(bot.id)")
            #else
            HStack(spacing: 12) {
                AssistantBotAvatar(botId: bot.id, icon: bot.icon, size: 36)
                Text(bot.name).lineLimit(1)
                Spacer()
                Menu {
                    Button { editing = bot } label: { Label(t("assistant.icons.change"), systemImage: "face.smiling") }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(.rect)
                }
                .tint(.primary)
                .accessibilityLabel(t("assistant.icons.options", ["name": bot.name]))
                .accessibilityIdentifier("assistant.icon.options.\(bot.id)")
            }
            #endif
        }
        .navigationTitle(t("assistant.icons.title"))
        .sheet(item: $editing) { AssistantBotIconPicker(bot: $0) }
    }
}
