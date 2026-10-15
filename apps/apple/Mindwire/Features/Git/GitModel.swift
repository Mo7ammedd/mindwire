import Foundation

/// Read-only queries use workspace exec. Registered projects use durable daemon
/// operations for every mutation, with explicit compatibility for older daemons.
/// Mirrors `WorkspaceModel` — owns a backend built from the workspace runtime and disposes it.
@MainActor
@Observable
final class GitModel {
    private let backend: Backend
    private let git: GitService
    private let remoteGit: WorkspaceGitService
    private let project: Project?
    private let presentation: ProjectPresentationCache
    let projectId: String?
    let repositoryName: String
    let workspace: Workspace
    var workspaceName: String { workspace.name }
    var workspaceId: String { workspace.id }
    let authorDefaults: GitAuthorDefaults
    private let makeAuthorRemote: () async throws -> any GitAuthorRemote
    private let makePullRequestRemote: () async throws -> any GitPullRequestRemote

    private(set) var status: GitStatus?
    private(set) var revision = 0
    private(set) var loading = true
    private(set) var error: String?
    private(set) var errorCode: String?
    private(set) var isMutating = false
    private(set) var activeAction: GitAction?
    private(set) var activePaths: Set<String> = []
    private(set) var activeOperation: GitOperation?
    private(set) var remoteOutput: String?
    private(set) var operationNotice: String?
    private(set) var identityRequired = false
    private(set) var authenticationRequired = false
    private(set) var savingAuthor = false
    private(set) var authorNotice: String?
    private(set) var pullRequestContext: GitPullRequestContext?
    private(set) var openingPullRequest = false
    private(set) var serviceRecoveryNeeded = false
    @ObservationIgnored private var operationTask: Task<Bool, Never>?
    @ObservationIgnored private var operationClient: GitOperationClient?
    @ObservationIgnored private var previews: [GitDiffPreviewKey: GitDiffPreviewState] = [:]
    @ObservationIgnored private var statusTask: (id: UUID, refreshPullRequest: Bool, task: Task<Void, Error>)?
    @ObservationIgnored private var disposed = false
    @ObservationIgnored private var pullRequestLookupKey: String?
    @ObservationIgnored private var pullRequestLookupError: (any Error)?
    @ObservationIgnored private var sharedDiffRevision = 0
    @ObservationIgnored private var fileDiffRevisions: [String: Int] = [:]

    var committing: Bool { activeAction == .commit && isMutating }
    var hasPendingOperation: Bool { projectId.flatMap { remoteGit.pendingRequest(projectId: $0) } != nil }
    var canCreatePullRequest: Bool {
        pullRequestContext?.matches(status) == true && pullRequestContext?.isFeatureBranch == true
    }
    var hasUnpushedCommits: Bool {
        guard let status, status.isRepo, !status.detached, status.head != nil,
              let branch = status.branch else { return false }
        if status.upstream == "origin/" + branch { return status.ahead > 0 }
        guard let context = pullRequestContext, context.matches(status) else { return false }
        return context.remoteHead == nil || (context.unpushedCount ?? 0) > 0
    }

    /// `path` scopes git to a project workdir; `nil` = the workspace's own repo.
    init(workspace: Workspace, stores: Stores, path: String? = nil, gitService: GitService? = nil,
         authorRemote: (() async throws -> any GitAuthorRemote)? = nil,
         pullRequestRemote: (() async throws -> any GitPullRequestRemote)? = nil) {
        let backend = BackendFactory.make(forRuntime: workspace.runtime, stores: stores)
        self.backend = backend
        self.git = gitService ?? BackendFactory.gitService(forBackend: backend, root: path)
        let remoteGit = WorkspaceGitService(workspaceId: workspace.id, stores: stores)
        self.remoteGit = remoteGit
        let project = stores.projects(forWorkspaceId: workspace.id).first { $0.path == path }
        self.project = project
        self.presentation = stores.projectPresentation
        self.projectId = project?.id
        self.repositoryName = project?.name ?? path.map { ($0 as NSString).lastPathComponent } ?? workspace.name
        self.workspace = workspace
        self.authorDefaults = stores.gitAuthors
        self.makeAuthorRemote = authorRemote ?? {
            GitAuthorClient(http: try await stores.workspaceData.gitIdentityHTTP(workspaceId: workspace.id))
        }
        self.makePullRequestRemote = pullRequestRemote ?? {
            try await remoteGit.pullRequestClient(projectId: project?.id, workspace: backend.workspace)
        }
    }

