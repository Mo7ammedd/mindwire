import SwiftUI
import UIKit
import Vision
import XCTest
@testable import Mindwire

@MainActor
final class GitReviewTests: XCTestCase {
    func testUnavailableServiceKeepsGitReviewVisibleAndOffersServiceRecovery() async throws {
        let fixture = GitReviewFixture(), registry = WorkspaceRemoteFixture()
        registry.prepareError = DaemonHTTPError(status: 502, message: "proxy cannot reach service")
        let (model, stores) = try makeModel(fixture, registry: registry)
        await model.load()
        XCTAssertTrue(model.isRepo)
        XCTAssertFalse(model.allChanges.isEmpty)
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.serviceRecoveryNeeded)
        let files = model.allChanges
        let window = try await render(SourceControlScreen(workspaceId: model.workspaceId, model: model),
            stores: stores, name: "mindwire-source-control-service-recovery")
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(window.rootViewController)))
        XCTAssertTrue(text.contains(t("git.serviceRecovery.title")), text)
        XCTAssertTrue(text.contains(t("workspace.daemon.title")), text)
        XCTAssertFalse(text.contains(t("git.loadFailed")), text)
        window.isHidden = true
        registry.prepareError = nil
        await model.refresh()
        XCTAssertFalse(model.serviceRecoveryNeeded)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.allChanges, files)
        let writes = await fixture.writes
        XCTAssertTrue(writes.isEmpty, "A service check must not bypass coordinated Git writes")
        await model.dispose()
    }

    func testPullRequestAppearsAfterCommitAndUsesTheCompactNativeSheet() async throws {
        let fixture = GitReviewFixture()
        await fixture.enablePullRequests(count: 0)
        let (model, stores) = try makeModel(fixture)
        await model.load()
        XCTAssertTrue(model.canCreatePullRequest, "A feature branch can review its staged files before the first commit")
        let committed = await model.commit("Polish the chat composer")
        XCTAssertTrue(committed)
        XCTAssertTrue(model.canCreatePullRequest)
        XCTAssertTrue(model.pullRequestContext?.needsPush == true)
        let writes = await fixture.writes
        XCTAssertEqual(writes, [.commit], "Committing must not automatically push or open a pull request")
        let overview = try await render(SourceControlScreen(workspaceId: "fixture", model: model),
                                        stores: stores, name: "mindwire-source-control-pull-request")
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(overview.rootViewController)))
        XCTAssertTrue(text.contains(t("git.pr.title")), text)
        overview.isHidden = true
        let sheet = try await render(GitPullRequestSheet(model: model), stores: stores, name: "mindwire-pull-request-sheet")
        let sheetText = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(sheet.rootViewController)))
        XCTAssertTrue(sheetText.contains(t("git.pr.pushCreate")), sheetText)
        XCTAssertTrue(sheetText.contains("Polish the chat composer"), sheetText)
        sheet.isHidden = true
        let light = try await render(GitPullRequestSheet(model: model), stores: stores,
                                     name: "mindwire-pull-request-light", width: 320, scheme: .light)
        light.isHidden = true
        let presented = try await render(SourceControlScreen(workspaceId: "fixture", model: model)
            .sheet(isPresented: .constant(true)) { GitPullRequestSheet(model: model) },
            stores: stores, name: "mindwire-pull-request-presentation")
        let presentedImage = try reviewSnapshot(presented, name: "mindwire-pull-request-presented")
        let presentedText = try ChatFeedSnapshot.visibleText(in: presentedImage)
        XCTAssertTrue(presentedText.contains(t("git.pr.pushCreate")), presentedText)
        XCTAssertTrue(presentedText.contains("Polish the chat composer"), "The native sheet should fit its commit preview: \(presentedText)")
        presented.isHidden = true
        await model.dispose()
    }

    func testPublishedPullRequestLeavesLocalFilesAndCredentialsAlone() async throws {
        let fixture = GitReviewFixture()
        await fixture.enablePullRequests(published: true)
        let (model, _) = try makeModel(fixture)
        await model.load()
        let files = model.allChanges
        let context = try XCTUnwrap(model.pullRequestContext)
        let url = await model.createPullRequest(context, draft: .init(title: context.title, base: "main"))
        XCTAssertEqual(url?.head.ref, context.branch)
        XCTAssertEqual(url?.title, context.title)
        XCTAssertEqual(model.allChanges, files)
        let writes = await fixture.writes
        XCTAssertTrue(writes.isEmpty, "Already published commits should create through the GitHub API without another Git write")
        XCTAssertFalse(model.openingPullRequest)
        await model.dispose()
    }

    func testPullRequestMetadataIsCachedAcrossLocalEditsAndSharedAcrossRefreshes() async throws {
        let fixture = GitReviewFixture()
        await fixture.enablePullRequests()
        let (model, _) = try makeModel(fixture)
        await model.load()
        _ = await model.stage([GitReviewFixture.mixed.path])
        let initial = await fixture.pullRequestReads
        XCTAssertEqual(initial, 1, "Staging does not change the branch's published commits")
        await fixture.holdStatusReads()
        let first = Task { await model.refresh() }
        let second = Task { await model.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        await fixture.releaseStatusReads()
        await first.value; await second.value
        let refreshed = await fixture.pullRequestReads
        XCTAssertEqual(refreshed, 2, "Concurrent manual refreshes share the metadata read")
        _ = await model.switchBranch(GitBranch(name: "main"))
        XCTAssertFalse(model.canCreatePullRequest)
        await model.dispose()
    }

    func testPullRequestMetadataFailureStopsCreationWithoutHidingWorkingFiles() async throws {
        let fixture = GitReviewFixture()
        await fixture.enablePullRequests(published: true)
        let (model, _) = try makeModel(fixture)
        await model.load()
        let files = model.allChanges
        let context = try XCTUnwrap(model.pullRequestContext)
        let failure = URLError(.networkConnectionLost)
        await fixture.failPullRequestLookup(failure)
        let url = await model.createPullRequest(context, draft: .init(title: context.title, base: "main"))
        XCTAssertNil(url)
        XCTAssertEqual(model.error, failure.localizedDescription)
        XCTAssertEqual(model.allChanges, files)
        XCTAssertFalse(model.openingPullRequest)
        await fixture.failPullRequestLookup(nil)
        await model.refresh()
        XCTAssertTrue(model.canCreatePullRequest)
        XCTAssertNil(model.error)
        let writes = await fixture.writes
        XCTAssertTrue(writes.isEmpty)
        await model.dispose()
    }

    func testPullRequestRejectsStaleConfirmationAndDuplicateTaps() async throws {
        let fixture = GitReviewFixture()
        await fixture.enablePullRequests(published: true)
        let (model, _) = try makeModel(fixture)
        await model.load()
        let original = try XCTUnwrap(model.pullRequestContext)
        await fixture.prependCommit()
        let stale = await model.createPullRequest(original, draft: .init(title: original.title, base: "main"))
        XCTAssertNil(stale)
        XCTAssertEqual(model.error, t("git.pr.changed"))
        let current = try XCTUnwrap(model.pullRequestContext)
        await fixture.holdStatusReads()
        let first = Task { await model.createPullRequest(current, draft: .init(title: current.title, base: "main")) }
        for _ in 0..<100 {
            if model.openingPullRequest { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.openingPullRequest)
        let duplicate = await model.createPullRequest(current, draft: .init(title: current.title, base: "main"))
        let conflicting = await model.stage([GitReviewFixture.mixed.path])
        XCTAssertNil(duplicate)
        XCTAssertFalse(conflicting)
        await fixture.releaseStatusReads()
        let ready = await first.value
        XCTAssertEqual(ready?.head.ref, current.branch)
        let writes = await fixture.writes
        XCTAssertTrue(writes.isEmpty)
        await model.dispose()
    }

    func testPullRequestPushUsesDurableOperationsAndPreservesUncommittedFiles() async throws {
        let fixture = GitReviewFixture()
        await fixture.enablePullRequests(published: true)
        let channel = GitOperationsChannel()
        let registry = WorkspaceRemoteFixture()
        registry.supportsGitAccess = true
        registry.gitOperationsProvider = { _ in DaemonHTTP(channel: channel, agentType: "") }
        registry.gitAccessProvider = { DaemonHTTP(channel: channel, agentType: "") }
        await channel.onExecution { await fixture.publishPullRequestBranch() }
        let (model, _) = try makeModel(fixture, registry: registry)
        await model.load()
        let files = model.allChanges
        let context = try XCTUnwrap(model.pullRequestContext)
        XCTAssertFalse(context.needsPush, "The local tracking ref is deliberately stale")
        let preview = try await model.pullRequestComparison(context, base: "main",
            baseHead: String(repeating: "b", count: 40), remoteHead: nil)
        let url = await model.createPullRequest(context, draft: .init(title: context.title, base: "main"), comparison: preview)
        XCTAssertEqual(url?.head.ref, context.branch, model.error ?? "")
        XCTAssertEqual(model.allChanges, files)
        XCTAssertFalse(model.pullRequestContext?.needsPush ?? true)
        let posts = await channel.posts
        XCTAssertEqual(posts.count, 1)
        let request = try JSONDecoder().decode(GitOperationRequest.self, from: XCTUnwrap(posts.first?.body))
        XCTAssertEqual(request.action, .push)
        XCTAssertNil(request.force)
        let writes = await fixture.writes
        XCTAssertTrue(writes.isEmpty, "The PR flow must not stage, commit, or run an uncoordinated Git write")
        await model.dispose()
    }

    func testPullRequestPreviewExcludesTheIndexAndRejectsAChangedBaseSelection() async throws {
        let fixture = GitReviewFixture()
        await fixture.enablePullRequests(published: true)
        let (model, _) = try makeModel(fixture)
        await model.load()
        let context = try XCTUnwrap(model.pullRequestContext)
        let local = model.allChanges
        let comparison = try await model.pullRequestComparison(context, base: "main",
            baseHead: String(repeating: "b", count: 40), remoteHead: context.head)
        XCTAssertEqual(comparison.files.map(\.path), ["Sources/Committed.swift"])
        XCTAssertFalse(comparison.files.contains { $0.path == GitReviewFixture.mixed.path })
        let file = try XCTUnwrap(comparison.files.first)
        let diff = try await DiffParser.lines(model: model, change: file, staged: true, comparison: comparison)
        XCTAssertTrue(diff.lines.contains { $0.text.contains("committedCode()") })
        let rejected = await model.createPullRequest(context, draft: .init(title: "Reviewed", base: "develop"), comparison: comparison)
        XCTAssertNil(rejected)
        XCTAssertEqual(model.error, t("git.pr.changed"))
        XCTAssertEqual(model.allChanges, local)
        let writes = await fixture.writes
        XCTAssertTrue(writes.isEmpty)
        await model.dispose()
    }

    func testPullRequestLostPushReceiptCanBeRecoveredWithoutPublishingTwice() async throws {
        let fixture = GitReviewFixture()
        await fixture.enablePullRequests()
        let channel = GitOperationsChannel(failure: .afterAcceptance)
        let registry = WorkspaceRemoteFixture()
        registry.supportsGitAccess = true
        registry.gitOperationsProvider = { _ in DaemonHTTP(channel: channel, agentType: "") }
        registry.gitAccessProvider = { DaemonHTTP(channel: channel, agentType: "") }
        await channel.onExecution { await fixture.publishPullRequestBranch() }
        let (model, _) = try makeModel(fixture, registry: registry)
        await model.load()
        let context = try XCTUnwrap(model.pullRequestContext)
        let interrupted = await model.createPullRequest(context, draft: .init(title: context.title, base: "main"))
        XCTAssertNil(interrupted, "A missing push receipt must not create a pull request with unconfirmed commits")
        XCTAssertTrue(model.hasPendingOperation)
        await channel.reconnect(status: "succeeded")
        await model.retryPendingOperation()
        XCTAssertFalse(model.hasPendingOperation)
        let ready = await model.createPullRequest(try XCTUnwrap(model.pullRequestContext), draft: .init(title: context.title, base: "main"))
        XCTAssertEqual(ready?.head.ref, context.branch)
        let executions = await channel.executions
        XCTAssertEqual(executions, 1)
        await model.dispose()
    }

    func testMissingCommitAuthorOpensSetupAndPreservesStagedWork() async throws {
        let fixture = GitReviewFixture()
        await fixture.setIdentity(GitIdentity())
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let files = model.allChanges
        let accepted = await model.commit("Keep this commit message")
        XCTAssertFalse(accepted)
        XCTAssertTrue(model.identityRequired)
        XCTAssertNil(model.error, "Author setup must not become a generic command failure")
        XCTAssertEqual(model.allChanges, files)
        let before = await fixture.committedMessages
        XCTAssertTrue(before.isEmpty)
        let window = try await render(GitCommitSheet(model: model, message: .constant("Keep this commit message")),
                                      stores: stores, name: "mindwire-commit-author")
        defer { window.isHidden = true }
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(window.rootViewController)))
        XCTAssertTrue(text.contains(t("git.identity.name")), text)
        XCTAssertTrue(text.contains(t("git.identity.email")), text)
        let saved = await model.saveAuthor(.init(name: "Chosen User", email: "chosen@example.invalid"), scope: .repository)
        XCTAssertTrue(saved)
        XCTAssertFalse(model.identityRequired)
        let afterSave = await fixture.committedMessages
        XCTAssertTrue(afterSave.isEmpty, "Saving an author must not commit the preserved draft")
        XCTAssertEqual(model.allChanges, files, "Saving an author must preserve the staged and working files")
        let completed = await model.commit("Keep this commit message")
        XCTAssertTrue(completed)
        let after = await fixture.committedMessages
        XCTAssertEqual(after, ["Keep this commit message"])
        await model.dispose()
    }

    func testCommitSheetUsesCompactFileRowsAndUnstagingPreservesTheWorkingCopy() async throws {
        let fixture = GitReviewFixture()
        let files = (1...8).map {
            GitFileChange(path: "Sources/File\($0).swift", kind: "modified", index: "M", worktree: "M",
                          staged: .init(additions: 4, deletions: 2), unstaged: .init(additions: 1))
        }
        await fixture.useFiles(files)
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let window = try await render(GitCommitSheet(model: model, message: .constant("Polish source control")),
                                      stores: stores, name: "mindwire-commit-compact")
        defer { window.isHidden = true }
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(window.rootViewController)))
        XCTAssertTrue(text.contains("File4.swift"), "Compact staged files should fit without opening a disclosure: \(text)")
        XCTAssertTrue(text.lowercased().contains(t("git.unstageAll").lowercased()), text)
        let removed = await model.unstage([files[0].path])
        XCTAssertTrue(removed)
        XCTAssertEqual(model.staged.count, 7)
        XCTAssertEqual(model.allChanges.count, 8, "Unstage must keep the file in working changes")
        XCTAssertTrue(model.unstaged.contains { $0.path == files[0].path })
        await model.dispose()
    }

    func testGitHubAuthenticationFailureKeepsCommitDraftForExplicitRetry() async throws {
        let fixture = GitReviewFixture()
        let failure = "fatal: could not read Username for 'https://github.com': terminal prompts disabled"
        await fixture.setWriteError(BackendError.message(failure))
        let (model, _) = try makeModel(fixture)
        await model.load()
        let files = model.allChanges
        let accepted = await model.commit("Keep this draft")
        XCTAssertFalse(accepted)
        XCTAssertTrue(model.authenticationRequired)
        XCTAssertFalse(model.identityRequired)
        XCTAssertFalse(model.isMutating)
        XCTAssertEqual(model.allChanges, files)
        await fixture.setWriteError(nil)
        await model.refresh()
        let beforeRetry = await fixture.committedMessages
        XCTAssertTrue(beforeRetry.isEmpty, "Refreshing access must not replay a failed commit hook")
        let retried = await model.commit("Keep this draft")
        XCTAssertTrue(retried)
        XCTAssertFalse(model.authenticationRequired)
        let messages = await fixture.committedMessages
        XCTAssertEqual(messages, ["Keep this draft"])
        await model.dispose()
    }

    func testCleanSourceControlPushesUnpublishedBranchOnceAndReturnsToCleanState() async throws {
        let fixture = GitReviewFixture(), channel = GitOperationsChannel(), registry = WorkspaceRemoteFixture()
        await fixture.useFiles([])
        await fixture.enablePullRequests()
        registry.supportsGitAccess = true
        registry.gitOperationsProvider = { _ in DaemonHTTP(channel: channel, agentType: "") }
        registry.gitAccessProvider = { DaemonHTTP(channel: channel, agentType: "") }
        await channel.onExecution { await fixture.publishPullRequestBranch() }
        let (model, _) = try makeModel(fixture, registry: registry)
        await model.load()
        XCTAssertTrue(model.hasUnpushedCommits)
        let reads = await fixture.pullRequestReads
        for _ in 0..<10 { XCTAssertTrue(model.hasUnpushedCommits) }
        let unchangedReads = await fixture.pullRequestReads
        XCTAssertEqual(reads, unchangedReads, "Rendering the action must not trigger additional remote reads")
        let pushed = await model.runRemote(.push)
        XCTAssertTrue(pushed, model.error ?? "")
        XCTAssertFalse(model.hasUnpushedCommits)
        XCTAssertTrue(model.isClean)
        let posts = await channel.posts
        XCTAssertEqual(posts.count, 1)
        let request = try JSONDecoder().decode(GitOperationRequest.self, from: XCTUnwrap(posts.first?.body))
        XCTAssertEqual(request.action, .push)
        XCTAssertNil(request.force)
        await model.dispose()
    }

    func testAuthorSetupRequiresTheDaemonCapabilityForRegisteredProjects() async throws {
        let fixture = GitReviewFixture()
        let (model, _) = try makeModel(fixture, registry: WorkspaceRemoteFixture())
        await model.load()
        let result = await model.saveAuthor(.init(name: "User", email: "user@example.invalid"), scope: .repository)
        XCTAssertFalse(result)
        XCTAssertEqual(model.error, t("git.identity.updateRequired"))
        let writes = await fixture.writes
        XCTAssertTrue(writes.isEmpty, "Author setup must never fall back to committing")
        await model.dispose()
    }

    func testAuthorCanBeSavedWithoutStagedFilesOrACommitDraft() async throws {
        let fixture = GitReviewFixture()
        await fixture.useFiles([])
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let saved = await model.saveAuthor(.init(name: "Independent Author", email: "author@example.invalid"), scope: .workspace)
        XCTAssertTrue(saved)
        let messages = await fixture.committedMessages
        XCTAssertTrue(messages.isEmpty)
        let window = try await render(NavigationStack { GitAuthorScreen(model: model, onSaved: {}) },
                                      stores: stores, name: "mindwire-author-scopes")
        defer { window.isHidden = true }
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(window.rootViewController)))
        XCTAssertTrue(text.contains(t("git.identity.scope.all_workspaces")), text)
        XCTAssertTrue(text.contains(t("git.identity.save")), text)
        XCTAssertFalse(text.contains("Save & Commit"), text)
        await model.dispose()
    }

    func testCleanSourceControlShowsAQuietEmptyStateAndHistory() async throws {
        let fixture = GitReviewFixture()
        await fixture.useFiles([])
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let window = try await render(SourceControlScreen(workspaceId: "fixture", model: model),
                                      stores: stores, name: "mindwire-source-control-clean")
        defer { window.isHidden = true }
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(window.rootViewController)))
        XCTAssertTrue(text.contains(t("git.clean")), text)
        XCTAssertTrue(text.contains(t("git.history.shortTitle")), text)
        await model.dispose()
    }

    func testFreshRepositoryAndRemoteActionsRenderWithTheSharedNativeLayout() async throws {
        let fixture = GitReviewFixture()
        await fixture.useFiles([])
        await fixture.useCommits([])
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let fresh = try await render(SourceControlScreen(workspaceId: "fixture", model: model),
                                     stores: stores, name: "mindwire-source-control-unborn")
        let freshText = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(fresh.rootViewController)))
        XCTAssertTrue(freshText.contains(t("git.history.empty")), freshText)
        fresh.isHidden = true
        await model.dispose()
        let (connected, connectedStores) = try makeModel(GitReviewFixture(), registry: WorkspaceRemoteFixture())
        await connected.load()
        let sync = try await render(GitSyncSheet(model: connected), stores: connectedStores, name: "mindwire-git-sync")
        defer { sync.isHidden = true }
        let syncText = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(sync.rootViewController)))
        for operation in GitRemoteOperation.allCases { XCTAssertTrue(syncText.contains(operation.title), syncText) }
        await connected.dispose()
    }

    func testRestorationUsesDurableOperationsAndReturnsStagedChangesForReview() async throws {
        let fixture = GitReviewFixture()
        let channel = GitOperationsChannel()
        let registry = WorkspaceRemoteFixture()
        registry.gitOperationsProvider = { _ in DaemonHTTP(channel: channel, agentType: "") }
        let (model, stores) = try makeModel(fixture, registry: registry)
        await model.load()
        let page = try await model.history()
        let commit = try XCTUnwrap(page.commits.last)
        let dirtyPlan = await model.prepareRestore(commit)
        XCTAssertNil(dirtyPlan)
        XCTAssertEqual(model.error, t("git.restore.dirty"))
        await fixture.useFiles([])
        let prepared = await model.prepareRestore(commit)
        let plan = try XCTUnwrap(prepared)
        XCTAssertEqual(plan.head, page.commits.first?.id)
        XCTAssertEqual(plan.branch, "feature/chat-input")
        await channel.onExecution {
            await fixture.useFiles([GitFileChange(path: "Sources/Chat/Composer.swift", kind: "modified", index: "M", worktree: ".",
                                                 staged: .init(additions: 3, deletions: 1))])
        }
        let restored = await model.restore(plan)
        XCTAssertTrue(restored)
        XCTAssertEqual(model.staged.count, 1)
        XCTAssertEqual(model.status?.head, plan.head)
        XCTAssertEqual(model.operationNotice, t("git.restore.done"))
        let writes = await fixture.writes
        XCTAssertTrue(writes.isEmpty, "Restoration must use the daemon rather than an exec fallback")
        let posts = await channel.posts
        let request = try JSONDecoder().decode(GitOperationRequest.self, from: XCTUnwrap(posts.first?.body))
        XCTAssertTrue(request.matches(plan.request))
        let window = try await render(SourceControlScreen(workspaceId: "fixture", model: model),
                                      stores: stores, name: "mindwire-source-control-restored")
        defer { window.isHidden = true }
        await model.dispose()
    }

    func testRestorationOnAnOlderServiceRequiresAnUpdateWithoutExecutingGit() async throws {
        let fixture = GitReviewFixture()
        await fixture.useFiles([])
        let (model, _) = try makeModel(fixture, registry: WorkspaceRemoteFixture())
        await model.load()
        let page = try await model.history()
        let plan = await model.prepareRestore(try XCTUnwrap(page.commits.last))
        XCTAssertNil(plan)
        XCTAssertEqual(model.error, t("git.restore.updateRequired"))
        let writes = await fixture.writes
        XCTAssertTrue(writes.isEmpty)
        await model.dispose()
    }

    func testUnstagingRenameIncludesBothPaths() async throws {
        let fixture = GitReviewFixture()
        await fixture.useFiles([GitFileChange(path: "new.swift", origPath: "old.swift", kind: "renamed", index: "R", worktree: ".")])
        let (model, _) = try makeModel(fixture)
        await model.load()
        let result = await model.unstage(["new.swift"])
        XCTAssertTrue(result)
        let paths = await fixture.unstagedPaths
        XCTAssertEqual(Set(paths), ["old.swift", "new.swift"], "Unstage must not leave a staged deletion at the rename source")
        await model.dispose()
    }

    func testHistoryPaginationKeepsItsTipAndRetainsRowsAfterAnError() async throws {
        let fixture = GitReviewFixture()
        let (model, _) = try makeModel(fixture)
        let state = GitHistoryState()
        await state.refresh(model)
        let initial = state.commits
        let tip = try XCTUnwrap(state.next?.tip)
        await fixture.prependCommit()
        await fixture.setFailure(true)
        await state.loadMore(model)
        XCTAssertEqual(state.commits, initial)
        XCTAssertNotNil(state.error)
        await fixture.setFailure(false)
        await state.loadMore(model)
        XCTAssertEqual(state.commits.count, 6)
        XCTAssertEqual(Set(state.commits.map(\.id)).count, 6)
        XCTAssertEqual(state.commits.first?.id, tip, "New commits must not shift an open history's pagination")
        await state.loadMore(model)
        XCTAssertEqual(state.commits.count, 8)
        XCTAssertNil(state.next)
        await state.refresh(model)
        XCTAssertEqual(state.commits.first?.subject, "New commit", "Explicit refresh picks up the current tip")
        await model.dispose()
    }

    func testHistoricalDiffUsesTheSharedEditorWithoutWorkingTreeMutations() async throws {
        let fixture = GitReviewFixture()
        await fixture.useFiles([])
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let page = try await model.history()
        let commit = try XCTUnwrap(page.commits.first)
        let details = try await model.commitDetails(commit)
        let overview = try await render(NavigationStack { GitCommitScreen(model: model, commit: commit) },
                                        stores: stores, name: "mindwire-commit-detail")
        overview.isHidden = true
        let window = try await render(NavigationStack {
            GitDiffScreen(model: model, change: details.files[0], staged: true, commit: commit)
        }, stores: stores, name: "mindwire-commit-diff")
        defer { window.isHidden = true }
        let host = try XCTUnwrap(window.rootViewController)
        let editor = try XCTUnwrap(findEditor(in: host.view))
        XCTAssertTrue(editor.text.contains("historicalCode()"))
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertFalse(text.contains(t("git.unstage")), text)
        XCTAssertFalse(text.contains(t("git.discard")), text)
        await model.refresh()
        try await Task.sleep(for: .milliseconds(100))
        let reads = await fixture.historicalReads
        let workingReads = await fixture.diffReads
        XCTAssertEqual(reads, 1, "An immutable commit diff must not reload when working-tree status changes")
        XCTAssertTrue(workingReads.isEmpty)
        await model.dispose()
    }

    func testHistoryNavigationOpensCommitFilesAndTheirNativeDiff() async throws {
        let fixture = GitReviewFixture()
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let presentation = GitHistoryPresentation()
        let window = try await render(NavigationStack(path: Binding(
            get: { presentation.path }, set: { presentation.path = $0 }
        )) {
            GitHistoryScreen(model: model)
                .navigationDestination(for: GitCommit.self) { GitCommitScreen(model: model, commit: $0) }
                .navigationDestination(for: GitDiffRoute.self) { route in
                    GitDiffScreen(model: model, change: route.change, staged: route.staged, commit: route.commit)
                }
        }, stores: stores, name: "mindwire-commit-history")
        defer { window.isHidden = true }
        let host = try XCTUnwrap(window.rootViewController)
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(text.contains("Improve native review"), text)
        let page = try await model.history()
        let commit = try XCTUnwrap(page.commits.first)
        presentation.path.append(commit)
        try await Task.sleep(for: .milliseconds(400))
        let detailText = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(detailText.contains("Composer.swift"), detailText)
        presentation.path.append(GitDiffRoute(change: GitReviewFixture.mixed, staged: true, commit: commit))
        for _ in 0..<150 {
            if findEditor(in: host.view)?.text.contains("historicalCode()") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let editor = try XCTUnwrap(findEditor(in: host.view))
        XCTAssertTrue(editor.text.contains("historicalCode()"))
        await model.dispose()
    }

    func testFailedMutationsNeverReportSuccessToTheReviewScreen() async throws {
        let fixture = GitReviewFixture()
        let (model, _) = try makeModel(fixture)
        await model.load()
        await fixture.setFailure(true)
        let staged = await model.stage(["Composer.swift"])
        let unstaged = await model.unstage(["Composer.swift"])
        let discarded = await model.discard(["Composer.swift"])
        XCTAssertFalse(staged)
        XCTAssertFalse(unstaged)
        XCTAssertFalse(discarded)
        XCTAssertEqual(model.error, "Fixture write failed")
        XCTAssertFalse(model.isMutating)
        XCTAssertFalse(model.isClean, "Failed actions must leave the changes available for review")
        await fixture.setFailure(false)
        let retried = await model.stage(["Composer.swift"])
        XCTAssertTrue(retried)
        XCTAssertNil(model.error)
        await model.dispose()
    }

    func testRepeatedActionWhileWaitingDoesNotSubmitAnotherWrite() async throws {
        let fixture = GitReviewFixture()
        let (model, _) = try makeModel(fixture)
        await model.load()
        await fixture.holdWrite()
        let first = Task { await model.stage(["Composer.swift"]) }
        for _ in 0..<100 {
            if await fixture.waiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.isMutating)
        let duplicate = await model.unstage(["Composer.swift"])
        XCTAssertFalse(duplicate)
        let writes = await fixture.writes
        XCTAssertEqual(writes, [.stage])
        await fixture.releaseWrite()
        let accepted = await first.value
        XCTAssertTrue(accepted)
        await model.dispose()
    }

    func testRefreshingAfterReadFailureRestoresTheRepository() async throws {
        let fixture = GitReviewFixture()
        await fixture.failStatus(true)
        let (model, _) = try makeModel(fixture)
        await model.load()
        XCTAssertNil(model.status)
        XCTAssertNotNil(model.error)
        await fixture.failStatus(false)
        await model.refresh()
        XCTAssertTrue(model.isRepo)
        XCTAssertNil(model.error)
        let revision = model.revision
        await model.refresh()
        XCTAssertGreaterThan(model.revision, revision, "Same line counts can still contain new code")
        await model.dispose()
    }

    func testChangeNavigationPreservesSourceHeadersAndUnicodeOffsets() throws {
        let patch = """
        diff --git a/greeting.swift b/greeting.swift
        --- a/greeting.swift
        +++ b/greeting.swift
        @@ -120,3 +120,3 @@
         let emoji = "👋"
        -oldGreeting("مرحبا")
        +newGreeting("مرحبا")
         keep()
        @@ -240 +240 @@
        -oldFooter()
        +newFooter()
        """
        let lines = DiffParser.parsePatch(patch)
        let document = DiffParser.inlineDiff(lines)
        XCTAssertTrue(document.text.contains("@@ -120,3 +120,3 @@"))
        XCTAssertTrue(document.text.contains("@@ -240 +240 @@"))
        XCTAssertEqual(document.changes.count, 2)
        let text = document.text as NSString
        XCTAssertEqual(text.substring(with: document.changes[0]), "oldGreeting(\"مرحبا\")\nnewGreeting(\"مرحبا\")\n")
        XCTAssertEqual(text.substring(with: document.changes[1]), "oldFooter()\nnewFooter()")
        let full = DiffParser.inlineDiff(lines, showsHunkHeaders: false)
        XCTAssertFalse(full.text.contains("@@"))
        XCTAssertTrue(full.text.contains("👋"))
        XCTAssertEqual(full.changes.count, 2)
        XCTAssertEqual((full.text as NSString).substring(with: full.changes[1]), "oldFooter()\nnewFooter()")
    }

    func testPreviewKeepsBinaryAndTruncationInformation() async throws {
        let fixture = GitReviewFixture()
        let (model, _) = try makeModel(fixture)
        await model.load()
        let change = GitFileChange(path: "new.swift", kind: "untracked", index: ".", worktree: "?")
        await fixture.setBlob(.init(path: change.path, rev: "WORKTREE", truncated: true, content: "first line\n"))
        let partial = try await DiffParser.lines(model: model, change: change, staged: false)
        XCTAssertTrue(partial.truncated)
        XCTAssertEqual(partial.lines.count, 1)
        await fixture.setBlob(.init(path: change.path, rev: "WORKTREE", binary: true))
        let binary = try await DiffParser.lines(model: model, change: change, staged: false)
        XCTAssertTrue(binary.binary)
        XCTAssertTrue(binary.lines.isEmpty)
        let old = try JSONDecoder().decode(GitDiff.self, from: Data(#"{"path":"x","staged":false,"binary":false,"additions":0,"deletions":0,"patch":""}"#.utf8))
        XCTAssertNil(old.truncated)
        await model.dispose()
    }

    func testSelectedDiffDraftPreservesUnicodeChangeSidesAndCodeFences() throws {
        let lines = DiffParser.parsePatch("""
        @@ -10,3 +10,3 @@
         let emoji = "👋"
        -oldGreeting("مرحبا")
        +newGreeting("مرحبا")
         keep()
        """)
        let document = DiffParser.inlineDiff(lines)
        let selected = try XCTUnwrap(DiffParser.selectedPatch(
            in: document.text, tints: document.tints, range: document.changes[0]))
        XCTAssertEqual(selected, "-oldGreeting(\"مرحبا\")\n+newGreeting(\"مرحبا\")\n")
        let payload = SendToAgentPayload(path: "/project/greeting.swift", code: selected,
                                         context: "Working Changes", format: "diff")
        XCTAssertTrue(payload.draft.contains("/project/greeting.swift\nWorking Changes\n```diff\n-"))
        XCTAssertTrue(payload.draft.contains("+newGreeting"))
        let markdown = SendToAgentPayload(path: "/project/README.md", code: "```swift\nlet x = 1\n```", format: "markdown")
        XCTAssertTrue(markdown.draft.contains("````markdown\n```swift"))
        XCTAssertTrue(markdown.draft.hasSuffix("```\n````\n\n"))
        XCTAssertNil(DiffParser.selectedPatch(in: document.text, tints: document.tints,
                                              range: NSRange(location: NSNotFound, length: 0)))
    }

    func testDiffSelectionCreatesOneAgentDraftAndCanRetryAfterFailure() async throws {
        let fixture = GitReviewFixture()
        let registry = WorkspaceRemoteFixture()
        let (model, stores) = try makeModel(fixture, registry: registry)
        await model.load()
        var opened: ChatDraftRoute?
        let window = try await render(NavigationStack {
            GitDiffScreen(model: model, change: GitReviewFixture.mixed, staged: false) { chatId, draft in
                opened = ChatDraftRoute(chatId: chatId, draft: draft)
            }
        }, stores: stores, name: "mindwire-source-control-actions")
        defer { window.isHidden = true }
        let host = try XCTUnwrap(window.rootViewController)
        let before = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(before.contains(t("git.discard")), before)
        let editor = try XCTUnwrap(findEditor(in: host.view))
        let range = (editor.text as NSString).range(of: "        await agent.send(message)\n        let draft = message")
        XCTAssertNotEqual(range.location, NSNotFound)
        editor.selectedRange = range
        try await Task.sleep(for: .milliseconds(200))
        let selectedImage = ChatFeedSnapshot.image(host)
        let selectionText = try ChatFeedSnapshot.visibleText(in: selectedImage)
        XCTAssertTrue(selectionText.contains(t("editor.sendToAgent")), selectionText)
        let attachment = XCTAttachment(image: selectedImage)
        attachment.name = "Selected diff exposes Send to Agent"; attachment.lifetime = .keepAlways; add(attachment)
        try selectedImage.pngData()?.write(to: URL(fileURLWithPath: "/tmp/mindwire-source-control-selection.png"))
        XCTAssertTrue(stores.chats.list().isEmpty, "Selecting code must not create a chat")
        let action = CodeSelectionAgentModel()
        let agent = try XCTUnwrap(stores.agents.get("codex"))
        let document = DiffParser.inlineDiff(try await DiffParser.lines(
            model: model, change: GitReviewFixture.mixed, staged: false).lines)
        let selected = try XCTUnwrap(DiffParser.selectedPatch(in: document.text, tints: document.tints, range: range))
        let payload = SendToAgentPayload(path: "/projects/mindwire/Sources/Chat/Composer.swift", code: selected,
                                         context: t("git.changes"), format: "diff")
        var callbacks = 0
        let onReady: (ChatDraftRoute) -> Void = { opened = $0; callbacks += 1 }
        registry.onPut = { _, _, _, _ in throw BackendError.message("Fixture offline") }
        action.select(agent, projectId: "project", selection: payload, repository: stores.workspaceData, onReady: onReady)
        for _ in 0..<100 {
            if !action.actions.running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(opened, "A failed chat creation must keep the selection available for retry")
        XCTAssertEqual(action.actions.error, "Fixture offline")
        XCTAssertFalse(action.isBusy)
        XCTAssertTrue(stores.chats.list().isEmpty)
        registry.onPut = { kind, _, payload, _ in
            XCTAssertEqual(kind, "chats")
            var chat = try JSONDecoder().decode(Chat.self, from: payload)
            chat.revision = 2
            registry.current = WorkspaceMetadata(version: 1, workspaceId: "database", revision: 2, full: true,
                agents: registry.current.agents, projects: registry.current.projects, chats: [chat], deleted: [])
            return registry.current
        }
        action.select(agent, projectId: "project", selection: payload, repository: stores.workspaceData, onReady: onReady)
        action.select(agent, projectId: "project", selection: payload, repository: stores.workspaceData, onReady: onReady)
        for _ in 0..<100 {
            if opened != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let route = try XCTUnwrap(opened)
        // A tap during dismissal must not create a second chat after the first request finishes.
        action.select(agent, projectId: "project", selection: payload, repository: stores.workspaceData, onReady: onReady)
        XCTAssertEqual(registry.putIDs.count, 2, "Only the initial failed write and its explicit retry reach the daemon")
        XCTAssertEqual(Set(registry.putIDs).count, 1, "Retry retains the original chat identity")
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(stores.chats.list().count, 1)
        XCTAssertEqual(stores.chats.get(route.chatId)?.agentId, "codex")
        XCTAssertEqual(stores.chats.get(route.chatId)?.projectId, "project")
        XCTAssertTrue(route.draft.contains("/projects/mindwire/Sources/Chat/Composer.swift"))
        XCTAssertTrue(route.draft.contains("-        await agent.send(message)\n+        let draft = message"))
        XCTAssertTrue(route.draft.contains("```diff"))
        XCTAssertNil(action.actions.error)
        await model.dispose()
    }

    func testStagedReviewExposesUnstageWithoutDiscardingWorkingChanges() async throws {
        let fixture = GitReviewFixture()
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let window = try await render(NavigationStack {
            GitDiffScreen(model: model, change: GitReviewFixture.mixed, staged: true)
        }, stores: stores, name: "mindwire-source-control-unstage")
        defer { window.isHidden = true }
        let host = try XCTUnwrap(window.rootViewController)
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(text.contains(t("git.unstage")), text)
        XCTAssertFalse(text.contains(t("git.discard")), text)
        let reads = await fixture.diffReads
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.first?.staged, true, "The action label and diff must refer to the same side of the file")
        await model.dispose()
    }

    func testFileListDefersDiffReadsAndReviewLoadsBothSidesOfAFile() async throws {
        let fixture = GitReviewFixture()
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let list = try await render(SourceControlScreen(workspaceId: "fixture", model: model),
                                    stores: stores, name: "mindwire-source-control-files")
        let before = await fixture.diffReads
        XCTAssertTrue(before.isEmpty, "Browsing filenames must not fetch every patch")
        list.isHidden = true
        await fixture.useFiles([GitReviewFixture.mixed])
        await model.refresh()
        let review = try await render(SourceControlScreen(workspaceId: "fixture", model: model, mode: .review),
                                      stores: stores, name: "mindwire-source-control-review")
        defer { review.isHidden = true }
        let reads = await fixture.diffReads
        XCTAssertTrue(reads.contains { $0.path == GitReviewFixture.mixed.path && $0.staged })
        XCTAssertTrue(reads.contains { $0.path == GitReviewFixture.mixed.path && !$0.staged },
                      "Review must retain working changes when the same file also has staged edits")
        review.isHidden = true
        let lightReview = try await render(SourceControlScreen(workspaceId: "fixture", model: model, mode: .review),
            stores: stores, name: "mindwire-source-control-review-light", scheme: .light)
        lightReview.isHidden = true
    }

    func testStagingProgressKeepsFileRowsAndScrollPositionUntilCompletion() async throws {
        let fixture = GitReviewFixture()
        let files = (1...16).map {
            GitFileChange(path: "Sources/File\($0).swift", kind: "modified", index: ".", worktree: "M",
                          unstaged: .init(additions: 8, deletions: 2))
        }
        await fixture.useFiles(files)
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let window = try await render(SourceControlScreen(workspaceId: "fixture", model: model),
            stores: stores, name: "mindwire-inline-stage-list")
        defer { window.isHidden = true }
        func collection(in view: UIView) -> UICollectionView? {
            if let list = view as? UICollectionView { return list }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        let list = try XCTUnwrap(collection(in: window))
        list.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
        try await Task.sleep(for: .milliseconds(200))
        list.layoutIfNeeded()
        let offset = list.contentOffset.y
        let anchor = try XCTUnwrap(list.indexPathsForVisibleItems.sorted().first)
        let before = try XCTUnwrap(list.layoutAttributesForItem(at: anchor)).frame
        _ = try reviewSnapshot(window, name: "mindwire-inline-stage-before")
        await fixture.holdWrite()
        defer { Task { await fixture.releaseWrite() } }
        let selected = files[6]
        let write = Task { await model.stage([selected.path]) }
        for _ in 0..<100 {
            if await fixture.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isMutating)
        XCTAssertEqual(model.fileAction(path: selected.path, staged: false), .stage)
        XCTAssertNil(model.fileAction(path: selected.path, staged: true))
        XCTAssertNil(model.fileAction(path: files[0].path, staged: false))
        XCTAssertEqual(model.unstaged, files, "Keep the file in place until the write is confirmed")
        XCTAssertTrue(model.staged.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        list.layoutIfNeeded()
        let during = try XCTUnwrap(list.layoutAttributesForItem(at: anchor)).frame
        XCTAssertEqual(list.contentOffset.y, offset, accuracy: 1)
        XCTAssertEqual(during.minY, before.minY, accuracy: 1, "Progress must not insert a section above the files")
        XCTAssertEqual(during.height, before.height, accuracy: 1)
        _ = try reviewSnapshot(window, name: "mindwire-inline-stage-pending")
        await fixture.releaseWrite()
        let succeeded = await write.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.staged.map(\.path), [selected.path])
        XCTAssertFalse(model.unstaged.contains { $0.path == selected.path })
        XCTAssertNil(model.activeAction)
        XCTAssertNil(model.remoteOutput, "A completed stage must not insert a command-output section")
        XCTAssertNil(model.operationNotice)
        list.setContentOffset(.zero, animated: false)
        try await Task.sleep(for: .milliseconds(200))
        _ = try reviewSnapshot(window, name: "mindwire-inline-stage-complete")
        await model.dispose()
    }

    func testStagingRetainsUnrelatedCachedDiffsAndManualRefreshRevalidatesThem() async throws {
        let fixture = GitReviewFixture()
        let files = ["Changed.swift", "Unchanged.swift"].map {
            GitFileChange(path: $0, kind: "modified", index: ".", worktree: "M", unstaged: .init(additions: 2))
        }
        await fixture.useFiles(files)
        let (model, _) = try makeModel(fixture)
        await model.load()
        for file in files {
            await model.preview(path: file.path, staged: false).load(model: model,
                request: .init(change: file, staged: false, revision: model.diffRevision(path: file.path)))
        }
        let unrelatedRevision = model.diffRevision(path: files[1].path)
        let succeeded = await model.stage([files[0].path])
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.diffRevision(path: files[1].path), unrelatedRevision)
        XCTAssertNotEqual(model.diffRevision(path: files[0].path), unrelatedRevision)
        await model.preview(path: files[1].path, staged: false).load(model: model,
            request: .init(change: files[1], staged: false, revision: model.diffRevision(path: files[1].path)))
        let staged = try XCTUnwrap(model.staged.first)
        await model.preview(path: staged.path, staged: true).load(model: model,
            request: .init(change: staged, staged: true, revision: model.diffRevision(path: staged.path)))
        let reads = await fixture.diffReads
        XCTAssertEqual(reads.filter { $0.path == files[1].path }.count, 1)
        XCTAssertEqual(reads.filter { $0.path == files[0].path && $0.staged }.count, 1)
        await model.refresh()
        await model.preview(path: files[1].path, staged: false).load(model: model,
            request: .init(change: files[1], staged: false, revision: model.diffRevision(path: files[1].path)))
        let refreshed = await fixture.diffReads
        XCTAssertEqual(refreshed.filter { $0.path == files[1].path }.count, 2,
            "Explicit refresh must still detect external edits even when line counts stay the same")
        await model.dispose()
    }

    func testRepositoryMenuStaysVisibleAcrossStatusRefreshes() async throws {
        let fixture = GitReviewFixture()
        let (model, stores) = try makeModel(fixture, registry: WorkspaceRemoteFixture())
        await model.load()
        let window = try await render(SourceControlScreen(workspaceId: "fixture", model: model),
                                      stores: stores, name: "mindwire-repository-menu-closed")
        defer { window.isHidden = true }
        let host = try XCTUnwrap(window.rootViewController)
        let button = try AgentManagementTestUI.button(in: host)
        button.performPrimaryAction()
        let interaction = try XCTUnwrap(button.contextMenuInteraction)
        defer { interaction.dismissMenu() }
        try await Task.sleep(for: .milliseconds(700))
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let scene = try XCTUnwrap(window.windowScene)
        func refreshLabel() throws -> UILabel {
            try XCTUnwrap(scene.windows.filter { !$0.isHidden }.flatMap(descendants)
                .compactMap { $0 as? UILabel }.first { $0.text == t("git.refresh") })
        }
        let label = try refreshLabel()
        for step in 0..<3 {
            if step == 1 {
                await fixture.useFiles([GitReviewFixture.mixed])
            }
            await model.refresh()
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertTrue(try refreshLabel() === label, "Unchanged actions must not rebuild and fade the open menu")
                XCTAssertNotNil(label.window)
                XCTAssertEqual(label.layer.presentation()?.opacity ?? label.layer.opacity, 1, accuracy: 0.01)
                XCTAssertTrue(try AgentManagementTestUI.button(in: host) === button)
            }
        }
        try reviewSnapshot(window, name: "mindwire-repository-menu-stable")
        await model.dispose()
    }

    func testCodeReviewStartsCompactAndReloadsAfterStatusRefresh() async throws {
        let fixture = GitReviewFixture()
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let window = try await render(NavigationStack {
            GitDiffScreen(model: model, change: GitReviewFixture.mixed, staged: false)
        }, stores: stores, name: "mindwire-source-control-diff")
        defer { window.isHidden = true }
        let initial = await fixture.diffReads
        XCTAssertEqual(initial.count, 1)
        XCTAssertNil(initial.first?.context, "Opening review must not request an entire large file")
        await model.refresh()
        try await Task.sleep(for: .milliseconds(250))
        let refreshed = await fixture.diffReads
        XCTAssertEqual(refreshed.count, 2)
        window.isHidden = true
        let lightDiff = try await render(NavigationStack {
            GitDiffScreen(model: model, change: GitReviewFixture.mixed, staged: false)
        }, stores: stores, name: "mindwire-source-control-diff-light", scheme: .light)
        lightDiff.isHidden = true
    }

    func testIdleOperationRecoveryAndConcurrentRefreshReadStatusOnce() async throws {
        let fixture = GitReviewFixture()
        let (model, _) = try makeModel(fixture, registry: WorkspaceRemoteFixture())
        await model.load()
        let initialReads = await fixture.statusReads
        XCTAssertEqual(initialReads, 1, "Recovering an idle project must not immediately invalidate an opened diff")
        let revision = model.revision
        await fixture.holdStatusReads()
        let first = Task { await model.refresh() }
        let second = Task { await model.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        let reads = await fixture.statusReads
        XCTAssertEqual(reads, 2, "Overlapping refreshes share the same status request")
        await fixture.releaseStatusReads()
        await first.value
        await second.value
        XCTAssertEqual(model.revision, revision + 1)
        await model.dispose()
    }

    func testIdleRecoveryKeepsControlsStableAndSerializesARequestedWrite() async throws {
        let fixture = GitReviewFixture()
        let channel = GitOperationsChannel()
        let registry = WorkspaceRemoteFixture()
        registry.gitOperationsProvider = { _ in DaemonHTTP(channel: channel, agentType: "") }
        let (model, _) = try makeModel(fixture, registry: registry)
        await model.load()
        await channel.holdRecoveryRead()
        let refresh = Task { await model.refresh() }
        for _ in 0..<100 {
            if await channel.waitingForRecovery { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await channel.waitingForRecovery
        XCTAssertTrue(waiting)
        XCTAssertFalse(model.isMutating, "An idle recovery read must not dim or rebuild menu actions")
        XCTAssertNil(model.activeAction)
        let write = Task { await model.stage([GitReviewFixture.mixed.path]) }
        let duplicate = Task { await model.stage([GitReviewFixture.mixed.path]) }
        try await Task.sleep(for: .milliseconds(100))
        let before = await channel.posts
        XCTAssertTrue(before.isEmpty, "User actions must wait for recovery before submitting")
        await channel.releaseRecoveryRead()
        await refresh.value
        let accepted = await [write.value, duplicate.value]
        XCTAssertEqual(accepted.filter { $0 }.count, 1)
        let executions = await channel.executions
        XCTAssertEqual(executions, 1)
        XCTAssertFalse(model.isMutating)
        await model.refresh()
        XCTAssertNil(model.activeAction, "Re-reading a completed operation must not present it as running")

        await channel.reconnect(status: "running")
        let resumed = Task { await model.refresh() }
        for _ in 0..<100 {
            if model.isMutating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isMutating, "A real remote operation must still lock conflicting actions")
        XCTAssertEqual(model.activeAction, .stage)
        let overlapping = await model.stage([GitReviewFixture.mixed.path])
        XCTAssertFalse(overlapping)
        await channel.reconnect(status: "succeeded")
        await resumed.value
        XCTAssertFalse(model.isMutating)
        await model.dispose()
    }

    func testAuthorSaveWaitsForIdleRecoveryWithoutCommitting() async throws {
        let fixture = GitReviewFixture()
        let channel = GitOperationsChannel()
        let registry = WorkspaceRemoteFixture()
        registry.gitOperationsProvider = { _ in DaemonHTTP(channel: channel, agentType: "") }
        let (model, _) = try makeModel(fixture, registry: registry,
                                      authorRemote: { GitReviewAuthorRemote(fixture: fixture) })
        await model.load()
        await channel.holdRecoveryRead()
        let refresh = Task { await model.refresh() }
        for _ in 0..<100 {
            if await channel.waitingForRecovery { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await channel.waitingForRecovery
        XCTAssertTrue(waiting)
        let author = GitIdentity(name: "Chosen User", email: "chosen@example.invalid")
        let save = Task { await model.saveAuthor(author, scope: .repository) }
        try await Task.sleep(for: .milliseconds(100))
        let before = try await fixture.identity()
        XCTAssertEqual(before.name, "Fixture User", "Author changes must wait for the pending operation check")
        await channel.releaseRecoveryRead()
        await refresh.value
        let saved = await save.value
        XCTAssertTrue(saved)
        let after = try await fixture.identity()
        XCTAssertEqual(after, author)
        let writes = await channel.posts
        XCTAssertTrue(writes.isEmpty, "Saving an author must not submit a Git operation")
        XCTAssertFalse(model.isMutating)
        await model.dispose()
    }

    func testCancelledChildRequestsNeverBecomeGitActionErrorsOrRetryWrites() async throws {
        let cancellations: [any Error] = [CancellationError(), URLError(.cancelled)]
        for cancellation in cancellations {
            let fixture = GitReviewFixture()
            let (model, _) = try makeModel(fixture)
            await fixture.setStatusError(cancellation)
            await model.load()
            XCTAssertNil(model.error)
            XCTAssertFalse(model.loading)
            await fixture.setStatusError(nil)
            await model.load()
            XCTAssertTrue(model.isRepo)
            let revision = model.revision
            await fixture.setStatusError(cancellation)
            await model.refresh()
            XCTAssertNil(model.error)
            XCTAssertEqual(model.revision, revision)
            XCTAssertFalse(model.allChanges.isEmpty, "Cancelling a read retains the last complete file list")
            await fixture.setStatusError(nil)
            await fixture.setWriteError(cancellation)
            let succeeded = await model.stage([GitReviewFixture.mixed.path])
            XCTAssertFalse(succeeded)
            XCTAssertNil(model.error)
            let writes = await fixture.writes
            XCTAssertEqual(writes, [.stage], "A cancelled write must never be resubmitted automatically")
            await model.dispose()
        }
    }

    func testMutationReconcilesWithAReadStartedAfterTheWrite() async throws {
        let fixture = GitReviewFixture()
        let (model, _) = try makeModel(fixture)
        await model.load()
        await fixture.holdStatusReads()
        let refreshing = Task { await model.refresh() }
        for _ in 0..<100 {
            if await fixture.statusReads == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let writing = Task { await model.unstage([GitReviewFixture.mixed.path]) }
        for _ in 0..<100 {
            if await fixture.statusReads == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let reads = await fixture.statusReads
        XCTAssertEqual(reads, 3, "A completed mutation must not reuse a snapshot taken before the write")
        await fixture.releaseStatusReads()
        await refreshing.value
        let succeeded = await writing.value
        XCTAssertTrue(succeeded)
        XCTAssertFalse(model.staged.contains { $0.path == GitReviewFixture.mixed.path })
        XCTAssertNil(model.error)
        await model.dispose()
    }

    func testDiffRefreshKeepsEditorViewportAndSelectionUntilNewContentArrives() async throws {
        let fixture = GitReviewFixture()
        let patch = "@@ -1,160 +1,160 @@\n-oldValue\n+newValue\n"
            + (1...159).map { " let line\($0) = \($0)" }.joined(separator: "\n") + "\n"
        await fixture.setPatch(patch)
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let window = try await render(NavigationStack {
            GitDiffScreen(model: model, change: GitReviewFixture.mixed, staged: false)
        }, stores: stores, name: "mindwire-diff-preserved-before-refresh")
        defer { window.isHidden = true }
        let editor = try XCTUnwrap(findEditor(in: window))
        let selection = (editor.text as NSString).range(of: "line40")
        editor.selectedRange = selection
        editor.setContentOffset(CGPoint(x: 0, y: 550), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        let offset = editor.contentOffset
        await fixture.holdDiffReads()
        await model.refresh()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(findEditor(in: window) === editor, "Refresh must not replace the native editor with a spinner")
        XCTAssertEqual(editor.selectedRange, selection)
        XCTAssertEqual(editor.contentOffset.y, offset.y, accuracy: 1)
        await fixture.releaseDiffReads()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(findEditor(in: window) === editor)
        XCTAssertEqual(editor.selectedRange, selection)
        XCTAssertEqual(editor.contentOffset.y, offset.y, accuracy: 1)
        XCTAssertTrue(editor.text.hasSuffix("let line159 = 159"), "The last line must remain available")
        _ = try reviewSnapshot(window, name: "mindwire-diff-preserved-after-refresh")
        await model.dispose()
    }

    func testSupersededOrCancelledDiffReadCannotOverwriteTheCurrentEditor() async throws {
        let fixture = GitReviewFixture()
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let window = try await render(NavigationStack {
            GitDiffScreen(model: model, change: GitReviewFixture.mixed, staged: false)
        }, stores: stores, name: "mindwire-diff-latest-request")
        defer { window.isHidden = true }
        let editor = try XCTUnwrap(findEditor(in: window))
        await fixture.holdDiffReads()
        await fixture.setPatch("@@ -1 +1 @@\n-old\n+obsoleteRead\n")
        await model.refresh()
        for _ in 0..<100 {
            if await fixture.diffReads.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await fixture.setPatch("@@ -1 +1 @@\n-old\n+currentRead\n")
        await model.refresh()
        for _ in 0..<100 {
            if await fixture.diffReads.count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await fixture.releaseDiffReads()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(findEditor(in: window) === editor)
        XCTAssertTrue(editor.text.contains("currentRead"))
        XCTAssertFalse(editor.text.contains("obsoleteRead"))
        await fixture.setDiffError(CancellationError())
        await model.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(findEditor(in: window) === editor)
        XCTAssertTrue(editor.text.contains("currentRead"))
        await fixture.setDiffError(BackendError.message("The computer disconnected"))
        await model.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(findEditor(in: window) === editor, "A refresh failure must preserve the last complete diff")
        let visible = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(window.rootViewController)))
        XCTAssertTrue(visible.contains("computer disconnected"), visible)
        XCTAssertFalse(visible.contains("CancellationError"), visible)
        await model.dispose()
    }

    func testReturningToAnOpenedFileRetainsItsBufferWithoutReadingAgain() async throws {
        let file = OpenedFileFixture()
        let workspace = SelfHostedWorkspaceService { try await file.execute($0) }
        let (_, stores) = try makeModel(GitReviewFixture())
        let navigation = GitHistoryPresentation()
        let window = try await render(NavigationStack(path: Binding(
            get: { navigation.path }, set: { navigation.path = $0 }
        )) {
            FileEditorScreen(workspace: workspace, path: "/project/File.swift")
                .navigationDestination(for: Int.self) { _ in Text("Another project tool") }
        }, stores: stores, name: "mindwire-file-retained-on-return")
        defer { window.isHidden = true }
        let editor = try XCTUnwrap(findEditor(in: window))
        editor.isEditable = true
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.insertText("// Unsaved local edit\n")
        let edited = editor.text
        XCTAssertTrue(edited.contains("Unsaved local edit"))
        navigation.path.append(1)
        try await Task.sleep(for: .milliseconds(350))
        navigation.path.removeLast()
        try await Task.sleep(for: .milliseconds(350))
        let returned = try XCTUnwrap(findEditor(in: window))
        XCTAssertEqual(returned.text, edited)
        let reads = await file.reads
        XCTAssertEqual(reads, 1, "Returning to an open editor must not re-read and replace the buffer")
    }

    func testPresentationResourcesSurviveNavigationAndReleaseOnlyWhenRemoved() async throws {
        let (_, stores) = try makeModel(GitReviewFixture())
        let lifetime = GitToolLifetimeState()
        let window = try await render(GitToolLifetimeHost(lifetime: lifetime), stores: stores,
                                      name: "mindwire-tool-lifetime")
        defer { window.isHidden = true }
        lifetime.path.append(1)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(lifetime.closes, 0)
        lifetime.path.removeLast()
        lifetime.covered = true
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(lifetime.closes, 0)
        lifetime.covered = false
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(lifetime.closes, 0)
        lifetime.presented = false
        for _ in 0..<100 {
            if lifetime.closes == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(lifetime.closes, 1, "Connections must be released exactly once with the owning presentation")
    }

    func testCancelledFileReadNeverOpensAnEmptyEditableFile() async throws {
        let workspace = SelfHostedWorkspaceService { _ in throw CancellationError() }
        let (_, stores) = try makeModel(GitReviewFixture())
        let window = try await render(NavigationStack {
            FileEditorScreen(workspace: workspace, path: "/project/config.swift", createIfMissing: true)
        }, stores: stores, name: "mindwire-cancelled-file-read")
        defer { window.isHidden = true }
        XCTAssertNil(findEditor(in: window), "A cancelled connection is not evidence of a missing file")
        let visible = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(window.rootViewController)))
        XCTAssertTrue(visible.contains(t("common.retry")), visible)
        XCTAssertFalse(visible.contains("CancellationError"), visible)
    }

    func testDelayedPreviewsKeepScrollPositionAndReuseLoadedRows() async throws {
        let fixture = GitReviewFixture()
        let files = (1...24).map {
            GitFileChange(path: "Sources/File\($0).swift", kind: "modified", index: ".", worktree: "M",
                          unstaged: .init(additions: 8, deletions: 2))
        }
        await fixture.useFiles(files)
        await fixture.holdDiffReads()
        defer { Task { await fixture.releaseDiffReads() } }
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let window = try await render(SourceControlScreen(workspaceId: "fixture", model: model, mode: .review),
                                      stores: stores, name: "mindwire-review-stable-loading")
        defer { window.isHidden = true }
        func collection(in view: UIView) -> UICollectionView? {
            if let view = view as? UICollectionView { return view }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        let list = try XCTUnwrap(collection(in: window))
        list.setContentOffset(CGPoint(x: 0, y: 850), animated: false)
        try await Task.sleep(for: .milliseconds(200))
        list.layoutIfNeeded()
        let offset = list.contentOffset.y
        let anchor = try XCTUnwrap(list.indexPathsForVisibleItems.sorted().first)
        let before = try XCTUnwrap(list.layoutAttributesForItem(at: anchor)).frame
        let initialReads = await fixture.diffReads
        XCTAssertLessThan(initialReads.count, files.count, "Review must still load only nearby rows")
        await fixture.releaseDiffReads()
        try await Task.sleep(for: .milliseconds(400))
        list.layoutIfNeeded()
        let after = try XCTUnwrap(list.layoutAttributesForItem(at: anchor)).frame
        XCTAssertEqual(list.contentOffset.y, offset, accuracy: 1, "Completing previews must not jump the scroll")
        XCTAssertEqual(after.minY - list.contentOffset.y, before.minY - offset, accuracy: 1)
        XCTAssertEqual(after.height, before.height, accuracy: 1, "Loading must not resize a review row")
        _ = try reviewSnapshot(window, name: "mindwire-review-stable-loaded")
        list.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        list.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        try await Task.sleep(for: .milliseconds(200))
        let reads = await fixture.diffReads
        XCTAssertTrue(Dictionary(grouping: reads, by: \.path).values.allSatisfy { $0.count == 1 },
                      "Recycled rows must reuse their completed diff")
        let cached = model.preview(path: files[0].path, staged: false)
        XCTAssertTrue(cached.hasResult)
        let oldLines = cached.lines
        await fixture.holdDiffReads()
        await model.refresh()
        let revalidation = Task {
            await cached.load(model: model, request: .init(change: files[0], staged: false, revision: model.revision))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(cached.lines, oldLines, "Refresh keeps the previous excerpt visible until replacement arrives")
        await fixture.releaseDiffReads()
        await revalidation.value
        await model.dispose()
    }

    func testBranchSelectionAndCreationRefreshTheCurrentBranch() async throws {
        let fixture = GitReviewFixture()
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let window = try await render(GitBranchSheet(model: model), stores: stores, name: "mindwire-branches")
        defer { window.isHidden = true }
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(window.rootViewController)))
        XCTAssertTrue(text.contains("main"), text)
        XCTAssertTrue(text.contains("origin/release"), text)
        let creation = try await render(NavigationStack { GitCreateBranchScreen(model: model, onCreated: {}) },
                                        stores: stores, name: "mindwire-create-branch")
        let form = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(creation.rootViewController)))
        XCTAssertTrue(form.lowercased().contains("create from"), form)
        creation.isHidden = true
        let initialFiles = model.allChanges
        let switched = await model.switchBranch(.init(name: "main"))
        XCTAssertTrue(switched)
        XCTAssertEqual(model.status?.branch, "main")
        let created = await model.createBranch("feature/native-review")
        XCTAssertTrue(created)
        XCTAssertEqual(model.status?.branch, "feature/native-review")
        XCTAssertEqual(model.allChanges, initialFiles)
        await fixture.setFailure(true)
        let failed = await model.switchBranch(.init(name: "main"))
        XCTAssertFalse(failed)
        XCTAssertEqual(model.status?.branch, "feature/native-review")
        await model.dispose()
    }

    func testOldDaemonCannotBypassTheOperationLockForBranchChanges() async throws {
        let fixture = GitReviewFixture()
        let (model, _) = try makeModel(fixture, registry: WorkspaceRemoteFixture())
        await model.load()
        let created = await model.createBranch("feature/update-required")
        XCTAssertFalse(created)
        XCTAssertEqual(model.error, t("git.branches.updateRequired"))
        let branch = GitBranch(name: "feature/review", tip: String(repeating: "a", count: 40))
        let renamed = await model.renameBranch(branch, to: "feature/ready")
        XCTAssertFalse(renamed)
        XCTAssertEqual(model.error, t("git.branches.manage.updateRequired"))
        let deleted = await model.deleteBranch(branch, force: true)
        XCTAssertFalse(deleted)
        XCTAssertEqual(model.error, t("git.branches.manage.updateRequired"))
        let writes = await fixture.writes
        XCTAssertTrue(writes.isEmpty, "A missing branch capability must not fall back to an uncoordinated write")
        await model.dispose()
    }

    func testBranchManagementUsesTheConfirmedTipAndVersionedDaemonOperations() async throws {
        let fixture = GitReviewFixture(), channel = GitOperationsChannel(), registry = WorkspaceRemoteFixture()
        var versions: [Int] = []
        registry.gitOperationsProvider = { minimum in
            versions.append(minimum)
            return DaemonHTTP(channel: channel, agentType: "")
        }
        let (model, _) = try makeModel(fixture, registry: registry)
        await model.load()
        let branch = GitBranch(name: "feature/review", tip: String(repeating: "a", count: 40))
        let renamed = await model.renameBranch(branch, to: " feature/ready ")
        XCTAssertTrue(renamed)
        let deleted = await model.deleteBranch(branch)
        XCTAssertTrue(deleted)
        XCTAssertEqual(Array(versions.suffix(2)), [5, 5])
        let posts = await channel.posts
        let requests = try posts.map { try JSONDecoder().decode(GitOperationRequest.self, from: $0.body) }
        XCTAssertEqual(requests.map(\.action), [.renameBranch, .deleteBranch])
        XCTAssertTrue(requests.allSatisfy { $0.branch == branch.name && $0.expectedTip == branch.tip })
        XCTAssertEqual(requests.first?.newName, "feature/ready")
        XCTAssertFalse(requests.last?.force == true, "A normal deletion must never implicitly force-delete unmerged work")
        let writes = await fixture.writes
        XCTAssertTrue(writes.isEmpty)
        await model.dispose()
    }

    func testReviewFocusMovesWithoutReplacingDiffColorsOrCodeSelection() async throws {
        let fixture = GitReviewFixture()
        let (model, stores) = try makeModel(fixture)
        await model.load()
        let result = try await DiffParser.lines(model: model, change: GitReviewFixture.mixed, staged: false)
        let document = DiffParser.inlineDiff(result.lines)
        let focus = GitReviewFocusFixture()
        let handle = EditorHandle()
        let window = try await render(NavigationStack {
            GitReviewFocusEditor(text: document.text, tints: document.tints, focus: focus, handle: handle)
                .navigationTitle("Review changes").navigationBarTitleDisplayMode(.inline)
        }, stores: stores, name: "mindwire-review-before-focus")
        defer { window.isHidden = true }
        let editor = try XCTUnwrap(handle.textView)
        let colors = editor.highlightedRanges.map(\.color)
        let ids = editor.highlightedRanges.map(\.id)
        let originalSelection = (document.text as NSString).range(of: "let draft = message")
        editor.selectedRange = originalSelection
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(focus.selectedText, "let draft = message")

        for (index, range) in document.changes.enumerated() {
            focus.range = range
            editor.scrollRangeToVisible(NSRange(location: range.location, length: 0))
            try await Task.sleep(for: .milliseconds(100))
            let highlight = try XCTUnwrap(editor.highlightedRanges.last)
            XCTAssertEqual(highlight.id, "review-focus")
            XCTAssertEqual(highlight.range, range)
            XCTAssertEqual(editor.highlightedRanges.dropLast().map(\.id), ids, "Moving focus reuses the existing diff highlights")
            XCTAssertEqual(editor.highlightedRanges.dropLast().map(\.color), colors)
            XCTAssertEqual(editor.selectedRange, originalSelection, "Review navigation must preserve the user's code selection")
            XCTAssertEqual(editor.text, document.text)
            let image = ChatFeedSnapshot.image(try XCTUnwrap(window.rootViewController))
            let attachment = XCTAttachment(image: image)
            attachment.name = "Review highlight at change \(index + 1)"; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/mindwire-review-focus-\(index + 1).png"))
        }

        focus.fontSize = 20
        focus.wrapLines = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.highlightedRanges.last?.range, document.changes.last)
        XCTAssertEqual(editor.selectedRange, originalSelection)
        focus.range = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(editor.highlightedRanges.contains { $0.id == "review-focus" })
        XCTAssertEqual(editor.highlightedRanges.count, colors.count)
        await model.dispose()
    }

    func testFirstPresentedReviewKeepsActionsTogetherAndBoundaryLinesVisible() async throws {
        for width: CGFloat in [390, 320] {
            let fixture = GitReviewFixture()
            let file = GitFileChange(path: "Sources/Review.swift", kind: "untracked", index: ".", worktree: "?")
            await fixture.useFiles([file])
            await fixture.setBlob(.init(path: file.path, rev: "WORKTREE",
                content: (1...160).map { "let line\($0) = \($0)" }.joined(separator: "\n")))
            let (model, stores) = try makeModel(fixture, registry: WorkspaceRemoteFixture())
            await model.load()
            let presentation = GitReviewPresentation()
            let window = try await render(GitReviewPresentationView(model: model, change: file, presentation: presentation),
                stores: stores, name: "mindwire-review-presentation-\(Int(width))", width: width)
            defer { window.isHidden = true }
            presentation.isPresented = true
            try await Task.sleep(for: .milliseconds(400))
            presentation.path = [0]
            for _ in 0..<100 {
                if findEditor(in: window) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let editor = try XCTUnwrap(findEditor(in: window))
            let initialOffset = editor.contentOffset.y
            // Read the first presented layout, not a reopened editor or a manually resized bar.
            let first = try reviewSnapshot(window, name: "mindwire-review-first-\(Int(width))")
            try assertActionsOnOneRow(in: first)
            XCTAssertEqual(editor.topEdgeEffect.style, .soft)
            XCTAssertEqual(editor.bottomEdgeEffect.style, .soft)
            XCTAssertGreaterThan(editor.contentInset.top, 44, "The editor must extend under the file header")
            XCTAssertGreaterThan(editor.contentInset.bottom, 40, "Keep code above the review actions")
            XCTAssertEqual(initialOffset, -editor.contentInset.top, accuracy: 1,
                           "The first code line must be visible as soon as the file opens")

            let firstLine = editor.caretRect(for: editor.beginningOfDocument)
            XCTAssertGreaterThanOrEqual(firstLine.minY, editor.contentOffset.y + editor.contentInset.top - 1)
            editor.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            _ = try reviewSnapshot(window, name: "mindwire-review-native-edges-\(Int(width))")

            let selection = (editor.text as NSString).range(of: "let line70 = 70")
            editor.selectedRange = selection
            try await Task.sleep(for: .milliseconds(100))
            let selected = try reviewSnapshot(window, name: "mindwire-review-selection-edges-\(Int(width))")
            XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: selected).contains(t("editor.sendToAgent")))
            XCTAssertEqual(editor.selectedRange, selection)
            editor.selectedRange = NSRange(location: selection.location, length: 0)
            try await Task.sleep(for: .milliseconds(100))

            editor.scrollRangeToVisible(NSRange(location: (editor.text as NSString).length, length: 0))
            try await Task.sleep(for: .milliseconds(100))
            let lastLine = editor.caretRect(for: editor.endOfDocument)
            XCTAssertLessThanOrEqual(lastLine.maxY,
                                     editor.contentOffset.y + editor.bounds.height - editor.contentInset.bottom + 1,
                                     "The final line must scroll fully above Stage and Discard")
            _ = try reviewSnapshot(window, name: "mindwire-review-last-\(Int(width))")
            await model.dispose()
        }
    }

    func testOpenedFileSelectionFooterPreservesPositionAndLastLineVisibility() async throws {
        let content = (1...160).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let workspace = SelfHostedWorkspaceService { _ in .init(exitCode: 0, stdout: content, stderr: "") }
        let (_, stores) = try makeModel(GitReviewFixture())
        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "dark" : "light"
            let window = try await render(NavigationStack {
                FileEditorScreen(workspace: workspace, path: "/Sources/Example.swift", projectId: "project",
                                 onOpenChat: { _, _ in })
            }, stores: stores, name: "mindwire-file-first-\(name)", scheme: scheme)
            defer { window.isHidden = true }
            let editor = try XCTUnwrap(findEditor(in: window))
            XCTAssertEqual(editor.contentOffset.y, -editor.contentInset.top, accuracy: 1)
            XCTAssertGreaterThan(editor.contentInset.top, 44)
            let initialBottomInset = editor.contentInset.bottom
            editor.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            _ = try reviewSnapshot(window, name: "mindwire-file-header-\(name)")

            let selection = (content as NSString).range(of: "let value70 = 70")
            editor.selectedRange = selection
            try await Task.sleep(for: .milliseconds(100))
            let selected = try reviewSnapshot(window, name: "mindwire-file-selection-\(name)")
            XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: selected).contains(t("editor.sendToAgent")))
            XCTAssertGreaterThan(editor.contentInset.bottom, initialBottomInset + 30)
            XCTAssertEqual(editor.contentOffset.y, 600, accuracy: 1, "The footer must not jump the code")
            XCTAssertEqual(editor.selectedRange, selection)

            editor.scrollRangeToVisible(NSRange(location: (content as NSString).length, length: 0))
            try await Task.sleep(for: .milliseconds(100))
            let lastLine = editor.caretRect(for: editor.endOfDocument)
            XCTAssertLessThanOrEqual(lastLine.maxY,
                editor.contentOffset.y + editor.bounds.height - editor.contentInset.bottom + 1)
            _ = try reviewSnapshot(window, name: "mindwire-file-last-\(name)")
            editor.selectedRange = NSRange(location: (content as NSString).length, length: 0)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(editor.contentInset.bottom, initialBottomInset, accuracy: 1)
        }
    }

    private func assertActionsOnOneRow(in image: UIImage) throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let words = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text, observation.boundingBox)
        }
        let discard = try XCTUnwrap(words.first { $0.0 == t("git.discard") }?.1, "\(words)")
        let stage = try XCTUnwrap(words.first { $0.0 == t("git.stage") }?.1, "\(words)")
        XCTAssertEqual(discard.midY, stage.midY, accuracy: 0.015, "Review actions must never stack")
        XCTAssertLessThan(discard.maxX, stage.minX)
        XCTAssertLessThan(stage.midY, 0.15, "Review actions belong at the bottom")
    }

    @discardableResult private func reviewSnapshot(_ window: UIWindow, name: String) throws -> UIImage {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        return image
    }

    private func makeModel(_ fixture: GitReviewFixture, registry: WorkspaceRemoteFixture? = nil,
                           authorRemote: (() async throws -> any GitAuthorRemote)? = nil,
                           pullRequestRemote: (any GitPullRequestRemote)? = nil) throws -> (GitModel, Stores) {
        let suite = "git-review-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let workspace = Workspace(id: "fixture", name: "Mindwire", runtime: .server(serverId: "fixture"), createdAt: isoNow())
        if let registry {
            registry.supportsProjectOperations = true
            registry.current = WorkspaceMetadata(version: 1, workspaceId: "database", revision: 1, full: true,
                agents: [Agent(id: "codex", name: "Codex", agentType: .codex, workspaceId: "database", createdAt: isoNow())],
                projects: [Project(id: "project", name: "Mindwire", workspaceId: "database", path: "/projects/mindwire", createdAt: isoNow())],
                chats: [], deleted: [])
            stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in registry },
                                                           resolveWorkspace: { $0 == workspace.id ? workspace : nil })
            try stores.workspaceData.apply(registry.current, workspaceId: workspace.id)
        }
        let authorClient: (() async throws -> any GitAuthorRemote)? = authorRemote ?? (registry == nil
            ? { GitReviewAuthorRemote(fixture: fixture) } : nil)
        let prRemote = pullRequestRemote ?? GitReviewPullRequestRemote()
        return (GitModel(workspace: workspace, stores: stores, path: "/projects/mindwire", gitService: fixture,
                         authorRemote: authorClient, pullRequestRemote: { prRemote }), stores)
    }

    private func findEditor(in view: UIView) -> DiffGutterTextView? {
        if let editor = view as? DiffGutterTextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor(in: $0) }.first
    }

    private func render<V: View>(_ view: V, stores: Stores, name: String, width: CGFloat = 390,
                                scheme: ColorScheme = .dark) async throws -> UIWindow {
        let host = UIHostingController(rootView: view.environment(\.stores, stores).tint(Palette.accent).preferredColorScheme(scheme))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(700))
        let image = ChatFeedSnapshot.image(host)
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        return window
    }
}

