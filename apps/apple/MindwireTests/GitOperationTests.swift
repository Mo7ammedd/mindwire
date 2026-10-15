import XCTest
@testable import Mindwire

@MainActor
final class GitOperationTests: XCTestCase {
    func testFailedOrTruncatedGitReadsNeverLookLikeEmptyFilesOrCleanRepositories() async throws {
        let clipped = try JSONDecoder().decode(ExecResult.self, from: Data(
            #"{"exitCode":0,"stdout":"YWJj","stderr":"","truncated":true}"#.utf8))
        let responses = [
            ExecResult(exitCode: 128, stdout: "", stderr: "The Git read failed"),
            ExecResult(exitCode: 0, stdout: "invalid % response", stderr: ""),
            clipped,
        ]
        for response in responses {
            let git = ExecGitService(workspace: SelfHostedWorkspaceService { _ in response }, root: "/project")
            do { _ = try await git.status(); XCTFail("Incomplete status must not mark a repository clean") } catch {}
            do { _ = try await git.diff(path: "file.swift", staged: false, unified: nil); XCTFail("Incomplete diff must not show no changes") } catch {}
            do { _ = try await git.blob(path: "file.swift", rev: .worktree); XCTFail("Incomplete file must not open an empty buffer") } catch {}
        }
        let unfinished = ExecGitService(workspace: SelfHostedWorkspaceService { _ in
            ExecResult(exitCode: 0, stdout: Data("# branch.head main\0".utf8).base64EncodedString(), stderr: "")
        }, root: "/project")
        do { _ = try await unfinished.status(); XCTFail("Status needs all of its response sections") } catch {}
        do { _ = try await unfinished.diff(path: "file.swift", staged: false, unified: nil); XCTFail("Diff needs both counts and patch") } catch {}
    }

    func testCompleteEmptyGitReadsAndWrappedBase64RemainValid() async throws {
        let empty = ExecGitService(workspace: SelfHostedWorkspaceService { _ in
            ExecResult(exitCode: 0, stdout: "\n", stderr: "")
        }, root: "/project")
        let missing = try await empty.status()
        XCTAssertFalse(missing.isRepo)
        let blob = try await empty.blob(path: "empty.swift", rev: .worktree)
        XCTAssertEqual(blob.content, "")
        let clean = ExecGitService(workspace: SelfHostedWorkspaceService { _ in
            ExecResult(exitCode: 0, stdout: "Hw==\n", stderr: "")
        }, root: "/project")
        let noChanges = try await clean.diff(path: "empty.swift", staged: false, unified: nil)
        XCTAssertEqual(noChanges.patch, "")
        let payload = "1\t1\tfile.swift\0\u{1f}@@ -1 +1 @@\n-old\n+new\n"
        let changed = ExecGitService(workspace: SelfHostedWorkspaceService { _ in
            ExecResult(exitCode: 0, stdout: Data(payload.utf8).base64EncodedString(options: .lineLength64Characters) + "\n", stderr: "")
        }, root: "/project")
        let diff = try await changed.diff(path: "file.swift", staged: false, unified: nil)
        XCTAssertEqual(diff.additions, 1)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertTrue(diff.patch.contains("+new"))
    }

    func testBranchManagementRetainsConfirmationAcrossReconnects() async throws {
        for action in [GitAction.renameBranch, .deleteBranch] {
            let channel = GitOperationsChannel(failure: .beforeAcceptance)
            let savedDefaults = try defaults()
            let original = client(channel, defaults: savedDefaults)
            let intent = GitOperationRequest(action: action, branch: "feature/review",
                newName: action == .renameBranch ? "feature/ready" : nil,
                expectedTip: String(repeating: "a", count: 40), force: action == .deleteBranch)
            XCTAssertEqual(intent.minimumOperationsVersion, 5)
            do { _ = try await original.start(intent) { nil }; XCTFail("Expected disconnect") } catch { }
            let reopened = client(channel, defaults: savedDefaults)
            XCTAssertEqual(reopened.pending?.request, intent)
            var changed = intent
            changed.expectedTip = String(repeating: "b", count: 40)
            do { _ = try await reopened.start(changed) { nil }; XCTFail("Stale branch confirmation was replaced") }
            catch { XCTAssertEqual(error.localizedDescription, t("git.operation.pending")) }
            await channel.reconnect(status: "succeeded")
            let result = try await reopened.start(intent) { nil }
            XCTAssertEqual(result.request, intent)
            let executions = await channel.executions
            XCTAssertEqual(executions, 1)
        }
    }

    func testBranchParserRetainsTheTipUsedToGuardDestructiveActions() {
        let tip = String(repeating: "a", count: 40)
        let branches = ExecGitService.parseBranches("refs/heads/main\t*\torigin/main\t\t\(tip)\n")
        XCTAssertEqual(branches.first?.tip, tip)
        XCTAssertEqual(branches.first?.name, "main")
    }

    func testRestoreIntentRetainsTheConfirmedVersionAndRepositoryAcrossReconnects() async throws {
        let channel = GitOperationsChannel(failure: .beforeAcceptance)
        let defaults = try defaults()
        let original = client(channel, defaults: defaults)
        let request = GitOperationRequest(action: .restoreCommit, commitId: String(repeating: "a", count: 40),
                                         expectedHead: String(repeating: "b", count: 40), expectedBranch: "main")
        XCTAssertEqual(request.minimumOperationsVersion, 4)
        do { _ = try await original.start(request) { nil }; XCTFail("Expected disconnect") } catch { }
        let reopened = client(channel, defaults: defaults)
        XCTAssertEqual(reopened.pending?.request, request)
        for change in ["commit", "head", "branch"] {
            var different = request
            switch change {
            case "commit": different.commitId = String(repeating: "c", count: 40)
            case "head": different.expectedHead = String(repeating: "c", count: 40)
            default: different.expectedBranch = "other"
            }
            do { _ = try await reopened.start(different) { nil }; XCTFail("Changed restoration was accepted") }
            catch { XCTAssertEqual(error.localizedDescription, t("git.operation.pending")) }
        }
        await channel.reconnect(status: "succeeded")
        let completed = try await reopened.start(request) { nil }
        XCTAssertTrue(completed.request.matches(request))
        XCTAssertNil(reopened.pending)
        let executions = await channel.executions
        XCTAssertEqual(executions, 1)
    }

    func testStatusRetainsImmutableHEADAndRecognizesAnUnbornBranch() {
        let head = String(repeating: "a", count: 40)
        let status = ExecGitService.parseStatus(Data("# branch.oid \(head)\0# branch.head main\0\u{1f}\u{1f}".utf8), root: "/repo")
        XCTAssertEqual(status.head, head)
        XCTAssertEqual(status.branch, "main")
        let unborn = ExecGitService.parseStatus(Data("# branch.oid (initial)\0# branch.head main\0\u{1f}\u{1f}".utf8), root: "/repo")
        XCTAssertNil(unborn.head)
        XCTAssertTrue(unborn.isRepo)
        XCTAssertEqual(unborn.branch, "main")
    }

    func testCommitAuthorIntentSurvivesDisconnectAndCannotChangeOnRetry() async throws {
        let channel = GitOperationsChannel(failure: .beforeAcceptance)
        let client = client(channel, defaults: try defaults())
        let author = GitIdentity(name: "Selected User", email: "selected@example.invalid")
        let request = GitOperationRequest(action: .commit, message: "My draft", identity: author)
        XCTAssertEqual(request.minimumOperationsVersion, 3)
        do { _ = try await client.start(request) { nil }; XCTFail("Expected disconnect") } catch { }
        do {
            _ = try await client.start(.init(action: .commit, message: "My draft", identity: .init(name: "Different", email: "other@example.invalid"))) { nil }
            XCTFail("Pending author was changed")
        } catch { XCTAssertEqual(error.localizedDescription, t("git.operation.pending")) }
        await channel.reconnect(status: "succeeded")
        let result = try await client.start(.init(action: .commit, message: "My draft", identity: author)) { nil }
        XCTAssertEqual(result.id, request.id)
        XCTAssertEqual(result.identity, author)
        XCTAssertTrue(result.request.matches(request))
        let executions = await channel.executions
        XCTAssertEqual(executions, 1)
    }

    func testHistoryParsingPreservesRenamesUnusualPathsAndRootParents() throws {
        let id = String(repeating: "a", count: 40)
        let metadata = [id, "", "User مرحبا", "user@example.invalid", "1700000000", "Initial commit"]
        let commits = ExecGitService.parseHistory(Data((metadata.joined(separator: "\0") + "\0").utf8))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].parents, [])
        XCTAssertEqual(commits[0].authorName, "User مرحبا")
        let names = "R100\0old\tname.swift\0new\nname.swift\0A\0literal[1].swift\0D\0deleted.swift\0M\0image.png\0"
        let stats = "0\t0\t\0old\tname.swift\0new\nname.swift\02\t0\tliteral[1].swift\00\t3\tdeleted.swift\0-\t-\timage.png\0"
        let files = ExecGitService.parseCommitFiles(names: Data(names.utf8), counts: Data(stats.utf8))
        XCTAssertEqual(files.map(\.path), ["new\nname.swift", "literal[1].swift", "deleted.swift", "image.png"])
        XCTAssertEqual(files[0].origPath, "old\tname.swift")
        XCTAssertEqual(files[1].staged?.additions, 2)
        XCTAssertEqual(files[2].staged?.deletions, 3)
        XCTAssertEqual(files[2].changeKind, .deleted)
        let partial = ExecGitService.parseCommitFiles(names: Data((names + "A\0unfinished").utf8), counts: Data(stats.utf8))
        XCTAssertEqual(partial, files, "Truncated paths must never become clickable file rows")
    }

