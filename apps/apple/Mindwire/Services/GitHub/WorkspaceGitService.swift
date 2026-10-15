import Foundation

/// Shared by project setup, Source Control and agent turns. The daemon supplies
/// the authoritative binding; device credentials are never an implicit fallback.
@MainActor
enum GitCredentialResolver {
    static func authorization(connection: GitConnection?, repoURL: String?, workspaceId: String,
                              stored: Bool, stores: Stores) async throws -> ProjectCloneAuth? {
        guard let connection, !connection.usesServerCredentials else { return nil }
        if connection.lifetime == .workspace && stored { return nil }
        guard let account = stores.github.get(connection.id), account.mode.rawValue == connection.mode,
              account.mode != .ghCli || account.workspaceId == workspaceId else {
            throw GitAuthenticationError(message: t("github.access.missingAccount", ["account": connection.login]))
        }
        let repo = repoURL.flatMap(GitHubRepo.fromGitInput)
        if repoURL != nil && repo == nil { throw BackendError.message(t("github.repos.invalidURL")) }
        var auth = try await BackendFactory.githubService(for: account, stores: stores).authorization(repo: repo, account: account)
        auth.connectionId = connection.id
        return auth
    }
}

@MainActor
struct WorkspaceGitService {
    let workspaceId: String
    let stores: Stores

    func pendingRequest(projectId: String) -> GitOperationRequest? {
        GitOperationClient.receipts(defaults: stores.defaults).list()
            .first { $0.workspaceId == workspaceId && $0.projectId == projectId }?.request
    }

    func operationClient(projectId: String, minimumVersion: Int = 1) async throws -> GitOperationClient? {
        guard let http = try await stores.workspaceData.gitOperationsHTTP(workspaceId: workspaceId,
                                                                         minimumVersion: minimumVersion) else { return nil }
        guard let identity = stores.workspaceData.identity(workspaceId: workspaceId) else { throw WorkspaceRegistryError.missing }
        return GitOperationClient(http: http, workspaceId: workspaceId, registryId: identity,
            projectId: projectId, receipts: GitOperationClient.receipts(defaults: stores.defaults))
    }

    func authorization(action: GitAction, projectId: String) async throws -> ProjectCloneAuth? {
        if action == .commit {
            do {
                guard try await stores.workspaceData.gitOperationsHTTP(workspaceId: workspaceId, minimumVersion: 6) != nil else { return nil }
                let state = try await projectState(projectId)
                // Local commits don't mint expiring clone tokens. A configured
                // PAT/key can be supplied without a GitHub network request.
                guard state.repoUrl?.isEmpty == false, state.connection?.readOnly != true else { return nil }
                return try await GitCredentialResolver.authorization(connection: state.connection, repoURL: state.repoUrl,
                    workspaceId: workspaceId, stored: state.stored, stores: stores)
            } catch {
                if Task.isCancelled || error.isRequestCancellation { throw error }
                // Older services still support ordinary commits. New services
                // allow an offline commit and report auth only if a hook needs it.
                return nil
            }
        }
        guard action.isRemote else { return nil }
        let state = try await projectState(projectId)
        if action == .push && state.connection?.readOnly == true {
            throw GitAuthenticationError(message: t("github.access.oblienReadOnly"))
        }
        return try await GitCredentialResolver.authorization(connection: state.connection, repoURL: state.repoUrl,
            workspaceId: workspaceId, stored: state.stored, stores: stores)
    }

    /// Use the project's explicit/inherited binding, exactly as Push does. A
    /// native binding uses `gh` on this workspace; it never reads its token out.
    func pullRequestClient(projectId: String?, workspace: WorkspaceService) async throws -> any GitPullRequestRemote {
        let connection: GitConnection?
        if let projectId { connection = try await projectState(projectId).connection }
        else { connection = nil }
        guard let connection, !connection.usesServerCredentials else {
            return GitHubPullRequestClient { method, path, body in
                try await GhCliGitHubService.request(method, path, json: body, on: workspace)
            }
        }
        guard connection.mode == GitHubAuthMode.token.rawValue else {
            throw BackendError.message(t("git.pr.apiAccessRequired"))
        }
        guard let account = stores.github.get(connection.id), account.mode == .token else {
            throw BackendError.message(t("github.access.missingAccount", ["account": connection.login]))
        }
        // Read the Keychain afresh for each request so an edited credential is
        // immediately usable. Neither the model nor PR metadata retains a token.
        let provider = BackendFactory.githubService(for: account, stores: stores)
        return GitHubPullRequestClient { method, path, body in
            let auth = try await provider.authorization(repo: nil, account: account)
            return try await GitHubREST.request(method, path, json: body, token: auth.token).value
        }
    }

    func state() async throws -> WorkspaceGitState {
        try await client().decode("GET", "/workspace/git")
    }

    func projectState(_ id: String) async throws -> ProjectGitState {
        let http = try await client()
        return try await http.decode("GET", "/workspace/projects/\(http.encQuery(id))/git")
    }

    func setDefault(_ connection: GitConnection?, stored: Bool) async throws {
        let auth = connection?.lifetime == .workspace
            ? try await GitCredentialResolver.authorization(connection: connection, repoURL: nil, workspaceId: workspaceId, stored: stored, stores: stores)
            : nil
        let http = try await client()
        _ = try await http.run("PUT", "/workspace/git", json: try body(connection: connection, auth: auth))
    }

    func setProject(_ project: Project, connection: GitConnection?, stored: Bool) async throws {
        let auth = connection?.lifetime == .workspace
            ? try await GitCredentialResolver.authorization(connection: connection, repoURL: nil, workspaceId: workspaceId, stored: stored, stores: stores)
            : nil
        let http = try await client()
        var value = try body(connection: connection, auth: auth)
        guard let revision = project.revision else { throw WorkspaceRegistryError.updateRequired }
        value["expectedRevision"] = revision
        let snapshot: WorkspaceMetadata = try await http.decode("PUT", "/workspace/projects/\(http.encQuery(project.id))/git", json: value)
        // Reconcile through the existing revisioned workspace cache.
        try stores.workspaceData.apply(snapshot, workspaceId: workspaceId)
    }

    func forget(_ connectionId: String) async throws {
        let http = try await client()
        _ = try await http.run("DELETE", "/workspace/git/connections/\(http.encQuery(connectionId))", json: nil)
    }

    func run(_ operation: GitRemoteOperation, projectId: String) async throws -> GitRemoteResult {
        let state = try await projectState(projectId)
        if operation == .push && state.connection?.readOnly == true {
            throw GitAuthenticationError(message: t("github.access.oblienReadOnly"))
        }
        let auth = try await GitCredentialResolver.authorization(connection: state.connection, repoURL: state.repoUrl,
            workspaceId: workspaceId, stored: state.stored, stores: stores)
        let http = try await client()
        var body: [String: Any] = [:]
        if let auth { body["auth"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(auth)) }
        return try await http.decode("POST", "/workspace/projects/\(http.encQuery(projectId))/git/\(operation.rawValue)", json: body)
    }

    private func client() async throws -> DaemonHTTP { try await stores.workspaceData.gitHTTP(workspaceId: workspaceId) }

    private func body(connection: GitConnection?, auth: ProjectCloneAuth?) throws -> [String: Any] {
        var value: [String: Any] = ["connection": NSNull()]
        if let connection { value["connection"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(connection)) }
        if let auth { value["auth"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(auth)) }
        return value
    }
}
