import SwiftUI

/// The four-tab shell. The bottom bar is the native `TabView` — Liquid Glass is automatic.
struct MainScene: View {
    var repository: WorkspaceRepository = .shared
    @Environment(AppModel.self) private var app
    @Environment(\.stores) private var stores

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            // Projects is the primary tab — the main way in (a project = agents working in a folder).
            Tab(value: AppTab.projects) {
                ProjectsTab(repository: repository)
            } label: {
                Label { Text(t("tabs.projects")) } icon: { AppIcon(.project, size: 24, decorative: true) }
                    .accessibilityLabel(t("tabs.projects"))
            }
            Tab(value: AppTab.agents) {
                AgentsTab(repository: repository)
            } label: {
                Label { Text(t("tabs.agents")) } icon: { AppIcon(Icon.agents, size: 24, decorative: true) }
                    .accessibilityLabel(t("tabs.agents"))
            }
            Tab(value: AppTab.workspaces) {
                WorkspacesTab(repository: repository)
            } label: {
                Label { Text(t("tabs.workspaces")) } icon: { AppIcon(Icon.workspace, size: 24, decorative: true) }
                    .accessibilityLabel(t("tabs.workspaces"))
            }
            Tab(value: AppTab.settings) {
                SettingsTab()
            } label: {
                Label { Text(t("tabs.settings")) } icon: { AppIcon(Icon.settings, size: 24, decorative: true) }
                    .accessibilityLabel(t("tabs.settings"))
            }
        }
        #if targetEnvironment(macCatalyst)
        .task { await LocalComputer.shared.prepare(stores: stores, repository: repository) }
        #endif
    }
}
