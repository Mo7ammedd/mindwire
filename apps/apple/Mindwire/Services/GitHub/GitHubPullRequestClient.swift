import Foundation

/// One PR workflow for PAT and workspace `gh` authentication. Only the transport
/// changes; branch validation, duplicate detection and submission stay shared.
@MainActor
struct GitHubPullRequestClient: GitPullRequestRemote {
    let request: (_ method: String, _ path: String, _ json: Data?) async throws -> Data

    func prepare(_ context: GitPullRequestContext) async throws -> GitPullRequestPreparation {
        struct Repository: Decodable { let default_branch: String }
        struct Branch: Decodable {
            struct Commit: Decodable { let sha: String }
            let name: String
            let commit: Commit
        }
        let prefix = repositoryPath(context)
        async let metadata = decode(Repository.self, "GET", prefix)
        async let open = existing(context, base: nil)
        let repository = try await metadata
        var branches: [String] = []
        var heads: [String: String] = [:]
        var page = 1
        while true {
            try Task.checkCancellation()
            let batch = try await decode([Branch].self, "GET", prefix + "/branches?per_page=100&page=\(page)")
            branches += batch.map(\.name)
            for branch in batch { heads[branch.name] = branch.commit.sha }
            if batch.count < 100 { break }
            page += 1
        }
        let existing = try await open
        if heads[repository.default_branch] == nil {
            let branch = try await decode(Branch.self, "GET", prefix + "/branches/" + encode(repository.default_branch))
            heads[branch.name] = branch.commit.sha
        }
        return .init(defaultBranch: repository.default_branch,
            branches: Array(Set(branches + [repository.default_branch])).sorted(), existing: existing, branchHeads: heads)
    }

    func create(_ context: GitPullRequestContext, draft: GitPullRequestDraft) async throws -> GitHubPullRequest {
        guard draft.isValid, draft.base != context.branch else { throw BackendError.message(t("git.pr.invalidDraft")) }
        struct RemoteBranch: Decodable {
            struct Commit: Decodable { let sha: String }
            let commit: Commit
        }
        let remote = try await decode(RemoteBranch.self, "GET", repositoryPath(context) + "/branches/" + encode(context.branch))
        guard remote.commit.sha == context.head else { throw BackendError.message(t("git.pr.remoteChanged")) }
        if let expectedBase = draft.expectedBaseHead {
            let base = try await decode(RemoteBranch.self, "GET", repositoryPath(context) + "/branches/" + encode(draft.base))
            guard base.commit.sha == expectedBase else { throw BackendError.message(t("git.pr.baseChanged")) }
        }
        // Reopening the form or retrying after a lost response returns the same
        // open PR. It never changes an existing PR's title, base, or description.
        if let existing = try await existing(context, base: draft.base) { return existing }
        let body = try JSONSerialization.data(withJSONObject: [
            "title": draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            "body": draft.body, "head": context.branch, "base": draft.base, "draft": draft.draft,
        ])
        do {
            let created = try await decode(GitHubPullRequest.self, "POST", repositoryPath(context) + "/pulls", body)
            return try validate(created, context: context, base: draft.base)
        } catch {
            guard !Task.isCancelled, !error.isRequestCancellation else { throw error }
            // GitHub may have accepted the write before a timeout or 422 from a
            // concurrent submission. Recover by reading; never repeat the POST.
            if let found = try? await existing(context, base: draft.base) { return found }
            throw error
        }
    }

    private func existing(_ context: GitPullRequestContext, base: String?) async throws -> GitHubPullRequest? {
        var path = repositoryPath(context) + "/pulls?state=open&head=" + encode(context.repository.owner + ":" + context.branch)
        if let base { path += "&base=" + encode(base) }
        path += "&per_page=100"
        let pulls = try await decode([GitHubPullRequest].self, "GET", path)
        guard let pull = pulls.first(where: { $0.head.ref == context.branch && (base == nil || $0.base.ref == base) }) else { return nil }
        return try validate(pull, context: context, base: base)
    }

    private func validate(_ pull: GitHubPullRequest, context: GitPullRequestContext, base: String?) throws -> GitHubPullRequest {
        guard pull.number > 0, pull.head.ref == context.branch, base == nil || pull.base.ref == base,
              pull.htmlURL.scheme == "https", pull.htmlURL.host == "github.com",
              pull.htmlURL.user == nil, pull.htmlURL.password == nil,
              pull.htmlURL.path.lowercased() == "/\(context.repository.fullName)/pull/\(pull.number)".lowercased() else {
            throw BackendError.message(t("git.pr.incompleteResponse"))
        }
        return pull
    }

    private func decode<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, _ json: Data? = nil) async throws -> T {
        let data = try await request(method, path, json)
        return try JSONDecoder().decode(type, from: data)
    }
    private func repositoryPath(_ context: GitPullRequestContext) -> String {
        "/repos/\(encode(context.repository.owner))/\(encode(context.repository.name))"
    }
    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }
}
