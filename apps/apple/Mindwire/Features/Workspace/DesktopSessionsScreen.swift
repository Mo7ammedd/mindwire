import SwiftUI
import OblienKit

private struct DesktopConfirmation {
    let desktop: SavedWorkspaceDesktop
    let deleting: Bool
    var title: String { deleting ? "Delete Desktop?" : "Stop Desktop?" }
    var action: String { deleting ? "Delete Desktop" : "Stop Desktop" }
    var message: String {
        if !deleting { return "Apps on this desktop will close. Its profile and files are kept." }
        return desktop.id == "console"
            ? "Remove this desktop connection. The screen and workspace files are kept."
            : "Stop its apps and delete its private desktop profile. Project files in the workspace are kept."
    }
}

private extension View {
    func desktopConfirmation(_ confirmation: Binding<DesktopConfirmation?>, model: DesktopSessionsModel?, completed: @escaping () -> Void) -> some View {
        alert(confirmation.wrappedValue?.title ?? "Desktop",
              isPresented: Binding(get: { confirmation.wrappedValue != nil }, set: { if !$0 { confirmation.wrappedValue = nil } }),
              presenting: confirmation.wrappedValue) { value in
            Button(value.action, role: .destructive) {
                Task {
                    if value.deleting { await model?.delete(value.desktop) }
                    else { await model?.stop(value.desktop) }
                    if model?.operationError == nil { completed() }
                }
            }
            Button(t("common.cancel"), role: .cancel) {}
        } message: { value in Text(value.message) }
    }
}

/// Workspace and project entry points share the same picker and native viewer.
struct DesktopSessionsScreen: View {
    let workspaceId: String
    var project: Project? = nil
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: DesktopSessionsModel?
    @State private var viewer: SavedWorkspaceDesktop?
    @State private var pendingViewer: SavedWorkspaceDesktop?
    @State private var editor: Editor?
    @State private var confirmation: DesktopConfirmation?
    @State private var showSetup = false
    @State private var refreshID = 0

    init(workspaceId: String, project: Project? = nil, repository: WorkspaceRepository = .shared, model: DesktopSessionsModel? = nil) {
        self.workspaceId = workspaceId; self.project = project; self.repository = repository
        _model = State(initialValue: model)
    }

    private struct Editor: Identifiable {
        var desktop: SavedWorkspaceDesktop?
        var id: String { desktop?.id ?? "create" }
    }
    private var canObserve: Bool { viewer == nil && editor == nil && !showSetup && scenePhase == .active }

