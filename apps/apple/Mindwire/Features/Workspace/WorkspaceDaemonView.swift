import SwiftUI

extension DaemonWorkState {
    var workspaceStatusTitle: String? {
        if let powerAction {
            if powerAction == .stop { return t("workspace.power.stopping") }
            return t(workspaceStatus?.power == .running ? "workspace.daemon.connecting" : "workspace.power.starting")
        }
        switch workspaceStatus?.power {
        case .stopped: return t("workspace.power.stopped")
        case .starting: return t("workspace.power.starting")
        case .stopping: return t("workspace.power.stopping")
        default: return nil
        }
    }

    var workspaceTransitioning: Bool { powerAction != nil || workspaceStatus?.power.isTransitioning == true }
}

/// The same workspace state powers agent rows, the workspace list, and project preflight.
struct WorkspaceDaemonStatusLabel: View {
    let workspaceId: String
    var showsProgress = false
    var showsLatestVersion = false
    var compact = false
    var coordinator: DaemonWorkCoordinator = .shared
    @ScaledMetric(relativeTo: .caption) private var compactSize: CGFloat = 16
    @Environment(\.stores) private var stores
    private var state: DaemonWorkState? { coordinator.states[.init(workspaceId: workspaceId)] }
    private var preparing: Bool { stores.preparation.active.contains(.init(workspaceId: workspaceId)) }
    private var scheduled: Bool { stores.serviceUpdates.active.contains(workspaceId) }

    var body: some View {
        Group {
            if compact {
                indicator
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(indicatorColor)
                    .frame(width: compactSize, height: compactSize)
                    .help(status)
            } else {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: 4) {
                        indicator
                        Text([versions, status].compactMap { $0 }.joined(separator: " · "))
                            .lineLimit(2)
                    }
                    if showsProgress, let state, state.changingService {
                        WorkspaceDaemonProgress(work: state)
                    }
                }
                .font(.caption)
                .foregroundStyle(state?.reachable == true && state?.supportsProjects == false ? Color.orange : .secondary)
            }
        }
        .accessibilityElement(children: compact ? .ignore : .combine)
        .accessibilityLabel(t("workspace.daemon.title") + ": " + status)
        .accessibilityValue(versions ?? "")
    }

    @ViewBuilder
    private var indicator: some View {
        if state?.workspaceStatus?.provisioning?.isFailed == true {
            AppIcon(compact ? .alertCircle : .warning)
        } else if state?.workspaceTransitioning == true {
            ProgressView().controlSize(.mini)
        } else if state?.workspaceStatus?.power == .stopped {
            AppIcon(compact ? .pauseCircle : .pauseCircle)
        } else if state?.running != true, state?.error != nil {
            AppIcon(compact ? .alertCircle : .warning)
        } else if state?.updateOperation?.status == "waiting" || state?.updateWaiting == true {
            AppIcon(.clock)
        } else if preparing || scheduled || state?.running == true || state?.updateOperation?.isActive == true {
            ProgressView().controlSize(.mini)
        } else if state?.error != nil {
            AppIcon(compact ? .alertCircle : .warning)
        } else if state?.reachable == nil {
            ProgressView().controlSize(.mini)
        } else if state?.reachable == false {
            AppIcon(compact ? .alertCircle : .wifiOff)
        } else if state?.supportsProjects == false || state?.updateAvailable == true {
            AppIcon(compact ? .arrowUpCircle : .download)
        } else if compact {
            Circle().fill(Palette.success).frame(width: compactSize * 7 / 16, height: compactSize * 7 / 16)
        } else {
            AppIcon(.checkCircle)
        }
    }

    private var indicatorColor: Color {
        if state?.workspaceStatus?.provisioning?.isFailed == true { return Palette.danger }
        if state?.workspaceUnavailable == true || preparing || scheduled || state?.running == true { return .secondary }
        if state?.error != nil { return Palette.danger }
        if state?.updateWaiting == true || state?.updateOperation?.isActive == true { return .secondary }
        if state?.reachable == false || state?.updateAvailable == true
            || (state?.reachable == true && state?.supportsProjects == false) { return Palette.warning }
        return .secondary
    }

    private var versions: String? {
        guard let installed = state?.installedVersion else { return nil }
        if showsLatestVersion, state?.updateAvailable == true, let latest = state?.latestVersion {
            return "v\(installed) → v\(latest)"
        }
        return "v" + installed
    }

    private var status: String {
        Self.title(for: state, preparing: preparing, scheduled: scheduled)
    }

    static func title(for state: DaemonWorkState?, preparing: Bool, scheduled: Bool) -> String {
        if state?.workspaceStatus?.provisioning?.isFailed == true { return "Setup needs attention" }
        if state?.workspaceStatus?.provisioning?.isPending == true { return "Creating" }
        if let title = state?.workspaceStatusTitle { return title }
        if preparing && state?.running != true { return t("workspace.daemon.installing") }
        guard let state else { return t("workspace.daemon.checking") }
        if !state.running, state.error != nil {
            return t(state.activity == .updatingDaemon ? "agentUpdates.failed" : "agentUpdates.setupFailed")
        }
        if let operation = state.updateOperation, operation.isActive {
            if state.reachable == nil { return t("workspace.daemon.updateQueued") }
            if operation.observationError != nil || state.reachable == false { return t("workspace.daemon.updatePendingConnection") }
            if operation.status == "waiting" {
                if operation.force == true { return t("workspace.daemon.progress.starting") }
                if let count = operation.activity?.openTerminals, count > 0 {
                    return t(count == 1 ? "workspace.daemon.waitingTerminalStatus" : "workspace.daemon.waitingTerminalsStatus",
                             ["count": "\(count)"])
                }
                return t("workspace.daemon.waiting")
            }
            if operation.status == "queued" { return t("workspace.daemon.updateQueued") }
            return operation.progress?.label ?? t("workspace.daemon.updating")
        }
        if state.running {
            if state.activity == .checking { return t("workspace.daemon.checking") }
            return t(state.activity == .installingDaemon ? "workspace.daemon.installing" : "workspace.daemon.updating")
        }
        if scheduled { return t(state.installedVersion == nil ? "workspace.daemon.installing" : "workspace.daemon.updating") }
        if state.updateWaiting { return t("workspace.daemon.waiting") }
        guard let reachable = state.reachable else { return t("workspace.daemon.checking") }
        if !reachable { return t("workspace.daemon.offline") }
        if !state.supportsProjects { return t("workspace.daemon.updateRequired") }
        if state.updateAvailable { return t("workspace.daemon.updateAvailable") }
        return t("workspace.daemon.ready")
    }
}

