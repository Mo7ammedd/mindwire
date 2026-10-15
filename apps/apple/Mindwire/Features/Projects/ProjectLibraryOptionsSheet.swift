import SwiftUI

enum ProjectLibraryAction: String {
    case newProject, newFolder, chooseProjects, renameFolder, deleteFolder, sync
}

/// One entry point for creation and library preferences. Navigation actions are handed back
/// after this sheet dismisses; display preferences update in place without daemon requests.
struct ProjectLibraryOptionsSheet: View {
    let folder: ProjectFolder?
    let perform: (ProjectLibraryAction) -> Void
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    private var library: ProjectLibrary { stores.projectLibrary }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    action(.newProject, title: "newProject.title", icon: .project)
                    if folder != nil {
                        action(.chooseProjects, title: "projects.folder.chooseProjects", icon: .folderPlus)
                    } else {
                        action(.newFolder, title: "projects.folder.new", icon: .folderPlus)
                    }
                }

                Section(t("projects.view")) {
                    Picker(t("projects.layout"), selection: Binding(get: { library.layout }, set: library.setLayout)) {
                        ForEach(ProjectLibraryLayout.allCases, id: \.self) { layout in
                            Label(layout.title, icon: layout == .list ? .list : .grid).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("projects.options.layout")
                    if folder == nil {
                        Picker(t("projects.view"), selection: Binding(get: { library.view }, set: library.setView)) {
                            ForEach(ProjectLibraryView.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("projects.options.view")
                    }
                    Picker(t("projects.sort"), selection: Binding(get: { library.sort }, set: library.setSort)) {
                        ForEach(ProjectLibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("projects.options.sort")
                }

                if library.hasOrganization {
                    Section {
                        action(.sync, title: "projects.library.sync", icon: .refresh)
                    }
                }

                if folder != nil {
                    Section {
                        action(.renameFolder, title: "projects.folder.rename", icon: .edit)
                        DestructiveButton(t("projects.folder.delete"), icon: .trash) { perform(.deleteFolder) }
                            .accessibilityIdentifier("projects.options.deleteFolder")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .contentMargins(.top, Spacing.sm, for: .scrollContent)
            .navigationTitle(folder?.name ?? t("tabs.projects"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) {
                    Button(t("common.done")) { dismiss() }
                        .tint(.primary)
                        .accessibilityIdentifier("projects.options.done")
                }
            }
        }
        .accessibilityIdentifier("projects.optionsSheet")
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(folder == nil ? 500 : 580), .large])
        .presentationDragIndicator(.visible)
    }

    private func action(_ action: ProjectLibraryAction, title: String, icon: AppIconName) -> some View {
        Button { perform(action) } label: {
            Label {
                Text(t(title)).fontWeight(action == .newProject ? .semibold : .regular).foregroundStyle(.primary)
            } icon: {
                AppIcon(icon).foregroundStyle(Palette.accent).accessibilityHidden(true)
            }
        }
        .tint(.primary)
        .accessibilityIdentifier("projects.options.\(action.rawValue)")
    }
}