@MainActor @Observable
private final class GitHistoryPresentation { var path = NavigationPath() }

private actor OpenedFileFixture {
    private(set) var reads = 0
    func execute(_ command: [String]) async throws -> ExecResult {
        reads += 1
        return ExecResult(exitCode: 0, stdout: "let loadedVersion = \(reads)\n", stderr: "")
    }
}

@MainActor @Observable
private final class GitToolLifetimeState {
    var presented = true
    var covered = false
    var path: [Int] = []
    var closes = 0
}

private struct GitToolLifetimeHost: View {
    @Bindable var lifetime: GitToolLifetimeState
    var body: some View {
        if lifetime.presented { GitToolLifetimeView(lifetime: lifetime) }
        else { Text("Project") }
    }
}

private struct GitToolLifetimeView: View {
    @Bindable var lifetime: GitToolLifetimeState
    @StateObject private var resources = PresentationResources()
    var body: some View {
        NavigationStack(path: $lifetime.path) {
            Text("Source Control")
                .navigationDestination(for: Int.self) { _ in Text("File diff") }
        }
        .sheet(isPresented: $lifetime.covered) { Text("Editor settings") }
        .onAppear {
            let state = lifetime
            resources.cleanup = { state.closes += 1 }
        }
    }
}

@MainActor @Observable
private final class GitReviewPresentation {
    var isPresented = false
    var path: [Int] = []
}

