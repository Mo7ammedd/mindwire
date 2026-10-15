import Foundation

/// Submission ends when the daemon acknowledges the operation. The projects list then renders
/// its cached progress independently of the lifetime of this form.
@MainActor
final class ProjectCreationModel: ObservableObject {
    @Published private(set) var isSubmitting = false
    @Published private(set) var errorMessage: String?

    func clearError() { if !isSubmitting { errorMessage = nil } }

    func createFolder(name: String, workspaceId: String, path: String, stores: Stores) async -> ProjectOperation? {
        await submit(data: stores.workspaceData, workspaceId: workspaceId) {
            ProjectCreateRequest(id: stores.workspaceData.projectRequestID(workspaceId: workspaceId, source: "folder", name: name, path: path),
                                 source: "folder", name: name, path: path)
        }
    }

    func clone(repo: GitHubRepo, account: GitHubAccount?, name: String,
               workspaceId: String, destination: String, stores: Stores,
               lifetime: GitCredentialLifetime = .run) async -> ProjectOperation? {
        await submit(data: stores.workspaceData, workspaceId: workspaceId) {
            var auth: ProjectCloneAuth?
            var connection: GitConnection?
            if let account {
                if account.mode == .ghCli && account.workspaceId != workspaceId {
                    throw BackendError.message(t("project.operation.accountWorkspace"))
                }
                let supported = stores.workspaceData.supportsGitAccess(workspaceId: workspaceId)
                if lifetime == .workspace && !supported { throw WorkspaceRegistryError.gitAccessUnavailable }
                connection = supported ? GitConnection(account: account, lifetime: lifetime) : nil
                auth = try await BackendFactory.githubService(for: account, stores: stores).cloneAuth(repo: repo, account: account)
            }
            let url = auth?.kind == "ssh" ? repo.sshUrl : repo.cloneUrl
            return ProjectCreateRequest(id: stores.workspaceData.projectRequestID(workspaceId: workspaceId, source: "clone", name: name,
                                          path: destination, repoUrl: url, authKind: auth?.kind ?? "", connectionID: connection?.id ?? "",
                                          lifetime: connection?.lifetime.rawValue ?? ""),
                                        source: "clone", name: name, path: destination, repoUrl: url, auth: auth, gitConnection: connection)
        }
    }

    func submit(data: WorkspaceDataRepository, workspaceId: String,
                request: @escaping @MainActor () async throws -> ProjectCreateRequest) async -> ProjectOperation? {
        guard !isSubmitting else { return nil }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await data.requireProjectSupport(workspaceId: workspaceId)
            try Task.checkCancellation()
            let request = try await request()
            try Task.checkCancellation()
            return try await data.startProject(request, workspaceId: workspaceId)
        } catch is CancellationError { return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
