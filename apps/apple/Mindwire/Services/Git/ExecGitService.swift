import Foundation

/// Working-tree reads and compatibility mutations over workspace exec, shared by
/// cloud and SSH workspaces. GitModel uses durable daemon operations for writes
/// to registered projects when the daemon advertises that capability.
///
/// Anything that can carry NUL or binary bytes (`status --porcelain=v2 -z`, file blobs) is
/// base64'd on the workspace and split at the byte level here, so the porcelain NUL terminators and
/// binary content survive the exec transport intact (a raw NUL in stdout would otherwise truncate
/// the captured string). `root` is a project workdir (the repo top-level); `.` falls back to the
/// workspace's default cwd.
final class ExecGitService: GitService {
    private let workspace: WorkspaceService
    private let root: String

    init(workspace: WorkspaceService, root: String? = nil) {
        self.workspace = workspace
        self.root = (root?.isEmpty == false) ? root! : "."
    }

    // MARK: - Status

    func status() async throws -> GitStatus {
        // One round-trip: repo check, then porcelain v2 (+branch headers) and both numstats,
        // separated by 0x1F and base64'd as a single blob. Empty stdout ⇒ not a git repo.
        let script = """
        set -o pipefail
        export GIT_OPTIONAL_LOCKS=0
        if git -C \(q(root)) rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        {
          git -C \(q(root)) status --porcelain=v2 --branch -z --untracked-files=all || exit $?
          printf '\\037'
          git -C \(q(root)) diff --numstat -z || exit $?
          printf '\\037'
          git -C \(q(root)) diff --numstat --cached -z || exit $?
        } | base64
        fi
        """
        let result = try await workspace.exec(shell.command(script))
        let data = try readPayload(result)
        if data.isEmpty { return .notRepo }
        guard data.split(separator: 0x1F, maxSplits: 2, omittingEmptySubsequences: false).count == 3 else {
            throw BackendError.message(t("git.readIncomplete"))
        }
        return Self.parseStatus(data, root: root == "." ? nil : root)
    }

    // Git ref names cannot contain tabs/newlines. Symbolic remote HEAD aliases are omitted.
    func branches() async throws -> [GitBranch] {
        let result = try await workspace.exec(shell.command(
            "git -C \(q(root)) for-each-ref --format='%(refname)%09%(HEAD)%09%(upstream:short)%09%(symref)%09%(objectname)' refs/heads refs/remotes"))
        try check(result)
        return Self.parseBranches(result.stdout)
    }

    /// Local refs only: opening Source Control never contacts GitHub or fetches.
    /// The push URL is authoritative because the existing Push action uses origin.
    func pullRequestContext() async throws -> GitPullRequestContext? {
        let script = """
        set -o pipefail
        export GIT_OPTIONAL_LOCKS=0
        git_pr_branch=$(git -C \(q(root)) symbolic-ref --quiet --short HEAD 2>/dev/null) || exit 0
        git_pr_head=$(git -C \(q(root)) rev-parse --verify --quiet HEAD) || exit 0
        git_pr_fetch=$(git -C \(q(root)) remote get-url origin 2>/dev/null) || exit 0
        git_pr_push=$(git -C \(q(root)) remote get-url --push --all origin 2>/dev/null) || exit 0
        git_pr_default=$(git -C \(q(root)) symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || git_pr_default=''
        git_pr_remote=$(git -C \(q(root)) rev-parse --verify --quiet "refs/remotes/origin/$git_pr_branch" 2>/dev/null) || git_pr_remote=''
        git_pr_count=''
        if [ -n "$git_pr_default" ]; then
          git_pr_count=$(git -C \(q(root)) rev-list --count "$git_pr_default..$git_pr_head" 2>/dev/null) || git_pr_count=''
        fi
        git_pr_unpushed=''
        if [ "$git_pr_remote" = "$git_pr_head" ]; then
          git_pr_unpushed=0
        elif [ -n "$git_pr_remote" ]; then
          git_pr_unpushed=$(git -C \(q(root)) rev-list --count "$git_pr_remote..$git_pr_head" 2>/dev/null) || git_pr_unpushed=''
        fi
        git_pr_title=$(git -C \(q(root)) log -1 --format=%s "$git_pr_head") || exit $?
        printf '%s\\0' "$git_pr_branch" "$git_pr_head" "$git_pr_fetch" "$git_pr_push" "$git_pr_default" "$git_pr_remote" "$git_pr_count" "$git_pr_title" "$git_pr_unpushed" | base64
        """
        let result = try await workspace.exec(shell.command(script))
        return try Self.parsePullRequestContext(readPayload(result))
    }

