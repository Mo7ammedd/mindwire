import SwiftUI

/// Create a project two ways, chosen up front (native push navigation, no rigid wizard):
/// - **Screen 1:** choose *Clone a repository* or *Open a folder*, reusing a workspace if available.
/// - **Optional setup:** create a workspace, then continue the chosen project automatically.
/// - **Screen 2 (Clone):** choose repo + location + name → cloned into `<location>/<name>`.
/// - **Folder picker:** selecting a folder registers it directly, using the folder's name.
struct NewProjectScreen: View {
    var presetWorkspaceId: String?
    var libraryFolderId: String?
    var onSubmitted: (() -> Void)?
    var repository: WorkspaceRepository

    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var flow = ProjectStartFlow()
    private var source: Source { flow.source }
    @State private var name = ""
    @State private var path = ""                    // clone → location dir; folder → the chosen folder
    @State private var selectedWorkspaceId: String?
    private var workspaces: [Workspace] { repository.all }
    @State private var selectedRepo: GitHubRepo?
    @State private var selectedAccount: GitHubAccount?
    @State private var gitLifetime: GitCredentialLifetime = .run

    @State private var backend: Backend?
    @State private var backendFor: String?
    @State private var creating = false
    @StateObject private var cloner = ProjectCreationModel() // daemon operation presentation
    @State private var activeSheet: ProjectSheet?
    @State private var serviceInfo = ServiceUpdatePresentation()
    @State private var folderSelection: CreateProjectInput?
    @State private var submitFolderAfterDismissal = false
    @State private var firstAgentProject: ProjectStartResult?
    @State private var creationFinished = false

    typealias Source = ProjectStartFlow.Source

    /// Every selector owns its native navigation and cancellation controls.
    private enum ProjectSheet: Identifiable {
        case workspaces, newWorkspace, repos
        case folder(workspace: Workspace, service: WorkspaceService, source: Source, startPath: String)
        var id: Int {
            switch self {
            case .workspaces: return 0
            case .newWorkspace: return 1
            case .folder: return 2
            case .repos: return 3
            }
        }
    }

    init(presetWorkspaceId: String? = nil,
         libraryFolderId: String? = nil,
         presetRepo: GitHubRepo? = nil,
         presetAccount: GitHubAccount? = nil,
         repository: WorkspaceRepository? = nil,
         onSubmitted: (() -> Void)? = nil) {
        self.presetWorkspaceId = presetWorkspaceId
        self.libraryFolderId = libraryFolderId
        self.onSubmitted = onSubmitted
        self.repository = repository ?? .shared
        _selectedRepo = State(initialValue: presetRepo)
        _selectedAccount = State(initialValue: presetAccount)
        _name = State(initialValue: presetRepo?.name ?? "")
        // Arriving with a repo (from the repo browser) → skip the fork, straight to clone details.
        if presetRepo != nil {
            _flow = State(initialValue: ProjectStartFlow(presetSource: .clone))
        }
    }

    var body: some View {
        if let result = firstAgentProject {
            NewAgentScreen(workspaceId: result.workspaceId, projectName: result.operation.name) { _ in
                finishCreation(result)
            }
            .task {
                // Observe the existing clone while choosing/installing the harness. Cancelling
                // this view only detaches the observer; the daemon keeps the project operation.
                guard result.routes(in: stores).isEmpty else { return }
                do {
                    let completed = try await stores.workspaceData.observeProject(result.operation.id, workspaceId: result.workspaceId) { _ in }
                    if completed.status == "succeeded" {
                        _ = try await stores.workspaceData.projectResult(completed, workspaceId: result.workspaceId)
                    }
                } catch { /* The Projects list retains the operation and its recovery actions. */ }
            }
        } else {
            projectCreation
        }
    }

