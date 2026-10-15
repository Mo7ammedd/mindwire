import SwiftUI

/// One on-demand lookup chooses the existing directory browser or file/image editor.
struct WorkspaceFileLinkView: View {
    let workspace: WorkspaceService
    let link: WorkspaceFileLink
    let project: Project?
    var basePath: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var target: Target?
    @State private var error: String?
    @State private var loading = false

    private struct Target {
        let root: String
        let folder: String
        let file: String?
    }

    var body: some View {
        Group {
            if let target {
                FilesSheet(workspace: workspace, basePath: target.root, title: project?.name ?? t("workspace.files.title"),
                           startPath: target.folder, projectId: project?.id,
                           initialFile: target.file, initialLine: link.line, allowsQuickClose: true)
            } else {
                NavigationStack {
                    Group {
                        if let error {
                            ContentUnavailableView {
                                Label(t("editor.loadFailed"), icon: .fileWarning)
                            } description: { Text(error) } actions: {
                                Button(t("common.retry")) { Task { await load() } }
                            }
                        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                    .navigationTitle((link.path as NSString).lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { AppToolbarItem(placement: .confirmationAction) {
                        Button(t("common.done")) { dismiss() }.tint(.primary)
                    } }
                }
            }
        }
        .task(id: link) { await load() }
    }

    private func load() async {
        guard target == nil, !loading else { return }
        loading = true
        defer { loading = false }
        error = nil
        do {
            guard let base = basePath ?? project?.path else { throw ChatLinkError.missingContext }
            let home = link.path.hasPrefix("~") || base.hasPrefix("~") ? try await workspace.homeDirectory() : nil
            let path = try link.resolvedPath(root: base, home: home)
            let root = try WorkspaceFileLink(path: project?.path ?? base).resolvedPath(root: "/", home: home)
            let quoted = workspace.shell.quote(path)
            let result = try await workspace.exec(workspace.shell.command(
                "if [ -d \(quoted) ]; then printf directory; elif [ -f \(quoted) ]; then printf file; else printf missing; fi"))
            try Task.checkCancellation()
            guard result.exitCode == nil || result.exitCode == 0 else {
                throw BackendError.message(result.stderr.isEmpty ? t("editor.loadFailed") : result.stderr)
            }
            let kind = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard kind == "directory" || kind == "file" else { throw ChatLinkError.missingFile }
            let withinProject = root == "/" || path == root || path.hasPrefix(root + "/")
            target = Target(root: withinProject ? root : "/",
                            folder: kind == "directory" ? path : (path as NSString).deletingLastPathComponent,
                            file: kind == "file" ? path : nil)
        } catch {
            if !Task.isCancelled && !error.isRequestCancellation { self.error = error.localizedDescription }
        }
    }
}
