import SwiftUI

/// A cached thumbnail with the same icon slot as agent and workspace rows. No remote work here.
struct ProjectIcon: View {
    let project: Project
    @Environment(\.stores) private var stores
    var body: some View {
        ProjectIconArtwork(image: stores.projectPresentation.icon(for: project))
    }
}

struct ProjectIconArtwork: View {
    let image: UIImage?

    var body: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit()
                .clipShape(ProjectIconOutline())
        } else {
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                ZStack {
                    RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                        .fill(Palette.surfaceAlt)
                    AppIcon(.code, size: side * 0.56).foregroundStyle(Palette.textDim)
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }
}

private struct ProjectIconOutline: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: min(rect.width, rect.height) * 0.28, style: .continuous)
            .path(in: rect)
    }
}

struct ProjectIconSheet: View {
    let projectId: String
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var backend: Backend?
    @State private var project: Project?
    @State private var selectedPath: String?
    @State private var candidate: ProjectIconData?
    @State private var preview: UIImage?
    @State private var choosing = false
    @State private var loading = false
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Spacing.lg) {
                        ProjectIconArtwork(image: preview)
                            .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(project?.name ?? "").font(.headline)
                            Text(selectedPath.map { ($0 as NSString).lastPathComponent } ?? t("project.icon.default"))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if loading { ProgressView().controlSize(.small) }
                    }
                    .padding(.vertical, Spacing.sm)
                    Button { choosing = true } label: {
                        Label(t("project.icon.chooseFile"), icon: .folder)
                    }
                    .tint(.primary)
                    .disabled(backend == nil || loading || saving)
                    .accessibilityIdentifier("project.icon.chooseFile")
                    if selectedPath != nil {
                        Button(t("project.icon.reset")) { selectedPath = nil; candidate = nil; preview = nil }
                            .tint(.primary).disabled(loading || saving)
                    }
                } footer: { Text(t("project.icon.formats")) }
            }
            .navigationTitle(t("project.icon.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.tint(.primary).disabled(saving)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: {
                        if saving { ProgressView().controlSize(.small) }
                        else { Text(t("common.save")) }
                    }
                    .tint(.primary).disabled(loading || saving || project == nil || (selectedPath == project?.iconPath && candidate == nil))
                    .accessibilityIdentifier("project.icon.save")
                }
            }
            .task {
                guard project == nil else { return }
                guard let current = stores.projects.get(projectId), let workspace = repository.get(current.workspaceId) else {
                    failure = t("workspace.missing.body"); return
                }
                project = current; selectedPath = current.iconPath
                preview = stores.projectPresentation.icon(for: current)
                backend = BackendFactory.make(forRuntime: workspace.runtime, stores: stores)
                if current.iconPath != nil && preview == nil {
                    loading = true
                    defer { loading = false }
                    do {
                        let icon = try await stores.workspaceData.projectIcon(current.id)
                        try stores.projectPresentation.record(icon: icon, for: current)
                        preview = stores.projectPresentation.icon(for: current)
                    } catch { if !Task.isCancelled { failure = error.localizedDescription } }
                }
            }
            .onDisappear {
                let old = backend; backend = nil
                if let old { Task { await old.dispose() } }
            }
            .sheet(isPresented: $choosing) {
                if let project, let backend {
                    FilesSheet(workspace: backend.workspace, basePath: project.path, title: t("project.icon.chooseFile"),
                               selectFileExtensions: ProjectIconData.extensions) { path in
                        Task { await select(path, in: project) }
                    }
                }
            }
            .alert(t("project.icon.failed"), isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            )) { Button(t("common.ok"), role: .cancel) { failure = nil } } message: { Text(failure ?? "") }
        }
        .interactiveDismissDisabled(saving)
    }

    static func relativePath(_ selected: String, root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard selected.hasPrefix(prefix) else { return nil }
        let relative = String(selected.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" }) else { return nil }
        return relative
    }

    private func select(_ path: String, in project: Project) async {
        guard let relative = Self.relativePath(path, root: project.path) else { failure = t("project.icon.invalidPath"); return }
        loading = true
        defer { loading = false }
        do {
            let icon = try await stores.workspaceData.projectIcon(project.id, path: relative)
            let image = try icon.thumbnail()
            candidate = icon; selectedPath = icon.path; preview = image
        } catch { failure = error.localizedDescription }
    }

    private func save() {
        guard let project, !saving, !loading else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await stores.workspaceData.setProjectIcon(project.id, path: selectedPath)
                if let candidate, let saved = stores.projects.get(project.id) {
                    try stores.projectPresentation.record(icon: candidate, for: saved)
                }
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}
