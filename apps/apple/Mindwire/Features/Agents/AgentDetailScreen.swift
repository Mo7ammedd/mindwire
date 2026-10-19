import SwiftUI

/// One agent persona: a header (logo + name + type), its recent chats (across the workspace's
/// projects), and details (including its owning workspace). The agent is owned by a workspace; a chat
/// still runs in its project's cwd. A manage menu + settings sheet live in the toolbar.
struct AgentDetailScreen: View {
    let agentId: String

    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var agent: Agent?
    @State private var chats: [Chat] = []
    @State private var auth: DaemonSession?
    @State private var workspaceImages: [WorkspaceImage] = []

    @State private var showingServiceInfo = false
    @State private var showAllChats = false
    @State private var showingNewChat = false
    @State private var pendingChat: Chat?
    @State private var activity = ChatActivityStore.shared
    @State private var actions = WorkspaceActions()
    @State private var loaded = false

    init(agentId: String, session: DaemonSession? = nil) {
        self.agentId = agentId
        _auth = State(initialValue: session)
    }

    var body: some View {
        content
            .navigationTitle(agent?.displayName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .agentManagement(agent: agent, session: auth, actions: actions)
            .onAppear {
                // Deleting from the pushed authentication page must also leave this profile.
                if loaded, stores.agents.get(agentId) == nil { dismiss() }
            }
            .task { await ensureAuth() }
            .observeWorkspaceCache(reload)
            .observeChatActivity(agentIds: [agentId])
            .sheet(isPresented: $showingServiceInfo) {
                if let id = agent?.workspaceId, let workspace = WorkspaceRepository.shared.get(id) {
                    ServiceUpdateInfoSheet(workspace: workspace)
                }
            }
            .sheet(isPresented: $showAllChats) {
                ChatHistorySheet(agentId: agentId)
            }
            .sheet(isPresented: $showingNewChat, onDismiss: {
                reload()
                if let chat = pendingChat { pendingChat = nil; app.push(.chat(chatId: chat.id)) }
            }) {
                if let workspaceId = agent?.workspaceId {
                    ChatAgentPicker(workspaceId: workspaceId) { chat in
                        pendingChat = chat; showingNewChat = false
                    }
                }
            }
    }

    /// Cached authentication never overrides a shared install job's live readiness.
    @ViewBuilder
    private var content: some View {
        if let agent {
            AgentReadinessView(agent: agent, session: auth) {
                agentList(agent)
            }
        } else {
            if loaded {
                ContentUnavailableView(t("agent.missing.title"), icon: .userCircle,
                                       description: Text(t("agent.missing.body")))
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func agentList(_ agent: Agent) -> some View {
        List {
            header(agent)
            Section {
                NavigationLink(value: AppRoute.agentAuthentication(agentId: agentId)) {
                    Label(t("agentAuth.section"), icon: .userKey)
                }
                .tint(.primary)
            }
            chatsSection
            detailsSection(agent)
        }
        .readablePane()
    }

    @ViewBuilder
    private func header(_ agent: Agent) -> some View {
        Section {
            HStack(spacing: Spacing.md) {
                AgentLogo(id: agent.agentType, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName).font(.headline).lineLimit(1)
                    Text(agent.typeDisplayName)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Spacing.sm)
                if let work = auth?.daemonWork, work.updateAvailable || work.updateOperation?.isActive == true || work.error != nil {
                    Button { showingServiceInfo = true } label: { AgentRowStatus(agent: agent) }
                        .buttonStyle(.borderless)
                        .tint(.primary)
                        .accessibilityLabel(t("workspace.daemon.info"))
                } else {
                    AgentRowStatus(agent: agent)
                }
            }
        }
    }

    private static let inlineChatLimit = 3

    /// The agent's recent chats across all its projects (each labeled with its project).
    @ViewBuilder
    private var chatsSection: some View {
        Section {
            newChatAction

            ForEach(activity.ordered(chats, limit: Self.inlineChatLimit)) { chat in
                ChatListRow(chat: chat, subtitle: projectName(chat.projectId), onChanged: reload)
            }
            Button { showAllChats = true } label: {
                HStack {
                    Label(t("chat.all.title"), icon: Icon.history)
                    Spacer()
                    AppIcon(Icon.chevron).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)
            .accessibilityIdentifier("agent.chats.all")
        } header: {
            Text(t("agentDetail.chats"))
        } footer: {
            if chats.isEmpty { Text(t("chat.all.agentHint")) }
        }
    }

    @ViewBuilder
    private func detailsSection(_ agent: Agent) -> some View {
        Section(t("agentDetail.section.details")) {
            workspaceRow(agent)
            LabeledContent(t("agentDetail.row.type"),
                           value: agent.typeDisplayName)
            LabeledContent(t("agentDetail.row.created"), value: fmtDate(agent.createdAt))
        }
    }

    /// The workspace that owns this agent (its runtime home). Tappable → that workspace when it's a
    /// resolvable one; otherwise a plain "No workspace" for legacy/orphaned agents.
    @ViewBuilder
    private func workspaceRow(_ agent: Agent) -> some View {
        if let id = agent.workspaceId, let workspace = WorkspaceRepository.shared.get(id) {
            NavigationLink(value: AppRoute.workspaceDetail(id: id)) {
                LabeledContent {
                    Text(workspace.name).foregroundStyle(.secondary)
                } label: {
                    Label {
                        Text(t("agentDetail.row.workspace"))
                    } icon: {
                        WorkspaceImageIcon(image: workspace.image, catalog: workspaceImages, size: 22)
                            .accessibilityHidden(true)
                    }
                }
            }
            .tint(.primary)
            .task(id: workspace.image) {
                guard workspace.runtime.isCloud, workspace.image != nil else { return }
                workspaceImages = await CloudImages.cached()
            }
        } else {
            LabeledContent {
                Text(t("agent.noWorkspace")).foregroundStyle(.secondary)
            } label: {
                Label(t("agentDetail.row.workspace"), icon: Icon.server)
            }
        }
    }

    private func projectName(_ id: String) -> String {
        stores.projects.get(id)?.name ?? t("agentDetail.noProject")
    }

    private func reload() {
        loaded = true
        agent = stores.agents.get(agentId)
        chats = stores.chats(forAgentId: agentId)
    }

    /// A chat needs a project: open it directly when there is one, otherwise offer a native menu.
    private var newChatAction: some View {
        Button { showingNewChat = true } label: { Label(t("agentDetail.newChat"), icon: Icon.edit) }
        .tint(.primary)
        .disabled(auth?.phase != .ready || actions.running)
    }

    /// Load local data, then run the connectivity + auth check (cached per agent).
    private func ensureAuth() async {
        reload()
        guard agent != nil else { return }
        let model = auth ?? DaemonManager.shared.session(for: agentId, stores: stores)
        auth = model
        await model.load()
        await activity.refresh(agentIds: [agentId], stores: stores)
        reload()
    }
}

// MARK: - Shared helpers (Agents feature)

/// Short localized date from an ISO-8601 string; falls back to the raw string.
func fmtDate(_ iso: String) -> String {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    guard let date else { return iso }
    return date.formatted(date: .abbreviated, time: .omitted)
}
