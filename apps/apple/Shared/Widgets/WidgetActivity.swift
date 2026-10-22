import Foundation

struct WidgetBot: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let artworkKey: String
    let artwork: Data?
}

enum WidgetWorkState: String, Codable, Sendable {
    case working, approval, input, finished, failed, stopped

    var needsAttention: Bool { self == .approval || self == .input || self == .failed }
    var priority: Int {
        switch self {
        case .approval, .input: 0
        case .failed: 1
        case .working: 2
        case .finished: 3
        case .stopped: 4
        }
    }
    var label: String {
        switch self {
        case .working: "Working"
        case .approval: "Needs approval"
        case .input: "Needs your reply"
        case .finished: "Finished"
        case .failed: "Needs attention"
        case .stopped: "Stopped"
        }
    }
    var symbol: String {
        switch self {
        case .working: "ellipsis"
        case .approval: "hand.raised.fill"
        case .input: "bubble.left.fill"
        case .finished: "checkmark"
        case .failed: "exclamationmark"
        case .stopped: "pause.fill"
        }
    }
}

/// Only display metadata. No transcript, commands, credentials or approval responses.
struct WidgetChatActivity: Codable, Equatable, Identifiable, Sendable {
    let chatID: String
    let botID: String
    let title: String
    let state: WidgetWorkState
    let runID: String?
    var observedAt: Date
    /// List summaries cannot tell whether an approval was answered. A loaded chat can.
    var canResolveAttention = false
    var id: String { chatID }
    var expiresAt: Date { observedAt.addingTimeInterval(5 * 60) }
    func isStale(at date: Date) -> Bool { date >= expiresAt }
    func label(at date: Date) -> String {
        guard isStale(at: date) else { return state.label }
        switch state {
        case .working: return "Last seen working"
        case .approval: return "Approval requested"
        case .input: return "Reply requested"
        default: return state.label
        }
    }

    func sameContent(as other: Self) -> Bool {
        var copy = self
        copy.observedAt = other.observedAt
        return copy == other
    }
}

struct WidgetAssistantSnapshot: Equatable, Sendable {
    var artwork: Data?
    var bots: [WidgetBot] = []
    var activity: [WidgetChatActivity] = []

    init(catalog: WidgetCatalog = WidgetCatalog(), updates: [WidgetChatActivity] = []) {
        artwork = catalog.assistantArtwork
        bots = catalog.bots ?? []
        let botIDs = Set(bots.map(\.id))
        var rows = Dictionary((catalog.activity ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for update in updates where botIDs.contains(update.botID) {
            if let current = rows[update.id] {
                // A fresh observation from a different run wins over an unsequenced push.
                if let run = current.runID, let incoming = update.runID, run != incoming,
                   !current.isStale(at: .now) { continue }
                // Never let a delayed approval reopen a terminal run.
                if current.runID == update.runID, [.finished, .failed, .stopped].contains(current.state),
                   [.approval, .input, .working].contains(update.state) { continue }
                if current.observedAt >= update.observedAt {
                    let unresolved = current.runID == update.runID && current.state == .working
                        && !current.canResolveAttention && update.state.needsAttention
                    if !unresolved { continue }
                }
            }
            rows[update.id] = update
        }
        var seenBots = Set<String>()
        activity = rows.values.filter {
            botIDs.contains($0.botID) && ($0.state == .approval || $0.state == .input || $0.state == .working || Date().timeIntervalSince($0.observedAt) < 86400)
        }.sorted {
            if $0.state.priority != $1.state.priority { return $0.state.priority < $1.state.priority }
            return $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt > $1.observedAt
        }.filter { seenBots.insert($0.botID).inserted }
    }

    var focus: WidgetChatActivity? { activity.first }
    func bot(for activity: WidgetChatActivity) -> WidgetBot? { bots.first { $0.id == activity.botID } }
    var destination: URL { focus.map { WidgetLink.chat($0.chatID).url } ?? WidgetLink.ask.url }
    var attentionCount: Int { activity.filter { $0.state.needsAttention }.count }
    var workingCount: Int { activity.filter { $0.state == .working }.count }
}
