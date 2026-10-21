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
    let capsule: JSONValue
    let digest: String
    var losses: [ChatHandoffLoss]?
}

struct ChatHandoffLoss: Decodable {
    let code: String
    let count: Int
}

struct ChatHandoffRequest: Codable, Equatable {
    let newChatId: String
    let requestId: String
    let targetAgentId: String
    let task: String
    let context: String
    let previewDigest: String
}

struct DaemonHandoffResult: Decodable {
    let chatId: String
    let run: DaemonRun
    let snapshot: WorkspaceMetadata
}
