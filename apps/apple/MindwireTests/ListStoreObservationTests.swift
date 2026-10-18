import XCTest
import Observation
@testable import Mindwire

@MainActor
final class ListStoreObservationTests: XCTestCase {
    func testMetadataReadsAndIdenticalSavesDoNotInvalidateAWindow() {
        let suite = "metadata-observation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = JSONListStore<Chat>(key: "chats", defaults: defaults)
        let chat = Chat(id: "chat", agentId: "agent", projectId: "project", title: "Hello", createdAt: "today")
        store.save(chat)
        let revision = store.revision
        for _ in 0..<100 {
            _ = store.list()
            _ = store.get(chat.id)
            store.save(chat)
        }
        XCTAssertEqual(store.revision, revision)
        var renamed = chat
        renamed.title = "Updated title"
        store.save(renamed)
        XCTAssertEqual(store.revision, revision + 1)
        XCTAssertEqual(store.get(chat.id)?.title, "Updated title")
    }

    func testAChangedListNotifiesTheDesktopWithoutPolling() {
        let suite = "metadata-observation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = JSONListStore<Chat>(key: "chats", defaults: defaults)
        let changed = expectation(description: "Metadata change invalidates its observer")
        withObservationTracking { _ = store.revision } onChange: { changed.fulfill() }
        store.save(.init(id: "chat", agentId: "agent", projectId: "project", title: "New chat", createdAt: "today"))
        wait(for: [changed], timeout: 1)
    }
}
