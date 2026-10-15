import SwiftUI

/// A read-only summary of the shared workspace checks; opening it never starts another probe.
@MainActor
struct WorkspaceStatusOverview {
    struct Entry: Identifiable {
        enum Detail { case service, syncing, syncFailed, checkFailed, powerFailed }
        let workspace: Workspace
        let checking: Bool
        let preparing: Bool
        let needsAttention: Bool
        let hasUpdate: Bool
        let detail: Detail
        var id: String { workspace.id }
    }

    let entries: [Entry]
    let refreshing: Bool
    let inventoryFailed: Bool

    init(repository: WorkspaceRepository, stores: Stores) {
        refreshing = repository.isRefreshing
        inventoryFailed = repository.refreshError != nil
        entries = repository.all.map { workspace in
            let key = DaemonWorkKey(workspaceId: workspace.id)
            let work = DaemonWorkCoordinator.shared.states[key]
            let stopped = work?.workspaceStatus?.power == .stopped && work?.powerAction == nil
            let preparing = work?.workspaceTransitioning == true || stores.preparation.active.contains(key)
                || (work?.running == true && work?.activity != .checking)
            let syncFailed = stores.workspaceData.errors[workspace.id] != nil
            let needsAttention = !preparing && (work?.powerError != nil || (!stopped && (work?.error != nil
                || work?.reachable == false || (work?.reachable == true && work?.supportsProjects == false) || syncFailed)))
            let checking = !stopped && !preparing && (stores.workspaceData.syncing.contains(workspace.id)
                || work?.running == true || (work?.reachable == nil && !needsAttention))
            let serviceReady = work?.reachable == true && work?.supportsProjects == true && work?.error == nil
            let detail: Entry.Detail
            if preparing { detail = .service }
            else if work?.powerError != nil { detail = .powerFailed }
            else if syncFailed && serviceReady { detail = .syncFailed }
            else if needsAttention && work?.reachable == nil && work?.error == nil { detail = .checkFailed }
            else if checking && serviceReady { detail = .syncing }
            else { detail = .service }
            return Entry(workspace: workspace, checking: checking, preparing: preparing,
                         needsAttention: needsAttention,
                         hasUpdate: !stopped && !preparing && !needsAttention && work?.updateAvailable == true,
                         detail: detail)
        }
    }

    var checkingCount: Int { entries.filter(\.checking).count }
    var preparingCount: Int { entries.filter(\.preparing).count }
    var issueCount: Int { entries.filter(\.needsAttention).count }
    var updateCount: Int { entries.filter(\.hasUpdate).count }
    var busy: Bool { refreshing || checkingCount > 0 || preparingCount > 0 }
    var hasIssues: Bool { inventoryFailed || issueCount > 0 }
    var attentionCount: Int { issueCount + (inventoryFailed ? 1 : 0) }

    var title: String {
        if issueCount > 0 { return countLabel("attention", issueCount) }
        if inventoryFailed { return t("workspace.status.refreshFailed") }
        if preparingCount > 0 { return t("workspace.status.preparing") }
        if busy { return t("workspace.status.checking") }
        if updateCount > 0 { return countLabel("updates", updateCount) }
        return t("workspace.status.ready")
    }

    var detail: String? {
        var parts: [String] = []
        if issueCount > 0 && inventoryFailed { parts.append(t("workspace.status.refreshFailed")) }
        if checkingCount > 0 && (hasIssues || preparingCount > 0) {
            parts.append(t("workspace.status.checkingCount", ["count": String(checkingCount)]))
        }
        if preparingCount > 0 && hasIssues {
            parts.append(t("workspace.status.preparingCount", ["count": String(preparingCount)]))
        }
        if updateCount > 0 && (busy || hasIssues) { parts.append(countLabel("updates", updateCount)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func countLabel(_ kind: String, _ count: Int) -> String {
        t("workspace.status.\(kind).\(count == 1 ? "one" : "many")", ["count": String(count)])
    }
}

/// Toolbar indicator shown only for issues, counting affected workspaces and any inventory error.
struct WorkspaceStatusButton: View {
    let overview: WorkspaceStatusOverview
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.xs) {
                AppIcon(.alertCircle)
                Text(overview.attentionCount, format: .number)
            }
            .foregroundStyle(.red)
        }
        .tint(.primary)
        .accessibilityLabel(t("projects.workspaceAttention"))
        .accessibilityValue([overview.title, overview.detail].compactMap { $0 }.joined(separator: ". "))
        .accessibilityIdentifier("projects.workspaceStatus")
    }
}

