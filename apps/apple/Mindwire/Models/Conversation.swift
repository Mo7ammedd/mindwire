import Foundation

/// A reference to native harness history. Browsing does not create a project or
/// copy messages into the app. The daemon associates the reference when opened.
struct Conversation: Codable, Identifiable, Equatable {
    let id: String
    var chatId: String?
    var agentId: String?
    let agentType: String
    var agentName: String
    var projectId: String?
    var projectName: String?
    let cwd: String
    var title: String
    let createdAt: String
    var updatedAt: String
    var lastStatus: String?
    var lastRunId: String?

    var folderLabel: String {
        let parts = cwd.split(separator: "/").map(String.init)
        if parts.count >= 2, ["Users", "home"].contains(parts[0]) {
            return "~/" + parts.dropFirst(2).joined(separator: "/")
        }
        return cwd
    }

    var activityDate: Date? { RelativeTime.date(updatedAt) }
}

struct ConversationQuery: Equatable {
    var agentId: String? = nil
    var search = ""
    var cursor: String? = nil
    var limit = 50
    var refresh = false
}

struct ConversationPage: Codable {
    let workspaceId: String
    var items: [Conversation]
    let total: Int
    var nextCursor: String? = nil
    var issues: [WorkspaceSessionDiscoveryIssue]? = nil
}

struct ConversationOpenRequest: Codable {
    let id: String
    var agentId: String? = nil
}

struct ConversationOpenResult: Codable {
    let chatId: String
    let snapshot: WorkspaceMetadata
}