    func testBranchIntentSurvivesRetryAndRejectsAnotherBranch() async throws {
        let channel = GitOperationsChannel(failure: .beforeAcceptance)
        let client = client(channel, defaults: try defaults())
        let intent = GitOperationRequest(action: .switchBranch, branch: "origin/release", remote: true)
        do { _ = try await client.start(intent) { nil }; XCTFail("Expected a lost acknowledgement") } catch { }
        do {
            _ = try await client.start(.init(action: .switchBranch, branch: "main")) { nil }
            XCTFail("Pending branch was replaced")
        } catch { XCTAssertEqual(error.localizedDescription, t("git.operation.pending")) }
        await channel.reconnect(status: "succeeded")
        let result = try await client.start(.init(action: .switchBranch, branch: "origin/release", remote: true)) { nil }
        XCTAssertEqual(result.id, intent.id)
        XCTAssertEqual(result.branch, "origin/release")
        XCTAssertEqual(result.remote, true)
        XCTAssertTrue(result.request.matches(intent))
        let executions = await channel.executions
        XCTAssertEqual(executions, 1)
    }

    func testBranchRefsKeepTrackingInformationAndExcludeSymbolicAliases() {
        let branches = ExecGitService.parseBranches("""
        refs/heads/feature/review\t \torigin/feature/review\t
        refs/heads/main\t*\torigin/main\t
        refs/remotes/origin/HEAD\t \t\trefs/remotes/origin/main
        refs/remotes/origin/release\t \t\t
        """)
        XCTAssertEqual(branches.map(\.name), ["main", "feature/review", "origin/release"])
        XCTAssertEqual(branches.first?.isCurrent, true)
        XCTAssertEqual(branches[1].upstream, "origin/feature/review")
        XCTAssertEqual(branches.last?.isRemote, true)
    }

