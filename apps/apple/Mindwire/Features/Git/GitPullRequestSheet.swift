import SwiftUI

/// Create with the connected GitHub account. Opening GitHub is an optional action
/// after a PR exists; creation never depends on a separate browser login.
struct GitPullRequestSheet: View {
    let model: GitModel
    @Environment(\.dismiss) private var dismiss
    @State private var opening = false
    @State private var loadingDetails = true
    @State private var preparation: GitPullRequestPreparation?
    @State private var preparationError: String?
    @State private var context: GitPullRequestContext?
    @State private var draft = GitPullRequestDraft(title: "", base: "")
    @State private var result: GitHubPullRequest?
    @State private var comparison: GitPullRequestComparison?
    @State private var loadingComparison = false
    @State private var comparisonError: (any Error)?
    @State private var refreshID = 0
    @State private var refreshRepository = true
    @State private var showingCommit = false
    @State private var commitMessage = ""
    @State private var stagedExpanded = true
    @State private var workingExpanded = false
    @FocusState private var editing: Bool

    var body: some View {
        let previewRequest = comparisonRequest
        NavigationStack {
            List {
                if let context {
                    Section {
                        HStack(spacing: Spacing.md) {
                            ProviderLogo(id: .github, size: 22).accessibilityHidden(true)
                            Text(context.repository.fullName).font(.subheadline.weight(.medium))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: Spacing.sm)
                            if loadingDetails { ProgressView().controlSize(.small) }
                        }
                        branch(t("git.pr.from"), value: context.branch)
                        if result == nil {
                            Picker(t("git.pr.into"), selection: $draft.base) {
                                ForEach(baseBranches, id: \.self) { Text($0).tag($0) }
                            }
                            .font(.subheadline).tint(.primary)
                            .disabled(loadingDetails || opening)
                            .accessibilityIdentifier("git.pr.basePicker")
                        } else { branch(t("git.pr.into"), value: result?.base.ref ?? draft.base) }
                    }
                    if let result {
                        Section {
                            Label(t("git.pr.ready", ["number": "\(result.number)"]), icon: .gitPullRequest)
                                .font(.subheadline.weight(.medium))
                            Text(result.title).font(.body)
                            if result.draft { Text(t("git.pr.draft")).font(.caption).foregroundStyle(.secondary) }
                            Link(t("git.pr.view"), destination: result.htmlURL).tint(.primary)
                        }
                    } else {
                        comparisonSection
                        localChangesSection
                        Section {
                            TextField(t("git.pr.titlePlaceholder"), text: $draft.title, axis: .vertical)
                                .font(.body.weight(.medium)).lineLimit(1...3)
                                .focused($editing).accessibilityIdentifier("git.pr.titleField")
                            TextField(t("git.pr.descriptionPlaceholder"), text: $draft.body, axis: .vertical)
                                .lineLimit(4...8).focused($editing)
                                .accessibilityIdentifier("git.pr.bodyField")
                        } header: { Text(t("git.pr.details")) }
                        .disabled(opening)
                        Section {
                            Toggle(t("git.pr.draft"), isOn: $draft.draft).disabled(opening)
                        }
                    }
                } else {
                    Section { Text(t("git.pr.unavailable")).foregroundStyle(.secondary) }
                }
                if let preparationError {
                    Section {
                        Text(preparationError).font(.footnote).foregroundStyle(.secondary)
                        Button(t("common.retry")) { reload() }
                            .disabled(loadingDetails)
                    }
                }
                GitOperationSections(model: model)
                if model.error != nil, !opening {
                    Section {
                        Button(t("git.refresh")) { reload() }
                            .disabled(loadingDetails)
                    }
                }
                if preparationError != nil || model.error != nil, let projectId = model.projectId {
                    Section {
                        NavigationLink {
                            GitAccessSettingsScreen(workspaceId: model.workspaceId, projectId: projectId)
                        } label: { Label(t("github.access.title"), icon: .key) }
                    }
                }
            }
            .listStyle(.insetGrouped).listSectionSpacing(.compact)
            .contentMargins(.top, Spacing.sm, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(t("git.pr.sheetTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t(result == nil ? "common.cancel" : "common.done")) { dismiss() }
                        .tint(.primary).disabled(opening)
                }
                if let context, result == nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            guard !opening else { return }
                            editing = false
                            opening = true
                            Task {
                                defer { opening = false }
                                result = await model.createPullRequest(context, draft: draft, comparison: comparison)
                            }
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                if opening { ProgressView().controlSize(.small).tint(Palette.onAccent) }
                                Text(t(comparison?.needsPush == true ? "git.pr.pushCreate" : "git.pr.create"))
                                    .font(.body.weight(.semibold)).foregroundStyle(Palette.onAccent)
                            }
                            .frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .disabled(opening || loadingDetails || loadingComparison || preparationError != nil || !draft.isValid
                                  || !comparisonIsCurrent || comparison?.commitCount == 0 || comparison?.truncated == true
                                  || draft.base == context.branch || model.isMutating || model.hasPendingOperation)
                        .accessibilityIdentifier("git.pr.create")
                    }
                }
            }
            .toolbarBackground(.visible, for: .bottomBar)
            .navigationDestination(for: GitPullRequestComparison.self) { comparison in
                GitPullRequestFilesScreen(model: model, comparison: comparison)
            }
            .navigationDestination(for: GitDiffRoute.self) { route in
                GitDiffScreen(model: model, change: route.change, staged: route.staged,
                              commit: route.commit, comparison: route.comparison)
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(opening)
        .sheet(isPresented: $showingCommit, onDismiss: { reload(refreshRepository: false) }) {
            GitCommitSheet(model: model, message: $commitMessage)
        }
        .task(id: refreshID) { await loadDetails(refreshRepository: refreshRepository) }
        .task(id: previewRequest) { await loadComparison(previewRequest) }
    }

    private struct ComparisonRequest: Hashable {
        let context: GitPullRequestContext
        let base: String
        let baseHead: String
        let remoteHead: String?
    }

    private var comparisonRequest: ComparisonRequest? {
        guard !loadingDetails, result == nil, let context, let baseHead = preparation?.branchHeads[draft.base] else { return nil }
        return .init(context: context, base: draft.base, baseHead: baseHead,
                     remoteHead: preparation?.branchHeads[context.branch])
    }

    private var comparisonIsCurrent: Bool {
        guard let comparison, let request = comparisonRequest else { return false }
        return comparison.head == request.context.head && comparison.baseBranch == request.base
            && comparison.baseHead == request.baseHead && comparison.remoteHead == request.remoteHead
            && request.context.matches(model.status)
    }

    @ViewBuilder private var comparisonSection: some View {
        Section {
            if let comparison, comparisonIsCurrent {
                if comparison.files.isEmpty {
                    Text(t("git.pr.noCommittedChanges")).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    NavigationLink(value: comparison) {
                        HStack {
                            Text(t(comparison.files.count == 1 ? "git.filesChanged.one" : "git.filesChanged",
                                   ["count": "\(comparison.files.count)"])).font(.subheadline.weight(.medium))
                            Spacer(minLength: Spacing.sm)
                            GitDiffStats(additions: comparison.counts.additions, deletions: comparison.counts.deletions)
                        }
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("git.pr.reviewFiles")
                }
                HStack {
                    Text(t(comparison.commitCount == 1 ? "git.pr.commitCount.one" : "git.pr.commitCount",
                           ["count": "\(comparison.commitCount)"]))
                    Spacer(minLength: Spacing.sm)
                    Text(t(comparison.needsPush ? "git.pr.publishFirst" : "git.pr.pushed"))
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("git.pr.publishState")
                if comparison.truncated { Text(t("git.history.truncated")).font(.footnote).foregroundStyle(.secondary) }
            } else if let comparisonError {
                Text(comparisonError.localizedDescription).font(.footnote).foregroundStyle(.secondary)
                if comparisonError is GitPullRequestPreviewError {
                    Button(t("git.pr.fetchBranches")) {
                        Task {
                            if await model.runRemote(.fetch) { reload(refreshRepository: false) }
                        }
                    }
                    .disabled(model.isMutating || model.hasPendingOperation)
                } else { Button(t("common.retry")) { reload() }.disabled(loadingDetails) }
            } else if loadingDetails || loadingComparison {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(t("git.pr.comparing")).font(.subheadline).foregroundStyle(.secondary)
                }
            } else if context?.matches(model.status) == false {
                Text(t("git.pr.changed")).font(.footnote).foregroundStyle(.secondary)
                Button(t("git.refresh")) { reload() }
            }
        } header: { Text(t("git.pr.comparisonBase", ["base": draft.base])) }
    }

    @ViewBuilder private var localChangesSection: some View {
        if !model.staged.isEmpty || !model.unstaged.isEmpty {
            Section {
                if !model.staged.isEmpty {
                    DisclosureGroup(isExpanded: $stagedExpanded) {
                        ForEach(model.staged) { change in
                            GitFileRow(model: model, change: change, staged: true)
                        }
                    } label: {
                        Text(t("git.stagedCount", ["count": "\(model.staged.count)"])).font(.subheadline)
                    }
                    .tint(.primary).accessibilityIdentifier("git.pr.staged")
                }
                if !model.unstaged.isEmpty {
                    DisclosureGroup(isExpanded: $workingExpanded) {
                        ForEach(model.unstaged) { change in
                            GitFileRow(model: model, change: change, staged: false)
                        }
                    } label: {
                        Text(t("git.pr.workingCount", ["count": "\(model.unstaged.count)"])).font(.subheadline)
                    }
                    .tint(.primary)
                }
                Button(t("git.pr.reviewCommit")) { showingCommit = true }
                    .disabled(opening || model.isMutating)
                    .accessibilityIdentifier("git.pr.reviewCommit")
            } header: { Text(t("git.pr.notCommitted")) }
              footer: { Text(t("git.pr.localExcluded")) }
            .disabled(opening)
        }
    }

    @MainActor private func reload(refreshRepository: Bool = true) {
        self.refreshRepository = refreshRepository
        refreshID += 1
    }

    @MainActor private func loadComparison(_ request: ComparisonRequest?) async {
        guard !Task.isCancelled, comparisonRequest == request else { return }
        comparison = nil; comparisonError = nil
        guard let request else { loadingComparison = false; return }
        loadingComparison = true
        defer { if comparisonRequest == request { loadingComparison = false } }
        do {
            let value = try await model.pullRequestComparison(request.context, base: request.base,
                baseHead: request.baseHead, remoteHead: request.remoteHead)
            try Task.checkCancellation()
            guard comparisonRequest == request else { return }
            comparison = value
        } catch {
            if !Task.isCancelled, !error.isRequestCancellation, comparisonRequest == request { comparisonError = error }
        }
    }

    private var baseBranches: [String] {
        Array(Set((preparation?.branches ?? []) + [draft.base])).filter { !$0.isEmpty && $0 != context?.branch }.sorted()
    }

    @MainActor private func loadDetails(refreshRepository: Bool = false) async {
        guard !opening, !Task.isCancelled else { return }
        loadingDetails = true
        preparationError = nil
        defer { if !Task.isCancelled { loadingDetails = false } }
        if refreshRepository {
            await model.refresh()
            guard !Task.isCancelled else { return }
        }
        guard let current = model.pullRequestContext, current.isFeatureBranch else {
            context = nil
            loadingDetails = false
            return
        }
        context = current
        if draft.title.isEmpty { draft.title = String(current.title.prefix(256)) }
        if draft.base.isEmpty { draft.base = current.baseBranch ?? "" }
        do {
            let details = try await model.preparePullRequest(current)
            try Task.checkCancellation()
            preparation = details
            guard current.matches(model.status) else { throw BackendError.message(t("git.pr.changed")) }
            if draft.base.isEmpty || details.branchHeads[draft.base] == nil { draft.base = details.defaultBranch }
            result = details.existing
        } catch {
            if !Task.isCancelled && !error.isRequestCancellation { preparationError = error.localizedDescription }
        }
    }

    private func branch(_ label: String, value: String) -> some View {
        LabeledContent {
            Text(value).font(.subheadline).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
        } label: { Text(label).font(.subheadline).foregroundStyle(.secondary) }
    }
}

