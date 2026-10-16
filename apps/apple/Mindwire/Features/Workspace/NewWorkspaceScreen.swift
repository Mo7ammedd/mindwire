import SwiftUI

/// Multi-step wizard for creating a workspace: name → runtime → (cloud-only) power.
/// One native `Form` per step, advanced with a glass bottom bar; a provisioning
/// overlay replaces the wizard while the workspace spins up. Mirrors `NewAgentScreen`.
///
/// Self-contained: owns its model, provisions, persists via `stores.createWorkspace`,
/// queues service setup, invokes `onCreated(workspace)`, and dismisses. Present with `.sheet`.
struct NewWorkspaceScreen: View {
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss

    let onCreated: (Workspace) -> Void
    private let assistantCloud: Bool
    var contextMessage: String?

    @State private var model = NewWorkspaceModel()
    @State private var servers: [Connection] = []
    @State private var step: Step = .name
    @State private var addDestination: ConnectionAddDestination?
    @State private var showLogin = false
    @State private var loginForImages = false
    @State private var pairedWorkspace: Workspace?

    /// Wizard steps, in order. The 3rd step is `power` for cloud, `review` for a self-hosted runtime
    /// (which has no cloud power preset) — so both paths are a consistent 3 steps.
    private enum Step: Int, CaseIterable {
        case name, runtime, image, power, review
    }

