import Foundation

enum APIError: LocalizedError {
    case http(status: Int, detail: String?)
    case transport(String)
    case tokenMint(String)
    case badURL(String)

    var errorDescription: String? {
        switch self {
        case .http(let s, let d):
            if let data = d?.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object["error_description"] as? String ?? object["message"] as? String ?? object["error"] as? String ?? "Request failed (\(s))"
            }
            return (d?.isEmpty == false) ? d : "Request failed (\(s))"
        case .transport: return "Couldn't reach the server. Check your connection and try again."
        case .tokenMint(let m): return m
        case .badURL(let u): return "Bad URL: \(u)"
        }
    }
}

/// Account credentials must never follow a control-plane redirect to another origin.
private final class MindwireAccountHTTPDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Mindwire account and Cloud Computer API. Only Mindwire sessions live on the
/// device; reseller credentials and computer namespaces stay in Console.
actor MindwireAPI {
    static let shared = MindwireAPI()
    private let base = AppConstants.mindwireServicesBase
    static let httpSession = URLSession(configuration: .default, delegate: MindwireAccountHTTPDelegate(), delegateQueue: nil)
    private let session = MindwireAPI.httpSession

    struct DeviceLogin: Decodable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURI: URL
        let verificationURIComplete: URL
        let expiresIn: Int
        let interval: Int
        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code", userCode = "user_code"
            case verificationURI = "verification_uri", verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in", interval
        }
    }
    enum AuthPollStatus { case pending, authenticated, expired, slowDown }

    func token(forceRefresh: Bool = false) throws -> String {
        guard let value = MindwireSessionToken.get(), !value.isEmpty else {
            throw APIError.http(status: 401, detail: "Sign in to Mindwire to use Cloud Computers.")
        }
        return value
    }

    func clearToken() { MindwireSessionToken.clear() }

    func signOut() async throws {
        _ = try await accountRequest("POST", "/api/account/sign-out", body: Data("{}".utf8))
        clearToken()
    }

    @discardableResult
    func send(_ method: String, _ path: String, body: Data? = nil, retrying: Bool = false, logResponseBody: Bool = true) async throws -> Data? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\") else { throw APIError.badURL(path) }
        return try await accountRequest(method, "/api/cloud/provider" + path, body: body)
    }

    @discardableResult
    func accountRequest(_ method: String, _ path: String, body: Data? = nil, authenticated: Bool = true) async throws -> Data? {
        guard path.hasPrefix("/api/"), !path.contains("\\"), let url = URL(string: base + path), url.host == URL(string: base)?.host else {
            throw APIError.badURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(base, forHTTPHeaderField: "Origin")
        if authenticated { request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        APILog.request(request)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw APIError.transport(path) }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport(path) }
        // Responses may contain login codes, runtime credentials or clone tokens.
        APILog.response(request, status: http.statusCode, body: Data())
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, detail: String(data: data, encoding: .utf8))
        }
        return data.isEmpty ? nil : data
    }

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        guard let data = try await send("GET", path) else { throw APIError.http(status: 204, detail: "Empty response") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func createAuthSession() async throws -> DeviceLogin {
        let body = try JSONSerialization.data(withJSONObject: ["client_id": "mindwire-native"])
        guard let data = try await accountRequest("POST", "/api/account/device/code", body: body, authenticated: false) else {
            throw APIError.tokenMint("Mindwire did not return a sign-in code.")
        }
        let login = try JSONDecoder().decode(DeviceLogin.self, from: data)
        guard login.verificationURIComplete.scheme == "https", login.verificationURIComplete.host == URL(string: base)?.host else {
            throw APIError.badURL(login.verificationURIComplete.absoluteString)
        }
        return login
    }

    func pollAuthSession(_ code: String) async throws -> AuthPollStatus {
        let body = try JSONSerialization.data(withJSONObject: ["client_id": "mindwire-native", "device_code": code,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
        do {
            guard let data = try await accountRequest("POST", "/api/account/device/token", body: body, authenticated: false) else { return .pending }
            struct Grant: Decodable { let access_token: String }
            let grant = try JSONDecoder().decode(Grant.self, from: data)
            guard !grant.access_token.isEmpty, MindwireSessionToken.set(grant.access_token) else {
                throw APIError.tokenMint("Mindwire could not securely save your sign-in. Please try again.")
            }
            return .authenticated
        } catch APIError.http(let status, let detail) {
            let object = detail?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            switch object?["error"] as? String {
            case "authorization_pending": return .pending
            case "slow_down": return .slowDown
            case "expired_token", "access_denied", "invalid_grant": return .expired
            default: throw APIError.http(status: status, detail: detail)
            }
        }
    }

    func authStatus() async throws -> AuthStatus {
        guard MindwireSessionToken.get() != nil else { return AuthStatus(authenticated: false) }
        do {
            guard let data = try await accountRequest("GET", "/api/cloud/account") else { throw APIError.transport("account") }
            return try JSONDecoder().decode(AuthStatus.self, from: data)
        } catch APIError.http(let status, _) where status == 401 {
            return AuthStatus(authenticated: false)
        }
    }

    func linkPreviousAccount() async throws {
        guard let legacy = SessionToken.get() else { return }
        struct LinkStatus: Decodable { let connected: Bool }
        do {
            if let data = try await accountRequest("GET", "/api/cloud/legacy/status"),
               try JSONDecoder().decode(LinkStatus.self, from: data).connected { return }
        } catch APIError.http(let status, _) where status == 401 {
            // An expired previous session requires fresh proof, never email matching.
        }
        let body = try JSONSerialization.data(withJSONObject: ["token": legacy])
        _ = try await accountRequest("POST", "/api/cloud/legacy/link", body: body)
        // Keep the original credential until migration is confirmed; server-side
        // storage is encrypted. The app never sends it to ordinary computer APIs.
    }
}
