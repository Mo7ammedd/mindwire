import SwiftUI

/// The message stays with Source Control when this sheet closes or a commit fails.
struct GitCommitSheet: View {
    let model: GitModel
    @Binding var message: String
    var onOpenChat: ((String, String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var showingIdentity = false
    @State private var path: [GitDiffRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    LabeledContent(t("git.branch"), value: model.status?.branch ?? t("git.detached"))
                    Button { showingIdentity = true } label: {
                        Label(t("git.identity.title"), icon: .userCircle)
                    }
                    .tint(.primary).disabled(model.isMutating)
                }
                Section {
                    TextField(t("git.commitMessage.placeholder"), text: $message, axis: .vertical)
                        .lineLimit(3...8)
                        .disabled(model.committing)
                        .accessibilityIdentifier("git.commit.message")
                } header: {
                    Text(t("git.commit.message"))
                } footer: {
                    Text(t("git.commit.stagedOnly"))
                }
                if model.hasStaged {
                    Section {
                        ForEach(model.staged) { change in
                            GitFileRow(model: model, change: change, staged: true)
                        }
                    } header: {
                        HStack {
                            Text(t("git.stagedCount", ["count": "\(model.staged.count)"]))
                            Spacer()
                            Button(t("git.unstageAll")) { Task { await model.unstageAll() } }
                                .textCase(nil).tint(.primary).disabled(model.isMutating)
                        }
                    }
                } else {
                    Section {
                        Text(t("git.commit.stageFirst")).foregroundStyle(.secondary)
                        if !model.unstaged.isEmpty {
                            Button(t("git.stageAll")) { Task { await model.stageAll() } }
                                .disabled(model.isMutating)
                        }
                    }
                }
                if !model.conflicts.isEmpty {
                    Section {
                        Label(t("git.commit.resolveConflicts"), icon: .warning)
                            .foregroundStyle(.secondary)
                    }
                }
                if model.authenticationRequired { GitAuthenticationRecoverySection(model: model) }
                if model.isMutating { Section { ProgressView(model.activeAction?.title ?? t("git.loading")) } }
            }
            .listSectionSpacing(.compact)
            .navigationTitle(t("git.commit"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: GitDiffRoute.self) { route in
                GitDiffScreen(model: model, change: route.change, staged: route.staged, onOpenChat: onOpenChat)
            }
            .navigationDestination(isPresented: $showingIdentity) {
                GitAuthorScreen(model: model) { showingIdentity = false }
            }
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.tint(.primary).disabled(model.committing)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button(t("git.commit")) {
                        Task {
                            if await model.commit(message) { message = ""; dismiss() }
                            else if model.identityRequired { showingIdentity = true }
                            else if !model.authenticationRequired, let error = model.error { failure = error }
                        }
                    }
                    .disabled(!model.hasStaged || model.isMutating || !model.conflicts.isEmpty
                              || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .tint(.primary)
                    .accessibilityIdentifier("git.commit.submit")
                }
            }
            .alert(t("git.operation.failed"), isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            )) {
                Button(t("common.ok"), role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
            .onChange(of: model.error) { _, error in
                if let error, path.isEmpty && !showingIdentity && !model.authenticationRequired { failure = error }
            }
            .task {
                if model.identityRequired {
                    if message.isEmpty { message = model.activeOperation?.message ?? "" }
                    showingIdentity = true
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.committing || model.savingAuthor)
    }
}

/// Shared by repository settings and missing-author remediation. Saving returns
/// to the previous screen; only the separate Commit button creates a commit.
struct GitAuthorScreen: View {
    let model: GitModel
    var onSaved: () -> Void
    @State private var identity = GitIdentity()
    @State private var scope: GitAuthorScope = .repository
    @State private var settings = GitAuthorSettings()
    @State private var drafts: [GitAuthorScope: GitIdentity] = [:]
    @State private var useInherited = false
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Picker(t("git.identity.scope"), selection: $scope) {
                    ForEach(GitAuthorScope.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.inline)
                .accessibilityIdentifier("git.identity.scope")
            } header: { Text(t("git.identity.scope")) }
              footer: { Text(scope.help) }
            Section {
                if scope != .allWorkspaces {
                    Toggle(t("git.identity.inherit"), isOn: $useInherited)
                }
                if !useInherited {
                TextField(t("git.identity.name"), text: $identity.name)
                    .textContentType(.name).autocorrectionDisabled()
                    .accessibilityIdentifier("git.identity.name")
                TextField(t("git.identity.email"), text: $identity.email)
                    .textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("git.identity.email")
                }
            } header: { Text(t("git.identity.author")) }
              footer: { Text(t("git.identity.body")) }
            if scope != .allWorkspaces {
                Section {
                    LabeledContent(scope.title, value: scope == .repository ? model.repositoryName : model.workspaceName)
                } footer: { Text(t("git.identity.precedence")) }
            } else {
                GitAuthorSyncSection(defaults: model.authorDefaults)
            }
            if loading { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
        }
        .listSectionSpacing(.compact)
        .disabled(loading || model.savingAuthor)
        .navigationTitle(t("git.identity.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        if await model.saveAuthor(useInherited ? nil : identity.normalized, scope: scope) {
                            onSaved()
                        } else {
                            failure = model.error ?? t("git.identity.saveFailed")
                        }
                    }
                } label: {
                    if model.savingAuthor { ProgressView().controlSize(.small) }
                    else { Text(t("git.identity.save")) }
                }
                .tint(.primary)
                .disabled(loading || (!useInherited && !identity.isValid) || model.isMutating)
                .accessibilityIdentifier("git.identity.submit")
            }
        }
        .task {
            do {
                settings = try await model.authorSettings()
                identity = settings.effective
                if !identity.isValid { identity = model.authorDefaults.preference?.identity ?? identity }
            } catch {
                if let current = try? await model.identity() { identity = current }
                failure = error.localizedDescription
            }
            loading = false
        }
        .onChange(of: scope) { old, next in
            drafts[old] = identity
            let saved = next == .allWorkspaces ? model.authorDefaults.preference?.identity ?? settings.allWorkspaces : settings.configured(next)
            identity = drafts[next] ?? saved ?? identity
            useInherited = false
        }
        .alert(t("git.identity.saveFailed"), isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button(t("common.ok"), role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
}

/// Pending delivery is visible without checking a workspace from view rendering.
struct GitAuthorSyncSection: View {
    let defaults: GitAuthorDefaults
    private var pending: [Workspace] { WorkspaceRepository.shared.all.filter { defaults.isPending($0.id) } }

    var body: some View {
        if !pending.isEmpty {
            Section {
                DisclosureGroup(t("git.identity.pendingCount", ["count": "\(pending.count)"])) {
                    ForEach(pending) { workspace in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(workspace.name).font(.subheadline)
                            Text(defaults.errors[workspace.id] ?? t("git.identity.waiting"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .tint(.primary)
        }
    }
}
