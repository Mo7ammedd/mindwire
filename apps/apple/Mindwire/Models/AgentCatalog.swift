import Foundation

/// A daemon adapter id. This is deliberately open-ended: a newer Mindwire binary can add an
/// adapter without requiring a matching iOS release or a duplicated client enum.
struct AgentID: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String
    var id: String { rawValue }

    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    static let claudeCode = AgentID(rawValue: "claude-code")
    static let codex = AgentID(rawValue: "codex")
    static let grok = AgentID(rawValue: "grok")
    static let opencode = AgentID(rawValue: "opencode")
}

struct AgentDescriptor: Codable, Identifiable, Hashable {
    let id: AgentID
    let name: String
    let tagline: String
    var command: String?
    var botProfiles: Bool? = nil
}

/// Bot instructions must survive resumed conversations. Ordinary chat capabilities do not
/// imply this; older catalogs only fall back to engines with an established bot contract.
enum BotEngineSupport {
    static func supports(_ type: AgentID, catalog: [AgentDescriptor] = [], capabilities: DaemonCapabilities? = nil) -> Bool {
        if let supported = capabilities?.botProfiles { return supported }
        if let supported = catalog.first(where: { $0.id == type })?.botProfiles { return supported }
        return type == .claudeCode || type == .codex || type == .opencode || type == .grok
    }
}