    static func parsePullRequestContext(_ data: Data) throws -> GitPullRequestContext? {
        if data.isEmpty { return nil }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard fields.count == 10, fields.last == "", !fields[0].isEmpty, !fields[1].isEmpty else {
            throw BackendError.message(t("git.readIncomplete"))
        }
        // Unsupported hosts, multiple push URLs, and credential-bearing remotes
        // never become browser links or persisted project metadata.
        guard let repository = GitHubRepo.fromGitInput(fields[3]),
              GitHubRepo.fromGitInput(fields[2])?.fullName.caseInsensitiveCompare(repository.fullName) == .orderedSame else { return nil }
        let prefix = "refs/remotes/origin/"
        let base = fields[4].hasPrefix(prefix) ? String(fields[4].dropFirst(prefix.count)) : nil
        return GitPullRequestContext(repository: repository, branch: fields[0], head: fields[1],
            baseBranch: base?.isEmpty == false ? base : nil,
            remoteHead: fields[5].isEmpty ? nil : fields[5],
            commitCount: Int(fields[6]), title: fields[7], unpushedCount: Int(fields[8]))
    }

    static func parseBranches(_ output: String) -> [GitBranch] {
        output.split(separator: "\n").compactMap { row -> GitBranch? in
            let fields = row.components(separatedBy: "\t")
            guard (4...5).contains(fields.count), fields[3].isEmpty else { return nil }
            let remote = fields[0].hasPrefix("refs/remotes/")
            let prefix = remote ? "refs/remotes/" : "refs/heads/"
            guard fields[0].hasPrefix(prefix) else { return nil }
            return GitBranch(name: String(fields[0].dropFirst(prefix.count)), isCurrent: fields[1] == "*",
                             isRemote: remote, upstream: fields[2].isEmpty ? nil : fields[2],
                             tip: fields.count == 5 ? fields[4] : nil)
        }.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            if $0.isRemote != $1.isRemote { return !$0.isRemote }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func switchBranch(_ name: String, remote: Bool) async throws {
        try await validateBranch(name)
        let target = remote ? "refs/remotes/" + name : name
        try await mutate("git -C \(q(root)) switch \(remote ? "--track" : "--no-guess") -- \(q(target))")
    }

    func createBranch(_ name: String) async throws {
        try await validateBranch(name)
        try await mutate("git -C \(q(root)) switch -c \(q(name))")
    }

    private func validateBranch(_ name: String) async throws {
        guard !name.isEmpty, name != "HEAD", !name.hasPrefix("-"), !name.contains("\0") else {
            throw BackendError.message(t("git.branches.invalidName"))
        }
        try await mutate("git -C \(q(root)) check-ref-format \(q("refs/heads/" + name))")
    }

    // MARK: - Blob (one side of a diff)

    func blob(path: String, rev: GitRev) async throws -> GitBlob {
        let cap = 2_000_000
        let cmd: String
        switch rev {
        case .head:
            cmd = "git -C \(q(root)) show \(q("HEAD:" + path)) 2>/dev/null | \(shell.base64Capture(capBytes: cap))"
        case .index:
            cmd = "git -C \(q(root)) show \(q(":" + path)) 2>/dev/null | \(shell.base64Capture(capBytes: cap))"
        case .worktree:
            cmd = "set -o pipefail\nhead -c \(cap) \(q(join(root, path))) | base64"
        }
        let result = try await workspace.exec(shell.command(cmd))
        let data = try readPayload(result)
        let binary = Self.looksBinary(data)
        let content = binary ? "" : (String(data: data, encoding: .utf8) ?? "")
        return GitBlob(path: path, rev: rev.rawValue, binary: binary || (content.isEmpty && !data.isEmpty),
                       size: data.count, truncated: data.count >= cap, content: content)
    }

    // MARK: - Diff (unified patch + line counts)

    func diff(path: String, staged: Bool, unified: Int? = nil) async throws -> GitDiff {
        let cached = staged ? "--cached " : ""
        // `-U<n>` widens the patch context — a huge value yields the WHOLE file (full-file diff view).
        let ctx = unified.map { "-U\($0) " } ?? ""
        // numstat (counts / binary flag) + the patch, 0x1F-separated and base64'd in one round-trip.
        let script = """
        set -o pipefail
        export GIT_OPTIONAL_LOCKS=0
        {
          git --literal-pathspecs -C \(q(root)) diff \(cached)--numstat -z -- \(q(path)) || exit $?
          printf '\\037'
          git --literal-pathspecs -C \(q(root)) diff \(cached)\(ctx)--no-color --no-ext-diff -- \(q(path)) | { head -c 1000000; cat >/dev/null; } || exit $?
        } | base64
        """
        let result = try await workspace.exec(shell.command(script))
        let data = try readPayload(result)
        let sections = data.split(separator: 0x1F, maxSplits: 1, omittingEmptySubsequences: false)
        guard sections.count == 2 else { throw BackendError.message(t("git.readIncomplete")) }
        let numstatData = sections[0]
        let patchData = sections[1]
        let numstatTokens = numstatData.split(separator: 0x00, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var additions = 0, deletions = 0, binary = false
        if let first = numstatTokens.first {
            let parts = first.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 2 {
                if parts[0] == "-" || parts[1] == "-" { binary = true }
                else { additions = Int(parts[0]) ?? 0; deletions = Int(parts[1]) ?? 0 }
            }
        }
        let patch = binary ? "" : String(decoding: patchData, as: UTF8.self)
        return GitDiff(path: path, staged: staged, binary: binary,
                       additions: additions, deletions: deletions, patch: patch,
                       truncated: patchData.count >= 1_000_000)
    }

    /// Result of a HEAD-vs-worktree diff for one file, for the editor's line tints.
    enum HeadDiff { case none; case untracked; case patch(String) }

    /// The combined (staged + unstaged) diff of a file against `HEAD`, for editor change tints —
    /// unlike `diff(staged:)`, this catches staged edits AND, via a sentinel, untracked files (which
    /// `git diff` ignores entirely). `.none` = tracked & unchanged; `.untracked` = the caller should
    /// tint every line as added; `.patch` = a unified patch to parse. One exec round-trip.
    func headDiff(path: String) async throws -> HeadDiff {
        let script = """
        if git -C \(q(root)) ls-files --error-unmatch -- \(q(path)) >/dev/null 2>&1; then
        git -C \(q(root)) diff HEAD --no-color -- \(q(path)) | head -c 1000000 | base64
        elif [ -e \(q(join(root, path))) ]; then
        printf '@@UNTRACKED@@'
        fi
        """
        let out = try await workspace.exec(shell.command(script)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if out == "@@UNTRACKED@@" { return .untracked }
        guard !out.isEmpty,
              let data = Data(base64Encoded: out, options: .ignoreUnknownCharacters) else { return .none }
        let patch = String(decoding: data, as: UTF8.self)
        return patch.isEmpty ? .none : .patch(patch)
    }

    // MARK: - Mutations

    func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        // -A under each pathspec stages adds, modifications AND deletions (and untracked files).
        try await mutate("git --literal-pathspecs -C \(q(root)) add -A -- \(qList(paths))")
    }

    func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await mutate("""
        if git -C \(q(root)) rev-parse --verify --quiet HEAD >/dev/null; then
          git --literal-pathspecs -C \(q(root)) reset -q HEAD -- \(qList(paths))
        else
          git_head_status=$?
          if [ "$git_head_status" -ne 1 ]; then exit "$git_head_status"; fi
          git --literal-pathspecs -C \(q(root)) rm --cached -r -f --ignore-unmatch -- \(qList(paths))
        fi
        """)
    }

    func discard(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        // Classify first. A failed checkout must never become a request to delete
        // a tracked file. Git clean rechecks tracking and respects ignored files.
        let steps = paths.map { p -> String in
            """
            if git --literal-pathspecs -C \(q(root)) ls-files --error-unmatch -- \(q(p)) >/dev/null 2>&1; then
              git --literal-pathspecs -C \(q(root)) checkout -- \(q(p)) || exit $?
            else
              git_check_status=$?
              if [ "$git_check_status" -ne 1 ]; then exit "$git_check_status"; fi
              git --literal-pathspecs -C \(q(root)) clean -f -- \(q(p)) || exit $?
            fi
            """
        }
        try await mutate(steps.joined(separator: "\n"))
    }

    func identity() async throws -> GitIdentity {
        let script = """
        set -o pipefail
        git -C \(q(root)) rev-parse --git-dir >/dev/null || exit $?
        for git_identity_key in user.name user.email; do
          git_identity_value=$(git -C \(q(root)) config --get "$git_identity_key")
          git_identity_status=$?
          if [ "$git_identity_status" -gt 1 ]; then exit "$git_identity_status"; fi
          printf '%s' "$git_identity_value" | base64 | tr -d '\\n'
          printf '\\n'
        done
        """
        let result = try await workspace.exec(shell.command(script))
        try check(result)
        let fields = result.stdout.components(separatedBy: "\n")
        let values = fields.prefix(2).map { Data(base64Encoded: $0).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        return GitIdentity(name: values.first ?? "", email: values.count > 1 ? values[1] : "")
    }

    func commit(message: String, identity: GitIdentity? = nil) async throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var setup = ""
        if let identity = identity?.normalized {
            guard identity.isValid else { throw GitIdentityError.required }
            setup = """
            git -C \(q(root)) config --local --replace-all user.name \(q(identity.name)) || exit $?
            git -C \(q(root)) config --local --replace-all user.email \(q(identity.email)) || exit $?
            export GIT_AUTHOR_NAME=\(q(identity.name)) GIT_COMMITTER_NAME=\(q(identity.name))
            export GIT_AUTHOR_EMAIL=\(q(identity.email)) GIT_COMMITTER_EMAIL=\(q(identity.email))
            """
        }
        do {
            try await mutate("""
            export LC_ALL=C
            \(setup)
            git -C \(q(root)) var GIT_AUTHOR_IDENT >/dev/null || exit $?
            git -C \(q(root)) var GIT_COMMITTER_IDENT >/dev/null || exit $?
            git -C \(q(root)) commit -m \(q(trimmed))
            """)
        } catch {
            if GitIdentityError.matches(error.localizedDescription) { throw GitIdentityError.required }
            throw error
        }
    }

    /// Bound output without losing the command's failure to a successful base64 pipeline.
    /// Drain excess bytes so a deliberate cap doesn't turn into a misleading SIGPIPE error.
    func readGit(_ arguments: [String], cap: Int = 2_000_000) async throws -> Data {
        let script = """
        set -o pipefail
        export GIT_OPTIONAL_LOCKS=0
        git --literal-pathspecs -C \(q(root)) \(qList(arguments)) | { head -c \(cap); cat >/dev/null; } | base64
        """
        let result = try await workspace.exec(shell.command(script))
        return try readPayload(result)
    }

    func historyTip() async throws -> String? {
        let script = """
        git -C \(q(root)) rev-parse --git-dir >/dev/null || exit $?
        if git -C \(q(root)) rev-parse --verify --quiet HEAD; then
          exit 0
        else
          git_history_status=$?
          if [ "$git_history_status" -eq 1 ]; then exit 0; fi
          exit "$git_history_status"
        fi
        """
        let result = try await workspace.exec(shell.command(script))
        try check(result)
        let tip = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return tip.isEmpty ? nil : tip
    }

    // MARK: - Exec helpers

    /// Failed or clipped transport output must never become an empty diff or a clean repository.
    private func readPayload(_ result: ExecResult) throws -> Data {
        try check(result)
        guard result.truncated != true else { throw BackendError.message(t("git.readIncomplete")) }
        let encoded = result.stdout.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: encoded) else {
            throw BackendError.message(t("git.readIncomplete"))
        }
        return data
    }

