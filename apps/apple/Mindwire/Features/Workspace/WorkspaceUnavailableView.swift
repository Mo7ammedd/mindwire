import SwiftUI

/// Shared recovery for stale project/workspace routes. Missing cache entries never delete data.
struct WorkspaceUnavailableView: View {
    let workspaceId: String
    let repository: WorkspaceRepository
    var projectPath: String?
    var removeProject: (() -> Void)?
    var onChooseComputer: (() -> Void)? = nil

    @Environment(AppModel.self) private var app
    @State private var showLogin = false

    var body: some View {
        Group {
            if let onChooseComputer, repository.hasRefreshed || repository.requiresSignIn(for: workspaceId) {
                AssistantPage {
                    AssistantArtwork()
                    AssistantHeading(title: "Connect a computer", detail: "This chat’s computer isn’t connected.")
                    if repository.requiresSignIn(for: workspaceId) {
                        AssistantOption(title: "Mindwire Cloud", detail: "Sign in to reconnect.", icon: .cloud) {
                            showLogin = true
                        }
                    }
                } footer: {
                    AssistantPrimaryButton(title: "Choose a computer", icon: .laptop, action: onChooseComputer)
                }
                .environment(\.assistantTheme, .website)
                .accessibilityIdentifier("chat.computerRequired")
            } else if repository.requiresSignIn(for: workspaceId) {
                MindwireSignInPrompt(bodyKey: "workspace.signIn.body") { showLogin = true }
                    .accessibilityIdentifier("workspace-sign-in-required")
            } else if !repository.hasRefreshed || repository.isRefreshing {
                ProgressView(t("workspace.checking"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailable
            }
        }
        .mindwireSignIn(isPresented: $showLogin) {
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
