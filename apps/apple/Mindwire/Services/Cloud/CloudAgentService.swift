import Foundation

/// `AgentService` backed by the Oblien platform REST API (`/v1/sessions`).
final class CloudAgentService: AgentService {
    private let api = OblienAPI.shared

    func listSessions() async throws -> [AgentSession] {
        try await api.get("/v1/sessions")
    }

    func getSession(_ id: String) async throws -> AgentSession? {
        guard let data = try await api.send("GET", "/v1/sessions/\(enc(id))") else { return nil }
        return try? JSONDecoder().decode(AgentSession.self, from: data)
    }

    func startSession(_ input: StartAgentInput) async throws -> AgentSession {
        let body = try JSONEncoder().encode(input)
        guard let data = try await api.send("POST", "/v1/sessions", body: body) else {
            throw APIError.http(status: 204, detail: "empty session response")
        }
        return try JSONDecoder().decode(AgentSession.self, from: data)
    }

    func stopSession(_ id: String) async throws {
        _ = try await api.send("POST", "/v1/sessions/\(enc(id))/stop")
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
