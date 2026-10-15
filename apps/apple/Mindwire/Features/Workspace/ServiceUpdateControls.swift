import SwiftUI

/// A compact entry point; both actions use the app's existing workspace update queue.
struct ServiceUpdatesMenu: View {
    let workspaces: [Workspace]
    @Environment(\.stores) private var stores
    @Environment(\.serviceUpdatePresentation) private var presentation
    @State private var checkFailed = false
    private var updates: ServiceUpdateScheduler { stores.serviceUpdates }

    var body: some View {
        AppMenu {
            Button(t("agentUpdates.checkUpdates"), icon: .refresh) { check(update: false) }
                .disabled(updates.busy)
            Button(t("workspace.daemon.updateAll"), icon: .download) { check(update: true) }
                .disabled(updates.busy)
            Button(t("workspace.daemon.info"), icon: .info) { presentation?.show() }
            if updates.releaseCheckedAt != nil || updates.releaseCheckError != nil || !updates.active.isEmpty || updates.waitingCount > 0 {
                Section { ServiceUpdateSummary() }
            }
        } label: {
            if updates.busy { ProgressView().controlSize(.small) }
            else { AppIcon(.refresh) }
        }
        .tint(.primary)
        .disabled(workspaces.isEmpty)
        .accessibilityLabel(t("workspace.daemon.updates"))
        .accessibilityIdentifier("workspace-service-updates")
        .alert(t("workspace.daemon.checkUpdatesFailedTitle"), isPresented: $checkFailed) {
            Button(t("common.ok"), role: .cancel) {}
        } message: {
            Text(updates.releaseCheckError ?? t("workspace.daemon.checkUpdatesFailed"))
        }
    }

    private func check(update: Bool) {
        presentation?.show()
        Task {
            let succeeded = update ? await updates.updateAll(workspaces) : await updates.checkUpdates(workspaces)
            checkFailed = !succeeded
        }
    }
}

struct ServiceUpdatesSettingsSection: View {
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @Environment(\.serviceUpdatePresentation) private var presentation
    @State private var checkFailed = false
    private var updates: ServiceUpdateScheduler { stores.serviceUpdates }