    // Derived sections. A path with both staged + worktree changes ("MM") appears in both.
    private var files: [GitFileChange] { status?.files ?? [] }
    var staged: [GitFileChange] { files.filter(\.isStaged) }
    var changes: [GitFileChange] { files.filter(\.hasUnstagedChange) }
    var untracked: [GitFileChange] { files.filter(\.isUntracked) }
    var conflicts: [GitFileChange] { files.filter(\.isConflicted) }
    /// VS Code groups untracked into "Changes" — both are unstaged work.
    var unstaged: [GitFileChange] { changes + untracked }
    /// Every changed path, once, for the repository summary and file search.
    var allChanges: [GitFileChange] { files }

    var isRepo: Bool { status?.isRepo ?? false }
    var isClean: Bool { files.isEmpty }
    var hasStaged: Bool { !staged.isEmpty }

    func branches() async throws -> [GitBranch] { try await git.branches() }
    func identity() async throws -> GitIdentity { try await git.identity() }
    private var authorContext: GitAuthorContext { .init(projectId: projectId, path: status?.root) }

    func authorSettings() async throws -> GitAuthorSettings {
        try await makeAuthorRemote().load(authorContext)
    }

    /// Author setup has no commit message and never enters the Git mutation dispatcher.
    @discardableResult
    func saveAuthor(_ identity: GitIdentity?, scope: GitAuthorScope) async -> Bool {
        guard await canBeginMutation() else { return false }
        if let identity, !identity.isValid { error = t("git.identity.invalid"); return false }
        savingAuthor = true; isMutating = true; error = nil; authorNotice = nil
        defer { savingAuthor = false; isMutating = false }
        if scope == .allWorkspaces {
            authorDefaults.set(identity)
            // The queue outlives this screen. Acknowledged workspaces are skipped;
            // unavailable and future workspaces pick up the default on reconciliation.
            authorDefaults.reconcile(WorkspaceRepository.shared.all)
            let applied = await authorDefaults.synchronize(workspaceId)
            if applied, let state = try? await authorSettings() { identityRequired = !state.effective.isValid }
            authorNotice = t(applied ? "git.identity.savedAll" : "git.identity.savedPending")
            return true
        }
        do {
            let state = try await makeAuthorRemote().save(.init(scope: scope, identity: identity?.normalized), context: authorContext)
            identityRequired = !state.effective.isValid
            authorNotice = t("git.identity.saved")
            return true
        } catch {
            if !Task.isCancelled && !error.isRequestCancellation { self.error = error.localizedDescription }
            return false
        }
    }
    func history(cursor: GitHistoryCursor? = nil, limit: Int = 30) async throws -> GitHistoryPage {
        try await git.history(cursor: cursor, limit: limit)
    }
    func commitDetails(_ commit: GitCommit) async throws -> GitCommitDetails { try await git.commitDetails(commit) }
    func commitDiff(_ commit: GitCommit, change: GitFileChange, unified: Int?) async throws -> GitDiff {
        try await git.commitDiff(commit, change: change, unified: unified)
    }

    func prepareRestore(_ commit: GitCommit) async -> GitRestorePlan? {
        guard await canBeginMutation() else { return nil }
        isMutating = true; error = nil; operationNotice = nil; remoteOutput = nil
        defer { isMutating = false }
        do {
            guard let projectId else { throw BackendError.message(t("git.restore.projectRequired")) }
            guard try await remoteGit.operationClient(projectId: projectId, minimumVersion: 4) != nil else {
                throw WorkspaceRegistryError.gitRestoreUnavailable
            }
            try await readStatus()
            guard let status, status.isRepo, let head = status.head else {
                throw BackendError.message(t("git.history.invalidRevision"))
            }
            guard isClean else { throw BackendError.message(t("git.restore.dirty")) }
            return GitRestorePlan(commit: commit, head: head, branch: status.branch)
        } catch {
            if !Task.isCancelled && !error.isRequestCancellation { self.error = error.localizedDescription }
            return nil
        }
    }

