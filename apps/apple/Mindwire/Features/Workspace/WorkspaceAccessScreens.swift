import SwiftUI

struct WorkspaceSSHScreen: View {
    let model: WorkspaceManagementModel
    @State private var confirmation: WorkspaceConfirmation?
    @State private var editor: SSHCredentialKind?
    @State private var credential: WorkspaceCredential?

    var body: some View {
        WorkspaceControlPage(title: "SSH Access", model: model, feature: .ssh) {
            Section {
                WorkspaceControlReadState(state: model.ssh)
                if let access = model.ssh.value {
                    if access.supported == false {
                        Text("This workspace does not provide SSH access.").foregroundStyle(.secondary)
                    } else {
                        Toggle("SSH Access", isOn: Binding(get: { access.sshEnabled == true }, set: changeAccess))
                            .disabled(model.isBusy)
                    }
                }
            } footer: { Text("Connect through Oblien’s SSH gateway from your own terminal or file client.") }
            if let access = model.ssh.value, access.sshEnabled == true {
                if let connection = access.connection {
                    Section("Connection") {
                        if let command = connection.command { WorkspaceCopyRow(title: "SSH", value: command) }
                        if let command = connection.scpUpload { WorkspaceCopyRow(title: "Upload", value: command) }
                        if let command = connection.scpDownload { WorkspaceCopyRow(title: "Download", value: command) }
                    }
                }
                Section {
                    if access.authMethods?.contains("password") != false {
                        Button("Set Password") { editor = .password }
                    }
                    if access.authMethods?.contains("publickey") != false {
                        Button("Add Public Key") { editor = .publicKey }
                        LabeledContent("Public Key", value: access.sshKeySet == true ? "Configured" : "Not configured")
                    }
                } header: { Text("Authentication") } footer: {
                    if access.passwordAffectsDesktop == true { Text("The SSH password also signs in to this workspace’s desktop account.") }
                }
                .disabled(model.isBusy)
            }
        }
        .workspaceConfirmation($confirmation)
        .sheet(item: $editor) { kind in WorkspaceSSHCredentialEditor(model: model, kind: kind) }
        .sheet(item: $credential) { WorkspaceCredentialSheet(credential: $0) }
    }
    private func changeAccess(_ enabled: Bool) {
        if enabled {
            Task {
                if case .ssh(let access) = await model.execute(.sshAccess(true), title: "Enabling SSH…", refresh: [.ssh]),
                   let password = access.password {
                    credential = .init(title: "SSH Password", value: password, detail: "Save this password now, or set a new one in SSH Access.")
                }
            }
        } else {
            confirmation = .init(title: "Disable SSH Access?", message: "Existing SSH connections may close. The workspace keeps running.", actionTitle: "Disable") {
                await model.execute(.sshAccess(false), title: "Disabling SSH…", refresh: [.ssh])
            }
        }
    }
}

private enum SSHCredentialKind: String, Identifiable {
    case password, publicKey
    var id: String { rawValue }
    var title: String { self == .password ? "Set SSH Password" : "Add Public Key" }
}
private struct WorkspaceSSHCredentialEditor: View {
    let model: WorkspaceManagementModel
    let kind: SSHCredentialKind
    @State private var value = ""
    var body: some View {
        WorkspaceControlEditor(title: kind.title, model: model,
            canSave: kind == .password ? value.count >= 6 : validKey,
            save: {
                await model.execute(kind == .password ? .sshPassword(value) : .sshPublicKey(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                                    title: "Saving authentication…", refresh: [.ssh]) != nil
            }) {
                Section {
                    if kind == .password {
                        SecureField("Password", text: $value).textContentType(.newPassword)
                    } else {
                        TextField("ssh-ed25519 …", text: $value, axis: .vertical).lineLimit(3...8)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } footer: {
                    Text(kind == .password ? "Use at least six characters." : "Paste the public key from your computer. Keep its private key on that computer.")
                }
            }
    }
    private var validKey: Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-", "sk-ssh-ed25519", "sk-ecdsa-sha2-"].contains { trimmed.hasPrefix($0) }
            && !trimmed.contains("PRIVATE KEY")
    }
}

struct WorkspaceAPIAccessScreen: View {
    let model: WorkspaceManagementModel
    @State private var confirmation: WorkspaceConfirmation?
    @State private var credential: WorkspaceCredential?

    var body: some View {
        WorkspaceControlPage(title: "Runtime API", model: model, feature: .apiAccess) {
            Section {
                WorkspaceControlReadState(state: model.apiAccess)
                if let access = model.apiAccess.value {
                    Toggle("Runtime API Access", isOn: Binding(get: { access.enabled == true }, set: changeAccess))
                        .disabled(model.isBusy)
                }
            } footer: { Text("Mindwire uses this connection for chats, files, terminals, and desktop access.") }
            if model.apiAccess.value?.enabled == true {
                Section {
                    Button("Show Gateway Token") { showToken(raw: false) }
                    Button("Show Direct Runtime Token") { showToken(raw: true) }
                    Button("Rotate Token") {
                        confirmation = .init(title: "Rotate Runtime Token?", message: "Active chats, terminals, and desktop connections will disconnect. Clients must reconnect with the new token.", actionTitle: "Rotate") {
                            if case .credential(let token) = await model.execute(.rotateRuntimeToken, title: "Rotating token…", refresh: [.apiAccess]) {
                                credential = .init(title: "Gateway Token", value: token, detail: "Use this token to authenticate to the workspace gateway.")
                            }
                        }
                    }
                } header: { Text("Credentials") } footer: {
                    Text("Gateway tokens are used with workspace.oblien.com. Direct tokens are for clients that can reach the workspace’s private network.")
                }
                .disabled(model.isBusy)
            }
        }
        .workspaceConfirmation($confirmation)
        .sheet(item: $credential) { WorkspaceCredentialSheet(credential: $0) }
    }
    private func changeAccess(_ enabled: Bool) {
        if enabled {
            Task { await model.execute(.runtimeAccess(true), title: "Enabling runtime access…", refresh: [.apiAccess]) }
        } else {
            confirmation = .init(title: "Disable Runtime API?", message: "Mindwire will lose access to chats, files, terminals, and desktop until you enable it again. The workspace keeps running.", actionTitle: "Disable", destructive: true) {
                await model.execute(.runtimeAccess(false), title: "Disabling runtime access…", refresh: [.apiAccess])
            }
        }
    }
    private func showToken(raw: Bool) {
        Task {
            if case .credential(let token) = await model.execute(.runtimeToken(raw: raw), title: "Loading token…") {
                credential = .init(title: raw ? "Direct Runtime Token" : "Gateway Token", value: token,
                                   detail: "This token grants access to the workspace. Keep it private.")
            }
        }
    }
}

struct WorkspaceCredential: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let detail: String
}
struct WorkspaceCredentialSheet: View {
    let credential: WorkspaceCredential
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var copied = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(credential.value).textSelection(.enabled).privacySensitive()
                    Button(copied ? "Copied" : "Copy", icon: copied ? .check : .copy) {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": credential.value]],
                            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
                        copied = true
                    }
                } footer: { Text(credential.detail) }
            }
            .navigationTitle(credential.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { AppToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(.primary) } }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { dismiss() } }
    }
}
