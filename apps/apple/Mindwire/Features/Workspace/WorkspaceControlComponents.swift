import SwiftUI

enum WorkspaceDetailTab: String, CaseIterable { case overview = "Overview", manage = "Manage" }

struct WorkspaceConfirmation {
    var title: String
    var message: String
    var actionTitle: String
    var destructive = false
    var action: @MainActor () async -> Void
}
extension View {
    func workspaceConfirmation(_ confirmation: Binding<WorkspaceConfirmation?>) -> some View {
        alert(confirmation.wrappedValue?.title ?? "", isPresented: Binding(
            get: { confirmation.wrappedValue != nil },
            set: { if !$0 { confirmation.wrappedValue = nil } }
        ), presenting: confirmation.wrappedValue) { value in
            Button(value.actionTitle, role: value.destructive ? .destructive : nil) { Task { await value.action() } }
            Button(t("common.cancel"), role: .cancel) {}
        } message: { value in Text(value.message) }
    }
}

struct WorkspaceControlPage<Content: View>: View {
    let title: String
    let model: WorkspaceManagementModel
    let feature: WorkspaceManagementFeature
    var additionalRefresh: (() async -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        List {
            content()
            WorkspaceControlFeedback(model: model)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", icon: .refresh) { Task { await refresh() } }
                    .tint(.primary)
            }
        }
        .task { await model.refresh(feature) }
        .refreshable { await refresh() }
    }
    private func refresh() async {
        await model.refresh(feature, force: true)
        await additionalRefresh?()
    }
}

struct WorkspaceControlFeedback: View {
    let model: WorkspaceManagementModel
    var body: some View {
        if let title = model.actionTitle {
            Section { HStack(spacing: Spacing.sm) { ProgressView().controlSize(.small); Text(title).foregroundStyle(.secondary) } }
        }
        if let error = model.actionError {
            Section { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}

struct WorkspaceControlReadState<Value>: View {
    let state: WorkspaceControlValue<Value>
    var body: some View {
        if let error = state.error {
            Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
        } else if !state.loaded {
            HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
        }
    }
}

struct WorkspaceControlEmptyState: View {
    let title: String
    let description: String
    var body: some View {
        VStack(spacing: Spacing.xs) {
            Text(title).font(.headline).foregroundStyle(.primary)
            Text(description).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
        .listRowBackground(Color.clear)
    }
}

struct WorkspaceControlEditor<Content: View>: View {
    let title: String
    let model: WorkspaceManagementModel
    var saveTitle = "Save"
    var canSave = true
    let save: () async -> Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                content()
                    .disabled(model.isBusy)
                WorkspaceControlFeedback(model: model)
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button(t("common.cancel")) { dismiss() }.tint(.primary) }
                AppToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) { Task { if await save() { dismiss() } } }
                        .disabled(!canSave || model.isBusy)
                }
            }
        }
    }
}

struct WorkspaceCopyRow: View {
    let title: String
    let value: String
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: Spacing.sm) {
                Text(value).textSelection(.enabled).lineLimit(2)
                Button("Copy \(title)", icon: .copy) { UIPasteboard.general.string = value }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).tint(.secondary)
            }
        }
    }
}

enum WorkspaceControlFormat {
    static func capacity(_ mb: Int?) -> String {
        guard let mb else { return "—" }
        if mb < 1024 { return "\(mb) MiB" }
        return String(format: "%g GiB", Double(mb) / 1024)
    }
    static func status(_ value: String?) -> String {
        switch value {
        case "running": return "Running"
        case "suspended", "hibernated": return "Hibernated"
        case "paused": return "Paused"
        case "stopped", "shutdown", "exited": return "Stopped"
        case "starting", "booting", "creating", "provisioning": return "Starting"
        case "stopping": return "Stopping"
        case "hibernating", "snapshotting": return "Hibernating"
        case "resuming", "restoring": return "Resuming"
        case "ready": return "Ready"
        case "failed", "error": return "Needs attention"
        case "queued", "pending": return "Queued"
        default: return value?.replacingOccurrences(of: "_", with: " ").capitalized ?? "—"
        }
    }
}

