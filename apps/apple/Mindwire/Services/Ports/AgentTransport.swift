import Foundation

/// Uniform daemon exec surface (over curl-exec for cloud, direct HTTP for self-host).
protocol AgentTransport: AnyObject {
    func nativeActivity(chatId: String) async throws -> NativeSessionActivity?
    func nativeEvents(chatId: String, cursor: String?) -> AsyncThrowingStream<NativeSessionFrame, Error>?
    func nativeAction(chatId: String, action: NativeSessionAction) async throws -> NativeSessionReceipt
    func voiceStatus() async throws -> HarnessVoiceStatus
    func startVoice(chatId: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String, clientId: String, voice: String?) async throws -> DaemonRun
    func voiceControl(runId: String, clientId: String, action: String, sequence: Int?, audio: HarnessVoiceAudio?) async throws
    func voiceEvents(runId: String, clientId: String) -> AsyncThrowingStream<HarnessVoiceEvent, Error>?
    func health() async -> DaemonHealth
    func requireIdleForDaemonUpdate(health: DaemonHealth) async throws
    func catalog() async throws -> DaemonCatalog
    func agentInfo() async throws -> DaemonAgentInfo
    func uploadAttachment(chatId: String, attachment: DaemonAttachment, progress: (@MainActor @Sendable (Double) -> Void)?) async throws -> DaemonAttachment
    func attachmentData(_ id: String) async throws -> Data
    func software(refresh: Bool) async throws -> DaemonHarnessSoftware?
    /// `cwd` runs the turn in a specific dir (a project/agent workdir); `nil` = the daemon default.
    func sendTurn(chatId: String, message: String, cwd: String?) async throws -> DaemonRun
    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?) async throws -> DaemonRun
    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String?) async throws -> DaemonRun
    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String?, attachments: [DaemonAttachment]) async throws -> DaemonRun
    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String?, attachments: [DaemonAttachment], queueIfRunning: Bool) async throws -> DaemonRun
    func projectGitState(_ projectId: String) async throws -> ProjectGitState
    func getRun(_ runId: String) async throws -> DaemonRun
    func runSnapshot(_ runId: String) async throws -> DaemonRunSnapshot?
    func cancelRun(_ runId: String) async throws
    func respondToRun(_ runId: String, interactionId: String, reply: DaemonInteractionReply) async throws
    func respondToRun(_ runId: String, interactionId: String, reply: DaemonInteractionReply, gitAuth: ProjectCloneAuth?) async throws
    func setPermissionMode(_ runId: String, mode: String) async throws
    /// Live SSE of a run's unified events; nil when the channel can't stream (curl/ssh) → caller polls.
    func streamRun(_ runId: String, after: Int?) -> AsyncThrowingStream<DaemonEvent, Error>?
    /// The chat's latest run (`GET /chats/{id}/run`) — the reattach anchor on reopen. nil = no runs yet.
    func chatRun(chatId: String) async throws -> DaemonRun?
    /// The daemon's native session summaries. Navigation links are synced by WorkspaceDataRepository.
    func listChats() async throws -> [DaemonChatSummary]
    func renameChat(chatId: String, title: String) async throws -> DaemonChatSummary
    func previewHandoff(chatId: String) async throws -> DaemonHandoffPreview
    func handoff(chatId: String, request: ChatHandoffRequest) async throws -> DaemonHandoffResult
    func forkChat(chatId: String, newChatId: String, beforeMessageId: String) async throws -> DaemonChatFork
    func deleteChat(chatId: String) async throws
    func listMessages(chatId: String, limit: Int?, before: String?) async throws -> [DaemonMessage]
    func messagePage(chatId: String, limit: Int, before: String?, maxBytes: Int) async throws -> DaemonMessagePage
    func messagePage(chatId: String, limit: Int, before: String?, maxBytes: Int, ifRevision: String?) async throws -> DaemonMessagePage
    func getConfig() async throws -> [String: String]
    func setConfig(_ config: [String: String]) async throws
    func models() async throws -> [DaemonModelInfo]
    func commands(directory: String?, refresh: Bool) async throws -> DaemonCommandCatalog
    func compactChat(chatId: String, instructions: String, requestId: String) async throws -> DaemonRun
    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String?, attachments: [DaemonAttachment], queueIfRunning: Bool, command: DaemonCommandInvocation?) async throws -> DaemonRun
    func memory(directory: String?) async throws -> [DaemonMemoryDocument]
    func setMemory(scope: DaemonResourceScope, directory: String?, content: String) async throws -> DaemonMemoryDocument
    func deleteMemory(scope: DaemonResourceScope, directory: String?) async throws
    func prompts(directory: String?) async throws -> [DaemonPromptTemplate]
    func prompt(name: String, scope: DaemonResourceScope, directory: String?) async throws -> DaemonPromptTemplate
    func setPrompt(name: String, scope: DaemonResourceScope, directory: String?, content: String) async throws -> DaemonPromptTemplate
    func deletePrompt(name: String, scope: DaemonResourceScope, directory: String?) async throws
    func subagents(directory: String?) async throws -> [DaemonSubagent]
    func subagent(name: String, scope: DaemonResourceScope, directory: String?) async throws -> DaemonSubagent
    func setSubagent(name: String, scope: DaemonResourceScope, directory: String?, content: String) async throws -> DaemonSubagent
    func deleteSubagent(name: String, scope: DaemonResourceScope, directory: String?) async throws
    func mcpServers(directory: String?) async throws -> [DaemonResourceScope: [String: DaemonMCPServer]]
    func setMCPServer(name: String, scope: DaemonResourceScope, directory: String?, server: DaemonMCPServer) async throws -> DaemonMCPServer
    func deleteMCPServer(name: String, scope: DaemonResourceScope, directory: String?) async throws
    func providers(directory: String?) async throws -> [DaemonResourceScope: [String: DaemonCustomProvider]]
    func setProvider(id: String, scope: DaemonResourceScope, directory: String?, provider: DaemonCustomProvider, apiKey: String?) async throws -> DaemonCustomProvider
    func deleteProvider(id: String, scope: DaemonResourceScope, directory: String?) async throws
    func setNotifyConfig(url: String, channel: String, token: String) async throws
    /// Kick off the agent's toolchain install (async on the daemon) — returns immediately with
    /// `running: true`; the daemon runs the steps in the background so the request can't time out
    /// through the proxy. Poll `setupStatus()` for progress + completion.
    func setup() async throws -> DaemonSetupResult
    func update() async throws -> DaemonSetupResult
    /// Current toolchain install state (running/ok/steps) — polled after `setup()` until done.
    func setupStatus() async throws -> DaemonSetupResult

    // Auth — a generic methods → begin → step → status flow. The agent's daemon adapter owns the
    // specifics and persists credentials in the workspace (never in the client).
    func authMethods() async throws -> [DaemonAuthMethod]
    func authBegin(_ method: String) async throws -> DaemonAuthState
    func authStep(_ input: [String: String]) async throws -> DaemonAuthState
    func authStatus() async throws -> DaemonAuthStatus
    func authLogout() async throws -> DaemonAuthStatus
}

