import Foundation

struct ChatHandoffOrigin: Codable, Hashable {
    let chatId: String
    let agentId: String
    let title: String
    var runId: String?
}

struct DaemonHandoffPreview: Decodable {
    let source: ChatHandoffOrigin
    let context: String
    let truncated: Bool
    let historySource: String
}

struct ChatHandoffRequest: Codable, Equatable {
    let newChatId: String
    let requestId: String
    let targetAgentId: String
    let task: String
    let context: String
}

struct DaemonHandoffResult: Decodable {
    let chatId: String
    let run: DaemonRun
    let snapshot: WorkspaceMetadata
}