/// Source Control opens in a sheet and pushes a diff from a screen with its own bottom toolbar.
/// Exercise that transition: a standalone NavigationStack misses inherited bars and first sizing.
private struct GitReviewPresentationView: View {
    let model: GitModel
    let change: GitFileChange
    @Bindable var presentation: GitReviewPresentation

    var body: some View {
        Text("Project")
            .sheet(isPresented: $presentation.isPresented) {
                NavigationStack(path: $presentation.path) {
                    List { Text(change.name) }
                        .navigationTitle(t("git.sourceControl"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .bottomBar) { Button(t("git.commit")) {} } }
                        .toolbarBackground(.visible, for: .bottomBar)
                        .navigationDestination(for: Int.self) { _ in
                            GitDiffScreen(model: model, change: change, staged: false, onOpenChat: { _, _ in })
                        }
                }
            }
    }
}

@MainActor @Observable
private final class GitReviewFocusFixture {
    var range: NSRange?
    var fontSize: CGFloat = 13
    var wrapLines = false
    var selectedText: String?
}

private struct GitReviewFocusEditor: View {
    let text: String
    let tints: [Int: DiffTint]
    let focus: GitReviewFocusFixture
    let handle: EditorHandle

    var body: some View {
        CodeEditorView(text: .constant(text), fontSize: focus.fontSize, isDark: true,
                       wrapLines: focus.wrapLines, isEditable: false, diffTints: tints,
                       focusedRange: focus.range, onSelectionChange: { focus.selectedText = $0 }, handle: handle)
    }
}

