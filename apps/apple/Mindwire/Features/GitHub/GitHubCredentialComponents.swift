import SwiftUI
import UIKit

struct GitHubConnectionRow: View {
    let account: GitHubAccount
    var body: some View {
        EntityRow {
            Text(account.displayName)
        } subtitle: {
            Text(account.identityLabel)
        } icon: {
            GitHubCredentialIcon(mode: account.mode)
        } accessory: {
            if let check = account.lastCheck {
                AppIcon(check.succeeded ? .check : .warning)
                    .font(.caption)
                    .foregroundStyle(check.succeeded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .accessibilityLabel(t(check.succeeded ? "github.credential.lastTestPassed" : "github.credential.lastTestFailed"))
            }
        }
    }
}

struct GitHubCredentialIcon: View {
    let mode: GitHubAuthMode
    var body: some View {
        switch mode {
        case .token: AppIcon(.key).foregroundStyle(.secondary)
        case .sshKey: AppIcon(.shield).foregroundStyle(.secondary)
        case .ghCli: AppIcon(Icon.terminal).foregroundStyle(.secondary)
        case .oblienApp: ProviderLogo(id: .github, size: 22)
        }
    }
}

/// Native fields with an explicit reveal control. Revealed values hide again
/// when the app becomes inactive, including before the app-switcher snapshot.
struct GitHubSecretField: View {
    let title: String
    @Binding var text: String
    var multiline = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var revealed: Bool

    init(title: String, text: Binding<String>, multiline: Bool = false) {
        self.title = title
        self._text = text
        self.multiline = multiline
        self._revealed = State(initialValue: multiline)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Group {
                if revealed {
                    TextField(title, text: $text, axis: .vertical).lineLimit(multiline ? 3...7 : 1...4)
                } else { SecureField(title, text: $text) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .privacySensitive()
            Button { revealed.toggle() } label: {
                AppIcon(revealed ? .eyeOff : .eye)
            }
            .buttonStyle(.borderless).tint(.secondary)
            .accessibilityLabel(t(revealed ? "github.credential.hide" : "github.credential.show"))
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { revealed = false } }
    }
}

struct GitHubSecretValue: View {
    let secret: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        Group {
            if let secret, !secret.isEmpty {
                HStack {
                    Text(revealed ? t("github.credential.value") : "••••••••••••")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { revealed.toggle() } label: {
                        AppIcon(revealed ? .eyeOff : .eye)
                    }
                    .accessibilityLabel(t(revealed ? "github.credential.hide" : "github.credential.show"))
                    if revealed {
                        Button {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: secret]],
                                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
                            copied = true
                        } label: { AppIcon(copied ? Icon.checkmark : .copy) }
                        .accessibilityLabel(t("common.copy"))
                    }
                }
                .buttonStyle(.borderless).tint(.secondary)
                if revealed {
                    Text(secret).font(.callout).textSelection(.enabled).privacySensitive()
                }
            } else {
                Text(t("github.credential.secretMissing")).foregroundStyle(.secondary)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { revealed = false; copied = false }
        }
        .onDisappear { revealed = false; copied = false }
    }
}

struct GitHubPublicKeySection: View {
    let secret: String
    var showAddLink = true
    @State private var copied = false
    var body: some View {
        if let publicKey = GitHubCredentialService.publicKey(from: secret) {
            Section {
                Text(publicKey).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = publicKey
                    copied = true
                } label: {
                    Label(t(copied ? "github.connect.sshKey.copied" : "github.credential.copyPublicKey"),
                          icon: copied ? Icon.checkmark : .copy)
                        .foregroundStyle(.primary)
                }
                .tint(.primary)
                if showAddLink {
                    Link(destination: GitHubCredentialLinks.sshKey) {
                        Label(t("github.credential.addKeyOnGitHub"), icon: .arrowUpRight)
                            .foregroundStyle(.primary)
                    }
                    .tint(.primary)
                }
            } header: { Text(t("github.credential.publicKey")) }
            .onChange(of: secret) { _, _ in copied = false }
        }
    }
}

struct GitHubCredentialReportView: View {
    let report: GitHubCredentialReport
    var body: some View {
        Label(report.summary, icon: .checkCircle)
            .foregroundStyle(.secondary)
        if report.mode == .token {
            DisclosureGroup(t("github.credential.testDetails")) {
                Text(t("github.credential.tokenTestScope")).font(.footnote).foregroundStyle(.secondary)
                if let scopes = report.scopes, !scopes.isEmpty {
                    LabeledContent(t("github.credential.scopes"), value: scopes.joined(separator: ", "))
                }
                if let expiry = report.expiresAt {
                    LabeledContent(t("github.credential.expires"), value: expiry)
                }
            }
            .tint(.secondary)
        }
    }
}
