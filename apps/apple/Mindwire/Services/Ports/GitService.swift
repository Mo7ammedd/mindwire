import Foundation

/// Working-tree reads and compatibility mutations over workspace exec. GitModel
/// routes writes for registered projects through durable daemon operations when
/// supported. These commands always execute alongside the repository on the server.
protocol GitService: AnyObject {
    func status() async throws -> GitStatus
    func branches() async throws -> [GitBranch]
    func pullRequestContext() async throws -> GitPullRequestContext?
    func pullRequestComparison(head: String, baseBranch: String, baseHead: String, remoteHead: String?) async throws -> GitPullRequestComparison
    func comparisonDiff(_ comparison: GitPullRequestComparison, change: GitFileChange, unified: Int?) async throws -> GitDiff
    func switchBranch(_ name: String, remote: Bool) async throws
    func createBranch(_ name: String) async throws
    func identity() async throws -> GitIdentity
    func history(cursor: GitHistoryCursor?, limit: Int) async throws -> GitHistoryPage
    func commitDetails(_ commit: GitCommit) async throws -> GitCommitDetails
    func commitDiff(_ commit: GitCommit, change: GitFileChange, unified: Int?) async throws -> GitDiff
    func blob(path: String, rev: GitRev) async throws -> GitBlob
    /// `unified` widens the patch context lines (`-U<n>`); a huge value yields the whole file.
    func diff(path: String, staged: Bool, unified: Int?) async throws -> GitDiff
    func stage(_ paths: [String]) async throws
    func unstage(_ paths: [String]) async throws
    func discard(_ paths: [String]) async throws
    func commit(message: String, identity: GitIdentity?) async throws
}

extension GitService {
    func pullRequestContext() async throws -> GitPullRequestContext? { nil }
    func pullRequestComparison(head: String, baseBranch: String, baseHead: String, remoteHead: String?) async throws -> GitPullRequestComparison {
        throw BackendError.message(t("git.pr.previewUnavailable"))
    }
    func comparisonDiff(_ comparison: GitPullRequestComparison, change: GitFileChange, unified: Int?) async throws -> GitDiff {
        throw BackendError.message(t("git.pr.previewUnavailable"))
    }
}
