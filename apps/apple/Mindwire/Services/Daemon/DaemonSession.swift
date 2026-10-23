import SwiftUI
import Observation

/// The shared gate for an installed, reachable and authenticated agent. Neither cached credentials
/// nor the end of an installer process can substitute for the daemon verifying the CLI.
enum AgentConnectionPhase: Equatable {
    case checking                 // running the connectivity + auth check
    case ready                    // reachable AND authenticated — render the agent page
    case needsAuth                // reachable but not authenticated — show the connect gate
    case unreachable(String)      // no workspace, or the daemon couldn't be reached
}

/// What preparation is doing right now. Only the "work" cases warrant a progress bar — a plain
/// re-open of a ready agent (the common case) stays `.checking`: a quiet spinner, never a scary
/// "installing" checklist for work that isn't happening.
enum PrepActivity: Equatable {
    case checking          // quiet: probing, fast setup, auth — nothing to install
    case installingDaemon  // downloading + launching a new daemon (first run)
    case updatingDaemon    // replacing a stale daemon (version bump)
    case installingTools   // /setup is actually installing the agent CLI
    case updatingTools     // /update is replacing the agent CLI

    var isWorking: Bool { self != .checking }
}

/// The single, centralized handle the app uses to talk to one agent's daemon. **The daemon is the
/// driver of each agent** — it owns the agent's auth methods, settings schema, and status; this
/// object is just the app-side mirror. One instance per agent (shared via `DaemonManager`), so the
/// detail page, settings, the connect gate, and chat all speak to the *same* daemon session.
///
/// Everything routes through `call(_:)`:
///  - it ensures the daemon is up **once** (cached per agent — no repeated hard checks), and
///  - only re-ensures (relaunch) when a call actually fails with a connection error, then retries.
///
/// Auth: field methods (Claude's `apiKey`) submit values in one `authStep`; interactive methods
/// (`login`) `authBegin` to surface an OAuth URL, then poll `authStep([:])` to completion.
/// Credentials are persisted by the daemon in the workspace — never on the device.
@MainActor
@Observable
final class DaemonSession {
    let agentId: String

    // Daemon-provided agent props (the source of truth that drives the UI).
    private(set) var info: DaemonAgentInfo?
    var methods: [DaemonAuthMethod] { info?.authMethods ?? fallbackMethods }
    var status: DaemonAuthStatus? { toolsWork?.authentication ?? info?.authStatus ?? fallbackStatus }
    var schema: DaemonSettingsSchema { info?.schema ?? .empty }
    var capabilities: DaemonCapabilities? { info?.capabilities }
    var software: DaemonHarnessSoftware? { toolsWork?.software ?? info?.software }
    var modelProviders: [String] { info?.modelProviders ?? [] }
    /// The agent's editable config file (absolute path on the workspace), if any.
    var configPath: String? {
        guard let p = info?.configPath, !p.isEmpty else { return nil }
        return p
    }
    /// The agent's workspace exec surface — so the config file can open in the code editor.
    var workspace: WorkspaceService? { backend?.workspace ?? providedWorkspace }
    /// A caller providing a transport can lend its matching file service without creating a backend.
    private let providedWorkspace: WorkspaceService?

    // Connectivity + lifecycle.
    private var connectionPhase: AgentConnectionPhase = .checking
    private(set) var connectionContext: WorkspaceConnectionContext?
    var phase: AgentConnectionPhase {
        get {
            if activeWork != nil { return .checking }
            if toolsWork?.requiresVerification == true {
                if let error = toolsWork?.error { return .unreachable(error) }
                if case .unreachable = connectionPhase { return connectionPhase }
                return .checking
            }
            if connectionPhase == .ready || connectionPhase == .needsAuth, let status {
                return status.configured ? .ready : .needsAuth
            }
            return connectionPhase
        }
        set { connectionPhase = newValue }
    }
    var preparing = false
    var loading = false
    var prepSteps: [DaemonStepResult] { toolsWork?.steps ?? [] }
    /// What preparation is doing now — drives whether the UI shows a quiet spinner or a progress bar.
    var activity: PrepActivity { activeWork?.activity ?? .checking }
    /// Human-readable detail shown under the active work ("Downloading the agent…", etc.).
    var statusMessage: String? {
        get { activeWork?.message ?? connectionMessage }
        set { connectionMessage = newValue }
    }
    /// Follow the active job, so a completed service download never fills the CLI's progress bar.
    var preparationProgress: Double? { activeWork?.progressFraction }
    var preparationPlan: [String] { activeWork?.plan ?? [] }
    var preparationStartedAt: Date? { activeWork?.startedAt }
    var preparationCurrentStep: String? { activeWork?.currentStep }
    var loadError: String?
    var hasWorkspace: Bool { bound }
    var isConfigured: Bool { status?.configured == true }

    // Active connect attempt (field or interactive).
    var working = false
    private(set) var signingOut = false
    private var authenticationRevision = 0
    var connectError: String?
    var activeMethod: String?
    var loginURL: String?
    private(set) var loginCallbackURL: String?
    var loginCode: String?
    var loginMessage: String?
    var loginFields: [DaemonField] = []
    var loginSections: [DaemonAuthSection] = []
    var loginSubmitting = false
    var loginForm: DaemonAuthFormSchema { .init(fields: loginFields, sections: loginSections) }
    /// Completion of the current login attempt, independent of an existing signed-in account.
    private(set) var completedAuthMethod: String?

    private var backend: Backend?
    @ObservationIgnored private weak var gitStores: Stores?
    private var workspaceId: String?
    var authenticationWorkspace: Workspace? { workspaceId.flatMap { WorkspaceRepository.shared.get($0) } }
    private var connectionMessage: String?
    private let workCoordinator = DaemonWorkCoordinator.shared
    private var daemonKey: DaemonWorkKey { .init(workspaceId: workspaceId ?? agentId) }
    private var toolsKey: DaemonWorkKey { .init(workspaceId: workspaceId ?? agentId, agentType: agentType) }
    var daemonWork: DaemonWorkState? { workCoordinator.states[daemonKey] }
    var toolsWork: DaemonWorkState? { workCoordinator.states[toolsKey] }
    private var activeWork: DaemonWorkState? {
        if let work = daemonWork, work.changingService { return work }
        if let work = toolsWork, work.running { return work }
        return nil
    }
    private var transport: AgentTransport = NullTransport()
    private var bound = false
    private var agentType = ""
    private var daemonToken = ""
    private var ensured = false          // per-agent cache: daemon up + toolchain installed
    private var preparedInfo: DaemonAgentInfo? // reuse setup's verified /agent response for the auth gate
    private var lastNotificationAttempt: Date?
    private var notificationsConfigured = false
    private var notificationTask: Task<Void, Never>?
    private var ensureTask: Task<Void, Error>?   // in-flight ensure, so concurrent callers dedup
    private var loadTask: Task<Void, Never>?
    private var loadFreshness = RefreshState()
    private var loadedDaemonRevision: Int?
    private let now: () -> Date
    private var pollTask: Task<Void, Never>?
    private var interactiveAttemptID: UUID?
    private var finishingInteractiveAttemptID: UUID?
    private var loginFlowID: String?
    private var interactiveInputRevision = 0
    private var authCancelTask: Task<Void, Never>?
    // Only used if `/agent` omits them and the dedicated endpoints answer.
    private var fallbackMethods: [DaemonAuthMethod] = []
    private var fallbackStatus: DaemonAuthStatus?