    @discardableResult
    func restore(_ plan: GitRestorePlan) async -> Bool {
        await perform(plan.request)
    }

    @discardableResult
    func switchBranch(_ branch: GitBranch) async -> Bool {
        guard !branch.isCurrent else { return true }
        return await perform(.init(action: .switchBranch, branch: branch.name, remote: branch.isRemote))
    }

    @discardableResult
    func createBranch(_ name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return await perform(.init(action: .createBranch, branch: name))
    }

    @discardableResult
    func renameBranch(_ branch: GitBranch, to name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isRemote, let tip = branch.tip, !name.isEmpty else {
            error = t("git.branches.refreshRequired"); return false
        }
        return await perform(.init(action: .renameBranch, branch: branch.name, newName: name, expectedTip: tip))
    }

    @discardableResult
    func deleteBranch(_ branch: GitBranch, force: Bool = false) async -> Bool {
        guard !branch.isRemote, let tip = branch.tip else {
            error = t("git.branches.refreshRequired"); return false
        }
        return await perform(.init(action: .deleteBranch, branch: branch.name, expectedTip: tip, force: force))
    }

    func load() async {
        guard !disposed, !Task.isCancelled else { return }
        loading = status == nil
        error = nil
        do { try await readStatus() }
        catch {
            if !Task.isCancelled && !error.isRequestCancellation { self.error = error.localizedDescription }
            loading = false
            return
        }
        loading = false
        if isRepo, projectId != nil { _ = await perform(nil) }
    }

    func refresh() async {
        guard !disposed, !Task.isCancelled else { return }
        do { try await readStatus(refreshPullRequest: true); error = nil }
        catch {
            if !Task.isCancelled && !error.isRequestCancellation { self.error = error.localizedDescription }
            return
        }
        if isRepo, projectId != nil, !isMutating { _ = await perform(nil) }
    }

    @discardableResult
    func stage(_ paths: [String]) async -> Bool {
        guard !paths.isEmpty else { return false }
        return await perform(.init(action: .stage, paths: paths))
    }
    @discardableResult
    func unstage(_ paths: [String]) async -> Bool {
        guard !paths.isEmpty else { return false }
        // A staged rename is an old-path deletion plus a new-path addition. Reset
        // both sides so Unstage never leaves half of the rename in the next commit.
        let originals = staged.filter { paths.contains($0.path) && $0.index == "R" }.compactMap(\.origPath)
        return await perform(.init(action: .unstage, paths: paths + originals))
    }
    @discardableResult
    func discard(_ paths: [String]) async -> Bool {
        guard !paths.isEmpty else { return false }
        return await perform(.init(action: .discard, paths: paths))
    }
    func stageAll() async { await stage(unstaged.map(\.path)) }
    func unstageAll() async { await unstage(staged.map(\.path)) }

