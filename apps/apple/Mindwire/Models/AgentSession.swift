import Foundation

enum AgentSessionStatus: String, Codable, Hashable {
    case starting, running, idle
    case awaitingInput = "awaiting_input"
    case stopped, error
}

/// A live run inside the workspace. Not persisted by the client — fetched live from the backend.
struct AgentSession: Codable, Identifiable, Hashable {
    let id: String
    var agentId: String?
    let agent: String
    var title: String
    var status: AgentSessionStatus
    var cwd: String
    let createdAt: String
    var updatedAt: String
}

struct StartAgentInput: Encodable {
    let agent: String
    let cwd: String
    var prompt: String?
}

/// A persisted Agent joined with its (optional) live session and resolved server.
struct AgentRow: Identifiable, Hashable {
    var id: String { agent.id }
    let agent: Agent
    var session: AgentSession?
    var server: Connection?
}