struct WorkspaceDaemonSection: View {
    let workspace: Workspace
    var coordinator: DaemonWorkCoordinator = .shared
    @Environment(\.stores) private var stores
    @Environment(\.serviceUpdatePresentation) private var presentation
    @State private var checkFailed = false
    private var state: DaemonWorkState? { coordinator.states[.init(workspaceId: workspace.id)] }

    var body: some View {
        Section(t("workspace.daemon.title")) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Button { presentation?.show(workspace: workspace) } label: {
                        HStack(spacing: Spacing.sm) {
                            WorkspaceDaemonStatusLabel(workspaceId: workspace.id, coordinator: coordinator)
                            Spacer(minLength: Spacing.sm)
                            AppIcon(.info).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityHint(t("workspace.daemon.info"))
                    .accessibilityIdentifier("workspace-service-info")
                    Button {
                        Task { checkFailed = !(await stores.serviceUpdates.checkUpdates([workspace])) }
                    } label: {
                        Group {
                            if stores.serviceUpdates.checking { ProgressView().controlSize(.small) }
                            else { AppIcon(.refresh) }
                        }
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .tint(.secondary)
                    .disabled(stores.serviceUpdates.busy || state?.running == true)
                    .accessibilityLabel(t("agentUpdates.checkUpdates"))
                    .accessibilityIdentifier("workspace-service-check-updates")
                }
                if let state, state.changingService {
                    WorkspaceDaemonProgress(work: state)
                        .padding(EdgeInsets(top: 0, leading: 0, bottom: Spacing.sm, trailing: Spacing.sm))
                }
            }
            .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.lg, bottom: Spacing.xs, trailing: Spacing.sm))
        }
        .alert(t("workspace.daemon.checkUpdatesFailedTitle"), isPresented: $checkFailed) {
            Button(t("common.ok"), role: .cancel) {}
        } message: {
            Text(stores.serviceUpdates.releaseCheckError ?? t("workspace.daemon.checkUpdatesFailed"))
        }
    }
}

