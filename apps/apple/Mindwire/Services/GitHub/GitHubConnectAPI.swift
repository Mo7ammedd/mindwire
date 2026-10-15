import Foundation

extension Notification.Name {
    /// Posted when a GitHub step returns to the app via the `oblien://github/connected` deep link
    /// (fires after both OAuth connect and App install), so the connect screen can advance.
    static let oblienGitHubConnected = Notification.Name("oblien.github.connected")
}

/// Oblien GitHub **connection** endpoints over the shared session JWT. Two ordered steps:
/// `connect` (OAuth → user token) then `install` (the App on that account); `install` 409s until
/// connected. Both take `platform:"mobile"` to deep-link (`oblien://github/connected`) back.
/// Repo listing/clone live in `OblienGitHubService`.
struct GitHubConnectAPI {
    private let api: OblienAPI

    init(api: OblienAPI = .shared) { self.api = api }

    /// Current connection (we hold a working GitHub OAuth token) for the signed-in Oblien user.
    func status() async throws -> GitHubStatus {
        let data = try await api.send("GET", "/github/status") ?? Data()
        return try JSONDecoder().decode(GitHubStatus.self, from: data)
    }

    /// Step 1 — `POST /github/connect`: GitHub OAuth authorize URL. Open it; the callback stores the
    /// user token and deep-links back. Then re-check `status()`.
    func connectURL() async throws -> URL { try await redirectURL(from: "/github/connect") }

    /// Step 2 — `POST /github/install` (requires connected): the App install URL. 409 `not_connected`
    /// if you skipped step 1.
    func installURL() async throws -> URL { try await redirectURL(from: "/github/install") }

    private func redirectURL(from path: String) async throws -> URL {
        // `platform:"mobile"` → deep-link callback instead of a web popup.
        let body = try JSONSerialization.data(withJSONObject: ["platform": "mobile"])
        let data = try await api.send("POST", path, body: body) ?? Data()
        let resp = try JSONDecoder().decode(ConnectResponse.self, from: data)
        guard let raw = resp.redirectUrl, let url = URL(string: raw) else {
            throw BackendError.message(resp.message ?? "GitHub didn't return a URL.")
        }
        return url
    }

    /// Accounts/orgs the App is installed on, live from GitHub (`GET /github/user/orgs`).
    func installations() async throws -> [GitHubOwner] {
        let data = try await api.send("GET", "/github/user/orgs") ?? Data()
        return try GitHubJSON.decode([GHInstall].self, from: data).map {
            GitHubOwner(login: $0.login, kind: $0.type == "Organization" ? .org : .user, avatarUrl: $0.avatar_url)
        }
    }

    func disconnect() async throws { _ = try await api.send("POST", "/github/disconnect") }
}

private struct GHInstall: Decodable { let login: String; let avatar_url: String?; let type: String? }

/// `GET /github/status`: `connected:false` when not linked; full GitHub user fields when connected.
struct GitHubStatus: Decodable {
    let connected: Bool
    let login: String?
    let avatarUrl: String?
    enum CodingKeys: String, CodingKey {
        case connected, login
        case avatarUrl = "avatar_url"
    }
}

private struct ConnectResponse: Decodable { let redirectUrl: String?; let message: String? }
