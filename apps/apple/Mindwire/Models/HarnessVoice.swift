import Foundation

/// A harness interface, not a coding model's audio-file modality.
struct HarnessVoiceCapability: Codable, Hashable {
    let mode: String
    let support: String
    let remote: Bool
    var detail: String?
    var supportsConversation: Bool { mode == "conversation" && support == "native" && remote }
}

struct HarnessVoiceStatus: Codable {
    let capability: HarnessVoiceCapability
    let available: Bool
    var code: String?
    var detail: String?
    var voices: [String]?
}

struct HarnessVoiceAudio: Codable, Sendable {
    let data: Data
    var sampleRate = 24_000
    var channels = 1
}

struct HarnessVoiceEvent: Decodable, Sendable {
    let type: String
    var audio: HarnessVoiceAudio?
    var text: String?
    var role: String?
    var itemId: String?
    var final: Bool?
}
