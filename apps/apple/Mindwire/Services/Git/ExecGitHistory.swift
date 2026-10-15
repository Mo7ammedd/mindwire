import Foundation

/// History is read from the repository over the same cloud/SSH transport as working changes.
/// Every comparison uses immutable object IDs, so index edits and new commits cannot change it.
extension ExecGitService {
    func history(cursor: GitHistoryCursor?, limit: Int = 30) async throws -> GitHistoryPage {
        let tip: String
        if let cursor { tip = cursor.tip }
        else if let head = try await historyTip() { tip = head }
        else { return GitHistoryPage(commits: [], next: nil) }
        try Self.validateObjectID(tip)
        let count = min(max(limit, 1), 100)
        let offset = max(cursor?.offset ?? 0, 0)
        let data = try await readGit([
            "log", "--topo-order", "--no-show-signature", "--encoding=UTF-8", "-z",
            "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s",
            "--skip=\(offset)", "--max-count=\(count + 1)", tip, "--"
        ])
        let parsed = Self.parseHistory(data)
        guard !parsed.isEmpty || data.isEmpty else {
            throw BackendError.message(t("git.history.invalidResponse"))
        }
        let commits = Array(parsed.prefix(count))
        let more = parsed.count > count || data.count >= 2_000_000
        return GitHistoryPage(commits: commits, next: more ? .init(tip: tip, offset: offset + commits.count) : nil)
    }

    func commitDetails(_ commit: GitCommit) async throws -> GitCommitDetails {
        let comparison = try Self.comparison(commit)
        async let names = readGit(comparison + ["--name-status", "-z", "--"])
        async let counts = readGit(comparison + ["--numstat", "-z", "--"])
        async let message = readGit(["show", "--no-patch", "--no-show-signature", "--encoding=UTF-8", "--format=%B", commit.id, "--"], cap: 65_536)
        let (nameData, statData, messageData) = try await (names, counts, message)
        return GitCommitDetails(message: String(decoding: messageData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                                files: Self.parseCommitFiles(names: nameData, counts: statData),
                                truncated: nameData.count >= 2_000_000 || statData.count >= 2_000_000 || messageData.count >= 65_536)
    }

    func commitDiff(_ commit: GitCommit, change: GitFileChange, unified: Int?) async throws -> GitDiff {
        try await revisionDiff(Self.comparison(commit), change: change, unified: unified)
    }

    func pullRequestComparison(head: String, baseBranch: String, baseHead: String, remoteHead: String?) async throws -> GitPullRequestComparison {
        try Self.validateObjectID(head)
        try Self.validateObjectID(baseHead)
        do { _ = try await readGit(["cat-file", "-e", baseHead + "^{commit}"]) }
        catch {
            if Task.isCancelled || error.isRequestCancellation { throw error }
            let message = error.localizedDescription.lowercased()
            if ["not a valid object name", "bad object", "could not get object info", "missing object"].contains(where: message.contains) {
                throw GitPullRequestPreviewError.needsFetch
            }
            throw error
        }
        let common = try await readGit(["merge-base", baseHead, head])
        let mergeBase = String(decoding: common, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateObjectID(mergeBase)
        let comparison = try Self.comparison(from: mergeBase, to: head)
        async let names = readGit(comparison + ["--name-status", "-z", "--"])
        async let counts = readGit(comparison + ["--numstat", "-z", "--"])
        async let commits = readGit(["rev-list", "--count", baseHead + ".." + head, "--"])
        let (nameData, statData, commitData) = try await (names, counts, commits)
        guard let count = Int(String(decoding: commitData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), count >= 0 else {
            throw BackendError.message(t("git.readIncomplete"))
        }
        return GitPullRequestComparison(baseBranch: baseBranch, baseHead: baseHead, head: head,
            mergeBase: mergeBase, remoteHead: remoteHead, commitCount: count,
            files: Self.parseCommitFiles(names: nameData, counts: statData),
            truncated: nameData.count >= 2_000_000 || statData.count >= 2_000_000)
    }

    func comparisonDiff(_ comparison: GitPullRequestComparison, change: GitFileChange, unified: Int?) async throws -> GitDiff {
        try await revisionDiff(Self.comparison(from: comparison.mergeBase, to: comparison.head), change: change, unified: unified)
    }

    private func revisionDiff(_ comparison: [String], change: GitFileChange, unified: Int?) async throws -> GitDiff {
        let paths = Array(Set([change.path, change.origPath].compactMap { $0 })).sorted()
        let context = unified.map { ["-U\(max(0, $0))"] } ?? []
        async let patch = readGit(comparison + ["--patch", "--no-color", "--no-ext-diff", "--no-textconv"] + context + ["--"] + paths, cap: 1_000_000)
        async let stats = readGit(comparison + ["--numstat", "-z", "--"] + paths)
        let (patchData, statData) = try await (patch, stats)
        let tokens = Self.nulFields(statData)
        let counts = Self.parseNumstat(tokens)[change.path] ?? GitLineStat()
        let binary = tokens.contains { $0.hasPrefix("-\t-\t") }
        return GitDiff(path: change.path, staged: true, binary: binary,
                       additions: counts.additions, deletions: counts.deletions,
                       patch: binary ? "" : String(decoding: patchData, as: UTF8.self),
                       truncated: patchData.count >= 1_000_000)
    }

    private static func comparison(_ commit: GitCommit) throws -> [String] {
        try comparison(from: commit.parents.first, to: commit.id)
    }

    private static func comparison(from parent: String?, to head: String) throws -> [String] {
        try validateObjectID(head)
        var args = ["diff-tree", "--no-commit-id", "--root", "-r", "--find-renames"]
        // A merge is reviewed against its first parent, the branch before this commit.
        if let parent { try validateObjectID(parent); args.append(parent) }
        args.append(head)
        return args
    }

    private static func validateObjectID(_ id: String) throws {
        guard [40, 64].contains(id.utf8.count), id.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
        }) else { throw BackendError.message(t("git.history.invalidRevision")) }
    }

    /// Keep only complete NUL-terminated records if the transport cap cuts a large result.
    private static func nulFields(_ data: Data) -> [String] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if !fields.isEmpty { fields.removeLast() }
        return fields.map { String(decoding: $0, as: UTF8.self) }
    }

