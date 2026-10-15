import SwiftUI

struct BackupSyncScreen: View {
    @Environment(\.stores) private var stores
    @State private var confirmingDelete = false
    @State private var showingInfo = false
    @State private var importing = false
    @State private var readingFile = false
    @State private var fileAction: FileAction?
    @State private var fileStatus: String?
    private struct FileAction: Identifiable { let id = UUID(); var data: Data? }

    var body: some View {
        let sync = stores.connectionSync
        List {
            Section {
                Toggle("iCloud Sync", isOn: Binding(get: { sync.enabled }, set: { value in
                    Task { await sync.setEnabled(value) }
                }))
                .disabled(sync.busy)
                .accessibilityIdentifier("backup.icloud-toggle")
                if sync.enabled {
                    HStack {
                        Text(sync.status)
                        Spacer()
                        if sync.busy { ProgressView().controlSize(.small) }
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("backup.status")
                    if let date = sync.lastSyncedAt {
                        LabeledContent("Last synced") { Text(date, format: .relative(presentation: .named)) }
                    }
                    Button("Sync Now", icon: .refresh) { Task { await sync.syncNow() } }
                        .disabled(sync.busy).tint(.primary)
                        .accessibilityIdentifier("backup.sync-now")
                }
            } footer: {
                Text("Restore your computers, servers and preferences after reinstalling, or on another device with the same Apple Account.")
            }

            if let error = sync.error {
                Section {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button("Try Again", icon: .refresh) { Task { await sync.retry() } }
                        .disabled(sync.busy).tint(.primary)
                }
            }

            if sync.enabled {
                Section {
                    Toggle("Sync Server Credentials", isOn: Binding(get: { sync.syncCredentials }, set: { value in
                        Task { await sync.setSyncCredentials(value) }
                    }))
                    .disabled(sync.busy)
                    .accessibilityIdentifier("backup.credentials-toggle")
                } footer: {
                    Text("Server passwords and SSH keys use end-to-end encrypted iCloud Keychain. Computer access is approved separately on each device.")
                }
            }

            Section {
                Button("What’s Saved", icon: .info) { showingInfo = true }.tint(.primary)
                LabeledContent("Computers & Servers", value: sync.savedConnectionCount.formatted())
            }

            Section {
                Button("Save Backup", icon: .download) { fileStatus = nil; fileAction = FileAction() }
                    .accessibilityIdentifier("backup.export")
                Button("Restore Backup", icon: .upload) { fileStatus = nil; importing = true }
                    .accessibilityIdentifier("backup.import")
                if readingFile { ProgressView("Opening backup…") }
                if let fileStatus { Text(fileStatus).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Backup File")
            } footer: {
                Text("Keep an encrypted copy in Files, even when iCloud is unavailable.")
            }
            .tint(.primary)
            .disabled(readingFile)

            if sync.enabled || sync.lastSyncedAt != nil {
                Section {
                    DestructiveButton("Delete iCloud Data", icon: .trash) { confirmingDelete = true }
                        .disabled(sync.busy)
                        .accessibilityIdentifier("backup.delete-cloud")
                } footer: {
                    Text("Your connections on this device and files in your workspaces are kept.")
                }
            }
        }
        .navigationTitle("Backup & Sync")
        .navigationBarTitleDisplayMode(.inline)
        .task { await sync.foreground() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.mindwireBackup]) { result in
            guard case .success(let url) = result else {
                if case .failure(let error) = result { fileStatus = ConnectionSyncError.message(for: error) }
                return
            }
            readingFile = true
            Task {
                defer { readingFile = false }
                do {
                    let data = try await Task.detached(priority: .userInitiated) { try ConnectionFileEncryption.read(url) }.value
                    fileAction = FileAction(data: data)
                } catch { fileStatus = ConnectionSyncError.message(for: error) }
            }
        }
        .sheet(item: $fileAction) { action in
            ConnectionBackupFileSheet(importedData: action.data) { fileStatus = $0 }
                .presentationDetents([.large])
        }
        .alert("Delete iCloud Data?", isPresented: $confirmingDelete) {
            Button("Delete iCloud Data", role: .destructive) { Task { await sync.deleteCloudData() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes Mindwire’s saved connections, preferences and synced server credentials from iCloud. Local connections are kept, and sync turns off on your devices.")
        }
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                List {
                    Section("Saved in iCloud") {
                        Text("Computer and server addresses, verified identities, workspace connections and app preferences.")
                    }
                    Section("Secure credentials") {
                        Text("Server passwords and SSH keys sync only when you turn on Sync Server Credentials. Each phone keeps its own computer approval.")
                    }
                    Section("In your workspace") {
                        Text("Projects, folders, files and conversation history load from your workspace when you reconnect.")
                    }
                }
                .navigationTitle("What’s Saved")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { AppToolbarItem(placement: .confirmationAction) { Button("Done") { showingInfo = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
