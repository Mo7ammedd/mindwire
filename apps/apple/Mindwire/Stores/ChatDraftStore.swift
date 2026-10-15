import Foundation
import Observation

/// Composer text is independent of transcript caching and observes only its own chat.
@MainActor
@Observable
final class ChatDraft {
    var text: String {
        didSet { if text != oldValue { revision &+= 1 } }
    }
    @ObservationIgnored private(set) var revision: UInt64 = 0
    @ObservationIgnored fileprivate var savedRevision: UInt64 = 0

    init(text: String = "") { self.text = text }

    /// An acknowledgement from an older screen must not erase newer typing.
    @discardableResult
    func clearSubmitted(revision submittedRevision: UInt64) -> Bool {
        guard revision == submittedRevision else { return false }
        text = ""
        return true
    }
}

/// Lazy per-chat reads; typing changes memory only. Navigation/backgrounding flushes
/// one dirty string rather than encoding all drafts or scheduling work per keystroke.
@MainActor
final class ChatDraftStore {
    private let defaults: UserDefaults
    private var drafts: [String: ChatDraft] = [:]
    static func key(_ chatId: String) -> String { "mindwire:chat-draft:v1:" + chatId }

    init(defaults: UserDefaults) { self.defaults = defaults }

    func draft(for chatId: String) -> ChatDraft {
        if let draft = drafts[chatId] { return draft }
        let draft = ChatDraft(text: defaults.string(forKey: Self.key(chatId)) ?? "")
        drafts[chatId] = draft
        return draft
    }

    func persist(_ chatId: String) {
        guard let draft = drafts[chatId], draft.revision != draft.savedRevision else { return }
        if draft.text.isEmpty { removePersisted(chatId) }
        else { defaults.set(draft.text, forKey: Self.key(chatId)) }
        draft.savedRevision = draft.revision
    }

    func remove(_ chatId: String) {
        // Shared screens lose the deleted text too. A late disappearance cannot save
        // this discarded object back into the store.
        drafts.removeValue(forKey: chatId)?.text = ""
        removePersisted(chatId)
    }

    private func removePersisted(_ chatId: String) {
        let key = Self.key(chatId)
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
    }
}