    func testLostAcknowledgementSurvivesClientRecreationWithoutRepeatingWrite() async throws {
        let channel = GitOperationsChannel(failure: .afterAcceptance)
        let defaults = try defaults()
        let first = client(channel, defaults: defaults)
        let request = GitOperationRequest(action: .push)
        do {
            _ = try await first.start(request) { ProjectCloneAuth(kind: "token", token: "private-fixture") }
            XCTFail("Offline acknowledgement should keep the request pending")
        } catch { }
        XCTAssertEqual(first.pending?.id, request.id)
        let cache = try XCTUnwrap(defaults.data(forKey: "mindwire:git-operation-receipts:v1"))
        XCTAssertFalse(String(decoding: cache, as: UTF8.self).contains("private-fixture"))
        await channel.reconnect(status: "succeeded")
        let recreated = client(channel, defaults: defaults)
        let recovered = try await recreated.recover()
        XCTAssertEqual(recovered?.id, request.id)
        XCTAssertEqual(recovered?.status, "succeeded")
        XCTAssertNil(recreated.pending)
        let calls = await channel.posts
        let executions = await channel.executions
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(executions, 1)
    }

    func testReconnectOnlyObservesAndExplicitRetryKeepsOriginalID() async throws {
        let channel = GitOperationsChannel(failure: .beforeAcceptance)
        let defaults = try defaults()
        let first = client(channel, defaults: defaults)
        let request = GitOperationRequest(action: .commit, message: "Only once")
        do { _ = try await first.start(request) { nil }; XCTFail("Expected a lost connection") } catch { }
        await channel.reconnect(status: "succeeded")
        let recreated = client(channel, defaults: defaults)
        do { _ = try await recreated.recover(); XCTFail("Missing operation needs explicit retry") } catch { }
        let beforeRetry = await channel.posts
        XCTAssertEqual(beforeRetry.count, 1, "Opening Source Control must not replay a pending commit")
        let result = try await recreated.start(.init(action: .commit, message: "Only once")) { nil }
        XCTAssertEqual(result.id, request.id)
        let posts = await channel.posts
        XCTAssertEqual(posts.map(\.id), [request.id, request.id])
        let executions = await channel.executions
        XCTAssertEqual(executions, 1)
    }