/// Observes existing status only. Checks run after an explicit refresh, never on presentation.
struct WorkspaceStatusSheet: View {
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: [WorkspaceImage] = []
    @State private var refreshing = false

    var body: some View {
        let overview = WorkspaceStatusOverview(repository: repository, stores: stores)
        let issues = overview.entries.filter(\.needsAttention)
        let working = overview.entries.filter { !$0.needsAttention && ($0.checking || $0.preparing) }
        let others = overview.entries.filter { !$0.needsAttention && !$0.checking && !$0.preparing }
        NavigationStack {
            List {
                if overview.inventoryFailed {
                    Section {
                        Label(t("workspace.status.refreshFailed"), icon: .alertCircle)
                            .foregroundStyle(.red)
                        Text(t("workspace.status.refreshFailedBody"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if !issues.isEmpty {
                    Section(t("workspace.status.issues")) { rows(issues) }
                }
                if !working.isEmpty {
                    Section(t("workspace.status.activity")) { rows(working) }
                }
                if !others.isEmpty {
                    Section(t("tabs.workspaces")) { rows(others) }
                }
                if overview.entries.isEmpty, !overview.inventoryFailed {
                    if overview.refreshing {
                        ProgressView(t("workspace.status.checking"))
                    } else {
                        ContentUnavailableView(t("workspaces.empty.title"), icon: Icon.workspace,
                                               description: Text(t("workspaces.empty.body")))
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(t("projects.workspaceAttention"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .topBarLeading) {
                    Button { Task { await refresh() } } label: {
                        if refreshing { ProgressView().controlSize(.small) }
                        else { AppIcon(.refresh) }
                    }
                    .tint(.primary)
                    .disabled(refreshing)
                    .accessibilityLabel(t("workspace.status.refresh"))
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button(t("common.done")) { dismiss() }.tint(.primary)
                }
            }
            .refreshable { await refresh() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: repository.all.compactMap(\.image)) {
            guard repository.all.contains(where: { $0.runtime.isCloud && $0.image != nil }) else { return }
            catalog = await CloudImages.cached()
        }
    }

    private func rows(_ entries: [WorkspaceStatusOverview.Entry]) -> some View {
        ForEach(entries) { entry in
            WorkspaceStatusRow(entry: entry, catalog: catalog) {
                dismiss()
                app.push(.workspaceDetail(id: entry.id))
            }
        }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await repository.refreshChecks()
    }
}

private struct WorkspaceStatusRow: View {
    let entry: WorkspaceStatusOverview.Entry
    let catalog: [WorkspaceImage]
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(entry.workspace.name).foregroundStyle(.primary)
                        detail
                    }
                } icon: {
                    WorkspaceImageIcon(image: entry.workspace.image, catalog: catalog, size: 22)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: Spacing.sm)
                AppIcon(Icon.chevron).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .tint(.primary)
    }

    @ViewBuilder
    private var detail: some View {
        switch entry.detail {
        case .service:
            WorkspaceDaemonStatusLabel(workspaceId: entry.id, showsProgress: true)
        case .syncing:
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.mini)
                Text(t("workspace.sync.loading"))
            }
            .font(.caption).foregroundStyle(.secondary)
        case .syncFailed, .checkFailed:
            HStack(spacing: Spacing.xs) {
                AppIcon(.alertCircle)
                Text(t(entry.detail == .syncFailed ? "workspace.status.syncFailed" : "workspace.status.checkFailed"))
            }
            .font(.caption).foregroundStyle(.secondary)
        case .powerFailed:
            Label(t("workspace.power.failed"), icon: .alertCircle)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
