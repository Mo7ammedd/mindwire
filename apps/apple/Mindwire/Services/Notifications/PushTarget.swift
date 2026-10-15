import Foundation

/// FCM normally flattens custom data into userInfo. Other relays nest it or JSON-encode it.
/// Shared with the notification extension so presentation and navigation read the same metadata.
enum PushPayload {
    static func data(from payload: [AnyHashable: Any]) -> [AnyHashable: Any] {
        var data = payload
        var nested = payload["data"] as? [AnyHashable: Any]
        if nested == nil, let json = payload["data"] as? String, let bytes = json.data(using: .utf8) {
            nested = (try? JSONSerialization.jsonObject(with: bytes)) as? [AnyHashable: Any]
        }
        data.merge(nested ?? [:]) { _, value in value }
        return data
    }
}

/// Deep-link target carried in a push notification's payload, so tapping a notification opens the
/// exact thing that triggered it. The sender (the workspace daemon via `/notifications/send`) sets
/// `target_type` + `target_id` in the message data; the app parses it on tap and routes through
/// `AppModel.open(_:)`. Keep this contract in sync with the sender.
enum PushTarget: Hashable {
    case chat(String)
    case project(String)
    case agent(String)
    case workspace(String)

    /// Payload keys the sender must set.
    enum Key {
        static let type = "target_type"   // "chat" | "project" | "agent" | "workspace"
        static let id = "target_id"
    }

    /// Parse from an APNs/FCM `userInfo`. Accepts the meta at the top level or nested under a
    /// `data` object (FCM data messages put custom keys there).
    init?(payload: [AnyHashable: Any]) {
        let data = PushPayload.data(from: payload)
        func value(_ key: String) -> String? {
            guard let value = (data[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        if let type = value(Key.type), let id = value(Key.id) {
            switch type {
            case "chat":    self = .chat(id)
            case "project": self = .project(id)
            case "agent":   self = .agent(id)
            case "workspace", "sandbox": self = .workspace(id)
            default:        return nil
            }
        } else if let id = value("chatId") ?? value("chat_id") {
            self = .chat(id)
        } else if let id = value("workspace_id") ?? value("channel") {
            self = .workspace(id)
        } else {
            return nil
        }
    }
}
