import SwiftUI

/// Saves a workspace profile and immediately prepares its CLI through the shared installation job.
struct NewAgentScreen: View {
    private let projectName: String?
    private let embedded: Bool
    private let assistantSetup: Bool
    private let requiresBotSupport: Bool
    private let assistantWorkspace: Workspace?
    private let existingAgents: [Agent]
    private let onSelected: ((Agent) -> Void)?
    private let onFinished: ((Agent?) -> Void)?
    private let repository: WorkspaceRepository
    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model: NewAgentModel
    @State private var activeSheet: AgentCreationSheet?
    @State private var actions = WorkspaceActions()
    @State private var existingAgent: Agent?

    private enum AgentCreationSheet: Int, Identifiable {
        case workspaces, newWorkspace
        var id: Int { rawValue }
    }

    init(workspaceId: String? = nil, agentType: AgentID = .claudeCode, releaseCatalog: ReleaseCatalog = .shared,
         repository: WorkspaceRepository? = nil, projectName: String? = nil, assistantSetup: Bool = false, embedded: Bool = false,
         assistantWorkspace: Workspace? = nil, existingAgents: [Agent] = [], requiresBotSupport: Bool = true,
         onSelected: ((Agent) -> Void)? = nil,
         onFinished: ((Agent?) -> Void)? = nil) {
        self.projectName = projectName
        self.embedded = embedded
        self.assistantSetup = assistantSetup
        self.requiresBotSupport = requiresBotSupport
        self.assistantWorkspace = assistantWorkspace
        self.existingAgents = existingAgents
        self.onSelected = onSelected
        self.onFinished = onFinished
        self.repository = repository ?? .shared
        let model = NewAgentModel(workspaceId: workspaceId, agentType: agentType, releaseCatalog: releaseCatalog)
        if assistantSetup { model.name = "Mindwire" }
        _model = State(initialValue: model)
    }

