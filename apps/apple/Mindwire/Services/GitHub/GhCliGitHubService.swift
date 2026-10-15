import Foundation

/// GitHub via the **`gh` CLI already signed in on a self-hosted workspace**. Listing and cloning
/// run as `gh` commands over the workspace's exec seam, so auth lives entirely on the server — the
/// app never holds a GitHub credential for this mode. A short-lived backend is built from the
/// account's `workspaceId` per call and disposed after.
final class GhCliGitHubService: GitHubService {
    private let stores: Stores

    init(stores: Stores) { self.stores = stores }

    func identity(workspaceId: String) async throws -> GHRestUser {
        let reference = GitHubAccount(id: newId(), login: "", mode: .ghCli, workspaceId: workspaceId, createdAt: isoNow())
        return try await withWorkspace(reference) { workspace in
            try await Self.json(GHRestUser.self, ["gh", "api", "user"], on: workspace)
        }
    }

    func owners(for account: GitHubAccount) async throws -> [GitHubOwner] {
        try await withWorkspace(account) { workspace in
            let user = try await Self.json(GHRestUser.self, ["gh", "api", "user"], on: workspace)
            let orgs = (try? await Self.json([GHRestUser].self, ["gh", "api", "user/orgs"], on: workspace)) ?? []
            return [GitHubOwner(login: user.login, kind: .user, avatarUrl: user.avatarUrl)]
                + orgs.map { GitHubOwner(login: $0.login, kind: .org, avatarUrl: $0.avatarUrl) }
        }
    }

    func repos(account: GitHubAccount, owner: GitHubOwner, query: String?) async throws -> [GitHubRepo] {
        try await withWorkspace(account) { workspace in
            let fields = "name,nameWithOwner,owner,description,isPrivate,primaryLanguage,stargazerCount,updatedAt,defaultBranchRef"
            let cmd = ["gh", "repo", "list", owner.login, "--json", fields, "--limit", "100"]
            let repos = try await Self.json([GHCliRepo].self, cmd, on: workspace).map { $0.toRepo() }
            return GitHubFilter.byName(repos, query: query)
        }
    }

    func authorization(repo: GitHubRepo?, account: GitHubAccount) async throws -> ProjectCloneAuth {
        ProjectCloneAuth(kind: "gh")
    }

    // MARK: - Workspace plumbing

    private func withWorkspace<T>(_ account: GitHubAccount,
                                _ body: (WorkspaceService) async throws -> T) async throws -> T {
        guard let workspaceId = account.workspaceId, let workspace = await WorkspaceRepository.shared.get(workspaceId) else {
            throw BackendError.message("This GitHub account isn't linked to a workspace.")
        }
        let backend = BackendFactory.make(forRuntime: workspace.runtime, stores: stores)
        do {
            let result = try await body(backend.workspace)
            await backend.dispose()
            return result
        } catch {
            await backend.dispose()
            throw error
        }
    }

    private static func json<T: Decodable>(_ type: T.Type, _ cmd: [String], on workspace: WorkspaceService) async throws -> T {
        let bytes = try await data(cmd, on: workspace)
        return try JSONDecoder().decode(T.self, from: bytes)
    }

    /// Reuse the workspace's signed-in CLI without exporting its token to the phone.
    /// JSON goes through a private input file so multiline PR text stays literal.
    static func request(_ method: String, _ path: String, json: Data?, on workspace: WorkspaceService) async throws -> Data {
        let args = ["gh", "api", "--hostname", "github.com", "--method", method,
                    "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", path]
        let shell = workspace.shell
        let command = args.map(shell.quote).joined(separator: " ")
        let script: String
        if let json {
            script = """
            set -eu
            export GH_PROMPT_DISABLED=1
            umask 077
            mindwire_pr_input=$(mktemp)
            trap 'rm -f "$mindwire_pr_input"' EXIT
            printf '%s' \(shell.quote(String(decoding: json, as: UTF8.self))) > "$mindwire_pr_input"
            \(command) --input "$mindwire_pr_input"
            """
        } else { script = "export GH_PROMPT_DISABLED=1\n" + command }
        return try await data(shell.command(script), on: workspace)
    }

    private static func data(_ cmd: [String], on workspace: WorkspaceService) async throws -> Data {
        let result = try await workspace.exec(cmd)
        if let code = result.exitCode, code != 0 {
            let detail = result.stderr.isEmpty ? "gh exited with code \(code)." : result.stderr
            throw BackendError.message(detail)
        }
        guard let data = result.stdout.data(using: .utf8) else {
            throw BackendError.message("gh returned no output.")
        }
        guard result.exitCode != nil, result.truncated != true else { throw BackendError.message(t("git.pr.incompleteResponse")) }
        return data
    }
}

/// GitHub via a generated **SSH key**. There's no API to list with, so the repo browser is
/// bypassed in the UI (the user pastes a repo). This adapter supplies the key for a daemon attempt;
/// listing returns empty.
final class SshKeyGitHubService: GitHubService {
    func owners(for account: GitHubAccount) async throws -> [GitHubOwner] { [] }
    func repos(account: GitHubAccount, owner: GitHubOwner, query: String?) async throws -> [GitHubRepo] { [] }

    func authorization(repo: GitHubRepo?, account: GitHubAccount) async throws -> ProjectCloneAuth {
        guard let pem = Keychain.get(KeychainKey.githubSshKey(account.id)), SSHKey.isPrivateKeyPEM(pem) else {
            throw BackendError.message("This SSH key is missing or invalid. Reconnect it.")
        }
        return ProjectCloneAuth(kind: "ssh", privateKey: pem)
    }
}
