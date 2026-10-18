// Connection controls share the repository's live recovery state. Opening this
// page reads cached status; only Reconnect or pull-to-refresh starts a check.
import SwiftUI

struct ServerDetailScreen: View {
    let serverId: String
    var repository: WorkspaceRepository = .shared

    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable { case unchecked, checking, online, offline }

    @State private var connection: Connection?
    @State private var phase: Phase = .unchecked
    @State private var latencyMs: Int?
    @State private var healthDetail: String?

    @State private var showTerminal = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false
    @State private var keyBusy = false
    @State private var keyError: String?
    @State private var editing = false
    @State private var pairingAgain = false
    @State private var showingDetails = false
    @State private var creatingWorkspace = false
    @State private var pendingWorkspaceID: String?
    @State private var openedWorkspaceID: String?
    private var recoveryState: ComputerRecoveryCoordinator.State? { repository.computerRecovery.states[serverId] }
    private var reconnecting: Bool { repository.reconnectingComputers.contains(serverId) || phase == .checking }
    private var connected: Bool { repository.computerRecovery.healthy.contains(serverId) || phase == .online }

    var body: some View {
        Group {
            if let connection {
                List {
                    if connection.pairedComputer != nil { computerControls(connection) }
                    if needsCredential { authSection }
                    terminalSection
                    workspacesSection
                    if connection.pairedComputer == nil {
                        connectionSection(connection)
                        if connection.remote != nil, !needsCredential { authSection }
                        healthSection
                    }
                }
                .listSectionSpacing(.compact)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(connection?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if connection != nil {
                AppToolbarItem(placement: .topBarTrailing) { menu }
            }
        }
        .fullScreenCover(isPresented: $showTerminal) {
            TerminalScreen(title: connection?.name ?? t("workspace.terminal.title")) {
                connection.map { TerminalSessionFactory.provider(forConnection: $0) }
                    ?? LocalTerminalProvider { NullTerminalSession() }
            }
        }
        .sheet(isPresented: $editing) {
            if let remote = connection?.remote {
                AddServerScreen(editing: remote) { connection = $0; phase = .unchecked; healthDetail = nil; latencyMs = nil }
            }
        }
        .sheet(isPresented: $pairingAgain) {
            ComputerRecoverySheet(serverId: serverId) {
                connection = $0; phase = .online; healthDetail = nil; latencyMs = nil
            }
        }
        .sheet(isPresented: $showingDetails) { computerDetails }
        .sheet(isPresented: $creatingWorkspace, onDismiss: {
            openedWorkspaceID = pendingWorkspaceID
            pendingWorkspaceID = nil
        }) {
            NewWorkspaceScreen(server: connection) { pendingWorkspaceID = $0.id }
        }
        .navigationDestination(item: $openedWorkspaceID) { id in
            WorkspaceDetailScreen(workspaceId: id, repository: repository)
        }
        .inputDialog(
            titleKey: "serverDetail.rename.title",
            isPresented: $renaming,
            text: $renameText,
            placeholder: t("serverDetail.rename.label")
        ) {
            stores.renameServer(serverId, name: renameText)
            connection = stores.connections.get(serverId)
        }
        .alert(
            "Remove Connection?",
            isPresented: $confirmingDelete
        ) {
            Button("Remove", role: .destructive) {
                WorkspaceRepository.shared.forgetConnection(serverId)
                dismiss()
            }
            Button(t("common.cancel"), role: .cancel) {}
        } message: {
            Text(deleteBody)
        }
        .onAppear { connection = stores.connections.get(serverId) }
        .onChange(of: repository.revision) { connection = stores.connections.get(serverId) }
        .refreshable { await runHealthCheck() }
    }

    // MARK: - Sections

    private func connectionSection(_ c: Connection) -> some View {
        Section(t("detail.section.connection")) {
            LabeledContent("Type", value: c.isLocal ? "Paired computer" : "SSH server")
            if let r = c.remote {
                LabeledContent(t("field.host"), value: "\(r.host):\(r.port)")
                LabeledContent("Username", value: r.username)
                Button("Edit Connection", icon: Icon.edit) { editing = true }.tint(.primary)
            }
            LabeledContent(t("detail.row.workspace"), value: c.workspace ?? "~")
        }
    }

    private var healthSection: some View {
        Section("Connection check") {
            switch phase {
            case .unchecked:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.small)
            case .online:
                Text(t("detail.status.online")).foregroundStyle(.secondary)
            case .offline:
                Label(t("detail.status.offline"), icon: .warning)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.red)
                if connection?.pairedComputer != nil {
                    Button("Reconnect Computer", icon: .refresh) { pairingAgain = true }.tint(.primary)
                }
            }

            if let latencyMs {
                LabeledContent(t("detail.row.latency"), value: "\(latencyMs) ms")
            }
            if let healthDetail {
                Text(healthDetail).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Test Connection", icon: .refresh) { Task { await runHealthCheck() } }
                .tint(.primary).disabled(phase == .checking)
        }
    }

    @ViewBuilder
    private var authSection: some View {
        Section {
            LabeledContent(t("serverDetail.auth.method"), value: authMethodLabel)
            if isKeyAuth || needsCredential {
                Button("Edit Authentication", icon: .key) { editing = true }.tint(.primary)
            } else {
                Button { setUpKey() } label: {
                    HStack {
                        Label(t("serverDetail.auth.setupKey"), icon: .key)
                        Spacer()
                        if keyBusy { ProgressView() }
                    }
                }
                .tint(.primary)
                .disabled(keyBusy)
            }
        } header: {
            Text(t("serverDetail.section.auth"))
        } footer: {
            if let keyError {
                Text(keyError).foregroundStyle(.red)
            } else if needsCredential {
                Text(stores.connectionSync.syncCredentials
                    ? "Add this server’s password or SSH key, or wait for iCloud Keychain to finish restoring it."
                    : "Add this server’s password or SSH key to connect.")
            } else {
                Text(t("serverDetail.auth.hint"))
            }
        }
    }

    private var isKeyAuth: Bool {
        if case .key = connection?.remote?.auth { return true }
        return false
    }

    private var needsCredential: Bool {
        guard let ref = connection?.remote?.auth.secretReference else { return false }
        return stores.connectionSync.secrets.local(ref) == nil
    }

    private var authMethodLabel: String {
        switch connection?.remote?.auth {
        case .password: return t("addServer.auth.password")
        case .key:      return t("serverDetail.auth.key")
        case .agent:    return t("addServer.auth.agent")
        case .none:     return "—"
        }
    }

    private func setUpKey() {
        keyBusy = true
        keyError = nil
        Task {
            do {
                try await stores.setUpServerKey(serverId)
                await MainActor.run {
                    connection = stores.connections.get(serverId)
                    keyBusy = false
                }
            } catch {
                await MainActor.run {
                    keyError = error.localizedDescription
                    keyBusy = false
                }
            }
        }
    }

    private var terminalSection: some View {
        Section("Tools") {
            Button { showTerminal = true } label: {
                Label(t("workspace.terminal.open"), icon: Icon.terminal)
            }
            .tint(.primary)
            .disabled(connection?.pairedComputer?.needsDeviceApproval == true
                || connection?.remote == nil && connection?.pairedComputer == nil)
            if let connection, connection.remote != nil || connection.pairedComputer != nil {
                NavigationLink {
                    ConnectionPortsScreen(connection: connection)
                } label: { Label("Port Forwarding", icon: .arrowsLeftRight) }
                .disabled(connection.pairedComputer?.needsDeviceApproval == true)
            }
        }
    }

    @ViewBuilder private var workspacesSection: some View {
        let workspaces = stores.workspaces(forServerId: serverId)
        if !workspaces.isEmpty || connection?.remote != nil {
            Section("Computer") {
                ForEach(workspaces) { workspace in
                    NavigationLink(value: AppRoute.workspaceDetail(id: workspace.id)) { WorkspaceRow(workspace: workspace) }
                }
                if connection?.remote != nil, workspaces.isEmpty {
                    Button("Set up computer", icon: Icon.plus) { creatingWorkspace = true }
                        .tint(.primary)
                }
            }
        }
    }

    private func computerControls(_ connection: Connection) -> some View {
        Section {
            VStack(spacing: Spacing.lg) {
                HStack(spacing: Spacing.md) {
                    ModeIcon(type: connection.type, size: 24)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Spacing.sm) {
                            Circle().fill(connectionTint).frame(width: 7, height: 7)
                            Text(connectionTitle).font(.headline)
                        }
                        Text(connectionHint).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Connection Details", icon: .info) { showingDetails = true }
                        .labelStyle(.iconOnly).buttonStyle(.plain).tint(.secondary)
                        .accessibilityIdentifier("computer-connection-details")
                }
                HStack(spacing: Spacing.sm) {
                    Button {
                        if connection.pairedComputer?.needsDeviceApproval == true { pairingAgain = true }
                        else { Task { await reconnectComputer() } }
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            if reconnecting { ProgressView().controlSize(.small).tint(.white) }
                            else { AppIcon(.refresh).font(.system(size: 16, weight: .semibold)) }
                            Text(connection.pairedComputer?.needsDeviceApproval == true ? "Approve This Device" : "Reconnect")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                    .disabled(reconnecting).accessibilityIdentifier("computer-reconnect")
                    if connection.pairedComputer?.needsDeviceApproval != true {
                      Button { pairingAgain = true } label: {
                        Text("Repair…").frame(maxWidth: .infinity)
                      }
                      .buttonStyle(.bordered).tint(.primary)
                      .accessibilityIdentifier("computer-repair")
                    }
                }
                .controlSize(.regular)
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    private var connectionTitle: String {
        if connection?.pairedComputer?.needsDeviceApproval == true { return "Approval needed" }
        if reconnecting { return "Reconnecting…" }
        switch recoveryState {
        case .connecting: return "Reconnecting…"
        case .waiting: return "Offline"
        case .offline: return "No internet"
        case .paused: return "Retry paused"
        case .needsAttention: return "Needs repair"
        case nil: return connected ? "Connected" : phase == .offline ? "Offline" : "Ready to connect"
        }
    }

    private var connectionHint: String {
        if connection?.pairedComputer?.needsDeviceApproval == true { return "Approve this device to use your saved computer." }
        if reconnecting || recoveryState == .connecting { return "Finding your computer" }
        switch recoveryState {
        case .waiting: return "Mindwire will retry automatically."
        case .offline: return "Reconnects when your internet returns."
        case .paused: return "Tap Reconnect to try again."
        case .needsAttention: return "Repair your saved connection to continue."
        default: return connected ? "Secure SSH connection" : "Keep your computer awake and Mindwire running."
        }
    }

    private var connectionTint: Color {
        if reconnecting || recoveryState == .connecting { return Palette.accent }
        if case .needsAttention = recoveryState { return Palette.danger }
        return recoveryState == nil && connected ? Palette.success : .secondary
    }

    private var computerDetails: some View {
        NavigationStack {
            Form {
                if let computer = connection?.pairedComputer {
                    Section("Connection") {
                        LabeledContent("Computer", value: connection?.name ?? "Computer")
                        LabeledContent("Status", value: connectionTitle)
                        LabeledContent("Provider", value: computer.connectionPolicy.providerName)
                        LabeledContent("Automatic recovery", value: computer.discovery != nil ? "Enabled" : computer.connectionPolicy.address == "persistent" ? "Persistent address" : "Not set up")
                    }
                    if let detail = healthDetail, phase == .offline {
                        Section { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                    } else if case .needsAttention(let message) = recoveryState {
                        Section { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    Section {
                        DisclosureGroup("Addresses & identity") {
                            ForEach(Array(computer.routes.enumerated()), id: \.offset) { _, route in
                                LabeledContent(route.kind == "websocket" ? "Internet" : "Direct SSH",
                                    value: route.url.flatMap(URL.init(string:))?.host ?? route.host ?? "")
                            }
                            Text(computer.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        NavigationLink("Setup & Connection Help") { ComputerSetupHelpScreen() }
                    } footer: {
                        Text("Your phone verifies this computer’s identity. The tunnel cannot read files, commands or chats.")
                    }
                }
            }
            .navigationTitle("Connection Details").navigationBarTitleDisplayMode(.inline)
            .toolbar { AppToolbarItem(placement: .confirmationAction) { Button("Done") { showingDetails = false }.tint(.primary) } }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var menu: some View {
        AppMenu {
            if connection?.remote != nil {
                Button("Edit Connection", icon: Icon.edit) { editing = true }
            }
            Button {
                renameText = connection?.name ?? ""
                renaming = true
            } label: {
                Label(t("common.rename"), icon: Icon.edit)
            }
            DestructiveButton("Remove Connection", icon: Icon.trash) {
                confirmingDelete = true
            }
        } label: {
            AppIcon(Icon.ellipsis)
                            .foregroundStyle(.primary)
        }
    }

    // MARK: - Health

    private func runHealthCheck() async {
        guard let connection, phase != .checking else { return }
        if connection.pairedComputer != nil { await reconnectComputer(); return }
        phase = .checking
        let backend = BackendFactory.make(for: connection)
        let health = await backend.healthCheck()
        await backend.dispose()
        guard !Task.isCancelled else { return }
        latencyMs = health.latencyMs
        healthDetail = health.detail
        phase = health.ok ? .online : .offline
    }

    private func reconnectComputer() async {
        phase = .checking
        healthDetail = nil
        do {
            connection = try await repository.reconnectComputer(serverId)
            phase = .online
        } catch is CancellationError {
            phase = .unchecked
        } catch {
            healthDetail = error.localizedDescription
            phase = .offline
        }
    }

    // MARK: - Helpers

    private var deleteBody: String {
        let count = stores.workspaces(forServerId: serverId).count
        let location = stores.connectionSync.enabled ? "your synced devices" : "this device"
        return "Remove \(connection?.name ?? "this connection") and its \(count) saved workspace(s) from \(location)? Files and programs on the computer are kept."
    }

}
