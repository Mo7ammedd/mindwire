import Foundation

/// The four bottom tabs.
enum AppTab: String, Hashable, Codable, CaseIterable { case agents, projects, workspaces, settings }

enum ComputerCollection: String, Hashable { case personal, cloud }

/// One shared set of pushed destinations, resolved by EVERY content tab (`withAppRoutes()`).
/// In-app drill-down uses `NavigationLink(value:)` / appends to the *current* tab's path, so the
/// destination opens within the stack you're already in and the bottom tab never changes.
/// Folder drill-down is part of this same path, so popping a project retains its folder. Only
/// deep links and post-creation jumps switch tabs (the `AppModel.open*` helpers). Modals are local
/// `.sheet` state in screens; Settings keeps its own `SettingsRoute` (no cross-entity nav).
enum AppRoute: Hashable, Codable {
    case botDetail(botId: String)
    case agentDetail(agentId: String)
    case agentAuthentication(agentId: String)
    case chat(chatId: String)
    case workspaceDetail(id: String)
    case workspaceProjects(workspaceId: String)
    case projectFolder(id: String, workspaceId: String?)
    case projectDetail(id: String)
}

enum SettingsRoute: Hashable, Codable {
    case account
    case backupSync
    case notifications
    case servers
    case serverDetail(id: String)
    case github
}

/// Files and Source Control open a chat with selected code ready for a comment.
struct ChatDraftRoute: Hashable { let chatId: String; let draft: String }
