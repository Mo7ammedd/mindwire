import SwiftUI

struct WorkspaceCloudSettingsScreen: View {
    let model: WorkspaceManagementModel
    let workspaceModel: WorkspaceModel
    var onDelete: () -> Void = {}
    @State private var showIdentity = false
    @State private var showLifecycle = false
    @State private var showIdle = false
    @State private var showNewWorkspace = false
    @State private var confirmation: WorkspaceConfirmation?

    var body: some View {
        WorkspaceControlPage(title: "Workspace Settings", model: model, feature: .settings) {
            Section("General") {
                WorkspaceControlReadState(state: model.info)
                if let workspace = model.info.value {
                    Button { showIdentity = true } label: {
                        LabeledContent("Name & Identity", value: workspace.name ?? "Workspace")
                    }.tint(.primary)
                    WorkspaceCopyRow(title: "Workspace ID", value: workspace.id)
                    if let namespace = workspace.namespace { LabeledContent("Namespace", value: namespace) }
                }
            }
            Section("Lifecycle") {
                WorkspaceControlReadState(state: model.lifecycle)
                if let lifecycle = model.lifecycle.value {
                    Button { showLifecycle = true } label: {
                        LabeledContent("Mode & Restart", value: lifecycle.mode == "temporary" ? "Temporary" : "Persistent")
                    }.tint(.primary)
                    Button { showIdle = true } label: {
                        LabeledContent("Sleep When Idle", value: (lifecycle.idle?.sleepSeconds ?? 0) > 0 ? "On" : "Off")
                    }.tint(.primary)
                    if lifecycle.mode == "temporary" {
                        if let ttl = lifecycle.ttl { LabeledContent("Time to Live", value: ttl) }
                        if let expiry = lifecycle.ttlExpiresAt { LabeledContent("Expires", value: dateLabel(expiry)) }
                        Button("Renew Time to Live") {
                            Task { await model.execute(.renewTTL, title: "Renewing workspace…", refresh: [.settings]) }
                        }.disabled(model.isBusy)
                    }
                }
            }
            Section {
                if let image = model.info.value?.image { WorkspaceCopyRow(title: "Base Image", value: image) }
                Button("Create with a Different Image") { showNewWorkspace = true }
            } header: { Text("Image") } footer: { Text("To use a different base image, create a new workspace. Retained disks can move your files between compatible workspaces.") }
            if workspaceModel.caps.power { WorkspaceActionsView(model: workspaceModel) }
            Section {
                NavigationLink { WorkspaceArchivesScreen(model: model) } label: { Label("Backups", icon: .history) }
                DestructiveButton("Reinstall Workspace", icon: .rotateLeft) {
                    confirmation = .init(title: "Reinstall Workspace?",
                        message: "This permanently erases the workspace’s private filesystem, installed tools, and project files. Its ID, resources, and public URLs are kept. Create a backup first to keep your files.",
                        actionTitle: "Reinstall", destructive: true) {
                        await model.execute(.reinstall, title: "Reinstalling workspace…", refresh: Set(WorkspaceManagementFeature.allCases))
                    }
                }
                DestructiveButton("Delete Workspace", icon: .trash, action: onDelete)
            }
            .disabled(model.isBusy || workspaceModel.powerAction != nil)
        }
        .sheet(isPresented: $showIdentity) { WorkspaceIdentityEditor(model: model) }
        .sheet(isPresented: $showLifecycle) { WorkspaceLifecycleEditor(model: model) }
        .sheet(isPresented: $showIdle) { WorkspaceIdleEditor(model: model) }
        .sheet(isPresented: $showNewWorkspace) { NewWorkspaceScreen { _ in } }
        .workspaceConfirmation($confirmation)
    }
    private func dateLabel(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}

private struct WorkspaceIdentityEditor: View {
    let model: WorkspaceManagementModel
    @State private var name: String
    @State private var slug: String
    @State private var logo: String
    init(model: WorkspaceManagementModel) {
        self.model = model
        _name = State(initialValue: model.info.value?.name ?? "")
        _slug = State(initialValue: model.info.value?.slug ?? "")
        _logo = State(initialValue: model.info.value?.logo ?? "")
    }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanSlug: String { slug.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanLogo: String { logo.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        !cleanName.isEmpty && cleanName.count <= 128 &&
        (cleanSlug.isEmpty || cleanSlug.range(of: "^[a-z0-9][a-z0-9-]{1,126}[a-z0-9]$", options: .regularExpression) != nil) &&
        (cleanLogo.isEmpty || URL(string: cleanLogo)?.scheme == "https")
    }
    var body: some View {
        WorkspaceControlEditor(title: "Name & Identity", model: model, canSave: valid, save: {
            await model.execute(.identity(name: cleanName, slug: cleanSlug.isEmpty ? nil : cleanSlug,
                                          logo: cleanLogo.isEmpty ? nil : cleanLogo), title: "Saving workspace…", refresh: [.settings]) != nil
        }) {
            Section {
                TextField("Workspace Name", text: $name)
                TextField("Slug", text: $slug).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: { Text("Slugs use 3–128 lowercase letters, numbers, or hyphens. Leave it empty to remove the alias.") }
            Section {
                TextField("Logo URL (optional)", text: $logo).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: { Text("Use an HTTPS image URL, or leave it empty to use the image’s logo.") }
        }
    }
}

private struct WorkspaceLifecycleEditor: View {
    let model: WorkspaceManagementModel
    @State private var mode: String
    @State private var restart: String
    @State private var maxRestarts: Int
    @State private var ttl: String
    @State private var ttlAction: String
    @State private var removeOnExit: Bool
    init(model: WorkspaceManagementModel) {
        self.model = model
        let value = model.lifecycle.value
        _mode = State(initialValue: value?.mode ?? "permanent")
        _restart = State(initialValue: value?.restartPolicy ?? "always")
        _maxRestarts = State(initialValue: value?.maxRestarts ?? 10)
        _ttl = State(initialValue: value?.ttl ?? "30m")
        _ttlAction = State(initialValue: value?.ttlAction ?? "stop")
        _removeOnExit = State(initialValue: value?.removeOnExit ?? false)
    }
    private var valid: Bool {
        mode == "permanent" || ttl.range(of: "^[1-9][0-9]{0,6}[smhd]?$", options: .regularExpression) != nil
    }
    var body: some View {
        WorkspaceControlEditor(title: "Mode & Restart", model: model, canSave: valid, save: {
            await model.execute(.lifecycle(mode: mode, restartPolicy: mode == "temporary" ? "no" : restart,
                maxRestarts: maxRestarts, ttl: ttl, ttlAction: ttlAction, removeOnExit: removeOnExit),
                title: "Saving lifecycle…", refresh: [.settings, .publicAccess]) != nil
        }) {
            Section {
                Picker("Mode", selection: $mode) {
                    Text("Persistent").tag("permanent")
                    Text("Temporary").tag("temporary")
                }
            } footer: { Text("Persistent workspaces stay available until you stop them. Temporary workspaces expire after their time to live.") }
            if mode == "permanent" {
                Section("Restart Policy") {
                    Picker("Restart", selection: $restart) {
                        Text("Never").tag("no")
                        Text("On Failure").tag("on-failure")
                        Text("Always").tag("always")
                        if restart == "never" { Text("Never").tag("never") }
                        if restart == "unless-stopped" { Text("Unless Stopped").tag("unless-stopped") }
                    }
                    Stepper("Maximum Restarts: \(maxRestarts)", value: $maxRestarts, in: 0...100)
                }
            } else {
                Section {
                    TextField("Time to Live", text: $ttl).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("When Time Expires", selection: $ttlAction) {
                        Text("Stop").tag("stop")
                        if model.lifecycle.value?.pauseSupported == true { Text("Pause").tag("pause") }
                        Text("Delete").tag("remove")
                    }
                    Toggle("Remove on Exit", isOn: $removeOnExit)
                } footer: { Text(ttlAction == "remove" || removeOnExit ? "Deletion permanently removes the workspace and its private files." : "Use a duration such as 30m, 2h, or 1d.") }
            }
        }
    }
}