@MainActor
private struct GitReviewAuthorRemote: GitAuthorRemote {
    let fixture: GitReviewFixture
    func load(_ context: GitAuthorContext?) async throws -> GitAuthorSettings {
        let author = try await fixture.identity()
        return GitAuthorSettings(effective: author, repository: author)
    }
    func save(_ update: GitAuthorUpdate, context: GitAuthorContext?) async throws -> GitAuthorSettings {
        await fixture.setIdentity(update.identity ?? GitIdentity())
        return try await load(context)
    }
}

@MainActor
private final class GitReviewPullRequestRemote: GitPullRequestRemote {
    private(set) var drafts: [GitPullRequestDraft] = []
    func prepare(_ context: GitPullRequestContext) async throws -> GitPullRequestPreparation {
        .init(defaultBranch: "main", branches: ["main", "develop", context.branch], existing: nil,
              branchHeads: ["main": String(repeating: "b", count: 40), "develop": String(repeating: "c", count: 40)])
    }
    func create(_ context: GitPullRequestContext, draft: GitPullRequestDraft) async throws -> GitHubPullRequest {
        drafts.append(draft)
        return .init(number: 23, title: draft.title, htmlURL: URL(string: "https://github.com/team/app/pull/23")!,
            draft: draft.draft, head: .init(ref: context.branch, sha: context.head),
            base: .init(ref: draft.base, sha: String(repeating: "b", count: 40)))
    }
}

