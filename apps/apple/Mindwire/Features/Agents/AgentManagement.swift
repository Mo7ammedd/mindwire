import SwiftUI

/// Profile management does not require a harness login. Native chat deletion still has to
/// succeed before removing the profile, including the service's checks for running turns.
enum AgentManagement {
    @MainActor
    static func remove(_ agentId: String, session: DaemonSession?, stores: Stores) async throws {
        let chats = stores.chats(forAgentId: agentId)
        if !chats.isEmpty {
            let session = session ?? DaemonManager.shared.session(for: agentId, stores: stores)
            for chat in chats { try await session.deleteChat(chat.id) }
        }
        try await stores.workspaceData.removeAgent(agentId)
    }
}

/// Keep navigation and management outside the readiness gate on every agent entry point.
private struct AgentManagementModifier: ViewModifier {
    let agent: Agent?
    let session: DaemonSession?
    let actions: WorkspaceActions
    let showsAuthentication: Bool
    let onRemoved: (() -> Void)?

    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false
    @State private var showingSettings = false
    @State private var showingServiceInfo = false
    @State private var showingTerminal = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if let agent {
                    AppToolbarItem(placement: .topBarTrailing) {
                        AppMenu {
                            Button {
                                renameText = agent.name
                                renaming = true
                            } label: { Label(t("common.rename"), icon: Icon.edit) }

                            Button { showingTerminal = true } label: {
                                Label(t("workspace.terminal.open"), icon: Icon.terminal)
                            }

                            if showsAuthentication {
                                NavigationLink(value: AppRoute.agentAuthentication(agentId: agent.id)) {
                                    Label(t("agentAuth.section"), icon: .userKey)
                                }
                            }

                            Button { showingSettings = true } label: {
                                Label(t("agentSettings.title"), icon: Icon.settings)
                            }

                            if agent.workspaceId != nil {
                                Button(t("workspace.daemon.title"), icon: .download) {
                                    showingServiceInfo = true
                                }
                            }

                            DestructiveButton(t("agentSettings.delete"), icon: Icon.trash) {
                                confirmingDelete = true
                            }
                        } label: {
                            AppIcon(Icon.ellipsis).foregroundStyle(.primary)
                        }
                        .accessibilityLabel(t("agentDetail.menu.title"))
                        .accessibilityIdentifier("agent.manage")
                        .disabled(actions.running)
                    }
                }
            }
            .sheet(isPresented: $showingSettings, onDismiss: settingsDismissed) {
                if let agent { AgentSettingsScreen(agentId: agent.id) }
            }
            .sheet(isPresented: $showingServiceInfo) {
                if let id = agent?.workspaceId, let workspace = WorkspaceRepository.shared.get(id) {
                    ServiceUpdateInfoSheet(workspace: workspace)
                }
            }
            .fullScreenCover(isPresented: $showingTerminal) {
                TerminalScreen(title: agent?.displayName ?? t("workspace.terminal.title")) {
                    TerminalSessionFactory.provider(
                        for: WorkspaceRepository.shared.get(agent?.workspaceId ?? ""), stores: stores)
                }
            }
            .inputDialog(
                titleKey: "agentDetail.rename.title",
                isPresented: $renaming,
                text: $renameText,
                placeholder: t("agentDetail.rename.label")
            ) {
                guard let agent else { return }
                actions.run { try await stores.workspaceData.renameAgent(agent.id, name: renameText) }
            }
            .alert(t("agentDetail.delete.title"), isPresented: $confirmingDelete) {
                Button(t("common.delete"), role: .destructive) {
                    guard let agent else { return }
                    actions.run {
                        try await AgentManagement.remove(agent.id, session: session, stores: stores)
                        removed()
                    }
                }
                Button(t("common.cancel"), role: .cancel) {}
            } message: {
                if let agent {
                    Text(t("agentDetail.delete.body", [
                        "name": agent.displayName,
                        "count": "\(stores.chatCount(agentId: agent.id))",
                    ]))
                }
            }
            .workspaceActionAlerts(actions)
    }

    private func settingsDismissed() {
        guard let agent, stores.agents.get(agent.id) != nil else {
            removed()
            return
        }
        Task { await session?.load() }
    }

    private func removed() {
        if let onRemoved { onRemoved() }
        else { dismiss() }
    }
}

extension View {
    func agentManagement(agent: Agent?, session: DaemonSession?, actions: WorkspaceActions,
                         showsAuthentication: Bool = true, onRemoved: (() -> Void)? = nil) -> some View {
        modifier(AgentManagementModifier(agent: agent, session: session, actions: actions,
                                        showsAuthentication: showsAuthentication, onRemoved: onRemoved))
    }
}