    var body: some View {
        Section {
            ServiceAutomaticUpdatesToggle()
            VStack(alignment: .leading, spacing: Spacing.md) {
                Button {
                    presentation?.show()
                    Task { checkFailed = !(await updates.updateAll(repository.all)) }
                } label: {
                    HStack {
                        Label(t("workspace.daemon.updateAll"), icon: .download)
                            .foregroundStyle(.primary)
                        Spacer()
                        if updates.busy { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .disabled(repository.all.isEmpty || updates.busy)
                .accessibilityIdentifier("settings-update-all-services")
                ForEach(updates.active.sorted(), id: \.self) { id in
                    if let work = updates.work(for: id), work.changingService {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            if updates.active.count > 1, let workspace = repository.get(id) {
                                Text(workspace.name).font(.caption.weight(.medium))
                            }
                            WorkspaceDaemonProgress(work: work)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(t("workspace.daemon.title"))
                Spacer()
                Button { presentation?.show() } label: {
                    AppIcon(.info)
                        .frame(minWidth: 32, minHeight: 32)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.borderless)
                    .tint(.secondary)
                    .accessibilityLabel(t("workspace.daemon.info"))
                    .accessibilityIdentifier("settings-service-update-info")
            }
        }
        .alert(t("workspace.daemon.checkUpdatesFailedTitle"), isPresented: $checkFailed) {
            Button(t("common.ok"), role: .cancel) {}
        } message: {
            Text(updates.releaseCheckError ?? t("workspace.daemon.checkUpdatesFailed"))
        }
    }
}

/// The sheet and Settings edit the same preference; neither owns a second update policy.
private struct ServiceAutomaticUpdatesToggle: View {
    @AppStorage(StorageKey.automaticServiceUpdates) private var enabled = true

    var body: some View {
        Toggle(t("settings.serviceUpdates"), isOn: $enabled)
            .tint(Palette.success)
            .accessibilityIdentifier("service-automatic-updates")
    }
}

struct ServiceReleaseRows: View {
    var installed: String? = nil
    var latest: String?
    var checkedAt: Date?

    var body: some View {
        if let installed {
            LabeledContent(t("workspace.daemon.installedVersion"), value: "v" + installed)
        }
        if let latest, latest != installed {
            LabeledContent(t("workspace.daemon.latestRelease"), value: "v" + latest)
        }
        if let version = latest ?? installed,
           let url = URL(string: "https://github.com/\(AppConstants.mindwireRepository)/releases/tag/v\(version)") {
            Link(t("workspace.daemon.releaseNotes"), destination: url)
        }
        if let checkedAt {
            LabeledContent(t("workspace.daemon.checkedAt")) {
                Text(checkedAt, style: .relative).foregroundStyle(.secondary)
            }
        }
    }
}

/// Settings, the workspace row and the toolbar share the same cached service information.
/// Opening the sheet never starts a network check or an installation.
struct ServiceUpdateInfoSheet: View {
    var workspace: Workspace? = nil
    var repository: WorkspaceRepository = .shared
    var coordinator: DaemonWorkCoordinator = .shared

    var body: some View {
        NavigationStack {
            ServiceUpdateInfoContent(workspace: workspace, repository: repository, coordinator: coordinator)
        }
        .tint(.primary)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct ServiceUpdateInfoContent: View {
    var workspace: Workspace?
    let repository: WorkspaceRepository
    let coordinator: DaemonWorkCoordinator
    var showsDone = true
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var checkFailed = false
    @State private var reconnectingComputer: Connection?
    private var updates: ServiceUpdateScheduler { stores.serviceUpdates }
    private var checkingDisabled: Bool {
        if let workspace {
            return updates.busy || coordinator.states[.init(workspaceId: workspace.id)]?.running == true
                || stores.preparation.active.contains(.init(workspaceId: workspace.id))
                || stores.workspaceData.syncing.contains(workspace.id)
        }
        return updates.busy || repository.all.isEmpty
    }

    var body: some View {
        Form {
            if let workspace {
                WorkspaceDaemonDetailsSection(workspace: workspace, repository: repository, coordinator: coordinator,
                    onReconnectComputer: { reconnectingComputer = $0 })
            } else {
                Section {
                    Button(t("workspace.daemon.updateAll"), icon: .download) {
                        Task { checkFailed = !(await updates.updateAll(repository.all)) }
                    }
                    .disabled(repository.all.isEmpty || updates.busy)
                    .accessibilityIdentifier("service-info-update-all")
                    ServiceUpdateSummary(showsRelease: false)
                } footer: { Text(t("workspace.daemon.restartNotice")) }
                Section(t("tabs.workspaces")) {
                    ForEach(repository.all) { workspace in
                        NavigationLink {
                            ServiceUpdateInfoContent(workspace: workspace, repository: repository,
                                                     coordinator: coordinator, showsDone: false)
                        } label: {
                            ServiceUpdateWorkspaceRow(workspace: workspace, coordinator: coordinator)
                        }
                        .accessibilityIdentifier("service-info-workspace-\(workspace.id)")
                    }
                }
                if repository.all.isEmpty {
                    Section {
                        Text(t("workspaces.empty.title"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if workspace == nil, updates.latestVersion != nil {
                Section {
                    ServiceReleaseRows(latest: updates.latestVersion, checkedAt: updates.releaseCheckedAt)
                }
            }
            Section {
                ServiceAutomaticUpdatesToggle()
            } footer: { Text(t("settings.serviceUpdates.scope")) }
        }
        .navigationTitle(showsDone ? t("workspace.daemon.title") : workspace?.name ?? t("workspace.daemon.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $reconnectingComputer) { connection in
            ComputerRecoverySheet(serverId: connection.id, repository: repository)
        }
        .toolbar {
            AppToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { checkFailed = !(await updates.checkUpdates(workspace.map { [$0] } ?? repository.all)) }
                } label: {
                    if updates.checking { ProgressView().controlSize(.small) }
                    else { AppIcon(.refresh) }
                }
                .disabled(checkingDisabled)
                .accessibilityLabel(t("agentUpdates.checkUpdates"))
                .accessibilityIdentifier("service-info-check-updates")
            }
            AppToolbarItem(placement: .confirmationAction) {
                if showsDone { Button(t("common.done")) { dismiss() }.tint(.primary) }
            }
        }
        .alert(t("workspace.daemon.checkUpdatesFailedTitle"), isPresented: $checkFailed) {
            Button(t("common.ok"), role: .cancel) {}
        } message: {
            Text(updates.releaseCheckError ?? t("workspace.daemon.checkUpdatesFailed"))
        }
    }
}

/// Every workspace stays in the results, including failures and queued computers.
/// Versions and a short status are enough here; progress and diagnostics share the detail view.
private struct ServiceUpdateWorkspaceRow: View {
    let workspace: Workspace
    let coordinator: DaemonWorkCoordinator
    @Environment(\.stores) private var stores
    private var state: DaemonWorkState? { coordinator.states[.init(workspaceId: workspace.id)] }

    var body: some View {
        EntityRow {
            Text(workspace.name)
        } subtitle: {
            Text([state?.installedVersion.map { "v" + $0 }, status].compactMap { $0 }.joined(separator: " · "))
        } icon: {
            WorkspaceImageIcon(image: workspace.image, size: 22)
        } accessory: {
            if stores.serviceUpdates.checkingWorkspaces.contains(workspace.id) {
                ProgressView().controlSize(.small)
            } else {
                WorkspaceDaemonStatusLabel(workspaceId: workspace.id, compact: true, coordinator: coordinator)
            }
        }
    }

    private var status: String {
        if stores.serviceUpdates.checkingWorkspaces.contains(workspace.id) { return t("workspace.daemon.checkingUpdates") }
        if state?.updateCheckError != nil { return t("workspace.daemon.updateCheckFailed") }
        if stores.workspaceData.errors[workspace.id] != nil, state?.reachable == true { return t("workspace.daemon.updateCheckFailed") }
        if state?.reachable == nil {
            return t(state?.updateOperation?.isActive == true ? "workspace.daemon.updateQueued" : "workspace.daemon.notChecked")
        }
        if state?.reachable == true, state?.supportsProjects == true, state?.updateAvailable == false, state?.latestVersion != nil,
           state?.error == nil, state?.updateOperation?.isActive != true { return t("workspace.daemon.upToDate") }
        return WorkspaceDaemonStatusLabel.title(for: state,
            preparing: stores.preparation.active.contains(.init(workspaceId: workspace.id)),
            scheduled: stores.serviceUpdates.active.contains(workspace.id))
    }
}

/// Read-only feedback, shared by Settings and the toolbar menu. Opening either reads cache.
struct ServiceUpdateSummary: View {
    var showsRelease = true
    @Environment(\.stores) private var stores
    private var updates: ServiceUpdateScheduler { stores.serviceUpdates }

    var body: some View {
        if updates.checking {
            Text(t("workspace.daemon.checkingUpdates"))
        } else if let error = updates.releaseCheckError {
            Text(error)
        } else {
            if !updates.active.isEmpty {
                Text(t("workspace.daemon.updatingCount", ["count": "\(updates.active.count)"]))
            }
            if updates.waitingCount > 0 {
                Text(t("workspace.daemon.waitingCount", ["count": "\(updates.waitingCount)"]))
            }
            if showsRelease, let version = updates.latestVersion {
                Text(t("workspace.daemon.publishedVersion", ["version": version]))
            }
        }
    }
}
