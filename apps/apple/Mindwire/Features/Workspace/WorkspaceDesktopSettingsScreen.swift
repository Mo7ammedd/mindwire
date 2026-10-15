import SwiftUI

struct WorkspaceDesktopSettingsScreen: View {
    let model: WorkspaceManagementModel
    let workspaceModel: WorkspaceModel
    let openDesktop: () -> Void
    @State private var choice = ""
    @State private var confirmation: WorkspaceConfirmation?
    private var installation: WorkspaceDesktopInstallation? { model.installation.value }
    private var choices: [WorkspaceDesktopInstallation.Choice] { installation?.choices ?? [] }
    private var selectedChoice: WorkspaceDesktopInstallation.Choice? { choices.first { $0.id == choice } ?? choices.first }
    private var enoughMemory: Bool {
        guard let minimum = selectedChoice?.minimumMemoryMb else { return true }
        return (model.info.value?.resources?.memoryMb ?? workspaceModel.resources?.memoryMb ?? 0) >= minimum
    }

    var body: some View {
        WorkspaceControlPage(title: "Desktop", model: model, feature: .desktop) {
            if installation?.isPending == true {
                Section {
                    ProgressView(progressTitle).padding(.vertical, Spacing.xs)
                    if let error = model.operationError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }
            } else if installation?.phase == "restart_required" {
                Section {
                    Text("Desktop is installed. Restart the workspace to finish setup.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Restart to Finish") { confirmRestart() }.disabled(workspaceModel.powerAction != nil)
                }
            }
            if model.desktop.value?.supported == true || installation?.isInstalled == true && installation?.phase != "restart_required" {
                Section {
                    if let access = model.desktop.value {
                        Toggle("Desktop Access", isOn: Binding(get: { access.enabled }, set: { enabled in
                            if enabled {
                                Task { await model.execute(.desktopAccess(true), title: "Enabling desktop…", refresh: [.desktop]) }
                            } else {
                                confirmation = WorkspaceConfirmation(title: "Disable Desktop Access?", message: "Desktop connections will close. The workspace and its programs keep running.", actionTitle: "Disable") {
                                    await model.execute(.desktopAccess(false), title: "Disabling desktop…", refresh: [.desktop])
                                }
                            }
                        })).disabled(model.isBusy || model.info.value?.isRunning != true)
                        LabeledContent("Display", value: access.enabled ? access.available ? "Ready" : "Preparing" : "Access disabled")
                    }
                    Button(action: openDesktop) { Label("Open Desktops", icon: .monitor) }
                        .disabled(model.isBusy || model.info.value?.isRunning != true)
                } footer: {
                    Text("Connect using Mindwire’s native desktop viewer. Connecting enables desktop access if needed.")
                }
            }
            if installation?.installable == true, installation?.isInstalled != true, installation?.isPending != true,
               installation?.phase != "runtime_upgrade_required" {
                Section {
                    if !choices.isEmpty {
                        Picker("Environment", selection: $choice) {
                            ForEach(choices) { Text($0.label).tag($0.id) }
                        }
                        if let selectedChoice {
                            Text(selectedChoice.description ?? "Prepared desktop software.").font(.subheadline).foregroundStyle(.secondary)
                            if let memory = selectedChoice.minimumMemoryMb {
                                LabeledContent("Minimum Memory", value: WorkspaceControlFormat.capacity(memory))
                            }
                        }
                    } else {
                        Text("Install Cinnamon, a browser, a file manager, and a terminal. This needs internet access, 2 GiB RAM, and 3 GiB free disk space.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !enoughMemory { Text("Increase the workspace’s memory before adding this desktop.").font(.footnote).foregroundStyle(.secondary) }
                    Button(installTitle) { install() }
                        .disabled(model.isBusy || !enoughMemory || (choices.isEmpty && model.info.value?.isRunning != true) || model.info.value?.hasSavedExecution == true)
                } header: { Text("Desktop Setup") } footer: {
                    if !choices.isEmpty { Text(model.info.value?.isRunning == true ? "Adding desktop restarts the workspace. Running programs stop; files are kept." : "The workspace stays stopped until you start it.") }
                }
            }
            if let value = installation, value.phase == "failed" {
                Section { Text(value.error ?? "Desktop preparation failed. Check the workload logs and retry.").font(.footnote).foregroundStyle(.secondary) }
            }
            if installation?.phase == "runtime_upgrade_required" {
                Section { Text("Update the Oblien workspace runtime before installing desktop.").font(.subheadline).foregroundStyle(.secondary) }
            } else if model.info.value?.isRunning == false, installation?.isPending != true {
                Section {
                    Button("Start Workspace") { Task { await workspaceModel.power(.start); await model.refresh(.desktop, force: true) } }
                        .disabled(workspaceModel.powerAction != nil || model.isBusy)
                } footer: { Text("Start the workspace to connect to its desktop.") }
            } else if installation?.installable == false, model.desktop.value?.supported == false {
                Section { WorkspaceControlEmptyState(title: "Desktop unavailable", description: "This image does not provide a compatible desktop. Terminal and files remain available.") }
            }
            if !model.installation.loaded || model.installation.error != nil { Section { WorkspaceControlReadState(state: model.installation) } }
            if model.desktop.error != nil { Section { WorkspaceControlReadState(state: model.desktop) } }
        }
        .onChange(of: choices.map(\.id), initial: true) { _, ids in if !ids.contains(choice) { choice = ids.first ?? "" } }
        .workspaceConfirmation($confirmation)
    }
    private var installTitle: String {
        if installation?.phase == "failed" { return "Retry Desktop Setup" }
        if choices.isEmpty { return "Install Desktop" }
        return model.info.value?.isRunning == true ? "Add Desktop & Restart" : "Add Desktop"
    }
    private var progressTitle: String {
        switch installation?.stage {
        case "starting": return "Starting workspace…"
        case "verifying": return "Checking desktop…"
        case "attaching": return "Attaching desktop software…"
        default: return "Preparing desktop…"
        }
    }
    private func install() {
        let restart = model.info.value?.isRunning == true && !choices.isEmpty
        let action: @MainActor () async -> Void = {
            await model.execute(.installDesktop(choice: selectedChoice?.id, restart: restart), title: "Preparing desktop…", refresh: [.desktop])
        }
        if restart {
            confirmation = WorkspaceConfirmation(title: "Add Desktop & Restart?", message: "Running programs and chats will stop. Your workspace files are kept.", actionTitle: "Add & Restart", action: action)
        } else { Task { await action() } }
    }
    private func confirmRestart() {
        confirmation = WorkspaceConfirmation(title: "Restart Workspace?", message: "Running programs and chats will stop while desktop setup finishes. Files are kept.", actionTitle: "Restart") {
            await workspaceModel.power(.restart)
            await model.refresh(.desktop, force: true)
        }
    }
}
