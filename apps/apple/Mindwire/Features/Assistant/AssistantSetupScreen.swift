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
    @State private var sheet: SetupSheet?
    @State private var refreshing = false
    @State private var error: String?
    @State private var attempt = 0
    @State private var restored = false

    private enum SetupSheet: String, Identifiable {
        case computer, cloud, subscription
        var id: String { rawValue }
    }

    private var workspace: Workspace? { workspaceID.flatMap(repository.get) }

    var body: some View {
        NavigationStack {
            Group {
                if let readyAgent {
                    preparation(agent: readyAgent)
                } else if let selectedAgent {
                    AgentSetupScreen(agent: selectedAgent, onRemoved: { self.selectedAgent = nil }) {
                        readyAgent = selectedAgent
                    }
                } else if let workspace {
                    connections(workspace)
                } else {
                    computers
                }
            }
            .navigationTitle(t(readyAgent != nil ? "assistant.setup.finish" : selectedAgent != nil || workspace != nil
                               ? "assistant.setup.ai" : "assistant.setup.computer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.tint(.primary)
                }
                if workspaceID != nil {
                    AppToolbarItem(placement: .topBarTrailing) {
                        Button(t("common.back")) { goBack() }.tint(.primary)
                    }
                }
            }
        }
        .task {
            if !restored {
                restored = true
                workspaceID = stores.experience.pendingWorkspaceID
                selectedAgent = stores.experience.pendingAgentID.flatMap(stores.agents.get)
                if selectedAgent?.workspaceId != workspaceID { selectedAgent = nil }
            }
            await repository.refreshIfNeeded()
        }
        .task(id: workspaceID) { await refreshAgents() }
        .onChange(of: stores.experience.pendingWorkspaceID) { _, id in
            // A pairing deep link may finish in the window's shared pairing sheet.
            if id != workspaceID, let id {
                workspaceID = id
                selectedAgent = nil; readyAgent = nil; preparedProject = nil; error = nil
            }
        }
        .observeWorkspaceCache(reloadAgents)
        .sheet(item: $sheet) { item in
            switch item {
            case .computer:
                AddServerScreen(presetType: .local) { connection in
                    if let workspace = stores.workspaces(forServerId: connection.id).first {
                        choose(workspace)
                    }
                }
            case .cloud:
                NewWorkspaceScreen(assistantCloud: true) { choose($0) }
            case .subscription:
                if let workspaceID {
                    NewAgentScreen(workspaceId: workspaceID, assistantSetup: true) { agent in
                        if let agent { select(agent); readyAgent = agent }
                        sheet = nil
                    }
                }
            }
        }
    }

    private var computers: some View {
        List {
            Section {
                Text(t("assistant.setup.computer.body"))
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            Section {
                option(t("assistant.setup.own"), detail: t("assistant.setup.own.body"), icon: .monitor) { sheet = .computer }
                option(t("assistant.setup.cloud"), detail: t("assistant.setup.cloud.body"), icon: .cloud) { sheet = .cloud }
            }
            if !repository.all.isEmpty {
                Section(t("assistant.setup.saved")) {
                    ForEach(repository.all) { workspace in
                        option(workspace.name,
                               detail: t(workspace.isCloud ? "assistant.setup.cloud" : "assistant.setup.own"),
                               icon: workspace.isCloud ? .cloud : .monitor) { choose(workspace) }
                    }
                }
            }
        }
        .refreshable { await repository.refresh() }
    }

    private func connections(_ workspace: Workspace) -> some View {
        List {
            Section {
                LabeledContent(t("assistant.computer"), value: workspace.name)
                Text(t("assistant.setup.ai.body")).foregroundStyle(.secondary)
            }
            if !agents.isEmpty {
                Section(t("assistant.setup.existing")) {
                    ForEach(agents) { agent in
                        Button { select(agent) } label: {
                            Label(agent.typeDisplayName, icon: .plug)
                        }
                        .tint(.primary)
                    }
                }
            }
            Section {
                Button { sheet = .subscription } label: {
                    Label(t("assistant.setup.connectAI"), icon: .plus)
                }
                .tint(.primary)
                if refreshing { ProgressView(t("assistant.setup.checking")) }
                if let message = stores.workspaceData.errors[workspace.id] {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                    Button(t("common.retry")) { Task { await refreshAgents(force: true) } }
                }
            } footer: {
                Text(t("assistant.setup.ai.cost"))
            }
        }
    }

    private func preparation(agent: Agent) -> some View {
        VStack(spacing: Spacing.lg) {
            AppLogo(size: 48)
            if let preparedProject {
                Text(t("assistant.setup.ready")).font(.title2.bold())
                Text(t("assistant.setup.folder")).foregroundStyle(.secondary)
                Button(t("assistant.start")) {
                    stores.experience.use(agent: agent, project: preparedProject)
                    onReady()
                    dismiss()
                }
                .buttonStyle(.glassProminent).controlSize(.large).tint(Palette.accent)
            } else if let error {
                Text(error).foregroundStyle(.secondary)
                Button(t("common.retry")) { attempt += 1 }.buttonStyle(.glass)
            } else {
                ProgressView()
                Text(t("assistant.setup.preparing")).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func option(_ title: String, detail: String, icon: AppIconName, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.md) {
                AppIcon(icon, size: 24).padding(.top, 2)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                AppIcon(.chevronRight).foregroundStyle(.tertiary)
            }
            .padding(.vertical, Spacing.sm)
        }
        .tint(.primary)
    }

    private func choose(_ workspace: Workspace) {
        workspaceID = workspace.id
        stores.experience.pendingWorkspaceID = workspace.id
        stores.experience.pendingAgentID = nil
        selectedAgent = nil; readyAgent = nil; preparedProject = nil; error = nil
    }

    private func select(_ agent: Agent) {
        stores.experience.pendingAgentID = agent.id
        selectedAgent = agent
    }

    private func goBack() {
        if selectedAgent != nil {
            selectedAgent = nil; readyAgent = nil; preparedProject = nil; error = nil
            stores.experience.pendingAgentID = nil
        } else {
            workspaceID = nil
            stores.experience.pendingWorkspaceID = nil
        }
    }

    private func reloadAgents() {
        agents = workspaceID.map { stores.availableAgents(forWorkspaceId: $0) } ?? []
    }

    private func refreshAgents(force: Bool = false) async {
        reloadAgents()
        guard let workspace else { return }
        refreshing = true
        defer { refreshing = false }
        if force { await stores.workspaceData.refresh(workspace) }
        else { await stores.workspaceData.refreshIfNeeded(workspace) }
        guard !Task.isCancelled else { return }
        reloadAgents()
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
