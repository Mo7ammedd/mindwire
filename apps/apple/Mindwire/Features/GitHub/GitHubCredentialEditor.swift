import SwiftUI

struct GitHubCredentialEditor: View {
    let onSaved: (GitHubAccount) -> Void
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var model: GitHubCredentialEditorModel
    @State private var showHelp = false
    @State private var operation: Task<Void, Never>?

    init(mode: GitHubAuthMode, account: GitHubAccount? = nil, onSaved: @escaping (GitHubAccount) -> Void) {
        self.onSaved = onSaved
        _model = State(initialValue: GitHubCredentialEditorModel(mode: mode, account: account))
    }

    var body: some View {
        Form {
            Section(t("github.credential.name")) {
                TextField(t("github.credential.namePlaceholder"), text: $model.name)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("github.credential.name")
            }
            if model.mode == .token { tokenSection }
            if model.mode == .sshKey { sshSections }
            if model.hasSecret {
                Section {
                    Button {
                        operation = Task { await model.test() }
                    } label: {
                        HStack {
                            Label(t("github.credential.test"), icon: .network)
                                .foregroundStyle(.primary)
                            Spacer()
                            if model.working { ProgressView().controlSize(.small) }
                        }
                    }
                    .tint(.primary).disabled(!model.canTest)
                    .accessibilityIdentifier("github.credential.test")
                    if let report = model.report { GitHubCredentialReportView(report: report) }
                    if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
                } footer: {
                    Text(t(model.account == nil ? "github.credential.checkBeforeSave" : "github.credential.editHint"))
                }
            } else if let error = model.error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .disabled(model.working)
        .navigationTitle(model.account == nil ? model.mode.title : t("github.credential.edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.account != nil {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { operation?.cancel(); dismiss() }.tint(.primary)
                }
            }
            if model.hasSecret {
                AppToolbarItem(placement: .topBarTrailing) {
                    Button { showHelp = true } label: { AppIcon(.info) }
                        .tint(.primary).accessibilityLabel(t("github.credential.help"))
                }
            }
            AppToolbarItem(placement: .confirmationAction) {
                Button(t(model.account == nil ? "github.credential.add" : "common.save")) {
                    operation = Task {
                        if let account = await model.save(stores: stores) { onSaved(account) }
                    }
                }
                .disabled(!model.canSave).tint(.primary)
                .accessibilityIdentifier("github.credential.save")
            }
        }
        .sheet(isPresented: $showHelp) {
            GitHubCredentialHelpSheet(mode: model.mode, name: model.trimmedName)
        }
        .onDisappear { operation?.cancel() }
    }

    private var tokenSection: some View {
        Section {
            GitHubSecretField(title: t("github.connect.token.placeholder"), text: $model.secret)
                .accessibilityIdentifier("github.credential.secret")
            AppMenu {
                Link(t("github.credential.fineGrained"), destination: GitHubCredentialLinks.token(name: model.trimmedName))
                Link(t("github.credential.classic"), destination: GitHubCredentialLinks.token(name: model.trimmedName, classic: true))
            } label: {
                Label(t("github.credential.createToken"), icon: .arrowUpRight)
                    .foregroundStyle(.primary)
            }
            .tint(.primary)
        } header: { Text(model.mode.title) }
    }

    @ViewBuilder private var sshSections: some View {
        if model.account == nil {
            Section {
                Picker(model.mode.title, selection: $model.keySource) {
                    Text(t("github.connect.sshKey.generate")).tag(GitHubCredentialEditorModel.KeySource.generate)
                    Text(t("github.connect.sshKey.existing")).tag(GitHubCredentialEditorModel.KeySource.existing)
                }
                .pickerStyle(.segmented)
            }
        }
        if !model.usesGeneratedKey {
            Section {
                GitHubSecretField(title: t("github.connect.sshKey.paste.placeholder"), text: $model.secret, multiline: true)
                    .accessibilityIdentifier("github.credential.secret")
            } header: { Text(t("github.credential.privateKey")) }
              footer: { Text(t("github.credential.keyFormat")) }
        }
        GitHubPublicKeySection(secret: model.value)
    }
}