private actor GitReviewFixture: GitService {
    struct DiffRead { let path: String; let staged: Bool; let context: Int? }
    static let mixed = GitFileChange(path: "Sources/Chat/Composer.swift", kind: "modified", index: "M", worktree: "M",
                                     staged: .init(additions: 8, deletions: 3), unstaged: .init(additions: 24, deletions: 6))
    private var files = [mixed,
        GitFileChange(path: "Sources/Chat/QuestionSheet.swift", kind: "untracked", index: ".", worktree: "?"),
        GitFileChange(path: "Sources/Legacy/PromptCard.swift", kind: "deleted", index: ".", worktree: "D", unstaged: .init(deletions: 42)),
        GitFileChange(path: "Resources/Appearance.json", origPath: "Resources/Theme.json", kind: "renamed", index: ".", worktree: "R",
                      unstaged: .init(additions: 3, deletions: 1))]
    private var fails = false
    private var statusFails = false
    private var statusError: (any Error)?
    private var diffError: (any Error)?
    private var writeError: (any Error)?
    private var diffPatch: String?
    private var holdStatus = false
    private var statusGates: [CheckedContinuation<Void, Never>] = []
    private(set) var statusReads = 0
    private var hold = false
    private var gate: CheckedContinuation<Void, Never>?
    private var holdDiffs = false
    private var diffGates: [CheckedContinuation<Void, Never>] = []
    private var currentBranch = "feature/chat-input"
    private var author = GitIdentity(name: "Fixture User", email: "fixture@example.invalid")
    private(set) var committedMessages: [String] = []
    private(set) var historicalReads = 0
    private(set) var historyRequests: [GitHistoryCursor?] = []
    private(set) var unstagedPaths: [String] = []
    private var historyCommits = (1...8).reversed().map {
        GitCommit(id: String(format: "%040d", $0), parents: $0 == 1 ? [] : [String(format: "%040d", $0 - 1)],
                  authorName: "Fixture User", authorEmail: "fixture@example.invalid", date: Date(timeIntervalSince1970: 1_790_000_000),
                  subject: "Improve native review \($0)")
    }
    private var localBranches = ["main", "feature/chat-input"]
    private var fileBlob = GitBlob(path: "new.swift", rev: "WORKTREE", content: "import SwiftUI\n\nstruct QuestionSheet: View {\n    var body: some View { Text(\"Your input\") }\n}\n")
    private(set) var diffReads: [DiffRead] = []
    private(set) var writes: [GitAction] = []
    private var pullRequestsEnabled = false
    private var pullRequestCount = 2
    private var pullRequestPublished = false
    private var pullRequestError: (any Error)?
    private(set) var pullRequestReads = 0
    var waiting: Bool { gate != nil }

    func enablePullRequests(count: Int = 2, published: Bool = false) {
        pullRequestsEnabled = true; pullRequestCount = count; pullRequestPublished = published
    }
    func publishPullRequestBranch() { pullRequestPublished = true }
    func failPullRequestLookup(_ error: (any Error)?) { pullRequestError = error }
    func pullRequestContext() async throws -> GitPullRequestContext? {
        pullRequestReads += 1
        if let pullRequestError { throw pullRequestError }
        guard pullRequestsEnabled, let commit = historyCommits.first else { return nil }
        return GitPullRequestContext(repository: GitHubRepo.fromGitInput("team/app")!, branch: currentBranch,
            head: commit.id, baseBranch: "main", remoteHead: pullRequestPublished ? commit.id : nil,
            commitCount: pullRequestCount, title: commit.subject)
    }

    func pullRequestComparison(head: String, baseBranch: String, baseHead: String, remoteHead: String?) async throws -> GitPullRequestComparison {
        .init(baseBranch: baseBranch, baseHead: baseHead, head: head, mergeBase: baseHead,
              remoteHead: remoteHead, commitCount: pullRequestCount,
              files: [.init(path: "Sources/Committed.swift", kind: "modified", index: "M", worktree: ".",
                            staged: .init(additions: 2, deletions: 1))])
    }
    func comparisonDiff(_ comparison: GitPullRequestComparison, change: GitFileChange, unified: Int?) async throws -> GitDiff {
        .init(path: change.path, staged: true, additions: 2, deletions: 1,
              patch: "@@ -1 +1,2 @@\n-oldCode()\n+committedCode()\n+reviewedCode()\n")
    }

    func setFailure(_ value: Bool) { fails = value }
    func setIdentity(_ value: GitIdentity) { author = value }
    func prependCommit() {
        historyCommits.insert(GitCommit(id: String(repeating: "f", count: 40), parents: [historyCommits[0].id],
                                       authorName: "New Author", authorEmail: "new@example.invalid", date: Date(), subject: "New commit"), at: 0)
    }
    func failStatus(_ value: Bool) { statusFails = value }
    func setStatusError(_ error: (any Error)?) { statusError = error }
    func setDiffError(_ error: (any Error)?) { diffError = error }
    func setWriteError(_ error: (any Error)?) { writeError = error }
    func setPatch(_ patch: String) { diffPatch = patch }
    func holdStatusReads() { holdStatus = true }
    func releaseStatusReads() {
        holdStatus = false
        let pending = statusGates
        statusGates = []
        for gate in pending { gate.resume() }
    }
    func holdWrite() { hold = true }
    func releaseWrite() { hold = false; gate?.resume(); gate = nil }
    func setBlob(_ blob: GitBlob) { fileBlob = blob }
    func useFiles(_ files: [GitFileChange]) { self.files = files }
    func useCommits(_ commits: [GitCommit]) { historyCommits = commits }
    func holdDiffReads() { holdDiffs = true }
    func releaseDiffReads() {
        holdDiffs = false
        let pending = diffGates
        diffGates = []
        for gate in pending { gate.resume() }
    }
    func branches() async throws -> [GitBranch] {
        localBranches.map { GitBranch(name: $0, isCurrent: $0 == currentBranch) }
            + [GitBranch(name: "origin/release", isRemote: true)]
    }
    func switchBranch(_ name: String, remote: Bool) async throws {
        try await write(.switchBranch)
        currentBranch = name
    }
    func createBranch(_ name: String) async throws {
        try await write(.createBranch)
        localBranches.append(name)
        currentBranch = name
    }

    func status() async throws -> GitStatus {
        statusReads += 1
        let snapshot = GitStatus(isRepo: true, root: "/projects/mindwire", branch: currentBranch, upstream: "origin/main",
                                 ahead: 2, behind: 0, detached: false, files: files, head: historyCommits.first?.id)
        if holdStatus { await withCheckedContinuation { statusGates.append($0) } }
        if let statusError { throw statusError }
        if statusFails { throw BackendError.message("Fixture read failed") }
        return snapshot
    }
    func blob(path: String, rev: GitRev) async throws -> GitBlob { fileBlob }
    func diff(path: String, staged: Bool, unified: Int?) async throws -> GitDiff {
        diffReads.append(.init(path: path, staged: staged, context: unified))
        let error = diffError
        let patch = diffPatch ?? """
        diff --git a/Composer.swift b/Composer.swift
        --- a/Composer.swift
        +++ b/Composer.swift
        @@ -28,6 +28,8 @@ struct Composer: View {
             private func send() async {
        -        await agent.send(message)
        +        let draft = message
        +        message = ""
        +        await agent.send(draft)
             }

        @@ -62,3 +64,3 @@
        -    var canSend: Bool { !message.isEmpty }
        +    var canSend: Bool { !message.isEmpty && !isSending }
         }
        """
        if holdDiffs { await withCheckedContinuation { diffGates.append($0) } }
        if let error { throw error }
        return GitDiff(path: path, staged: staged, additions: 4, deletions: 2, patch: patch)
    }
    func stage(_ paths: [String]) async throws {
        try await write(.stage)
        files = files.map { file in
            guard paths.contains(file.path) else { return file }
            return GitFileChange(path: file.path, origPath: file.origPath,
                kind: file.isUntracked ? "added" : file.kind, index: file.isUntracked ? "A" : file.worktree, worktree: ".",
                staged: .init(additions: (file.staged?.additions ?? 0) + (file.unstaged?.additions ?? 0),
                              deletions: (file.staged?.deletions ?? 0) + (file.unstaged?.deletions ?? 0)))
        }
    }
    func unstage(_ paths: [String]) async throws {
        try await write(.unstage)
        unstagedPaths = paths
        files = files.map { file in
            guard paths.contains(file.path) else { return file }
            return GitFileChange(path: file.path, origPath: file.origPath, kind: file.kind, index: ".", worktree: "M", unstaged: file.unstaged)
        }
    }
    func discard(_ paths: [String]) async throws { try await write(.discard) }
    func commit(message: String, identity: GitIdentity?) async throws {
        if let identity { author = identity }
        guard author.isValid else { throw GitIdentityError.required }
        try await write(.commit)
        committedMessages.append(message)
        if pullRequestsEnabled {
            pullRequestCount += 1; pullRequestPublished = false
            historyCommits.insert(GitCommit(id: String(repeating: "e", count: 40), parents: historyCommits.first.map { [$0.id] } ?? [],
                authorName: author.name, authorEmail: author.email, date: Date(), subject: message), at: 0)
        }
    }
    func identity() async throws -> GitIdentity { author }
    func history(cursor: GitHistoryCursor?, limit: Int) async throws -> GitHistoryPage {
        historyRequests.append(cursor)
        if fails { throw BackendError.message("Fixture history failed") }
        guard !historyCommits.isEmpty else { return GitHistoryPage(commits: [], next: nil) }
        let base = cursor.flatMap { c in historyCommits.firstIndex { $0.id == c.tip } } ?? 0
        let offset = cursor?.offset ?? 0
        let tip = cursor?.tip ?? historyCommits[0].id
        let start = base + offset
        let count = min(limit, 3)
        let values = Array(historyCommits.dropFirst(start).prefix(count))
        return GitHistoryPage(commits: values,
                              next: start + values.count < historyCommits.count ? .init(tip: tip, offset: offset + values.count) : nil)
    }
    func commitDetails(_ commit: GitCommit) async throws -> GitCommitDetails {
        GitCommitDetails(message: commit.subject, files: [Self.mixed])
    }
    func commitDiff(_ commit: GitCommit, change: GitFileChange, unified: Int?) async throws -> GitDiff {
        historicalReads += 1
        return GitDiff(path: change.path, staged: true, additions: 1, deletions: 1,
                       patch: "@@ -1 +1 @@\n-oldCode()\n+historicalCode()\n")
    }
    private func write(_ action: GitAction) async throws {
        writes.append(action)
        if hold { await withCheckedContinuation { gate = $0 } }
        if let writeError { throw writeError }
        if fails { throw BackendError.message("Fixture write failed") }
    }
}