    /// Returns `true` on success so the view only clears the message box when the commit landed —
    /// a failed commit keeps the typed message for retry.
    @discardableResult
    func commit(_ message: String) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await perform(.init(action: .commit, message: trimmed))
    }

    @discardableResult
    func runRemote(_ operation: GitRemoteOperation) async -> Bool {
        guard projectId != nil, let action = GitAction(rawValue: operation.rawValue) else { return false }
        return await perform(.init(action: action))
    }

    func preparePullRequest(_ context: GitPullRequestContext) async throws -> GitPullRequestPreparation {
        error = nil
        return try await makePullRequestRemote().prepare(context)
    }

    func pullRequestComparison(_ context: GitPullRequestContext, base: String, baseHead: String, remoteHead: String?) async throws -> GitPullRequestComparison {
        guard context.matches(status) else { throw BackendError.message(t("git.pr.changed")) }
        return try await git.pullRequestComparison(head: context.head, baseBranch: base, baseHead: baseHead, remoteHead: remoteHead)
    }

    func comparisonDiff(_ comparison: GitPullRequestComparison, change: GitFileChange, unified: Int?) async throws -> GitDiff {
        try await git.comparisonDiff(comparison, change: change, unified: unified)
    }

    /// Creates through the connected GitHub account. Publishing still uses the
    /// existing durable Push; no files are staged or committed by the PR flow.
    func createPullRequest(_ confirmed: GitPullRequestContext, draft: GitPullRequestDraft,
                           comparison: GitPullRequestComparison? = nil) async -> GitHubPullRequest? {
        guard await canBeginMutation(), !hasPendingOperation else { return nil }
        guard draft.isValid, draft.base != confirmed.branch else { error = t("git.pr.invalidDraft"); return nil }
        openingPullRequest = true
        error = nil
        defer { openingPullRequest = false }
        do {
            if let comparison {
                guard comparison.head == confirmed.head, comparison.baseBranch == draft.base,
                      comparison.commitCount > 0, !comparison.truncated else {
                    throw BackendError.message(t("git.pr.changed"))
                }
            }
            try await readStatus(refreshPullRequest: true)
            if let pullRequestLookupError { throw pullRequestLookupError }
            guard let current = pullRequestContext, current.matches(status), current.isFeatureBranch,
                  current.hasSameSource(as: confirmed) else {
                throw BackendError.message(t("git.pr.changed"))
            }
            let remote = try await makePullRequestRemote()
            guard (comparison?.commitCount ?? current.commitCount) != 0 else {
                throw BackendError.message(t("git.pr.noCommittedChanges"))
            }
            if comparison?.needsPush ?? current.needsPush {
                guard projectId != nil else { throw BackendError.message(t("git.pr.projectRequired")) }
                guard await perform(.init(action: .push), forPullRequest: true) else { return nil }
                guard let published = pullRequestContext, published.hasSameSource(as: confirmed),
                      published.matches(status), !published.needsPush else {
                    throw BackendError.message(t("git.pr.publishUnconfirmed"))
                }
            }
            try Task.checkCancellation()
            var reviewedDraft = draft
            reviewedDraft.expectedBaseHead = comparison?.baseHead ?? draft.expectedBaseHead
            return try await remote.create(current, draft: reviewedDraft)
        } catch {
            if !Task.isCancelled && !error.isRequestCancellation { self.error = error.localizedDescription }
            return nil
        }
    }

    func retryPendingOperation() async {
        guard let projectId, let request = remoteGit.pendingRequest(projectId: projectId) else { return }
        _ = await perform(request)
    }

    func cancelOperation() async {
        guard let operationClient, let activeOperation, activeOperation.isActive else { return }
        do { self.activeOperation = try await operationClient.cancel(activeOperation.id) }
        catch { if !Task.isCancelled && !error.isRequestCancellation { self.error = error.localizedDescription } }
    }

    func blob(path: String, rev: GitRev) async throws -> GitBlob {
        try await git.blob(path: path, rev: rev)
    }

    func diff(path: String, staged: Bool, unified: Int? = nil) async throws -> GitDiff {
        try await git.diff(path: path, staged: staged, unified: unified)
    }

    func preview(path: String, staged: Bool) -> GitDiffPreviewState {
        let key = GitDiffPreviewKey(path: path, staged: staged)
        if let preview = previews[key] { return preview }
        let preview = GitDiffPreviewState()
        previews[key] = preview
        return preview
    }

    func fileAction(path: String, staged: Bool) -> GitAction? {
        guard isMutating, activePaths.contains(path), let action = activeAction, action.isFileAction,
              staged == (action == .unstage) else { return nil }
        return action
    }

    /// Staging changes the selected file's index. Other excerpts keep their
    /// cached request even though the list receives its new status snapshot.
    func diffRevision(path: String) -> Int {
        _ = revision
        return fileDiffRevisions[path] ?? sharedDiffRevision
    }

    func dispose() async {
        guard !disposed else { return }
        disposed = true
        operationTask?.cancel() // Detach the observer; only Cancel stops server work.
        statusTask?.task.cancel()
        for preview in previews.values { preview.cancel() }
        await backend.dispose()
    }

    private func readStatus(refreshPullRequest: Bool = false, changedPaths: Set<String>? = nil) async throws {
        guard !disposed else { throw CancellationError() }
        try Task.checkCancellation()
        if let pending = statusTask {
            try await pending.task.value
            try Task.checkCancellation()
            if refreshPullRequest, !pending.refreshPullRequest, let status {
                await readPullRequestContext(for: status, force: true)
            }
            return
        }
        let id = UUID()
        let task = Task {
            let next = try await git.status()
            try Task.checkCancellation()
            applyStatus(next, changedPaths: changedPaths)
            await readPullRequestContext(for: next, force: refreshPullRequest)
        }
        statusTask = (id, refreshPullRequest, task)
        defer { if statusTask?.id == id { statusTask = nil } }
        try await task.value
        try Task.checkCancellation()
    }

    private func applyStatus(_ next: GitStatus, changedPaths: Set<String>?) {
        let previous = status
        if pullRequestContext?.matches(next) != true { pullRequestContext = nil }
        if status?.branch != next.branch || status?.root != next.root {
            for preview in previews.values { preview.cancel() }
            previews.removeAll()
        }
        if status != next { status = next }
        if let project { presentation.record(status: next, for: project) }
        let paths = Set(files.map(\.path))
        for key in Array(previews.keys) where !paths.contains(key.path) {
            previews.removeValue(forKey: key)?.cancel()
        }
        revision += 1
        if let changedPaths, previous?.branch == next.branch, previous?.root == next.root, previous?.head == next.head {
            let oldFiles = Dictionary(previous?.files.map { ($0.path, $0) } ?? [], uniquingKeysWith: { _, last in last })
            let changed = Set(next.files.filter { oldFiles[$0.path] != $0 }.map(\.path)).union(changedPaths)
            for path in changed { fileDiffRevisions[path] = revision }
            fileDiffRevisions = fileDiffRevisions.filter { paths.contains($0.key) }
        } else {
            sharedDiffRevision = revision
            fileDiffRevisions.removeAll()
        }
    }

    private func readPullRequestContext(for snapshot: GitStatus, force: Bool) async {
        guard snapshot.isRepo, !snapshot.detached, let head = snapshot.head, let branch = snapshot.branch else {
            pullRequestContext = nil; pullRequestLookupKey = nil; pullRequestLookupError = nil
            return
        }
        let key = (snapshot.root ?? "") + "\0" + branch + "\0" + head
        guard force || pullRequestLookupKey != key else { return }
        pullRequestLookupError = nil
        do {
            let context = try await git.pullRequestContext()
            try Task.checkCancellation()
            guard !disposed, status?.branch == branch, status?.head == head else { return }
            pullRequestContext = context?.matches(snapshot) == true ? context : nil
            pullRequestLookupKey = key
        } catch {
            // Missing optional PR metadata must not hide the working tree or diff.
            // Manual refresh and the next changed revision can retry this local read.
            if !Task.isCancelled && !disposed {
                pullRequestContext = nil; pullRequestLookupKey = nil; pullRequestLookupError = error
            }
        }
    }

    /// nil observes existing work. It never resubmits an unacknowledged request.
    private func perform(_ request: GitOperationRequest?, forPullRequest: Bool = false) async -> Bool {
        guard !disposed, !Task.isCancelled else { return false }
        if request == nil, let pending = operationTask { return await pending.value }
        guard await canBeginMutation(forPullRequest: forPullRequest) else { return false }
        if let request {
            beginOperation(request)
            if request.action == .commit { authorNotice = nil }
            remoteOutput = nil; operationNotice = nil
            if let projectId { presentation.invalidateGit(projectId) }
        }
        let task = Task {
            defer {
                operationTask = nil; operationClient = nil
                activeAction = nil; activePaths = []; isMutating = false
            }
            return await self.execute(request)
        }
        operationTask = task
        return await task.value
    }

    /// Every mutation, including author settings and restore preparation, waits for
    /// an idle recovery check. Already active operations reject conflicting actions.
    private func canBeginMutation(forPullRequest: Bool = false) async -> Bool {
        while !disposed, !Task.isCancelled, !isMutating, forPullRequest || !openingPullRequest {
            guard let pending = operationTask else { return true }
            _ = await pending.value
        }
        return false
    }

    private func beginOperation(_ request: GitOperationRequest) {
        isMutating = true; activeAction = request.action; activePaths = Set(request.paths ?? [])
        activeOperation = nil; error = nil; errorCode = nil; identityRequired = false; authenticationRequired = false
    }

    private func execute(_ request: GitOperationRequest?) async -> Bool {
        var succeeded = false
        var completedAction: GitAction?
        var needsStatusRefresh = request != nil
        do {
            let client: GitOperationClient?
            do {
                client = if let projectId {
                    try await remoteGit.operationClient(projectId: projectId,
                        minimumVersion: request?.minimumOperationsVersion ?? 1)
                } else { nil }
                serviceRecoveryNeeded = false
            } catch {
                if !Task.isCancelled && !error.isRequestCancellation { serviceRecoveryNeeded = true }
                throw error
            }
            if let projectId, let client {
                operationClient = client
                let initial: GitOperation?
                if let request {
                    initial = try await client.start(request) {
                        try await self.remoteGit.authorization(action: request.action, projectId: projectId)
                    }
                } else { initial = try await client.recover() }
                if let initial {
                    needsStatusRefresh = needsStatusRefresh || initial.isActive
                    let observeProgress = request != nil || initial.isActive
                    if request == nil, initial.isActive { beginOperation(initial.request) }
                    let result = try await client.wait(initial) { operation in
                        if observeProgress {
                            self.activeOperation = operation; self.activeAction = operation.action
                        }
                    }
                    if request != nil || initial.isActive {
                        remoteOutput = result.action.isFileAction ? nil : result.output
                        completedAction = result.action
                    }
                    succeeded = result.status == "succeeded"
                    if !succeeded {
                        errorCode = result.errorCode
                        if result.action == .commit,
                           result.errorCode == "git_identity_required" || result.errorCode == nil && GitIdentityError.matches(result.error ?? "") {
                            identityRequired = true
                        } else {
                            authenticationRequired = result.errorCode == "git_auth_required"
                                || GitAuthenticationError.matches(result.error ?? "")
                            error = result.error ?? t("git.operation.failed")
                        }
                    }
                } else { succeeded = true }
            } else if let request {
                // Compatibility is based on an explicit missing capability. A
                // connection failure never falls through to an uncoordinated write.
                switch request.action {
                case .stage: try await git.stage(request.paths ?? [])
                case .unstage: try await git.unstage(request.paths ?? [])
                case .discard: try await git.discard(request.paths ?? [])
                case .commit: try await git.commit(message: request.message ?? "", identity: request.identity)
                case .switchBranch: try await git.switchBranch(request.branch ?? "", remote: request.remote == true)
                case .createBranch: try await git.createBranch(request.branch ?? "")
                case .renameBranch, .deleteBranch:
                    throw projectId == nil ? BackendError.message(t("git.branches.projectRequired"))
                        : WorkspaceRegistryError.gitBranchManagementUnavailable
                case .restoreCommit:
                    // Restoring always needs the daemon's reservation, state guards and
                    // durable receipt. Never fall through to an uncoordinated exec write.
                    throw projectId == nil ? BackendError.message(t("git.restore.projectRequired"))
                        : BackendError.message(t("git.restore.updateRequired"))
                case .fetch, .pull, .push:
                    guard let projectId, let remote = GitRemoteOperation(rawValue: request.action.rawValue) else { return false }
                    remoteOutput = try await remoteGit.run(remote, projectId: projectId).output
                }
                succeeded = true
                completedAction = request.action
            } else { succeeded = true }
        } catch {
            if !Task.isCancelled && !error.isRequestCancellation {
                if error is GitIdentityError || request?.action == .commit && GitIdentityError.matches(error.localizedDescription) {
                    identityRequired = true
                } else {
                    authenticationRequired = error is GitAuthenticationError
                        || GitAuthenticationError.matches(error.localizedDescription)
                    self.error = error.localizedDescription
                }
            }
        }
        // Reconcile actual writes, including failed outcomes. An idle recovery
        // already has fresh status; reading it again would restart the opened diff.
        if needsStatusRefresh, !Task.isCancelled, !disposed {
            // A read started before this write completed can contain the old index.
            // Reconciliation must use a fresh snapshot, not join that pending read.
            statusTask?.task.cancel()
            statusTask = nil
            let changedPaths = request?.action.isFileAction == true ? Set(request?.paths ?? []) : nil
            do { try await readStatus(refreshPullRequest: completedAction?.isRemote == true, changedPaths: changedPaths) }
            catch {
                if self.error == nil && !Task.isCancelled && !error.isRequestCancellation {
                    self.error = error.localizedDescription
                }
            }
            if succeeded && error == nil { operationNotice = completedAction?.completionMessage ?? operationNotice }
        }
        return succeeded
    }
}
