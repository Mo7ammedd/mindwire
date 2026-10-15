import Foundation

/// Sign-in providers. `slug` is the Oblien social slug used in `GET /auth/{slug}/url`.
enum CloudProvider: String, Codable, CaseIterable, Identifiable, Hashable {
    case oblien, google, apple, github, x
    var id: String { rawValue }
}

struct CloudProviderMeta: Identifiable, Hashable {
    let id: CloudProvider
    let name: String
    var slug: String?
}

enum CloudProviders {
    /// Order matches `CLOUD_PROVIDERS`.
    static let all: [CloudProviderMeta] = [
        .init(id: .oblien, name: "Oblien", slug: nil),
        .init(id: .google, name: "Google", slug: "google"),
        .init(id: .apple, name: "Apple", slug: "apple"),
        .init(id: .github, name: "GitHub", slug: "github"),
        .init(id: .x, name: "X", slug: "twitter"),
    ]
    static func slug(_ id: CloudProvider) -> String? { all.first { $0.id == id }?.slug }
}

/// Matches `GET /auth/status` → `user`: `{ id (number), name, email, image, show_welcome }`.
struct AuthUser: Codable, Hashable {
    var id: Int?
    var name: String?
    var email: String?
    var image: String?
    var showWelcome: Bool?
    enum CodingKeys: String, CodingKey {
        case id, name, email, image
        case showWelcome = "show_welcome"
    }
}

struct AuthStatus: Codable, Hashable {
    let authenticated: Bool
    var user: AuthUser?
}

/// Drawer/account footer view-model.
struct Account: Hashable {
    let name: String
    var email: String?
    let initial: String
}
