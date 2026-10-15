import Foundation
import CryptoKit

/// `AgentTransport` over the in-workspace Mindwire runtime (`mindwired` on 127.0.0.1:8790). Transport-
/// agnostic: it maps each daemon endpoint to a `DaemonHTTP` call, which rides a pluggable
/// `DaemonChannel` — Oblien proxy (cloud), SSH direct-tcpip tunnel (self-hosted), or exec fallback.
/// `BackendFactory.transport(forBackend:)` picks the channel.
final class ExecDaemonTransport: AgentTransport {
    private let http: DaemonHTTP

    /// Curl-over-exec universal fallback. `agentType` scopes every call to that
    /// agent on the shared per-workspace daemon.
    convenience init(workspace: WorkspaceService, agentType: String,
                     port: Int = AppConstants.daemonPort, daemonToken: String? = nil) {
        self.init(channel: CurlExecChannel(workspace: workspace, port: port, token: daemonToken), agentType: agentType)
    }

    /// Any channel (e.g. `SSHTunnelChannel` for a self-hosted VPS), scoped to `agentType`.
    init(channel: DaemonChannel, agentType: String) {
        self.http = DaemonHTTP(channel: channel, agentType: agentType)
    }

    func health() async -> DaemonHealth {
        do { return try await http.decode("GET", "/healthz") }
        catch { return DaemonHealth(ok: false, agent: nil, version: nil) }
    }

    func catalog() async throws -> DaemonCatalog { try await http.decode("GET", "/catalog") }

    func requireIdleForDaemonUpdate(health: DaemonHealth) async throws {
        try await DaemonUpdateGuard.requireIdle(http: DaemonHTTP(channel: http.channel, agentType: ""), health: health)
    }

    func agentInfo() async throws -> DaemonAgentInfo { try await http.decode("GET", "/agent") }

    func nativeActivity(chatId: String) async throws -> NativeSessionActivity? {
        do { return try await http.decode("GET", "/chats/\(http.enc(chatId))/native", quiet: true) }
        catch let error as DaemonHTTPError where error.status == 404 || error.status == 405 || error.code == "native_session_invalid" || error.code == "native_fork_pending" {
            return nil // Older service, new draft, or an unstarted fork.
        }
    }

    func nativeEvents(chatId: String, cursor: String?) -> AsyncThrowingStream<NativeSessionFrame, Error>? {
        let query = cursor.map { "?cursor=\(http.encQuery($0))" } ?? ""
        return http.decodedStream("/chats/\(http.enc(chatId))/native/events\(query)")
    }

