import SwiftUI

/// Browsing and direct entry share the same selection callback and credential rules.
struct GitHubReposScreen: View {
    let workspaceId: String
    var onClear: (() -> Void)?
    var showsCancel: Bool
    var commitOnTap: Bool
    var onPick: (GitHubAccount?, GitHubRepo) -> Void

    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var model: GitHubRepoPickerModel
    @State private var showLogin = false
    @State private var showConnect = false
    @State private var managingAccount: GitHubAccount?

    init(workspaceId: String, onClear: (() -> Void)? = nil, showsCancel: Bool = true,
         commitOnTap: Bool = false, selectedRepo: GitHubRepo? = nil, selectedAccount: GitHubAccount? = nil,
         model: GitHubRepoPickerModel? = nil,
         onPick: @escaping (GitHubAccount?, GitHubRepo) -> Void) {
        self.workspaceId = workspaceId
        self.onClear = onClear
        self.showsCancel = showsCancel
        self.commitOnTap = commitOnTap
        self.onPick = onPick
        _model = State(initialValue: model ?? GitHubRepoPickerModel(selectedRepo: selectedRepo, selectedAccount: selectedAccount))
    }

    var body: some View {
        NavigationStack {
            searchableRepositories
                .navigationTitle(t("github.repos.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if showsCancel {
                        AppToolbarItem(placement: .cancellationAction) {
                            Button(t("common.cancel")) { dismiss() }.tint(.primary)
                        }
                    }
                    if model.mode == .link || !commitOnTap {
                        AppToolbarItem(placement: .confirmationAction) {
                            Button(t("github.repos.select"), action: commitSelection)
                                .tint(.primary).disabled(!model.canSelect)
                                .accessibilityIdentifier("github.selectRepository")
                        }
                    }
                }
        }
        // Mode changes only change presentation. They never discard input or restart a listing.
        .onAppear { model.reloadAccounts(stores.gitHubAccounts(), workspaceId: workspaceId) }
        .task(id: "\(model.browseAccount?.id ?? ""):\(model.refreshID)") { await model.loadOwners(stores: stores) }
        .task(id: model.ownerID) { await model.loadRepos(stores: stores) }
        .task(id: "\(model.linkAccount?.id ?? ""):\(model.refreshID)") { await model.checkLinkAccess() }
        .sheet(isPresented: $showConnect) {
            GitHubConnectScreen(workspaceId: workspaceId) { connection in
                model.reloadAccounts(stores.gitHubAccounts(), workspaceId: workspaceId, preferred: connection.id)
                model.refreshID += 1
            }
        }
        .mindwireSignIn(isPresented: $showLogin) { model.refreshID += 1 }
        .sheet(item: $managingAccount, onDismiss: {
            model.reloadAccounts(stores.gitHubAccounts(), workspaceId: workspaceId)
            model.refreshID += 1
        }) { account in
            NavigationStack {
                GitHubConnectionScreen(account: account)
                    .toolbar {
                        AppToolbarItem(placement: .cancellationAction) {
                            Button(t("common.done")) { managingAccount = nil }.tint(.primary)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var searchableRepositories: some View {
        if model.mode == .repositories, model.browseAccount != nil {
            repositoryList
                .searchable(text: $model.query, prompt: t("github.repos.search"))
                .refreshable { model.refreshID += 1 }
        } else {
            repositoryList
        }
    }

    private var repositoryList: some View {
        List {
            Section {
                Picker(t("github.repos.source"), selection: $model.mode) {
                    Text(t("github.repos.browse")).tag(GitHubRepoPickerModel.Mode.repositories)
                    Text(t("github.repos.link")).tag(GitHubRepoPickerModel.Mode.link)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("github.repositorySource")
            }
            if model.mode == .link { linkSections }
            else { browseSections }
            if let onClear {
                Section { Button(t("project.repo.clear"), role: .destructive) { onClear(); dismiss() } }
            }
        }
    }

    private var linkSections: some View {
        Group {
            Section {
                TextField(t("github.repos.linkPlaceholder"), text: $model.repositoryInput, axis: .vertical)
                    .lineLimit(1...3)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(commitSelection)
                    .accessibilityIdentifier("github.repositoryLink")
                if let repo = model.inputRepository {
                    Label {
                        Text(repo.fullName).lineLimit(2)
                    } icon: {
                        Image("provider-github").renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("github.repositoryPreview")
                }
            } header: {
                Text(t("github.repos.link"))
            } footer: {
                if model.inputRepository == nil {
                    Text(t(model.repositoryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                           ? "github.repos.linkHint" : "github.repos.invalidURL"))
                }
            }
            Section {
                if model.accounts.isEmpty && model.linkAccountID == GitHubRepoPickerModel.publicAccountID {
                    LabeledContent(t("github.repos.access"), value: t("github.repos.public"))
                    Button(t("github.connect.connect.cta")) { showConnect = true }
                } else {
                    connectionMenu(forLink: true)
                }
                if model.checkingLinkAccess { ProgressView() }
                else if model.needsLinkLogin {
                    Button(t("github.access.signInOblien")) { showLogin = true }
                }
            } footer: {
                Text(t(model.linkAccountMissing ? "github.accounts.tokenMissing"
                       : model.linkAccount == nil ? "github.repos.publicHint" : "github.repos.accessHint"))
            }
        }
    }

    @ViewBuilder
    private var browseSections: some View {
        if model.browseAccounts.isEmpty {
            Section {
                ContentUnavailableView {
                    Label {
                        Text(t("github.repos.noAccounts.title"))
                    } icon: {
                        Image("provider-github").renderingMode(.template)
                    }
                } description: {
                    Text(t("github.repos.noAccounts.body"))
                } actions: {
                    Button(t("github.connect.connect.cta")) { showConnect = true }
                        .buttonStyle(.glassProminent)
                }
            }
            .listRowBackground(Color.clear)
        } else {
            Section {
                connectionMenu(forLink: false)
                if model.owners.count > 1 {
                    Picker(t("github.repos.owner"), selection: $model.ownerID) {
                        ForEach(model.owners) { Text($0.login).tag($0.id) }
                    }
                }
            }
            Section {
                if model.loadingOwners || model.loadingRepos {
                    ProgressView()
                } else if model.needsBrowseLogin {
                    Button(t("github.access.signInOblien")) { showLogin = true }
                } else if let error = model.error {
                    Text(error).foregroundStyle(.red)
                    Button(t("common.retry")) { model.refreshID += 1 }
                } else if model.owners.isEmpty && model.browseAccount?.mode == .oblienApp {
                    Button(t("github.connect.install.cta")) { showConnect = true }
                    Text(t("github.repos.noInstalls.body")).font(.footnote).foregroundStyle(.secondary)
                } else if model.visibleRepos.isEmpty {
                    if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView.search(text: model.query)
                    } else {
                        Text(t("github.repos.empty")).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.visibleRepos) { repo in
                        Button {
                            model.picked = repo
                            if commitOnTap { commitSelection() }
                        } label: {
                            HStack {
                                GitHubRepoRow(repo: repo)
                                Spacer(minLength: Spacing.sm)
                                if model.picked?.id == repo.id {
                                    AppIcon(Icon.checkmark).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.primary)
                        .accessibilityAddTraits(model.picked?.id == repo.id ? .isSelected : [])
                    }
                }
            } header: {
                Text(model.owners.count > 1 || model.ownerID.isEmpty ? t("github.repos.browse") : model.ownerID)
            }
        }
    }

    /// Keep account names compact in the form; the native menu includes credential methods
    /// and account management without taking another row away from the repository list.
    private func connectionMenu(forLink: Bool) -> some View {
        let title = t(forLink ? "github.repos.access" : "github.accounts.connection")
        let account = forLink ? model.linkAccount : model.browseAccount
        let value = account?.displayName ?? t(model.linkAccountMissing ? "github.repos.missingConnection" : "github.repos.public")
        return AppMenu {
            Picker(title, selection: forLink ? $model.linkAccountID : $model.browseAccountID) {
                if forLink {
                    Text(t("github.repos.public")).tag(GitHubRepoPickerModel.publicAccountID)
                    if model.linkAccountMissing {
                        Text(t("github.repos.missingConnection")).tag(model.linkAccountID)
                    }
                }
                ForEach(forLink ? model.accounts : model.browseAccounts) { Text($0.connectionLabel).tag($0.id) }
            }
            Button(t("github.credential.addConnection"), icon: .plus) { showConnect = true }
            if let account {
                Button(t("github.credential.manageConnection"), icon: .sliders) { managingAccount = account }
            }
        } label: {
            LabeledContent {
                HStack(spacing: Spacing.xs) {
                    Text(value).lineLimit(1).truncationMode(.middle)
                    AppIcon(.chevronsUpDown).font(.caption)
                }
                .foregroundStyle(.secondary)
            } label: {
                Text(title).foregroundStyle(.primary)
            }
        }
        .tint(.primary)
        .accessibilityLabel("\(title), \(account?.connectionLabel ?? value)")
    }

    private func commitSelection() {
        guard model.canSelect, let repo = model.selection else { return }
        onPick(model.selectedAccount, repo)
        dismiss()
    }
}
