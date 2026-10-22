import Foundation
import WidgetKit

/// A separate, coordinated inbox keeps notification-extension writes from racing the app's catalog.
/// It stores bounded status metadata, never the notification body or approval contents.
enum WidgetPushUpdates {
    private static var url: URL? {
        MindwireWidget.catalogURL?.deletingLastPathComponent().appendingPathComponent("widget-activity-v1.json")
    }

    static func read() -> [WidgetChatActivity] {
        guard let url else { return [] }
        var result: [WidgetChatActivity] = []
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { location in
            result = decode(location)
        }
        return result
    }

    @discardableResult
    static func record(data: [AnyHashable: Any], receivedAt: Date = .now) -> Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        guard data["appId"] == nil, data["target_type"] as? String != "app",
              let chatID = (data["chatId"] ?? data["chat_id"] ?? data["target_id"]) as? String,
              !chatID.isEmpty, chatID.count <= 1024, let condition = data["condition"] as? String else { return false }
        let state: WidgetWorkState
        switch condition {
        case "waiting_approval": state = .approval
        case "waiting_feedback", "waiting_input": state = .input
        case "finished": state = .finished
        case "error": state = .failed
        default: return false
        }
        let catalog = MindwireWidget.readCatalog()
        let known = catalog.activity?.first { $0.chatID == chatID }
        guard let botID = data["botId"] as? String ?? known?.botID,
              catalog.bots?.contains(where: { $0.id == botID }) == true, let url else { return false }
        let update = WidgetChatActivity(chatID: chatID, botID: botID, title: known?.title ?? "Open conversation",
                                       state: state, runID: data["runId"] as? String, observedAt: receivedAt)
        var changed = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: nil) { location in
            var rows = decode(location)
            if let previous = rows.first(where: { $0.id == chatID }) {
                if previous.observedAt >= update.observedAt || previous.sameContent(as: update) { return }
                if previous.runID == update.runID, [.finished, .failed, .stopped].contains(previous.state),
                   [.approval, .input].contains(update.state) { return }
            }
            rows.removeAll { $0.id == chatID || receivedAt.timeIntervalSince($0.observedAt) > 7 * 86400 }
            rows.append(update)
            rows = Array(rows.sorted { $0.observedAt > $1.observedAt }.prefix(64))
            do {
                try JSONEncoder().encode(rows).write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                changed = true
            } catch { /* Notification delivery must always continue. */ }
        }
        if changed { WidgetCenter.shared.reloadTimelines(ofKind: MindwireWidget.askKind) }
        return changed
        #endif
    }

    private static func decode(_ url: URL) -> [WidgetChatActivity] {
        guard let data = try? Data(contentsOf: url), data.count < 262_144,
              let rows = try? JSONDecoder().decode([WidgetChatActivity].self, from: data) else { return [] }
        return Array(rows.filter { Date().timeIntervalSince($0.observedAt) < 7 * 86400 }.prefix(64))
    }
}
