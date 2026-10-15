import SwiftUI

/// The list's long-press menu and the workspace toolbar share the same actions and confirmations.
@MainActor @Observable
final class WorkspaceActionState {
    var target: Workspace?
    var renaming = false
    var removing = false
    var renameText = ""
    var recoveringComputer: Connection?
    var deleting = false
    var deletionError: String?

    func rename(_ workspace: Workspace) {
        target = workspace
        renameText = workspace.name
        renaming = true
    }

    func remove(_ workspace: Workspace) {
        target = workspace
        removing = true
    }
}

struct WorkspaceMenuActions: View {
    let workspace: Workspace
    let actions: WorkspaceActionState
    @Environment(\.stores) private var stores

    var body: some View {
        let computer = workspace.savedComputer(in: stores)
        Group {
            if let computer {
                Button("Reconnect Computer", icon: .refresh) { actions.recoveringComputer = computer }
            }
            Button(t("common.rename"), icon: .edit) { actions.rename(workspace) }
            DestructiveButton(computer == nil ? t("common.delete") : "Remove Computer", icon: .trash) {
                actions.remove(workspace)
            }
        }
        .disabled(actions.deleting)
    }
}

extension View {
    func workspaceActionPresentation(_ actions: WorkspaceActionState, repository: WorkspaceRepository,
                                     onDeleted: @escaping () -> Void = {}, onBackup: (() -> Void)? = nil) -> some View {
        modifier(WorkspaceActionPresentation(actions: actions, repository: repository,
                                             onDeleted: onDeleted, onBackup: onBackup))
    }
}

private struct WorkspaceActionPresentation: ViewModifier {
    @Bindable var actions: WorkspaceActionState
    let repository: WorkspaceRepository
    var onDeleted: () -> Void
    var onBackup: (() -> Void)?
    @Environment(\.stores) private var stores

    private var computer: Connection? { actions.target?.savedComputer(in: stores) }

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.recoveringComputer) { connection in
                ComputerRecoverySheet(serverId: connection.id, repository: repository)
            }
            .inputDialog(titleKey: "common.rename", isPresented: $actions.renaming,
                         text: $actions.renameText, confirmKey: "common.rename") {
                let name = actions.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let target = actions.target, !name.isEmpty else { return }
                Task { await repository.rename(target.id, to: name) }
            }
            .alert(computer == nil ? t("workspace.delete.title") : "Remove Computer?",
                   isPresented: $actions.removing, presenting: actions.target) { workspace in
                if let onBackup { Button(t("workspace.delete.backup"), action: onBackup) }
                Button(computer == nil ? t("workspace.delete.confirm") : "Remove Computer", role: .destructive) {
                    remove(workspace)
                }
                Button(t("common.cancel"), role: .cancel) {}
            } message: { workspace in
                if let computer {
                    Text(stores.connectionSync.enabled
                        ? "Remove \(computer.name) from Mindwire on your synced devices? Files, chats and running programs on the computer are kept."
                        : "Remove \(computer.name) and its cached projects and chats from this device? Files, chats and running programs on the computer are kept.")
                } else {
                    Text(t(workspace.runtime.sandbox == nil ? "workspace.delete.body" : "workspace.delete.sandboxBody", [
                        "projects": "\(stores.projects(forWorkspaceId: workspace.id).count)",
                    ]))
                }
            }
            .alert(t("workspace.delete.failed"), isPresented: Binding(
                get: { actions.deletionError != nil }, set: { if !$0 { actions.deletionError = nil } }
            )) {
                Button(t("common.ok"), role: .cancel) {}
            } message: {
                Text(actions.deletionError ?? "")
            }
    }

    private func remove(_ workspace: Workspace) {
        guard !actions.deleting else { return }
        actions.deleting = true
        Task {
            defer { actions.deleting = false }
            do {
                try await repository.delete(workspace.id)
                // The repository must finish before leaving the detail or showing the updated list.
                onDeleted()
            } catch {
                APILog.note("workspace[\(workspace.id)]: delete failed — \(error.localizedDescription.oneLine())")
                actions.deletionError = error.localizedDescription
            }
        }
    }
}

private extension Workspace {
    func savedComputer(in stores: Stores) -> Connection? {
        guard runtime.sandbox == nil, let id = runtime.serverId,
              let connection = stores.connections.get(id), connection.pairedComputer != nil else { return nil }
        return connection
    }
}
