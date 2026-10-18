import SwiftUI

/// Authentication is available as soon as the service has verified the CLI.
/// Uses the same session and method forms as first-time setup and agent settings.
struct AgentAuthenticationScreen: View {
    let agentId: String

    @Environment(\.stores) private var stores
    @Environment(\.appExperienceMode) private var experienceMode

    @State private var agent: Agent?
    @State private var model: DaemonSession?
    @State private var actions = WorkspaceActions()
    @State private var loaded = false
    @State private var settings: AgentSettingsModel?
    @State private var showingModels = false
    @State private var loadingModels = false
    @State private var settingsError: String?

    private var service: AssistantAIService? {
        experienceMode == .general ? agent.flatMap { AssistantAIService(agentType: $0.agentType) } : nil
    }

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
        .navigationTitle(service?.name ?? t("agentAuth.section"))
        .navigationBarTitleDisplayMode(.inline)
        .agentManagement(agent: experienceMode == .developer ? agent : nil, session: model, actions: actions, showsAuthentication: false)
        .environment(\.assistantAIService, service)
        .sheet(isPresented: $showingModels) {
            if let settings, let model {
                AgentQuickSettingsSheet(settings: settings, session: model, livePermissions: false,
                                        title: "Models", settingCanons: ["model", "reasoningEffort"]) {
                    try await model.saveConfig($0)
                }
            }
        }
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
                            Text(service?.name ?? agent.displayName).font(.headline)
                            Text(service == nil ? agent.typeDisplayName : "Manage your account and sign-in methods.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        if let service { AssistantServiceMark(service: service, size: 30) }
                        else { AgentLogo(id: agent.agentType, size: 30) }
                    }
                } footer: {
                    Text(service == nil ? t("agentAuth.manage.help") : "Changing this account also affects bots using it on this computer.")
                }
            }

            if let model {
                AgentAuthSection(model: model)
                if service != nil, model.capabilities?.models == true {
                    Section {
                        Button {
                            Task { await openModels(model) }
                        } label: {
                            HStack {
                                Label("Models", icon: .sliders)
                                Spacer()
                                if loadingModels { ProgressView() }
                                else { AppIcon(.chevronRight, size: 16).foregroundStyle(.secondary) }
                            }
                        }
                        .tint(.primary).disabled(loadingModels || model.working)
                        if let settingsError { Text(settingsError).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            } else {
                Section { ProgressView() }
            }
        }
    }

    private func openModels(_ session: DaemonSession) async {
        guard !loadingModels else { return }
        loadingModels = true; settingsError = nil
        defer { loadingModels = false }
        do {
            let config = try await session.config()
            let settings = AgentSettingsModel(agentId: agentId, stores: stores)
            settings.load()
            settings.adopt(schema: session.schema, config: config)
            self.settings = settings
            showingModels = true
        } catch { settingsError = error.localizedDescription }
    }
}
