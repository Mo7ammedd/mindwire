import Foundation

struct WorkspaceMetadata: Codable {
    let version: Int
    let workspaceId: String
    let revision: Int64
    let full: Bool
    var agents: [Agent]
    var projects: [Project]
    var chats: [Chat]
    let deleted: [WorkspaceRecordDeletion]
    var sessionDiscoveryIssues: [WorkspaceSessionDiscoveryIssue]? = nil
    var agentDiscoveryIssues: [WorkspaceAgentDiscoveryIssue]? = nil
    var projectLibrary: DaemonProjectLibrary? = nil
    var bots: [AssistantBot]? = nil
}

struct WorkspaceAgentDiscoveryIssue: Codable, Equatable {
    let agent: String
    let message: String
}

struct WorkspaceEnsureAgentResult: Codable {
    let agentId: String
    let snapshot: WorkspaceMetadata
}

struct WorkspaceSessionDiscoveryIssue: Codable, Equatable {
    let projectId: String
    let agent: String
    let message: String
}

struct WorkspaceRecordDeletion: Codable {
    let kind: String
    let id: String
    let revision: Int64
}

struct WorkspaceLegacyImport: Codable {
    var agents: [Agent] = []
    var projects: [Project] = []
    var chats: [Chat] = []
    var isEmpty: Bool { agents.isEmpty && projects.isEmpty && chats.isEmpty }
}

struct WorkspaceCacheCheckpoint: Codable {
    var identity: String
    var revision: Int64
}
