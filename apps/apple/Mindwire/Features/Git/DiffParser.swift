import Foundation

/// Unified-diff parsing shared by Source Control, agent file cards, and the file editor.
enum DiffParser {
    /// Load a file's diff lines: git's patch for tracked files, or the whole working content for
    /// untracked (all additions) / conflicted (plain context, since `diff --cc` isn't unified).
    /// `unified` widens patch context — pass a huge value to render the WHOLE file (full-file diff).
    static func lines(model: GitModel, change: GitFileChange, staged: Bool, unified: Int? = nil, commit: GitCommit? = nil,
                      comparison: GitPullRequestComparison? = nil) async throws
        -> (lines: [DiffLine], binary: Bool, additions: Int, deletions: Int, truncated: Bool) {
        if let comparison {
            let diff = try await model.comparisonDiff(comparison, change: change, unified: unified)
            return (diff.binary ? [] : parsePatch(diff.patch), diff.binary, diff.additions, diff.deletions, diff.truncated == true)
        } else if let commit {
            let diff = try await model.commitDiff(commit, change: change, unified: unified)
            return (diff.binary ? [] : parsePatch(diff.patch), diff.binary, diff.additions, diff.deletions, diff.truncated == true)
        } else if change.isConflicted {
            let blob = try await model.blob(path: change.path, rev: .worktree)
            if blob.binary { return ([], true, 0, 0, false) }
            return (contentLines(blob.content, kind: .context), false, 0, 0, blob.truncated)
        } else if change.isUntracked {
            let blob = try await model.blob(path: change.path, rev: .worktree)
            if blob.binary { return ([], true, 0, 0, false) }
            let l = contentLines(blob.content, kind: .addition)
            return (l, false, l.count, 0, blob.truncated)
        } else {
            let diff = try await model.diff(path: change.path, staged: staged, unified: unified)
            if diff.binary { return ([], true, 0, 0, false) }
            return (parsePatch(diff.patch), false, diff.additions, diff.deletions, diff.truncated == true)
        }
    }

    /// Hunk headers retain real source locations in compact review. Full-file review hides them.
    /// Change ranges use UTF-16, matching the native editor even when code contains emoji.
    static func inlineDiff(_ lines: [DiffLine], showsHunkHeaders: Bool = true)
        -> (text: String, tints: [Int: DiffTint], changes: [NSRange]) {
        var out: [String] = []
        var tints: [Int: DiffTint] = [:]
        var seenHunk = false
        for line in lines {
            if line.kind == .hunk {
                if showsHunkHeaders { out.append(line.text) }
                else if seenHunk { out.append("⋯") }
                seenHunk = true
                continue
            }
            out.append(line.text)
            let n = out.count                           // 1-based buffer line
            if line.kind == .addition { tints[n] = .added }
            else if line.kind == .deletion { tints[n] = .removed }
        }
        let text = out.joined(separator: "\n")
        var changes: [NSRange] = []
        var start: Int?
        var offset = 0
        for (index, line) in out.enumerated() {
            if tints[index + 1] != nil {
                if start == nil { start = offset }
            } else if let first = start {
                changes.append(NSRange(location: first, length: offset - first))
                start = nil
            }
            offset += (line as NSString).length + (index < out.count - 1 ? 1 : 0)
        }
        if let start { changes.append(NSRange(location: start, length: offset - start)) }
        return (text, tints, changes)
    }

    /// Native selection uses UTF-16 offsets. Preserve which selected lines were added or removed
    /// when the colored diff becomes a plain-text chat draft.
    static func selectedPatch(in text: String, tints: [Int: DiffTint], range: NSRange) -> String? {
        let source = text as NSString
        guard range.location != NSNotFound, range.length > 0, range.location <= source.length,
              range.length <= source.length - range.location else { return nil }
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        var result = ""
        for (index, line) in lines.enumerated() {
            let length = (line as NSString).length + (index < lines.count - 1 ? 1 : 0)
            let intersection = NSIntersectionRange(range, NSRange(location: offset, length: length))
            if intersection.length > 0 {
                let prefix: String
                switch tints[index + 1] {
                case .added: prefix = "+"
                case .removed: prefix = "-"
                case nil: prefix = line.hasPrefix("@@") ? "" : " "
                }
                result += prefix + source.substring(with: intersection)
            }
            offset += length
            if offset >= NSMaxRange(range) { break }
        }
        return result.isEmpty ? nil : result
    }

