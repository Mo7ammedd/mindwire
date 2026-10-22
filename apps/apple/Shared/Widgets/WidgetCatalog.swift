import Foundation

/// A presentation snapshot. Connections, URLs, commands and credentials stay in the app.
struct WidgetAppShortcut: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let computerName: String
    let icon: String?
    let artwork: Data?
}

struct WidgetCatalog: Codable, Equatable, Sendable {
    var version = 1
    var apps: [WidgetAppShortcut] = []
    var assistantArtworkKey: String? = nil
    var assistantArtwork: Data? = nil
    var bots: [WidgetBot]? = nil
    var activity: [WidgetChatActivity]? = nil
}

enum MindwireWidget {
    static let appGroup = "group.com.oblien.mindwire"
    static let appsKind = "MindwireApps"
    static let askKind = "AskMindwire"

    static var catalogURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("widget-catalog-v1.json")
    }

    static func readCatalog() -> WidgetCatalog {
        guard let url = catalogURL, let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(WidgetCatalog.self, from: data),
              catalog.version == 1 else { return WidgetCatalog() }
        return catalog
    }
}

enum WidgetLink: Equatable {
    case app(String), chat(String), apps, ask

    var url: URL {
        var components = URLComponents()
        components.scheme = "mindwire"
        components.host = "widget"
        switch self {
        case .app(let id):
            components.path = "/app"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .chat(let id):
            components.path = "/chat"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .apps: components.path = "/apps"
        case .ask: components.path = "/ask"
        }
        return components.url!
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "mindwire", components.host == "widget",
              components.user == nil, components.password == nil, components.port == nil else { return nil }
        switch components.path {
        case "/app", "/chat":
            let values = (components.queryItems ?? []).filter { $0.name == "id" }
            guard values.count == 1, let id = values.first?.value, !id.isEmpty, id.count <= 1024 else { return nil }
            self = components.path == "/chat" ? .chat(id) : .app(id)
        case "/apps": self = .apps
        case "/ask": self = .ask
        default: return nil
        }
    }
}
