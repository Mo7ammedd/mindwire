import SwiftUI

/// Power actions share the workspace-owned operation state and use native confirmation alerts.
struct WorkspaceActionsView: View {
    let model: WorkspaceModel
    @State private var confirmation: WorkspaceConfirmation?
    private var controls: WorkspaceManagementModel? { model.management }
    private var busy: Bool { model.powerAction != nil || controls?.isBusy == true }

    var body: some View {
        Section(t("workspace.power.title")) {
            if let action = model.powerAction {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(t(action == .stop ? "workspace.power.stopping" : "workspace.power.starting")).foregroundStyle(.secondary)
                }
            } else {
                switch model.status?.power {
                case .running:
                    if controls?.lifecycle.value?.pauseSupported == true { transition("Pause", icon: .pauseCircle, command: .pause, message: "Programs will pause with their memory kept. Resume to continue.") }
                    if controls?.lifecycle.value?.snapshotSupported == true { transition("Hibernate", icon: .moon, command: .hibernate, message: "Save running programs and release the workspace’s memory. Resume to continue the saved session.") }
                    Button(t("workspace.restart"), icon: Icon.restart) { confirmPower(.restart) }.tint(.primary).disabled(busy)
                    DestructiveButton(t("workspace.stop"), icon: .stopCircle) { confirmPower(.stop) }
                        .disabled(model.powerAction != nil || controls?.actionTitle != nil)
                case .stopped:
                    let saved = ["paused", "suspended", "hibernated"].contains(model.status?.detail ?? "")
                    Button(saved ? "Resume Workspace" : t("workspace.start"), icon: .playCircle) { Task { await model.power(.start) } }
                        .tint(.primary).disabled(busy || model.status?.provisioning?.isFailed == true)
                    if model.status?.provisioning?.isFailed == true {
                        Text("Retry creation from Overview to finish setting up this workspace.").font(.footnote).foregroundStyle(.secondary)
                    }
                case .starting, .stopping:
                    HStack(spacing: Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text(WorkspaceControlFormat.status(model.status?.detail)).foregroundStyle(.secondary)
                    }
                case .unknown, nil:
                    Button("Refresh Workspace Status", icon: .refresh) { Task { await model.load(force: true) } }.tint(.primary)
                }
            }
        }
        .task { await controls?.refresh(.settings) }
        .workspaceConfirmation($confirmation)
    }
    private func confirmPower(_ action: PowerAction) {
        confirmation = .init(title: action == .stop ? "Stop Workspace?" : "Restart Workspace?",
            message: "Running programs and chats will stop. Your files are kept.", actionTitle: action == .stop ? "Stop" : "Restart", destructive: action == .stop) {
                await model.power(action)
            }
    }
    private func transition(_ title: String, icon: AppIconName, command: WorkspaceManagementCommand, message: String) -> some View {
        Button(title, icon: icon) {
            confirmation = .init(title: title + " Workspace?", message: message, actionTitle: title) {
                await controls?.execute(command, title: title == "Pause" ? "Pausing workspace…" : "Hibernating workspace…", refresh: [.settings])
            }
        }.tint(.primary).disabled(busy)
    }
}
