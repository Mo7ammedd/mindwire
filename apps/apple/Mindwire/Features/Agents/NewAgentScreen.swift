import SwiftUI

/// Saves a workspace profile and immediately prepares its CLI through the shared installation job.
struct NewAgentScreen: View {
    private let projectName: String?
    private let onFinished: ((Agent?) -> Void)?
    private let repository: WorkspaceRepository
    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model: NewAgentModel
    @State private var activeSheet: AgentCreationSheet?
    @State private var actions = WorkspaceActions()

    private enum AgentCreationSheet: Int, Identifiable {
        case workspaces, newWorkspace
        var id: Int { rawValue }
    }

    init(workspaceId: String? = nil, agentType: AgentID = .claudeCode, releaseCatalog: ReleaseCatalog = .shared,
         repository: WorkspaceRepository? = nil, projectName: String? = nil, onFinished: ((Agent?) -> Void)? = nil) {
        self.projectName = projectName
        self.onFinished = onFinished
        self.repository = repository ?? .shared
        _model = State(initialValue: NewAgentModel(workspaceId: workspaceId, agentType: agentType, releaseCatalog: releaseCatalog))
    }

    var body: some View {
        NavigationStack {
            if let agent = model.createdAgent {
                AgentSetupScreen(agent: agent, onRemoved: close) {
                    if let onFinished { onFinished(stores.agents.get(agent.id)) }
                    else {
                        dismiss()
                        if model.fixedWorkspaceId == nil { app.openAgent(agent.id) }
                    }
                }
                .toolbar {
                    AppToolbarItem(placement: .cancellationAction) {
                        Button(t("agentAuth.setup.close"), action: close).tint(.primary)
                    }
                }
            } else {
                agentStep
            }
        }
        .task { await reloadWorkspaces() }
        .task { await model.loadCatalog() }
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
                        Button(t(projectName == nil ? "newAgent.create" : "common.continue"), action: create)
                            .tint(.primary)
                            .disabled(model.workspaceId == nil || model.catalog.isEmpty || model.loadingCatalog)
                    }
                }
            }
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
            _ = try await model.create(stores: stores)
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
