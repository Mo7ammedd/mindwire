import SwiftUI

/// Account reuse, sign-in and adding another connection share one flow on both platforms.
struct AssistantConnectionPicker: View {
    let workspace: Workspace
    var repository: WorkspaceRepository = .shared
    var discovery: AssistantConnectionDiscovery
    var managesConnections = false
    let onReady: (Agent) -> Void
    @Environment(\.stores) private var stores
    @State private var selected: Agent?
    @State private var adding = false
    @State private var attempt = 0
    @State private var managing: Agent?

    private var visibleConnections: [AssistantConnection] { discovery.connections }

    var body: some View {
        VStack(spacing: 0) {
            if selected != nil || adding {
                HStack {
                    Button { selected = nil; adding = false } label: {
                        Label(t("common.back"), systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(20)
            }
            if let selected {
                AgentSetupScreen(agent: selected, onRemoved: { self.selected = nil }) { complete(selected) }
                    .id(selected.id)
            } else if adding {
                NewAgentScreen(workspaceId: workspace.id, repository: repository, assistantSetup: true,
                    embedded: true, assistantWorkspace: workspace,
                    existingAgents: stores.agents(forWorkspaceId: workspace.id), requiresBotSupport: !managesConnections,
                    onSelected: { selected = $0 }) {
                        if let agent = $0 { complete(agent) } else { adding = false }
                    }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(managesConnections ? "AI connections" : visibleConnections.isEmpty ? "Connect your AI" : "Your AI is already here")
                                .font(.system(size: ApplePlatform.isDesktop ? 22 : 26, weight: .semibold))
                            Text(workspace.runtime.isLocal ? "Use an account on this Mac." : "Use an account on \(workspace.name).")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if discovery.loading && visibleConnections.isEmpty {
                            ProgressView("Checking your connections…")
                        }
                        ForEach(visibleConnections) { connection in
                            HStack(spacing: 0) {
                                Button {
                                    if managesConnections { managing = connection.agent }
                                    else { selected = connection.agent }
                                } label: {
                                    HStack(spacing: 12) {
                                        if let service = AssistantAIService(agentType: connection.agent.agentType) {
                                            AssistantServiceMark(service: service, size: 28).frame(width: 32)
                                        } else { AgentLogo(id: connection.agent.agentType, size: 28).frame(width: 32) }
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(managesConnections ? connection.name : connection.status == .ready ? "Use your \(connection.name) connection" : "Connect \(connection.name)")
                                                .font(.system(size: ApplePlatform.isDesktop ? 14 : 17, weight: .medium))
                                            Text(detail(connection)).font(.system(size: ApplePlatform.isDesktop ? 12 : 14))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if connection.status == .checking { ProgressView().controlSize(.small) }
                                        else if managesConnections { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.secondary) }
                                    }
                                    .padding(16)
                                    .contentShape(.rect(cornerRadius: 16))
                                }
                                .buttonStyle(.plain)
                                .disabled(connection.status == .checking)
                                .accessibilityIdentifier("assistant.connection.\(connection.agent.agentType.rawValue)")
                                if !managesConnections {
                                    Button { managing = connection.agent } label: {
                                        Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 8)
                                    .accessibilityLabel("Manage \(connection.name) connection")
                                    .accessibilityIdentifier("assistant.connection.manage.\(connection.agent.agentType.rawValue)")
                                }
                            }
                            .background(AssistantStyle.surface, in: .rect(cornerRadius: 16))
                        }
                        if let error = discovery.error {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(visibleConnections.isEmpty ? "Connect an account" : "Connect another account") { adding = true }
                                .buttonStyle(.bordered)
                                .disabled(discovery.loading && discovery.connections.isEmpty)
                            Spacer()
                            Button("Check again") { attempt += 1 }
                                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(discovery.loading)
                        }
                    }
                    .frame(maxWidth: 440, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .background(AssistantStyle.canvas)
        .environment(\.appExperienceMode, .general)
        .sheet(item: $managing, onDismiss: { attempt += 1 }) { agent in
            NavigationStack {
                AgentAuthenticationScreen(agentId: agent.id)
                    .toolbar {
                        AppToolbarItem(placement: .confirmationAction) {
                            Button(t("common.done")) { managing = nil }.tint(.primary)
                        }
                    }
            }
            .environment(\.appExperienceMode, .general)
        }
        .task(id: "\(workspace.id):\(attempt)") {
            await discovery.load(workspace: workspace, stores: stores, force: attempt > 0,
                                 requiresBotSupport: !managesConnections)
        }
    }

    private func complete(_ agent: Agent) {
        discovery.recordReady(agent)
        if managesConnections { selected = nil; adding = false }
        onReady(agent)
    }

    private func detail(_ connection: AssistantConnection) -> String {
        switch connection.status {
        case .ready: "Already signed in"
        case .checking: "Checking sign-in…"
        case .signIn: "Found here · sign in to continue"
        case .unavailable: "Check this connection to continue"
        }
    }
}