    init(agentId: String, transport: AgentTransport? = nil, workspace: WorkspaceService? = nil,
         workspaceId: String? = nil, agentType: String = "",
         now: @escaping () -> Date = Date.init) {
        self.agentId = agentId
        self.providedWorkspace = workspace
        self.now = now
        self.workspaceId = workspaceId
        self.agentType = agentType
        if let transport {
            self.transport = transport
            bound = true
            ensured = true
        }
    }

    /// Resolve the agent → workspace → transport. Returns false when the agent has no reachable
    /// workspace (orphaned / cloud workspace gone).
    @discardableResult
    func bind(stores: Stores) -> Bool {
        gitStores = stores
        guard let agent = stores.agents.get(agentId),
              let workspaceId = agent.workspaceId,
              let workspace = WorkspaceRepository.shared.get(workspaceId) else {
            transport = NullTransport()
            backend = nil
            bound = false
            ensured = false
            phase = .unreachable(t("agentAuth.noWorkspace"))
            return false
        }
        let backend = BackendFactory.make(forRuntime: workspace.runtime, stores: stores)
        connectionContext = WorkspaceConnectionContext(workspace, stores: stores)
        self.backend = backend
        bound = true
        self.workspaceId = workspaceId
        self.agentType = agent.agentType.rawValue
        let tokenKey = KeychainKey.runtimeToken(workspaceId)
        if let stored = Keychain.get(tokenKey), !stored.isEmpty {
            daemonToken = stored
        } else {
            daemonToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            Keychain.set(daemonToken, for: tokenKey)
        }
        // Scope the transport to this agent type so the shared per-workspace daemon routes to it.
        self.transport = BackendFactory.transport(forBackend: backend, agentType: agentType, daemonToken: daemonToken)
        return true
    }

    // MARK: - Centralized daemon access

    /// THE way to make a daemon request. Ensures the daemon is up (cached), runs `op`, and if the
    /// call fails with a *connection* error (daemon died / restarted) re-ensures once and retries.
    /// Non-connection errors (e.g. a 409 "turn already running") propagate untouched.
    @discardableResult
    func call<T>(retryOnConnectionFailure: Bool = true, _ op: (AgentTransport) async throws -> T) async throws -> T {
        try await ensure()
        do {
            return try await op(transport)
        } catch let error where Self.isConnectionFailure(error) {
            loadFreshness.invalidate()
            workCoordinator.recordFailure(error, for: daemonKey, revision: workCoordinator.probeRevision(daemonKey))
            ensured = false
            guard retryOnConnectionFailure else { throw error }
            try await ensure(force: true)
            return try await op(transport)
        }
    }

    /// Ensure the daemon + toolchain are ready (cached per agent). Returns the install steps for a
    /// Preparing UI. Hard work runs only on the first call (or a forced re-ensure).
    @discardableResult
    func prepare() async throws -> [DaemonStepResult] {
        try await ensure()
        return prepSteps
    }

    /// Ensure the daemon once, then hand back the RAW live event stream. Deliberately NOT wrapped in
    /// `call(_:)`: a long-lived stream isn't a retryable one-shot (its normal EOF would be misread as
    /// a connection failure and silently restarted). Reconnection is the caller's concern.
    /// nil ⇒ the channel can't stream (curl/ssh) → the caller polls instead.
    func streamRun(_ runId: String, after: Int? = nil) async throws -> AsyncThrowingStream<DaemonEvent, Error>? {
        try await ensure()
        return transport.streamRun(runId, after: after)
    }

    /// Passive status reads must not start workspaces or install tools just to draw a list badge.
    func readChatActivity() async throws -> [DaemonChatSummary] {
        guard hasWorkspace else { throw BackendError.unreachable(t("agentAuth.noWorkspace")) }
        return try await transport.listChats()
    }

    /// Like the list badge, its elapsed clock must never prepare or restart the workspace.
    func readRunActivity(_ runId: String) async throws -> DaemonRun {
        guard hasWorkspace else { throw BackendError.unreachable(t("agentAuth.noWorkspace")) }
        return try await transport.getRun(runId)
    }

    /// The chat's latest run — a one-shot, so it rides `call` (self-heals a dead daemon).
    func chatRun(_ chatId: String) async throws -> DaemonRun? {
        try await call { try await $0.chatRun(chatId: chatId) }
    }

    func nativeActivity(_ chatId: String) async throws -> NativeSessionActivity? {
        try await ensure()
        let health: DaemonHealth
        if let cached = daemonWork?.health { health = cached }
        else { health = await transport.health() }
        guard (health.nativeSessionVersion ?? 0) >= 1 else { return nil }
        return try await call { try await $0.nativeActivity(chatId: chatId) }
    }

    func readNativeActivity(_ chatId: String) async throws -> NativeSessionActivity? {
        guard hasWorkspace else { throw BackendError.unreachable(t("agentAuth.noWorkspace")) }
        // A list badge must never start a workspace or provision a CLI.
        return try await transport.nativeActivity(chatId: chatId)
    }

    func nativeEvents(_ chatId: String, cursor: String?) async throws -> AsyncThrowingStream<NativeSessionFrame, Error>? {
        try await ensure()
        return transport.nativeEvents(chatId: chatId, cursor: cursor)
    }

    func nativeAction(_ chatId: String, action: NativeSessionAction,
                      progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                      onPrepared: (@MainActor @Sendable (NativeSessionAction) -> Void)? = nil,
                      canAdmit: (@MainActor @Sendable () -> Bool)? = nil) async throws -> NativeSessionReceipt {
        var prepared = action
        if let attachments = action.attachments, !attachments.isEmpty {
            prepared.attachments = try await uploadAttachments(chatId: chatId, attachments: attachments, progress: progress)
        }
        if canAdmit?() == false { throw CancellationError() }
        onPrepared?(prepared)
        // An uncertain acknowledgement stays uncertain. The caller retains the
        // same request/connection IDs for an explicit retry, including reconnects.
        return try await call(retryOnConnectionFailure: false) { try await $0.nativeAction(chatId: chatId, action: prepared) }
    }

    private func uploadAttachments(chatId: String, attachments: [DaemonAttachment],
                                   progress: (@MainActor @Sendable (Double) -> Void)?) async throws -> [DaemonAttachment] {
        var result: [DaemonAttachment] = []
        for (index, attachment) in attachments.enumerated() {
            let uploaded = try await call { transport in
                try await transport.uploadAttachment(chatId: chatId, attachment: attachment) { value in
                    progress?((Double(index) + value) / Double(attachments.count))
                }
            }
            result.append(uploaded)
        }
        return result
    }

