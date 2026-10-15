import XCTest
@testable import Mindwire

@MainActor
final class GitPullRequestTests: XCTestCase {
    private let head = String(repeating: "a", count: 40)

    func testDefaultBranchIsReadFromOriginRatherThanAssumingMain() throws {
        let context = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload(branch: "main", base: "develop")))
        XCTAssertTrue(context.isFeatureBranch)
        XCTAssertEqual(context.baseBranch, "develop")
        XCTAssertEqual(context.repository.fullName, "team/app")
        XCTAssertTrue(context.needsPush)
        XCTAssertEqual(context.commitCount, 2)
        let base = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload(branch: "develop", base: "develop")))
        XCTAssertFalse(base.isFeatureBranch)
        let empty = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload(count: "0")))
        XCTAssertTrue(empty.isFeatureBranch, "A new feature branch can open the form to review and commit staged files")
    }

    func testUnpublishedAndPublishedBranchesUseTheirOwnRemoteTip() throws {
        let unpublished = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload()))
        XCTAssertTrue(unpublished.needsPush)
        let published = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload(remoteHead: head)))
        XCTAssertFalse(published.needsPush)
        let diverged = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload(remoteHead: String(repeating: "b", count: 40), unpushed: "3")))
        XCTAssertTrue(diverged.needsPush)
        XCTAssertEqual(diverged.unpushedCount, 3)
        let behind = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload(remoteHead: String(repeating: "b", count: 40), unpushed: "0")))
        XCTAssertEqual(behind.unpushedCount, 0, "A different remote tip does not imply local commits to push")
        XCTAssertTrue(published.matches(GitStatus(isRepo: true, branch: "feature/review", ahead: 0, behind: 0,
                                                detached: false, files: [], head: head)))
        XCTAssertFalse(published.matches(GitStatus(isRepo: true, branch: "another", ahead: 0, behind: 0,
                                                 detached: false, files: [], head: head)))
    }

    func testNativeCreatePreservesLiteralTextAndBranchNames() async throws {
        let context = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload(branch: "feature/#12+fish&chips'🦊")))
        let draft = GitPullRequestDraft(title: "Fix + polish & draft=true #12 👋",
            body: "First line\n\n`literal code` and $(touch should-not-run)\n'quoted' \\n", base: "release/next", draft: true)
        let fixture = PullRequestFixture(context: context)
        let result = try await fixture.client.create(context, draft: draft)
        XCTAssertEqual(result.title, draft.title)
        XCTAssertEqual(result.head.ref, context.branch)
        XCTAssertEqual(result.base.ref, draft.base)
        XCTAssertTrue(result.draft)
        let post = try XCTUnwrap(fixture.calls.first { $0.method == "POST" })
        XCTAssertEqual(post.path, "/repos/team/app/pulls")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.body)) as? [String: Any])
        XCTAssertEqual(body["title"] as? String, draft.title)
        XCTAssertEqual(body["body"] as? String, draft.body)
        XCTAssertEqual(body["head"] as? String, context.branch)
        XCTAssertEqual(body["base"] as? String, draft.base)
        XCTAssertEqual(body["draft"] as? Bool, true)
        let branchPath = try XCTUnwrap(fixture.calls.first?.path)
        XCTAssertTrue(branchPath.contains("feature%2F%2312%2Bfish%26chips%27"), branchPath)
        let lookup = try XCTUnwrap(fixture.calls.first { $0.path.contains("state=open") })
        let query = try XCTUnwrap(URLComponents(string: "https://api.github.com" + lookup.path)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "head" }?.value, "team:" + context.branch)
        XCTAssertEqual(query.first { $0.name == "base" }?.value, draft.base)
    }

    func testPreparationReadsGitHubDefaultAndAllBaseBranches() async throws {
        let context = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload(base: "", count: "")))
        let fixture = PullRequestFixture(context: context)
        fixture.branches = (0..<101).map { "release/\($0)" }
        fixture.defaultBranch = "develop"
        let prepared = try await fixture.client.prepare(context)
        XCTAssertEqual(prepared.defaultBranch, "develop")
        XCTAssertEqual(prepared.branches.count, 102)
        XCTAssertTrue(prepared.branches.contains("release/100"))
        XCTAssertEqual(prepared.branchHeads["develop"], fixture.baseHead)
        XCTAssertTrue(fixture.calls.contains { $0.path.hasSuffix("page=2") })
        XCTAssertFalse(fixture.calls.contains { $0.method == "POST" })
    }

    func testRetryRecoversAcceptedPullRequestWithoutAnotherPost() async throws {
        let context = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload()))
        for failure in [URLError(.networkConnectionLost) as any Error,
                        GitHubAPIError(status: 422, message: "A pull request already exists", requiresSSO: false)] {
            let fixture = PullRequestFixture(context: context)
            fixture.acceptThenFail = failure
            let draft = GitPullRequestDraft(title: "Only once", body: "Keep this description", base: "main")
            let first = try await fixture.client.create(context, draft: draft)
            let retried = try await fixture.client.create(context, draft: .init(title: "Different draft", base: "main"))
            XCTAssertEqual(retried, first, "Retry must preserve the existing PR, including its title and description")
            XCTAssertEqual(fixture.calls.filter { $0.method == "POST" }.count, 1)
            XCTAssertEqual(retried.title, "Only once")
            let prepared = try await fixture.client.prepare(context)
            XCTAssertEqual(prepared.existing, first, "Reopening should show the existing PR inside Mindwire")
        }
    }

    func testChangedRemoteHeadAndInvalidDraftNeverCreatePullRequest() async throws {
        let context = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload()))
        let fixture = PullRequestFixture(context: context)
        fixture.remoteHead = String(repeating: "b", count: 40)
        do {
            _ = try await fixture.client.create(context, draft: .init(title: "Confirmed title", base: "main"))
            XCTFail("A changed remote head must be reviewed again")
        } catch { XCTAssertEqual(error.localizedDescription, t("git.pr.remoteChanged")) }
        for draft in [GitPullRequestDraft(title: " ", base: "main"),
                      .init(title: "Title", base: context.branch),
                      .init(title: "Title", body: String(repeating: "a", count: 65_537), base: "main")] {
            do { _ = try await fixture.client.create(context, draft: draft); XCTFail("Invalid draft was submitted") }
            catch { XCTAssertEqual(error.localizedDescription, t("git.pr.invalidDraft")) }
        }
        XCTAssertFalse(fixture.calls.contains { $0.method == "POST" })
    }

    func testChangedBaseRejectsTheReviewedComparisonBeforePosting() async throws {
        let context = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload()))
        let fixture = PullRequestFixture(context: context)
        let draft = GitPullRequestDraft(title: "Reviewed changes", base: "main",
                                        expectedBaseHead: String(repeating: "d", count: 40))
        do { _ = try await fixture.client.create(context, draft: draft); XCTFail("A new base needs a new preview") }
        catch { XCTAssertEqual(error.localizedDescription, t("git.pr.baseChanged")) }
        XCTAssertFalse(fixture.calls.contains { $0.method == "POST" })
    }

    func testWorkspaceGitHubCLIUsesItsExistingLoginAndPrivateLiteralInput() async throws {
        let recorder = PullRequestCommandRecorder()
        let workspace = SelfHostedWorkspaceService { await recorder.run($0) }
        let body = try JSONSerialization.data(withJSONObject: ["title": "What's new?",
            "body": "First line\n`literal` $(touch should-not-run)\n'quoted' \\n", "draft": true])
        let result = try await GhCliGitHubService.request("POST", "/repos/team/app/pulls", json: body, on: workspace)
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "{}")
        let commands = await recorder.commands
        let command = try XCTUnwrap(commands.first)
        let script = try XCTUnwrap(command.last)
        XCTAssertTrue(script.contains("--hostname"))
        XCTAssertTrue(script.contains("github.com"))
        XCTAssertTrue(script.contains("--input"))
        XCTAssertTrue(script.contains("umask 077"))
        XCTAssertTrue(script.contains("GH_PROMPT_DISABLED=1"))
        XCTAssertFalse(script.contains("auth token"), "Workspace credentials must stay on that workspace")
        XCTAssertFalse(script.contains("gh auth login"))
        try script.write(toFile: "/tmp/mindwire-github-pr-gh-request.sh", atomically: true, encoding: .utf8)
        try body.write(to: URL(fileURLWithPath: "/tmp/mindwire-github-pr-gh-body.json"))
    }

    func testPATSubmissionUsesAuthenticatedJSONAndSurfacesGitHubValidation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PullRequestHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); PullRequestHTTPFixture.respond = nil }
        let body = Data(#"{"title":"Native PR","body":"First\nSecond","draft":true}"#.utf8)
        PullRequestHTTPFixture.respond = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-pr-fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            return (201, Data(#"{"number":23}"#.utf8))
        }
        let response = try await GitHubREST.request("POST", "/repos/team/app/pulls", json: body,
            token: "private-pr-fixture", session: session)
        XCTAssertEqual(response.http.statusCode, 201)
        for detail in [#"[{"message":"No commits between main and feature"}]"#, #"["No commits between main and feature"]"#] {
            PullRequestHTTPFixture.respond = { _ in
                (422, Data("{\"message\":\"Validation Failed\",\"errors\":\(detail)}".utf8))
            }
            do {
                _ = try await GitHubREST.request("POST", "/repos/team/app/pulls", json: body,
                    token: "private-pr-fixture", session: session)
                XCTFail("Expected GitHub's actionable validation error")
            } catch { XCTAssertEqual(error.localizedDescription, "No commits between main and feature") }
        }
    }

    func testUnknownDefaultUsesGitHubsDefaultWithoutInventingABaseBranch() throws {
        let context = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload(base: "", count: "")))
        XCTAssertNil(context.baseBranch)
        XCTAssertNil(context.commitCount)
        XCTAssertTrue(context.isFeatureBranch)
        let conventionalDefault = try XCTUnwrap(ExecGitService.parsePullRequestContext(payload(branch: "main", base: "", count: "")))
        XCTAssertFalse(conventionalDefault.isFeatureBranch)
    }

    func testUnsupportedAndAmbiguousRemotesNeverBecomePullRequestLinks() throws {
        for remote in ["https://gitlab.com/team/app.git", "https://github.com.evil.invalid/team/app.git",
                       "https://secret@github.com/team/app.git", "https://github.com/team/app.git?token=secret",
                       "https://github.com/team/app.git\nhttps://github.com/other/app.git"] {
            XCTAssertNil(try ExecGitService.parsePullRequestContext(payload(push: remote)))
        }
        XCTAssertNil(try ExecGitService.parsePullRequestContext(payload(push: "https://github.com/another/fork.git")),
                     "Origin's tracking refs cannot verify a different push destination")
        XCTAssertNotNil(try ExecGitService.parsePullRequestContext(payload(push: "git@github.com:team/app.git")))
        XCTAssertNil(try ExecGitService.parsePullRequestContext(Data()))
        XCTAssertThrowsError(try ExecGitService.parsePullRequestContext(Data("partial\0payload".utf8)))
    }

    private func payload(branch: String = "feature/review", base: String = "main", remoteHead: String = "",
                         count: String = "2", title: String = "Improve review", push: String = "https://github.com/team/app.git",
                         unpushed: String = "") -> Data {
        Data(([branch, head, "https://github.com/team/app.git", push,
               base.isEmpty ? "" : "refs/remotes/origin/" + base, remoteHead, count, title, unpushed, ""].joined(separator: "\0")).utf8)
    }
}