    var body: some View {
        NavigationStack {
            List {
                if let model {
                    if !model.loaded, model.loading {
                        HStack { Text("Loading desktops").foregroundStyle(.secondary); Spacer(); ProgressView() }
                    } else if let error = model.loadError, model.sessions.isEmpty {
                        Section {
                            WorkspaceControlEmptyState(title: "Desktops unavailable", description: error)
                            Button("Try Again") { Task { await model.refresh(force: true) } }.tint(.primary)
                            Button("Desktop Setup") { showSetup = true }.tint(.primary)
                        }
                    } else if model.sessions.isEmpty {
                        emptyState(model)
                    } else {
                        Section {
                            ForEach(model.sessions) { desktop in row(desktop, model: model) }
                        } footer: {
                            Text(model.isConsole ? "This Mac shares one screen across projects." : "Apps stay open when you disconnect.")
                        }
                        if let error = model.loadError {
                            Section { Text(error).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .contentMargins(.top, Spacing.sm, for: .scrollContent)
            .navigationTitle(project == nil ? "Desktops" : "Project Desktop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button(t("common.done")) { dismiss() }.tint(.primary) }
                AppToolbarItemGroup(placement: .topBarTrailing) {
                    if let model, !model.sessions.isEmpty, model.canCreate {
                        Button { editor = Editor() } label: { AppIcon(.plus) }
                            .accessibilityLabel("Create Desktop").tint(.primary)
                    }
                    Button { showSetup = true } label: { AppIcon(.settings) }
                        .accessibilityLabel("Workspace Desktop Setup").tint(.primary)
                }
            }
            .refreshable { await model?.refresh(force: true) }
        }
        .onAppear { prepareModel() }
        .task(id: "\(canObserve)-\(model?.hasPendingSessions == true)-\(refreshID)") {
            guard canObserve else { return }
            prepareModel()
            await model?.observeTransitions()
        }
        .sheet(item: $editor, onDismiss: {
            if let pendingViewer { viewer = pendingViewer; self.pendingViewer = nil }
            refreshID += 1
        }) { editor in
            if let model {
                DesktopSessionEditor(model: model, desktop: editor.desktop,
                    defaultName: project?.name ?? "Desktop") { desktop in
                    if editor.desktop == nil { pendingViewer = desktop }
                }
            }
        }
        .sheet(isPresented: $showSetup, onDismiss: { model?.invalidate(); refreshID += 1 }) {
            if let workspace = repository.get(workspaceId) {
                let workspaceModel = repository.model(for: workspace)
                if let controls = workspaceModel.management {
                    NavigationStack {
                        WorkspaceDesktopSettingsScreen(model: controls, workspaceModel: workspaceModel) { showSetup = false }
                            .toolbar { AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { showSetup = false }.tint(.primary) } }
                    }
                }
            }
        }
        .fullScreenCover(item: $viewer, onDismiss: { model?.invalidate(); refreshID += 1 }) { desktop in
            DesktopScreen(workspaceId: workspaceId, desktopId: desktop.id, desktopName: desktop.name, repository: repository)
        }
        .desktopConfirmation($confirmation, model: model) { refreshID += 1 }
        .alert("Desktop", isPresented: Binding(get: { editor == nil && model?.operationError != nil }, set: { if !$0 { model?.operationError = nil } })) {
            Button("OK") { model?.operationError = nil }
        } message: { Text(model?.operationError ?? "") }
    }

    private func emptyState(_ model: DesktopSessionsModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(project == nil ? "No desktops yet" : "A desktop for this project")
                    .font(.headline).foregroundStyle(.primary)
                Text(model.isConsole ? "This workspace uses one shared Mac screen." : "Open apps, test your UI, and watch your agent work.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if model.isConsole, project != nil {
                    Button { Task { if let desktop = await model.ensureProject() { viewer = desktop } } } label: {
                        if model.busy { ProgressView() } else { Text("Open Shared Desktop") }
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(Palette.onAccent).disabled(model.busy)
                } else if model.canCreate {
                    Button(model.pendingCreation == nil ? "Create Desktop" : "Resume Creation") { editor = Editor() }
                        .buttonStyle(.borderedProminent).foregroundStyle(Palette.onAccent)
                } else {
                    Text("This workspace’s desktop limit has been reached.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Spacing.sm)
        } footer: {
            if project != nil { Text("Your agents and this viewer use the same saved desktop.") }
        }
    }

    private func row(_ desktop: SavedWorkspaceDesktop, model: DesktopSessionsModel) -> some View {
        HStack(spacing: Spacing.md) {
            Button { viewer = desktop } label: {
                EntityRow {
                    Text(desktop.name)
                } subtitle: {
                    Text([desktop.sizeLabel, desktop.displayState].compactMap { $0 }.joined(separator: " · "))
                } icon: {
                    AppIcon(.monitor, decorative: true).foregroundStyle(Palette.accent)
                } accessory: {
                    if desktop.isTransitioning || model.activeId == desktop.id { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!desktop.canConnect || model.busy)
            .accessibilityIdentifier("desktop.session.\(desktop.id)")
            Button { editor = Editor(desktop: desktop) } label: { AppIcon(.info).foregroundStyle(.secondary) }
                .buttonStyle(.borderless).disabled(desktop.isTransitioning || model.busy)
                .accessibilityLabel("Settings for \(desktop.name)")
        }
        .contextMenu {
            Button { editor = Editor(desktop: desktop) } label: { Label("Desktop Settings", icon: .settings) }
            if desktop.isStopped {
                Button { Task { await model.start(desktop); refreshID += 1 } } label: { Label("Start Desktop", icon: .play) }
            } else if !desktop.isTransitioning {
                Button(role: .destructive) { confirmation = .init(desktop: desktop, deleting: false) } label: { Label("Stop Desktop", icon: .stop) }
            }
            if desktop.supportsDelete, !desktop.isTransitioning {
                Button(role: .destructive) { confirmation = .init(desktop: desktop, deleting: true) } label: { Label("Delete Desktop", icon: .trash) }
            }
        }
    }

    private func prepareModel() {
        guard model == nil, let workspace = repository.get(workspaceId) else { return }
        model = DesktopSessionsModel(remote: CloudDesktopSessionsClient(workspace: workspace, projectId: project?.id, stores: stores),
            recoveryKey: "mindwire.desktop.create.\(workspaceId).\(project?.id ?? "workspace")")
    }
}

struct DesktopSessionEditor: View {
    let model: DesktopSessionsModel
    let desktop: SavedWorkspaceDesktop?
    let completion: (SavedWorkspaceDesktop) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DesktopCreationDraft
    @State private var preset: String
    @State private var confirmation: DesktopConfirmation?

    private static let presets: [(String, DesktopResolution)] = [
        ("1280 × 800", .init(width: 1280, height: 800)),
        ("1440 × 900", .init(width: 1440, height: 900)),
        ("1920 × 1080", .init(width: 1920, height: 1080)),
        ("2560 × 1440", .init(width: 2560, height: 1440)),
    ]

    init(model: DesktopSessionsModel, desktop: SavedWorkspaceDesktop?, defaultName: String,
         completion: @escaping (SavedWorkspaceDesktop) -> Void) {
        self.model = model; self.desktop = desktop; self.completion = completion
        let value = desktop.map { DesktopCreationDraft(name: $0.name, resolution: $0.resolution) } ?? model.draft(name: defaultName)
        _draft = State(initialValue: value)
        _preset = State(initialValue: Self.presets.first { $0.1 == value.resolution }?.0 ?? "Custom")
    }
    private var resize: Bool { desktop?.supportsResize ?? !model.isConsole }
    private var canChangeResolution: Bool { currentDesktop?.canChangeResolution ?? true }
    private var pending: Bool { desktop == nil && model.pendingCreation != nil }
    private var currentDesktop: SavedWorkspaceDesktop? {
        guard let desktop else { return nil }
        return model.sessions.first { $0.id == desktop.id } ?? desktop
    }
    private var valid: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.name.utf8.count <= 80 else { return false }
        guard resize else { return true }
        guard let size = draft.resolution, let range = model.capabilities?.resolution else { return false }
        return (range.min.width...range.max.width).contains(size.width) && (range.min.height...range.max.height).contains(size.height)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Desktop name", text: $draft.name).textInputAutocapitalization(.sentences)
                        .accessibilityIdentifier("desktop.session.name")
                }
                .disabled(pending || model.busy)
                if resize, let range = model.capabilities?.resolution {
                    Section {
                        Picker("Resolution", selection: $preset) {
                            ForEach(Self.presets.filter { item in item.1.width >= range.min.width && item.1.height >= range.min.height && item.1.width <= range.max.width && item.1.height <= range.max.height }, id: \.0) { item in
                                Text(item.0).tag(item.0)
                            }
                            Text("Custom").tag("Custom")
                        }
                        if preset == "Custom" {
                            LabeledContent("Width") { TextField("Width", value: Binding(get: { draft.resolution?.width ?? 1280 }, set: { draft.resolution = .init(width: $0, height: draft.resolution?.height ?? 800) }), format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                            LabeledContent("Height") { TextField("Height", value: Binding(get: { draft.resolution?.height ?? 800 }, set: { draft.resolution = .init(width: draft.resolution?.width ?? 1280, height: $0) }), format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                        }
                    } header: { Text("Display") } footer: {
                        if !canChangeResolution { Text("Stop this desktop to change its resolution.") }
                        else { Text("\(range.min.width) × \(range.min.height) to \(range.max.width) × \(range.max.height). Smaller screens use fewer resources.") }
                    }
                    .disabled(pending || model.busy || !canChangeResolution)
                } else {
                    Section { Text("Screen size is managed in the operating system’s display settings.").font(.subheadline).foregroundStyle(.secondary) }
                }
                if let desktop = currentDesktop {
                    Section {
                        LabeledContent("Status", value: desktop.displayState)
                        LabeledContent("Session", value: desktop.id).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Section {
                        if desktop.isStopped {
                            Button { Task { await model.start(desktop); if model.operationError == nil { dismiss() } } } label: { Label("Start Desktop", icon: .play) }
                                .tint(.primary)
                        } else if !desktop.isTransitioning {
                            Button(role: .destructive) { confirmation = .init(desktop: desktop, deleting: false) } label: { Label("Stop Desktop", icon: .stop) }
                        }
                        if desktop.supportsDelete, !desktop.isTransitioning {
                            Button(role: .destructive) { confirmation = .init(desktop: desktop, deleting: true) } label: { Label("Delete Desktop", icon: .trash) }
                        }
                    }
                    .disabled(model.busy)
                }
                if pending, !model.busy {
                    Section { Text("Creation hasn’t been confirmed yet. Retry to recover the same desktop.").font(.footnote).foregroundStyle(.secondary) }
                }
                if let error = model.operationError { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationTitle(desktop == nil ? "New Desktop" : "Desktop Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button(t("common.cancel")) { dismiss() }.tint(.primary).disabled(model.busy) }
                AppToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: {
                        if model.busy { ProgressView() }
                        else { Text(desktop == nil ? (pending ? "Retry" : "Create") : "Save") }
                    }
                    .tint(.primary).disabled((!valid && !pending) || model.busy)
                    .accessibilityIdentifier("desktop.session.save")
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.busy)
        .desktopConfirmation($confirmation, model: model) { dismiss() }
        .onChange(of: preset) { _, value in
            if let size = Self.presets.first(where: { $0.0 == value })?.1 { draft.resolution = size }
        }
        .onAppear { model.operationError = nil }
    }
    private func save() {
        Task {
            let result: SavedWorkspaceDesktop?
            if let desktop { result = await model.save(desktop, name: draft.name, resolution: resize ? draft.resolution : nil) }
            else { result = await model.create(draft) }
            if let result { completion(result); dismiss() }
            else if desktop == nil, model.pendingCreation == nil { draft.requestId = UUID().uuidString }
        }
    }
}
