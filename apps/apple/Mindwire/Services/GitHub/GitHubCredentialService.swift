import Foundation
import NIOSSH

/// Explicit, bounded checks. Neither token nor key checks mutate a repository.
/// Repository listing and SSH authentication do not imply push access to every repo.
struct GitHubCredentialReport {
    let mode: GitHubAuthMode
    var user: GHRestUser? = nil
    var scopes: [String]? = nil
    var expiresAt: String? = nil

    var summary: String {
        if let user { return t("github.credential.signedInAs", ["login": user.login]) }
        return t("github.credential.keyAccepted")
    }
}

struct GitHubCredentialService {
    var session: URLSession = .shared

    func test(mode: GitHubAuthMode, secret: String) async throws -> GitHubCredentialReport {
        switch mode {
        case .token: return try await testToken(secret)
        case .sshKey: return try await testSSH(secret)
        default: throw BackendError.message(t("github.credential.unsupportedTest"))
        }
    }

    func testToken(_ token: String) async throws -> GitHubCredentialReport {
        guard !token.isEmpty else { throw BackendError.message(t("github.credential.missingSecret")) }
        let response = try await GitHubREST.response(GHRestUser.self, "/user", token: token, session: session)
        // A one-item request checks the endpoint used by the repo picker without
        // downloading a large account's full history or requiring read:org.
        _ = try await GitHubREST.get([GHRestRepo].self, "/user/repos?per_page=1", token: token, session: session)
        try Task.checkCancellation()
        let scopes = response.http.value(forHTTPHeaderField: "X-OAuth-Scopes")?.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Fine-grained tokens can omit this classic OAuth header or leave it
        // empty. Neither case proves that access is limited to public repos.
        return .init(mode: .token, user: response.value, scopes: scopes?.isEmpty == false ? scopes : nil,
                     expiresAt: response.http.value(forHTTPHeaderField: "GitHub-Authentication-Token-Expiration"))
    }

    func testSSH(_ privateKey: String) async throws -> GitHubCredentialReport {
        guard SSHKey.isPrivateKeyPEM(privateKey), let key = SSHKey.privateKey(from: privateKey) else {
            throw BackendError.message(t("github.credential.invalidKey"))
        }
        // GitHub publishes its current SSH pins through the authenticated HTTPS
        // origin. Require a matching key; never fall back to trust-on-first-use.
        let meta = try await GitHubREST.get(GitHubSSHMetadata.self, "/meta", session: session)
        let pins = meta.fingerprints
        guard !pins.isEmpty else { throw BackendError.message(t("github.credential.hostKeysMissing")) }
        let ssh = SSHConnection(host: "ssh.github.com", port: 443, username: "git", auth: .privateKey(key),
                                connectTimeoutSeconds: 12, expectedHostKeys: pins)
        defer { ssh.close() }
        do {
            try await withTaskCancellationHandler { try await ssh.authenticate() } onCancel: { ssh.close() }
            try Task.checkCancellation()
        } catch is SSHAuthenticationError {
            throw BackendError.message(t("github.credential.keyRejected"))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BackendError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw BackendError.message(t("github.credential.sshUnavailable"))
        }
        return .init(mode: .sshKey)
    }

    static func secret(for account: GitHubAccount) -> String? {
        switch account.mode {
        case .token: return Keychain.get(KeychainKey.githubToken(account.id))
        case .sshKey: return Keychain.get(KeychainKey.githubSshKey(account.id))
        default: return nil
        }
    }

    static func publicKey(from secret: String) -> String? {
        guard SSHKey.isPrivateKeyPEM(secret) else { return nil }
        return SSHKey.privateKey(from: secret).map { String(openSSHPublicKey: $0.publicKey) }
    }
}

struct GitHubSSHMetadata: Decodable {
    let sshKeyFingerprints: [String: String]
    enum CodingKeys: String, CodingKey { case sshKeyFingerprints = "ssh_key_fingerprints" }
    var fingerprints: Set<String> {
        Set(sshKeyFingerprints.filter { $0.key.hasPrefix("SHA256_") }.values.compactMap {
            guard Data(base64Encoded: $0 + String(repeating: "=", count: (4 - $0.count % 4) % 4))?.count == 32 else { return nil }
            return "SHA256:" + $0
        })
    }
}

enum GitHubCredentialLinks {
    static let sshKey = URL(string: "https://github.com/settings/ssh/new")!
    static let tokens = URL(string: "https://github.com/settings/tokens")!
    static let sshKeys = URL(string: "https://github.com/settings/keys")!

    static func token(name: String, classic: Bool = false, workflows: Bool = false) -> URL {
        var url = URLComponents(string: classic
            ? "https://github.com/settings/tokens/new"
            : "https://github.com/settings/personal-access-tokens/new")!
        let label = String((GitHubAccount.cleanLabel(name) ?? "Mindwire").prefix(40))
        if classic {
            url.queryItems = [.init(name: "description", value: label),
                              .init(name: "scopes", value: workflows ? "repo,workflow" : "repo")]
        } else {
            url.queryItems = [.init(name: "name", value: label),
                              .init(name: "description", value: "Mindwire repository access"),
                              .init(name: "contents", value: "write"),
                              .init(name: "pull_requests", value: "write")]
            if workflows { url.queryItems?.append(.init(name: "workflows", value: "write")) }
        }
        return url.url!
    }
}
