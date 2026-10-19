import SwiftUI

/// A small consumer entry point into the existing pairing, provisioning and authentication
/// flows. It does not own another connection, installation queue or agent session.
struct AssistantSetupScreen: View {
    var repository: WorkspaceRepository = .shared
    var onReady: () -> Void
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var workspaceID: String?
    @State private var agents: [Agent] = []
    @State private var selectedAgent: Agent?
    @State private var readyAgent: Agent?
    @State private var preparedProject: Project?
    @State private var path: [SetupStep] = []
    @State private var error: String?
    @State private var attempt = 0
    @State private var restored = false
    @State private var preparingLocalComputer = ApplePlatform.isDesktop
    @State private var computerPreparation = AssistantComputerPreparation()
    @State private var computerAttempt = 0

    private enum SetupStep: String, Hashable {
        case computer, pairComputer, cloud, createCloud, prepareComputer, account
    }

    private var workspace: Workspace? { workspaceID.flatMap(repository.get) }

    var body: some View {
        NavigationStack(path: $path) {
            computers
            .navigationTitle("Mindwire")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if path.isEmpty {
                    AppToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { AppIcon(.close) }
                            .tint(.primary).accessibilityLabel(t("common.cancel"))
                    }
                }
            }
            .navigationDestination(for: SetupStep.self) { step in
                switch step {
                case .computer:
                    if repository.all.contains(where: AssistantComputerDestination.computer.includes) {
                        AssistantComputerPicker(destination: .computer, repository: repository, onChoose: choose) {
                            path.append(.pairComputer)
                        }
                    } else { pairComputer }
                case .pairComputer:
                    pairComputer
                case .cloud:
                    AssistantComputerPicker(destination: .cloud, repository: repository, onChoose: choose) {
                        path.append(.createCloud)
                    }
                case .createCloud:
                    NewWorkspaceScreen(assistantCloud: true, embedded: true) { choose($0) }
                case .prepareComputer:
                    prepareComputer
                case .account:
                    account
                }
            }
        }
        .task {
            defer { preparingLocalComputer = false }
            if !restored {
                restored = true
                let pending = stores.experience.pendingWorkspaceID.flatMap(repository.get)
                if let pending {
                    let pendingAgent = stores.experience.pendingAgentID.flatMap(stores.agents.get)
                    choose(pending)
                    if let pendingAgent, pendingAgent.workspaceId == workspaceID {
                        stores.experience.pendingAgentID = pendingAgent.id
                    }
                } else {
                    #if targetEnvironment(macCatalyst)
                    await useThisMac()
                    #endif
                }
            }
        }
        .onChange(of: stores.experience.pendingWorkspaceID) { _, id in
            // A pairing deep link may finish in the window's shared pairing sheet.
            if id != workspaceID, let id {
                if let workspace = repository.get(id) { choose(workspace) }
            }
        }
        .onChange(of: path) { _, path in
            if !path.contains(.account), !path.contains(.prepareComputer), workspaceID != nil { clearSelection() }
        }
        .observeWorkspaceCache(reloadAgents)
    }

    private var computers: some View {
        AssistantPage {
            AssistantSetupProgress(step: 0)
            AssistantHeading(title: t("assistant.setup.computer"), detail: t("assistant.setup.computer.body"))
            VStack(spacing: 14) {
                #if targetEnvironment(macCatalyst)
                AssistantOption(title: "This Mac", detail: LocalComputer.shared.error ?? "", icon: .laptop) {
                    Task { await useThisMac() }
                }
                .disabled(preparingLocalComputer)
                if preparingLocalComputer { ProgressView() }
                #else
                AssistantDestinationCard(destination: .computer) { path.append(.computer) }
                #endif
                AssistantDestinationCard(destination: .cloud) { path.append(.cloud) }
            }
            Text(t("assistant.setup.computer.hint"))
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
    }

    #if targetEnvironment(macCatalyst)
    private func useThisMac() async {
        preparingLocalComputer = true
        defer { preparingLocalComputer = false }
        await LocalComputer.shared.prepare(stores: stores, repository: repository)
        guard !Task.isCancelled, path.isEmpty, workspaceID == nil, let id = LocalComputer.shared.workspaceId,
              let workspace = repository.get(id) else { return }
        choose(workspace)
    }
    #endif

    private var pairComputer: some View {
        AddServerScreen(presetType: .local, assistantSetup: true, embedded: true) { connection in
            if let workspace = stores.workspaces(forServerId: connection.id).first { choose(workspace) }
        }
    }

    private var prepareComputer: some View {
        AssistantPage {
            AssistantSetupProgress(step: 0)
            AssistantArtwork()
            AssistantHeading(title: t("assistant.setup.preparingComputer"),
                             detail: t("assistant.setup.preparingComputer.body"))
            if let workspace {
                AssistantConnectionSummary(name: workspace.name, isCloud: workspace.isCloud)
            }
            if let error = computerPreparation.error {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
            } else {
                ProgressView().accessibilityLabel(t("assistant.setup.preparingComputer"))
            }
        } footer: {
            if computerPreparation.error != nil {
                AssistantPrimaryButton(title: t("common.retry"), icon: .refresh) { computerAttempt += 1 }
            }
        }
        .task(id: "\(workspaceID ?? ""):\(computerAttempt)") {
            guard let workspaceID else { return }
            let ready = await computerPreparation.prepare(workspaceID) {
                try await stores.workspaceData.prepareDaemon(workspaceId: $0)
            }
            guard ready, !Task.isCancelled, self.workspaceID == workspaceID,
                  path.last == .prepareComputer else { return }
            reloadAgents()
            path[path.count - 1] = .account
            if let agent = stores.experience.pendingAgentID.flatMap(stores.agents.get),
               agent.workspaceId == workspaceID { select(agent) }
        }
    }

    private var account: some View {
        Group {
            if workspace == nil {
                AssistantPage {
                    AssistantHeading(title: t("assistant.setup.missingComputer"))
                } footer: {
                    AssistantPrimaryButton(title: t("common.back"), icon: .chevronLeft) {
                        if path.last == .account { path.removeLast() }
                    }
                }
            } else if computerPreparation.readyWorkspaceID != workspaceID {
                prepareComputer
            } else if let readyAgent {
                preparation(agent: readyAgent)
            } else if let selectedAgent {
                AgentSetupScreen(agent: selectedAgent, onRemoved: backToAccounts) {
                    guard workspaceID == selectedAgent.workspaceId, path.last == .account else { return }
                    readyAgent = selectedAgent
                }
            } else if let workspace {
                connections(workspace)
            }
        }
        .navigationBarBackButtonHidden(selectedAgent != nil)
        .toolbar {
            if selectedAgent != nil {
                AppToolbarItem(placement: .topBarLeading) {
                    Button(action: backToAccounts) { AppIcon(.chevronLeft) }
                        .tint(.primary).accessibilityLabel(t("common.back"))
                }
            }
        }
    }

    private func connections(_ workspace: Workspace) -> some View {
        NewAgentScreen(workspaceId: workspace.id, repository: repository, assistantSetup: true,
                       embedded: true, assistantWorkspace: workspace, existingAgents: agents, onSelected: select) { agent in
            if let agent, workspaceID == agent.workspaceId, path.last == .account { select(agent); readyAgent = agent }
        }
        .id(workspace.id)
    }

    private func preparation(agent: Agent) -> some View {
        AssistantPage {
            AssistantSetupProgress(step: 2)
            AssistantArtwork()
            AssistantHeading(title: t(preparedProject == nil ? "assistant.setup.preparing" : "assistant.setup.ready"))
            if let workspace {
                VStack(spacing: 14) {
                    AssistantConnectionSummary(name: workspace.name, isCloud: workspace.isCloud)
                    if let service = AssistantAIService(agentType: agent.agentType) {
                        HStack(spacing: 12) {
                            AssistantServiceMark(service: service, size: 20)
                            Text(service.name).font(.subheadline)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            if let error {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
            } else if preparedProject == nil {
                ProgressView().accessibilityLabel(t("assistant.setup.preparing"))
            }
        } footer: {
            if let preparedProject {
                AssistantPrimaryButton(title: t("assistant.start")) {
                    stores.experience.use(agent: agent, project: preparedProject)
                    onReady()
                    dismiss()
                }
            } else if error != nil {
                AssistantPrimaryButton(title: t("common.retry"), icon: .refresh) { attempt += 1 }
            }
        }
        .task(id: "\(agent.id):\(attempt)") {
            guard preparedProject == nil else { return }
            error = nil
            do {
                let project = try await AssistantContext.prepare(agent: agent, stores: stores)
                try Task.checkCancellation()
                preparedProject = project
            } catch {
                if !error.isRequestCancellation { self.error = error.localizedDescription }
            }
        }
    }

    private func choose(_ workspace: Workspace) {
        workspaceID = workspace.id
        stores.experience.pendingWorkspaceID = workspace.id
        stores.experience.pendingAgentID = nil
        selectedAgent = nil; readyAgent = nil; preparedProject = nil; error = nil
        computerPreparation.reset()
        // Returning from account choice lands in the same computer branch, including after
        // adding a computer. Pairing/creation does not remain underneath as an unfinished form.
        if ApplePlatform.isDesktop && workspace.runtime.isLocal { path = [.prepareComputer] }
        else { path = [workspace.isCloud ? .cloud : .computer, .prepareComputer] }
    }

    private func select(_ agent: Agent) {
        guard workspaceID == agent.workspaceId, computerPreparation.readyWorkspaceID == workspaceID,
              path.last == .account else { return }
        stores.experience.pendingAgentID = agent.id
        selectedAgent = agent
    }

    private func backToAccounts() {
        selectedAgent = nil; readyAgent = nil; preparedProject = nil; error = nil
        stores.experience.pendingAgentID = nil
    }

    private func clearSelection() {
        backToAccounts()
        computerPreparation.reset()
        workspaceID = nil
        stores.experience.pendingWorkspaceID = nil
        agents = []
    }

    private func reloadAgents() {
        agents = workspaceID.map { stores.availableAgents(forWorkspaceId: $0) } ?? []
    }
}

/// One ordinary project in the authoritative registry. Repeated setup reuses its directory
/// and project; it never moves existing files or creates a parallel conversation store.
enum AssistantContext {
    @MainActor static func prepare(agent: Agent, stores: Stores) async throws -> Project {
        try await withThrowingTaskGroup(of: Project.self) { group in
            group.addTask { @MainActor in try await prepareFolder(agent: agent, stores: stores) }
            group.addTask {
                try await Task.sleep(for: .seconds(90))
                throw BackendError.message(t("assistant.setup.timeout"))
            }
            defer { group.cancelAll() }
            guard let project = try await group.next() else { throw CancellationError() }
            return project
        }
    }

    @MainActor private static func prepareFolder(agent: Agent, stores: Stores) async throws -> Project {
        guard let workspaceID = agent.workspaceId else { throw WorkspaceRegistryError.missing }
        let session = DaemonManager.shared.session(for: agent.id, stores: stores)
        guard let service = session.workspace else { throw WorkspaceRegistryError.missing }
        let home = try await service.homeDirectory().trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/"), !home.contains("\n"), !home.contains("\0") else {
            throw BackendError.message(t("assistant.setup.homeError"))
        }
        let path = (home as NSString).appendingPathComponent(".mindwire-workspace")
        try Task.checkCancellation()
        try await stores.workspaceData.requireProjectSupport(workspaceId: workspaceID)
        let result = try await service.exec(service.shell.command("umask 077; " + service.shell.makeDir(path)))
        guard result.exitCode == 0 else {
            throw BackendError.message(result.stderr.nilIfEmpty ?? t("assistant.setup.folderError"))
        }
        try Task.checkCancellation()
        if let existing = stores.projects(forWorkspaceId: workspaceID).first(where: { $0.path == path }) {
            return existing
        }
        return try await stores.workspaceData.createProject(.init(name: "Mindwire", workspaceId: workspaceID, path: path))
    }
}