    /// Share the metadata already fetched for chat settings with its live
    /// controls. Opening a chat directly must not depend on visiting Agents first.
    func agentInfo() async throws -> DaemonAgentInfo {
        let value = try await call { try await $0.agentInfo() }
        info = value
        workCoordinator.recordAgentInfo(value, for: toolsKey)
        return value
    }

    /// The daemon's server-side chat list (for live "running" badges in chat lists).
    func listChats() async throws -> [DaemonChatSummary] {
        try await call { try await $0.listChats() }
    }

    func voiceStatus() async throws -> HarnessVoiceStatus {
        try await ensure()
        return try await call { try await $0.voiceStatus() }
    }

    func startVoice(chatId: String, cwd: String?, requestId: String, clientId: String, voice: String?) async throws -> DaemonRun {
        try await ensure()
        guard toolsWork?.running != true, daemonWork?.running != true else { throw BackendError.message(t("agentUpdates.busy")) }
        let health = await transport.health()
        try await prepareDesktopTools(health: health)
        return try await call(retryOnConnectionFailure: (health.turnRequestVersion ?? 0) >= 1) { transport in
            let auth = try await self.gitAuthorization(chatId: chatId, transport: transport)
            return try await transport.startVoice(chatId: chatId, cwd: cwd, gitAuth: auth, requestId: requestId, clientId: clientId, voice: voice)
        }
    }

    func voiceControl(runId: String, clientId: String, action: String, sequence: Int? = nil, audio: HarnessVoiceAudio? = nil) async throws {
        // Never replay microphone audio after an ambiguous connection failure.
        try await call(retryOnConnectionFailure: false) { try await $0.voiceControl(runId: runId, clientId: clientId, action: action, sequence: sequence, audio: audio) }
    }

    func voiceEvents(runId: String, clientId: String) throws -> AsyncThrowingStream<HarnessVoiceEvent, Error> {
        guard let stream = transport.voiceEvents(runId: runId, clientId: clientId) else { throw BackendError.message(t("chat.voice.native.streamingRequired")) }
        return stream
    }

    func sendTurn(chatId: String, message: String, cwd: String?, requestId: String = UUID().uuidString, attachments: [DaemonAttachment] = [], queueIfRunning: Bool = false, command: DaemonCommandInvocation? = nil,
                  attachmentProgress: (@MainActor @Sendable (Double) -> Void)? = nil,
                  canAdmit: (@MainActor @Sendable () -> Bool)? = nil) async throws -> DaemonRun {
        if toolsWork?.running == true || daemonWork?.running == true {
            throw BackendError.message(t("agentUpdates.busy"))
        }
        try await ensure()
        let health = await transport.health()
        if queueIfRunning {
            guard (health.queuedInputVersion ?? 0) >= 1 else { throw BackendError.message(t("chat.queue.updateRequired")) }
        } else { try await prepareDesktopTools(health: health) }
        if attachments.contains(where: \.isImage) {
            let supportsImages: Bool
            if let capabilities { supportsImages = capabilities.imageInput == true }
            else { supportsImages = try await transport.agentInfo().capabilities?.imageInput == true }
            guard supportsImages else { throw BackendError.message("This agent doesn't support image input.") }
            guard (health.imageAttachmentsVersion ?? 0) >= 1 else {
                throw BackendError.message("Update the Mindwire service to send images and keep them in chat history.")
            }
        }
        var prepared: [DaemonAttachment] = []
        if (health.attachmentUploadVersion ?? 0) >= 1 {
            prepared = try await uploadAttachments(chatId: chatId, attachments: attachments, progress: attachmentProgress)
        } else {
            // Existing image-capable services still work while their update is pending.
            // Ordinary files require durable storage, so never give the CLI a soon-deleted path.
            guard attachments.allSatisfy(\.isImage) else { throw BackendError.message("Update the Mindwire service to attach files.") }
            for attachment in attachments {
                let limit = min(160 * 1_024, 700 * 1_024 / max(1, attachments.count))
                if let data = attachment.data, data.count > limit {
                    let image = try await Task.detached(priority: .userInitiated) {
                        try ChatImageEncoding.prepare(data, name: attachment.name ?? "Photo.jpg", maximumBytes: limit)
                    }.value
                    prepared.append(image)
                } else { prepared.append(attachment) }
            }
        }
        let canRetry = (health.turnRequestVersion ?? 0) >= 1
        let inputs = prepared
        if canAdmit?() == false { throw CancellationError() }
        return try await call(retryOnConnectionFailure: canRetry) { transport in
            // The daemon probes admission against the current executable. A cached settings
            // response must not keep rejecting a CLI that was repaired outside this screen.
            let auth = try await self.gitAuthorization(chatId: chatId, transport: transport)
            return try await transport.sendTurn(chatId: chatId, message: message, cwd: cwd, gitAuth: auth,
                requestId: canRetry ? requestId : nil, attachments: inputs, queueIfRunning: queueIfRunning, command: command)
        }
    }

    func respondToRun(_ runId: String, chatId: String, interactionId: String,
                      reply: DaemonInteractionReply, canResume: Bool) async throws {
        if canResume { try await prepareDesktopTools(health: await transport.health()) }
        try await call { transport in
            let auth = canResume ? try await self.gitAuthorization(chatId: chatId, transport: transport) : nil
            try await transport.respondToRun(runId, interactionId: interactionId, reply: reply, gitAuth: auth)
        }
    }

    private func prepareDesktopTools(health: DaemonHealth) async throws {
        guard (health.surfaceProtocolVersion ?? 0) >= 2, let stores = gitStores, let workspaceId,
              let workspace = WorkspaceRepository.shared.get(workspaceId), workspace.isCloud else { return }
        do { _ = try await stores.workspaceData.desktopCatalogHTTP(workspace) }
        catch {
            if error.isRequestCancellation || Task.isCancelled { throw CancellationError() }
            // Desktop setup is optional. A provider outage must not block a coding turn.
            APILog.note("Desktop tool authorization unavailable; the chat can continue without it.")
        }
    }

    private func gitAuthorization(chatId: String, transport: AgentTransport) async throws -> ProjectCloneAuth? {
        guard let stores = gitStores, let workspaceId, let chat = stores.chats.get(chatId),
              let project = stores.projects.get(chat.projectId) else { return nil }
        let health = await transport.health()
        guard (health.gitAccessVersion ?? 0) >= 1 else {
            if project.gitConnection != nil { throw WorkspaceRegistryError.gitAccessUnavailable }
            return nil
        }
        let state = try await transport.projectGitState(project.id)
        guard state.repoUrl?.isEmpty == false else { return nil }
        return try await GitCredentialResolver.authorization(connection: state.connection, repoURL: state.repoUrl,
            workspaceId: workspaceId, stored: state.stored, stores: stores)
    }

    func renameChat(_ chatId: String, title: String) async throws -> DaemonChatSummary {
        try await call { try await $0.renameChat(chatId: chatId, title: title) }
    }

    func previewHandoff(_ chatId: String) async throws -> DaemonHandoffPreview {
        try await ensure()
        let health = await transport.health()
        guard (health.crossAgentHandoffVersion ?? 0) >= 2 else {
            throw BackendError.message(t("chat.handoff.updateRequired"))
        }
        return try await call { try await $0.previewHandoff(chatId: chatId) }
    }