    /// Run a mutating git script; throw the stderr (or stdout) on a nonzero exit so the UI can show it.
    private func mutate(_ script: String) async throws {
        let r = try await workspace.exec(shell.command(script))
        try check(r)
    }

    private func check(_ r: ExecResult) throws {
        if let code = r.exitCode, code != 0 {
            let raw = !r.stderr.isEmpty ? r.stderr : (!r.stdout.isEmpty ? r.stdout : "git command failed")
            throw BackendError.message(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The workspace's platform shell — wrapper, quoting, and the base64/rm toolbox.
    private var shell: Shell { workspace.shell }
    /// Quote a value for the shell (delegates to the platform shell — one escaper for the whole app).
    private func q(_ s: String) -> String { shell.quote(s) }
    private func qList(_ paths: [String]) -> String { paths.map { q($0) }.joined(separator: " ") }

    /// Absolute working-tree path for a repo-relative `path` (porcelain paths are relative to root).
    private func join(_ root: String, _ path: String) -> String {
        if root == "." { return path }
        return root.hasSuffix("/") ? root + path : root + "/" + path
    }

    /// Heuristic: a NUL byte in the first 8 KiB means binary (matches git's own check).
    private static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0x00)
    }

    // MARK: - Porcelain v2 parsing

    /// Parse the base64-decoded `status --porcelain=v2 --branch -z` + two `diff --numstat -z`
    /// sections (0x1F-separated) into a `GitStatus`. NUL-terminated, unescaped, byte-faithful.
    static func parseStatus(_ data: Data, root: String?) -> GitStatus {
        let sections = data.split(separator: 0x1F, maxSplits: 2, omittingEmptySubsequences: false)
        func tokens(_ idx: Int) -> [String] {
            guard idx < sections.count else { return [] }
            return sections[idx].split(separator: 0x00, omittingEmptySubsequences: true)
                .map { String(decoding: $0, as: UTF8.self) }
        }
        let statusToks = tokens(0)
        let unstagedNumstat = parseNumstat(tokens(1))
        let stagedNumstat = parseNumstat(tokens(2))

        var head: String?
        var branch: String?
        var upstream: String?
        var ahead = 0, behind = 0, detached = false
        var files: [GitFileChange] = []

        var i = 0
        while i < statusToks.count {
            let line = statusToks[i]
            if line.hasPrefix("# ") {
                let body = String(line.dropFirst(2))
                if body.hasPrefix("branch.oid ") {
                    let value = String(body.dropFirst("branch.oid ".count))
                    if value != "(initial)" { head = value }
                } else if body.hasPrefix("branch.head ") {
                    let v = String(body.dropFirst("branch.head ".count))
                    if v == "(detached)" { detached = true } else { branch = v }
                } else if body.hasPrefix("branch.upstream ") {
                    upstream = String(body.dropFirst("branch.upstream ".count))
                } else if body.hasPrefix("branch.ab ") {
                    let ab = body.dropFirst("branch.ab ".count).split(separator: " ")
                    for part in ab {
                        if part.hasPrefix("+") { ahead = Int(part.dropFirst()) ?? 0 }
                        else if part.hasPrefix("-") { behind = Int(part.dropFirst()) ?? 0 }
                    }
                }
                i += 1
            } else if line.hasPrefix("1 ") {
                if let change = parseOrdinary(line, staged: stagedNumstat, unstaged: unstagedNumstat) {
                    files.append(change)
                }
                i += 1
            } else if line.hasPrefix("2 ") {
                let orig = (i + 1 < statusToks.count) ? statusToks[i + 1] : nil
                if let change = parseRename(line, origPath: orig, staged: stagedNumstat, unstaged: unstagedNumstat) {
                    files.append(change)
                }
                i += 2   // a type-2 entry consumes the following NUL-terminated original path
            } else if line.hasPrefix("u ") {
                if let change = parseUnmerged(line) { files.append(change) }
                i += 1
            } else if line.hasPrefix("? ") {
                let path = String(line.dropFirst(2))
                files.append(GitFileChange(path: path, origPath: nil, kind: "untracked",
                                           index: ".", worktree: "?", staged: nil, unstaged: nil))
                i += 1
            } else {
                i += 1   // "! " ignored entries and anything unexpected
            }
        }

        return GitStatus(isRepo: true, root: root, branch: branch, upstream: upstream,
                         ahead: ahead, behind: behind, detached: detached, files: files, head: head)
    }

    /// numstat `-z` → [path: counts]. Normal record `adds\tdels\tpath`; a rename record is
    /// `adds\tdels\t` (empty path) followed by two NUL fields (from, to) — keyed by the new path.
    static func parseNumstat(_ toks: [String]) -> [String: GitLineStat] {
        var map: [String: GitLineStat] = [:]
        var i = 0
        while i < toks.count {
            let parts = toks[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 3 else { i += 1; continue }
            let adds = Int(parts[0]) ?? 0
            let dels = Int(parts[1]) ?? 0
            let path = String(parts[2])
            if path.isEmpty {
                if i + 2 < toks.count { map[toks[i + 2]] = GitLineStat(additions: adds, deletions: dels) }
                i += 3
            } else {
                map[path] = GitLineStat(additions: adds, deletions: dels)
                i += 1
            }
        }
        return map
    }

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    private static func parseOrdinary(_ line: String,
                                      staged: [String: GitLineStat],
                                      unstaged: [String: GitLineStat]) -> GitFileChange? {
        let f = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard f.count >= 9 else { return nil }
        let xy = f[1]
        let x = String(xy.prefix(1)), y = String(xy.suffix(1))
        let path = String(f[8])
        return GitFileChange(path: path, origPath: nil, kind: kind(x, y),
                             index: x, worktree: y, staged: staged[path], unstaged: unstaged[path])
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>` (+ following NUL `<origPath>`)
    private static func parseRename(_ line: String, origPath: String?,
                                    staged: [String: GitLineStat],
                                    unstaged: [String: GitLineStat]) -> GitFileChange? {
        let f = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard f.count >= 10 else { return nil }
        let xy = f[1]
        let x = String(xy.prefix(1)), y = String(xy.suffix(1))
        let path = String(f[9])
        return GitFileChange(path: path, origPath: origPath, kind: kind(x, y),
                             index: x, worktree: y, staged: staged[path], unstaged: unstaged[path])
    }

    /// `u <XY> …` — unmerged. Forced to U/U so the row reads as a conflict and routes cleanly,
    /// regardless of the specific combo (UU/AA/DD/…).
    private static func parseUnmerged(_ line: String) -> GitFileChange? {
        let f = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard f.count >= 11 else { return nil }
        let path = String(f[10])
        return GitFileChange(path: path, origPath: nil, kind: "conflicted",
                             index: "U", worktree: "U", staged: nil, unstaged: nil)
    }

    /// Coarse change kind for the row icon, from the porcelain X/Y codes.
    private static func kind(_ x: String, _ y: String) -> String {
        if y == "?" { return "untracked" }
        let c = x != "." ? x : y
        switch c {
        case "A": return "added"
        case "D": return "deleted"
        case "R": return "renamed"
        case "C": return "copied"
        case "U": return "conflicted"
        default:  return "modified"
        }
    }
}
