import SwiftUI

/// Bot identity is separate from engine authentication. Both experiences use this flow and
/// the same registry mutations, readiness screen and hidden assistant project.
struct BotCreationScreen: View {
    var repository: WorkspaceRepository = .shared
    let onCreated: (AssistantBot) -> Void
    let onAskMindwire: (AssistantBot) -> Void
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appExperienceMode) private var experienceMode
    @State private var model: NewAgentModel
    @State private var botId: String
    @State private var name = ""
    @State private var instructions = ""
    @State private var appearance: AssistantBotIcon
    @State private var setup: Setup = .plain
    @State private var appearanceExpanded = false
    @State private var selectedAgent: Agent?
    @State private var readyAgent: Agent?
    @State private var agents: [Agent] = []
    @State private var connections = AssistantConnectionDiscovery()
    @State private var generalAgent: Agent?
    @State private var choseBaseAgent = false
    @State private var resolvedEngineWorkspaceID: String?
    @State private var choosingConnection = false
    @State private var sheet: Sheet?
    @State private var saving = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    private enum Setup: String, CaseIterable, Identifiable {
        case plain, instructions, mindwire
        var id: String { rawValue }
        var title: String { t("bots.create.mode.\(rawValue)") }
        var icon: AppIconName {
            switch self {
            case .plain: .message
            case .instructions: .fileText
            case .mindwire: .sparkles
            }
        }
    }
    private enum Sheet: Int, Identifiable {
        case computers, addComputer, connection, appearance
        var id: Int { rawValue }
    }

    init(repository: WorkspaceRepository? = nil, workspaceId: String? = nil, initialWorkspaceId: String? = nil,
         onCreated: @escaping (AssistantBot) -> Void, onAskMindwire: @escaping (AssistantBot) -> Void) {
        self.repository = repository ?? .shared
        self.onCreated = onCreated
        self.onAskMindwire = onAskMindwire
        let id = "bot-" + UUID().uuidString.lowercased()
        _botId = State(initialValue: id)
        _appearance = State(initialValue: .fresh(botId: id))
        let model = NewAgentModel(workspaceId: workspaceId)
        model.pickedWorkspaceId = initialWorkspaceId
        _model = State(initialValue: model)
    }

    var body: some View {
        presentation
        .interactiveDismissDisabled(saving)
        .task(id: experienceMode) { if experienceMode == .developer { await model.loadCatalog() } }
        .task { reconcile(); await repository.refreshIfNeeded(); reconcile() }
        .task(id: "\(model.workspaceId ?? ""):\(experienceMode.rawValue)") {
            generalAgent = nil
            choseBaseAgent = false
            resolvedEngineWorkspaceID = nil
            reloadAgents()
            if let workspace = model.workspaceId.flatMap(repository.get) {
                if experienceMode == .general {
                    await connections.load(workspace: workspace, stores: stores)
                    guard !Task.isCancelled, model.workspaceId == workspace.id else { return }
                    // Reuse an account already chosen by the user. A newly discovered account
                    // is offered for confirmation instead of picking the first installed CLI.
                    reuseChosenConnection()
                } else {
                    await stores.workspaceData.refreshIfNeeded(workspace)
                    await model.loadBotCatalog(stores: stores)
                    guard !Task.isCancelled, model.workspaceId == workspace.id else { return }
                    reloadAgents()
                    await connections.load(workspace: workspace, stores: stores, catalog: engines)
                    guard !Task.isCancelled, model.workspaceId == workspace.id else { return }
                    selectAuthenticatedEngine()
                    resolvedEngineWorkspaceID = workspace.id
                }
                reloadAgents()
            }
        }
        .onChange(of: connections.readyAgentIDs) {
            reuseChosenConnection()
            selectAuthenticatedEngine()
        }
        .onChange(of: connections.loading) { selectAuthenticatedEngine() }
        .onChange(of: engines) { _, available in
            if experienceMode == .developer, !available.contains(where: { $0.id == model.agentType }), let first = available.first {
                model.agentType = first.id
            }
            selectAuthenticatedEngine()
        }
        .onChange(of: model.agentType) { selectAuthenticatedEngine() }
        .observeWorkspaceCache(reloadAgents)
        .onChange(of: repository.revision) { reconcile() }
        .onDisappear { task?.cancel() }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .computers:
                WorkspacePickerSheet(repository: repository, selectedWorkspaceId: model.workspaceId) { workspace in
                    model.pickedWorkspaceId = workspace.id
                }
            case .addComputer:
                NewWorkspaceScreen { workspace in model.pickedWorkspaceId = workspace.id }
            case .connection:
                if let workspace = model.workspaceId.flatMap(repository.get) {
                    connectionPicker(workspace)
                }
            case .appearance:
                appearancePicker
            }
        }
        .alert(t("assistant.bots.saveFailed"), isPresented: Binding(get: { error != nil && readyAgent == nil }, set: { if !$0 { error = nil } })) {
            Button(t("common.ok"), role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private var presentation: some View {
        #if targetEnvironment(macCatalyst)
        VStack(spacing: 0) {
            HStack {
                Text(choosingConnection ? "AI connection" : t("assistant.bots.create"))
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            NavigationStack { flow.toolbar(.hidden, for: .navigationBar) }
            Divider()
            HStack(spacing: 10) {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button(t(selectedAgent == nil ? "common.cancel" : "common.back"), action: cancel)
                    .keyboardShortcut(.cancelAction).disabled(saving)
                if selectedAgent == nil && readyAgent == nil && !choosingConnection {
                    Button(createTitle, action: begin).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(!canCreate)
                }
            }
            .controlSize(.regular).buttonStyle(.bordered)
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .font(.system(size: 13))
        .background(AssistantDesktopStyle.canvas)
        .frame(width: 560, height: choosingConnection || selectedAgent != nil || setup == .instructions ? 560 : 460)
        .presentationSizing(.fitted)
        #else
        NavigationStack {
            flow
                .navigationTitle(t("assistant.bots.create"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .cancellationAction) {
                        Button(t(selectedAgent == nil ? "common.cancel" : "common.back"), action: cancel).disabled(saving)
                    }
                }
        }
        #endif
    }

    @ViewBuilder private var flow: some View {
        if choosingConnection, let workspace = model.workspaceId.flatMap(repository.get) {
            AssistantConnectionPicker(workspace: workspace, repository: repository, discovery: connections, onReady: acceptConnection)
                .id(workspace.id)
        } else if readyAgent != nil { progress }
        else if let selectedAgent {
            AgentSetupScreen(agent: selectedAgent, onRemoved: resetAgent) {
                readyAgent = selectedAgent
                save(selectedAgent)
            }
        } else {
            #if targetEnvironment(macCatalyst)
            desktopForm
            #else
            mobileForm
            #endif
        }
    }

    #if targetEnvironment(macCatalyst)
    private var desktopForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 18) {
                    Button { withAnimation { appearanceExpanded.toggle() } } label: {
                        AssistantBotAvatar(botId: botId, icon: appearance.id, size: 56)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil").font(.system(size: 10, weight: .semibold))
                                    .padding(6).background(AssistantDesktopStyle.surface, in: .circle)
                                    .offset(x: 3, y: 3)
                            }
                    }
                    .buttonStyle(.plain).accessibilityLabel(t("assistant.icons.change"))
                    .popover(isPresented: $appearanceExpanded) {
                        BotAppearanceEditor(botId: botId, selection: $appearance)
                            .padding(20).frame(width: 380)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name").font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField(t("bots.create.namePlaceholder"), text: $name)
                            .font(.system(size: 20, weight: .medium)).textFieldStyle(.plain)
                            .focused($nameFocused).accessibilityIdentifier("bots.create.name")
                    }
                }
                connection
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("bots.create.setup")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker(t("bots.create.setup"), selection: $setup) {
                        ForEach(Setup.allCases) { option in Text(option.title).tag(option) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.regular)
                    setupDetail
                }
                catalogFailure
            }
            .padding(24).padding(.top, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
        .disabled(saving)
    }
    #endif

    private var mobileForm: some View {
        AssistantPage {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    Button { nameFocused = false; sheet = .appearance } label: {
                        AssistantBotAvatar(botId: botId, icon: appearance.id, size: 64)
                            .overlay(alignment: .bottomTrailing) {
                                AppIcon(.edit, size: 12, decorative: true)
                                    .foregroundStyle(.primary).frame(width: 26, height: 26)
                                    .background(AssistantStyle.surface, in: .circle)
                                    .overlay { Circle().strokeBorder(AssistantStyle.canvas, lineWidth: 3) }
                                    .offset(x: 3, y: 3)
                            }
                        }
                    .buttonStyle(AssistantPressStyle())
                    .accessibilityLabel(t("assistant.icons.change"))
                    .accessibilityIdentifier("bots.create.appearance")
                    VStack(alignment: .leading, spacing: 7) {
                        Text(t("bots.create.name")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        TextField(t("bots.create.namePlaceholder"), text: $name)
                            .font(.title3.weight(.medium)).textFieldStyle(.plain)
                            .textInputAutocapitalization(.words).submitLabel(.done).focused($nameFocused)
                            .onSubmit { nameFocused = false }
                            .accessibilityIdentifier("bots.create.name")
                    }
                }
                .padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading(t(experienceMode == .general ? "bots.create.connection" : "bots.create.runtime"))
                    connection
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading(t("bots.create.setup"))
                    setupChoices
                    setupDetail
                }
                catalogFailure
            }
        } footer: {
            Button(action: begin) {
                HStack(spacing: 10) {
                    if saving { ProgressView().tint(AssistantStyle.canvas) }
                    Text(createTitle)
                }
                .font(.headline).frame(maxWidth: .infinity, minHeight: 24)
                .foregroundStyle(AssistantStyle.canvas)
            }
                .buttonStyle(.glassProminent).controlSize(.large).tint(.primary)
                .disabled(!canCreate)
                .accessibilityIdentifier("bots.create.submit")
        }
        .disabled(saving)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
    }

    private var setupChoices: some View {
        VStack(spacing: 0) {
            ForEach(Setup.allCases) { option in
                Button {
                    nameFocused = false
                    setup = option
                } label: {
                    HStack(spacing: 12) {
                        AppIcon(option.icon, size: 20, decorative: true)
                            .foregroundStyle(setup == option ? Palette.accent : .secondary)
                            .frame(width: 24)
                        Text(option.title).font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        AppIcon(setup == option ? .checkCircleFilled : .circle, size: 20, decorative: true)
                            .foregroundStyle(setup == option ? Palette.accent : Color(.tertiaryLabel))
                    }
                    .padding(.horizontal, 16).frame(minHeight: 54)
                    .background(setup == option ? Palette.accent.opacity(0.06) : .clear)
                    .contentShape(.rect)
                }
                .buttonStyle(AssistantPressStyle()).foregroundStyle(.primary)
                .accessibilityAddTraits(setup == option ? .isSelected : [])
                .accessibilityIdentifier("bots.create.setup.\(option.rawValue)")
                if option != Setup.allCases.last { Divider().padding(.leading, 52).padding(.trailing, 16) }
            }
        }
        .background(AssistantStyle.surface, in: .rect(cornerRadius: 18))
        .clipShape(.rect(cornerRadius: 18))
    }

    private var appearancePicker: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    AssistantBotAvatar(botId: botId, icon: appearance.id, size: 80).padding(.top, 8)
                    BotAppearanceEditor(botId: botId, selection: $appearance)
                }
                .padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
            .navigationTitle(t("assistant.icons.change"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { sheet = nil } }
            }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    @ViewBuilder private var setupDetail: some View {
        if setup == .instructions {
            TextField(t("bots.create.instructionsPlaceholder"), text: $instructions, axis: .vertical)
                .font(ApplePlatform.isDesktop ? .system(size: 13) : .subheadline)
                .lineLimit(4...8).padding(16)
                .background(AssistantStyle.surface, in: .rect(cornerRadius: ApplePlatform.isDesktop ? 12 : 18))
                .accessibilityIdentifier("bots.create.instructions")
        } else if setup == .mindwire {
            Text(t("bots.create.masterHelp")).font(ApplePlatform.isDesktop ? .system(size: 12) : .footnote)
                .foregroundStyle(.secondary).padding(.horizontal, ApplePlatform.isDesktop ? 0 : 4)
        }
    }

    @ViewBuilder private var catalogFailure: some View {
        if experienceMode == .developer, let catalogError = model.catalogError, model.catalog.isEmpty {
            Text(catalogError).font(.footnote).foregroundStyle(.secondary)
            Button(t("common.retry")) { Task { await model.loadCatalog() } }.tint(.primary)
        }
    }

    @ViewBuilder private var connection: some View {
        if experienceMode == .general { generalConnection }
        else { developerConnection }
    }

    private var developerConnection: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(engines) { engine in
                    Button(engineName(engine)) {
                        choseBaseAgent = true
                        model.agentType = engine.id
                    }
                }
            } label: {
                selectionRow(title: t("bots.create.engine"), value: selectedEngineName, icon: Icon.agents,
                             accessory: .chevronDown,
                             checking: !choseBaseAgent && resolvedEngineWorkspaceID != model.workspaceId)
            }
            .disabled(engines.isEmpty)
            connectionDivider
            computerChoice
        }
        .buttonStyle(.plain).padding(.horizontal, 16)
        .background(AssistantStyle.surface, in: .rect(cornerRadius: ApplePlatform.isDesktop ? 12 : 18))
    }

    @ViewBuilder private var generalConnection: some View {
        if ApplePlatform.isDesktop { desktopGeneralConnection }
        else { mobileGeneralConnection }
    }

    private var mobileGeneralConnection: some View {
        let ready = connections.connections.filter { $0.status == .ready }
        return VStack(spacing: 0) {
            if let generalAgent {
                Button(action: chooseConnection) {
                    selectionRow(title: "AI", value: AssistantAIService.connectionName(for: generalAgent.agentType), icon: .sparkles)
                }
                .accessibilityIdentifier("bots.create.connection")
            } else if !ready.isEmpty {
                ForEach(ready) { candidate in
                    Button { generalAgent = candidate.agent } label: {
                        selectionRow(title: "AI", value: t("bots.create.useConnection", ["name": candidate.name]), icon: .sparkles)
                    }
                    .accessibilityIdentifier("bots.create.connection.\(candidate.id)")
                    connectionDivider
                }
                Button(action: chooseConnection) {
                    selectionRow(title: "", value: t("bots.create.otherConnections"), icon: .plus)
                }
            } else if connections.loading {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).frame(width: 24)
                    Text(t("bots.create.checkingConnections")).font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 64)
            } else {
                Button {
                    if model.workspaceId == nil { sheet = repository.all.isEmpty ? .addComputer : .computers }
                    else { chooseConnection() }
                } label: {
                    selectionRow(title: "AI", value: t("bots.create.connectAI"), icon: .sparkles)
                }
                .accessibilityIdentifier("bots.create.connection")
            }
            connectionDivider
            computerChoice
        }
        .buttonStyle(.plain).padding(.horizontal, 16)
        .background(AssistantStyle.surface, in: .rect(cornerRadius: 18))
    }

    private var connectionDivider: some View { Divider().padding(.leading, 36) }

    @ViewBuilder private var computerChoice: some View {
        let workspace = model.workspaceId.flatMap(repository.get)
        let name = workspace.map { $0.runtime.isLocal && ApplePlatform.isDesktop ? "This Mac" : $0.name }
            ?? t("bots.create.chooseComputer")
        if model.fixedWorkspaceId == nil {
            Button { sheet = repository.all.isEmpty ? .addComputer : .computers } label: {
                selectionRow(title: t("bots.create.computer"), value: name, icon: .laptop)
            }
            .accessibilityIdentifier("bots.create.computer")
        } else {
            selectionRow(title: t("bots.create.computer"), value: name, icon: .laptop, accessory: nil)
        }
    }

    private var desktopGeneralConnection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI connection").font(.system(size: ApplePlatform.isDesktop ? 12 : 14)).foregroundStyle(.secondary)
            if let generalAgent {
                HStack {
                    Text("Using \(AssistantAIService.connectionName(for: generalAgent.agentType))")
                    Spacer()
                    Button("Change", action: chooseConnection).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            } else if let candidate = connections.connections.first(where: { $0.status == .ready }) {
                Button("Use your \(candidate.name) connection") { generalAgent = candidate.agent }
                    .buttonStyle(.borderedProminent)
                Button("Other connections", action: chooseConnection).buttonStyle(.plain).foregroundStyle(.secondary)
            } else if connections.loading {
                ProgressView("Checking your connections…").controlSize(.small)
            } else {
                Button("Connect your AI") {
                    if model.workspaceId == nil { sheet = repository.all.isEmpty ? .addComputer : .computers }
                    else { chooseConnection() }
                }
                    .buttonStyle(.bordered)
            }
            if let workspace = model.workspaceId.flatMap(repository.get) {
                HStack {
                    Text(workspace.runtime.isLocal ? "On this Mac" : workspace.name)
                    Spacer()
                    if model.fixedWorkspaceId == nil && repository.all.count > 1 {
                        Button("Change computer") { sheet = .computers }.buttonStyle(.plain)
                    }
                }
                .font(.system(size: ApplePlatform.isDesktop ? 11 : 13)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: ApplePlatform.isDesktop ? 13 : 16))
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(AssistantStyle.surface, in: .rect(cornerRadius: ApplePlatform.isDesktop ? 12 : 22))
    }

    private func connectionPicker(_ workspace: Workspace) -> some View {
        NavigationStack {
            AssistantConnectionPicker(workspace: workspace, repository: repository, discovery: connections, onReady: acceptConnection)
            .id(workspace.id)
            .navigationTitle("AI connection").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { sheet = nil }.fixedSize()
                }
            }
        }
        .frame(idealWidth: ApplePlatform.isDesktop ? 520 : nil, idealHeight: ApplePlatform.isDesktop ? 520 : nil)
    }

    private func selectionRow(title: String, value: String, icon: AppIconName,
                              accessory: AppIconName? = .chevronRight, checking: Bool = false) -> some View {
        HStack(spacing: 12) {
            AppIcon(icon, size: ApplePlatform.isDesktop ? 18 : 20, decorative: true)
                .foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                if !title.isEmpty {
                    Text(title).font(ApplePlatform.isDesktop ? .system(size: 11) : .caption).foregroundStyle(.secondary)
                }
                Text(value).font(ApplePlatform.isDesktop ? .system(size: 13, weight: .medium) : .subheadline.weight(.medium))
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if checking { ProgressView().controlSize(.mini) }
            else if let accessory { AppIcon(accessory, size: 13, decorative: true).foregroundStyle(.tertiary) }
        }
        .foregroundStyle(.primary).padding(.vertical, ApplePlatform.isDesktop ? 11 : 13)
        .frame(minHeight: ApplePlatform.isDesktop ? nil : 58).contentShape(.rect)
    }

    private var engines: [AgentDescriptor] {
        model.botEngines(existingAgents: agents)
    }
    private var selectedEngineName: String {
        engines.first(where: { $0.id == model.agentType }).map(engineName) ?? model.agentType.rawValue
    }
    private func engineName(_ engine: AgentDescriptor) -> String {
        experienceMode == .general ? AssistantAIService(agentType: engine.id)?.name ?? engine.name : engine.name
    }

    private var progress: some View {
        VStack(spacing: 20) {
            AssistantBotAvatar(botId: botId, icon: appearance.id, size: 76)
            Text(name).font(.title2.weight(.semibold))
            if saving { ProgressView(t("bots.create.saving")) }
            if let error {
                Text(error).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(t("common.retry")) { if let readyAgent { save(readyAgent) } }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
            }
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func begin() {
        guard canCreate else { return }
        nameFocused = false
        saving = true
        error = nil
        task = Task { @MainActor in
            defer { saving = false }
            do {
                let agent: Agent
                if experienceMode == .general, let generalAgent, generalAgent.workspaceId == model.workspaceId {
                    agent = generalAgent
                } else if let existing = connections.connections.first(where: {
                    $0.status == .ready && $0.agent.agentType == model.agentType && $0.agent.workspaceId == model.workspaceId
                })?.agent {
                    agent = existing
                } else if let existing = agents.first(where: { $0.agentType == model.agentType && $0.workspaceId == model.workspaceId }) {
                    agent = existing
                } else {
                    model.name = selectedEngineName
                    agent = try await model.create(stores: stores)
                }
                try Task.checkCancellation()
                selectedAgent = agent
            } catch { if !error.isRequestCancellation { self.error = error.localizedDescription } }
        }
    }

    private func save(_ agent: Agent) {
        guard !saving else { return }
        saving = true
        error = nil
        task = Task { @MainActor in
            defer { saving = false }
            do {
                let project = try await AssistantContext.prepare(agent: agent, stores: stores)
                try Task.checkCancellation()
                let bot = try await stores.workspaceData.createBot(.init(agentId: agent.id, projectId: project.id,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines), id: botId, icon: appearance.id,
                    instructions: setup == .instructions ? instructions : ""))
                try Task.checkCancellation()
                if setup == .mindwire { onAskMindwire(bot) } else { onCreated(bot) }
                dismiss()
            } catch { if !error.isRequestCancellation { self.error = error.localizedDescription } }
        }
    }

    private func resetAgent() { selectedAgent = nil; readyAgent = nil; error = nil }
    private func cancel() {
        if choosingConnection { choosingConnection = false }
        else if selectedAgent == nil { dismiss() }
        else { resetAgent() }
    }
    private func chooseConnection() {
        if ApplePlatform.isDesktop { choosingConnection = true }
        else { sheet = .connection }
    }
    private func acceptConnection(_ agent: Agent) {
        guard agent.workspaceId == model.workspaceId else { return }
        generalAgent = agent
        choosingConnection = false
        sheet = nil
    }
    private func reuseChosenConnection() {
        guard experienceMode == .general, generalAgent == nil else { return }
        generalAgent = connections.connections.first {
            $0.agent.id == stores.experience.assistantAgentID && $0.agent.workspaceId == model.workspaceId && $0.status == .ready
        }?.agent
    }
    private func selectAuthenticatedEngine() {
        let supported = Set(engines.map(\.id))
        guard experienceMode == .developer, !choseBaseAgent, !connections.loading,
              !saving, selectedAgent == nil,
              let preferred = connections.connections.first(where: { connection in
                  connection.status == .ready && connection.agent.workspaceId == model.workspaceId
                      && supported.contains(connection.agent.agentType)
              }) else { return }
        if model.agentType != preferred.agent.agentType { model.agentType = preferred.agent.agentType }
    }
    private var createTitle: String { t(setup == .mindwire ? "bots.create.withMindwire" : "assistant.bots.create") }
    private var canCreate: Bool {
        guard !saving, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let workspaceID = model.workspaceId else { return false }
        if experienceMode == .general {
            return generalAgent?.workspaceId == workspaceID && generalAgent.flatMap { stores.agents.get($0.id) } != nil
        }
        return (choseBaseAgent || resolvedEngineWorkspaceID == workspaceID)
            && engines.contains(where: { $0.id == model.agentType })
    }
    private func reloadAgents() { agents = model.workspaceId.map { stores.agents(forWorkspaceId: $0) } ?? [] }
    private func reconcile() {
        if model.fixedWorkspaceId == nil, model.pickedWorkspaceId.flatMap(repository.get) == nil {
            let preferred = stores.experience.assistantAgentID.flatMap(stores.agents.get)?.workspaceId
            model.pickedWorkspaceId = preferred.flatMap(repository.get)?.id ?? repository.all.first?.id
        }
        reloadAgents()
    }
}
