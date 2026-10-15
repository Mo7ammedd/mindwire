// Real Git integration checks for the production Swift exec adapter. Runs on macOS,
// with a temporary repository and an isolated Git config; no simulator or login needed.
import Foundation

func t(_ key: String) -> String { key }
enum BackendError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
struct ExecResult { let stdout: String; let stderr: String; let exitCode: Int?; var truncated: Bool? = nil }
protocol WorkspaceService: AnyObject {
    var shell: Shell { get }
    func exec(_ cmd: [String]) async throws -> ExecResult
}
final class LocalGitWorkspace: WorkspaceService, @unchecked Sendable {
    let shell: Shell = PosixShell()
    let globalConfig: String
    init(globalConfig: String) { self.globalConfig = globalConfig }
    func exec(_ cmd: [String]) async throws -> ExecResult {
        let capture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: capture) }
        let out = capture.appendingPathComponent("out"), err = capture.appendingPathComponent("err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let output = try FileHandle(forWritingTo: out), errors = try FileHandle(forWritingTo: err)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = cmd
        var env = ProcessInfo.processInfo.environment
        for key in ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"] { env.removeValue(forKey: key) }
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = globalConfig
        process.environment = env
        process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        return ExecResult(stdout: String(decoding: try Data(contentsOf: out), as: UTF8.self),
                          stderr: String(decoding: try Data(contentsOf: err), as: UTF8.self), exitCode: Int(process.terminationStatus))
    }
}
@main struct CheckGitHistory {
    static func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw BackendError.message(reason) }
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mindwire-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("work space'$(literal)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let global = directory.appendingPathComponent("global.config")
        let workspace = LocalGitWorkspace(globalConfig: global.path)
        func git(_ args: [String]) async throws -> String {
            let result = try await workspace.exec(["git", "-C", root.path] + args)
            try require(result.exitCode == 0, "Git fixture failed: \(result.stderr)")
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ name: String, _ data: Data) throws { try data.write(to: root.appendingPathComponent(name)) }
        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["config", "user.useConfigOnly", "true"])
        let service = ExecGitService(workspace: workspace, root: root.path)
        let empty = try await service.history(cursor: nil, limit: 2)
        try require(empty.commits.isEmpty && empty.next == nil, "Unborn history should be empty")
        try write("original[1].swift", Data("one\ntwo\nthree\nfour\n".utf8))
        try write("original1.swift", Data("neighbor\n".utf8))
        try await service.stage(["original[1].swift"])
        try await service.unstage(["original[1].swift"])
        try require(try await git(["ls-files"]).isEmpty, "Unborn unstage did not clear the index")
        try require(FileManager.default.fileExists(atPath: root.appendingPathComponent("original[1].swift").path), "Unstage removed working file")
        try await service.stage(["original[1].swift", "original1.swift"])
        do { try await service.commit(message: "Initial 👋"); throw BackendError.message("Missing author was accepted") }
        catch is GitIdentityError { }
        let author = GitIdentity(name: "Tester's Name", email: "test@example.invalid")
        try await service.commit(message: "Initial 👋", identity: author)
        try require(try await service.identity() == author, "Repository author did not round-trip")
        try require(!FileManager.default.fileExists(atPath: global.path), "Author setup wrote global configuration")
        let firstPage = try await service.history(cursor: nil, limit: 2)
        try require(firstPage.commits.count == 1 && firstPage.commits[0].parents.isEmpty, "Root history parsing failed")
        let first = firstPage.commits[0]
        let rootDetails = try await service.commitDetails(first)
        try require(rootDetails.files.count == 2, "Root commit files missing")
        let literal = rootDetails.files.first { $0.path == "original[1].swift" }!
        let literalDiff = try await service.commitDiff(first, change: literal, unified: nil)
        try require(literalDiff.additions == 4 && !literalDiff.patch.contains("neighbor"), "Literal root diff included the neighboring path")
        _ = try await git(["mv", "--", "original[1].swift", "renamed\nfile.swift"])
        try write("renamed\nfile.swift", Data("one\ntwo\nchanged\nfour\n".utf8))
        try write("image.bin", Data([0, 1, 2, 3, 0, 4]))
        _ = try await git(["rm", "--", "original1.swift"])
        try await service.stage(["renamed\nfile.swift", "image.bin"])
        try await service.commit(message: "Rename, delete, and binary\n\nLonger details")
        let renamed = try await service.history(cursor: nil, limit: 2).commits[0]
        let detail = try await service.commitDetails(renamed)
        try require(detail.message.contains("Longer details"), "Commit body missing")
        let change = detail.files.first { $0.path == "renamed\nfile.swift" }!
        try require(change.origPath == "original[1].swift", "Rename source was lost")
        let renamePatch = try await service.commitDiff(renamed, change: change, unified: 1_000_000)
        try require(renamePatch.additions == 1 && renamePatch.deletions == 1 && renamePatch.patch.contains("+changed"), "Rename diff invalid")
        let imageChange = detail.files.first { $0.path == "image.bin" }!
        try require(try await service.commitDiff(renamed, change: imageChange, unified: nil).binary, "Binary diff treated as text")
        _ = try await git(["switch", "-c", "side"])
        try write("side.txt", Data("side\n".utf8))
        try await service.stage(["side.txt"]); try await service.commit(message: "Side work")
        _ = try await git(["switch", "main"])
        try write("main.txt", Data("main\n".utf8))
        try await service.stage(["main.txt"]); try await service.commit(message: "Main work")
        _ = try await git(["merge", "--no-ff", "side", "-m", "Merge side"])
        let page = try await service.history(cursor: nil, limit: 2)
        try require(page.commits.count == 2 && page.next != nil && page.commits[0].parents.count == 2, "Merge/pagination metadata failed")
        let merge = try await service.commitDetails(page.commits[0])
        try require(merge.files.map(\.path) == ["side.txt"], "Merge comparison wasn't against first parent")
        _ = try await git(["commit", "--allow-empty", "-m", "New tip while reading"])
        let next = try await service.history(cursor: page.next, limit: 2)
        try require(Set(page.commits.map(\.id)).isDisjoint(with: Set(next.commits.map(\.id))), "Pagination repeated commits after HEAD advanced")
        try require(!next.commits.contains { $0.subject == "New tip while reading" }, "Snapshot pagination switched HEAD")
        let refreshed = try await service.history(cursor: nil, limit: 2)
        try require(refreshed.commits[0].subject == "New tip while reading", "Refresh didn't see new HEAD")
        let noChanges = try await service.commitDetails(refreshed.commits[0])
        try require(noChanges.files.isEmpty, "Empty commit invented changes")
        // PR preparation only reads local refs. No GitHub request or network push.
        _ = try await git(["remote", "add", "origin", "https://github.com/team/app.git"])
        _ = try await git(["update-ref", "refs/remotes/origin/main", first.id])
        _ = try await git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        let reviewBranch = "feature/#12+fish&chips'"
        _ = try await git(["switch", "-c", reviewBranch])
        let reviewHead = try await git(["rev-parse", "HEAD"])
        guard let review = try await service.pullRequestContext() else { throw BackendError.message("Missing PR context") }
        try require(review.branch == reviewBranch && review.baseBranch == "main", "PR branch selection lost its exact refs")
        try require(review.isFeatureBranch && review.needsPush && (review.commitCount ?? 0) > 0, "New branch must offer publishing")
        try require(review.title == "New tip while reading", "PR title did not use the committed subject")
        try require(try await git(["rev-parse", "HEAD"]) == reviewHead, "PR preparation changed HEAD")
        try require(try await git(["status", "--porcelain"]).isEmpty, "PR preparation changed the worktree")
        _ = try await git(["update-ref", "refs/remotes/origin/" + reviewBranch, reviewHead])
        try require(try await service.pullRequestContext()?.needsPush == false, "Published branch was mistaken for an unpublished one")
        _ = try await git(["update-ref", "refs/remotes/origin/develop", first.id])
        _ = try await git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop"])
        try require(try await service.pullRequestContext()?.baseBranch == "develop", "Non-main default branch was ignored")
        _ = try await git(["config", "remote.origin.pushurl", "https://github.com/other/fork.git"])
        try require(try await service.pullRequestContext() == nil, "An unrelated push URL reused origin's tracking refs")
        _ = try await git(["config", "--unset", "remote.origin.pushurl"])
        _ = try await git(["switch", "--detach", "HEAD"])
        try require(try await service.pullRequestContext() == nil, "Detached HEAD must not offer a pull request")
        print("PASS: real Git history, author setup, literal paths, stable pagination, and read-only pull-request preparation")
    }
}
