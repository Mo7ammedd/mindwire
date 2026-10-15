import Foundation

struct NativeSessionCapabilities: Codable, Hashable {
    var status: Bool = false
    var observe: Bool = false
    var input: Bool = false
    var interrupt: Bool = false
    var respond: Bool = false
}

struct NativeSessionActivity: Codable, Hashable {
    let sessionId: String
    let cwd: String
    let owner: String
    var state: String
    var turnId: String? = nil
    var startedAt: String? = nil
    var reason: String? = nil
    let capabilities: NativeSessionCapabilities

    var isRunning: Bool { owner == "native" && (state == "running" || state == "waiting") }
}

struct NativeSessionSnapshot: Decodable {
    let connectionId: String
    let sequence: Int
    var turnId: String? = nil
    let activity: NativeSessionActivity
    var parts: [DaemonMessagePart]? = nil
    var inputs: [DaemonUserInput]? = nil
    var historyRequired: Bool? = nil
    var partial: Bool? = nil
    var replay: Bool? = nil
}

struct NativeSessionUpdate: Decodable {
    let connectionId: String
    let sequence: Int
    var activity: NativeSessionActivity? = nil
    var event: DaemonEvent? = nil
    var turnId: String? = nil
    var reset: Bool? = nil
    var historyChanged: Bool? = nil
    var partial: Bool? = nil
}

struct NativeSessionFrame: Decodable {
    let type: String
    var snapshot: NativeSessionSnapshot? = nil
    var update: NativeSessionUpdate? = nil
}

struct NativeSessionAction: Encodable, Equatable {
    let connectionId: String
    let requestId: String
    let kind: String
    var expectedTurnId: String? = nil
    var text: String? = nil
    var attachments: [DaemonAttachment]? = nil
    var response: NativeSessionResponse? = nil
}

struct NativeSessionResponse: Encodable, Equatable {
    let interactionId: String
    let decision: String?
    let options: [String]?
    let text: String?
    let answers: [String: DaemonQuestionAnswer]?
}

struct NativeSessionReceipt: Decodable {
    let requestId: String
    let status: String
    var turnId: String? = nil
}
