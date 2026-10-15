import Foundation

/// Shared by the app's harness glyphs and the notification extension's sender avatars.
struct AgentBrand {
    let name: String
    let assetName: String?
    let usesTemplate: Bool

    static func resolve(_ id: String) -> AgentBrand {
        switch id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude-code": return AgentBrand(name: "Claude Code", assetName: "agent-claude-code", usesTemplate: false)
        case "codex": return AgentBrand(name: "Codex", assetName: "agent-codex", usesTemplate: false)
        case "grok": return AgentBrand(name: "Grok", assetName: "agent-grok", usesTemplate: true)
        case "opencode": return AgentBrand(name: "OpenCode", assetName: "agent-opencode", usesTemplate: true)
        default: return AgentBrand(name: "Agent", assetName: nil, usesTemplate: true)
        }
    }
}