    private var projectCreation: some View {
        NavigationStack(path: $flow.path) {
            choiceStep
                .navigationTitle(t("newProject.title"))
                .navigationSubtitle(libraryFolderId.flatMap { stores.projectLibrary.folder($0)?.name } ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Child pickers own their cancellation action. Hiding the parent item while a
                    // sheet is active prevents iOS from merging both into the presented nav bar.
                    if activeSheet == nil, serviceInfo.sheet == nil {
                        AppToolbarItem(placement: .cancellationAction) {
                            Button(t("common.cancel")) { dismiss() }.tint(.primary).disabled(creating)
                        }
                    }
                }
                .navigationDestination(for: ProjectStartFlow.Step.self) { _ in
                    cloneDetails.onAppear {
                        flow.source = .clone
                        Task { await resolveDefaultFolder() }
                    }
                }
        }
        .serviceUpdatePresentation(repository: repository, presentation: serviceInfo)
        .onAppear(perform: reload)
        .onChange(of: repository.revision) { reconcileWorkspace() }
        .interactiveDismissDisabled(creating)
        .onChange(of: selectedWorkspaceId) { old, _ in
            if old != nil { path = "" }
            if let account = selectedAccount, account.mode == .ghCli,
               account.workspaceId != selectedWorkspaceId {
                selectedAccount = nil
                selectedRepo = nil
            }
            ensureBackend()
            if flow.path.last == .clone { Task { await resolveDefaultFolder() } }
        }
        .task(id: selectedWorkspaceId) {
            if let id = selectedWorkspaceId, let workspace = repository.get(id) {
                await stores.workspaceData.refreshIfNeeded(workspace)
            }
        }
        .onDisappear { if let backend { Task { await backend.dispose() } } }
        .sheet(item: $activeSheet, onDismiss: sheetDismissed) { sheet in
            switch sheet {
            case .workspaces:
                WorkspacePickerSheet(repository: repository, selectedWorkspaceId: selectedWorkspaceId) { workspace in
                    selectedWorkspaceId = workspace.id
                }
            case .newWorkspace:
                AddComputerScreen(repository: repository) { workspace in
                    reload()
                    selectedWorkspaceId = workspace.id
                    flow.didCreateWorkspace()
                }
            case .folder(let workspace, let service, let source, let startPath):
                // The picker keeps the workspace it opened on, even if the inventory refreshes.
                FilesSheet(workspace: service, basePath: "/", selectFolder: true, startPath: startPath) { picked in
                    if workspace.id == selectedWorkspaceId { path = picked }
                    if source == .folder {
                        let basename = (picked as NSString).lastPathComponent
                        folderSelection = .init(name: basename.isEmpty || basename == "/" ? workspace.name : basename,
                                                workspaceId: workspace.id, path: picked)
                        submitFolderAfterDismissal = true
                    }
                }
            case .repos:
                if let id = selectedWorkspaceId {
                    // Presented directly (GitHubReposScreen owns its NavigationStack) — one nav bar,
                    // one Cancel. Tap a repo → selected + dismissed (commit-on-tap).
                    GitHubReposScreen(workspaceId: id, showsCancel: true, commitOnTap: true,
                                      selectedRepo: selectedRepo, selectedAccount: selectedAccount) { account, repo in
                        selectedAccount = account
                        gitLifetime = .run
                        selectedRepo = repo
                        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = repo.name }
                    }
                }
            }
        }
    }

    // MARK: Screen 1 — workspace + how to start

    private var choiceStep: some View {
        Form {
            Section {
                Button { choose(.clone) } label: {
                    HStack {
                        choiceRow(t("newProject.choice.clone.title"), t("newProject.choice.clone.subtitle")) {
                            githubMark(.secondary, size: 24)
                        }
                        Spacer(minLength: Spacing.sm)
                        AppIcon(Icon.chevron).font(.footnote).foregroundStyle(.tertiary)
                    }
                }
                .tint(.primary)
                Button { choose(.folder) } label: {
                    HStack {
                        choiceRow(t("newProject.choice.folder.title"), t("newProject.choice.folder.subtitle")) {
                            AppIcon(.folder).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Spacing.sm)
                        AppIcon(Icon.chevron).font(.footnote).foregroundStyle(.tertiary)
                    }
                }
                .tint(.primary)
            } header: {
                Text(t("newProject.choice.title"))
            } footer: {
                if workspaces.isEmpty {
                    Text(t("newProject.workspace.next"))
                }
            }
            if !workspaces.isEmpty {
                workspaceSelection
                if let workspace = selectedWorkspace {
                    WorkspaceDaemonSection(workspace: workspace)
                }
            }
            submissionStatus
        }
        .disabled(creating)
    }

    private var workspaceSelection: some View {
        WorkspaceSelectionSection(repository: repository, selectedWorkspaceId: selectedWorkspaceId,
            footer: t("newProject.workspace.help"), accessibilityIdentifier: "newProject.workspace",
            onChoose: { activeSheet = .workspaces }, onCreate: { activeSheet = .newWorkspace })
    }

    private func choose(_ source: Source) {
        guard !creating else { return }
        cloner.clearError()
        folderSelection = nil
        present(flow.choose(source, hasWorkspace: selectedWorkspace != nil))
    }

    private func present(_ next: ProjectStartFlow.Presentation?) {
        switch next {
        case .workspace: activeSheet = .newWorkspace
        case .folder: openFolderPicker(source: .folder)
        case nil: break
        }
    }

    private func openFolderPicker(source: Source) {
        ensureBackend()
        guard let workspace = selectedWorkspace, let backend else { return }
        activeSheet = .folder(workspace: workspace, service: backend.workspace, source: source,
                              startPath: path.isEmpty ? "~" : path)
    }

    private func sheetDismissed() {
        let next = flow.workspaceSheetDismissed()
        if submitFolderAfterDismissal {
            submitFolderAfterDismissal = false
            if let folderSelection { createFolder(folderSelection) }
        } else {
            present(next)
        }
    }

    private func choiceRow<I: View>(_ title: String, _ subtitle: String, @ViewBuilder icon: () -> I) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            icon().frame(width: 26, height: 26)
        }
        .padding(.vertical, 2)
    }

    /// The GitHub brand mark (template SVG asset), tinted.
    private func githubMark(_ color: Color, size: CGFloat = 22) -> some View {
        Image("provider-github").renderingMode(.template).resizable().scaledToFit()
            .frame(width: size, height: size).foregroundStyle(color)
    }

    /// The native iOS "select" affordance (up/down chevron) — marks a row that opens a picker.
    private var selectArrow: some View {
        AppIcon(.chevronsUpDown).font(.caption).foregroundStyle(.tertiary)
    }

    // MARK: Clone details

    private var cloneDetails: some View {
        Form {
            workspaceSelection
            Section {
                Button { activeSheet = .repos } label: {
                    HStack {
                        Label {
                            Text(selectedRepo?.fullName ?? t("project.selectRepo"))
                                .foregroundStyle(.primary)
                        } icon: {
                            githubMark(selectedRepo == nil ? Palette.accent : .secondary, size: 20)
                        }
                        Spacer(minLength: Spacing.sm)
                        selectArrow
                    }
                }
                .tint(.primary).disabled(selectedWorkspace == nil)
            } header: {
                Text(t("project.repo.title"))
            }

            if selectedRepo != nil {
                Section {
                    LabeledContent(t("github.accounts.connection"), value: selectedAccount?.displayName ?? t("github.repos.public"))
                    if let selectedAccount, selectedAccount.mode != .oblienApp && selectedAccount.mode != .ghCli {
                        Picker(t("github.access.availability"), selection: $gitLifetime) {
                            ForEach(GitCredentialLifetime.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                } footer: {
                    if let selectedAccount {
                        Text(selectedAccount.mode == .oblienApp ? t("github.access.oblienReadOnly")
                             : (gitLifetime == .workspace ? t("github.access.workspaceHint") : t("github.access.runHint")))
                    } else {
                        Text(t("github.repos.publicHint"))
                    }
                }
            }

            Section {
                Button { openFolderPicker(source: .clone) } label: {
                    HStack {
                        Label(t("newProject.location"), icon: Icon.folder)
                        Spacer(minLength: Spacing.sm)
                        Text(path.isEmpty ? t("project.chooseFolder") : path)
                            .foregroundStyle(path.isEmpty ? Color.accentColor : .secondary)
                            .lineLimit(1).truncationMode(.middle)
                        selectArrow
                    }
                }
                .tint(.primary).disabled(creating || selectedWorkspace == nil)
            } header: {
                Text(t("newProject.clonePath"))
            } footer: {
                if selectedRepo != nil, !path.isEmpty {
                    Text(t("project.repo.willCloneInto", ["path": cloneTarget(base: path, projectName: sanitizedName)]))
                }
            }

            Section(t("newProject.section.name")) {
                TextField(t("newProject.namePlaceholder"), text: $name)
            }

            if let workspace = selectedWorkspace {
                WorkspaceDaemonSection(workspace: workspace)
            }
            submissionStatus
        }
        .disabled(creating)
        .navigationTitle(t("newProject.choice.clone.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if activeSheet == nil, serviceInfo.sheet == nil {
                AppToolbarItem(placement: .confirmationAction) {
                    Button(t("newProject.create")) { create() }
                        .fontWeight(.semibold).tint(Palette.accent)
                        .disabled(creating || !workspaceReady || !cloneDetailsValid)
                }
            }
        }
    }

    private var cloneDetailsValid: Bool {
        selectedWorkspaceId != nil && selectedRepo != nil
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private var submissionStatus: some View {
        if creating {
            Section {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                    Text(t("project.operation.submitting")).foregroundStyle(.secondary)
                }
            }
        } else if let message = cloner.errorMessage {
            Section {
                Label(message, icon: .warning).foregroundStyle(.red)
                if source == .folder, let folderSelection {
                    Button(t("common.retry")) { createFolder(folderSelection) }.tint(.primary)
                }
            }
        }
    }

    // MARK: Actions

    private func reload() {
        reconcileWorkspace()
        Task {
            await repository.refreshIfNeeded()
            reconcileWorkspace()
        }
    }

    private func reconcileWorkspace() {
        if selectedWorkspaceId.flatMap({ repository.get($0) }) == nil {
            selectedWorkspaceId = presetWorkspaceId.flatMap { repository.get($0)?.id } ?? workspaces.first?.id
        }
        ensureBackend()
    }

    /// Prefill the clone location with the workspace's home dir (an absolute `$HOME`) as a sensible,
    /// editable default. Clone branch only — folder projects pick their own folder.
    private func resolveDefaultFolder() async {
        guard path.isEmpty else { return }
        ensureBackend()
        guard let backend, let workspaceId = selectedWorkspaceId else { return }
        let home = try? await backend.workspace.homeDirectory()
        if let home, !home.isEmpty, path.isEmpty, selectedWorkspaceId == workspaceId { path = home }
    }

    /// (Re)build the backend for the selected workspace — used by the folder picker + clone.
    private func ensureBackend() {
        guard let id = selectedWorkspaceId, let workspace = repository.get(id) else {
            let old = backend
            backend = nil
            backendFor = nil
            if let old { Task { await old.dispose() } }
            return
        }
        if backendFor == id, backend != nil { return }
        let old = backend
        backend = BackendFactory.make(forRuntime: workspace.runtime, stores: stores)
        backendFor = id
        if let old { Task { await old.dispose() } }
    }

    private var selectedWorkspace: Workspace? {
        selectedWorkspaceId.flatMap { repository.get($0) }
    }

    private var workspaceReady: Bool {
        guard let id = selectedWorkspaceId else { return false }
        return DaemonWorkCoordinator.shared.states[.init(workspaceId: id)]?.canCreateProjects == true
    }

    private func create() {
        guard !creating, workspaceReady, let workspaceId = selectedWorkspaceId,
              let repo = selectedRepo, cloneDetailsValid else { return }
        let account = selectedAccount, name = self.name, lifetime = gitLifetime
        let destination = cloneTarget(base: path, projectName: sanitizedName)
        submit(workspaceId: workspaceId) {
            await cloner.clone(repo: repo, account: account, name: name, workspaceId: workspaceId,
                               destination: destination, stores: stores, lifetime: lifetime)
        }
    }

    private func createFolder(_ selection: CreateProjectInput) {
        submit(workspaceId: selection.workspaceId) {
            await cloner.createFolder(name: selection.name, workspaceId: selection.workspaceId,
                                      path: selection.path, stores: stores)
        }
    }

    private func submit(workspaceId: String, operation: @escaping @MainActor () async -> ProjectOperation?) {
        guard !creating, !creationFinished else { return }
        creating = true
        Task {
            let accepted = await operation()
            creating = false
            if let operation = accepted {
                if let libraryFolderId {
                    stores.projectLibrary.placeCreation(operation, workspaceId: workspaceId,
                        in: libraryFolderId, projects: stores.projects.list())
                }
                let result = ProjectStartResult(workspaceId: workspaceId, operation: operation)
                if result.needsAgent(in: stores) {
                    firstAgentProject = result
                } else {
                    finishCreation(result)
                }
            }
        }
    }

    private func finishCreation(_ result: ProjectStartResult) {
        guard !creationFinished else { return }
        creationFinished = true
        dismiss()
        onSubmitted?()
        result.navigate(in: app, libraryFolderId: libraryFolderId)
        if let workspace = repository.get(result.workspaceId) {
            Task { await stores.workspaceData.refreshIfNeeded(workspace) }
        }
    }

    /// The user's project name reduced to one safe path segment for the clone target.
    private var sanitizedName: String { Self.sanitizeDirectoryName(name) }

    /// `base/<project name>` — cloned into a subfolder named after the PROJECT (not the repo).
    /// ALWAYS absolute: when base is "/" (e.g. $HOME resolves to root) `dropLast()` empties it; it
    /// must NOT collapse to a bare relative name (git would clone into the shell's cwd and the
    /// recorded project path wouldn't resolve → "empty folder").
    private func cloneTarget(base: String, projectName: String) -> String {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        let dir = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"   // force absolute
        return dir == "/" ? "/\(projectName)" : "\(dir)/\(projectName)"
    }

    /// Reduce a free-text name to one safe directory segment: keep letters/digits/_/-, spaces→'-',
    /// drop everything else (incl. '/'); fall back to "project" so git never gets an empty target.
    private static func sanitizeDirectoryName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "project" }
        var out = ""
        for ch in trimmed {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { out.append(ch) }
            else if ch == " " { out.append("-") }
        }
        let cleaned = out.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return cleaned.isEmpty ? "project" : cleaned
    }
}
