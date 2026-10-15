import SwiftUI

struct GitBranchSheet: View {
    let model: GitModel
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [GitBranch] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var dialog: BranchDialog?
    @State private var search = ""
    @State private var showingCreate = false
    @State private var switching: String?
    @State private var renaming: GitBranch?

    private enum BranchDialog {
        case failure(String)
        case delete(GitBranch, force: Bool)
        var title: String {
            switch self {
            case .failure: return t("git.branches.operationFailed")
            case .delete(let branch, let force):
                return t(force ? "git.branches.deleteUnmerged.title" : "git.branches.delete.title", ["name": branch.name])
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if loading && branches.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else if let loadError {
                    ContentUnavailableView {
                        Label(t("git.branches.failed"), icon: .warning)
                    } description: { Text(loadError) } actions: {
                        Button(t("common.retry")) { Task { await load() } }.buttonStyle(.glass)
                    }
                    .listRowBackground(Color.clear)
                } else if branches.isEmpty {
                    GitEmptyState(title: t("git.branches.empty"), message: t("git.branches.empty.body"))
                        .padding(.vertical, Spacing.xl)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else if filtered.isEmpty {
                    GitEmptyState(title: t("git.search.empty"), message: t("git.search.empty.body"))
                        .padding(.vertical, Spacing.xl)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    branchSection(t("git.branches.local"), items: filtered.filter { !$0.isRemote })
                    branchSection(t("git.branches.remote"), items: filtered.filter(\.isRemote))
                }
            }
            .listSectionSpacing(.compact)
            .searchable(text: $search, prompt: t("git.branches.search"))
            .navigationTitle(t("git.branches.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.done")) { dismiss() }.tint(.primary)
                }
                AppToolbarItem(placement: .topBarTrailing) {
                    Button(t("git.branches.create"), icon: .plus) { showingCreate = true }
                        .tint(.primary).disabled(model.isMutating)
                        .accessibilityIdentifier("git.branches.create")
                }
            }
            .navigationDestination(isPresented: $showingCreate) {
                GitCreateBranchScreen(model: model) { dismiss() }
            }
            .navigationDestination(item: $renaming) { branch in
                GitCreateBranchScreen(model: model, branch: branch) {
                    renaming = nil
                    Task { await load() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .alert(dialog?.title ?? "", isPresented: Binding(
                get: { dialog != nil }, set: { if !$0 { dialog = nil } }
            ), presenting: dialog) { value in
                switch value {
                case .failure:
                    Button(t("common.ok"), role: .cancel) { dialog = nil }
                case .delete(let branch, let force):
                    Button(t(force ? "git.branches.deleteUnmerged.confirm" : "common.delete"), role: .destructive) {
                        dialog = nil
                        Task { await delete(branch, force: force) }
                    }
                    Button(t("common.cancel"), role: .cancel) { dialog = nil }
                }
            } message: { value in
                switch value {
                case .failure(let message): Text(message)
                case .delete(_, let force):
                    Text(t(force ? "git.branches.deleteUnmerged.body" : "git.branches.delete.body"))
                }
            }
        }
    }

    private var filtered: [GitBranch] {
        search.isEmpty ? branches : branches.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder private func branchSection(_ title: String, items: [GitBranch]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { branch in
                    HStack(spacing: Spacing.md) {
                        Button { Task { await select(branch) } } label: {
                            HStack(spacing: Spacing.md) {
                                Text(branch.name).font(.subheadline).foregroundStyle(.primary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: Spacing.sm)
                                if switching == branch.id { ProgressView().controlSize(.small) }
                                else if !branch.isRemote && branch.name == model.status?.branch {
                                    Text(t("git.branches.current.short")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("git.branch.\(branch.id)")
                        if !branch.isRemote {
                            AppMenu { branchActions(branch) } label: {
                                AppIcon(.more).foregroundStyle(.secondary)
                                    .frame(width: 32, height: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(t("git.branches.actions", ["name": branch.name]))
                            .accessibilityIdentifier("git.branchActions.\(branch.name)")
                        }
                    }
                    .tint(.primary)
                    .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg))
                    .appContextMenu { if !branch.isRemote { branchActions(branch) } }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !branch.isRemote && branch.name != model.status?.branch {
                            Button(role: .destructive) { dialog = .delete(branch, force: false) } label: {
                                Label(t("common.delete"), icon: Icon.trash)
                            }
                        }
                    }
                    .disabled(model.isMutating || loading)
                }
            }
        }
    }

    @ViewBuilder private func branchActions(_ branch: GitBranch) -> some View {
        if branch.name != model.status?.branch {
            Button { Task { await select(branch) } } label: {
                Label(t("git.branches.switch"), icon: .gitBranch)
            }
        }
        Button { renaming = branch } label: { Label(t("common.rename"), icon: Icon.edit) }
        Divider()
        DestructiveButton(t("git.branches.delete.action"), icon: Icon.trash) {
            dialog = .delete(branch, force: false)
        }
        .disabled(branch.name == model.status?.branch)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await model.branches()
            try Task.checkCancellation()
            branches = result
            loadError = nil
        } catch { if !Task.isCancelled { loadError = error.localizedDescription } }
    }

    private func select(_ branch: GitBranch) async {
        guard !model.isMutating, !loading else { return }
        // Reuse an existing tracking branch instead of trying to create it twice.
        let target = branch.isRemote ? branches.first { !$0.isRemote && $0.upstream == branch.name } ?? branch : branch
        if !target.isRemote && target.name == model.status?.branch { dismiss(); return }
        switching = branch.id
        defer { switching = nil }
        if await model.switchBranch(target) { dismiss() }
        else { dialog = .failure(model.error ?? t("git.operation.failed")) }
    }

    private func delete(_ branch: GitBranch, force: Bool) async {
        guard !model.isMutating, !loading else { return }
        switching = branch.id
        defer { switching = nil }
        if await model.deleteBranch(branch, force: force) { await load() }
        else if model.errorCode == "git_branch_unmerged", !force {
            dialog = .delete(branch, force: true)
        } else {
            dialog = .failure(model.error ?? t("git.operation.failed"))
            await load()
        }
    }
}

struct GitCreateBranchScreen: View {
    let model: GitModel
    var branch: GitBranch? = nil
    var onCreated: () -> Void
    @State private var name = ""
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var renaming: Bool { branch != nil }

    var body: some View {
        Form {
            Section(t("git.branches.name")) {
                TextField(t("git.branches.placeholder"), text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused).submitLabel(.done)
                    .onSubmit { create() }
                    .accessibilityIdentifier("git.branchName")
            }
            Section {
                LabeledContent(t(renaming ? "git.branches.rename.from" : "git.branches.from"),
                               value: branch?.name ?? model.status?.branch ?? t("git.detached"))
            } footer: { Text(t(renaming ? "git.branches.rename.body" : "git.branches.create.body")) }
        }
        .navigationTitle(t(renaming ? "git.branches.rename" : "git.branches.create"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppToolbarItem(placement: .confirmationAction) {
                Button(action: create) {
                    if model.activeAction == (renaming ? .renameBranch : .createBranch) { ProgressView().controlSize(.small) }
                    else { Text(t(renaming ? "common.rename" : "common.create")) }
                }
                .tint(.primary)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == branch?.name || model.isMutating)
                .accessibilityIdentifier("git.createBranch.confirm")
            }
        }
        .task { if name.isEmpty { name = branch?.name ?? "" }; focused = true }
        .alert(t("git.branches.operationFailed"), isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button(t("common.ok"), role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func create() {
        guard !model.isMutating, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        focused = false
        Task {
            let saved: Bool
            if let branch { saved = await model.renameBranch(branch, to: name) }
            else { saved = await model.createBranch(name) }
            if saved { onCreated() }
            else { failure = model.error ?? t("git.operation.failed") }
        }
    }
}
