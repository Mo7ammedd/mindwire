import Foundation

/// Browse repositories and obtain credentials for daemon-owned Git operations. This client
/// adapter never builds or executes git commands. Oblien tokens are minted per repository.
protocol GitHubService {
    func owners(for account: GitHubAccount) async throws -> [GitHubOwner]
    func repos(account: GitHubAccount, owner: GitHubOwner, query: String?) async throws -> [GitHubRepo]
    func authorization(repo: GitHubRepo?, account: GitHubAccount) async throws -> ProjectCloneAuth
}

extension GitHubService {
    func cloneAuth(repo: GitHubRepo, account: GitHubAccount) async throws -> ProjectCloneAuth {
        try await authorization(repo: repo, account: account)
    }
}