    func testPendingRequestCannotBeReplacedWithAnotherMutation() async throws {
        let channel = GitOperationsChannel(failure: .beforeAcceptance)
        let client = client(channel, defaults: try defaults())
        let request = GitOperationRequest(action: .stage, paths: ["original"])
        do { _ = try await client.start(request) { nil } } catch { }
        do {
            _ = try await client.start(.init(action: .discard, paths: ["different"])) { nil }
            XCTFail("Unresolved intent was replaced")
        } catch { XCTAssertEqual(error.localizedDescription, t("git.operation.pending")) }
        XCTAssertEqual(client.pending?.id, request.id)
        let posts = await channel.posts
        XCTAssertEqual(posts.count, 1)
    }

    func testWorkspaceReplacementNeverReplaysAnOldRequest() async throws {
        let channel = GitOperationsChannel()
        let defaults = try defaults()
        let request = GitOperationRequest(action: .push)
        let receipts = GitOperationClient.receipts(defaults: defaults)
        receipts.save(.init(workspaceId: "workspace", registryId: "old-registry", projectId: "project", request: request))
        let client = client(channel, defaults: defaults)
        do { _ = try await client.start(request) { nil }; XCTFail("Old request crossed a registry replacement") }
        catch { XCTAssertEqual(error.localizedDescription, t("git.operation.workspaceChanged")) }
        let posts = await channel.posts
        XCTAssertTrue(posts.isEmpty)
    }

    func testAnotherDeviceFindsActiveWorkAndObserverCancellationDoesNotCancelIt() async throws {
        let channel = GitOperationsChannel(terminal: false)
        let original = client(channel, defaults: try defaults())
        let request = GitOperationRequest(action: .fetch)
        let operation = try await original.start(request) { nil }
        let second = client(channel, defaults: try defaults())
        let recovered = try await second.recover()
        XCTAssertEqual(recovered?.id, operation.id)
        XCTAssertEqual(second.pending?.id, operation.id)
        let observer = Task { try await second.wait(operation) { _ in } }
        observer.cancel()
        do { _ = try await observer.value; XCTFail("Observer did not detach") } catch { }
        let cancellations = await channel.cancellations
        XCTAssertEqual(cancellations, 0)
        let cancelled = try await second.cancel(operation.id)
        XCTAssertEqual(cancelled.status, "cancelled")
        XCTAssertNil(second.pending)
        let explicitCancellations = await channel.cancellations
        XCTAssertEqual(explicitCancellations, 1)
    }

