import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var embeddedWorkspaceTool = false
    @Entry var desktopProjectContext: DesktopProjectContext? = nil
}

@MainActor enum DesktopWorkspaceFocus {
    static func leaveTool() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// Presentation context only. File, Git, terminal, and chat state stays in the shared tools.
struct DesktopProjectContext {
    let project: Project
    let projects: [Project]
    let tool: ProjectTool?
    let tools: [ProjectTool]
    let changedFiles: Int
    let selectTool: (ProjectTool?) -> Void
    let newChat: AnyView
    let actions: AnyView
}

private struct DesktopProjectSidebarHeader: View {
    let context: DesktopProjectContext
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer(minLength: 96)
                Button { app.showProjects() } label: {
                    Label("Projects", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(AssistantDesktopButtonStyle())
                .help("Back to Projects").accessibilityLabel("Back to Projects")
                .accessibilityIdentifier("desktop.project.back")
                Spacer(minLength: 0)
                DesktopNavigationToggle()
            }
            .padding(.horizontal, 12).frame(height: AssistantDesktopStyle.headerHeight)

            HStack(spacing: 10) {
                ProjectIcon(project: context.project).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Menu {
                        ForEach(context.projects) { project in
                            Button { if project.id != context.project.id { app.openProject(project.id) } } label: {
                                if project.id == context.project.id { Label(project.name, systemImage: "checkmark") }
                                else { Text(project.name) }
                            }
                        }
                        Divider()
                        Button("All projects") { app.showProjects() }
                    } label: { Text(context.project.name) }
                    .menuStyle(.borderlessButton).menuIndicator(.visible).buttonStyle(.plain)
                    .tint(.primary).font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Switch project").accessibilityIdentifier("desktop.project.switcher")
                    Text(context.project.path).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AssistantDesktopStyle.surface, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 12).padding(.bottom, 10)

            HStack(spacing: 3) {
                tool("Chats", icon: Icon.chat, value: nil)
                tool("Files", icon: .folder, value: .files)
                tool("Changes", icon: .gitBranch, value: .sourceControl)
                tool("Terminal", icon: .terminal, value: .terminal)
                if context.tools.contains(.desktop) { tool("Desktop", icon: .monitor, value: .desktop) }
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .background(AssistantDesktopStyle.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(AssistantDesktopStyle.separator).frame(height: 0.5) }
    }

    private func tool(_ title: String, icon: AppIconName, value: ProjectTool?) -> some View {
        Button { context.selectTool(value) } label: {
            VStack(spacing: 5) {
                AppIcon(icon, size: 16)
                    .overlay(alignment: .topTrailing) {
                        if value == .sourceControl, context.changedFiles > 0 {
                            Circle().fill(Palette.accent).frame(width: 5, height: 5).offset(x: 5, y: -2)
                        }
                    }
                Text(title).font(.system(size: 10, weight: context.tool == value ? .medium : .regular))
            }
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(context.tool == value ? AssistantDesktopStyle.selection : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(AssistantDesktopButtonStyle())
        .foregroundStyle(context.tool == value ? Color.primary : .secondary)
        .help(title).accessibilityLabel(title)
        .accessibilityAddTraits(context.tool == value ? .isSelected : [])
        .accessibilityIdentifier("desktop.project.tab.\(value?.rawValue ?? "overview")")
    }
}

private struct DesktopProjectDetailHeader: View {
    let context: DesktopProjectContext
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(spacing: 12) {
            if !app.desktopToolSidebarVisible {
                DesktopNavigationToggle()
                Button { app.showProjects() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(AssistantDesktopButtonStyle()).help("Back to Projects")
                    .accessibilityLabel("Back to Projects").accessibilityIdentifier("desktop.project.back")
            }
            Text(context.tool == .sourceControl ? "Source Control" : context.tool == .terminal ? "Terminal" : context.tool?.title ?? context.project.name)
                .font(.system(size: 14, weight: .medium))
            Spacer(minLength: 12)
            context.newChat.font(.system(size: 12)).buttonStyle(AssistantDesktopButtonStyle())
            context.actions.frame(width: 28, height: 28)
        }
        .padding(.horizontal, 20).padding(.leading, app.desktopToolSidebarVisible ? 0 : 76)
        .frame(height: AssistantDesktopStyle.headerHeight)
        .background(AssistantDesktopStyle.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(AssistantDesktopStyle.separator).frame(height: 0.5) }
    }
}

struct DesktopWorkspaceCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(AssistantDesktopStyle.surface, in: .rect(cornerRadius: 14))
    }
}

struct DesktopBrowserSearch: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9).frame(height: 30)
        .background(AssistantDesktopStyle.surface, in: .rect(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

/// Developer navigation lives inside the same desktop sidebar as General conversations.
/// Rows only select a destination; the existing project/workspace screens own all operations.
struct DesktopDeveloperItems: View {
    let section: AppTab
    let search: String
    var repository: WorkspaceRepository = .shared
    @Environment(AppModel.self) private var app
    @Environment(\.stores) private var stores
    @State private var projects: [Project] = []
    @State private var removal = ProjectRemovalActions()
    @State private var workspaceActions = WorkspaceActionState()
    @State private var connections: [Connection] = []
    @State private var selectedConnection: Connection?

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matchingProjects: [Project] {
        projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
    }
    private var computers: [Workspace] {
        repository.all.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.computerKind(in: stores).localizedCaseInsensitiveContains(query) }
            .sorted { lhs, rhs in
                if lhs.runtime.isLocal != rhs.runtime.isLocal { return lhs.runtime.isLocal }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
    private var unassignedConnections: [Connection] {
        ComputerInventory(workspaces: repository.all, connections: connections).unassignedConnections
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.displayAddress.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if section == .projects {
                if matchingProjects.isEmpty { empty("No projects") }
                ForEach(matchingProjects) { project in
                    Button { app.openProject(project.id) } label: {
                        DesktopDeveloperRow(title: project.name, subtitle: project.path,
                                            selected: app.desktopProjectID == project.id) {
                            ProjectIcon(project: project).frame(width: 30, height: 30)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("desktop.project.\(project.id)")
                    .contextMenu {
                        Button("Open project") { app.openProject(project.id) }
                        Button("Show computer") { app.openWorkspace(project.workspaceId) }
                        Divider()
                        ProjectRemovalMenuItems(project: project, actions: removal, repository: repository)
                    }
                    .desktopSidebarRow()
                }
            } else {
                if computers.isEmpty && unassignedConnections.isEmpty { empty("No computers") }
                ForEach(computers) { workspace in
                    Button { app.openWorkspace(workspace.id) } label: {
                        DesktopDeveloperRow(title: workspace.runtime.isLocal ? "This Mac" : workspace.name,
                                            subtitle: workspace.computerKind(in: stores),
                                            selected: app.desktopWorkspaceID == workspace.id) {
                            AppIcon(workspace.runtime.isLocal ? .laptop : workspace.isCloud ? .cloud : .server, size: 24)
                                .foregroundStyle(.secondary).frame(width: 30, height: 30)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("desktop.computer.\(workspace.id)")
                    .contextMenu { WorkspaceMenuActions(workspace: workspace, actions: workspaceActions) }
                    .desktopSidebarRow()
                }
                ForEach(unassignedConnections) { connection in
                    Button { selectedConnection = connection } label: {
                        DesktopDeveloperRow(title: connection.name, subtitle: connection.displayAddress, selected: selectedConnection?.id == connection.id) {
                            ModeIcon(type: connection.type, size: 24, color: .secondary)
                                .frame(width: 30, height: 30)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("desktop.connection.\(connection.id)")
                    .desktopSidebarRow()
                }
            }
        }
        .onAppear(perform: reload)
        .observeWorkspaceCache(reload)
        .onChange(of: stores.projects.revision) { reload() }
        .onChange(of: stores.connections.revision) { reload() }
        .onChange(of: repository.revision) { reload() }
        .projectRemovalAlerts(removal, repository: repository)
        .workspaceActionPresentation(workspaceActions, repository: repository)
        .sheet(item: $selectedConnection) { connection in
            ComputerConnectionSheet(connection: connection, repository: repository)
        }
    }

    private func empty(_ title: String) -> some View {
        Text(query.isEmpty ? title : "No results").font(.system(size: 13)).foregroundStyle(.secondary)
            .padding(.vertical, 20).desktopSidebarRow()
    }

    private func reload() {
        connections = stores.connections.list()
        let ids = Set(repository.all.map(\.id))
        projects = stores.projects.list().filter { ids.contains($0.workspaceId) }.sorted {
            let lhs = $0.lastUsedAt ?? $0.createdAt, rhs = $1.lastUsedAt ?? $1.createdAt
            return lhs == rhs ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : lhs > rhs
        }
    }
}

private struct DesktopDeveloperRow<Icon: View>: View {
    let title: String
    let subtitle: String
    let selected: Bool
    @ViewBuilder let icon: () -> Icon
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            icon()
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: selected ? .medium : .regular)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AssistantDesktopStyle.selection : hovered ? Color.primary.opacity(0.04) : .clear,
                    in: .rect(cornerRadius: 14))
        .contentShape(.rect(cornerRadius: 14))
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension View {
    func desktopSidebarRow() -> some View {
        listRowInsets(.init(top: 0, leading: AssistantDesktopStyle.sidebarInset, bottom: 0, trailing: AssistantDesktopStyle.sidebarInset))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}

struct DesktopDeveloperLanding: View {
    let section: AppTab
    @Environment(AppModel.self) private var app
    @Environment(\.stores) private var stores
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            DesktopWorkspaceHeader(title: section == .projects ? t("tabs.projects") : "Computers",
                                   subtitle: "", icon: section == .projects ? .folder : .laptop) {
                Button { creating = true } label: { AppIcon(.plus, size: 18).frame(width: 32, height: 32) }
                    .buttonStyle(AssistantDesktopButtonStyle())
                    .help(section == .projects ? "New project" : "Add computer")
            }
            VStack(spacing: 16) {
                AppIcon(section == .projects ? .folder : .laptop, size: 36).foregroundStyle(.tertiary)
                Text(section == .projects ? "Choose a project" : "Choose a computer")
                    .font(.system(size: 20, weight: .medium))
                Text(section == .projects ? "Your files, terminal, and conversations in one project." : "Use this Mac or manage a remote computer.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button(section == .projects ? "New project" : "Add computer") { creating = true }
                    .buttonStyle(.borderedProminent).tint(Palette.accent).controlSize(.regular)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AssistantDesktopStyle.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $creating) {
            if section == .projects { NewProjectScreen().frame(width: 660, height: 580) }
            else { AddComputerScreen { app.openWorkspace($0.id) }.frame(width: 660, height: 580) }
        }
    }
}

/// Matching header geometry for desktop chat, project, and computer panes.
struct DesktopWorkspaceHeader<Actions: View>: View {
    @Environment(AppModel.self) private var app
    let title: String
    var subtitle = ""
    let icon: AppIconName
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            if !app.desktopSidebarVisible { DesktopNavigationToggle() }
            if app.selectedTab == .workspaces, app.desktopWorkspaceID != nil {
                Button { app.showComputers() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(AssistantDesktopButtonStyle()).help("Back to Computers")
                    .accessibilityLabel("Back to Computers").accessibilityIdentifier("desktop.computer.back")
            }
            AppIcon(icon, size: 21).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 12)
            actions().font(.system(size: 13))
        }
        .padding(.horizontal, AssistantDesktopStyle.gutter)
        .padding(.leading, app.desktopSidebarVisible ? 0 : 76)
        .frame(height: AssistantDesktopStyle.headerHeight)
        .background(AssistantDesktopStyle.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(AssistantDesktopStyle.separator).frame(height: 0.5) }
    }
}

struct DesktopNavigationToggle: View {
    @Environment(AppModel.self) private var app
    private var title: String {
        if app.desktopBotRailVisible { return "Expand sidebar" }
        return app.desktopNavigationVisible ? "Collapse sidebar" : "Show sidebar"
    }
    var body: some View {
        Button { app.toggleDesktopSidebar() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 17)).frame(width: 32, height: 32)
        }
        .buttonStyle(AssistantDesktopButtonStyle()).foregroundStyle(.secondary)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("desktop.navigation.toggle")
    }
}

/// Embedded desktop tools share one browser/editor layout. Keeping their navigation stacks
/// mounted retains selections and unsaved buffers when the main navigation is opened or closed.
struct DesktopToolSplitView<Browser: View, Detail: View>: View {
    @ViewBuilder let browser: () -> Browser
    @ViewBuilder let detail: () -> Detail
    var showsDetailHeader = true
    @Environment(AppModel.self) private var app
    @Environment(\.desktopProjectContext) private var projectContext
    @State private var dragStart: CGFloat?
    private var width: CGFloat { app.desktopBrowserWidth }

    private var visible: Bool { (projectContext != nil || !app.desktopSidebarVisible) && app.desktopToolSidebarVisible }

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = min(width, max(240, geometry.size.width * 0.4))
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let projectContext { DesktopProjectSidebarHeader(context: projectContext) }
                    browser().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                    .frame(width: columnWidth, height: geometry.size.height)
                    .background(AssistantDesktopStyle.sidebar)
                    .frame(width: visible ? columnWidth : 0, alignment: .leading)
                    .clipped().allowsHitTesting(visible).accessibilityHidden(!visible)
                Rectangle().fill(AssistantDesktopStyle.separator)
                    .frame(width: visible ? 1 : 0)
                    .overlay {
                        if visible {
                            Color.clear.frame(width: 9).contentShape(.rect)
                                .gesture(DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        if dragStart == nil { dragStart = width }
                                        app.desktopBrowserWidth = min(400, max(240, (dragStart ?? width) + value.translation.width))
                                    }
                                    .onEnded { _ in dragStart = nil })
                                .accessibilityLabel("Resize browser")
                                .accessibilityAdjustableAction { direction in
                                    app.desktopBrowserWidth = min(400, max(240, width + (direction == .increment ? 20 : -20)))
                                }
                        }
                    }
                VStack(spacing: 0) {
                    if showsDetailHeader, let projectContext { DesktopProjectDetailHeader(context: projectContext) }
                    detail().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(AssistantDesktopStyle.canvas)
    }
}

/// Mode is app-wide, so an edit in any window must finish before changing experiences.
@MainActor @Observable final class DesktopFileEditing {
    static let shared = DesktopFileEditing()
    var editors: Set<UUID> = []
    var hasUnsavedChanges: Bool { !editors.isEmpty }
}

struct DesktopWorkspaceTab: View {
    let title: String
    let icon: AppIconName
    let selected: Bool
    var badge = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                AppIcon(icon, size: 15)
                Text(title).font(.system(size: 12, weight: selected ? .medium : .regular))
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Palette.accent.opacity(0.14), in: .capsule).foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(selected ? AssistantDesktopStyle.selection : .clear, in: .rect(cornerRadius: 9))
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(AssistantDesktopButtonStyle())
        .foregroundStyle(selected ? Color.primary : .secondary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
