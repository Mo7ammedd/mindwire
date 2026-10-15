import SwiftUI

enum SidebarDestination: Hashable {
    case app(AppRoute)
    case settings(SettingsRoute)

    func append(to path: inout NavigationPath) {
        switch self {
        case .app(let route): path.append(route)
        case .settings(let route): path.append(route)
        }
    }
}

struct SidebarNavigation {
    let selected: SidebarDestination?
    let select: (SidebarDestination) -> Void
}

struct SidebarControls {
    let hidden: Bool
    let toggle: () -> Void
}

extension View {
    func sidebarToolbar(_ controls: SidebarControls?) -> some View {
        toolbar {
            if let controls {
                AppToolbarItem(placement: .topBarLeading) {
                    Button(action: controls.toggle) { AppIcon(controls.hidden ? .sidebarOpen : .sidebarClose) }
                        .tint(.primary)
                        .keyboardShortcut("s", modifiers: [.command, .control])
                        .accessibilityLabel(controls.hidden ? "Show sidebar" : "Hide sidebar")
                        .accessibilityIdentifier("navigation.toggleSidebar")
                }
            }
        }
    }
}

private struct SidebarNavigationKey: EnvironmentKey {
    static let defaultValue: SidebarNavigation? = nil
}

extension EnvironmentValues {
    var sidebarNavigation: SidebarNavigation? {
        get { self[SidebarNavigationKey.self] }
        set { self[SidebarNavigationKey.self] = newValue }
    }
}

/// Root rows select the detail column on iPad and retain native push navigation on iPhone.
struct RootNavigationLink<Content: View>: View {
    let destination: SidebarDestination
    var usesDefaultRowBackground = true
    @ViewBuilder let label: () -> Content
    @Environment(\.sidebarNavigation) private var sidebar

    init(value: AppRoute, usesDefaultRowBackground: Bool = true, @ViewBuilder label: @escaping () -> Content) {
        destination = .app(value)
        self.usesDefaultRowBackground = usesDefaultRowBackground
        self.label = label
    }

    init(value: SettingsRoute, @ViewBuilder label: @escaping () -> Content) {
        destination = .settings(value)
        self.label = label
    }

    var body: some View {
        if let sidebar {
            if usesDefaultRowBackground {
                selectionButton(sidebar)
                    .listRowBackground(sidebar.selected == destination
                                       ? Palette.accent.opacity(0.12) : Color(.secondarySystemGroupedBackground))
            } else {
                selectionButton(sidebar)
            }
        } else {
            switch destination {
            case .app(let route): NavigationLink(value: route, label: label)
            case .settings(let route): NavigationLink(value: route, label: label)
            }
        }
    }

    private func selectionButton(_ sidebar: SidebarNavigation) -> some View {
        Button { withAnimation(.snappy) { sidebar.select(destination) } } label: {
            label().frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(sidebar.selected == destination ? .isSelected : [])
    }
}

/// The detail NavigationStack stays in the same position in the view tree as the window resizes.
/// Its original path, live chat, draft and back history therefore survive adding/removing a sidebar.
struct AdaptiveTabNavigation<Root: View>: View {
    @Binding var path: NavigationPath
    let tab: AppTab
    let title: String
    let selectionPrompt: String
    var repository: WorkspaceRepository = .shared
    @ViewBuilder let root: () -> Root
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @State private var selected: SidebarDestination?

    private var sidebarHidden: Bool { app.hiddenSidebars.contains(tab) }
    private var sidebarPath: Binding<NavigationPath> {
        Binding(get: { app.sidebarPaths[tab] ?? NavigationPath() },
                set: { app.sidebarPaths[tab] = $0 })
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = AdaptiveLayout.usesColumns(width: geometry.size.width, regular: sizeClass == .regular,
                                                  accessibility: typeSize.isAccessibilitySize)
            let controls = wide ? SidebarControls(hidden: sidebarHidden) {
                withAnimation(.snappy) {
                    if sidebarHidden { app.hiddenSidebars.remove(tab) }
                    else { app.hiddenSidebars.insert(tab) }
                }
            } : nil
            HStack(spacing: 0) {
                if wide && !sidebarHidden {
                    NavigationStack(path: sidebarPath) {
                        root()
                            .withAppRoutes(repository: repository)
                    }
                    .environment(\.sidebarNavigation, SidebarNavigation(selected: selected) { route in
                        selected = route
                        var next = NavigationPath()
                        route.append(to: &next)
                        path = next
                    })
                    .frame(width: AdaptiveLayout.sidebarWidth(in: geometry.size.width))
                    .accessibilityIdentifier("navigation.sidebar")
                    Divider()
                }
                NavigationStack(path: $path) {
                    Group {
                        if wide {
                            VStack(spacing: Spacing.sm) {
                                Text(selectionPrompt).font(.title3.weight(.semibold))
                                Text("Your workspace, ready when you are.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.center)
                            .padding(Spacing.xl)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.systemGroupedBackground))
                            .navigationTitle(title)
                            .navigationBarTitleDisplayMode(.inline)
                        } else { root() }
                    }
                    .sidebarToolbar(controls)
                    .withAppRoutes(hideBackButton: wide && path.count == 1, repository: repository,
                                   sidebarControls: controls, onRouteAppear: rememberSelection)
                }
                .environment(\.sidebarNavigation, nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("navigation.detail")
            }
            .onChange(of: path.isEmpty) { _, empty in if empty { selected = nil } }
        }
    }

    private func rememberSelection(_ route: AppRoute) {
        let root: AppRoute?
        switch (tab, route) {
        case (.projects, .projectDetail): root = route
        case (.projects, .chat(let id)):
            root = stores.chats.get(id).map { .projectDetail(id: $0.projectId) }
        case (.agents, .agentDetail): root = route
        case (.agents, .agentAuthentication(let id)): root = .agentDetail(agentId: id)
        case (.agents, .chat(let id)):
            root = stores.chats.get(id).map { .agentDetail(agentId: $0.agentId) }
        case (.workspaces, .workspaceDetail): root = route
        case (.workspaces, .workspaceProjects(let id)): root = .workspaceDetail(id: id)
        case (.workspaces, .projectDetail(let id)):
            root = stores.projects.get(id).map { .workspaceDetail(id: $0.workspaceId) }
        default: root = nil
        }
        if let root, selected != .app(root) { selected = .app(root) }
    }
}