    func handoff(_ chatId: String, request: ChatHandoffRequest) async throws -> DaemonHandoffResult {
        try await call { try await $0.handoff(chatId: chatId, request: request) }
    }

    func forkChat(_ chatId: String, newChatId: String, beforeMessageId: String) async throws -> DaemonChatFork {
        try await ensure()
        let health = await transport.health()
        guard (health.chatForkVersion ?? 0) >= 1, (health.turnRequestVersion ?? 0) >= 1 else {
            throw BackendError.message(t("chat.fork.updateRequired"))
        }
        return try await call { try await $0.forkChat(chatId: chatId, newChatId: newChatId, beforeMessageId: beforeMessageId) }
    }

    func deleteChat(_ chatId: String, stopRunning: Bool = false) async throws {
        try await call { transport in
            if stopRunning, let run = try await transport.chatRun(chatId: chatId), run.status == .running {
                try await transport.cancelRun(run.id)
                for _ in 0..<40 {
                    if try await transport.getRun(run.id).status != .running { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            // The daemon still rejects deletion if a turn is busy (including a newly started run).
            try await transport.deleteChat(chatId: chatId)
        }
    }

    /// Reading a context-menu preview must never install, launch or resume an agent.
    func readChatPreview(_ chatId: String) async throws -> [DaemonMessage] {
        async let history = transport.messagePage(chatId: chatId, limit: 6, before: nil, maxBytes: ChatHistoryPaging.maxBytes)
        async let latestRun = try? transport.chatRun(chatId: chatId)
        let messages = try await history.messages
        guard let run = await latestRun, run.status == .running,
              let snapshot = try? await transport.runSnapshot(run.id) else { return messages }
        return ChatTurnCompletion.reconcile(current: messages, fetched: nil, live: LiveTurn(snapshot: snapshot),
            run: snapshot.run, runId: run.id, baselineIDs: Set(messages.map(\.id)), pendingUser: nil).messages
    }

    private func ensure(force: Bool = false, updateService: Bool = false) async throws {
        if ensured && !force {
            // Reads, Stop and other controls for an existing run must remain available while a
            // background update is running. New turns are gated separately in sendTurn.
            // A retry of optional push setup must not delay sending, stopping, or reconnecting.
            Task { [weak self] in await self?.reconcileNotifications() }
            return
        }
        guard let backend else { throw BackendError.unreachable(t("agentAuth.noWorkspace")) }
        // Dedup concurrent ensures (the agent page + a chat can both prepare at once) — run one
        // bootstrap and have all callers await it.
        if let ensureTask { return try await ensureTask.value }
        let task = Task { try await self.runEnsure(backend, updateService: updateService) }
        ensureTask = task
        defer { ensureTask = nil }
        try await task.value
    }

    private func runEnsure(_ backend: Backend, updateService: Bool) async throws {
        if let workspaceId {
            let token = await WorkspaceDaemonCredential.resolve(workspaceId: workspaceId, workspace: backend.workspace)
            if token != daemonToken {
                daemonToken = token
                transport = BackendFactory.transport(forBackend: backend, agentType: agentType, daemonToken: token)
            }
        }
        try await workCoordinator.perform(daemonKey) { work in
            let current = await self.transport.health()
            let latest: String?
            if updateService { latest = try await ReleaseCatalog.shared.load(maxAge: 0, allowStale: false).version }
            // Existing services need no release-host request to open a conversation.
            // The foreground update scheduler refreshes available versions independently.
            else if current.ok { latest = await ReleaseCatalog.shared.cached()?.version }
            else { latest = await DaemonRelease.latestVersion() }
            if updateService, let latest { self.workCoordinator.recordLatestRelease(latest) }
            self.workCoordinator.recordHealth(current, for: self.daemonKey, latest: latest)
            var requireUpdateLease = false
            let confirmed = try await DaemonServicePreparation.run(
                current: current, latest: latest, work: work, updateRequested: updateService,
                startInstalled: {
                    try await BackendFactory.daemonInstaller(forBackend: backend).startInstalled(daemonToken: self.daemonToken)
                },
                install: { try await self.installDaemon(backend, target: $0, work: work, requireUpdateLease: requireUpdateLease, force: updateService) },
                requireIdle: {
                    if !updateService && !BackendFactory.daemonInstaller(forBackend: backend).queuesUpdates {
                        try await self.transport.requireIdleForDaemonUpdate(health: $0)
                    }
                    requireUpdateLease = ($0.serviceUpdateVersion ?? 0) >= 1
                },
                health: { await self.transport.health() })
            self.workCoordinator.recordHealth(confirmed, for: self.daemonKey, latest: latest)
            self.workCoordinator.configureStartupIfNeeded(self.daemonKey) {
                try await BackendFactory.daemonInstaller(forBackend: backend).configureStartup(daemonToken: self.daemonToken)
            }
        }

        try await workCoordinator.perform(toolsKey) { work in
            self.preparedInfo = try await AgentInstallation.ensure(transport: self.transport, work: work)
        }
        ensured = true
        // Notification credentials are optional. Cold history and controls must not wait
        // for the provider; use the same deduplicated retry path as later foreground checks.
        Task { [weak self] in await self?.reconcileNotifications() }
    }

    private func installDaemon(_ backend: Backend, target: String, work: DaemonWorkState, requireUpdateLease: Bool = false, force: Bool = false) async throws {
        try await BackendFactory.daemonInstaller(forBackend: backend)
            .install(agentType: agentType, cwd: "", target: target, daemonToken: daemonToken,
                     requireUpdateLease: requireUpdateLease, force: force,
                     onProgress: work.progressHandler())
        work.receive(.verifying)
        if let workspaceId {
            daemonToken = await WorkspaceDaemonCredential.resolve(workspaceId: workspaceId, workspace: backend.workspace)
            transport = BackendFactory.transport(forBackend: backend, agentType: agentType, daemonToken: daemonToken)
        }
    }

    /// Passive row observation never prepares a workspace or starts an update.
    func readPreparation() async {
        guard hasWorkspace else { return }
        async let daemon: Void = workCoordinator.refresh(daemonKey, interval: 60) {
            let cached = self.workCoordinator.freshHealth(for: self.daemonKey)
            let health: DaemonHealth
            if let cached { health = cached }
            else { health = await self.transport.health() }
            async let catalog = try? ReleaseCatalog.shared.load(maxAge: 300)
            // A reused health result must not renew its own expiry on every row appearance.
            if cached != nil { return .daemon(installed: nil, latest: (await catalog)?.version) }
            return .workspace(health: health, latest: (await catalog)?.version)
        }
        async let tools: Void = workCoordinator.refresh(toolsKey, interval: 3) {
            let setup = try await self.transport.setupStatus()
            let checkedAt = self.toolsWork?.authenticationCheckedAt ?? .distantPast
            let authentication = setup.running != true && Date().timeIntervalSince(checkedAt) >= 30
                ? try? await self.transport.authStatus() : nil
            return .setup(setup, authentication: authentication)
        }
        _ = await (daemon, tools)
        await refreshSoftware()
    }

    func refreshSoftware(force: Bool = false) async {
        guard software != nil || (daemonWork?.health?.harnessPolicyVersion ?? 0) >= 1 else { return }
        await workCoordinator.refreshSoftware(toolsKey, force: force) {
            try await self.transport.software(refresh: force)
        }
    }

    /// Visible agent pages keep following the service even when another client starts setup.
    /// A completed remote job is revalidated before cached authentication can unlock the page.
    func observePreparation() async {
        while !Task.isCancelled {
            await readPreparation()
            if toolsWork?.requiresVerification == true, toolsWork?.error == nil {
                await load()
            }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    /// The daemon's /update and /setup share its per-harness lock. The app shares the waiting task
    /// too, so opening another screen cannot post a second update or lose progress.
    func updateAgent() async throws {
        if try await workCoordinator.join(toolsKey) { await refresh(); return }
        _ = try await workCoordinator.join(daemonKey)
        try await ensure()
        let currentInfo = try await transport.agentInfo()
        try AgentInstallation.requireManagedInstaller(currentInfo)
        try await workCoordinator.perform(toolsKey, activity: .updatingTools) { work in
            let current = try await self.transport.setupStatus()
            if current.running != true {
                let chats = try await self.transport.listChats()
                guard !chats.contains(where: { $0.lastStatus == "running" }) else {
                    throw BackendError.message(t("agentUpdates.chatsRunning"))
                }
            }
            let started = current.running == true ? current : try await self.transport.update()
            try await AgentInstallation.waitForCompletion(transport: self.transport, initial: started, work: work)
            self.preparedInfo = try await self.transport.agentInfo()
            work.software = self.preparedInfo?.software
            guard self.preparedInfo?.installedVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                self.preparedInfo = nil
                self.ensured = false
                throw BackendError.message(t("agentUpdates.verifyFailed"))
            }
        }
        await refresh()
    }

    func updateDaemon() async throws {
        // Joining passive preparation must not consume the user's explicit update intent.
        if let ensureTask { try await ensureTask.value }
        _ = try await workCoordinator.join(daemonKey)
        try await ensure(force: true, updateService: true)
        await refresh()
    }

    private func configureNotifications(for backend: Backend) async {
        lastNotificationAttempt = Date()
        notificationsConfigured = false
        guard let workspaceId,
              let scope = WorkspaceNotificationScope(workspaceID: workspaceId, runtime: backend.runtime),
              let token = await WorkspaceNotify.sendToken(scope: scope) else { return }
        do {
            try await transport.setNotifyConfig(url: WorkspaceNotify.sendURL, channel: workspaceId, token: token)
            notificationsConfigured = true
        } catch {
            // Notifications must never prevent connecting to an otherwise healthy agent.
            APILog.note("daemon session[\(agentId)]: notification config failed — \(error.localizedDescription.oneLine())")
        }
    }

    /// Retry failed provisioning independently of the cached daemon/toolchain preparation. Passive
    /// foreground reconciliation only touches sessions already connected; it never starts a workspace.
    func reconcileNotifications(force: Bool = false) async {
        guard ensured, let backend else { return }
        if let notificationTask { await notificationTask.value; return }
        let interval: TimeInterval = notificationsConfigured ? 300 : 30
        if !force, let lastNotificationAttempt, Date().timeIntervalSince(lastNotificationAttempt) < interval { return }
        let task = Task { await self.configureNotifications(for: backend) }
        notificationTask = task
        defer { notificationTask = nil }
        await task.value
    }

    private static func isConnectionFailure(_ error: Error) -> Bool {
        // A CANCELLED request (Task cancellation from view churn, or a superseded call) is NOT the
        // daemon going down — treating it as one caused a re-ensure loop that re-ran /setup. Never
        // re-ensure on cancellation.
        if error is CancellationError { return false }
        let m = error.localizedDescription.lowercased()
        if m.contains("cancel") { return false }
        if case BackendError.unreachable = error { return true }
        return m.contains("connect") || m.contains("refused") || m.contains("unreachable")
            || m.contains("timed out") || m.contains("timeout") || m.contains("empty response")
    }

    // MARK: - Load / refresh (drives the connection phase + auth UI)

    /// Prepare the daemon, then load the agent props + settle the phase. Safe to call repeatedly.
    func load(force: Bool = false) async {
        if let loadTask { await loadTask.value; return }
        let authChanged = toolsWork?.authentication.map { $0.configured != status?.configured } ?? false
        guard force || activeWork != nil || toolsWork?.requiresVerification == true || authChanged
                || loadedDaemonRevision != workCoordinator.probeRevision(daemonKey)
                || !loadFreshness.isFresh(at: now()) else { return }
        let task = Task { await self.loadConnection(retryFailed: force) }
        loadTask = task
        defer { loadTask = nil }
        await task.value
    }

    /// Creation's background request and its login screen must share the same auth check too.
    private func loadConnection(retryFailed: Bool) async {
        guard hasWorkspace else {
            loadError = t("agentAuth.noWorkspace")
            phase = .unreachable(t("agentAuth.noWorkspace"))
            loadFreshness.finish(success: false, at: now(), revision: loadFreshness.revision)
            loadedDaemonRevision = workCoordinator.probeRevision(daemonKey)
            return
        }
        loadError = nil
        // Show the connecting/preparing UI for anything but an already-ready agent (which
        // revalidates silently). Resetting the phase here is what makes Retry *visibly* re-run
        // instead of appearing to do nothing.
        let showProgress = !(ensured && (phase == .ready || phase == .needsAuth))
        if showProgress {
            phase = .checking
            statusMessage = t("agentAuth.checking")
            preparing = true
        }
        do {
            try await ensure()
            if retryFailed, toolsWork?.error != nil {
                try await workCoordinator.perform(toolsKey, activity: .installingTools) { work in
                    self.preparedInfo = try await AgentInstallation.ensure(transport: self.transport, work: work, retryFailed: true)
                }
            }
        } catch {
            preparing = false
            statusMessage = nil
            loadError = error.localizedDescription
            phase = .unreachable(error.localizedDescription)
            loadFreshness.finish(success: false, at: now(), revision: loadFreshness.revision)
            loadedDaemonRevision = workCoordinator.probeRevision(daemonKey)
            return
        }
        preparing = false
        // ensure() left `activity` at .checking (quiet) — the auth read needs no progress UI.
        await refresh()
        statusMessage = nil
    }

    /// Re-read the daemon's agent props (`/agent` carries methods + status + schema) and settle the
    /// phase. Goes through `call`, so it self-heals a daemon that died since the last load.
    func refresh() async {
        guard hasWorkspace else { return }
        let checkRevision = loadFreshness.revision
        let authRevision = authenticationRevision
        let sharedAuthRevision = workCoordinator.authenticationRevision(for: toolsKey)
        loading = true
        defer { loading = false }
        do {
            let info = try await call { transport in
                if let info = self.preparedInfo {
                    self.preparedInfo = nil
                    return info
                }
                // Reopening a cached session still checks for an install owned by another screen
                // or client. Joining it never starts a second installer or cancels it on dismissal.
                let revision = self.workCoordinator.probeRevision(self.toolsKey)
                let setup = try await transport.setupStatus()
                self.workCoordinator.recordPreparation(setup, for: self.toolsKey, revision: revision)
                if setup.running != true, setup.started == true, !setup.ok {
                    throw BackendError.message(self.toolsWork?.error ?? t("agentAuth.stage.setupFailed"))
                }
                if setup.running == true {
                    var verified: DaemonAgentInfo?
                    try await self.workCoordinator.perform(self.toolsKey) { work in
                        verified = try await AgentInstallation.ensure(transport: transport, work: work, initial: setup)
                    }
                    if let verified { return verified }
                }
                return try await transport.agentInfo()
            }
            var methods: [DaemonAuthMethod] = []
            var authStatus: DaemonAuthStatus?
            if (info.authMethods ?? []).isEmpty {
                methods = (try? await call { try await $0.authMethods() }) ?? []
            }
            if info.authStatus == nil {
                authStatus = (try? await call { try await $0.authStatus() })
                    ?? DaemonAuthStatus(configured: info.configured)
            }
            guard authenticationRevision == authRevision,
                  workCoordinator.authenticationRevision(for: toolsKey) == sharedAuthRevision else { return }
            self.info = info
            fallbackMethods = methods
            fallbackStatus = authStatus
            workCoordinator.recordAgentInfo(info, for: toolsKey)
            if let authentication = info.authStatus ?? authStatus { workCoordinator.recordAuthentication(authentication, for: toolsKey) }
            loadError = nil
        } catch {
            guard authenticationRevision == authRevision,
                  workCoordinator.authenticationRevision(for: toolsKey) == sharedAuthRevision else { return }
            loadError = error.localizedDescription
        }
        loading = false
        settlePhase()
        loadFreshness.finish(success: loadError == nil, at: now(), revision: checkRevision)
        loadedDaemonRevision = workCoordinator.probeRevision(daemonKey)
    }

    /// CLI readiness and authentication are independent. Preserve a previously verified connection
    /// on a transient read failure, but never unlock an agent just because credentials exist.
    private func settlePhase() {
        // A dependency repair deferred for an active turn can run on the next explicit use.
        if info?.software?.needsSetup == true { ensured = false }
        if let info, info.installedVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ensured = false
            loadError = loadError ?? t("agentUpdates.verifyFailed")
            phase = .unreachable(loadError!)
        } else if let status, status.configured {
            phase = .ready
        } else if status != nil {
            phase = .needsAuth
        } else if phase == .ready {
            // tolerate a transient failure for an agent that was ready
        } else {
            phase = .unreachable(loadError ?? t("agentAuth.failed"))
        }
    }

    /// Read the adapter's native configuration. The device does not own a second config store.
    func config() async throws -> [String: String] {
        guard hasWorkspace else { throw BackendError.unreachable("No workspace connected.") }
        return try await call { try await $0.getConfig() }
    }

    /// Push non-secret settings to the daemon (`setConfig`). No-op when unbound.
    func pushConfig(_ config: [String: String]) async {
        guard backend != nil, !config.isEmpty else { return }
        do {
            try await call { try await $0.setConfig(config) }
            configurationRevision += 1
        } catch { }
    }

    /// Save settings and surface daemon validation/transport failures to an editing form.
    func saveConfig(_ config: [String: String]) async throws {
        guard hasWorkspace else { throw BackendError.unreachable("No workspace connected.") }
        try await call { try await $0.setConfig(config) }
        configurationRevision += 1
        await refresh()
    }

    // Native agent resources. Capability flags from /agent decide which controls the console shows;
    // the Go handlers remain the authoritative gate and persistence layer.
    private var cachedModels: [DaemonModelInfo]?
    private var modelsLoadedAt: Date?
    @ObservationIgnored private var configurationRevision = 0
    private struct ModelIdentity: Equatable {
        let revision: Int
        let configuration: Int
        let authentication: DaemonAuthStatus?
        let serviceVersion: String
        let harnessVersion: String
    }
    private var modelIdentity: ModelIdentity {
        .init(revision: authenticationRevision, configuration: configurationRevision, authentication: status,
              serviceVersion: info?.version ?? "",
              harnessVersion: toolsWork?.installedVersion ?? info?.installedVersion ?? "")
    }
    private var cachedModelIdentity: ModelIdentity?
    private struct ModelRead {
        let id = UUID()
        let identity: ModelIdentity
        let task: Task<[DaemonModelInfo], Error>
    }
    private var modelsRead: ModelRead?
    func models(force: Bool = false) async throws -> [DaemonModelInfo] {
        let identity = modelIdentity
        if !force, cachedModelIdentity == identity,
           let at = modelsLoadedAt, now().timeIntervalSince(at) < 300, let cachedModels { return cachedModels }
        let read: ModelRead
        if let pending = modelsRead, pending.identity == identity {
            read = pending
        } else {
            modelsRead?.task.cancel()
            read = ModelRead(identity: identity,
                             task: Task { try await self.call { try await $0.models() } })
            modelsRead = read
        }
        defer { if modelsRead?.id == read.id { modelsRead = nil } }
        let models = try await read.task.value
        guard identity == modelIdentity else { throw CancellationError() }
        cachedModels = models; modelsLoadedAt = now(); cachedModelIdentity = identity
        return models
    }

    private struct CommandRead {
        let id = UUID()
        let identity: ModelIdentity
        let task: Task<DaemonCommandCatalog, Error>
    }
    private struct CachedCommands {
        let identity: ModelIdentity
        let at: Date
        let catalog: DaemonCommandCatalog
    }
    @ObservationIgnored private var commandReads: [String: CommandRead] = [:]
    @ObservationIgnored private var commandCache: [String: CachedCommands] = [:]

    func commands(directory: String?, force: Bool = false) async throws -> DaemonCommandCatalog {
        let key = directory ?? ""
        let identity = modelIdentity
        if !force, let cached = commandCache[key], cached.identity == identity,
           now().timeIntervalSince(cached.at) < (cached.catalog.warning == nil ? 90 : 10) { return cached.catalog }
        let read: CommandRead
        if let pending = commandReads[key], pending.identity == identity { read = pending }
        else {
            commandReads[key]?.task.cancel()
            read = CommandRead(identity: identity, task: Task { try await self.call { try await $0.commands(directory: directory, refresh: force) } })
            commandReads[key] = read
        }
        defer { if commandReads[key]?.id == read.id { commandReads[key] = nil } }
        let catalog = try await read.task.value
        guard identity == modelIdentity else { throw CancellationError() }
        if commandCache.count >= 24, let oldest = commandCache.min(by: { $0.value.at < $1.value.at })?.key { commandCache[oldest] = nil }
        commandCache[key] = CachedCommands(identity: identity, at: now(), catalog: catalog)
        return catalog
    }

    func compactChat(chatId: String, instructions: String, requestId: String) async throws -> DaemonRun {
        try await call(retryOnConnectionFailure: capabilities?.commands == true) {
            try await $0.compactChat(chatId: chatId, instructions: instructions, requestId: requestId)
        }
    }
    func memory(directory: String? = nil) async throws -> [DaemonMemoryDocument] {
        try await call { try await $0.memory(directory: directory) }
    }
    func saveMemory(scope: DaemonResourceScope, directory: String? = nil, content: String) async throws -> DaemonMemoryDocument {
        try await call { try await $0.setMemory(scope: scope, directory: directory, content: content) }
    }
    func deleteMemory(scope: DaemonResourceScope, directory: String? = nil) async throws {
        try await call { try await $0.deleteMemory(scope: scope, directory: directory) }
    }
    func prompts(directory: String? = nil) async throws -> [DaemonPromptTemplate] {
        try await call { try await $0.prompts(directory: directory) }
    }
    func prompt(name: String, scope: DaemonResourceScope, directory: String? = nil) async throws -> DaemonPromptTemplate {
        try await call { try await $0.prompt(name: name, scope: scope, directory: directory) }
    }
    func savePrompt(name: String, scope: DaemonResourceScope, directory: String? = nil, content: String) async throws -> DaemonPromptTemplate {
        try await call { try await $0.setPrompt(name: name, scope: scope, directory: directory, content: content) }
    }
    func deletePrompt(name: String, scope: DaemonResourceScope, directory: String? = nil) async throws {
        try await call { try await $0.deletePrompt(name: name, scope: scope, directory: directory) }
    }
    func subagents(directory: String? = nil) async throws -> [DaemonSubagent] {
        try await call { try await $0.subagents(directory: directory) }
    }
    func subagent(name: String, scope: DaemonResourceScope, directory: String? = nil) async throws -> DaemonSubagent {
        try await call { try await $0.subagent(name: name, scope: scope, directory: directory) }
    }
    func saveSubagent(name: String, scope: DaemonResourceScope, directory: String? = nil, content: String) async throws -> DaemonSubagent {
        try await call { try await $0.setSubagent(name: name, scope: scope, directory: directory, content: content) }
    }
    func deleteSubagent(name: String, scope: DaemonResourceScope, directory: String? = nil) async throws {
        try await call { try await $0.deleteSubagent(name: name, scope: scope, directory: directory) }
    }
    func mcpServers(directory: String? = nil) async throws -> [DaemonResourceScope: [String: DaemonMCPServer]] {
        try await call { try await $0.mcpServers(directory: directory) }
    }
    func saveMCPServer(name: String, scope: DaemonResourceScope, directory: String? = nil, server: DaemonMCPServer) async throws -> DaemonMCPServer {
        try await call { try await $0.setMCPServer(name: name, scope: scope, directory: directory, server: server) }
    }
    func deleteMCPServer(name: String, scope: DaemonResourceScope, directory: String? = nil) async throws {
        try await call { try await $0.deleteMCPServer(name: name, scope: scope, directory: directory) }
    }
    func providers(directory: String? = nil) async throws -> [DaemonResourceScope: [String: DaemonCustomProvider]] {
        try await call { try await $0.providers(directory: directory) }
    }
    func saveProvider(id: String, scope: DaemonResourceScope, directory: String? = nil,
                      provider: DaemonCustomProvider, apiKey: String? = nil) async throws -> DaemonCustomProvider {
        try await call { try await $0.setProvider(id: id, scope: scope, directory: directory,
                                                  provider: provider, apiKey: apiKey) }
    }
    func deleteProvider(id: String, scope: DaemonResourceScope, directory: String? = nil) async throws {
        try await call { try await $0.deleteProvider(id: id, scope: scope, directory: directory) }
    }

    // MARK: - Field method (e.g. apiKey)

    func submit(method: DaemonAuthMethod, values: [String: String]) async -> Bool {
        guard !signingOut else { return false }
        authenticationRevision += 1
        working = true
        connectError = nil
        activeMethod = method.id
        defer { working = false; activeMethod = nil }
        do {
            let state = try await call { transport in
                if method.fields.isEmpty { return try await transport.authBegin(method.id) }
                return try await transport.authStep(values)
            }
            guard state.status == "complete" else {
                connectError = state.message ?? t("agentAuth.failed")
                return false
            }
            await refresh()
            if let loadError {
                connectError = loadError
                return false
            }
            guard isConfigured else {
                connectError = status?.detail ?? t("agentAuth.failed")
                return false
            }
            return true
        } catch {
            connectError = error.localizedDescription
            return false
        }
    }

    // MARK: - Interactive method (e.g. login)

    func startInteractive(_ method: DaemonAuthMethod) async {
        guard !signingOut else { return }
        authenticationRevision += 1
        cancelInteractive()
        let attemptID = UUID()
        interactiveAttemptID = attemptID
        working = true
        connectError = nil
        activeMethod = method.id
        loginURL = nil; loginCallbackURL = nil; loginCode = nil; loginMessage = nil
        await authCancelTask?.value
        guard interactiveAttemptID == attemptID else { return }
        guard !Task.isCancelled else { cancelInteractive(); return }
        do {
            let state = try await call { try await $0.authBegin(method.id) }
            guard interactiveAttemptID == attemptID else {
                // A dismissed sheet may still have had /begin in flight. Never
                // leave that native login running after its response arrives.
                if interactiveAttemptID == nil { cancelRemoteLogin(state.flowId) }
                return
            }
            guard !Task.isCancelled else {
                cancelRemoteLogin(state.flowId)
                cancelInteractive()
                return
            }
            apply(state)
            if state.status == "complete" || state.status == "error" {
                await finishInteractive(state, attemptID: attemptID)
                return
            }
            poll(attemptID: attemptID)
        } catch {
            guard interactiveAttemptID == attemptID else { return }
            guard !Task.isCancelled else { cancelInteractive(); return }
            connectError = error.localizedDescription
            working = false
            activeMethod = nil
            interactiveAttemptID = nil
        }
    }

    private func poll(attemptID: UUID) {
        pollTask = Task { [weak self] in
            guard let self else { return }
            let expiresAt = Date().addingTimeInterval(11 * 60)
            var failures = 0
            // Native login expires after 10 minutes. Let the service report that
            // expiry instead of abandoning a valid browser flow at five minutes.
            while true {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                do {
                    // Direct transport (not `call`): the daemon is up during an active login; a
                    // re-ensure here would restart it and drop the in-flight flow.
                    let revision = self.interactiveInputRevision
                    let state = try await self.transport.authStep(self.loginInput())
                    guard self.interactiveAttemptID == attemptID, !Task.isCancelled else { return }
                    failures = 0
                    self.connectError = nil
                    guard revision == self.interactiveInputRevision, !self.loginSubmitting else { continue }
                    self.apply(state)
                    if state.status == "complete" || state.status == "error" {
                        await self.finishInteractive(state, attemptID: attemptID)
                        return
                    }
                } catch {
                    guard self.interactiveAttemptID == attemptID, !Task.isCancelled else { return }
                    failures += 1
                    if failures >= 3 { self.connectError = t("agentAuth.reconnecting") }
                }
                if Date() >= expiresAt { break }
            }
            self.cancelInteractive()
            self.connectError = t("agentAuth.failed")
        }
    }

    func signOut() async throws {
        guard !signingOut else { return }
        guard capabilities?.authLogout == true else { throw BackendError.message(t("agentAuth.logout.updateRequired")) }
        signingOut = true
        authenticationRevision += 1
        defer { signingOut = false }
        cancelInteractive()
        await authCancelTask?.value
        let status = try await call { try await $0.authLogout() }
        guard !status.configured else { throw BackendError.message(t("agentAuth.logout.failed")) }
        authenticationRevision += 1
        info?.authStatus = status
        info?.configured = false
        fallbackStatus = status
        workCoordinator.recordAuthentication(status, for: toolsKey)
        loadError = nil
        loadFreshness.invalidate()
        settlePhase()
        if let methods = try? await transport.authMethods() {
            info?.authMethods = methods
            fallbackMethods = methods
        }
    }

    /// Browser/code handoffs use the same declared fields as API-key forms.
    func submitInteractive(values: [String: String]) async -> Bool {
        guard let attemptID = interactiveAttemptID, !loginSubmitting,
              !loginFields.isEmpty, loginForm.firstInvalidField(values) == nil else { return false }
        loginSubmitting = true
        interactiveInputRevision += 1
        connectError = nil
        var input = loginForm.submissionValues(values)
        input.merge(loginInput()) { _, flowValue in flowValue }
        do {
            let state = try await transport.authStep(input)
            guard interactiveAttemptID == attemptID else { return false }
            loginSubmitting = false
            interactiveInputRevision += 1
            apply(state)
            if state.status == "complete" || state.status == "error" {
                await finishInteractive(state, attemptID: attemptID)
            }
            return state.status != "error" && connectError == nil
        } catch {
            guard interactiveAttemptID == attemptID else { return false }
            loginSubmitting = false
            interactiveInputRevision += 1
            connectError = error.localizedDescription
            return false
        }
    }

    private func loginInput() -> [String: String] {
        if let loginFlowID { return ["_flowId": loginFlowID] }
        return [:] // older services still accept unscoped polls
    }

    /// A native browser callback rides the same authenticated transport as the
    /// rest of this login. Its destination is validated inside the daemon.
    func deliverLoginCallback(_ url: URL) async throws {
        guard let attemptID = interactiveAttemptID, let flowID = loginFlowID, working,
              loginCallbackURL != nil else { throw CancellationError() }
        interactiveInputRevision += 1
        let state = try await transport.authStep(["_flowId": flowID, "_callbackUrl": url.absoluteString])
        guard interactiveAttemptID == attemptID else { throw CancellationError() }
        interactiveInputRevision += 1
        apply(state)
        if state.status == "complete" || state.status == "error" {
            await finishInteractive(state, attemptID: attemptID)
        }
        if state.status == "error" { throw BackendError.message(t("agentAuth.failed")) }
    }

    private func apply(_ state: DaemonAuthState) {
        if let flowID = state.flowId { loginFlowID = flowID }
        if let url = state.url, !url.isEmpty { loginURL = url }
        loginCallbackURL = state.callbackUrl
        if let code = state.code, !code.isEmpty { loginCode = code }
        if let msg = state.message, !msg.isEmpty { loginMessage = msg }
        loginFields = state.fields
        loginSections = state.sections
    }

    private func finishInteractive(_ state: DaemonAuthState, attemptID: UUID) async {
        guard interactiveAttemptID == attemptID, finishingInteractiveAttemptID != attemptID else { return }
        finishingInteractiveAttemptID = attemptID
        defer { if finishingInteractiveAttemptID == attemptID { finishingInteractiveAttemptID = nil } }
        // Close Safari as soon as native completion arrives; refreshing account
        // metadata must not leave a finished browser session on screen.
        working = false
        if state.status == "complete" { await refresh() }
        guard interactiveAttemptID == attemptID else { return }
        working = false
        activeMethod = nil
        interactiveAttemptID = nil
        loginFlowID = nil
        loginFields = []; loginSections = []; loginSubmitting = false
        loginURL = nil; loginCallbackURL = nil; loginCode = nil
        if state.status == "error" {
            connectError = state.message ?? t("agentAuth.failed")
        } else if let loadError {
            connectError = loadError
        } else if !isConfigured {
            connectError = status?.detail ?? t("agentAuth.failed")
        } else {
            completedAuthMethod = state.method
        }
    }

    func cancelInteractive(notifyRemote: Bool = true) {
        if notifyRemote { cancelRemoteLogin(loginFlowID) }
        pollTask?.cancel()
        pollTask = nil
        interactiveAttemptID = nil
        finishingInteractiveAttemptID = nil
        loginFlowID = nil
        loginFields = []; loginSections = []; loginSubmitting = false
        interactiveInputRevision += 1
        completedAuthMethod = nil
        working = false
        activeMethod = nil
        loginURL = nil; loginCallbackURL = nil; loginCode = nil; loginMessage = nil
    }

    private func cancelRemoteLogin(_ flowID: String?) {
        guard let flowID, !flowID.isEmpty else { return }
        let previous = authCancelTask
        let transport = transport
        authCancelTask = Task {
            await previous?.value
            _ = try? await transport.authStep(["_flowId": flowID, "_action": "cancel"])
        }
    }
}

/// Registry of live `DaemonSession`s, one per agent, so every screen (detail, settings, connect
/// gate, chat) shares the same daemon connection + cached ensure for a given agent.
@MainActor
final class DaemonManager {
    static let shared = DaemonManager()
    private var sessions: [String: DaemonSession] = [:]
    private var notificationReconciliation: Task<Void, Never>?
    private var notificationRepairRevision = 0

    func reconcileNotifications(force: Bool = false) async {
        if force { notificationRepairRevision &+= 1 }
        if let notificationReconciliation { await notificationReconciliation.value; return }
        let task = Task {
            var forced = force
            repeat {
                let revision = self.notificationRepairRevision
                let account = MindwireAuth.shared.user?.id
                for session in Array(self.sessions.values) { await session.reconcileNotifications(force: forced) }
                if revision == self.notificationRepairRevision, account == MindwireAuth.shared.user?.id { return }
                forced = true // A registration/account change crossed the previous configuration.
            } while !Task.isCancelled
        }
        notificationReconciliation = task
        await task.value
        notificationReconciliation = nil
    }

    /// The shared session for an agent, created + bound on first use.
    func session(for agentId: String, stores: Stores) -> DaemonSession {
        let context = stores.agents.get(agentId)?.workspaceId
            .flatMap { WorkspaceRepository.shared.get($0) }
            .map { WorkspaceConnectionContext($0, stores: stores) }
        if let existing = sessions[agentId], existing.connectionContext == context {
            if !existing.hasWorkspace { existing.bind(stores: stores) }
            return existing
        }
        sessions[agentId]?.cancelInteractive()
        let session = DaemonSession(agentId: agentId)
        session.bind(stores: stores)
        sessions[agentId] = session
        return session
    }

    /// Forget an agent's session (e.g. on delete) so its transport/daemon state isn't retained.
    func discard(_ agentId: String, notifyRemote: Bool = true) {
        sessions[agentId]?.cancelInteractive(notifyRemote: notifyRemote)
        sessions[agentId] = nil
    }
}
