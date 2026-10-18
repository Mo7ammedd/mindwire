import SwiftUI

/// Project detail and chat shortcuts share the same tools, labels, and scoped destinations.
enum ProjectTool: String, CaseIterable, Identifiable {
    case sourceControl, files, terminal, desktop

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sourceControl: t("git.sourceControl")
        case .files: t("workspace.files.title")
        case .terminal: t("workspace.terminal.open")
        case .desktop: "Desktop"
        }
    }
    var icon: AppIconName {
        switch self {
        case .sourceControl: Icon.repo
        case .files: Icon.folder
        case .terminal: Icon.terminal
        case .desktop: .monitor
        }
    }

    @MainActor static func available(workspaceId: String, repository: WorkspaceRepository = .shared) -> [Self] {
        allCases.filter { $0 != .desktop || repository.supportsDesktop(workspaceId) }
    }
}

struct ProjectToolButton: View {
    let tool: ProjectTool
    var badge = 0
    var loading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label {
                    Text(tool.title).foregroundStyle(.primary)
                } icon: {
                    AppIcon(tool.icon, decorative: true)
                        .frame(minWidth: 24)
                        .foregroundStyle(Palette.accent)
                }
                Spacer()
                if loading {
                    ProgressView().controlSize(.mini)
                } else if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Palette.accent))
                        .foregroundStyle(Palette.onAccent)
                }
                AppIcon(Icon.chevron).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .tint(.primary)
        .accessibilityIdentifier("project.tool.\(tool.rawValue)")
    }
}

/// Reuses each tool's existing navigation and transport. A borrowed file service stays owned by
/// its caller; opening or closing a shortcut never disposes the chat's daemon session.
struct ProjectToolDestination: View {
    let tool: ProjectTool
    let project: Project
    var files: WorkspaceService? = nil
    var fileLink: WorkspaceFileLink? = nil
    var repository: WorkspaceRepository = .shared
    var embedded = false
    var onDirtyChange: ((Bool) -> Void)? = nil

    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var ownedBackend: Backend?
    @StateObject private var resources = PresentationResources()

    private var workspace: Workspace? { repository.get(project.workspaceId) }

    var body: some View {
        ZStack {
            if let workspace, !repository.requiresSignIn(for: project.workspaceId) {
                switch tool {
                case .sourceControl:
                    SourceControlScreen(workspaceId: project.workspaceId, path: project.path, embedded: embedded)
                case .files:
                    if let service = files ?? ownedBackend?.workspace {
                        Group {
                            if let fileLink {
                                WorkspaceFileLinkView(workspace: service, link: fileLink, project: project)
                            } else {
                                FilesSheet(workspace: service, basePath: project.path, title: project.name,
                                           projectId: project.id, embedded: embedded, onDirtyChange: onDirtyChange)
                            }
                        }.id(workspace.runtime)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .terminal:
                    TerminalScreen(title: project.name, embedded: embedded) {
                        TerminalSessionFactory.provider(for: workspace, stores: stores, workdir: project.path)
                    }
                case .desktop:
                    if embedded && ApplePlatform.isDesktop {
                        DesktopToolSplitView {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(workspace.name, systemImage: "desktopcomputer").font(.system(size: 13))
                                Text("Remote desktop").font(.system(size: 12)).foregroundStyle(.secondary)
                                Spacer()
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        } detail: { desktop(workspace) }
                    } else { desktop(workspace) }
                }
            } else {
                NavigationStack {
                    WorkspaceUnavailableView(workspaceId: project.workspaceId, repository: repository,
                                             projectPath: project.path)
                        .navigationTitle(tool.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            AppToolbarItem(placement: .confirmationAction) {
                                Button(t("common.done")) { dismiss() }.tint(.primary)
                            }
                        }
                }
            }
        }
        .task(id: workspace?.runtime) {
            guard tool == .files, files == nil else { return }
            guard ownedBackend?.runtime != workspace?.runtime else { return }
            let previous = ownedBackend
            // Constructing an adapter does not connect. The access check above gates file reads.
            let backend = workspace.map { BackendFactory.make(forRuntime: $0.runtime, stores: stores) }
            ownedBackend = backend
            resources.cleanup = { await backend?.dispose() }
            if let previous { await previous.dispose() }
        }
    }

    @ViewBuilder private func desktop(_ workspace: Workspace) -> some View {
        if workspace.isCloud {
            DesktopSessionsScreen(workspaceId: workspace.id, project: project, repository: repository)
        } else {
            DesktopScreen(workspaceId: workspace.id, repository: repository)
        }
    }
}
