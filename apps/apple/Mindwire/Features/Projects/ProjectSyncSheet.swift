import SwiftUI

struct ProjectSyncSheet: View {
    let projectId: String
    var repository: WorkspaceRepository = .shared
    let onOpen: (String) -> Void
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var targetWorkspaceId: String?
    @State private var destinationPath = ""
    @State private var choosingWorkspace = false
    @State private var choosingFolder = false
    @State private var backend: Backend?
    @State private var preparing = false
    @State private var failure: String?
    @State private var transferId: String?
    @State private var opened = false
    @State private var fileReview: ProjectSyncFileReview?
    @State private var initialized = false

    private var project: Project? { stores.projects.get(projectId) }
    private var transfer: ProjectTransfer? { transferId.flatMap { stores.projectSync.transfers[$0] } }
    private var target: Workspace? { targetWorkspaceId.flatMap { repository.get($0) } }
    private var existingCopy: Project? {
        guard let syncId = project?.syncId, let targetWorkspaceId else { return nil }
        return stores.projects(forWorkspaceId: targetWorkspaceId).first { $0.syncId == syncId }
    }

    var body: some View {
        NavigationStack {
            Form { formContent }
            .navigationTitle(t("project.transfer.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t(transfer == nil ? "common.cancel" : "common.done")) { dismiss() }.tint(.primary)
                }
                if transfer == nil {
                    AppToolbarItem(placement: .confirmationAction) {
                        Button(t("project.transfer.switch"), action: start)
                            .disabled(project == nil || target == nil || preparing || fileReview?.ready != true || (existingCopy == nil && destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                            .accessibilityIdentifier("project.transfer.start")
                    }
                }
            }
            .sheet(isPresented: $choosingWorkspace) {
                WorkspacePickerSheet(repository: repository, selectedWorkspaceId: targetWorkspaceId,
                                     excludedWorkspaceIds: Set([project?.workspaceId].compactMap { $0 })) { workspace in
                    Task { await choose(workspace) }
                }
            }
            .sheet(isPresented: $choosingFolder) {
                if let backend {
                    FilesSheet(workspace: backend.workspace, basePath: "/", title: t("project.transfer.browse"), selectFolder: true, startPath: "~") { path in
                        destinationPath = path
                    }
                }
            }
            .alert(t("project.transfer.failed"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(t("common.ok"), role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
            .task {
                guard !initialized, let project else { return }
                initialized = true
                destinationPath = "~/" + (project.path as NSString).lastPathComponent
                if let pending = stores.projectSync.transfer(for: project), pending.active || pending.canResume {
                    transferId = pending.id
                }
                if transferId == nil, fileReview == nil {
                    let review = ProjectSyncFileReview(projectId: project.id) {
                        ProjectSyncClient(http: try await stores.workspaceData.projectSyncHTTP(workspaceId: project.workspaceId))
                    }
                    fileReview = review
                    review.refresh()
                }
            }
            .onChange(of: transfer?.status) { _, status in
                if status == "succeeded", let id = transfer?.resultProjectId { open(id) }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            let old = backend; backend = nil
            if let old { Task { await old.dispose() } }
        }
    }

    @ViewBuilder
    private var formContent: some View {
        if let transfer {
            progressSection(transfer)
            if let conflicts = transfer.operation?.conflicts, !conflicts.isEmpty {
                Section(t("project.transfer.conflicts")) {
                    ForEach(conflicts) { conflict in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Label(conflict.displayPath, icon: conflict.kind == "conversation" ? .message : .file)
                                .font(.subheadline).lineLimit(2).truncationMode(.middle)
                            Text(conflict.message).font(.footnote).foregroundStyle(.secondary)
                        }.padding(.vertical, Spacing.xs)
                    }
                }
            }
            if transfer.canResume {
                Section {
                    Button(t("common.retry")) { stores.projectSync.retry(transfer.id) }
                        .accessibilityIdentifier("project.transfer.retry")
                    if ["failed", "conflicts"].contains(transfer.status) {
                        Button(t("project.transfer.reviewAgain")) {
                            stores.projectSync.dismissResult(transfer.id)
                            transferId = nil
                            if let project, fileReview == nil {
                                let review = ProjectSyncFileReview(projectId: project.id) {
                                    ProjectSyncClient(http: try await stores.workspaceData.projectSyncHTTP(workspaceId: project.workspaceId))
                                }
                                fileReview = review
                            }
                            fileReview?.refresh()
                        }
                    }
                }
            }
            if transfer.status == "succeeded", let id = transfer.resultProjectId {
                Section { Button(t("project.transfer.open")) { open(id) } }
            }
        } else {
            selectionSection
            if let fileReview {
                Section {
                    NavigationLink {
                        ProjectSyncFileReviewScreen(review: fileReview)
                    } label: {
                        HStack(spacing: Spacing.md) {
                            AppIcon(.folder).foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(t("project.transfer.files.title"))
                                if let preview = fileReview.preview {
                                    Text(t("project.transfer.files.summary", ["count": String(preview.fileCount), "size": ByteCountFormatter.string(fromByteCount: preview.bytes, countStyle: .file)]))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                } else {
                                    Text(t(fileReview.error == nil ? "project.transfer.files.checking" : "project.transfer.files.reviewRequired"))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: Spacing.sm)
                            if fileReview.loading { ProgressView().controlSize(.small) }
                        }
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("project.transfer.files")
                } footer: { Text(t("project.transfer.files.summaryHelp")) }
            }
            if target != nil, existingCopy == nil {
                Section {
                    HStack {
                        TextField(t("project.transfer.path"), text: $destinationPath)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("project.transfer.path")
                        Button { choosingFolder = true } label: { AppIcon(.folder) }
                            .disabled(backend == nil).accessibilityLabel(t("project.transfer.browse"))
                    }
                } header: { Text(t("project.section.location")) } footer: { Text(t("project.transfer.folderHelp")) }
            } else if let existingCopy {
                Section(t("project.section.location")) {
                    LabeledContent(t("project.transfer.existing"), value: existingCopy.path)
                        .font(.subheadline).lineLimit(2).truncationMode(.middle)
                }
            }
            Section {
                Text(t("project.transfer.preserves")).font(.subheadline).foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
        }
    }

    private var selectionSection: some View {
        Section {
            LabeledContent(t("project.transfer.from"), value: project.flatMap { repository.get($0.workspaceId)?.name } ?? "")
            Button { choosingWorkspace = true } label: {
                HStack(spacing: Spacing.md) {
                    if let target { WorkspaceImageIcon(image: target.image, catalog: [], size: 24) }
                    else { AppIcon(.arrowsLeftRight).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(target?.name ?? t("project.transfer.chooseWorkspace")).foregroundStyle(.primary)
                        if target != nil { Text(t("workspacePicker.change")).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: Spacing.sm)
                    if preparing { ProgressView().controlSize(.small) }
                    else { AppIcon(.chevronsUpDown).font(.caption).foregroundStyle(.tertiary) }
                }
                .padding(.vertical, Spacing.xs)
            }
            .tint(.primary)
            .accessibilityIdentifier("project.transfer.workspace")
        }
    }

    private func progressSection(_ transfer: ProjectTransfer) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    Text(statusTitle(transfer)).font(.headline)
                    Spacer()
                    if transfer.active, transfer.progress == nil { ProgressView().controlSize(.small) }
                }
                if let progress = transfer.progress { ProgressView(value: progress).tint(Palette.accent) }
                if let target = repository.get(transfer.targetWorkspaceId) {
                    Text(target.name).font(.subheadline).foregroundStyle(.secondary)
                }
                if transfer.transferredBytes > 0 {
                    Text(t("project.transfer.bytes", ["size": ByteCountFormatter.string(fromByteCount: transfer.transferredBytes, countStyle: .file)]))
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let error = transfer.error { Text(error).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                else if transfer.status == "paused" { Text(t("project.transfer.pausedBody")).font(.subheadline).foregroundStyle(.secondary) }
                if transfer.status == "recovery_required" {
                    Text(t("project.transfer.recoveryBody")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Spacing.sm)
            .accessibilityIdentifier("project.transfer.progress")
        }
    }

    private func statusTitle(_ transfer: ProjectTransfer) -> String {
        switch transfer.status {
        case "succeeded": return t("project.transfer.complete")
        case "conflicts": return t("project.transfer.conflicts")
        case "recovery_required": return t("project.transfer.recovery")
        case "paused": return t("project.transfer.paused")
        case "failed": return t("project.transfer.failed")
        default: return t("project.transfer.phase." + transfer.phase)
        }
    }

    private func choose(_ workspace: Workspace) async {
        targetWorkspaceId = workspace.id
        let old = backend; backend = BackendFactory.make(forRuntime: workspace.runtime, stores: stores)
        if let old { await old.dispose() }
        preparing = true
        defer { preparing = false }
        do { _ = try await stores.workspaceData.projectSyncHTTP(workspaceId: workspace.id) }
        catch { failure = error.localizedDescription }
    }

    private func start() {
        guard let project, let targetWorkspaceId, let fileReview, fileReview.ready else { return }
        do { transferId = try stores.projectSync.start(project: project, targetWorkspaceId: targetWorkspaceId, path: existingCopy == nil ? destinationPath : nil, includeIgnored: fileReview.includeIgnored, selectionToken: fileReview.preview?.selectionToken) }
        catch { failure = error.localizedDescription }
    }

    private func open(_ id: String) {
        guard !opened else { return }
        opened = true; onOpen(id)
    }
}
