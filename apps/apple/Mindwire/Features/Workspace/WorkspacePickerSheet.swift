import SwiftUI

/// The same workspace selection section in project and agent creation. Inventory and status
/// remain in the shared repository; the parent presents the shared picker in its sheet flow.
struct WorkspaceSelectionSection: View {
    let repository: WorkspaceRepository
    let selectedWorkspaceId: String?
    var footer: String? = nil
    var accessibilityIdentifier = "workspace.selection"
    let onChoose: () -> Void
    let onCreate: () -> Void

    @State private var catalog: [WorkspaceImage] = []

    private var workspace: Workspace? { selectedWorkspaceId.flatMap { repository.get($0) } }

    var body: some View {
        Section {
            if !repository.all.isEmpty {
                Button(action: onChoose) {
                    HStack {
                        if let workspace {
                            Label {
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text(workspace.name).foregroundStyle(.primary)
                                    Text(t("workspacePicker.change"))
                                        .font(.subheadline).foregroundStyle(Palette.accent)
                                }
                            } icon: {
                                WorkspaceImageIcon(image: workspace.image, catalog: catalog, size: 24)
                                    .accessibilityHidden(true)
                            }
                        } else {
                            Label(t("workspacePicker.title"), icon: Icon.workspace)
                        }
                        Spacer(minLength: Spacing.sm)
                        AppIcon(.chevronsUpDown).font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, Spacing.xs)
                }
                .tint(.primary)
                .foregroundStyle(.primary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(accessibilityIdentifier)
            }
            Button(action: onCreate) {
                Label(t("workspacePicker.add"), icon: Icon.plus)
            }
            .tint(.primary)
        } header: {
            Text(t("workspacePicker.section"))
        } footer: {
            if let footer { Text(footer) }
        }
        .task(id: repository.all.compactMap(\.image)) {
            guard repository.all.contains(where: { $0.runtime.isCloud && $0.image != nil }) else { return }
            catalog = await CloudImages.cached()
        }
    }
}

/// Selects from the shared workspace inventory using the same cards as the Workspaces tab.
/// Shares the repository's refresh policy and the existing cached service status.
struct WorkspacePickerSheet: View {
    var repository: WorkspaceRepository = .shared
    let selectedWorkspaceId: String?
    var excludedWorkspaceIds: Set<String> = []
    let onSelect: (Workspace) -> Void

    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: [WorkspaceImage] = []
    @State private var search = ""
    @State private var showLogin = false

    private var workspaces: [Workspace] { repository.all.filter { !excludedWorkspaceIds.contains($0.id) } }
    private var matches: [Workspace] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workspaces }
        return workspaces.filter {
            $0.name.localizedStandardContains(query)
                || CloudImages.displayName($0.image ?? "", in: catalog).localizedStandardContains(query)
        }
    }

    var body: some View {
        let _ = stores.workspaceData.revision
        NavigationStack {
            List {
                if repository.requiresSignIn {
                    Section {
                        MindwireSignInRow(bodyKey: "workspaces.signIn.body") { showLogin = true }
                    }
                }
                if repository.refreshError != nil {
                    Section {
                        Label(t("workspaces.refreshFailed"), icon: .wifiOff)
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button(t("common.retry")) { Task { await repository.refresh() } }
                            .disabled(repository.isRefreshing)
                    }
                }
                ForEach(matches) { workspace in
                    Section {
                        Button {
                            guard let current = repository.get(workspace.id) else { return }
                            onSelect(current)
                            dismiss()
                        } label: {
                            HStack {
                                WorkspaceRow(workspace: workspace, catalog: catalog)
                                if workspace.id == selectedWorkspaceId {
                                    AppIcon(.check)
                                        .foregroundStyle(Palette.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                        .tint(.primary)
                        .entityCardRow(selected: workspace.id == selectedWorkspaceId)
                        .accessibilityAddTraits(workspace.id == selectedWorkspaceId ? .isSelected : [])
                    }
                }
                if matches.isEmpty, repository.hasRefreshed, repository.refreshError == nil {
                    Section {
                        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView.search(text: search)
                        } else {
                            ContentUnavailableView(t("workspaces.empty.title"), icon: Icon.workspace,
                                                   description: Text(t("workspaces.empty.body")))
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(EntityCardStyle.spacing)
            .overlay {
                if workspaces.isEmpty, !repository.hasRefreshed {
                    ProgressView(t("workspaces.loading"))
                }
            }
            .navigationTitle(t("workspacePicker.title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: t("workspacePicker.search"))
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.tint(.primary)
                }
            }
            .refreshable { await repository.refresh() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await repository.refreshIfNeeded() }
        .task(id: workspaces.compactMap(\.image)) {
            guard workspaces.contains(where: { $0.runtime.isCloud && $0.image != nil }) else { return }
            catalog = await CloudImages.cached()
        }
        .mindwireSignIn(isPresented: $showLogin) {
            Task { await repository.refresh() }
        }
    }
}
