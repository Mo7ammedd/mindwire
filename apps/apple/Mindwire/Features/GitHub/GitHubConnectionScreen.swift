import SwiftUI

struct GitHubConnectionScreen: View {
    let account: GitHubAccount
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var current: GitHubAccount
    @State private var report: GitHubCredentialReport?
    @State private var working = false
    @State private var error: String?
    @State private var showEditor = false
    @State private var showHelp = false
    @State private var confirmRemove = false
    @State private var operation: Task<Void, Never>?

    init(account: GitHubAccount) {
        self.account = account
        _current = State(initialValue: account)
    }

    private var secret: String? { GitHubCredentialService.secret(for: current) }
    private var hasSecret: Bool { current.mode == .token || current.mode == .sshKey }

    var body: some View {
        List {
            Section {
                LabeledContent(t("github.credential.name"), value: current.displayName)
                LabeledContent(t("github.credential.method"), value: current.mode.title)
                if current.mode != .sshKey {
                    LabeledContent(t("github.credential.account"), value: "@\(current.login)")
                }
                if let date = current.addedDate {
                    LabeledContent(t("github.credential.added")) { Text(date, style: .date) }
                }
            }
            if hasSecret {
                Section(current.mode == .token ? current.mode.title : t("github.credential.privateKey")) {
                    GitHubSecretValue(secret: secret).id(current.lastCheck)
                }
            }
            Section {
                Button { operation = Task { await test() } } label: {
                    HStack {
                        Label(t("github.credential.test"), icon: .network)
                            .foregroundStyle(.primary)
                        Spacer()
                        if working { ProgressView().controlSize(.small) }
                    }
                }
                .tint(.primary).disabled(working)
                if let report { GitHubCredentialReportView(report: report) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                if let check = current.lastCheck, let date = check.date {
                    LabeledContent(t(check.succeeded ? "github.credential.lastTestPassed" : "github.credential.lastTestFailed")) {
                        Text(date, style: .relative)
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if current.mode == .sshKey, let secret {
                GitHubPublicKeySection(secret: secret)
            } else if current.mode != .sshKey {
                Section {
                    NavigationLink(t("github.credential.browse")) {
                        GitHubConnectionRepositoriesScreen(account: current)
                    }
                }
            }
            Section {
                DestructiveButton(t("github.accounts.removeLocal"), icon: Icon.trash) { confirmRemove = true }
                .disabled(working)
            }
        }
        .navigationTitle(current.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasSecret {
                AppToolbarItem(placement: .topBarTrailing) {
                    Button { showHelp = true } label: { AppIcon(.info) }
                        .tint(.primary).accessibilityLabel(t("github.credential.help"))
                }
            }
            AppToolbarItem(placement: .confirmationAction) {
                Button(t("common.edit")) { showEditor = true }.tint(.primary).disabled(working)
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .gitHubAccountsChanged, object: stores)) { _ in reload() }
        .onDisappear { operation?.cancel() }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                GitHubCredentialEditor(mode: current.mode, account: current) { _ in
                    report = nil; error = nil; reload(); showEditor = false
                }
            }
        }
        .sheet(isPresented: $showHelp) { GitHubCredentialHelpSheet(mode: current.mode, name: current.displayName) }
        .alert(t("github.credential.removeTitle", ["name": current.displayName]), isPresented: $confirmRemove) {
            Button(t("common.cancel"), role: .cancel) {}
            Button(t("github.accounts.removeLocal"), role: .destructive) {
                if stores.removeGitHubAccount(current.id) { dismiss() }
                else { error = t("github.credential.removeFailed") }
            }
        } message: { Text(t("github.credential.removeHint")) }
    }

    private func reload() {
        if let saved = stores.github.get(account.id) { current = saved }
        else { dismiss() }
    }

    private func test() async {
        guard !working else { return }
        working = true; error = nil; report = nil
        defer { working = false }
        do {
            let result: GitHubCredentialReport
            if hasSecret {
                guard let secret, !secret.isEmpty else { throw BackendError.message(t("github.credential.secretMissing")) }
                result = try await GitHubCredentialService().test(mode: current.mode, secret: secret)
                try Task.checkCancellation()
                guard let saved = stores.github.get(current.id), GitHubCredentialService.secret(for: saved) == secret else {
                    throw CancellationError()
                }
                if current.mode == .token, let user = result.user {
                    try stores.replaceGitHubToken(accountId: current.id, user: user, token: secret)
                }
            } else if current.mode == .ghCli, let workspaceId = current.workspaceId {
                let user = try await GhCliGitHubService(stores: stores).identity(workspaceId: workspaceId)
                guard current.login.caseInsensitiveCompare(user.login) == .orderedSame else {
                    throw BackendError.message(t("github.credential.cliAccountChanged"))
                }
                result = .init(mode: .ghCli, user: user)
            } else {
                let status = try await GitHubConnectAPI().status()
                guard status.connected else { throw BackendError.message(t("github.accounts.notConnected")) }
                result = .init(mode: .oblienApp, user: .init(login: status.login ?? current.login, name: nil, avatarUrl: status.avatarUrl))
            }
            try Task.checkCancellation()
            report = result
            stores.recordGitHubCheck(current.id, succeeded: true)
        } catch is CancellationError {}
        catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            stores.recordGitHubCheck(current.id, succeeded: false)
        }
    }
}

private struct GitHubConnectionRepositoriesScreen: View {
    let account: GitHubAccount
    @Environment(\.stores) private var stores
    @State private var owners: [GitHubOwner] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if loading && owners.isEmpty { ProgressView() }
                ForEach(owners) { owner in
                    NavigationLink(owner.login) { GitHubRepoListScreen(account: account, owner: owner) }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                    Button(t("common.retry")) { Task { await load() } }.disabled(loading)
                }
            }
        }
        .navigationTitle(t("github.repos.browse"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            owners = try await BackendFactory.githubService(for: account, stores: stores).owners(for: account)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
