import Foundation

/// Reads the same activity store and pending interactions used by chat. No extra connections,
/// history fetches, transcript copies, timers or per-token writes are needed for a widget.
@MainActor
enum WidgetActivityProjection {
    static func read(stores: Stores) -> [WidgetChatActivity] {
        let activity = ChatActivityStore.shared
        let botIDs = Set(stores.bots.list().filter { !$0.archived }.map(\.id))
        return stores.chats.list().compactMap { chat -> WidgetChatActivity? in
            guard let botID = chat.botId, botIDs.contains(botID) else { return nil }
            let model = stores.chatSessions.cached(chat.id)
            let requests = model?.pendingInteractions ?? []
            let state: WidgetWorkState
            if requests.contains(where: { ["approval", "plan"].contains($0.interaction.kind) }) { state = .approval }
            else if !requests.isEmpty { state = .input }
            else {
                switch activity.status(chat.id) {
                case .running: state = .working
                case .done: state = .finished
                case .error: state = .failed
                case .cancelled: state = .stopped
                case nil: return nil
                }
            }
            return WidgetChatActivity(chatID: chat.id, botID: botID,
                title: String(activity.title(chat).prefix(160)), state: state,
                runID: model?.transcriptRunID ?? activity.summaries[chat.id]?.lastRunId,
                observedAt: activity.lastActivity(chat) ?? .distantPast,
                canResolveAttention: model?.hasLoadedHistory == true && model?.catchingUp == false && model?.reconnecting == false)
        }.sorted {
            if $0.state.priority != $1.state.priority { return $0.state.priority < $1.state.priority }
            return $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt > $1.observedAt
        }
    }
}
