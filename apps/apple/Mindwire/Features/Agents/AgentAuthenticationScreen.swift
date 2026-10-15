import SwiftUI

/// Authentication is available as soon as the service has verified the CLI.
/// Uses the same session and method forms as first-time setup and agent settings.
struct AgentAuthenticationScreen: View {
    let agentId: String

    @Environment(\.stores) private var stores

    @State private var agent: Agent?
    @State private var model: DaemonSession?
    @State private var actions = WorkspaceActions()
    @State private var loaded = false

    init(agentId: String, session: DaemonSession? = nil) {
        self.agentId = agentId
        _model = State(initialValue: session)
    }

    var body: some View {
        Group {
            if let agent {
                AgentReadinessView(agent: agent, session: model, requiresAuthentication: false) { form }
            } else if loaded {
                ContentUnavailableView(t("agent.missing.title"), icon: .userCircle,
                                       description: Text(t("agent.missing.body")))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(t("agentAuth.section"))
        .navigationBarTitleDisplayMode(.inline)
        .agentManagement(agent: agent, session: model, actions: actions, showsAuthentication: false)
        .observeWorkspaceCache(reload)
        .task {
            reload()
            guard agent != nil else { return }
            let session = model ?? DaemonManager.shared.session(for: agentId, stores: stores)
            model = session
            await session.load()
        }
    }

    private func reload() {
        agent = stores.agents.get(agentId)
        loaded = true
    }

    private var form: some View {
        Form {
            if let agent {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayName).font(.headline)
                            Text(agent.typeDisplayName)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        AgentLogo(id: agent.agentType, size: 30)
                    }
                } footer: {
                    Text(t("agentAuth.manage.help"))
                }
            }

            if let model {
                AgentAuthSection(model: model)
            } else {
                Section { ProgressView() }
            }
        }
    }
}
