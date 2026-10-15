#if targetEnvironment(macCatalyst)
import Foundation
import Observation

/// One bootstrap for the app, shared by windows. Navigation and typing never run it again.
@MainActor @Observable
final class DesktopComputer {
    static let shared = DesktopComputer()
    private(set) var preparing = true
    private(set) var workspaceId: String?
    private(set) var projectId: String?
    private(set) var error: String?
    private var task: Task<Void, Never>?

    func prepare(stores: Stores, repository: WorkspaceRepository) async {
        if let task { await task.value; return }
        if let workspaceId, let projectId, repository.get(workspaceId) != nil,
           stores.projects.get(projectId)?.workspaceId == workspaceId { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--app-store-preview") {
            let project = stores.projects.list().first
            workspaceId = project?.workspaceId; projectId = project?.id; preparing = false
            return
        }
        #endif
        preparing = true
        error = nil
        let task = Task { @MainActor in
            defer { preparing = false }
            do {
                let endpoint = try await LocalComputerRuntime.shared.connect()
                guard let workspace = await repository.adopt(name: "This Mac",
                    runtime: .local(computerId: endpoint.computerId), spec: nil) else {
                    throw BackendError.message("This Mac couldn't be opened.")
                }
                workspaceId = workspace.id
                await stores.workspaceData.refresh(workspace)
                // Register a personal context in the same workspace registry used by
                // the phone. This references the existing home; it creates no folder.
                let existing = stores.projects.list().first {
                    $0.workspaceId == workspace.id && $0.path == endpoint.home
                }
                let project: Project
                if let existing { project = existing }
                else {
                    project = try await stores.workspaceData.createProject(
                        .init(name: "Personal", workspaceId: workspace.id, path: endpoint.home))
                }
                projectId = project.id
            } catch { self.error = error.localizedDescription }
        }
        self.task = task
        await task.value
        self.task = nil
    }
}
#endif
