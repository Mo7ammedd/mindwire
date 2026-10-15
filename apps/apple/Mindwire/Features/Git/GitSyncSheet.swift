import SwiftUI

/// One place for remote operations. Closing this sheet only detaches the view;
/// progress and the durable operation remain owned by the existing Git model.
struct GitSyncSheet: View {
    let model: GitModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingPullRequest = false

    private var destination: String? {
        model.status?.branch.map { "origin/" + $0 }
    }
    private var hasTrackingCounts: Bool {
        destination != nil && model.status?.upstream == destination
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(t("git.remote.destination"), value: destination ?? "origin")
                } footer: {
                    if hasTrackingCounts { Text(t("git.remote.countsHint")) }
                }
                Section {
                    action(.pull, icon: .arrowDown, count: hasTrackingCounts ? model.status?.behind : nil)
                    action(.push, icon: .arrowUp, count: hasTrackingCounts ? model.status?.ahead : nil)
                    action(.fetch, icon: .refresh, count: nil)
                } footer: {
                    if model.status?.detached == true { Text(t("git.remote.chooseBranch")) }
                }
                if model.canCreatePullRequest {
                    Section { GitPullRequestButton(model: model) { showingPullRequest = true } }
                }
                GitOperationSections(model: model)
                if let projectId = model.projectId {
                    Section {
                        NavigationLink {
                            GitAccessSettingsScreen(workspaceId: model.workspaceId, projectId: projectId)
                        } label: { Label(t("github.access.title"), icon: .key) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .contentMargins(.top, Spacing.sm, for: .scrollContent)
            .navigationTitle(t("git.remote.actions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) {
                    Button(t("common.done")) { dismiss() }.tint(.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showingPullRequest) { GitPullRequestSheet(model: model) }
    }

    private func action(_ operation: GitRemoteOperation, icon: AppIconName, count: Int?) -> some View {
        Button { Task { await model.runRemote(operation) } } label: {
            HStack(spacing: Spacing.md) {
                AppIcon(icon).frame(width: 22).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(operation.title).font(.body)
                    Text(t("git.remote.\(operation.rawValue).hint"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.sm)
                if let count, count > 0 {
                    Text("\(count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .tint(.primary)
        .disabled(model.isMutating || model.hasPendingOperation || model.projectId == nil
                  || (operation != .fetch && (model.status?.detached == true || model.status?.head == nil)))
        .accessibilityIdentifier("git.remote.\(operation.rawValue)")
    }
}
