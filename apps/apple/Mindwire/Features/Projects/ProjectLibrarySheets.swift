import SwiftUI

/// Moving a project is a local organization change and remains available while offline.
struct ProjectMoveToFolderSheet: View {
    let project: Project
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var actions = ProjectFolderActions()

    private var currentProject: Project { stores.projects.get(project.id) ?? project }

    var body: some View {
        let library = stores.projectLibrary
        let project = currentProject
        let projects = stores.projectsByRecency()
        NavigationStack {
            List {
                Section {
                    Button { move(to: nil) } label: {
                        HStack {
                            Label(t("projects.folder.none"), icon: .list)
                            Spacer()
                            if library.folderId(for: project) == nil { AppIcon(.check).foregroundStyle(Palette.accent) }
                        }
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("projectFolder.move.none")
                }
                Section {
                    ForEach(library.folders) { folder in
                        let members = projects.filter { library.folderId(for: $0) == folder.id }
                        Button { move(to: folder.id) } label: {
                            HStack {
                                ProjectFolderLabel(folder: folder, count: members.count,
                                    iconImages: Array(members.lazy.compactMap { stores.projectPresentation.icon(for: $0) }.prefix(4)))
                                if library.folderId(for: project) == folder.id { AppIcon(.check).foregroundStyle(Palette.accent) }
                            }
                        }
                        .tint(.primary)
                        .accessibilityIdentifier("projectFolder.move.\(folder.id)")
                    }
                }
            }
            .navigationTitle(t("projects.folder.move"))
            .navigationSubtitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.tint(.primary)
                }
                AppToolbarItem(placement: .topBarTrailing) {
                    Button { actions.create() } label: { AppIcon(.folderPlus) }
                        .tint(.primary)
                        .accessibilityLabel(t("projects.folder.new"))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .projectFolderPrompts(actions) { folder in move(to: folder.id) }
    }

    private func move(to folderId: String?) {
        if stores.projectLibrary.move([currentProject], to: folderId) { dismiss() }
    }
}

/// A draft selection commits on Done. Search never drops selections that are currently hidden.
struct ProjectFolderMembersSheet: View {
    let folderId: String
    var workspaceId: String?
    var repository: WorkspaceRepository = .shared
    var onCreateProject: () -> Void
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [Project] = []
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var loaded = false
    @State private var hasProjects = false

    var body: some View {
        let library = stores.projectLibrary
        let eligible = library.eligibleMembers(candidates.map { stores.projects.get($0.id) ?? $0 }, in: folderId)
        let shown = eligible.filter(matchesSearch)
        let members = shown.filter { library.folderId(for: $0) == folderId }
        let available = shown.filter { library.folderId(for: $0) == nil }
        NavigationStack {
            Group {
                if eligible.isEmpty {
                    ProjectLibraryEmptyState(
                        title: t(hasProjects ? "projects.folder.allAssigned" : "projects.folder.noProjects"),
                        message: t(hasProjects ? "projects.folder.allAssignedBody" : "projects.folder.createFirst")
                    ) {
                        Button(action: onCreateProject) {
                            Text(t("projects.empty.cta")).padding(.horizontal, Spacing.md)
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("projectFolder.createProject")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.bg)
                } else {
                    List {
                        if !members.isEmpty {
                            Section(t("projects.folder.members")) { memberRows(members) }
                        }
                        if !available.isEmpty {
                            Section(t("projects.folder.available")) { memberRows(available) }
                        }
                    }
                    .listSectionSpacing(.compact)
                    .overlay {
                        if shown.isEmpty { ContentUnavailableView.search(text: search) }
                    }
                    .searchable(text: $search, prompt: t("projects.folder.search"))
                    .searchToolbarBehavior(.minimize)
                }
            }
            .navigationTitle(t("projects.folder.chooseProjects"))
            .navigationSubtitle(library.folder(folderId)?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.tint(.primary)
                }
                if !eligible.isEmpty {
                    AppToolbarItem(placement: .confirmationAction) {
                        Button(t("common.done")) {
                            // A sync ID can arrive while this draft is open. Save using the latest
                            // identity without changing which rows the user selected.
                            let latest = candidates.map { stores.projects.get($0.id) ?? $0 }
                            let keys = Set(latest.filter { selected.contains($0.id) }.map { library.key(for: $0) })
                            library.setMembers(keys, in: folderId, candidates: latest)
                            dismiss()
                        }
                        .accessibilityIdentifier("projectFolder.saveMembers")
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                let projects = workspaceId.map { stores.developerProjects(workspaceId: $0) } ?? stores.projectsByRecency()
                hasProjects = !projects.isEmpty
                candidates = library.sorted(library.eligibleMembers(projects, in: folderId))
                selected = Set(candidates.filter { library.folderId(for: $0) == folderId }.map(\.id))
                loaded = true
            }
            .onChange(of: library.folder(folderId)?.id) { _, id in if id == nil { dismiss() } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func matchesSearch(_ project: Project) -> Bool {
        search.isEmpty || project.name.localizedStandardContains(search)
            || (repository.get(project.workspaceId)?.name.localizedStandardContains(search) == true)
    }

    private func memberRows(_ projects: [Project]) -> some View {
        ForEach(projects) { project in
            Button {
                if !selected.insert(project.id).inserted { selected.remove(project.id) }
            } label: {
                ProjectLibrarySelectionRow(project: project,
                    subtitle: repository.get(project.workspaceId)?.name ?? "",
                    selected: selected.contains(project.id))
            }
            .tint(.primary)
            .accessibilityIdentifier("projectFolder.member.\(project.id)")
        }
    }
}