/// Plain service properties and actions for the sheet, sharing the workspace's live state.
struct WorkspaceDaemonDetailsSection: View {
    let workspace: Workspace
    var repository: WorkspaceRepository = .shared
    var coordinator: DaemonWorkCoordinator = .shared
    var onReconnectComputer: ((Connection) -> Void)? = nil
    @Environment(\.stores) private var stores
    @State private var showingTerminals = false
    private var state: DaemonWorkState? { coordinator.states[.init(workspaceId: workspace.id)] }
    private var preparing: Bool {
        stores.preparation.active.contains(.init(workspaceId: workspace.id)) || stores.serviceUpdates.active.contains(workspace.id)
    }
    private var checking: Bool {
        stores.workspaceData.syncing.contains(workspace.id) || stores.serviceUpdates.checkingRelease
            || stores.serviceUpdates.checkingWorkspaces.contains(workspace.id)
    }
    private var failure: String? {
        if let error = state?.powerError { return error }
        guard state?.workspaceUnavailable != true else { return nil }
        return state?.error ?? state?.updateOperation?.error ?? state?.connectionError
            ?? state?.updateOperation?.observationError ?? state?.updateCheckError
            ?? stores.workspaceData.errors[workspace.id]
    }
    private var canStart: Bool { state?.workspaceStatus?.power == .stopped && state?.powerAction == nil }

    private var setupTitle: String? {
        if let state, state.installedVersion != nil, state.updateAvailable {
            if let operation = state.updateOperation, operation.isActive,
               operation.force == true || operation.status == "restarting" { return nil }
            if state.error != nil { return t("workspace.daemon.updateRetry") }
            let pairedComputer = workspace.runtime.serverId.flatMap { stores.connections.get($0)?.pairedComputer } != nil
            return t(state.workspaceUnavailable || (state.reachable == false && pairedComputer)
                ? "workspace.daemon.queueUpdate" : "workspace.daemon.update")
        }
        // The page already probes automatically. Wait for that first result before offering setup.
        guard state?.workspaceUnavailable != true, state?.reachable != nil || state?.error != nil else { return nil }
        if state?.reachable == true && (state?.supportsProjects == false || state?.updateAvailable == true || state?.error != nil) {
            return t("workspace.daemon.update")
        }
        return state?.installedVersion == nil ? t("workspace.daemon.install") : nil
    }

    private var canRetry: Bool {
        state?.workspaceUnavailable != true && (state?.reachable == false || (state?.reachable == nil && state?.error != nil))
    }
    private var canStartService: Bool { canRetry && state?.installedVersion != nil }

