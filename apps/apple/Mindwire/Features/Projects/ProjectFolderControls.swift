import SwiftUI

@MainActor @Observable
final class ProjectFolderActions {
    var naming = false
    var name = ""
    var editingId: String?
    var deleting: ProjectFolder?

    func create() { editingId = nil; name = ""; naming = true }
    func rename(_ folder: ProjectFolder) { editingId = folder.id; name = folder.name; naming = true }
}

private struct ProjectFolderPrompts: ViewModifier {
    @Bindable var actions: ProjectFolderActions
    var onCreated: (ProjectFolder) -> Void
    @Environment(\.stores) private var stores

    func body(content: Content) -> some View {
        let library = stores.projectLibrary
        content
            .alert(t(actions.editingId == nil ? "projects.folder.new" : "projects.folder.rename"),
                   isPresented: $actions.naming) {
                TextField(t("projects.folder.name"), text: $actions.name)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("projectFolder.name")
                Button(t("common.cancel"), role: .cancel) { }
                Button(t(actions.editingId == nil ? "common.create" : "common.save")) {
                    if let id = actions.editingId { library.renameFolder(id, name: actions.name) }
                    else if let folder = library.createFolder(name: actions.name) { onCreated(folder) }
                }
                .disabled(!library.validName(actions.name, excluding: actions.editingId))
                .accessibilityIdentifier("projectFolder.saveName")
            } message: {
                if actions.name.count > 80 { Text(t("projects.folder.nameLong")) }
                else if !actions.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        !library.validName(actions.name, excluding: actions.editingId) {
                    Text(t("projects.folder.duplicate"))
                } else { Text(t("projects.folder.nameHelp")) }
            }
            .alert(t("projects.folder.deleteTitle"), isPresented: Binding(
                get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }
            ), presenting: actions.deleting) { folder in
                Button(t("projects.folder.delete"), role: .destructive) { library.deleteFolder(folder.id) }
                    .accessibilityIdentifier("projectFolder.confirmDelete")
                Button(t("common.cancel"), role: .cancel) { }
            } message: { folder in
                Text(t("projects.folder.deleteBody", ["name": folder.name]))
            }
    }
}

extension View {
    func projectFolderPrompts(_ actions: ProjectFolderActions,
                              onCreated: @escaping (ProjectFolder) -> Void = { _ in }) -> some View {
        modifier(ProjectFolderPrompts(actions: actions, onCreated: onCreated))
    }
}

struct ProjectFolderLabel: View {
    let folder: ProjectFolder
    let count: Int
    var iconImages: [UIImage] = []
    var body: some View {
        EntityRow(style: .card) {
            Text(folder.name)
        } subtitle: {
            Text(t(count == 1 ? "projects.folder.projectCountOne" : "projects.folder.projectCount",
                   ["count": "\(count)"]))
        } icon: {
            ProjectFolderIcon(images: iconImages, size: EntityCardStyle.iconSize)
        }
    }
}

/// Native sheet rows reuse the same icon/text columns as project cards.
struct ProjectLibrarySelectionRow: View {
    let project: Project
    var subtitle: String
    var selected: Bool? = nil

    var body: some View {
        EntityRow(style: .card) {
            Text(project.name)
        } subtitle: {
            Text(subtitle)
        } icon: {
            ProjectIcon(project: project)
        } accessory: {
            if let selected {
                AppIcon(selected ? .checkCircleFilled : .circle)
                    .font(.body).foregroundStyle(selected ? Palette.accent : .secondary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected == true ? .isSelected : [])
    }
}