    init(contextMessage: String? = nil, rootDisk: WorkspaceManagedDisk? = nil, server: Connection? = nil, assistantCloud: Bool = false,
         onCreated: @escaping (Workspace) -> Void) {
        self.contextMessage = contextMessage
        self.assistantCloud = assistantCloud
        self.onCreated = onCreated
        let draft = NewWorkspaceModel()
        if assistantCloud { draft.name = "Mindwire Cloud" }
        _step = State(initialValue: assistantCloud ? .power : .name)
        draft.selectRoot(rootDisk)
        if let server { draft.selectedServerId = server.id; draft.name = server.name }
        if let rootDisk { draft.name = rootDisk.displayName }
        _model = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isProvisioning {
                    setupOverlay
                } else {
                    wizard
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.isProvisioning {
                    AppToolbarItem(placement: .cancellationAction) {
                        Button(t("common.cancel")) { dismiss() }
                            .tint(.primary)
                    }
                }
            }
            .alert(t("newAgent.setup.error"), isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button(t("common.ok"), role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $addDestination, onDismiss: {
            if let workspace = pairedWorkspace {
                pairedWorkspace = nil
                onCreated(workspace)
                dismiss()
            }
        }) { destination in
            AddServerScreen(presetType: destination.type, name: destination == .computer ? model.name : "") { connection in
                servers = stores.connections.list()
                model.selectedServerId = connection.id
                if connection.isLocal { pairedWorkspace = stores.workspaces(forServerId: connection.id).first }
            }
        }
        .oblienLoginSheet(isPresented: $showLogin) {
            if loginForImages {
                loginForImages = false
                Task {
                    await model.loadImages()
                    if assistantCloud { await model.loadAccountOverview() }
                }
            } else {
                create()
            }
        }
    }

    // MARK: Wizard

    /// The active step's Form plus progress chrome and the bottom Back/Next bar.
    private var wizard: some View {
        Group {
            if assistantCloud { assistantCloudForm }
            else { stepForm }
        }
            .navigationTitle(t(assistantCloud ? "assistant.setup.cloud" : "newWorkspace.title"))
            // iOS 26 soft scroll-edge effect: content blurs/fades natively as it passes under the
            // floating glass bar — no opaque panel.
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Spacing.sm) {
                    if !assistantCloud {
                        StepIndicator(current: currentStepIndex + 1, total: steps.count)
                            .padding(.horizontal, Spacing.xl)
                    }
                    bottomBar
                }
                .padding(.top, Spacing.sm)
                .frame(maxWidth: .infinity)
            }
    }

    @ViewBuilder
    private var stepForm: some View {
        @Bindable var model = model
        switch step {
        case .name:    nameStep(model: model)
        case .runtime: runtimeStep(model: model)
        case .image:   imageStep(model: model)
        case .power:   powerStep(model: model)
        case .review:  reviewStep(model: model)
        }
    }

    // MARK: Steps

    private func nameStep(model: NewWorkspaceModel) -> some View {
        Form {
            Section {
                TextField(t("newWorkspace.namePlaceholder"), text: $model.name)
                    .textInputAutocapitalization(.words)
            } header: {
                Text(t("newWorkspace.section.name"))
            } footer: {
                if let contextMessage { Text(contextMessage) }
            }
        }
    }

    private func runtimeStep(model: NewWorkspaceModel) -> some View {
        Form {
            // Oblien Cloud — the default host, its own card.
            Section {
                runtimeRow(
                    title: t("runtime.cloud.label"),
                    subtitle: t("runtime.cloud.subtitle"),
                    selected: model.selectedServerId == nil,
                    icon: { OblienMark(size: 24) }
                ) { model.selectedServerId = nil }
            }

            Section {
                Button {
                    addDestination = .computer
                } label: {
                    ConnectionDestinationRow(type: .local)
                }
                .tint(.primary)
            }
            Section {
                Button {
                    addDestination = .server
                } label: {
                    ConnectionDestinationRow(type: .ssh)
                }
                .tint(.primary)
            }
            if !servers.isEmpty {
                Section("Your computers & servers") {
                    ForEach(servers) { server in
                        runtimeRow(
                            title: server.name,
                            subtitle: serverSubtitle(server),
                            selected: model.selectedServerId == server.id,
                            icon: { ModeIcon(type: server.type, size: 24) }
                        ) { model.selectedServerId = server.id }
                    }
                }
            }
            if servers.first(where: { $0.id == model.selectedServerId })?.remote != nil {
                Section {
                    Picker(t("newWorkspace.environment"), selection: $model.useSandbox) {
                        Text(t("newWorkspace.direct")).tag(false)
                        Text(t("newWorkspace.sandbox")).tag(true)
                    }
                    .pickerStyle(.inline)
                } footer: {
                    Text(t(model.useSandbox ? "newWorkspace.sandbox.help" : "newWorkspace.direct.help"))
                }
            }
        }
        .listSectionSpacing(.compact)
    }

    /// A tappable runtime option with a trailing checkmark — used for the cloud + each server.
    @ViewBuilder
    private func runtimeRow<Icon: View>(
        title: String,
        subtitle: String,
        selected: Bool,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            EntityRow {
                Text(title)
            } subtitle: {
                Text(subtitle)
            } icon: {
                icon()
            } accessory: {
                if selected {
                    AppIcon(.check)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .tint(.primary)
    }

    /// Cloud-only — pick the base image (defaults to node), listed live from Oblien.
    private func imageStep(model: NewWorkspaceModel) -> some View {
        Form {
            if model.loadingImages {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if model.cloudAuthRequired {
                Section {
                    OblienSignInPrompt {
                        loginForImages = true
                        showLogin = true
                    }
                }
            } else if let err = model.imagesError {
                Section {
                    Text(err).foregroundStyle(Palette.danger)
                    Button(t("common.retry")) { Task { await model.loadImages() } }.tint(.primary)
                }
            } else if let root = model.storage.root {
                Section {
                    LabeledContent("Root Disk", value: root.displayName)
                    if let reference = root.rootImage { LabeledContent("Image", value: CloudImages.displayName(reference, in: model.images)) }
                    Button("Use a New Root") { model.selectRoot(nil) }.tint(.primary)
                } footer: {
                    Text("The retained root supplies this workspace’s existing files and boot configuration.")
                }
            } else {
                Section(t("newWorkspace.section.image")) {
                    ForEach(model.images) { img in
                        Button { model.selectedImageID = img.id } label: {
                            HStack(spacing: Spacing.md) {
                                imageIcon(img)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(img.label).foregroundStyle(.primary).lineLimit(1)
                                    if let d = img.description, !d.isEmpty {
                                        Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: Spacing.sm)
                                if model.selectedImageID == img.id {
                                    AppIcon(.check)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Palette.accent)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
        }
        .task { await model.loadImages() }
        .refreshable { await model.loadImages(force: true) }
    }

    /// The image's catalog logo — SVG (incl. simpleicons) and raster both render; failures fall
    /// back to a branded chip. See `RemoteLogoView`.
    private func imageIcon(_ img: WorkspaceImage) -> some View {
        RemoteLogoView(logo: img.logo, brandHex: img.color, label: img.label, size: 26)
    }

    private func powerStep(model: NewWorkspaceModel) -> some View {
        Form {
            cloudAccountSection

            Section {
                Stepper(value: $model.customCPUs, in: model.minimumCPUs...max(model.minimumCPUs, model.customMaximumCPUs)) {
                    resourceLabel(t("workspace.cpu"), detail: t("newWorkspace.resource.cpuHint"),
                                  value: "\(model.customCPUs) vCPU")
                }
                Stepper(value: $model.customMemoryGb, in: model.minimumMemoryGb...max(model.minimumMemoryGb, model.customMaximumMemoryGb)) {
                    resourceLabel(t("workspace.memory"), detail: t("newWorkspace.resource.memoryHint"),
                                  value: "\(model.customMemoryGb) GB")
                }
                if let root = model.storage.root {
                    LabeledContent("Root Disk", value: WorkspaceControlFormat.capacity(root.sizeMb))
                } else {
                    Stepper(value: $model.customDiskGb, in: model.minimumDiskGb...max(model.minimumDiskGb, model.customMaximumDiskGb)) {
                        resourceLabel(t("workspace.disk"), detail: t("newWorkspace.resource.diskHint"),
                                      value: "\(model.customDiskGb) GB")
                    }
                }
            } header: {
                Text(t("newWorkspace.custom.title"))
            } footer: {
                Text(t("newWorkspace.custom.limitHint"))
            }

            Section {
                NavigationLink {
                    WorkspaceCreationStorageScreen(model: model)
                } label: {
                    LabeledContent("Storage", value: model.storage.summary)
                }
            }

            cloudSummarySection
        }
        .task(id: model.spec) { await model.loadAccountOverview() }
    }
    private var cloudAccountSection: some View {
        Section {
            if model.loadingAccount && model.accountOverview == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let overview = model.accountOverview, let quota = overview.quota {
                LabeledContent(t("newWorkspace.account.plan"), value: quota.planLabel)
                if let balance = overview.balance {
                    LabeledContent(t("newWorkspace.account.credits"),
                                   value: String(format: "%.2f", balance))
                }
            }
        } header: {
            Text(t("newWorkspace.account.title"))
        }
    }

    private var cloudSummarySection: some View {
        Section {
            if model.loadingAccount {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let overview = model.accountOverview {
                if let estimate = overview.estimate {
                    LabeledContent(t("newWorkspace.account.estimate"),
                                   value: String(format: "%.0f–%.0f credits", estimate.estimate.min, estimate.estimate.max) + " / " + estimate.period)
                }
                if let denial = model.creationDenial {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Label(t("newWorkspace.unavailable.title"), icon: .warning)
                            .font(.headline)
                            .foregroundStyle(Palette.danger)
                        Text(denial).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if model.storage.validation(image: model.selectedImage) != nil {
                        Text("Review your storage choices before creating the workspace.").font(.footnote).foregroundStyle(.secondary)
                    } else if overview.creationDenial != nil {
                        billingLink(t("account.addCredits"), url: "https://oblien.com/dashboard/credits/purchase")
                    } else if overview.canUpgradePlan {
                        billingLink(upgradeLabel(overview), url: "https://oblien.com/dashboard/plan")
                    } else {
                        Label(t("newWorkspace.highestPlanHint"), icon: .verified)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if !assistantCloud || overview.quota != nil && overview.balance != nil && overview.estimate != nil {
                    Label(t("newWorkspace.available"), icon: .checkCircleFilled)
                        .foregroundStyle(Palette.success)
                }
            }
        } header: {
            Text(t("newWorkspace.summary"))
        } footer: {
            Text(t("newWorkspace.serviceHint"))
        }
    }

    private var assistantCloudForm: some View {
        Form {
            Section {
                Text(t("assistant.setup.cloud.review")).foregroundStyle(.secondary)
            }
            if model.cloudAuthRequired {
                Section {
                    OblienSignInPrompt { loginForImages = true; showLogin = true }
                }
            } else if model.loadingImages {
                Section { ProgressView(t("assistant.setup.checking")) }
            } else if let error = model.imagesError {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button(t("common.retry")) { Task { await loadAssistantCloud() } }.tint(.primary)
                }
            } else if model.selectedImage != nil {
                cloudAccountSection
                cloudSummarySection
                if !model.loadingAccount,
                   model.accountOverview?.quota == nil || model.accountOverview?.balance == nil || model.accountOverview?.estimate == nil {
                    Section {
                        Text(t("assistant.setup.cloud.costError")).foregroundStyle(.secondary)
                        Button(t("common.retry")) { Task { await model.loadAccountOverview() } }.tint(.primary)
                    }
                }
            } else {
                Section {
                    Text(t("assistant.setup.cloud.unavailable")).foregroundStyle(.secondary)
                    Button(t("common.retry")) { Task { await loadAssistantCloud() } }.tint(.primary)
                }
            }
        }
        .task { await loadAssistantCloud() }
    }

    private func loadAssistantCloud() async {
        await model.loadImages()
        guard !Task.isCancelled, model.selectedImage != nil else { return }
        await model.loadAccountOverview()
    }

    private func resourceLabel(_ title: String, detail: String, value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }

    private func billingLink(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(Palette.accent)
    }

    private func upgradeLabel(_ overview: CloudAccountOverview) -> String {
        overview.nextPlanName.map { "Upgrade to \($0)" } ?? t("account.upgrade")
    }

    /// Final step for a self-hosted runtime — confirm name + where it'll run before provisioning.
    private func reviewStep(model: NewWorkspaceModel) -> some View {
        Form {
            Section {
                LabeledContent(t("newWorkspace.section.name"), value: model.name)
                LabeledContent(t("newWorkspace.section.runtime"), value: runtimeSummary)
                if !model.isCloud {
                    LabeledContent(t("newWorkspace.environment"), value: t(model.useSandbox ? "newWorkspace.sandbox" : "newWorkspace.direct"))
                }
            } header: {
                Text(t("newWorkspace.section.review"))
            } footer: {
                Text(t("newWorkspace.serviceHint"))
            }
            if model.useSandbox {
                Section {
                    Stepper(value: $model.customCPUs, in: 1...model.customMaximumCPUs) {
                        LabeledContent("CPU", value: "\(model.customCPUs)")
                    }
                    Stepper(value: $model.customMemoryGb, in: 1...model.customMaximumMemoryGb) {
                        LabeledContent(t("workspace.memory"), value: "\(model.customMemoryGb) GB")
                    }
                } header: {
                    Text(t("newWorkspace.sandbox.resources"))
                } footer: {
                    Text(t("newWorkspace.sandbox.storage"))
                }
            }
        }
    }

    private var runtimeSummary: String {
        guard let id = model.selectedServerId else { return t("runtime.cloud.label") }
        return servers.first { $0.id == id }?.name ?? "Server unavailable"
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: Spacing.md) {
            if step != steps.first {
                Button(t("common.back")) { goBack() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            Spacer(minLength: 0)
            Button(t(assistantCloud ? "assistant.setup.createCloud" : isLastStep ? "newWorkspace.create" : "common.next")) {
                advance()
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(Palette.accent)
            .disabled(!stepIsValid)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: Step logic

    /// 3 steps either way: cloud gets the power preset, a self-hosted runtime gets a review step.
    private var steps: [Step] {
        assistantCloud ? [.power] : model.isCloud ? [.name, .runtime, .image, .power] : [.name, .runtime, .review]
    }

    private var isLastStep: Bool {
        step == steps.last
    }

    /// Index of the current step within the (runtime-dependent) sequence.
    private var currentStepIndex: Int {
        steps.firstIndex(of: step) ?? 0
    }

    /// Whether the current step's input is sufficient to advance.
    private var stepIsValid: Bool {
        switch step {
        case .name:  return !model.name.trimmingCharacters(in: .whitespaces).isEmpty
        case .image: return model.selectedImage != nil
        case .power: return !model.loadingAccount && model.creationDenial == nil
            && (!assistantCloud || model.selectedImage != nil && model.accountOverview?.quota != nil
                && model.accountOverview?.balance != nil && model.accountOverview?.estimate != nil && !model.loadingImages)
        default:     return true
        }
    }

    private func advance() {
        guard let index = steps.firstIndex(of: step) else { return }
        if index >= steps.count - 1 {
            create()
            return
        }
        withAnimation { step = steps[index + 1] }
    }

    private func goBack() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        withAnimation { step = steps[index - 1] }
    }

    // MARK: Setup overlay

    private var setupOverlay: some View {
        VStack(spacing: Spacing.lg) {
            ProgressView().controlSize(.large)
            Text(t("newWorkspace.setup.title")).font(.title2).multilineTextAlignment(.center)
            Text(t(!model.isCloud && model.useSandbox
                   ? "newWorkspace.sandbox.setup.\(model.stage.rawValue)"
                   : "newAgent.setup.\(model.stage.rawValue)"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !model.isCloud, model.useSandbox, model.stage == .booting {
                Text(t("newWorkspace.sandbox.setup.firstDownload"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func reload() {
        servers = stores.connections.list()
    }

    private func create() {
        Task {
            // Creating an Oblien Cloud workspace is account-scoped — require Oblien login first.
            // Self-hosted runtimes (SSH to your own server) don't.
            if model.isCloud, await OblienAuth.shared.ensure() == false {
                loginForImages = false
                showLogin = true
                return
            }
            guard let runtime = await model.provision(servers: servers) else { return }
            // The repository routes by runtime: self-hosted persists locally, cloud is surfaced
            // live from Oblien (never stored on device).
            guard let workspace = await WorkspaceRepository.shared.adopt(
                name: model.name,
                runtime: runtime,
                spec: model.isCloud || model.useSandbox ? model.spec : nil
            ) else {
                model.isProvisioning = false
                model.errorMessage = "The workspace was created, but its list could not be refreshed. Refresh Workspaces to open it."
                return
            }
            onCreated(workspace)
            dismiss()
        }
    }

    // MARK: Local formatting helpers

    private func serverSubtitle(_ c: Connection) -> String {
        if let remote = c.remote {
            return "\(remote.username)@\(remote.host):\(remote.port)"
        }
        if let visual = Modes.visuals[c.type] {
            return t(visual.subtitleKey)
        }
        return c.name
    }

}