    /// Split raw file content into renderable lines, normalizing a single trailing newline (so an
    /// `a\nb\nc\n` file is 3 lines, not 4 with a phantom blank) and treating empty content as no
    /// lines. `.addition` numbers only the new side; any other kind is shown as context.
    static func contentLines(_ content: String, kind: DiffLine.Kind) -> [DiffLine] {
        if content.isEmpty { return [] }
        let trimmed = content.hasSuffix("\n") ? String(content.dropLast()) : content
        let body = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return body.enumerated().map { i, text in
            kind == .addition
                ? DiffLine(id: i, kind: .addition, oldNumber: nil, newNumber: i + 1, text: text)
                : DiffLine(id: i, kind: .context, oldNumber: i + 1, newNumber: i + 1, text: text)
        }
    }

    /// Compact hunk for an in-memory edit (no git patch): Edit/MultiEdit old→new, Write is old == "".
    /// Trims shared leading/trailing lines and emits the differing middle as deletions then additions
    /// — matches the compact look of Claude's edit cards without a full Myers LCS.
    static func editDiff(old: String, new: String) -> [DiffLine] {
        if old.isEmpty { return contentLines(new, kind: .addition) }
        let o = old.components(separatedBy: "\n")
        let n = new.components(separatedBy: "\n")
        var lead = 0
        while lead < o.count, lead < n.count, o[lead] == n[lead] { lead += 1 }
        var tail = 0
        while tail < (o.count - lead), tail < (n.count - lead),
              o[o.count - 1 - tail] == n[n.count - 1 - tail] { tail += 1 }
        var out: [DiffLine] = []; var id = 0
        for i in 0..<lead { out.append(DiffLine(id: id, kind: .context, oldNumber: i + 1, newNumber: i + 1, text: o[i])); id += 1 }
        for i in lead..<(o.count - tail) { out.append(DiffLine(id: id, kind: .deletion, oldNumber: i + 1, newNumber: nil, text: o[i])); id += 1 }
        for i in lead..<(n.count - tail) { out.append(DiffLine(id: id, kind: .addition, oldNumber: nil, newNumber: i + 1, text: n[i])); id += 1 }
        for i in 0..<tail {
            let oi = o.count - tail + i
            out.append(DiffLine(id: id, kind: .context, oldNumber: oi + 1, newNumber: n.count - tail + i + 1, text: o[oi])); id += 1
        }
        return out
    }

    /// Parse a unified-diff patch into renderable lines, tracking old/new line numbers per hunk.
    ///
    /// Uses an `inHunk` state machine: file/extended headers (`diff --git`, `index`, `---`, `+++`,
    /// mode lines) only appear OUTSIDE a hunk, so they're skipped there. INSIDE a hunk every line is
    /// classified by its first byte ONLY (` ` / `+` / `-` / `\`) — never by substring — so a content
    /// line like `-- sql comment` (which renders as `--- sql comment`) is not mistaken for a header.
    static func parsePatch(_ patch: String) -> [DiffLine] {
        guard !patch.isEmpty else { return [] }
        var result: [DiffLine] = []
        var oldNo = 0, newNo = 0, id = 0
        var inHunk = false
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(line) { oldNo = o; newNo = n }
                result.append(DiffLine(id: id, kind: .hunk, oldNumber: nil, newNumber: nil, text: line))
                id += 1
                inHunk = true
                continue
            }
            if !inHunk { continue }                       // file/extended header region — no content
            if let first = line.first {
                switch first {
                case "+":
                    result.append(DiffLine(id: id, kind: .addition, oldNumber: nil, newNumber: newNo, text: String(line.dropFirst())))
                    newNo += 1; id += 1
                case "-":
                    result.append(DiffLine(id: id, kind: .deletion, oldNumber: oldNo, newNumber: nil, text: String(line.dropFirst())))
                    oldNo += 1; id += 1
                case " ":
                    result.append(DiffLine(id: id, kind: .context, oldNumber: oldNo, newNumber: newNo, text: String(line.dropFirst())))
                    oldNo += 1; newNo += 1; id += 1
                case "\\":
                    continue                              // "\ No newline at end of file"
                default:
                    inHunk = false                        // a bare line ⇒ the next file's header block
                }
            } else {
                inHunk = false                            // blank line outside hunk content (patch tail)
            }
        }
        return result
    }

    /// `@@ -a,b +c,d @@ …` → (a, c). Defaults the start to the count-less `@@ -a +c @@` form.
    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func start(_ s: Substring) -> Int {
            let body = s.dropFirst()                            // drop +/-
            return Int(body.split(separator: ",").first ?? body) ?? 0
        }
        return (start(parts[1]), start(parts[2]))
    }
}

/// One rendered diff line.
struct DiffLine: Identifiable, Hashable {
    enum Kind { case addition, deletion, context, hunk }
    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}
