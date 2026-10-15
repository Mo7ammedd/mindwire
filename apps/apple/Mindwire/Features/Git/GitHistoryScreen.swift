import SwiftUI

@MainActor @Observable
final class GitHistoryState {
    private(set) var commits: [GitCommit] = []
    private(set) var next: GitHistoryCursor?
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var branch: String?
    private(set) var error: String?
    @ObservationIgnored private var generation = 0

    func refresh(_ model: GitModel) async {
        generation += 1
        let request = generation
        let branch = model.status?.branch
        loading = true
        defer { if request == generation { loading = false } }
        error = nil
        do {
            let page = try await model.history()
            guard request == generation, !Task.isCancelled else { return }
            commits = page.commits
            self.branch = branch
            next = page.next
            loaded = true
        } catch { if request == generation && !Task.isCancelled && !error.isRequestCancellation { self.error = error.localizedDescription } }
    }

    func loadMore(_ model: GitModel) async {
        guard !loading, let cursor = next else { return }
        let request = generation
        loading = true
        defer { if request == generation { loading = false } }
        error = nil
        do {
            let page = try await model.history(cursor: cursor)
            guard request == generation, !Task.isCancelled else { return }
            let seen = Set(commits.map(\.id))
            commits.append(contentsOf: page.commits.filter { !seen.contains($0.id) })
            next = page.next
        } catch { if request == generation && !Task.isCancelled && !error.isRequestCancellation { self.error = error.localizedDescription } }
    }
}

struct GitHistoryScreen: View {
    let model: GitModel
    @State private var history = GitHistoryState()

    var body: some View {
        List {
            if history.commits.isEmpty {
                if history.loading {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
            } else {
                Section(history.branch ?? t("git.detached")) {
                    ForEach(history.commits) { commit in
                        NavigationLink(value: commit) {
                            GitCommitRow(commit: commit)
                        }
                    }
                }
            }
            if let error = history.error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button(t("common.retry")) {
                        Task {
                            if history.loaded && history.next != nil { await history.loadMore(model) }
                            else { await history.refresh(model) }
                        }
                    }
                } header: { Text(t("git.history.failed")) }
            } else if history.next != nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    .onAppear { Task { await history.loadMore(model) } }
                    .id(history.next)
            }
        }
        .overlay {
            if history.loaded && history.commits.isEmpty && history.error == nil {
                GitEmptyState(title: t("git.history.empty"), message: t("git.history.empty.body"))
                    .padding(.horizontal, Spacing.xl)
                    .allowsHitTesting(false)
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle(t("git.history.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .bottomBar)
        .refreshable { await history.refresh(model) }
        .task(id: model.status?.branch) {
            if !history.loaded || history.branch != model.status?.branch { await history.refresh(model) }
        }
    }
}

struct GitCommitRow: View {
    let commit: GitCommit
    var expandsSubject = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(commit.subject).font(.subheadline.weight(.medium)).lineLimit(expandsSubject ? nil : 2)
            HStack(spacing: Spacing.sm) {
                Text(commit.authorName).lineLimit(1)
                Spacer(minLength: 0)
                Text(commit.date, style: .date).lineLimit(1)
                Text(commit.shortID).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("git.history.\(commit.id)")
    }
}

struct GitCommitScreen: View {
    let model: GitModel
    let commit: GitCommit
    var onRestored: () -> Void = {}
    @State private var details: GitCommitDetails?
    @State private var loading = true
    @State private var error: String?
    @State private var restorePlan: GitRestorePlan?
    @State private var preparingRestore = false

    var body: some View {
        List {
            Section {
                GitCommitRow(commit: commit, expandsSubject: true)
                    .textSelection(.enabled)
                if let details, details.message != commit.subject, !details.message.isEmpty {
                    DisclosureGroup(t("git.history.message")) {
                        Text(details.message).font(.subheadline).textSelection(.enabled)
                    }
                    .tint(.primary)
                }
            } footer: {
                if commit.parents.count > 1 {
                    Text(t("git.history.merge", ["parent": String(commit.parents[0].prefix(8))]))
                }
            }
            GitOperationSections(model: model)
            if loading {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button(t("common.retry")) { Task { await load() } }
                } header: { Text(t("git.history.changesFailed")) }
            } else if let details {
                if details.files.isEmpty {
                    GitEmptyState(title: t("git.history.noFiles"))
                        .padding(.vertical, Spacing.xl)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(details.files) { change in
                            GitFileRow(model: model, change: change, staged: true, commit: commit)
                        }
                    } header: {
                        let counts = details.files.reduce(into: GitLineStat()) { total, file in
                            total.additions += file.staged?.additions ?? 0
                            total.deletions += file.staged?.deletions ?? 0
                        }
                        HStack {
                            Text(t(details.files.count == 1 ? "git.filesChanged.one" : "git.filesChanged",
                                   ["count": "\(details.files.count)"]))
                            Spacer()
                            GitDiffStats(additions: counts.additions, deletions: counts.deletions)
                        }
                    }
                }
                if details.truncated {
                    Section { Text(t("git.history.truncated")).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle(commit.shortID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .bottomBar)
        .toolbar {
            AppToolbarItem(placement: .topBarTrailing) {
                AppMenu {
                    Button {
                        Task {
                            preparingRestore = true
                            defer { preparingRestore = false }
                            restorePlan = await model.prepareRestore(commit)
                        }
                    } label: { Label(t("git.restore.action"), icon: .undo) }
                    .disabled(model.isMutating || model.status?.head == commit.id)
                    Button { UIPasteboard.general.string = commit.id } label: {
                        Label(t("git.history.copyID"), icon: .copy)
                    }
                } label: {
                    if preparingRestore { ProgressView().controlSize(.small) }
                    else { AppIcon(.more) }
                }
                .tint(.primary)
                .accessibilityLabel(t("git.history.actions"))
                .accessibilityIdentifier("git.commitActions")
            }
        }
        .alert(t("git.restore.title"), isPresented: Binding(
            get: { restorePlan != nil }, set: { if !$0 { restorePlan = nil } }
        ), presenting: restorePlan) { plan in
            Button(t("git.restore.confirm")) {
                restorePlan = nil
                Task { if await model.restore(plan) { onRestored() } }
            }
            Button(t("common.cancel"), role: .cancel) { restorePlan = nil }
        } message: { plan in
            Text(t("git.restore.body", ["id": plan.commit.shortID, "branch": plan.branch ?? t("git.detached")]))
        }
        .task { if details == nil { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let value = try await model.commitDetails(commit)
            try Task.checkCancellation()
            details = value
            error = nil
        } catch { if !Task.isCancelled && !error.isRequestCancellation { self.error = error.localizedDescription } }
    }
}
