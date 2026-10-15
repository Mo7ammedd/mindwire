import SwiftUI

/// Shared recovery for stale project/workspace routes. Missing cache entries never delete data.
struct WorkspaceUnavailableView: View {
    let workspaceId: String
    let repository: WorkspaceRepository
    var projectPath: String?
    var removeProject: (() -> Void)?

    @Environment(AppModel.self) private var app
    @State private var showLogin = false

    var body: some View {
        Group {
            if repository.requiresSignIn(for: workspaceId) {
                OblienSignInPrompt(bodyKey: "workspace.signIn.body") { showLogin = true }
                    .accessibilityIdentifier("workspace-sign-in-required")
            } else if !repository.hasRefreshed || repository.isRefreshing {
                ProgressView(t("workspace.checking"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailable
            }
        }
        .oblienLoginSheet(isPresented: $showLogin) {
            Task { await repository.refresh() }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label(t("workspace.missing.title"), icon: .hardDrive)
        } description: {
            VStack(spacing: Spacing.sm) {
                Text(t(repository.refreshError == nil ? "workspace.missing.body" : "workspace.missing.refreshFailed"))
                if let projectPath {
                    Text(projectPath).font(.caption.monospaced())
                        .lineLimit(2).truncationMode(.middle)
                }
            }
        } actions: {
            VStack(spacing: Spacing.md) {
                Button(t("common.retry")) {
                    Task { await repository.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(repository.isRefreshing)

                Button(t("workspace.viewAll")) {
                    app.workspacesPath = NavigationPath()
                    app.selectedTab = .workspaces
                }
                if let removeProject {
                    Button(t("project.removeFromProjects"), role: .destructive, action: removeProject)
                }
            }
        }
        .accessibilityIdentifier("workspace-unavailable")
    }
}