@MainActor
private final class PullRequestFixture {
    struct Call { let method: String; let path: String; let body: Data? }
    let context: GitPullRequestContext
    var remoteHead: String
    var baseHead = String(repeating: "c", count: 40)
    var defaultBranch = "main"
    var branches = ["main", "feature/review", "release/next"]
    var existing: GitHubPullRequest?
    var acceptThenFail: (any Error)?
    private(set) var calls: [Call] = []
    var client: GitHubPullRequestClient { .init { try self.respond($0, $1, $2) } }

    init(context: GitPullRequestContext) { self.context = context; remoteHead = context.head }

    private func respond(_ method: String, _ path: String, _ body: Data?) throws -> Data {
        calls.append(.init(method: method, path: path, body: body))
        if method == "POST" {
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
            let result = GitHubPullRequest(number: 23, title: try XCTUnwrap(value["title"] as? String),
                htmlURL: URL(string: "https://github.com/team/app/pull/23")!, draft: value["draft"] as? Bool ?? false,
                head: .init(ref: try XCTUnwrap(value["head"] as? String), sha: remoteHead),
                base: .init(ref: try XCTUnwrap(value["base"] as? String), sha: String(repeating: "c", count: 40)))
            existing = result
            if let acceptThenFail { self.acceptThenFail = nil; throw acceptThenFail }
            return try JSONEncoder().encode(result)
        }
        if path.contains("/pulls?") { return try JSONEncoder().encode(existing.map { [$0] } ?? []) }
        if path.contains("/branches?") {
            let query = URLComponents(string: "https://api.github.com" + path)?.queryItems
            let page = Int(query?.first { $0.name == "page" }?.value ?? "1") ?? 1
            return try JSONSerialization.data(withJSONObject: branches.dropFirst((page - 1) * 100).prefix(100).map {
                ["name": $0, "commit": ["sha": $0 == context.branch ? remoteHead : baseHead]] as [String: Any]
            })
        }
        if let range = path.range(of: "/branches/") {
            let branch = String(path[range.upperBound...]).removingPercentEncoding ?? ""
            return try JSONSerialization.data(withJSONObject: ["name": branch,
                "commit": ["sha": branch == context.branch ? remoteHead : baseHead]])
        }
        return try JSONSerialization.data(withJSONObject: ["default_branch": defaultBranch])
    }
}

private actor PullRequestCommandRecorder {
    private(set) var commands: [[String]] = []
    func run(_ command: [String]) -> ExecResult {
        commands.append(command)
        return ExecResult(exitCode: 0, stdout: "{}", stderr: "")
    }
}

private final class PullRequestHTTPFixture: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.respond!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
