import SwiftUI

struct WorkspaceArchivesScreen: View {
    let model: WorkspaceManagementModel
    @State private var showCreate = false
    @State private var confirmation: WorkspaceConfirmation?
    var body: some View {
        WorkspaceControlPage(title: "Backups", model: model, feature: .archives) {
            Section {
                WorkspaceControlReadState(state: model.archives)
                if let archives = model.archives.value {
                    if archives.isEmpty {
                        WorkspaceControlEmptyState(title: "No backups yet", description: "Save a copy of your workspace files before making major changes.")
                    } else {
                        ForEach(archives) { archive in
                            NavigationLink {
                                List {
                                    Section {
                                        LabeledContent("Version", value: archive.version)
                                        if let date = archive.createdAt { LabeledContent("Created", value: date) }
                                        if let size = archive.sizeBytes { LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                                    }
                                    Section {
                                        DestructiveButton("Delete Backup", icon: .trash) { delete(archive) }
                                            .disabled(model.isBusy)
                                    }
                                }
                                .navigationTitle(archive.name ?? "Backup \(archive.version)").navigationBarTitleDisplayMode(.inline)
                            } label: {
                                LabeledContent(archive.name ?? "Backup \(archive.version)") {
                                    if let size = archive.sizeBytes { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                                }
                            }
                            .swipeActions { Button("Delete", icon: .trash, role: .destructive) { delete(archive) } }
                        }
                    }
                }
                Button("Create Backup", icon: .plus) { showCreate = true }.disabled(model.isBusy)
            } footer: { Text("Backups contain files. Use Hibernate in the workspace’s power controls to save and resume running programs.") }
        }
        .sheet(isPresented: $showCreate) { WorkspaceArchiveEditor(model: model) }
        .workspaceConfirmation($confirmation)
    }
    private func delete(_ archive: WorkspaceArchive) {
        confirmation = .init(title: "Delete Backup?", message: "Backup \(archive.version) and its stored files will be permanently deleted. The live workspace is unchanged.", actionTitle: "Delete", destructive: true) {
            await model.execute(.deleteArchive(archive.version), title: "Deleting backup…", refresh: [.archives])
        }
    }
}

private struct WorkspaceArchiveEditor: View {
    let model: WorkspaceManagementModel
    @State private var version = ""
    @State private var paths = ""
    @State private var excludes = ""
    private func lines(_ text: String) -> [String]? {
        let values = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }
    private var valid: Bool {
        (version.isEmpty || (Int(version).map { $0 > 0 } ?? false)) &&
        ((lines(paths) ?? []) + (lines(excludes) ?? [])).allSatisfy { $0.hasPrefix("/") && !$0.contains("\0") }
    }
    var body: some View {
        WorkspaceControlEditor(title: "Create Backup", model: model, saveTitle: "Create", canSave: valid, save: {
            await model.execute(.createArchive(version: Int(version), paths: lines(paths), excludes: lines(excludes)),
                                title: "Creating backup…", refresh: [.archives]) != nil
        }) {
            Section {
                TextField("Version (automatic)", text: $version).keyboardType(.numberPad)
            }
            Section("Include Paths") {
                TextField("Entire workspace", text: $paths, axis: .vertical).lineLimit(2...6)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                TextField("None", text: $excludes, axis: .vertical).lineLimit(2...6)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Exclude Paths") } footer: { Text("Enter one absolute path per line, such as /app. Leave Include Paths empty to use the workspace’s default archive scope.") }
        }
    }
}