    func testFileCompletionArrivesOnTheStreamWithoutPollingOrRepeatingTheWrite() async throws {
        let channel = StreamingGitOperationsChannel()
        let client = client(channel, defaults: try defaults())
        let initial = try await client.start(.init(action: .stage, paths: ["Sources/File.swift"])) { nil }
        var statuses: [String] = []
        let completed = try await client.wait(initial) { statuses.append($0.status) }
        XCTAssertEqual(completed.status, "succeeded")
        XCTAssertEqual(statuses, ["running", "succeeded"], "Duplicate snapshots must not trigger more UI updates")
        XCTAssertNil(client.pending)
        let streams = await channel.streamPaths
        XCTAssertEqual(streams, ["/workspace/git/operations/\(initial.id)/stream"])
        let reads = await channel.receiptReads
        XCTAssertEqual(reads, 0, "A live completion must not wait for the polling fallback")
        let writes = await channel.base.executions
        XCTAssertEqual(writes, 1)
    }

    func testDroppedCompletionStreamRecoversTheReceiptWithoutResubmitting() async throws {
        let channel = StreamingGitOperationsChannel(dropStream: true)
        let client = client(channel, defaults: try defaults())
        let initial = try await client.start(.init(action: .unstage, paths: ["Sources/File.swift"])) { nil }
        let result = try await client.wait(initial) { _ in }
        XCTAssertEqual(result.status, "succeeded")
        XCTAssertNil(client.pending)
        let reads = await channel.receiptReads
        XCTAssertEqual(reads, 1)
        let writes = await channel.base.executions
        XCTAssertEqual(writes, 1)
    }

    func testOpeningSourceControlDoesNotReplayAnOldFailedOperation() async throws {
        let channel = GitOperationsChannel()
        let original = client(channel, defaults: try defaults())
        _ = try await original.start(.init(action: .stage, paths: ["file.swift"])) { nil }
        await channel.reconnect(status: "failed")
        let reopened = client(channel, defaults: try defaults())
        let recovered = try await reopened.recover()
        XCTAssertNil(recovered, "Historical failures must not resurface as a new error each time the screen opens")
        XCTAssertNil(reopened.pending)
        let writes = await channel.executions
        XCTAssertEqual(writes, 1)
    }

    private func defaults() throws -> UserDefaults {
        let name = "git-operations-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func client(_ channel: any DaemonChannel, defaults: UserDefaults) -> GitOperationClient {
        GitOperationClient(http: .init(channel: channel, agentType: ""), workspaceId: "workspace", registryId: "registry",
            projectId: "project", receipts: GitOperationClient.receipts(defaults: defaults))
    }
}