extension AgentTransport {
    func nativeActivity(chatId: String) async throws -> NativeSessionActivity? { nil }
    func nativeEvents(chatId: String, cursor: String?) -> AsyncThrowingStream<NativeSessionFrame, Error>? { nil }
    func nativeAction(chatId: String, action: NativeSessionAction) async throws -> NativeSessionReceipt {
        throw BackendError.message("Update Mindwire to control a conversation running in its terminal.")
    }
    func commands(directory: String?, refresh: Bool) async throws -> DaemonCommandCatalog {
        throw BackendError.message("Update the Mindwire service to browse native commands.")
    }
    func compactChat(chatId: String, instructions: String, requestId: String) async throws -> DaemonRun {
        throw BackendError.message("Update the Mindwire service to compact this conversation.")
    }
    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String?, attachments: [DaemonAttachment], queueIfRunning: Bool, command: DaemonCommandInvocation?) async throws -> DaemonRun {
        guard command == nil else { throw BackendError.message("Update the Mindwire service to run native commands.") }
        return try await sendTurn(chatId: chatId, message: message, cwd: cwd, gitAuth: gitAuth, requestId: requestId, attachments: attachments, queueIfRunning: queueIfRunning)
    }
    func voiceStatus() async throws -> HarnessVoiceStatus { throw BackendError.message(t("chat.voice.native.updateRequired")) }
    func startVoice(chatId: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String, clientId: String, voice: String?) async throws -> DaemonRun {
        throw BackendError.message(t("chat.voice.native.updateRequired"))
    }
    func voiceControl(runId: String, clientId: String, action: String, sequence: Int?, audio: HarnessVoiceAudio?) async throws {
        throw BackendError.message(t("chat.voice.native.updateRequired"))
    }
    func voiceEvents(runId: String, clientId: String) -> AsyncThrowingStream<HarnessVoiceEvent, Error>? { nil }
    func messagePage(chatId: String, limit: Int, before: String?, maxBytes: Int, ifRevision: String?) async throws -> DaemonMessagePage {
        try await messagePage(chatId: chatId, limit: limit, before: before, maxBytes: maxBytes)
    }
    func uploadAttachment(chatId: String, attachment: DaemonAttachment, progress: (@MainActor @Sendable (Double) -> Void)?) async throws -> DaemonAttachment {
        throw BackendError.message("Update the Mindwire service to attach files.")
    }
    func attachmentData(_ id: String) async throws -> Data {
        throw BackendError.message("Reconnect to the workspace to open this attachment.")
    }
    func previewHandoff(chatId: String) async throws -> DaemonHandoffPreview {
        throw BackendError.message(t("chat.handoff.updateRequired"))
    }
    func handoff(chatId: String, request: ChatHandoffRequest) async throws -> DaemonHandoffResult {
        throw BackendError.message(t("chat.handoff.updateRequired"))
    }
    func forkChat(chatId: String, newChatId: String, beforeMessageId: String) async throws -> DaemonChatFork {
        throw BackendError.message(t("chat.fork.updateRequired"))
    }
    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String?, attachments: [DaemonAttachment]) async throws -> DaemonRun {
        guard attachments.isEmpty else { throw BackendError.message("Update Mindwire to send images on this connection.") }
        return try await sendTurn(chatId: chatId, message: message, cwd: cwd, gitAuth: gitAuth, requestId: requestId)
    }
    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String?, attachments: [DaemonAttachment], queueIfRunning: Bool) async throws -> DaemonRun {
        guard !queueIfRunning else { throw BackendError.message(t("chat.queue.updateRequired")) }
        return try await sendTurn(chatId: chatId, message: message, cwd: cwd, gitAuth: gitAuth, requestId: requestId, attachments: attachments)
    }
    func messagePage(chatId: String, limit: Int, before: String?, maxBytes: Int) async throws -> DaemonMessagePage {
        let messages = try await listMessages(chatId: chatId, limit: limit, before: before)
        return DaemonMessagePage(messages: messages, hasMore: messages.count == limit,
                                 before: messages.first?.id)
    }
    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String?) async throws -> DaemonRun {
        // A legacy/mock transport cannot claim receipt support by ignoring the ID.
        guard requestId == nil else { throw BackendError.message("Update Mindwire to safely retry this message.") }
        return try await sendTurn(chatId: chatId, message: message, cwd: cwd, gitAuth: gitAuth)
    }
    func authLogout() async throws -> DaemonAuthStatus { throw BackendError.message(t("agentAuth.logout.updateRequired")) }
    func projectGitState(_ projectId: String) async throws -> ProjectGitState { throw WorkspaceRegistryError.gitAccessUnavailable }
    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?) async throws -> DaemonRun {
        guard gitAuth == nil else { throw WorkspaceRegistryError.gitAccessUnavailable }
        return try await sendTurn(chatId: chatId, message: message, cwd: cwd)
    }
    func respondToRun(_ runId: String, interactionId: String, reply: DaemonInteractionReply, gitAuth: ProjectCloneAuth?) async throws {
        guard gitAuth == nil else { throw WorkspaceRegistryError.gitAccessUnavailable }
        try await respondToRun(runId, interactionId: interactionId, reply: reply)
    }
    func software(refresh: Bool) async throws -> DaemonHarnessSoftware? { try await agentInfo().software }
    func requireIdleForDaemonUpdate(health: DaemonHealth) async throws {
        throw BackendError.message(t("workspace.daemon.unreachable"))
    }
    // Older daemons/transports still restore through a buffered replay.
    func runSnapshot(_ runId: String) async throws -> DaemonRunSnapshot? { nil }
    func update() async throws -> DaemonSetupResult { throw BackendError.message("Agent updates are unavailable on this connection.") }
}
