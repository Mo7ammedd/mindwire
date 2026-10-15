import XCTest
@testable import Mindwire

@MainActor
final class ChatDraftTests: XCTestCase {
    private func defaults() throws -> DraftCountingDefaults {
        let suite = "chat-drafts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DraftCountingDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testTypingAndReopeningUseMemoryAndOnlyDirtyDraftsAreWrittenOnPersist() throws {
        let defaults = try defaults()
        let store = ChatDraftStore(defaults: defaults)
        let draft = store.draft(for: "chat")
        for index in 0..<1_000 {
            draft.text = "Unsent message \(index)"
            XCTAssertTrue(store.draft(for: "chat") === draft)
        }
        XCTAssertEqual(defaults.reads, 1, "Opening an already cached draft cannot reread storage")
        XCTAssertEqual(defaults.writes, 0, "Typing must not write, encode or schedule persistence")
        store.persist("chat")
        XCTAssertEqual(defaults.writes, 1)
        for _ in 0..<10 { store.persist("chat") }
        XCTAssertEqual(defaults.writes, 1, "Unchanged disappearance/background callbacks must not repeat the write")
        XCTAssertEqual(ChatDraftStore(defaults: defaults).draft(for: "chat").text, "Unsent message 999")
    }

    func testSeparateChatsAndRelaunchPreserveExactMultilineText() throws {
        let defaults = try defaults()
        let store = ChatDraftStore(defaults: defaults)
        let text = "  Fix this function\nمرحبا 👋\nlet value = 3\n"
        store.draft(for: "first").text = text
        store.draft(for: "second").text = "A different unfinished request"
        store.persist("first")
        store.persist("second")
        let relaunched = ChatDraftStore(defaults: defaults)
        XCTAssertEqual(relaunched.draft(for: "first").text, text)
        XCTAssertEqual(relaunched.draft(for: "second").text, "A different unfinished request")
        XCTAssertEqual(relaunched.draft(for: "third").text, "")
        relaunched.persist("third")
        XCTAssertEqual(defaults.writes, 2, "Opening an empty composer must not create a stored record")
    }

    func testAcceptedSubmissionClearsTheSharedDraftAndItsPersistedText() throws {
        let defaults = try defaults()
        let store = ChatDraftStore(defaults: defaults)
        let originalScreen = store.draft(for: "chat")
        originalScreen.text = "Send this request"
        store.persist("chat")
        let submittedRevision = originalScreen.revision
        let reopenedScreen = store.draft(for: "chat")
        XCTAssertTrue(originalScreen.clearSubmitted(revision: submittedRevision))
        store.persist("chat")
        XCTAssertEqual(reopenedScreen.text, "", "A late acknowledgement must also clear the current screen")
        XCTAssertNil(defaults.string(forKey: ChatDraftStore.key("chat")))
        XCTAssertEqual(ChatDraftStore(defaults: defaults).draft(for: "chat").text, "")
    }

    func testClearingOrDeletingUnpersistedDraftsDoesNotWriteEmptyRecords() throws {
        let defaults = try defaults()
        let store = ChatDraftStore(defaults: defaults)
        let draft = store.draft(for: "chat")
        draft.text = "Changed my mind"
        draft.text = ""
        store.persist("chat")
        store.remove("chat")
        for index in 0..<100 { store.remove("never-opened-\(index)") }
        XCTAssertEqual(defaults.writes, 0)
    }

    func testTypingAfterSubmissionSurvivesItsLateAcknowledgement() throws {
        let defaults = try defaults()
        let store = ChatDraftStore(defaults: defaults)
        let draft = store.draft(for: "chat")
        draft.text = "First request"
        let submittedRevision = draft.revision
        store.draft(for: "chat").text = "Next request typed while sending"
        XCTAssertFalse(draft.clearSubmitted(revision: submittedRevision))
        store.persist("chat")
        XCTAssertEqual(ChatDraftStore(defaults: defaults).draft(for: "chat").text, "Next request typed while sending")
    }

    func testEditingBackToTheSameTextStillProtectsTheNewDraftFromAnOldAcknowledgement() throws {
        let store = ChatDraftStore(defaults: try defaults())
        let draft = store.draft(for: "chat")
        draft.text = "Repeat this request"
        let submittedRevision = draft.revision
        draft.text = "A new draft"
        draft.text = "Repeat this request"
        XCTAssertFalse(draft.clearSubmitted(revision: submittedRevision))
        XCTAssertEqual(draft.text, "Repeat this request")
    }

    func testTranscriptEvictionDoesNotEvictDraftsAndChatDeletionCannotRestoreThem() throws {
        let defaults = try defaults()
        let stores = Stores(defaults: defaults)
        let chat = stores.createChat(agentId: "agent", projectId: "project")
        let draft = stores.chatDrafts.draft(for: chat.id)
        draft.text = "Keep this while the transcript is evicted"
        stores.chatDrafts.persist(chat.id)
        _ = stores.chatSessions.model(for: chat.id)
        stores.chatSessions.remove(chat.id)
        XCTAssertTrue(stores.chatDrafts.draft(for: chat.id) === draft)
        XCTAssertEqual(draft.text, "Keep this while the transcript is evicted")
        stores.deleteChat(chat.id)
        XCTAssertEqual(draft.text, "")
        draft.text = "A late callback from the deleted screen"
        stores.chatDrafts.persist(chat.id)
        XCTAssertNil(defaults.string(forKey: ChatDraftStore.key(chat.id)))
        XCTAssertEqual(ChatDraftStore(defaults: defaults).draft(for: chat.id).text, "")
    }
}

/// Real isolated defaults with I/O counters, so performance assertions cover actual
/// calls to persistence rather than a duplicate implementation of draft storage.
private final class DraftCountingDefaults: UserDefaults {
    private(set) var reads = 0
    private(set) var writes = 0

    override func string(forKey defaultName: String) -> String? {
        reads += 1
        return super.string(forKey: defaultName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        writes += 1
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        writes += 1
        super.removeObject(forKey: defaultName)
    }
}
