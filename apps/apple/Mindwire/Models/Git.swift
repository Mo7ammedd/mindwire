import Foundation

/// Which revision of a file to fetch for a diff side.
enum GitRev: String, Codable, Hashable {
    case head = "HEAD"
    case index = "INDEX"
    case worktree = "WORKTREE"
}

/// Coarse change kind (drives the row icon). Decoded leniently — an unknown
/// daemon value falls back to `.modified` rather than failing the whole status.
enum GitChangeKind: String, Codable, Hashable {
    case modified, added, deleted, renamed, copied, untracked, conflicted
}

struct GitBranch: Identifiable, Hashable {
    var id: String { (isRemote ? "refs/remotes/" : "refs/heads/") + name }
    let name: String
    var isCurrent = false
    var isRemote = false
    var upstream: String?
    var tip: String? = nil
}

struct GitIdentity: Codable, Hashable {
    var name = ""
    var email = ""

    var normalized: Self {
        Self(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
             email: email.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isValid: Bool {
        let value = normalized
        let parts = value.email.split(separator: "@", omittingEmptySubsequences: false)
        return !value.name.isEmpty && value.name.utf8.count <= 256 && value.email.utf8.count <= 320
            && parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
            && !value.email.contains(where: { $0.isWhitespace })
            && !(value.name + value.email).unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) || $0 == "<" || $0 == ">"
            }
    }
}

enum GitIdentityError: LocalizedError {
    case required
    var errorDescription: String? { t("git.identity.required") }

    /// Compatibility with existing services that have only a human-readable Git failure.
    static func matches(_ text: String) -> Bool {
        ["Author identity unknown", "Committer identity unknown", "Please tell me who you are",
         "unable to auto-detect email address", "empty ident name", "empty ident email",
         "no email was given", "no name was given"].contains { text.contains($0) }
    }
}

struct GitCommit: Identifiable, Hashable {
    let id: String
    let parents: [String]
    let authorName: String
    let authorEmail: String
    let date: Date
    let subject: String
    var shortID: String { String(id.prefix(8)) }
}

/// A fixed tip keeps pagination stable while another client adds commits to the branch.
struct GitHistoryCursor: Hashable {
    let tip: String
    let offset: Int
}

struct GitHistoryPage {
    let commits: [GitCommit]
    let next: GitHistoryCursor?
}

struct GitCommitDetails {
    let message: String
    let files: [GitFileChange]
    var truncated = false
}

/// The confirmation captures both the version to restore and the repository the user saw.
/// The daemon checks these guards again under the shared Git operation reservation.
struct GitRestorePlan: Identifiable {
    let commit: GitCommit
    let head: String
    let branch: String?
    var id: String { commit.id + ":" + head + ":" + (branch ?? "") }
    var request: GitOperationRequest {
        .init(action: .restoreCommit, commitId: commit.id, expectedHead: head, expectedBranch: branch)
    }
}

/// One entry from the daemon's `git status` — one per path, carrying both the
/// index (staged) and worktree status codes. A path can be changed on both sides
/// at once ("MM"); the model splits it into the right section(s).
/// +/- line counts for one side of a file's change.
struct GitLineStat: Codable, Hashable {
    var additions: Int = 0
    var deletions: Int = 0
}

struct GitFileChange: Codable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    var origPath: String?     // rename/copy source
    let kind: String          // raw kind from the daemon (mapped via `changeKind`)
    let index: String         // X code: "." | M A D R C U ?
    let worktree: String      // Y code
    var staged: GitLineStat?  // index↔HEAD counts
    var unstaged: GitLineStat? // worktree↔index counts

    var changeKind: GitChangeKind { GitChangeKind(rawValue: kind) ?? .modified }

    /// +/- counts for the section a row is shown in.
    func lineStat(staged: Bool) -> GitLineStat? { staged ? self.staged : unstaged }

    /// Display name (last path component).
    var name: String { (path as NSString).lastPathComponent }

    var isConflicted: Bool { index == "U" || worktree == "U" }
    var isUntracked: Bool { worktree == "?" }
    /// Has a staged change (something in the index different from HEAD).
    var isStaged: Bool { !isConflicted && !isUntracked && index != "." }
    /// Has an unstaged working-tree change (worktree differs from the index).
    var hasUnstagedChange: Bool { !isConflicted && !isUntracked && worktree != "." }
}

struct GitStatus: Codable, Hashable {
    let isRepo: Bool
    var root: String?
    var branch: String?
    var upstream: String?
    var ahead: Int
    var behind: Int
    var detached: Bool
    var files: [GitFileChange]
    /// Full immutable HEAD ID; nil for an unborn branch or an older response.
    var head: String? = nil

    static let notRepo = GitStatus(
        isRepo: false, root: nil, branch: nil, upstream: nil,
        ahead: 0, behind: 0, detached: false, files: []
    )
}

/// Raw content of one side of a diff, plus guards so the diff view can skip
/// binary or oversized files instead of feeding them to Monaco.
struct GitBlob: Codable, Hashable {
    let path: String
    let rev: String
    var binary: Bool = false
    var size: Int = 0
    var truncated: Bool = false
    var content: String = ""
}

/// Git's own view of a file's change: the unified patch + line counts. The Monaco
/// diff editor diffs the two `GitBlob`s itself; this powers `+/−` badges and (later)
/// hunk-level staging.
struct GitDiff: Codable, Hashable {
    let path: String
    let staged: Bool
    var binary: Bool = false
    var additions: Int = 0
    var deletions: Int = 0
    var patch: String = ""
    /// Older transports omit this; capped patches must not appear to be the complete change.
    var truncated: Bool? = nil
}