    var body: some View {
        SetupNavigation(embedded: embedded) {
            if let agent = existingAgent ?? model.createdAgent {
                AgentSetupScreen(agent: agent, onRemoved: close) {
                    if let onFinished { onFinished(stores.agents.get(agent.id)) }
                    else {
                        dismiss()
                        if model.fixedWorkspaceId == nil { app.openAgent(agent.id) }
                    }
                }
                .toolbar {
                    if !embedded {
                        AppToolbarItem(placement: .cancellationAction) {
                            Button(t("agentAuth.setup.close"), action: close).tint(.primary)
                        }
                    }
                }
            } else if assistantSetup {
                assistantStep
            } else {
                agentStep
            }
        }
        .task { await reloadWorkspaces() }
        .task { await model.loadCatalog() }
        .task(id: model.workspaceId) {
            if assistantSetup && requiresBotSupport { await model.loadBotCatalog(stores: stores) }
        }
        .onChange(of: repository.revision) { reconcileWorkspace() }
        .workspaceActionAlerts(actions)
        .interactiveDismissDisabled(actions.running)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .workspaces:
                WorkspacePickerSheet(repository: repository, selectedWorkspaceId: model.pickedWorkspaceId) { workspace in
                    model.pickedWorkspaceId = workspace.id
                }
            case .newWorkspace:
                NewWorkspaceScreen { workspace in
                    Task {
                        await reloadWorkspaces()
                        model.pickedWorkspaceId = workspace.id
                    }
                }
            }
        }
    }

    // MARK: Step 1 — pick the agent

    private var agentStep: some View {
        Form {
            if model.needsWorkspacePicker {
                WorkspaceSelectionSection(repository: repository, selectedWorkspaceId: model.pickedWorkspaceId,
                    footer: t("newAgent.workspace.help"), accessibilityIdentifier: "newAgent.workspace",
                    onChoose: { activeSheet = .workspaces }, onCreate: { activeSheet = .newWorkspace })
            }
            if projectName == nil { nameSection }
            Section {
                if model.loadingCatalog && model.catalog.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    Picker(t("newAgent.section.agent"), selection: $model.agentType) {
                        ForEach(model.catalog) { descriptor in
                            AgentCatalogRow(descriptor: descriptor).tag(descriptor.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if let error = model.catalogError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button(t("common.retry")) { Task { await model.loadCatalog() } }
                }
            } header: {
                if let projectName {
                    Text(t("newProject.agent.body", ["name": projectName]))
                        .font(.subheadline).fontWeight(.regular).textCase(nil)
                } else {
                    Text(t("newAgent.section.agent"))
                }
            } footer: {
                if projectName != nil { Text(t("newProject.agent.workspaceHint")) }
            }
            if projectName != nil { nameSection }
        }
        .contentMargins(.top, projectName == nil ? nil : Spacing.sm, for: .scrollContent)
        .disabled(actions.running)
        .navigationTitle(t(projectName == nil ? "newAgent.title" : "newProject.agent.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if activeSheet == nil {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t(projectName == nil ? "common.cancel" : "newProject.agent.skip"), action: close)
                        .tint(.primary).disabled(actions.running)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    if actions.running {
                        ProgressView().accessibilityLabel(t("workspace.sync.loading"))
                    } else {
                        Button(t(projectName != nil ? "common.continue" : "newAgent.create"), action: create)
                            .tint(.primary)
                            .disabled(model.workspaceId == nil || model.catalog.isEmpty || model.loadingCatalog)
                    }
                }
            }
        }
    }

    private var availableServices: [AssistantAIService] {
        let available = Set((requiresBotSupport ? model.botEngines(existingAgents: existingAgents) : model.catalog).map(\.id))
        return AssistantAIService.allCases.filter { available.contains($0.agentType) }
    }

    private var assistantStep: some View {
        Group {
            if ApplePlatform.isDesktop {
                AssistantDesktopSetupPanel {
                    AssistantBotAvatar(botId: "mindwire", size: 72)
                    VStack(spacing: 10) {
                        Text(t("assistant.setup.ai")).font(.system(size: 28, weight: .semibold))
                        Text(t("assistant.setup.ai.body")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    assistantChoices
                }
            } else {
                AssistantPage {
                    AssistantSetupProgress(step: 1)
                    AssistantHeading(title: t("assistant.setup.ai"), detail: t("assistant.setup.ai.body"))
                    if let workspace = assistantWorkspace {
                        AssistantConnectionSummary(name: workspace.name, isCloud: workspace.isCloud)
                    }
                    assistantChoices
                } footer: {
                    Text(t("assistant.setup.ai.cost")).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .disabled(actions.running)
        .navigationTitle("Mindwire")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(actions.running)
        .toolbar {
            if !embedded {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel"), action: close).tint(.primary).disabled(actions.running)
                }
            }
        }
    }

    @ViewBuilder private var assistantChoices: some View {
        VStack(spacing: 14) {
            ForEach(availableServices) { service in
                AssistantServiceButton(service: service,
                                       busy: actions.running && model.agentType == service.agentType) {
                    connect(service)
                }
            }
        }
        if model.loadingCatalog && availableServices.isEmpty { ProgressView(t("assistant.setup.checking")) }
        if let error = model.catalogError {
            Text(error).font(.subheadline).foregroundStyle(.secondary)
            Button(t("common.retry")) { Task { await model.loadCatalog() } }.tint(.primary)
        }
        if !model.loadingCatalog && availableServices.isEmpty && model.catalogError == nil {
            Text(t("assistant.ai.unavailable")).font(.subheadline).foregroundStyle(.secondary)
            Button(t("common.retry")) { Task { await model.loadCatalog() } }.tint(.primary)
        }
    }

    private func connect(_ service: AssistantAIService) {
        guard !actions.running, model.workspaceId != nil, availableServices.contains(service) else { return }
        model.agentType = service.agentType
        // Reuse the workspace's profile, then let the same readiness gate verify its live auth.
        if let saved = existingAgents.first(where: { $0.agentType == service.agentType }),
           let agent = stores.agents.get(saved.id), agent.workspaceId == model.workspaceId {
            if let onSelected { onSelected(agent) }
            else {
                stores.experience.pendingAgentID = agent.id
                existingAgent = agent
            }
        } else {
            create()
        }
    }

    private var nameSection: some View {
        Section(t(projectName == nil ? "newAgent.section.name" : "newProject.agent.name")) {
            TextField(t("newAgent.namePlaceholder"), text: $model.name)
                .textInputAutocapitalization(.words)
        }
    }

    private func close() {
        if let onFinished { onFinished(nil) }
        else { dismiss() }
    }

    private func create() {
        actions.run {
            let agent = try await model.create(stores: stores)
            if assistantSetup {
                if let onSelected { onSelected(agent) }
                else { stores.experience.pendingAgentID = agent.id }
            }
        }
    }

    private func reloadWorkspaces() async {
        guard model.needsWorkspacePicker else { return }
        reconcileWorkspace()
        await repository.refreshIfNeeded()
        reconcileWorkspace()
    }

    private func reconcileWorkspace() {
        guard model.needsWorkspacePicker else { return }
        if model.pickedWorkspaceId.flatMap({ repository.get($0) }) == nil {
            model.pickedWorkspaceId = repository.all.first?.id
        }
    }
}
