import Foundation

/// GitHub via the **Oblien GitHub App** (`api.oblien.com/github/*`), authenticated with the
/// app's Oblien session JWT. Goes through the shared `OblienAPI` actor, so token mint, Keychain
/// persistence and 401-refresh are reused. Clone uses a short-lived, repo-scoped clone token
/// minted on demand — no long-lived credential ever touches the device.
final class OblienGitHubService: GitHubService {
    private let api: OblienAPI

    init(api: OblienAPI = .shared) { self.api = api }

    func owners(for account: GitHubAccount) async throws -> [GitHubOwner] {
        let data = try await api.send("GET", "/github/user/orgs") ?? Data("[]".utf8)
        return try GitHubJSON.decode([GHOblienOwner].self, from: data).map { $0.toOwner() }
    }

    func repos(account: GitHubAccount, owner: GitHubOwner, query: String?) async throws -> [GitHubRepo] {
        let path: String
        switch owner.kind {
        case .user: path = "/github/repos/user?owner=\(owner.login.ghQueryValue)"
        case .org:  path = "/github/orgs/\(owner.login.ghPathSegment)/repos"
        }
        let data = try await api.send("GET", path) ?? Data("[]".utf8)
        let repos = try GitHubJSON.decode([GHOblienRepo].self, from: data).map { $0.toRepo() }
        return GitHubFilter.byName(repos, query: query)
    }

    func authorization(repo: GitHubRepo?, account: GitHubAccount) async throws -> ProjectCloneAuth {
        guard let repo else { throw BackendError.message(t("github.access.oblienReadOnly")) }
        let p = "/github/repos/\(repo.owner.ghPathSegment)/\(repo.name.ghPathSegment)/clone-token"
        let data = try await api.send("POST", p) ?? Data()
        let minted = try GitHubJSON.decode(GHCloneToken.self, from: data)
        // Older gateways return only an authenticated URL. Extract the credential;
        // never pass that URL as a project record or a git origin.
        let components = minted.cloneUrl.flatMap { URLComponents(string: $0) }
        let urlToken = components?.host?.lowercased() == "github.com" ? components?.password : nil
        guard let token = minted.token?.nilIfEmpty ?? urlToken?.nilIfEmpty else {
            throw BackendError.message("GitHub didn't return a clone token for this repository.")
        }
        return ProjectCloneAuth(kind: "token", username: "x-access-token", token: token,
                                expiresAt: minted.expiresAt, readOnly: true)
    }
}
