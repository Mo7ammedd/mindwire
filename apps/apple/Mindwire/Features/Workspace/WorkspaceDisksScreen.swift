import SwiftUI

private enum WorkspaceDiskTab: String, CaseIterable { case attached = "Attached", available = "My Disks", software = "Software" }
private struct WorkspaceDiskForm: Identifiable {
    let id = UUID()
    var kind: WorkspaceDiskAction.Kind
    var disk: WorkspaceManagedDisk?
}

struct WorkspaceDisksScreen: View {
    let model: WorkspaceManagementModel
    let workspaceModel: WorkspaceModel
    let repository: WorkspaceRepository
    @State private var tab = WorkspaceDiskTab.attached
    @State private var form: WorkspaceDiskForm?
    @State private var confirmation: WorkspaceConfirmation?

    var body: some View {
        WorkspaceControlPage(title: "Disks & Software", model: model, feature: .disks, additionalRefresh: {
            if tab == .available { await model.loadAvailableDisks(force: true) }
            if tab == .software { await model.loadSoftware(force: true) }
        }) {
            Section {
                Picker("Storage", selection: $tab) {
                    ForEach(WorkspaceDiskTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            operationSection
            if let reason = model.storageBlockedReason {
                Section {
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                    if model.info.value?.isRunning == true {
                        Button("Stop Workspace") {
                            confirmation = WorkspaceConfirmation(title: "Stop Workspace?", message: "Running programs and chats will stop. Files are kept.", actionTitle: "Stop", destructive: true) {
                                await workspaceModel.power(.stop)
                                await model.refresh(.disks, force: true)
                            }
                        }.tint(.primary).disabled(model.isBusy || workspaceModel.powerAction != nil)
                    } else if model.info.value?.hasSavedExecution == true {
                        Button("Discard Saved Memory", role: .destructive) {
                            confirmation = WorkspaceConfirmation(title: "Discard Saved Memory?", message: "The saved session cannot be resumed. Disk files are kept, and the next start will be a fresh boot.", actionTitle: "Discard", destructive: true) {
                                await model.diskAction(.init(kind: .discardSavedExecution))
                            }
                        }.disabled(model.isBusy)
                    }
                }
            }
            switch tab {
            case .attached:
                Section {
                    WorkspaceControlReadState(state: model.disks)
                    diskRows(model.disks.value?.disks ?? [])
                    if model.disks.loaded, model.disks.value?.disks.isEmpty == true {
                        WorkspaceControlEmptyState(title: "No additional disks", description: "Attach storage or software when you need it. Your workspace already has its own root disk.")
                    }
                }
            case .available:
                Section {
                    WorkspaceControlReadState(state: model.allDisks)
                    diskRows(model.allDisks.value ?? [])
                    if model.allDisks.loaded, model.allDisks.value?.isEmpty == true {
                        WorkspaceControlEmptyState(title: "No saved disks", description: "Create a disk to keep files independently of a workspace.")
                    }
                }
            case .software:
                Section {
                    WorkspaceControlReadState(state: model.software)
                    ForEach(model.software.value ?? []) { software in
                        NavigationLink { softwareDetails(software) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(software.displayName)
                                Text(software.description ?? "Provided by Oblien").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    if model.software.loaded, model.software.value?.isEmpty == true {
                        WorkspaceControlEmptyState(title: "No compatible software", description: "The library shows software available for this workspace’s operating system. Desktop setup is in Desktop.")
                    }
                }
            }
        }
        .toolbar {
            AppToolbarItem(placement: .topBarTrailing) {
                AppMenu {
                    Button("Create Disk", icon: .plus) { form = .init(kind: .create) }
                    Button("Attach Disk", icon: .link) { form = .init(kind: .attach) }.disabled(model.storageBlockedReason != nil)
                    Button("Retain Root Disk", icon: .hardDrive) { form = .init(kind: .retain) }
                        .disabled(model.storageBlockedReason != nil || model.disks.value?.disks.contains(where: { $0.kind == "root" && $0.connections.contains(where: { $0.role == "root" }) }) == true)
                } label: { AppIcon(.plus).tint(.primary) }
                .disabled(model.isBusy)
            }
        }
        .task(id: tab) {
            if tab == .available { await model.loadAvailableDisks() }
            if tab == .software { await model.loadSoftware() }
        }
        .sheet(item: $form) { form in
            WorkspaceDiskEditor(model: model, repository: repository, kind: form.kind, disk: form.disk)
        }
        .workspaceConfirmation($confirmation)
    }

    @ViewBuilder private var operationSection: some View {
        ForEach(model.operations.values.sorted { $0.id < $1.id }, id: \.id) { operation in
            if operation.isPending || operation.state == "failed" {
                Section {
                    if operation.isPending {
                        ProgressView(WorkspaceControlFormat.status(operation.phase ?? operation.state))
                    } else {
                        Text(operation.error ?? "The disk operation needs attention.").font(.footnote).foregroundStyle(.secondary)
                        Button("Retry Operation") { Task { await model.diskAction(.init(kind: .retry, operationId: operation.id)) } }.disabled(model.isBusy)
                    }
                }
            }
        }
        if let error = model.operationError { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
    }

    @ViewBuilder private func diskRows(_ disks: [WorkspaceManagedDisk]) -> some View {
        ForEach(disks) { disk in
            NavigationLink { WorkspaceDiskDetailScreen(model: model, repository: repository, initialDisk: disk) } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(disk.displayName).lineLimit(1)
                        Text([WorkspaceControlFormat.capacity(disk.sizeMb), disk.isSystem ? "Oblien" : disk.isReadOnly ? "Read only" : disk.format?.uppercased(), disk.operationId == nil ? nil : "Preparing"].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                } icon: { AppIcon(.hardDrive).foregroundStyle(.secondary) }
            }
        }
    }

    private func softwareDetails(_ software: WorkspaceSoftware) -> some View {
        List {
            Section {
                Text(software.description ?? software.displayName).foregroundStyle(.secondary)
                LabeledContent("Owner", value: "Oblien")
                LabeledContent("Access", value: "Read only")
                LabeledContent("Capacity", value: WorkspaceControlFormat.capacity(software.sizeMb))
            }
            Section {
                Button("Attach Software") {
                    Task { await model.diskAction(.init(kind: .attachSoftware, diskId: software.id)) }
                }.disabled(model.isBusy || model.storageBlockedReason != nil)
            } footer: {
                Text(model.storageBlockedReason ?? "Shared software keeps its files read only. Your workspace keeps its own projects, preferences, and build output.")
            }
            WorkspaceControlFeedback(model: model)
        }
        .navigationTitle(software.displayName).navigationBarTitleDisplayMode(.inline)
    }
}

private struct WorkspaceDiskDetailScreen: View {
    let model: WorkspaceManagementModel
    let repository: WorkspaceRepository
    let initialDisk: WorkspaceManagedDisk
    @Environment(\.dismiss) private var dismiss
    @State private var form: WorkspaceDiskForm?
    @State private var confirmation: WorkspaceConfirmation?
    @State private var showCreateWorkspace = false
    private var disk: WorkspaceManagedDisk {
        (model.allDisks.value ?? []).first { $0.id == initialDisk.id } ?? model.disks.value?.disks.first { $0.id == initialDisk.id } ?? initialDisk
    }
    private var attachedHere: Bool { disk.connections.contains { $0.workspaceId == model.info.value?.id } }

    var body: some View {
        List {
            Section {
                LabeledContent("Capacity", value: WorkspaceControlFormat.capacity(disk.sizeMb))
                LabeledContent("Owner", value: disk.isSystem ? "Oblien" : "Your account")
                LabeledContent("Access", value: disk.isReadOnly ? "Read only" : "Writable")
                LabeledContent("Type", value: disk.kind == "root" ? "Root filesystem" : disk.format?.uppercased() ?? "Data disk")
                LabeledContent("Status", value: WorkspaceControlFormat.status(disk.state))
            }
            if !disk.connections.isEmpty {
                Section("Connected Workspaces") {
                    ForEach(disk.connections, id: \.workspaceId) { attachment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(repository.get(attachment.workspaceId)?.name ?? attachment.workspaceId)
                            Text(attachment.role == "root" ? "Root filesystem" : attachment.role == "layer" ? "Software layer" : attachment.mountPath ?? attachment.target ?? "Block device")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                if disk.canCreateWorkspace {
                    Button("Create Workspace") { showCreateWorkspace = true }
                }
                if let workspace = model.info.value, disk.canAttach(to: workspace) {
                    formButton("Attach to Workspace", kind: .attach, needsStopped: true)
                }
                if attachedHere, disk.permits("detach") {
                    Button("Detach Disk") {
                        confirmation = WorkspaceConfirmation(title: "Detach “\(disk.displayName)” ?", message: "Its files remain on the disk and it continues to use account storage.", actionTitle: "Detach") {
                            await model.diskAction(.init(kind: .detach, diskId: disk.id))
                        }
                    }.disabled(model.storageBlockedReason != nil)
                }
                if attachedHere, disk.permits("move") { formButton("Move to Workspace", kind: .move, needsStopped: true) }
                if disk.permits("clone") { formButton(disk.isSystem ? "Copy to My Disks" : "Copy Disk", kind: .clone, needsStopped: attachedHere && !disk.isReadOnly) }
                if disk.permits("save") { formButton("Save Read-only Copy", kind: .save, needsStopped: attachedHere && !disk.isReadOnly) }
                if disk.permits("fork") { formButton("Fork Root", kind: .fork) }
                if disk.permits("resize") { formButton("Grow Disk", kind: .resize) }
            }.disabled(model.isBusy).tint(.primary)
            if disk.permits("delete") {
                Section {
                    Button("Delete Disk", role: .destructive) {
                        confirmation = WorkspaceConfirmation(title: "Delete “\(disk.displayName)” ?", message: "All files on this disk will be permanently deleted.", actionTitle: "Delete", destructive: true) {
                            if await model.diskAction(.init(kind: .delete, diskId: disk.id)) { dismiss() }
                        }
                    }.disabled(model.isBusy)
                }
            }
            WorkspaceControlFeedback(model: model)
        }
        .navigationTitle(disk.displayName).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $form) { WorkspaceDiskEditor(model: model, repository: repository, kind: $0.kind, disk: $0.disk) }
        .sheet(isPresented: $showCreateWorkspace) {
            NewWorkspaceScreen(rootDisk: disk) { _ in
                Task {
                    await model.loadAvailableDisks(force: true)
                    await model.refresh(.disks, force: true)
                }
            }
        }
        .workspaceConfirmation($confirmation)
    }
    private func formButton(_ title: String, kind: WorkspaceDiskAction.Kind, needsStopped: Bool = false) -> some View {
        Button(title) { form = .init(kind: kind, disk: disk) }.disabled(needsStopped && model.storageBlockedReason != nil)
    }
}

private struct WorkspaceDiskEditor: View {
    let model: WorkspaceManagementModel
    let repository: WorkspaceRepository
    let kind: WorkspaceDiskAction.Kind
    let disk: WorkspaceManagedDisk?
    @State private var name = ""
    @State private var capacity = "4096"
    @State private var format = "ext4"
    @State private var diskId = ""
    @State private var targetWorkspaceId = ""
    @State private var mountPath = "/data"
    @State private var target = "local"
    private var selectedDisk: WorkspaceManagedDisk? { disk ?? model.allDisks.value?.first { $0.id == diskId } }
    private var title: String {
        switch kind {
        case .create: return "Create Disk"
        case .attach: return "Attach Disk"
        case .move: return "Move Disk"
        case .clone: return "Copy Disk"
        case .save: return "Save Disk"
        case .fork: return "Fork Root"
        case .resize: return "Grow Disk"
        case .retain: return "Retain Root"
        default: return "Disk"
        }
    }
    private var needsName: Bool { [.create, .clone, .save, .fork, .retain].contains(kind) }
    private var needsCapacity: Bool { [.create, .fork, .resize].contains(kind) }
    private var targets: [WorkspaceImageOption.DiskTarget] {
        model.images.value?.first { $0.image == model.info.value?.image }?.diskTargets ?? []
    }
    private var destinations: [ManagedWorkspace] {
        guard let disk = selectedDisk, let sourceID = model.info.value?.id else { return [] }
        return (model.workspaceChoices.value ?? []).filter { disk.canMove(to: $0, from: sourceID) }
    }
    private var valid: Bool {
        if needsName, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if needsCapacity, !(64...1_048_576).contains(Int(capacity) ?? 0) { return false }
        if kind == .resize, (Int(capacity) ?? 0) <= (disk?.sizeMb ?? 0) { return false }
        if kind == .attach, selectedDisk == nil || model.storageBlockedReason != nil { return false }
        if kind == .move, !destinations.contains(where: { $0.id == targetWorkspaceId }) || model.storageBlockedReason != nil { return false }
        return selectedDisk?.format == "raw" || WorkspaceControlValidation.mountPath(mountPath)
    }

    var body: some View {
        WorkspaceControlEditor(title: title, model: model, saveTitle: title, canSave: valid, save: save) {
            Section {
                if needsName { TextField("Name", text: $name) }
                if needsCapacity {
                    LabeledContent("Capacity (MiB)") { TextField("4096", text: $capacity).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                    Text(WorkspaceControlFormat.capacity(Int(capacity))).font(.footnote).foregroundStyle(.secondary)
                }
                if kind == .create {
                    Picker("Format", selection: $format) { Text("ext4 filesystem").tag("ext4"); Text("Raw block device").tag("raw") }
                }
                if kind == .attach, disk == nil {
                    Picker("Disk", selection: $diskId) {
                        Text("Choose a disk").tag("")
                        if let workspace = model.info.value {
                            ForEach((model.allDisks.value ?? []).filter { $0.canAttach(to: workspace) }) { disk in
                                Text("\(disk.displayName) · \(WorkspaceControlFormat.capacity(disk.sizeMb))").tag(disk.id)
                            }
                        }
                    }
                    WorkspaceControlReadState(state: model.allDisks)
                }
                if kind == .move {
                    Picker("Destination", selection: $targetWorkspaceId) {
                        Text("Choose a workspace").tag("")
                        ForEach(destinations, id: \.id) { workspace in
                            Text(workspace.name ?? workspace.id).tag(workspace.id)
                        }
                    }
                    WorkspaceControlReadState(state: model.workspaceChoices)
                    if model.workspaceChoices.loaded, destinations.isEmpty {
                        Text("No compatible stopped workspaces in this namespace.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if [.attach, .move].contains(kind), let disk = selectedDisk, disk.kind != "root" {
                    if disk.format == "raw", kind == .attach {
                        Picker("Runtime", selection: $target) {
                            Text("Linux host").tag("local")
                            ForEach(targets.filter { $0.formats.contains("raw") && $0.id != "local" }) { target in Text(target.label).tag(target.id) }
                        }
                        Text("The disk is attached as a block device. Formatting is a separate operation inside that operating system.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if disk.format != "raw" {
                        TextField("Mount directory (optional)", text: $mountPath).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
            } footer: {
                Text(kind == .retain ? "Retaining gives this workspace’s root its own disk ID. It survives workspace deletion." : kind == .move ? "Both workspaces must be stopped and in the same namespace." : kind == .attach && selectedDisk?.kind == "root" ? "This saved root becomes a read-only software layer under the workspace’s private files." : "Private disk capacity counts toward account storage until the disk is deleted.")
            }
        }
        .task {
            name = disk.map { $0.displayName + (kind == .save ? " saved" : " copy") } ?? (kind == .retain ? (model.info.value?.name ?? "Workspace") + " root" : "")
            if let size = disk?.sizeMb { capacity = String(kind == .resize ? size + 1024 : size) }
            diskId = disk?.id ?? ""
            if kind == .attach { await model.loadAvailableDisks(); await model.loadImages() }
            if kind == .move { await model.loadWorkspaceChoices(force: true) }
        }
    }
    private func save() async -> Bool {
        await model.diskAction(.init(kind: kind, diskId: selectedDisk?.id, targetWorkspaceId: targetWorkspaceId.isEmpty ? nil : targetWorkspaceId,
            name: needsName ? name : nil, namespace: model.info.value?.namespace, sizeMb: needsCapacity ? Int(capacity) : nil,
            format: kind == .create ? format : nil, mountPath: selectedDisk?.format == "raw" ? nil : mountPath,
            target: selectedDisk?.format == "raw" ? target : nil, readOnly: selectedDisk?.isReadOnly,
            role: selectedDisk?.kind == "root" ? "layer" : nil))
    }
}
