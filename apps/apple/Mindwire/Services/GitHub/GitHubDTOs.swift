import Foundation

/// Decoding + small helpers shared by the live GitHub adapters.
///
/// Two response families:
/// - **Oblien `/github/*`** returns "mapped repo" objects (no clone/ssh URL — we derive them) and
///   some legacy list endpoints return `{ "error": ... }` with HTTP 200, so we branch on the body.
/// - **GitHub REST** (token mode) returns standard GitHub objects.
enum GitHubJSON {
    /// Decode `T`, first surfacing the legacy `{ "error" | "message" }` (HTTP-200) failure shape.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        if let err = try? decoder.decode(GHErrorBody.self, from: data),
           let message = (err.message?.isEmpty == false ? err.message : nil) ?? err.error {
            throw BackendError.message(message)
        }
        return try decoder.decode(T.self, from: data)
    }
}

private struct GHErrorBody: Decodable { let error: String?; let message: String? }

enum GitHubFilter {
    /// Client-side name filter — the listing endpoints don't take a search query.
    static func byName(_ repos: [GitHubRepo], query: String?) -> [GitHubRepo] {
        guard let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { return repos }
        return repos.filter { $0.fullName.localizedCaseInsensitiveContains(q) }
    }
}

extension String {
    /// Percent-encode a single path segment (owner/repo/org logins). Validated server-side too.
    var ghPathSegment: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self }
    var ghQueryValue: String { addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self }
}

// MARK: - Oblien `/github` DTOs

/// `GET /github/user/orgs` element.
struct GHOblienOwner: Decodable {
    let login: String
    let avatarUrl: String?
    let type: String?   // "User" | "Organization"
    enum CodingKeys: String, CodingKey { case login; case avatarUrl = "avatar_url"; case type }

    func toOwner() -> GitHubOwner {
        GitHubOwner(login: login,
                    kind: (type?.lowercased() == "organization") ? .org : .user,
                    avatarUrl: avatarUrl)
    }
}

/// The Oblien "mapped repo" object (no clone/ssh URL — derived from owner/name).
struct GHOblienRepo: Decodable {
    let fullName: String
    let name: String
    let owner: String
    let description: String?
    let isPrivate: Bool?
    let defaultBranch: String?
    let language: String?
    let stars: Int?
    let updatedAt: String?
    enum CodingKeys: String, CodingKey {
        case fullName = "full_name", name, owner, description
        case isPrivate = "private"
        case defaultBranch = "default_branch", language, stars
        case updatedAt = "updated_at"
    }

    func toRepo() -> GitHubRepo {
        GitHubRepo(owner: owner, name: name, fullName: fullName,
                   isPrivate: isPrivate ?? false, defaultBranch: defaultBranch,
                   description: description, language: language, stars: stars ?? 0,
                   updatedAt: updatedAt,
                   cloneUrl: "https://github.com/\(owner)/\(name).git",
                   sshUrl: "git@github.com:\(owner)/\(name).git")
    }
}

/// `POST /github/repos/:owner/:repo/clone-token`.
struct GHCloneToken: Decodable {
    let token: String?
    let cloneUrl: String?
    let expiresAt: String?
    enum CodingKeys: String, CodingKey { case token; case cloneUrl = "clone_url"; case expiresAt = "expires_at" }
}

// MARK: - GitHub REST DTOs (token mode)

struct GHRestUser: Decodable {
    let login: String
    let name: String?
    let avatarUrl: String?
    enum CodingKeys: String, CodingKey { case login, name; case avatarUrl = "avatar_url" }
}

struct GHRestRepo: Decodable {
    struct OwnerRef: Decodable { let login: String; let type: String?; let avatar_url: String? }
    let name: String
    let fullName: String
    let owner: OwnerRef
    let description: String?
    let isPrivate: Bool
    let defaultBranch: String?
    let language: String?
    let stargazersCount: Int?
    let updatedAt: String?
    let cloneUrl: String
    let sshUrl: String
    enum CodingKeys: String, CodingKey {
        case name, owner, description, language
        case fullName = "full_name"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
        case stargazersCount = "stargazers_count"
        case updatedAt = "updated_at"
        case cloneUrl = "clone_url"
        case sshUrl = "ssh_url"
    }

    func toRepo() -> GitHubRepo {
        GitHubRepo(owner: owner.login, name: name, fullName: fullName, isPrivate: isPrivate,
                   defaultBranch: defaultBranch, description: description, language: language,
                   stars: stargazersCount ?? 0, updatedAt: updatedAt, cloneUrl: cloneUrl, sshUrl: sshUrl)
    }
}

// MARK: - gh CLI DTOs (gh repo list --json …)

struct GHCliRepo: Decodable {
    struct Ref: Decodable { let name: String? }
    struct OwnerRef: Decodable { let login: String }
    let name: String
    let nameWithOwner: String
    let owner: OwnerRef
    let description: String?
    let isPrivate: Bool?
    let primaryLanguage: Ref?
    let stargazerCount: Int?
    let updatedAt: String?
    let defaultBranchRef: Ref?

    func toRepo() -> GitHubRepo {
        GitHubRepo(owner: owner.login, name: name, fullName: nameWithOwner,
                   isPrivate: isPrivate ?? false, defaultBranch: defaultBranchRef?.name,
                   description: description, language: primaryLanguage?.name, stars: stargazerCount ?? 0,
                   updatedAt: updatedAt,
                   cloneUrl: "https://github.com/\(nameWithOwner).git",
                   sshUrl: "git@github.com:\(nameWithOwner).git")
    }
}