    var body: some View {
        Section {
            LabeledContent(t("workspace.daemon.status")) {
                Text(WorkspaceDaemonStatusLabel.title(for: state,
                    preparing: stores.preparation.active.contains(.init(workspaceId: workspace.id)),
                    scheduled: stores.serviceUpdates.active.contains(workspace.id)))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            ServiceReleaseRows(installed: state?.installedVersion,
                latest: stores.serviceUpdates.latestVersion ?? state?.latestVersion,
                checkedAt: stores.serviceUpdates.releaseCheckedAt)
            if let operation = state?.updateOperation, operation.isActive {
                if operation.status == "waiting", operation.force != true {
                    Text(operation.activity?.waitingMessage ?? t("workspace.daemon.updateWaiting"))
                        .font(.footnote).foregroundStyle(.secondary)
                    if (operation.activity?.openTerminals ?? 0) > 0 {
                        Button(t("workspace.daemon.openTerminals"), icon: Icon.terminal) { showingTerminals = true }
                            .accessibilityIdentifier("service-update-open-terminals")
                    }
                } else if state?.running != true, let progress = operation.progress {
                    ServicePreparationProgress(title: progress.label)
                }
            }
            if state?.workspaceUnavailable == true {
                Text(t(canStart ? "workspace.power.stoppedBody" :
                       state?.powerAction == .stop || state?.workspaceStatus?.power == .stopping
                       ? "workspace.power.stoppingBody" : "workspace.power.startingBody"))
                    .font(.footnote).foregroundStyle(.secondary)
                if canStart {
                    Button(t("workspace.power.startAction")) {
                        Task { await repository.model(for: workspace).power(.start) }
                    }
                }
                if let setupTitle { Button(setupTitle) { update() } }
                if let failure { errorDetails(failure) }
            } else if let state, state.changingService || (state.running && state.activity == .installingDaemon) {
                // First setup can begin before the installer emits a progress marker.
                // Don't keep the preceding connection error and setup actions on screen.
                WorkspaceDaemonProgress(work: state)
            } else {
                if let failure {
                    Text(failureMessage(failure)).font(.footnote).foregroundStyle(.secondary)
                }
                actions.disabled(state?.changingService == true)
                if let failure { errorDetails(failure) }
            }
            if state?.reachable == false, let id = workspace.runtime.serverId,
               let connection = stores.connections.get(id), connection.pairedComputer != nil,
               let onReconnectComputer {
                Button("Reconnect Computer", icon: .refresh) { onReconnectComputer(connection) }
                    .tint(.primary)
                    .accessibilityIdentifier("computer-reconnect")
            }
        } footer: {
            if setupTitle != nil, state?.installedVersion != nil {
                Text(t("workspace.daemon.restartNotice"))
            } else if state?.workspaceUnavailable != true, state?.running != true, !preparing,
               state?.reachable == true, state?.supportsProjects == false {
                Text(t("workspace.sync.updateRequired"))
            } else if state?.updateOperation?.isActive != true, state?.running != true, state?.updateWaiting == true, state?.reachable == true,
                      state?.workspaceUnavailable != true {
                Text(t("workspace.daemon.updateWaiting"))
            } else if stores.serviceUpdates.automaticUpdates, state?.updateAvailable == true,
                      state?.reachable == true, (state?.health?.serviceUpdateVersion ?? 0) < 1 {
                Text(t("workspace.daemon.autoUpdateRequired"))
            }
        }
        .fullScreenCover(isPresented: $showingTerminals, onDismiss: {
            Task { await stores.serviceUpdates.checkUpdates([workspace]) }
        }) {
            TerminalScreen(title: workspace.name, startsNewSessionIfEmpty: false) {
                TerminalSessionFactory.provider(for: workspace, stores: stores)
            }
        }
    }

    /// Actions use native form rows instead of recreating the workspace card.
    @ViewBuilder
    private var actions: some View {
        if let setupTitle {
            Button(setupTitle) { update() }
                .accessibilityIdentifier("service-info-update-now")
        }
        if canStartService {
            Button(t("workspace.daemon.start")) {
                Task { try? await stores.workspaceData.startDaemon(workspaceId: workspace.id) }
            }
        }
        if canRetry {
            Button {
                Task { await stores.workspaceData.refresh(workspace) }
            } label: {
                HStack(spacing: Spacing.xs) {
                    if checking { ProgressView().controlSize(.mini) }
                    Text(t("common.retry"))
                }
            }
            .tint(.secondary)
            .accessibilityHint(t("workspace.daemon.check"))
        }
    }

    private func update() {
        if state?.installedVersion == nil {
            stores.preparation.enqueue(workspaceId: workspace.id)
        } else {
            stores.serviceUpdates.enqueue(workspaceId: workspace.id)
        }
    }

    @ViewBuilder
    private func errorDetails(_ details: String) -> some View {
        let message = failureMessage(details)
        if details != message {
            DisclosureGroup(t("workspace.daemon.errorDetails")) {
                Text(verbatim: details).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let checkedAt = state?.checkedAt {
                    HStack(spacing: 0) {
                        Text(t("workspace.daemon.lastChecked"))
                        Text(checkedAt, style: .relative)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .tint(.secondary)
            .id(details)
        }
    }

    private func failureMessage(_ details: String) -> String {
        if state?.powerError != nil { return t("workspace.power.failed") }
        if state?.error != nil, state?.activity == .checking { return t("workspace.daemon.startFailed") }
        // Preserve the app's actionable explanations; transport bodies and installer logs
        // belong in the collapsed diagnostic disclosure, never in the main service note.
        let explanations = ["workspace.daemon.busy", "workspace.daemon.verifyFailed", "workspace.daemon.unreachable",
                            "workspace.daemon.legacyRestart", "workspace.sync.updateRequired", "workspace.missing.body"].map { t($0) }
        if explanations.contains(details) { return details }
        guard state?.error != nil else { return t("workspace.daemon.unreachable") }
        return t(state?.activity == .updatingDaemon ? "workspace.daemon.updateFailed" : "workspace.daemon.setupFailed")
    }
}

/// Lists and the service section show the same measured download progress and setup stage.
struct WorkspaceDaemonProgress: View {
    let work: DaemonWorkState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(work.installProgress?.label ?? work.message ?? t("workspace.daemon.progress.preparing"))
                    .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                if let fraction = work.progressFraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            InstallationProgressBar(progress: work.progressFraction)
        }
    }
}

struct ServicePreparationProgress: View {
    var title = t("workspace.daemon.progress.preparing")
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            InstallationProgressBar()
        }
    }
}
