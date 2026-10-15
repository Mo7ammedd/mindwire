import Foundation

/// A read-only snapshot of the branch and origin that the user is about to publish.
/// The native PR form verifies this snapshot again before publishing.
struct GitPullRequestContext: Hashable {
    let repository: GitHubRepo
    let branch: String
    let head: String
    let baseBranch: String?
    let remoteHead: String?
    let commitCount: Int?
    let title: String
    /// Commits absent from origin's version of this branch, from local refs only.
    var unpushedCount: Int? = nil

    var needsPush: Bool { remoteHead != head }

    var isFeatureBranch: Bool {
        if let baseBranch { return branch != baseBranch }
        // An unfetched origin may not have a symbolic HEAD yet. The native form
        // resolves its default through the authenticated GitHub API on opening.
        return !["main", "master", "trunk"].contains(branch)
    }

    func matches(_ status: GitStatus?) -> Bool {
        status?.isRepo == true && status?.detached == false
            && status?.branch == branch && status?.head == head
    }

    func hasSameSource(as other: Self) -> Bool {
        repository.fullName == other.repository.fullName && branch == other.branch
            && head == other.head && baseBranch == other.baseBranch
    }

}

struct GitPullRequestDraft: Equatable {
    var title: String
    var body = ""
    var base: String
    var draft = false
    var expectedBaseHead: String? = nil

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 256
            && !base.isEmpty && body.utf8.count <= 65_536
    }
}

struct GitHubPullRequest: Codable, Equatable, Identifiable {
    var id: Int { number }
    let number: Int
    let title: String
    let htmlURL: URL
    let draft: Bool
    let head: Branch
    let base: Branch

    struct Branch: Codable, Equatable { let ref: String; let sha: String }
    enum CodingKeys: String, CodingKey { case number, title, draft, head, base; case htmlURL = "html_url" }
}

struct GitPullRequestPreparation {
    let defaultBranch: String
    let branches: [String]
    let existing: GitHubPullRequest?
    var branchHeads: [String: String] = [:]
}

/// The PR is the committed head compared with its merge base, independent of the
/// index and working directory. All diff reads use these immutable object IDs.
struct GitPullRequestComparison: Hashable {
    let baseBranch: String
    let baseHead: String
    let head: String
    let mergeBase: String
    let remoteHead: String?
    let commitCount: Int
    let files: [GitFileChange]
    let truncated: Bool
    let counts: GitLineStat

    init(baseBranch: String, baseHead: String, head: String, mergeBase: String, remoteHead: String?,
         commitCount: Int, files: [GitFileChange], truncated: Bool = false) {
        self.baseBranch = baseBranch; self.baseHead = baseHead; self.head = head
        self.mergeBase = mergeBase; self.remoteHead = remoteHead; self.commitCount = commitCount
        self.files = files; self.truncated = truncated
        self.counts = files.reduce(into: GitLineStat()) { total, file in
            total.additions += file.staged?.additions ?? 0
            total.deletions += file.staged?.deletions ?? 0
        }
    }

    var needsPush: Bool { head != remoteHead }
    var id: String { mergeBase + ":" + head }
    // Navigation links identify immutable revisions, not every file in a large PR.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.baseBranch == rhs.baseBranch && lhs.baseHead == rhs.baseHead && lhs.head == rhs.head
            && lhs.mergeBase == rhs.mergeBase && lhs.remoteHead == rhs.remoteHead
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(baseBranch); hasher.combine(baseHead); hasher.combine(head)
        hasher.combine(mergeBase); hasher.combine(remoteHead)
    }
}

enum GitPullRequestPreviewError: LocalizedError {
    case needsFetch
    var errorDescription: String? { t("git.pr.fetchNeeded") }
}

@MainActor
protocol GitPullRequestRemote {
    func prepare(_ context: GitPullRequestContext) async throws -> GitPullRequestPreparation
    func create(_ context: GitPullRequestContext, draft: GitPullRequestDraft) async throws -> GitHubPullRequest
}
