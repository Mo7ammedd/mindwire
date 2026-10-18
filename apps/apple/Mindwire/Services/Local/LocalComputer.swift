#if targetEnvironment(macCatalyst)
import Foundation
import Observation

/// One bootstrap for the app, shared by windows. Navigation and typing never run it again.
@MainActor @Observable
final class LocalComputer {
    static let shared = LocalComputer()
    private(set) var preparing = true
    private(set) var workspaceId: String?
    private(set) var error: String?
    private var task: Task<Void, Never>?

    func prepare(stores: Stores, repository: WorkspaceRepository) async {
        if let task { await task.value; return }
        if let workspaceId, repository.get(workspaceId) != nil,
           error == nil, stores.workspaceData.errors[workspaceId] == nil { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--app-store-preview") {
            let project = stores.projects.list().first
            workspaceId = project?.workspaceId; preparing = false
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
                if let failure = stores.workspaceData.errors[workspace.id] {
                    throw BackendError.message(failure)
                }
                // General prepares its shared hidden context after choosing an AI.
                // Opening the desktop never creates an unrelated project at home.
            } catch { self.error = error.localizedDescription }
        }
        self.task = task
        await task.value
        self.task = nil
    }
}
#endif
