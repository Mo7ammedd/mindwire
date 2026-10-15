import Foundation

/// GitHub via a user-supplied **personal access token**, talking to GitHub's REST API directly
/// (`api.github.com`). The token is read from the Keychain (never inlined in a stored record),
/// and sent write-only to the daemon for a selected operation or agent run.
final class TokenGitHubService: GitHubService {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func owners(for account: GitHubAccount) async throws -> [GitHubOwner] {
        let token = try requireToken(account)
        async let userTask = GitHubREST.get(GHRestUser.self, "/user", token: token, session: session)
        async let reposTask = visibleRepositories(token: token)
        let user = try await userTask
        let repos = try await reposTask
        return Self.owners(user: user, repositories: repos)
    }

    func repos(account: GitHubAccount, owner: GitHubOwner, query: String?) async throws -> [GitHubRepo] {
        let token = try requireToken(account)
        let repos = try await visibleRepositories(token: token)
            .filter { $0.owner.login.caseInsensitiveCompare(owner.login) == .orderedSame }.map { $0.toRepo() }
        return GitHubFilter.byName(repos, query: query)
    }

    private func visibleRepositories(token: String) async throws -> [GHRestRepo] {
        try await GitHubREST.getAll(GHRestRepo.self, "/user/repos?per_page=100&sort=updated", token: token, session: session)
    }

    /// Repository visibility works for fine-grained tokens even when /user/orgs
    /// is unavailable. Include repositories owned by collaborators as well.
    static func owners(user: GHRestUser, repositories: [GHRestRepo]) -> [GitHubOwner] {
        var owners: [String: GitHubOwner] = [:]
        for repo in repositories {
            owners[repo.owner.login.lowercased()] = GitHubOwner(login: repo.owner.login,
                kind: repo.owner.type == "Organization" ? .org : .user, avatarUrl: repo.owner.avatar_url)
        }
        if owners.isEmpty || owners[user.login.lowercased()] != nil {
            owners[user.login.lowercased()] = GitHubOwner(login: user.login, kind: .user, avatarUrl: user.avatarUrl)
        }
        return owners.values.sorted {
            if $0.login == user.login { return $1.login != user.login }
            if $1.login == user.login { return false }
            return $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending
        }
    }

    func authorization(repo: GitHubRepo?, account: GitHubAccount) async throws -> ProjectCloneAuth {
        let token = try requireToken(account)
        return ProjectCloneAuth(kind: "token", username: "x-access-token", token: token)
    }

    private func requireToken(_ account: GitHubAccount) throws -> String {
        guard let token = Keychain.get(KeychainKey.githubToken(account.id)), !token.isEmpty else {
            throw BackendError.message("This GitHub account is missing its access token. Reconnect it.")
        }
        return token
    }
}

/// Minimal GitHub REST client — bearer PAT, JSON, GitHub's API version header.
enum GitHubREST {
    private static let base = "https://api.github.com"

    struct Response<Value> {
        let value: Value
        let http: HTTPURLResponse
    }

    static func get<T: Decodable>(_ type: T.Type, _ path: String, token: String? = nil, session: URLSession = .shared) async throws -> T {
        try await response(type, path, token: token, session: session).value
    }

    static func response<T: Decodable>(_ type: T.Type, _ path: String, token: String? = nil,
                                       session: URLSession = .shared) async throws -> Response<T> {
        let response = try await request("GET", path, token: token, session: session)
        return Response(value: try JSONDecoder().decode(T.self, from: response.value), http: response.http)
    }

    static func request(_ method: String, _ path: String, json: Data? = nil, token: String? = nil,
                        session: URLSession = .shared) async throws -> Response<Data> {
        guard let url = URL(string: base + path) else { throw BackendError.message("Bad GitHub URL.") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = method
        req.httpBody = json
        if json != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        APILog.request(req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BackendError.message("No response from GitHub.") }
        // PR descriptions and repository metadata can be private. Log the status,
        // never the request/response body or the credential used to authorize it.
        APILog.note("GitHub \(method) \(path) → \(http.statusCode)")
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubAPIError(status: http.statusCode, message: GitHubREST.message(from: data, status: http.statusCode),
                                 requiresSSO: http.value(forHTTPHeaderField: "X-GitHub-SSO") != nil)
        }
        return Response(value: data, http: http)
    }

    static func getAll<T: Decodable>(_ type: T.Type, _ path: String, token: String, session: URLSession = .shared) async throws -> [T] {
        var result: [T] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let values = try await get([T].self, path + (path.contains("?") ? "&" : "?") + "page=\(page)", token: token, session: session)
            result += values
            if values.count < 100 { return result }
            page += 1
        }
    }

    private static func message(from data: Data, status: Int) -> String {
        if let error = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let details = (error["errors"] as? [Any])?.compactMap { detail in
                (detail as? String) ?? (detail as? [String: Any])?["message"] as? String
            }
            if let detail = details?.first(where: { !$0.isEmpty }) { return detail }
            if let message = error["message"] as? String, !message.isEmpty { return message }
        }
        return "GitHub request failed (\(status))."
    }
}

struct GitHubAPIError: LocalizedError {
    let status: Int
    let message: String
    let requiresSSO: Bool
    var errorDescription: String? {
        if status == 401 { return t("github.credential.tokenRejected") }
        if requiresSSO { return t("github.credential.authorizeSSO") }
        return message
    }
}
