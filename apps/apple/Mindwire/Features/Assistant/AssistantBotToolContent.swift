import SwiftUI

/// Tool acknowledgements resolve authoritative daemon identities before opening cached records.
/// A remote result must never accidentally open an identically named local bot or chat.
struct AssistantBotToolContent: View {
    let result: AssistantBotToolResult
    let workspaceId: String?
    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @State private var syncing = false
    @State private var error: String?
    @State private var savedBot: AssistantBot?
    @State private var savedChatID: String?

    private var destination: Workspace? {
        if let identity = result.workspaceId {
            return WorkspaceRepository.shared.all.first { stores.workspaceData.identity(workspaceId: $0.id) == identity }
        }
        return workspaceId.flatMap(WorkspaceRepository.shared.get)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AssistantBotAvatar(botId: result.botId, icon: savedBot?.icon ?? result.icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(savedBot?.name ?? result.name).font(.subheadline.weight(.medium))
                    Text(t(statusKey)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if syncing { ProgressView().chatActivityTint().controlSize(.small) }
                else if result.archived != true {
                    Button(t("common.open")) {
                        if let savedChatID { app.openChat(savedChatID) }
                        else if let savedBot {
                            if app.usesAssistant { app.openBot(savedBot.id) }
                            else { app.push(.botDetail(botId: savedBot.id)) }
                        }
                    }
                    .font(.subheadline.weight(.medium)).buttonStyle(.plain).tint(.primary)
                    .disabled(savedBot?.archived != false)
                    .accessibilityIdentifier("assistant.bot.result.open.\(result.botId)")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button(t("common.retry")) { Task { await refresh() } }.font(.caption).tint(.primary)
            }
        }
        .padding(.vertical, 8)
        .onAppear(perform: reload)
        .observeWorkspaceCache(reload)
        .onChange(of: stores.bots.revision) { reload() }
        .task(id: "\(workspaceId ?? ""):\(result.workspaceId ?? ""):\(result.revision ?? 0)") { await refresh() }
    }

    private var statusKey: String {
        switch result.operation {
        case "created": "assistant.bots.created"
        case "memory_updated": "assistant.bots.memorySaved"
        case "knowledge_updated", "knowledge_removed": "assistant.bots.knowledgeSaved"
        case "chat_created": "assistant.bots.chatCreated"
        case "task_started": "bots.task.started"
        case "task_input": "bots.task.input"
        case "task_cancelled": "bots.task.cancelled"
        default: "assistant.bots.updated"
        }
    }

    private func reload() {
        guard let workspace = destination else { savedBot = nil; savedChatID = nil; return }
        let bot = stores.bots.get(result.botId)
        savedBot = bot?.workspaceId == workspace.id ? bot : nil
        if let chat = result.chatId.flatMap(stores.chats.get),
           stores.projects.get(chat.projectId)?.workspaceId == workspace.id { savedChatID = chat.id }
        else { savedChatID = nil }
    }

    private func refresh() async {
        guard let workspace = destination else {
            error = t("bots.connections.unknownComputer")
            return
        }
        syncing = true
        await stores.workspaceData.refresh(workspace)
        syncing = false
        error = stores.workspaceData.errors[workspace.id]
        reload()
    }
}
