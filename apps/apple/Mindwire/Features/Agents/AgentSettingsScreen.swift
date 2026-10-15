import SwiftUI

/// Full-page settings modal for one agent: identity, schema-driven config, activity, danger.
struct AgentSettingsScreen: View {
    let agentId: String

    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss

    @State private var model: AgentSettingsModel?
    @State private var auth: DaemonSession?
    @State private var confirmingDelete = false
    @State private var savedFlash = false
    @State private var saveError: String?
    @State private var saving = false
    @State private var showingServiceInfo = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(t("agentSettings.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .topBarLeading) {
                        Button(t("common.cancel")) { dismiss() }
                            .tint(.primary)
                    }
                    AppToolbarItem(placement: .topBarTrailing) {
                        Button(t("common.save")) { Task { await save() } }
                            .fontWeight(.semibold)
                            .tint(.primary)
                            .disabled(model?.agent == nil || model?.configurationLoaded != true || !canEdit || saving)
                    }
                }
                .overlay(alignment: .bottom) { if savedFlash { savedToast } }
        }
        .task { await start() }
        .sheet(isPresented: $showingServiceInfo) {
            if let id = model?.agent?.workspaceId, let workspace = WorkspaceRepository.shared.get(id) {
                ServiceUpdateInfoSheet(workspace: workspace)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model, let agent = model.agent {
            AgentReadinessView(agent: agent, session: auth, requiresAuthentication: false) {
                form(model, agent)
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var canEdit: Bool { auth?.phase == .ready || auth?.phase == .needsAuth }

    @ViewBuilder
    private func form(_ model: AgentSettingsModel, _ agent: Agent) -> some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent {
                    AgentLogo(id: agent.agentType, size: 30)
                } label: {
                    Text(agent.displayName)
                        .font(.headline)
                    Text(agent.typeDisplayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section(t("agentSettings.section.identity")) {
                TextField(t("agentSettings.row.name"), text: $model.name, prompt: Text(agent.displayName))
                    .textInputAutocapitalization(.words)
            }

            if let auth { AgentAuthSection(model: auth) }

            Section {
                NavigationLink {
                    NotificationPreferencesScreen(scope: .agent(agentId))
                } label: {
                    Label(t("notifications.title"), icon: .bell)
                }
            }

            if let auth { softwareSection(auth, agent: agent) }

            if let saveError {
                Section { Text(saveError).foregroundStyle(.red) }
            }

            if model.hasConfig {
                AgentSettingsFields(schema: model.schema, values: model.configBinding,
                                    models: model.availableModels, loadingModels: model.loadingModels)
            }

            Section(t("agentSettings.section.activity")) {
                LabeledContent(t("agentDetail.row.type"),
                               value: agent.typeDisplayName)
                LabeledContent(t("agentSettings.row.created"), value: fmtDate(agent.createdAt))
                if let lastUsed = agent.lastUsedAt {
                    LabeledContent(t("agentSettings.row.lastUsed"), value: fmtDate(lastUsed))
                }
            }

            Section {
                DestructiveButton(t("agentSettings.delete"), icon: Icon.trash) { confirmingDelete = true }
                    .disabled(saving)
            }
        }
        .alert(
            t("agentDetail.delete.title"),
            isPresented: $confirmingDelete
        ) {
            Button(t("common.delete"), role: .destructive) { Task { await deleteAgent() } }
            Button(t("common.cancel"), role: .cancel) {}
        } message: {
            Text(deleteBody(agent))
        }
    }

    @ViewBuilder
    private func softwareSection(_ session: DaemonSession, agent: Agent) -> some View {
        Section(t("agentUpdates.title")) {
            if let info = session.info {
                LabeledContent(t("agentUpdates.daemon"), value: info.version)
                LabeledContent(agent.typeDisplayName, value: info.installedVersion.isEmpty ? "—" : info.installedVersion)
            }
            if let software = session.software {
                LabeledContent(t("agentUpdates.compatibility"), value: software.statusTitle)
                if let message = software.message, software.compatibility != "supported" {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                if software.requiresDaemonUpdate, let version = software.requiredDaemonVersion {
                    Text(t("agentUpdates.requiresServiceVersion", ["version": version]))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if software.catalogStale {
                    Text(t("agentUpdates.savedCompatibility")).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text(t("agentUpdates.policyRequired")).font(.footnote).foregroundStyle(.secondary)
            }
            if let work = session.daemonWork, work.changingService || work.error != nil {
                AgentWorkProgress(work: work)
            }
            if let work = session.toolsWork, work.running || work.error != nil || work.updateAvailable {
                AgentWorkProgress(work: work)
            }
            if session.daemonWork?.updateAvailable == true, let workspaceId = agent.workspaceId {
                Button(t("agentUpdates.updateDaemon")) {
                    stores.serviceUpdates.enqueue(workspaceId: workspaceId)
                    showingServiceInfo = true
                }
                .disabled(session.daemonWork?.running == true || session.toolsWork?.running == true)
            }
            if let software = session.software, software.canUpdate, let version = software.recommendedVersion {
                Button(software.repairAvailable == true ? t("agentUpdates.repairCLI")
                       : t("agentUpdates.updateToVersion", ["version": version])) {
                    Task {
                        do { try await session.updateAgent() }
                        catch { saveError = error.localizedDescription }
                    }
                }
                .disabled(session.daemonWork?.running == true || session.toolsWork?.running == true)
            }
            if session.software?.supportsUpdates == true {
                Button {
                    Task { await session.refreshSoftware(force: true) }
                } label: {
                    HStack {
                        Text(t("agentUpdates.checkUpdates"))
                        if session.toolsWork?.softwareRefreshing == true { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(session.toolsWork?.softwareRefreshing == true || session.toolsWork?.running == true)
            }
        }
    }

    private var savedToast: some View {
        HStack(spacing: Spacing.sm) {
            AppIcon(Icon.checkmark).foregroundStyle(.secondary)
            Text(t("agentSettings.saved"))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .chromeGlass(Capsule())
        .padding(.bottom, Spacing.xl)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    // MARK: - Actions

    /// Build app identity, then load both schema and values from the authoritative daemon.
    private func start() async {
        let settings = self.model ?? AgentSettingsModel(agentId: agentId, stores: stores)
        settings.load()
        self.model = settings

        let auth = self.auth ?? DaemonManager.shared.session(for: agentId, stores: stores)
        self.auth = auth
        await auth.load()
        do {
            let config = try await auth.config()
            settings.adopt(schema: auth.schema, config: config)
            saveError = nil
            await settings.loadModels(using: auth)
        } catch { saveError = error.localizedDescription }
    }

    private func save() async {
        guard canEdit else { return }
        guard let model else { return }
        guard let auth else { return }
        guard !saving, model.configurationLoaded else { return }
        saving = true
        defer { saving = false }
        do {
            guard try await model.save() else { return }
            let changes = model.changedConfig()
            if !changes.isEmpty { try await auth.saveConfig(changes) }
            saveError = nil
        } catch {
            saveError = error.localizedDescription
            return
        }
        withAnimation { savedFlash = true }
        try? await Task.sleep(for: .seconds(0.9))
        dismiss()
    }

    private func deleteAgent() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await AgentManagement.remove(agentId, session: auth, stores: stores)
        } catch {
            saveError = error.localizedDescription
            return
        }
        dismiss()
    }

    private func deleteBody(_ agent: Agent) -> String {
        t("agentDetail.delete.body", [
            "name": agent.displayName,
            "count": "\(stores.chatCount(agentId: agentId))",
        ])
    }
}

/// Multi-select over a comma-joined string value (the daemon stores a `multiselect` comma-joined,
/// e.g. the tools picker). A native `Menu` of checkable rows — works inside a `Form` without needing
/// a `NavigationStack`, and shows the selected count in the row.
struct MultiSelectField: View {
    let label: String
    let options: [DaemonFieldOption]
    @Binding var value: String

    private var selected: Set<String> {
        Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    private func toggle(_ v: String) {
        var set = selected
        if set.contains(v) { set.remove(v) } else { set.insert(v) }
        // Re-serialize in the option order so the stored string is stable, not click-ordered.
        value = options.map(\.value).filter { set.contains($0) }.joined(separator: ",")
    }

    var body: some View {
        let sel = selected
        AppMenu {
            ForEach(options, id: \.value) { opt in
                Button { toggle(opt.value) } label: {
                    Label(opt.label, icon: sel.contains(opt.value) ? .checkCircleFilled : .circle)
                }
            }
        } label: {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                Text(sel.isEmpty ? "—" : "\(sel.count)").foregroundStyle(.secondary).monospacedDigit()
                AppIcon(Icon.chevron).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .tint(.primary)
    }
}
