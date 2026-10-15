import Foundation
import Observation

/// Keep mutations ordered across duplicate rows/sheets. Local navigation records are removed only
/// after the daemon acknowledges deletion; a failed request leaves the chat available to retry.
@MainActor @Observable
final class ChatListActions {
    static let shared = ChatListActions()
    private(set) var pending: Set<String> = []

    func rename(_ chat: Chat, title: String, stores: Stores, session: DaemonSession? = nil) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, pending.insert(chat.id).inserted else { return }
        defer { pending.remove(chat.id) }
        let session = session ?? DaemonManager.shared.session(for: chat.agentId, stores: stores)
        _ = try await session.renameChat(chat.id, title: title)
        stores.renameChat(chat.id, title: title)
    }

    func delete(_ chat: Chat, stores: Stores, session: DaemonSession? = nil,
                activity: ChatActivityStore? = nil) async throws {
        guard pending.insert(chat.id).inserted else { return }
        defer { pending.remove(chat.id) }
        let session = session ?? DaemonManager.shared.session(for: chat.agentId, stores: stores)
        try await session.deleteChat(chat.id, stopRunning: true)
        stores.deleteChat(chat.id)
        (activity ?? .shared).remove(chat.id)
    }
}
