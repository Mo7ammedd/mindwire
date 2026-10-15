import Foundation

enum APIError: LocalizedError {
    case http(status: Int, detail: String?)
    case transport(String)
    case tokenMint(String)
    case badURL(String)

    var errorDescription: String? {
        switch self {
        case .http(let s, let d): return (d?.isEmpty == false) ? d : "Request failed (\(s))"
        case .transport: return "Couldn't reach the server. Check your connection and try again."
        case .tokenMint(let m): return m
        case .badURL(let u): return "Bad URL: \(u)"
        }
    }
}

/// Oblien **management** API client (`api.oblien.com`): lazily mints an anonymous
/// session token (persisted in the Keychain), attaches `Authorization: Bearer`,
/// retries once on 401. Mirrors the RN `ApiClient` + token bootstrap.
actor OblienAPI {
    static let shared = OblienAPI()

    private let base = AppConstants.oblienAPIBase
    private let session = URLSession(configuration: .default)
    private var mintTask: Task<String, Error>?

    // MARK: - Session token

    func token(forceRefresh: Bool = false) async throws -> String {
        if forceRefresh { clearToken() }
        if let existing = SessionToken.get(), !existing.isEmpty { return existing }
        if let task = mintTask { return try await task.value }
        let task = Task<String, Error> { try await self.mint() }
        mintTask = task
        defer { mintTask = nil }
        return try await task.value
    }

    func clearToken() {
        SessionToken.clear()
        mintTask = nil
    }

    private func mint() async throws -> String {
        let req = try request("POST", AppConstants.oblienAPIBase + "/auth/token", authed: false)
        let (data, resp) = try await perform(req, path: "/auth/token")
        guard (200..<300).contains(resp.statusCode) else {
            throw APIError.tokenMint("Token request failed (\(resp.statusCode))")
        }
        guard let token = Self.extractToken(data), !token.isEmpty else {
            throw APIError.tokenMint("Token response did not contain a token")
        }
        SessionToken.set(token)
        return token
    }

    private static func extractToken(_ data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            if let s = obj as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let dict = obj as? [String: Any] {
                if let t = dict["token"] as? String { return t }
                if let t = dict["access_token"] as? String { return t }
            }
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    // MARK: - Requests (management surface)

    /// Raw request against `api.oblien.com`. Returns nil on 204/empty.
    @discardableResult
    func send(_ method: String, _ path: String, body: Data? = nil, retrying: Bool = false, logResponseBody: Bool = true) async throws -> Data? {
        let tok = try await token()
        var req = try request(method, base + path, authed: true, token: tok)
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await perform(req, path: path, logResponseBody: logResponseBody)
        if resp.statusCode == 401, !retrying {
            clearToken()
            return try await send(method, path, body: body, retrying: true, logResponseBody: logResponseBody)
        }
        guard (200..<300).contains(resp.statusCode) else {
            throw APIError.http(status: resp.statusCode, detail: String(data: data, encoding: .utf8))
        }
        if resp.statusCode == 204 || data.isEmpty { return nil }
        return data
    }

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        guard let data = try await send("GET", path) else {
            throw APIError.http(status: 204, detail: "empty response")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Auth

    enum AuthPollStatus { case pending, authenticated, expired }

    /// Hosted-login session (mirrors the dashboard): `POST /auth/session {app:"mobile"}` →
    /// `{ url }` = `auth.oblien.com/<id>`. Opening it lets the user log in on the hosted page
    /// (email/password, 2FA, all OAuth providers), which attaches them to THIS session — the same
    /// token becomes authenticated. Returns the url + the session id (for polling).
    func createAuthSession() async throws -> (url: URL, id: String) {
        // `redirect_url` is required by the server (500 without it) and must be a first-party
        // `*.oblien.com` https URL. Mobile never follows it — we poll — so any valid one works.
        let body = try JSONSerialization.data(withJSONObject: [
            "app": "mobile",
            "redirect_url": "https://oblien.com",
        ])
        guard let data = try await send("POST", "/auth/session", body: body) else {
            throw APIError.http(status: 0, detail: "Empty session response")
        }
        struct Resp: Decodable { let url: String }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let url = URL(string: resp.url) else { throw APIError.badURL(resp.url) }
        return (url, url.lastPathComponent)
    }

    /// Poll a hosted-login session with the same token. 404/403/network collapse to `.expired`.
    func pollAuthSession(_ id: String) async -> AuthPollStatus {
        do {
            guard let data = try await send("GET", "/auth/session/\(id)/poll"),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["status"] as? String else { return .pending }
            switch status {
            case "authenticated": return .authenticated
            case "expired":       return .expired
            default:              return .pending
            }
        } catch {
            return .expired
        }
    }

    func authStatus() async throws -> AuthStatus { try await get("/auth/status") }

    // MARK: - Plumbing

    private func request(_ method: String, _ urlString: String, authed: Bool, token: String? = nil) throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw APIError.badURL(urlString) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if authed, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func perform(_ req: URLRequest, path: String, logResponseBody: Bool = true) async throws -> (Data, HTTPURLResponse) {
        APILog.request(req)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw APIError.transport(path) }
            APILog.response(req, status: http.statusCode, body: logResponseBody ? data : Data())
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch {
            APILog.failure(req, error: error)
            throw APIError.transport(path)
        }
    }
}
