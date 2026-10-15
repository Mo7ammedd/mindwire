import SwiftUI

struct WorkspaceCreationStorageScreen: View {
    let model: NewWorkspaceModel
    @State private var showDisks = false

    var body: some View {
        @Bindable var storage = model.storage
        Form {
            Section {
                Picker("Namespace", selection: $storage.namespace) {
                    Text("Personal").tag("")
                    ForEach(storage.namespaces.value ?? []) { Text($0.name).tag($0.id) }
                    if !storage.namespace.isEmpty, storage.namespaces.value?.contains(where: { $0.id == storage.namespace }) != true {
                        Text(storage.namespace).tag(storage.namespace)
                    }
                }
                WorkspaceControlReadState(state: storage.namespaces)
            } footer: {
                Text("The workspace and its disks must belong to the same namespace.")
            }
            Section("Root Filesystem") {
                NavigationLink {
                    WorkspaceCreationRootPicker(model: model)
                } label: {
                    LabeledContent("Root Disk", value: storage.root?.displayName ?? "New from Image")
                }
            }
            Section {
                ForEach($storage.attachments) { $attachment in
                    NavigationLink {
                        WorkspaceCreationAttachmentEditor(attachment: $attachment, image: model.selectedImage)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(attachment.disk.displayName)
                                Text(attachment.disk.kind == "root" ? "Read-only software layer" : WorkspaceControlFormat.capacity(attachment.disk.sizeMb))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: { AppIcon(.hardDrive).foregroundStyle(.secondary) }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { storage.attachments.removeAll { $0.id == attachment.id } }
                    }
                }
                Button { showDisks = true } label: {
                    Label("Add Disk", icon: .plus).foregroundStyle(.primary)
                }.tint(.primary)
            } header: {
                Text("Additional Disks")
            } footer: {
                Text("Disks keep their files when a workspace is deleted. You can also attach disks later from Manage.")
            }
            if let error = storage.validation(image: model.selectedImage) {
                Section { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Storage").navigationBarTitleDisplayMode(.inline)
        .task { await storage.load() }
        .refreshable { await storage.load(force: true) }
        .sheet(isPresented: $showDisks) {
            NavigationStack {
                WorkspaceCreationDiskPicker(model: model)
                    .toolbar { AppToolbarItem(placement: .cancellationAction) { Button("Cancel") { showDisks = false }.tint(.primary) } }
            }
        }
    }
}

private struct WorkspaceCreationRootPicker: View {
    let model: NewWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    private var available: [WorkspaceManagedDisk] {
        (model.storage.disks.value ?? []).filter {
            $0.canCreateWorkspace && $0.namespace?.nonBlank == model.storage.namespace.nonBlank
        }
    }
    var body: some View {
        List {
            Section {
                Button { model.selectRoot(nil); dismiss() } label: {
                    HStack {
                        Text("New from Image")
                        Spacer()
                        if model.storage.root == nil { AppIcon(.check) }
                    }
                }.tint(.primary)
            }
            Section("Existing Roots") {
                WorkspaceControlReadState(state: model.storage.disks)
                ForEach(available) { disk in
                    Button { model.selectRoot(disk); dismiss() } label: {
                        WorkspaceCreationDiskLabel(disk: disk, selected: disk.id == model.storage.root?.id)
                    }.tint(.primary)
                }
                if model.storage.disks.loaded, available.isEmpty {
                    WorkspaceControlEmptyState(title: "No available roots", description: "Retain a workspace’s root or fork a saved root in Disks & Software to reuse it here.")
                }
            }
        }
        .navigationTitle("Root Disk").navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.storage.load(force: true) }
    }
}

private struct WorkspaceCreationDiskPicker: View {
    let model: NewWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    private var available: [WorkspaceManagedDisk] {
        (model.storage.disks.value ?? []).filter { disk in
            disk.id != model.storage.root?.id && !model.storage.attachments.contains(where: { $0.id == disk.id }) &&
            disk.canAttachToNewWorkspace(image: model.storage.root?.rootImage ?? model.selectedImage?.image, namespace: model.storage.namespace.nonBlank)
        }
    }
    var body: some View {
        List {
            Section {
                WorkspaceControlReadState(state: model.storage.disks)
                ForEach(available) { disk in
                    Button {
                        let target = disk.format == "raw" ? model.selectedImage?.diskTargets?.first(where: { $0.id != "local" && $0.formats.contains("raw") })?.id ?? "local" : "local"
                        model.storage.attachments.append(.init(disk: disk, target: target, readOnly: disk.isReadOnly))
                        dismiss()
                    } label: {
                        WorkspaceCreationDiskLabel(disk: disk, selected: false)
                    }.tint(.primary)
                }
                if model.storage.disks.loaded, available.isEmpty {
                    WorkspaceControlEmptyState(title: "No compatible disks", description: "Available disks in this namespace appear here. A writable disk must be detached from its current workspace first.")
                }
            }
        }
        .navigationTitle("Add Disk").navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.storage.load(force: true) }
    }
}

private struct WorkspaceCreationDiskLabel: View {
    let disk: WorkspaceManagedDisk
    let selected: Bool
    var body: some View {
        HStack(spacing: Spacing.md) {
            AppIcon(.hardDrive).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(disk.displayName)
                Text([WorkspaceControlFormat.capacity(disk.sizeMb), disk.isReadOnly ? "Read only" : disk.format?.uppercased()].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if selected { AppIcon(.check) }
        }
    }
}

private struct WorkspaceCreationAttachmentEditor: View {
    @Binding var attachment: WorkspaceCreationAttachment
    let image: WorkspaceImage?
    var body: some View {
        Form {
            Section {
                LabeledContent("Capacity", value: WorkspaceControlFormat.capacity(attachment.disk.sizeMb))
                if attachment.disk.kind == "root" {
                    LabeledContent("Role", value: "Software layer")
                } else if attachment.disk.format == "raw" {
                    Picker("Runtime", selection: $attachment.target) {
                        Text("Linux host").tag("local")
                        ForEach((image?.diskTargets ?? []).filter { $0.id != "local" && $0.formats.contains("raw") }) { Text($0.label).tag($0.id) }
                    }
                } else {
                    TextField("Mount directory (automatic if empty)", text: $attachment.mountPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if attachment.disk.isReadOnly { LabeledContent("Access", value: "Read only") }
                else { Toggle("Read Only", isOn: $attachment.readOnly) }
            } footer: {
                Text(attachment.disk.kind == "root" ? "Files in this layer remain unchanged. The workspace keeps its own writes in its private root." : "Existing files are preserved. Attaching a raw disk does not format it.")
            }
        }
        .navigationTitle(attachment.disk.displayName).navigationBarTitleDisplayMode(.inline)
    }
}
