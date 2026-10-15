import SwiftUI

struct ConnectionBackupFileSheet: View {
    var importedData: Data?
    var onComplete: (String) -> Void
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var includeCredentials = false
    @State private var restorePreferences = true
    @State private var unlocked: ConnectionFileBackup?
    @State private var document: ConnectionBackupDocument?
    @State private var exporting = false
    @State private var busy = false
    @State private var error: String?

    private var restoring: Bool { importedData != nil }
    private var missingCount: Int {
        let ids = Set(stores.connections.list().map(\.id))
        return unlocked?.connections.filter { !ids.contains($0.connection.id) }.count ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                if let unlocked {
                    Section {
                        LabeledContent("Created") { Text(unlocked.createdAt, style: .date) }
                        LabeledContent("Saved Connections", value: unlocked.connections.count.formatted())
                        LabeledContent("Connections to Add", value: missingCount.formatted())
                        let credentials = unlocked.credentialsToRestore(in: stores, secrets: stores.connectionSync.secrets).count
                        if credentials > 0 { LabeledContent("Credentials to Restore", value: credentials.formatted()) }
                        Toggle("Restore App Preferences", isOn: $restorePreferences)
                    } footer: {
                        Text("Existing connections are kept. Each device needs its own approval to access a paired computer.")
                    }
                } else {
                    Section {
                        SecureField("Backup password", text: $password)
                            .textContentType(restoring ? .password : .newPassword)
                            .accessibilityIdentifier("backup.file.password")
                        if !restoring {
                            SecureField("Confirm password", text: $confirmation)
                                .textContentType(.newPassword)
                                .accessibilityIdentifier("backup.file.confirm-password")
                        }
                    } footer: {
                        Text(restoring ? "Enter the password used to save this backup."
                             : "Use at least 12 characters. Keep this password safe—you’ll need it to restore the file.")
                    }
                    if !restoring {
                        Section {
                            Toggle("Include Server Credentials", isOn: $includeCredentials)
                                .accessibilityIdentifier("backup.file.credentials")
                        } footer: {
                            Text("Server passwords and SSH keys are encrypted inside the file. Computer approvals stay on this device.")
                        }
                    }
                }

                if let error { Section { Text(error).font(.subheadline).foregroundStyle(.secondary) } }

                Section {
                    Button {
                        if let unlocked { restore(unlocked) } else { Task { await process() } }
                    } label: {
                        HStack {
                            Text(restoring ? (unlocked == nil ? "Unlock Backup" : "Restore Backup") : "Save to Files")
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(busy || (unlocked == nil && (password.isEmpty
                        || !restoring && (password.count < 12 || password != confirmation))))
                    .accessibilityIdentifier("backup.file.continue")
                } footer: {
                    if !restoring {
                        Text("Save outside Mindwire’s own folder so the file survives deleting the app. If iCloud is full, choose an available local folder, another Files provider or external storage.")
                    }
                }
            }
            .navigationTitle(restoring ? "Restore Backup" : "Save Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            }
        }
        .interactiveDismissDisabled(busy)
        .fileExporter(isPresented: $exporting, document: document, contentType: .mindwireBackup,
                      defaultFilename: "Mindwire-Backup-" + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))) { result in
            switch result {
            case .success:
                onComplete("Backup saved.")
                dismiss()
            case .failure(let failure):
                if (failure as NSError).code != NSUserCancelledError { error = failure.localizedDescription }
            }
        }
        .onDisappear { password = ""; confirmation = "" }
    }

    private func process() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        let password = password
        do {
            if let importedData {
                unlocked = try await Task.detached(priority: .userInitiated) {
                    try ConnectionFileEncryption.decrypt(importedData, password: password)
                }.value
                self.password = ""
            } else {
                let backup = try ConnectionFileBackup.capture(stores: stores, secrets: stores.connectionSync.secrets,
                    includeCredentials: includeCredentials)
                let data = try await Task.detached(priority: .userInitiated) {
                    try ConnectionFileEncryption.encrypt(backup, password: password)
                }.value
                document = ConnectionBackupDocument(data: data)
                exporting = true
            }
        } catch { self.error = ConnectionSyncError.message(for: error) }
    }

    private func restore(_ backup: ConnectionFileBackup) {
        do {
            let count = try backup.restore(to: stores, secrets: stores.connectionSync.secrets, restorePreferences: restorePreferences)
            stores.connectionSync.localDidChange()
            onComplete(count == 0 ? "Backup restored." : count == 1 ? "Restored 1 connection." : "Restored \(count) connections.")
            dismiss()
        } catch { self.error = ConnectionSyncError.message(for: error) }
    }
}
