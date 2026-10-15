import Foundation

protocol AgentService: AnyObject {
    func listSessions() async throws -> [AgentSession]
    func getSession(_ id: String) async throws -> AgentSession?
    func startSession(_ input: StartAgentInput) async throws -> AgentSession
    func stopSession(_ id: String) async throws
}
