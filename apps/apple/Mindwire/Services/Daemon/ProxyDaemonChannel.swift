import Foundation
import OblienKit

/// Cloud requests use the gateway bearer token plus a separate daemon token. Both ordinary HTTP
/// requests and SSE use one builder, so credential refresh applies to the entire chat connection.
struct ProxyDaemonChannel: StreamingDaemonChannel {
    private let channel: URLSessionDaemonChannel
    var label: String { "proxy" }

    init(workspaceId: String, port: Int = AppConstants.daemonPort, daemonToken: String) {
        let credentials = ProxyDaemonCredentials(workspaceId: workspaceId, port: port, daemonToken: daemonToken)
        channel = URLSessionDaemonChannel(label: "proxy") { method, path, body, force in
            try await credentials.request(method: method, path: path, jsonBody: body, force: force)
        }
    }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        try await channel.perform(method: method, path: path, jsonBody: jsonBody)
    }

    func stream(method: String, path: String, jsonBody: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        try await channel.stream(method: method, path: path, jsonBody: jsonBody)
    }
}

private actor ProxyDaemonCredentials {
    private let workspaceId: String
    private let port: Int
    private let daemonToken: String
    private var runtimeClient: RuntimeClient?

    init(workspaceId: String, port: Int, daemonToken: String) {
        self.workspaceId = workspaceId
        self.port = port
        self.daemonToken = daemonToken
    }

    private func runtime(force: Bool) async throws -> RuntimeClient {
        if let runtimeClient, !force { return runtimeClient }
        let client = try await OblienCloud.client.workspace(workspaceId).runtime(force: force)
        runtimeClient = client
        return client
    }

    func request(method: String, path: String, jsonBody: Data?, force: Bool) async throws -> URLRequest {
        let runtime = try await runtime(force: force)
        let gatewayToken = try await runtime.token()
        let base = OblienCloud.client.config.runtimeURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/proxy/\(port)\(path)") else {
            throw BackendError.message("invalid Mindwire proxy URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization")
        request.setValue(daemonToken, forHTTPHeaderField: "X-Mindwire-Token")
        if let jsonBody {
            request.httpBody = jsonBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