private struct GitPullRequestFilesScreen: View {
    let model: GitModel
    let comparison: GitPullRequestComparison

    var body: some View {
        List {
            Section {
                ForEach(comparison.files) { change in
                    GitFileRow(model: model, change: change, staged: true, comparison: comparison)
                }
            } header: {
                HStack {
                    Text(t("git.pr.comparisonBase", ["base": comparison.baseBranch]))
                    Spacer()
                    GitDiffStats(additions: comparison.counts.additions, deletions: comparison.counts.deletions)
                }
            }
        }
        .listStyle(.insetGrouped).listSectionSpacing(.compact)
        .accessibilityIdentifier("git.pr.files")
        .navigationTitle(t("git.pr.filesTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .bottomBar)
    }
}

/// The same compact action in the repository header and the remote-actions sheet.
struct GitPullRequestButton: View {
    let model: GitModel
    var spacing: CGFloat = Spacing.md
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: spacing) {
                AppIcon(.gitPullRequest, size: 22).foregroundStyle(Palette.accent).accessibilityHidden(true)
                Text(t("git.pr.title")).font(.subheadline.weight(.medium))
                Spacer(minLength: Spacing.sm)
                AppIcon(.chevronRight).font(.caption.weight(.medium)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 32)
        }
        .tint(.primary)
        .disabled(model.isMutating || model.openingPullRequest || model.hasPendingOperation)
        .accessibilityIdentifier("git.openPullRequest")
    }
}
