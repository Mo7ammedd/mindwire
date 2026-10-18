import Foundation

/// Mindwire-owned services. Oblien remains the current native sign-in provider;
/// its session is verified by Mindwire, never interpreted locally as an identity.
actor MindwireServicesAPI {
    static let shared = MindwireServicesAPI()
    private let session = URLSession(configuration: .default)

    func send(_ method: String, _ path: String, body: Data? = nil, retrying: Bool = false) async throws -> Data? {
        guard path.hasPrefix("/api/notifications/"),
              let url = URL(string: AppConstants.mindwireServicesBase + path) else { throw APIError.badURL(path) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await OblienAPI.shared.token(forceRefresh: retrying))", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        APILog.request(request)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw APIError.transport(path) }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport(path) }
        // Send credentials are returned once; never log response bodies.
        APILog.response(request, status: http.statusCode, body: Data())
        if http.statusCode == 401 && !retrying {
            return try await send(method, path, body: body, retrying: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, detail: String(data: data, encoding: .utf8))
        }
        return data.isEmpty ? nil : data
    }
}

struct NotificationSendToken: Decodable, Sendable {
    let id: Int
    var status: String
    let tokenPrefix: String?
    let token: String?
    let workspaceID: String?
    let tag: String?
    enum CodingKeys: String, CodingKey {
        case id, status, token, tag
        case tokenPrefix = "token_prefix", workspaceID = "workspace_id"
    }
}
