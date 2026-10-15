// Shared full history, optionally scoped to a project and opened within its navigation stack.
import SwiftUI

struct ChatHistorySheet: View {
    var projectId: String? = nil
    var agentId: String? = nil
    var workspaceId: String? = nil
    var conversationRepository: ConversationRepository? = nil

    @Environment(AppModel.self) private var app
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss

    @State private var chats: [Chat] = []
    @State private var activity = ChatActivityStore.shared
    @State private var history: ConversationHistory?
    @State private var search = ""
    @State private var openingID: String?
    @State private var openingTask: Task<Void, Never>?
    @State private var openError: String?
    @State private var showingService = false
    @State private var showingIssues = false

    private var globalWorkspaceId: String? {
        guard projectId == nil else { return nil }
        return workspaceId ?? agentId.flatMap { stores.agents.get($0)?.workspaceId }
    }

    private var filteredChats: [Chat] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return activity.ordered(chats).filter { chat in
            query.isEmpty || [activity.title(chat), stores.projects.get(chat.projectId)?.name ?? "",
                              stores.projects.get(chat.projectId)?.path ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(t(globalWorkspaceId != nil ? "chat.all.title" : projectId == nil ? "chat.recent" : "agentDetail.chats"))
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: t("chat.all.search"))
                .refreshable { await refresh() }
                .toolbar {
                    AppToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { AppIcon(Icon.close) }
                            .tint(.primary)
                    }
                }
        }
        .onAppear(perform: reload)
        .onDisappear { openingTask?.cancel(); openingTask = nil }
        .observeWorkspaceCache(reload)
        .observeChatActivity(agentIds: chats.map(\.agentId))
        .task(id: search) {
            guard let workspaceId = globalWorkspaceId else { return }
            if !search.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            let cached = (conversationRepository ?? stores.conversations).history(workspaceId: workspaceId, agentId: agentId, search: search)
            history = cached
            await cached.load()
        }
        .sheet(isPresented: $showingService) {
            if let id = globalWorkspaceId, let workspace = WorkspaceRepository.shared.get(id) {
                ServiceUpdateInfoSheet(workspace: workspace)
            }
        }
        .alert(t("chat.all.issues"), isPresented: $showingIssues) {
            Button(t("common.ok"), role: .cancel) {}
        } message: { Text(history?.issues.map(\.message).joined(separator: "\n\n") ?? "") }
        .alert(t("chat.all.openFailed"), isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button(t("common.ok"), role: .cancel) {}
        } message: { Text(openError ?? "") }
    }

    @ViewBuilder
    private var content: some View {
        List {
            if let history, let error = history.error {
                Section {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    if history.requiresUpdate {
                        Button(t("workspace.daemon.title")) { showingService = true }.tint(.primary)
                    } else {
                        Button(t("common.retry")) { Task { await history.load(force: true) } }.tint(.primary)
                    }
                }
            } else if let history, !history.issues.isEmpty {
                Button { showingIssues = true } label: {
                    Label(t("chat.all.issues"), icon: .warning).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let history, history.total != nil {
                if history.items.isEmpty { emptyState }
                ForEach(history.items) { conversation in
                    conversationRow(conversation)
                }
                if history.nextCursor != nil {
                    HStack {
                        Spacer()
                        if history.isLoadingMore { ProgressView() }
                        else {
                            Button(t("chat.all.loadMore")) { Task { await history.loadMore() } }.tint(.primary)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .task { if history.error == nil { await history.loadMore() } }
                }
            } else {
                ForEach(filteredChats) { chat in row(chat) }
                if filteredChats.isEmpty {
                    if globalWorkspaceId != nil && (history == nil || history?.isLoading == true) {
                        HStack(spacing: Spacing.sm) {
                            ProgressView()
                            Text(t("chat.all.loading")).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .listRowBackground(Color.clear)
                    } else if history?.error == nil { emptyState }
                }
            }
        }
        .accessibilityIdentifier("chat.history.list")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(t(search.isEmpty ? "chat.all.empty" : "chat.all.noMatches")).font(.headline)
            Text(t(search.isEmpty ? "chat.all.emptyBody" : "chat.all.searchBody"))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.lg)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func conversationRow(_ conversation: Conversation) -> some View {
        if let id = conversation.chatId, let chat = stores.chats.get(id),
           stores.projects.get(chat.projectId)?.workspaceId == globalWorkspaceId {
            ChatListRow(chat: chat, subtitle: conversation.folderLabel,
                        onOpen: { open(chat) }, onChanged: changed)
                .disabled(openingID != nil)
        } else {
            Button { open(conversation) } label: {
                HStack {
                    ChatRowLabel(title: conversation.title, subtitle: conversation.folderLabel,
                                 status: conversation.lastStatus.flatMap(RunStatus.init(rawValue:)),
                                 date: conversation.activityDate)
                    if openingID == conversation.id { ProgressView().controlSize(.mini) }
                }
            }
            .tint(.primary)
            .disabled(openingID != nil)
            .accessibilityIdentifier("chat.history.native.\(conversation.id)")
        }
    }

    private func row(_ chat: Chat) -> some View {
        let agent = stores.agents.get(chat.agentId)
        let subtitle = globalWorkspaceId == nil ? agent?.displayName : stores.projects.get(chat.projectId)?.name
        return ChatListRow(chat: chat, subtitle: subtitle, onOpen: { open(chat) }, onChanged: changed)
    }

    private func open(_ chat: Chat) {
        let id = chat.id
        dismiss()
        if projectId != nil || globalWorkspaceId != nil { app.push(.chat(chatId: id)) }
        else { app.openChat(id) }
    }

    private func open(_ conversation: Conversation) {
        guard let workspaceId = globalWorkspaceId, openingID == nil else { return }
        openingID = conversation.id
        openingTask = Task {
            defer { openingID = nil }
            do {
                let chat = try await (conversationRepository ?? stores.conversations).open(conversation, workspaceId: workspaceId, agentId: agentId)
                guard !Task.isCancelled else { return }
                open(chat)
            } catch {
                if !error.isRequestCancellation { openError = error.localizedDescription }
            }
        }
    }

    private func changed() {
        reload()
        if let history { Task { await history.load(force: true) } }
    }

    private func refresh() async {
        if let history { await history.load(force: true) }
        else if let id = projectId.flatMap({ stores.projects.get($0)?.workspaceId }), let workspace = WorkspaceRepository.shared.get(id) {
            await stores.workspaceData.refresh(workspace)
        }
        reload()
    }

    private func reload() {
        if let projectId { chats = stores.chats(forProjectId: projectId) }
        else if let agentId { chats = stores.chats(forAgentId: agentId) }
        else if let workspaceId { chats = stores.chats(forWorkspaceId: workspaceId) }
        else { chats = stores.chatsByRecency() }
    }
}