actor GitOperationsChannel: DaemonChannel {
    nonisolated let label = "git-operations-fixture"
    enum Failure { case none, beforeAcceptance, afterAcceptance }
    struct Post { let id: String; let body: Data }
    private var failure: Failure
    private var terminal: Bool
    private var offline = false
    private var records: [String: [String: Any]] = [:]
    private(set) var posts: [Post] = []
    private(set) var executions = 0
    private(set) var cancellations = 0
    private var onExecution: (@Sendable () async -> Void)?
    private var holdRecovery = false
    private var recoveryGate: CheckedContinuation<Void, Never>?

    var waitingForRecovery: Bool { recoveryGate != nil }
    func holdRecoveryRead() { holdRecovery = true }
    func releaseRecoveryRead() { holdRecovery = false; recoveryGate?.resume(); recoveryGate = nil }

    init(failure: Failure = .none, terminal: Bool = true) { self.failure = failure; self.terminal = terminal }
    func onExecution(_ action: @escaping @Sendable () async -> Void) { onExecution = action }

    func reconnect(status: String) {
        offline = false; failure = .none; terminal = status == "succeeded"
        for id in Array(records.keys) {
            let sequence = (records[id]?["sequence"] as? Int ?? 0) + 1
            records[id]?["status"] = status
            records[id]?["sequence"] = sequence
        }
    }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        if offline { throw URLError(.notConnectedToInternet) }
        if method == "GET", path == "/workspace/projects/project/git" {
            return (200, #"{"connection":null,"inherited":true,"stored":false,"repoUrl":"https://github.com/team/app.git"}"#)
        }
        if method == "POST", path == "/workspace/projects/project/git/operations" {
            guard let data = jsonBody, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = body["id"] as? String, let action = body["action"] as? String else { throw URLError(.badServerResponse) }
            posts.append(.init(id: id, body: data))
            if failure == .beforeAcceptance { failure = .none; throw URLError(.networkConnectionLost) }
            if records[id] == nil {
                executions += 1
                var record: [String: Any] = ["id": id, "projectId": "project", "action": action,
                    "status": terminal ? "succeeded" : "running", "createdAt": "2026-09-19T12:00:00Z",
                    "updatedAt": "2026-09-19T12:00:01Z", "sequence": 2, "output": "Done"]
                record["paths"] = body["paths"]; record["message"] = body["message"]
                record["branch"] = body["branch"]; record["remote"] = body["remote"]
                record["identity"] = body["identity"]
                record["commitId"] = body["commitId"]; record["expectedHead"] = body["expectedHead"]
                record["expectedBranch"] = body["expectedBranch"]
                record["newName"] = body["newName"]
                record["expectedTip"] = body["expectedTip"]
                record["force"] = body["force"]
                records[id] = record
                await onExecution?()
            }
            if failure == .afterAcceptance { failure = .none; offline = true; throw URLError(.networkConnectionLost) }
            return try response(202, records[id]!)
        }
        if method == "GET", path == "/workspace/projects/project/git/operations?active=true&actionsVersion=5" {
            if holdRecovery { await withCheckedContinuation { recoveryGate = $0 } }
            return try response(200, ["operations": Array(records.values)])
        }
        if path.hasPrefix("/workspace/git/operations/") {
            let components = path.split(separator: "/")
            let id = String(components[3])
            guard var record = records[id] else { return (404, #"{"error":"not found"}"#) }
            if method == "POST", path.hasSuffix("/cancel") {
                cancellations += 1; record["status"] = "cancelled"; records[id] = record
            }
            return try response(200, record)
        }
        throw URLError(.unsupportedURL)
    }

    private func response(_ status: Int, _ value: Any) throws -> (status: Int, body: String) {
        (status, String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
}

private actor StreamingGitOperationsChannel: StreamingDaemonChannel {
    nonisolated let label = "streaming-git-operations-fixture"
    let base = GitOperationsChannel(terminal: false)
    let dropStream: Bool
    private(set) var streamPaths: [String] = []
    private(set) var receiptReads = 0

    init(dropStream: Bool = false) { self.dropStream = dropStream }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        if method == "GET", path.hasPrefix("/workspace/git/operations/") { receiptReads += 1 }
        return try await base.perform(method: method, path: path, jsonBody: jsonBody)
    }

    func stream(method: String, path: String, jsonBody: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        guard method == "GET", path.hasSuffix("/stream"), jsonBody == nil else { throw URLError(.unsupportedURL) }
        streamPaths.append(path)
        let receipt = String(path.dropLast("/stream".count))
        let initial = try await base.perform(method: "GET", path: receipt, jsonBody: nil)
        await base.reconnect(status: "succeeded")
        let completed = try await base.perform(method: "GET", path: receipt, jsonBody: nil)
        let drop = dropStream
        return AsyncThrowingStream { continuation in
            continuation.yield(Data(initial.body.utf8))
            if drop { continuation.finish(throwing: URLError(.networkConnectionLost)) }
            else {
                continuation.yield(Data(initial.body.utf8))
                continuation.yield(Data(completed.body.utf8))
                continuation.finish()
            }
        }
    }
}