    static func parseHistory(_ data: Data) -> [GitCommit] {
        let fields = nulFields(data)
        var commits: [GitCommit] = []
        var i = 0
        while i + 5 < fields.count {
            let id = fields[i]
            guard (try? validateObjectID(id)) != nil, let time = TimeInterval(fields[i + 4]) else { break }
            commits.append(GitCommit(id: id, parents: fields[i + 1].split(separator: " ").map(String.init),
                                     authorName: fields[i + 2], authorEmail: fields[i + 3],
                                     date: Date(timeIntervalSince1970: time), subject: String(fields[i + 5].prefix(1024))))
            i += 6
        }
        return commits
    }

    static func parseCommitFiles(names: Data, counts: Data) -> [GitFileChange] {
        let fields = nulFields(names)
        let stats = parseNumstat(nulFields(counts))
        var files: [GitFileChange] = []
        var i = 0
        while i + 1 < fields.count {
            let code = String(fields[i].prefix(1))
            let renamed = code == "R" || code == "C"
            if renamed && i + 2 >= fields.count { break }
            let path = fields[i + (renamed ? 2 : 1)]
            let kind: String
            switch code {
            case "A": kind = "added"
            case "D": kind = "deleted"
            case "R": kind = "renamed"
            case "C": kind = "copied"
            default: kind = "modified"
            }
            files.append(GitFileChange(path: path, origPath: renamed ? fields[i + 1] : nil,
                                       kind: kind, index: code, worktree: ".", staged: stats[path]))
            i += renamed ? 3 : 2
        }
        return files
    }
}
