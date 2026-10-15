import SwiftUI

/// Workspace headings group the agent capsules without an outer card.
struct AgentsListScreen: View {
    var repository: WorkspaceRepository = .shared
    @Environment(\.sidebarNavigation) private var sidebar
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var minimumButtonWidth: CGFloat = 136
    @ScaledMetric(relativeTo: .subheadline) private var minimumButtonHeight: CGFloat = 52

    @State private var groups: [WorkspaceAgents] = []
    @State private var showNewAgent = false
    @State private var showHistory = false

    private struct WorkspaceAgents: Identifiable, Equatable {
        let workspace: Workspace
        let agents: [Agent]
        var id: String { workspace.id }
    }

    var body: some View {
        Group {
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                AgentWorkspaceHeading(workspace: group.workspace)
                                LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.sm) {
                                    ForEach(group.agents) { agent in
                                        agentButton(agent)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xl)
                }
                .background(Palette.bg)
                .accessibilityIdentifier("agents.workspaces")
            }
        }
        .navigationTitle(t("tabs.agents"))
        .principalBrand()
        .toolbar {
            AppToolbarItem(placement: .topBarLeading) {
                Button { showHistory = true } label: { AppIcon(Icon.history) }
                    .tint(.primary)
                    .accessibilityLabel(t("chat.all.title"))
            }
            AppToolbarItem(placement: .topBarTrailing) {
                Button { showNewAgent = true } label: { AppIcon(Icon.plus) }
                    .tint(.primary)
                    .accessibilityLabel(t("newAgent.title"))
            }
        }
        .onAppear(perform: reload)
        .observeWorkspaceCache(reload)
        .onChange(of: repository.revision) { reload() }
        .onChange(of: repository.agents().map(\.id)) { reload() }
        .task { await repository.refreshIfNeeded() }
        .refreshable {
            await repository.refreshChecks()
            reload()
        }
        .observeChatActivity(agentIds: groups.flatMap { $0.agents.map(\.id) })
        .sheet(isPresented: $showNewAgent, onDismiss: reload) {
            NewAgentScreen(repository: repository)
        }
        .sheet(isPresented: $showHistory, onDismiss: reload) {
            ChatHistorySheet()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(t("agents.empty.title"), icon: Icon.agents)
        } description: {
            Text(t("agents.empty.body"))
        } actions: {
            Button(t("agents.empty.cta")) { showNewAgent = true }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(Palette.accent)
        }
    }

    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: minimumButtonWidth), spacing: Spacing.sm)]
    }

    private func agentButton(_ agent: Agent) -> some View {
        let selected = sidebar?.selected == .app(.agentDetail(agentId: agent.id))
        return RootNavigationLink(value: AppRoute.agentDetail(agentId: agent.id), usesDefaultRowBackground: false) {
            AgentCompactLabel(agent: agent)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .frame(maxWidth: .infinity, minHeight: minimumButtonHeight, alignment: .leading)
                .background {
                    Capsule(style: .continuous)
                        .fill(Palette.surface)
                    if selected {
                        Capsule(style: .continuous)
                            .fill(Palette.accentSoft)
                            .strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agents.agent.\(agent.id)")
    }

    private func reload() {
        // Build groups only when the cached inventory changes. Group by ID so
        // identically named computers stay distinct, and keep the repository's order.
        let byWorkspace = Dictionary(grouping: repository.agents(), by: \.workspaceId)
        let next = repository.all.compactMap { workspace -> WorkspaceAgents? in
            guard let agents = byWorkspace[workspace.id], !agents.isEmpty else { return nil }
            return WorkspaceAgents(workspace: workspace, agents: agents)
        }
        if next != groups { groups = next }
    }
}

/// A workspace-wide update or connection problem has one indicator and one route
/// to its controls. Reading the shared state does not start another service check.
private struct AgentWorkspaceHeading: View {
    let workspace: Workspace
    @Environment(\.stores) private var stores
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 18

    private var showsStatus: Bool {
        let key = DaemonWorkKey(workspaceId: workspace.id)
        let state = DaemonWorkCoordinator.shared.states[key]
        return state?.workspaceUnavailable == true || state?.running == true
            || state?.error != nil || state?.reachable == false || state?.updateAvailable == true
            || (state?.reachable == true && state?.supportsProjects == false)
            || state?.updateWaiting == true || state?.updateOperation?.isActive == true
            || stores.preparation.active.contains(key) || stores.serviceUpdates.active.contains(workspace.id)
    }

    var body: some View {
        RootNavigationLink(value: AppRoute.workspaceDetail(id: workspace.id), usesDefaultRowBackground: false) {
            HStack(spacing: Spacing.sm) {
                Group {
                    if workspace.isCloud && workspace.image == nil {
                        AppIcon(Icon.cloud, size: iconSize).foregroundStyle(.secondary)
                    } else {
                        WorkspaceImageIcon(image: workspace.image, size: iconSize)
                    }
                }
                .frame(width: iconSize + 14, height: iconSize + 14)
                .background(Palette.surface, in: .circle)
                .accessibilityHidden(true)
                Text(workspace.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: Spacing.sm)
                if showsStatus {
                    WorkspaceDaemonStatusLabel(workspaceId: workspace.id, compact: true)
                }
            }
            .frame(minHeight: 44, alignment: .center)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("agents.workspace.\(workspace.id)")
    }
}