    func nativeAction(chatId: String, action: NativeSessionAction) async throws -> NativeSessionReceipt {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(action))
        return try await http.decode("POST", "/chats/\(http.enc(chatId))/native/actions", json: body)
    }

    func voiceStatus() async throws -> HarnessVoiceStatus {
        guard http.channel is StreamingDaemonChannel else {
            throw BackendError.message(t("chat.voice.native.streamingRequired"))
        }
        do { return try await http.decode("GET", "/voice") }
        catch let error as DaemonHTTPError where error.status == 404 || error.status == 405 {
            throw BackendError.message(t("chat.voice.native.updateRequired"))
        }
    }

    func startVoice(chatId: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String, clientId: String, voice: String?) async throws -> DaemonRun {
        var options: [String: Any] = ["clientId": clientId]
        if let voice, !voice.isEmpty { options["voice"] = voice }
        var body: [String: Any] = ["chatId": chatId, "message": "", "requestId": requestId, "options": ["voice": options]]
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        if let gitAuth { body["gitAuth"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gitAuth)) }
        return try await http.decode("POST", "/turns", json: body)
    }

    func voiceControl(runId: String, clientId: String, action: String, sequence: Int?, audio: HarnessVoiceAudio?) async throws {
        var body: [String: Any] = ["clientId": clientId, "action": action]
        if let sequence { body["sequence"] = sequence }
        if let audio { body["audio"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(audio)) }
        _ = try await http.run("POST", "/runs/\(http.enc(runId))/voice", json: body, quiet: true)
    }

    func voiceEvents(runId: String, clientId: String) -> AsyncThrowingStream<HarnessVoiceEvent, Error>? {
        guard let channel = http.channel as? StreamingDaemonChannel else { return nil }
        let path = http.scoped("/runs/\(http.enc(runId))/voice/stream?clientId=\(http.encQuery(clientId))")
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(24)) { continuation in
            let task = Task {
                do {
                    for try await data in try await channel.stream(method: "GET", path: path, jsonBody: nil) {
                        try Task.checkCancellation()
                        let event = try JSONDecoder().decode(HarnessVoiceEvent.self, from: data)
                        if case .dropped = continuation.yield(event) {
                            throw BackendError.message(t("chat.voice.native.tooSlow"))
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func attachmentData(_ id: String) async throws -> Data {
        struct Content: Decodable { let data: Data }
        let content: Content = try await http.decode("GET", "/artifacts/\(http.enc(id))")
        guard content.data.count <= ChatImageDraft.maximumFileBytes else { throw BackendError.message("This attachment is too large to open.") }
        return content.data
    }

    func uploadAttachment(chatId: String, attachment: DaemonAttachment, progress: (@MainActor @Sendable (Double) -> Void)?) async throws -> DaemonAttachment {
        struct State: Decodable {
            let id: String, name: String, mime: String
            let bytes: Int, offset: Int
            let complete: Bool
        }
        let bytes: Data
        if let data = attachment.data { bytes = data }
        else if let id = attachment.artifactId { bytes = try await attachmentData(id) }
        else { return attachment } // Existing native workspace path.
        guard bytes.count <= ChatImageDraft.maximumFileBytes else { throw BackendError.message("Choose files up to 16 MB each.") }
        let name = attachment.name ?? (attachment.isImage ? "Photo.jpg" : "Attachment")
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let identity = Data((chatId + "\0" + name + "\0" + digest).utf8)
        let id = SHA256.hash(data: identity).prefix(16).map { String(format: "%02x", $0) }.joined()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let end = min(bytes.count, offset + 384 * 1_024)
            let state: State = try await http.decode("PUT", "/chats/\(http.enc(chatId))/attachments/\(id)", json: [
                "name": name, "mime": attachment.mime ?? "application/octet-stream", "bytes": bytes.count,
                "sha256": digest, "offset": offset, "data": bytes.subdata(in: offset..<end).base64EncodedString()
            ])
            guard state.id == id, state.bytes == bytes.count, state.offset <= bytes.count,
                  state.offset >= end, !state.complete || state.offset == bytes.count,
                  state.complete || state.offset > offset else {
                throw BackendError.message("The attachment upload didn't complete. Try sending it again.")
            }
            await progress?(bytes.isEmpty ? 1 : Double(state.offset) / Double(bytes.count))
            if state.complete {
                return DaemonAttachment(artifactId: state.id, bytes: state.bytes, name: state.name, mime: state.mime)
            }
            offset = state.offset
        }
    }

    func sendTurn(chatId: String, message: String, cwd: String?) async throws -> DaemonRun {
        try await sendTurn(chatId: chatId, message: message, cwd: cwd, gitAuth: nil)
    }

    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?) async throws -> DaemonRun {
        try await sendTurn(chatId: chatId, message: message, cwd: cwd, gitAuth: gitAuth, requestId: nil)
    }

    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String?) async throws -> DaemonRun {
        try await sendTurn(chatId: chatId, message: message, cwd: cwd, gitAuth: gitAuth, requestId: requestId, attachments: [])
    }

    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String?, attachments: [DaemonAttachment]) async throws -> DaemonRun {
        try await sendTurn(chatId: chatId, message: message, cwd: cwd, gitAuth: gitAuth, requestId: requestId, attachments: attachments, queueIfRunning: false)
    }

    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String?, attachments: [DaemonAttachment], queueIfRunning: Bool) async throws -> DaemonRun {
        try await sendTurn(chatId: chatId, message: message, cwd: cwd, gitAuth: gitAuth, requestId: requestId, attachments: attachments, queueIfRunning: queueIfRunning, command: nil)
    }

    func sendTurn(chatId: String, message: String, cwd: String?, gitAuth: ProjectCloneAuth?, requestId: String?, attachments: [DaemonAttachment], queueIfRunning: Bool, command: DaemonCommandInvocation?) async throws -> DaemonRun {
        var body: [String: Any] = ["chatId": chatId, "message": message]
        if queueIfRunning { body["queueIfRunning"] = true }
        if let requestId { body["requestId"] = requestId }
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        if let gitAuth { body["gitAuth"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gitAuth)) }
        var options: [String: Any] = [:]
        if let command { options["command"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) }
        if !attachments.isEmpty { options["attachments"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(attachments)) }
        if !options.isEmpty {
            body["options"] = options
            guard try JSONSerialization.data(withJSONObject: body).count <= 1_024 * 1_024 else {
                throw BackendError.message("This message is too large. Remove an attachment or shorten the text and try again.")
            }
        }
        return try await http.decode("POST", "/turns", json: body)
    }

    func projectGitState(_ projectId: String) async throws -> ProjectGitState {
        try await http.decode("GET", "/workspace/projects/\(http.encQuery(projectId))/git")
    }

    func getRun(_ runId: String) async throws -> DaemonRun {
        try await http.decode("GET", "/runs/\(http.enc(runId))")
    }

    func runSnapshot(_ runId: String) async throws -> DaemonRunSnapshot? {
        let body = try await http.run("GET", "/runs/\(http.enc(runId))/snapshot", json: nil, missingIsEmpty: true)
        guard !body.isEmpty else { return nil }
        return try JSONDecoder().decode(DaemonRunSnapshot.self, from: Data(body.utf8))
    }

    func cancelRun(_ runId: String) async throws {
        _ = try await http.run("POST", "/runs/\(http.enc(runId))/cancel", json: nil)
    }

    func respondToRun(_ runId: String, interactionId: String, reply: DaemonInteractionReply) async throws {
        try await respondToRun(runId, interactionId: interactionId, reply: reply, gitAuth: nil)
    }

    func respondToRun(_ runId: String, interactionId: String, reply: DaemonInteractionReply, gitAuth: ProjectCloneAuth?) async throws {
        guard var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any] else {
            throw BackendError.message("Could not encode the interaction response.")
        }
        body["interactionId"] = interactionId
        if let gitAuth { body["gitAuth"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gitAuth)) }
        _ = try await http.run("POST", "/runs/\(http.enc(runId))/respond", json: body)
    }

    func setPermissionMode(_ runId: String, mode: String) async throws {
        _ = try await http.run("POST", "/runs/\(http.enc(runId))/set-permission-mode", json: ["mode": mode])
    }

    func streamRun(_ runId: String, after: Int? = nil) -> AsyncThrowingStream<DaemonEvent, Error>? {
        let cursor = after.map { "?after=\($0)" } ?? ""
        return http.stream("/runs/\(http.enc(runId))/stream\(cursor)")
    }

    func chatRun(chatId: String) async throws -> DaemonRun? {
        // GET /chats/{id}/run → 204 (empty body) when the chat has no runs yet.
        let body = try await http.run("GET", "/chats/\(http.enc(chatId))/run", json: nil)
        guard let data = body.data(using: .utf8), !body.isEmpty else { return nil }
        return try JSONDecoder().decode(DaemonRun.self, from: data)
    }

    func listChats() async throws -> [DaemonChatSummary] {
        try await http.decode("GET", "/chats")
    }

    func renameChat(chatId: String, title: String) async throws -> DaemonChatSummary {
        try await http.decode("PUT", "/chats/\(http.enc(chatId))", json: ["title": title])
    }

    func forkChat(chatId: String, newChatId: String, beforeMessageId: String) async throws -> DaemonChatFork {
        try await http.decode("POST", "/chats/\(http.enc(chatId))/fork",
                              json: ["newChatId": newChatId, "beforeMessageId": beforeMessageId])
    }

    func deleteChat(chatId: String) async throws {
        _ = try await http.run("DELETE", "/chats/\(http.enc(chatId))", json: nil)
    }

    func listMessages(chatId: String, limit: Int?, before: String?) async throws -> [DaemonMessage] {
        var path = "/chats/\(http.enc(chatId))/messages"
        var q: [String] = []
        if let limit { q.append("limit=\(limit)") }
        if let before { q.append("before=\(http.encQuery(before))") }
        if !q.isEmpty { path += "?" + q.joined(separator: "&") }   // scoped() appends &agent= after this
        return try await http.decode("GET", path)
    }

    func messagePage(chatId: String, limit: Int, before: String?, maxBytes: Int) async throws -> DaemonMessagePage {
        try await messagePage(chatId: chatId, limit: limit, before: before, maxBytes: maxBytes, ifRevision: nil)
    }

    func messagePage(chatId: String, limit: Int, before: String?, maxBytes: Int, ifRevision: String?) async throws -> DaemonMessagePage {
        var path = "/chats/\(http.enc(chatId))/messages?limit=\(limit)&paged=true&maxBytes=\(maxBytes)"
        if let before { path += "&before=\(http.encQuery(before))" }
        if before == nil, let ifRevision { path += "&ifRevision=\(http.encQuery(ifRevision))" }
        let body = try await http.run("GET", path, json: nil, quiet: ifRevision != nil)
        let data = Data(body.utf8)
        var page: DaemonMessagePage
        do {
            if body.first(where: { !$0.isWhitespace }) == "[" {
                // Old services ignore the new query parameters. Decode their array without
                // a version probe or a second download of the same transcript.
                let messages = try JSONDecoder().decode([DaemonMessage].self, from: data)
                page = .init(messages: messages, hasMore: messages.count == limit, before: messages.first?.id)
            } else if body.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
                page = .init(messages: [], hasMore: false, before: nil)
            } else {
                page = try JSONDecoder().decode(DaemonMessagePage.self, from: data)
            }
        } catch {
            // Transcript bodies can contain private code and tool output; never log a
            // response preview when decoding fails.
            throw BackendError.message(t("chat.error.historyFormat"))
        }
        page.byteCount = data.count
        if page.notModified == true {
            guard let ifRevision, before == nil, page.revision == ifRevision, page.messages.isEmpty else {
                throw BackendError.message(t("chat.error.historyFormat"))
            }
        }
        return page
    }

    func getConfig() async throws -> [String: String] {
        try await http.decode("GET", "/config")
    }

    func setConfig(_ config: [String: String]) async throws {
        _ = try await http.run("PUT", "/config", json: config)
    }

    func models() async throws -> [DaemonModelInfo] { try await http.decode("GET", "/models") }

    func commands(directory: String?, refresh: Bool) async throws -> DaemonCommandCatalog {
        let path = "/commands?refresh=\(refresh)" + (directory.map { "&dir=" + http.encQuery($0) } ?? "")
        return try await http.decode("GET", path)
    }

    func compactChat(chatId: String, instructions: String, requestId: String) async throws -> DaemonRun {
        try await http.decode("POST", "/chats/\(http.enc(chatId))/compact", json: ["instructions": instructions, "requestId": requestId])
    }

    func memory(directory: String?) async throws -> [DaemonMemoryDocument] {
        try await http.decode("GET", resourcePath("/memory", directory: directory))
    }

    func setMemory(scope: DaemonResourceScope, directory: String?, content: String) async throws -> DaemonMemoryDocument {
        try await http.decode("PUT", resourcePath("/memory", directory: directory),
                              json: ["scope": scope.rawValue, "content": content])
    }

    func deleteMemory(scope: DaemonResourceScope, directory: String?) async throws {
        _ = try await http.run("DELETE", resourcePath("/memory", scope: scope, directory: directory), json: nil)
    }

    func prompts(directory: String?) async throws -> [DaemonPromptTemplate] {
        try await http.decode("GET", resourcePath("/prompts", directory: directory))
    }

    func prompt(name: String, scope: DaemonResourceScope, directory: String?) async throws -> DaemonPromptTemplate {
        try await http.decode("GET", resourcePath("/prompts/\(http.enc(name))", scope: scope, directory: directory))
    }

    func setPrompt(name: String, scope: DaemonResourceScope, directory: String?, content: String) async throws -> DaemonPromptTemplate {
        try await http.decode("PUT", resourcePath("/prompts/\(http.enc(name))", scope: scope, directory: directory), json: ["content": content])
    }

    func deletePrompt(name: String, scope: DaemonResourceScope, directory: String?) async throws {
        _ = try await http.run("DELETE", resourcePath("/prompts/\(http.enc(name))", scope: scope, directory: directory), json: nil)
    }

    func subagents(directory: String?) async throws -> [DaemonSubagent] {
        try await http.decode("GET", resourcePath("/subagents", directory: directory))
    }

    func subagent(name: String, scope: DaemonResourceScope, directory: String?) async throws -> DaemonSubagent {
        try await http.decode("GET", resourcePath("/subagents/\(http.enc(name))", scope: scope, directory: directory))
    }

    func setSubagent(name: String, scope: DaemonResourceScope, directory: String?, content: String) async throws -> DaemonSubagent {
        try await http.decode("PUT", resourcePath("/subagents/\(http.enc(name))", scope: scope, directory: directory), json: ["content": content])
    }

    func deleteSubagent(name: String, scope: DaemonResourceScope, directory: String?) async throws {
        _ = try await http.run("DELETE", resourcePath("/subagents/\(http.enc(name))", scope: scope, directory: directory), json: nil)
    }

    func mcpServers(directory: String?) async throws -> [DaemonResourceScope: [String: DaemonMCPServer]] {
        try await http.decode("GET", resourcePath("/mcp", directory: directory))
    }

    func setMCPServer(name: String, scope: DaemonResourceScope, directory: String?, server: DaemonMCPServer) async throws -> DaemonMCPServer {
        try await http.decode("PUT", resourcePath("/mcp/\(http.enc(name))", scope: scope, directory: directory), json: try jsonObject(server))
    }

    func deleteMCPServer(name: String, scope: DaemonResourceScope, directory: String?) async throws {
        _ = try await http.run("DELETE", resourcePath("/mcp/\(http.enc(name))", scope: scope, directory: directory), json: nil)
    }

    func providers(directory: String?) async throws -> [DaemonResourceScope: [String: DaemonCustomProvider]] {
        try await http.decode("GET", resourcePath("/providers", directory: directory))
    }

    func setProvider(id: String, scope: DaemonResourceScope, directory: String?, provider: DaemonCustomProvider, apiKey: String?) async throws -> DaemonCustomProvider {
        var body = try jsonObject(provider)
        if let apiKey, !apiKey.isEmpty { body["apiKey"] = apiKey }
        return try await http.decode("PUT", resourcePath("/providers/\(http.enc(id))", scope: scope, directory: directory), json: body)
    }

    func deleteProvider(id: String, scope: DaemonResourceScope, directory: String?) async throws {
        _ = try await http.run("DELETE", resourcePath("/providers/\(http.enc(id))", scope: scope, directory: directory), json: nil)
    }

    func setNotifyConfig(url: String, channel: String, token: String) async throws {
        _ = try await http.run("PUT", "/notify/config", json: ["url": url, "channel": channel, "token": token, "format": "push"])
        let config: DaemonNotifyConfig = try await http.decode("GET", "/notify/config")
        guard config.configured, config.url == url, config.channel == channel,
              config.format == "push", config.hasToken == true else {
            throw BackendError.message("Update the Mindwire service to configure notifications.")
        }
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func resourcePath(_ path: String, scope: DaemonResourceScope? = nil, directory: String? = nil) -> String {
        var query: [String] = []
        if let scope { query.append("scope=\(http.encQuery(scope.rawValue))") }
        if let directory, !directory.isEmpty { query.append("dir=\(http.encQuery(directory))") }
        return query.isEmpty ? path : "\(path)?\(query.joined(separator: "&"))"
    }

    func setup() async throws -> DaemonSetupResult { try await http.decode("POST", "/setup") }
    func update() async throws -> DaemonSetupResult { try await http.decode("POST", "/update") }
    func software(refresh: Bool) async throws -> DaemonHarnessSoftware? {
        try await http.decode("GET", refresh ? "/agent/software?refresh=true" : "/agent/software", quiet: !refresh)
    }
    // quiet: this is polled ~every 1.5s during install; logging each poll floods the console.
    func setupStatus() async throws -> DaemonSetupResult { try await http.decode("GET", "/setup", quiet: true) }

    // MARK: - Auth

    func authMethods() async throws -> [DaemonAuthMethod] {
        try await http.decode("GET", "/auth/methods")
    }

    func authBegin(_ method: String) async throws -> DaemonAuthState {
        try await http.decode("POST", "/auth/begin", json: ["method": method])
    }

    func authStep(_ input: [String: String]) async throws -> DaemonAuthState {
        // The daemon decodes the request body directly as the input map (not wrapped).
        try await http.decode("POST", "/auth/step", json: input)
    }

    func authStatus() async throws -> DaemonAuthStatus {
        try await http.decode("GET", "/auth/status")
    }

    func authLogout() async throws -> DaemonAuthStatus {
        try await http.decode("POST", "/auth/logout")
    }
}
