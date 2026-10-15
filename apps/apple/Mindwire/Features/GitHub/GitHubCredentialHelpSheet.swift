import SwiftUI

struct GitHubCredentialHelpSheet: View {
    let mode: GitHubAuthMode
    var name = ""
    @Environment(\.dismiss) private var dismiss
    @State private var workflows = false

    var body: some View {
        NavigationStack {
            Form {
                if mode == .token {
                    Section(t("github.credential.setup")) {
                        Text(t("github.credential.tokenInstructions"))
                        Toggle(t("github.credential.workflowAccess"), isOn: $workflows)
                    }
                    Section {
                        Link(t("github.credential.fineGrained"),
                             destination: GitHubCredentialLinks.token(name: name, workflows: workflows))
                        Link(t("github.credential.classic"),
                             destination: GitHubCredentialLinks.token(name: name, classic: true, workflows: workflows))
                    } header: { Text(t("github.credential.createToken")) }
                      footer: { Text(t("github.credential.permissionsHint")) }
                    Section(t("github.credential.testDetails")) {
                        Text(t("github.credential.tokenTestScope"))
                    }
                } else {
                    Section(t("github.credential.setup")) {
                        Text(t("github.credential.sshInstructions"))
                        Link(t("github.credential.addKeyOnGitHub"), destination: GitHubCredentialLinks.sshKey)
                    }
                    Section(t("github.connect.sshKey.existing")) {
                        Text(t("github.credential.sshImportInstructions"))
                    }
                    Section(t("github.credential.testDetails")) {
                        Text(t("github.credential.sshTestScope"))
                    }
                }
                Section(t("github.credential.storage")) {
                    Text(t("github.credential.storageHint"))
                    Link(t("github.credential.manageOnGitHub"), destination: mode == .token
                         ? GitHubCredentialLinks.tokens : GitHubCredentialLinks.sshKeys)
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) {
                    Button(t("common.done")) { dismiss() }.tint(.primary)
                }
            }
        }
    }
}