struct WorkspaceManageLinks: View {
    let workspace: Workspace
    let model: WorkspaceModel
    let repository: WorkspaceRepository
    let openDesktop: () -> Void
    let openFiles: () -> Void
    let openTerminal: () -> Void
    var onDelete: () -> Void = {}

    var body: some View {
        Section("Workspace") {
            if model.caps.resources {
                NavigationLink {
                    List {
                        WorkspaceResourcesView(model: model)
                        if model.caps.power { WorkspaceActionsView(model: model) }
                        if let error = model.error { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
                    }
                    .navigationTitle("Resources & Activity").navigationBarTitleDisplayMode(.inline)
                    .refreshable { await model.load(force: true) }
                } label: { Label("Resources & Activity", icon: .chartLine) }
            }
            if model.caps.terminal { Button(action: openTerminal) { Label("Terminal", icon: Icon.terminal) }.tint(.primary) }
            if model.caps.files { Button(action: openFiles) { Label("Files", icon: Icon.folder) }.tint(.primary) }
            if let controls = model.management, controls.features.contains(.desktop) {
                NavigationLink { WorkspaceDesktopSettingsScreen(model: controls, workspaceModel: model, openDesktop: openDesktop) }
                    label: { Label("Desktop", icon: .monitor) }
            } else if !workspace.isCloud, repository.supportsDesktop(workspace.id) {
                Button(action: openDesktop) { Label("Desktop", icon: .monitor) }.tint(.primary)
            }
            NavigationLink { GitAccessSettingsScreen(workspaceId: workspace.id) }
                label: { Label(t("github.access.title"), icon: .key) }
        }
        if let controls = model.management {
            Section("Oblien") {
                if controls.features.contains(.disks) {
                    NavigationLink { WorkspaceDisksScreen(model: controls, workspaceModel: model, repository: repository) }
                        label: { Label("Disks & Software", icon: .hardDrive) }
                }
                if controls.features.contains(.workloads) {
                    NavigationLink { WorkspaceWorkloadsScreen(model: controls) }
                        label: { Label("Workloads", icon: .layers) }
                }
                if controls.features.contains(.network) {
                    NavigationLink { WorkspaceNetworkScreen(model: controls, workspaceId: workspace.id, repository: repository) }
                        label: { Label("Network", icon: .network) }
                }
                if controls.features.contains(.publicAccess) {
                    NavigationLink { WorkspacePublicAccessScreen(model: controls) }
                        label: { Label("Public Access", icon: .globe) }
                }
            }
            Section("Access & Settings") {
                if controls.features.contains(.ssh) {
                    NavigationLink { WorkspaceSSHScreen(model: controls) } label: { Label("SSH Access", icon: .terminal) }
                }
                if controls.features.contains(.apiAccess) {
                    NavigationLink { WorkspaceAPIAccessScreen(model: controls) } label: { Label("Runtime API", icon: .code) }
                }
                if controls.features.contains(.settings) {
                    NavigationLink { WorkspaceCloudSettingsScreen(model: controls, workspaceModel: model, onDelete: onDelete) }
                        label: { Label("Workspace Settings", icon: .sliders) }
                }
                if controls.features.contains(.archives) {
                    NavigationLink { WorkspaceArchivesScreen(model: controls) } label: { Label("Backups", icon: .history) }
                }
                if controls.features.contains(.logs) {
                    NavigationLink { WorkspaceLogsScreen(model: controls, source: .boot, title: "Workspace Logs") }
                        label: { Label("Workspace Logs", icon: .alignLeft) }
                }
            }
        }
        if let image = workspace.image { WorkspaceImageFooter(image: image) }
    }
}
