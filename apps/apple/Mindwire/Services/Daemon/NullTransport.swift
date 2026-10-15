import Foundation

/// No-op `AgentTransport` used before a chat is bound to a workspace (e.g. an orphaned chat whose
/// workspace is gone). Reports offline and refuses turns; message listing returns empty so the chat
/// screen still renders cleanly. The real transport (`ExecDaemonTransport`) replaces it once a
/// workspace is bound (`ChatModel.bind`).
final class NullTransport: AgentTransport {
    func health() async -> DaemonHealth { DaemonHealth(ok: false, agent: "", version: "") }
    func catalog() async throws -> DaemonCatalog {
        throw BackendError.unreachable("No workspace connected.")
    }

    func agentInfo() async throws -> DaemonAgentInfo {
        throw BackendError.unreachable("No workspace connected.")
    }

    func sendTurn(chatId: String, message: String, cwd: String?) async throws -> DaemonRun {
        throw BackendError.unreachable("Connect this chat to a workspace to run the agent.")
    }

    func getRun(_ runId: String) async throws -> DaemonRun {
        throw BackendError.unreachable("No workspace connected.")
    }

    func cancelRun(_ runId: String) async throws {}
    func respondToRun(_ runId: String, interactionId: String, reply: DaemonInteractionReply) async throws { throw unavailable }
    func setPermissionMode(_ runId: String, mode: String) async throws { throw unavailable }

    func streamRun(_ runId: String, after: Int? = nil) -> AsyncThrowingStream<DaemonEvent, Error>? { nil }
    func chatRun(chatId: String) async throws -> DaemonRun? { nil }
    func listChats() async throws -> [DaemonChatSummary] { [] }
    func renameChat(chatId: String, title: String) async throws -> DaemonChatSummary { throw unavailable }
    func deleteChat(chatId: String) async throws { throw unavailable }

    func listMessages(chatId: String, limit: Int?, before: String?) async throws -> [DaemonMessage] { [] }

    func getConfig() async throws -> [String: String] {
        throw BackendError.unreachable("No workspace connected.")
    }
    func setConfig(_ config: [String: String]) async throws {}
    func models() async throws -> [DaemonModelInfo] { throw unavailable }
    func memory(directory: String?) async throws -> [DaemonMemoryDocument] { throw unavailable }
    func setMemory(scope: DaemonResourceScope, directory: String?, content: String) async throws -> DaemonMemoryDocument { throw unavailable }
    func deleteMemory(scope: DaemonResourceScope, directory: String?) async throws { throw unavailable }
    func prompts(directory: String?) async throws -> [DaemonPromptTemplate] { throw unavailable }
    func prompt(name: String, scope: DaemonResourceScope, directory: String?) async throws -> DaemonPromptTemplate { throw unavailable }
    func setPrompt(name: String, scope: DaemonResourceScope, directory: String?, content: String) async throws -> DaemonPromptTemplate { throw unavailable }
    func deletePrompt(name: String, scope: DaemonResourceScope, directory: String?) async throws { throw unavailable }
    func subagents(directory: String?) async throws -> [DaemonSubagent] { throw unavailable }
    func subagent(name: String, scope: DaemonResourceScope, directory: String?) async throws -> DaemonSubagent { throw unavailable }
    func setSubagent(name: String, scope: DaemonResourceScope, directory: String?, content: String) async throws -> DaemonSubagent { throw unavailable }
    func deleteSubagent(name: String, scope: DaemonResourceScope, directory: String?) async throws { throw unavailable }
    func mcpServers(directory: String?) async throws -> [DaemonResourceScope: [String: DaemonMCPServer]] { throw unavailable }
    func setMCPServer(name: String, scope: DaemonResourceScope, directory: String?, server: DaemonMCPServer) async throws -> DaemonMCPServer { throw unavailable }
    func deleteMCPServer(name: String, scope: DaemonResourceScope, directory: String?) async throws { throw unavailable }
    func providers(directory: String?) async throws -> [DaemonResourceScope: [String: DaemonCustomProvider]] { throw unavailable }
    func setProvider(id: String, scope: DaemonResourceScope, directory: String?, provider: DaemonCustomProvider, apiKey: String?) async throws -> DaemonCustomProvider { throw unavailable }
    func deleteProvider(id: String, scope: DaemonResourceScope, directory: String?) async throws { throw unavailable }
    func setNotifyConfig(url: String, channel: String, token: String) async throws { throw unavailable }

    private var unavailable: BackendError { .unreachable("No workspace connected.") }

    func setup() async throws -> DaemonSetupResult {
        throw BackendError.unreachable("No workspace connected.")
    }
    func setupStatus() async throws -> DaemonSetupResult {
        throw BackendError.unreachable("No workspace connected.")
    }

    func authMethods() async throws -> [DaemonAuthMethod] { [] }
    func authBegin(_ method: String) async throws -> DaemonAuthState {
        throw BackendError.unreachable("No workspace connected.")
    }
    func authStep(_ input: [String: String]) async throws -> DaemonAuthState {
        throw BackendError.unreachable("No workspace connected.")
    }
    func authStatus() async throws -> DaemonAuthStatus { DaemonAuthStatus(configured: false) }
}
