import SwiftUI

/// One removal flow for project details and project rows. Keeping files always uses the
/// daemon's metadata endpoint; deleting files requires its own explicit confirmation.
@MainActor @Observable
final class ProjectRemovalActions {
    struct Request {
        let project: Project
        let deleteFiles: Bool
        let localOnly: Bool

        var title: String { t(deleteFiles ? "project.deleteFolder" : "project.removeFromProjects") }
        var message: String {
            t(deleteFiles ? "project.deleteFolder.body" : localOnly ? "project.removeUnavailable.body" : "project.removeFromProjects.body",
              ["name": project.name, "path": project.path])
        }
    }

    var confirmation: Request?
    var error: String?
    private(set) var running = false
    private(set) var removedProjectId: String?

    func confirm(_ project: Project, deleteFiles: Bool = false, repository: WorkspaceRepository) {
        guard !running else { return }
        confirmation = Request(project: project, deleteFiles: deleteFiles,
                               localOnly: !deleteFiles && repository.get(project.workspaceId) == nil)
    }

    func remove(_ request: Request, stores: Stores, repository: WorkspaceRepository) async {
        guard !running else { return }
        running = true
        error = nil
        defer { running = false }
        do {
            if request.localOnly {
                stores.forgetProject(request.project.id)
            } else {
                guard repository.get(request.project.workspaceId) != nil else {
                    throw BackendError.message(t("workspace.missing.body"))
                }
                if request.deleteFiles {
                    _ = try await stores.workspaceData.removeProjectFiles(request.project.id, confirmed: request.project)
                } else {
                    try await stores.workspaceData.removeProject(request.project.id)
                }
            }
            removedProjectId = request.project.id
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ProjectRemovalMenuItems: View {
    let project: Project
    let actions: ProjectRemovalActions
    let repository: WorkspaceRepository

    var body: some View {
        DestructiveButton(t("project.removeFromProjects"), icon: .minusCircle) {
            actions.confirm(project, repository: repository)
        }
        .disabled(actions.running)
        if repository.get(project.workspaceId) != nil {
            DestructiveButton(t("project.deleteFolder"), icon: Icon.trash) {
                actions.confirm(project, deleteFiles: true, repository: repository)
            }
            .disabled(actions.running)
        }
    }
}

private struct ProjectRemovalAlerts: ViewModifier {
    @Bindable var actions: ProjectRemovalActions
    let repository: WorkspaceRepository
    @Environment(\.stores) private var stores

    func body(content: Content) -> some View {
        content
            .alert(actions.confirmation?.title ?? "", isPresented: Binding(
                get: { actions.confirmation != nil }, set: { if !$0 { actions.confirmation = nil } }
            ), presenting: actions.confirmation) { request in
                Button(request.title, role: .destructive) {
                    Task { await actions.remove(request, stores: stores, repository: repository) }
                }
                Button(t("common.cancel"), role: .cancel) {}
            } message: { request in
                Text(request.message)
            }
            .alert(t("project.removeFailed"), isPresented: Binding(
                get: { actions.error != nil }, set: { if !$0 { actions.error = nil } }
            )) {
                Button(t("common.ok"), role: .cancel) {}
            } message: {
                Text(actions.error ?? "")
            }
    }
}

extension View {
    func projectRemovalAlerts(_ actions: ProjectRemovalActions, repository: WorkspaceRepository) -> some View {
        modifier(ProjectRemovalAlerts(actions: actions, repository: repository))
    }
}
