import XCTest
import Observation
import os
@testable import Mindwire

@MainActor
final class ChatActivityTests: XCTestCase {
    func testPreviewIsBoundedWhileFullHistoryKeepsEveryRunningChat() {
        let activity = ChatActivityStore()
        let chats = (0..<7).map {
            Chat(id: "chat-\($0)", agentId: "agent", projectId: "project", title: "Chat \($0)",
                 createdAt: "2026-09-14T10:0\($0):00Z")
        }
        activity.receive(chats.prefix(5).map {
            DaemonChatSummary(chatId: $0.id, lastStatus: "running", lastRunId: "run-\($0.id)")
        }, workspaceId: "workspace")
        XCTAssertEqual(activity.ordered(chats, limit: 3).map(\.id), ["chat-4", "chat-3", "chat-2"])
        XCTAssertEqual(activity.ordered(chats).prefix(5).map(\.id), ["chat-4", "chat-3", "chat-2", "chat-1", "chat-0"])
        XCTAssertEqual(activity.ordered(chats).suffix(2).map(\.id), ["chat-6", "chat-5"])
    }

    func testNewRunResponseWinsOverAnEarlierInFlightListRead() {
        let activity = ChatActivityStore()
        activity.receive([DaemonChatSummary(chatId: "chat", lastStatus: "done", lastRunId: "old")], workspaceId: "workspace")
        activity.record(DaemonRun(id: "new", chatId: "chat", status: .running, createdAt: "2026-09-14T10:01:00Z"), workspaceId: "workspace")
        activity.receive([DaemonChatSummary(chatId: "chat", lastStatus: "done", lastRunId: "old")],
                         workspaceId: "workspace", since: [:])
        XCTAssertEqual(activity.status("chat"), .running)
        XCTAssertEqual(activity.summaries["chat"]?.lastRunId, "new")
        activity.receive([], workspaceId: "workspace", since: [:])
        XCTAssertEqual(activity.status("chat"), .running, "Stale empty snapshots cannot remove an accepted run")
    }

    func testUnchangedActivityDoesNotInvalidateChatLists() {
        let activity = ChatActivityStore()
        let run = DaemonRun(id: "run", chatId: "chat", status: .running, createdAt: "2026-09-14T10:00:00Z")
        activity.record(run, workspaceId: "workspace")
        let snapshot = Array(activity.summaries.values)
        let invalidations = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = activity.summaries
            _ = activity.runStartedAt("chat")
        } onChange: { invalidations.withLock { $0 += 1 } }
        activity.receive(snapshot, workspaceId: "workspace")
        activity.record(run, workspaceId: "workspace")
        XCTAssertEqual(invalidations.withLock { $0 }, 0, "Unchanged activity stays cached")

        activity.record(DaemonRun(id: run.id, chatId: run.chatId, status: .done, createdAt: run.createdAt,
                                 endedAt: "2026-09-14T10:01:00Z"))
        XCTAssertEqual(invalidations.withLock { $0 }, 1, "New activity still updates the UI")
    }

    func testOldObserverCannotReplaceANewerRunOrRegressATerminalRun() {
        let activity = ChatActivityStore()
        activity.receive([DaemonChatSummary(chatId: "chat", updatedAt: "2026-09-14T10:01:00Z",
            lastStatus: "running", lastRunId: "new")], workspaceId: "workspace")
        activity.record(DaemonRun(id: "old", chatId: "chat", status: .done, createdAt: "2026-09-14T10:00:00Z",
                                 endedAt: "2026-09-14T10:00:30Z"))
        XCTAssertEqual(activity.summaries["chat"]?.lastRunId, "new")
        activity.record(DaemonRun(id: "new", chatId: "chat", status: .done, createdAt: "2026-09-14T10:01:00Z",
                                 endedAt: "2026-09-14T10:02:00Z"))
        activity.record(DaemonRun(id: "new", chatId: "chat", status: .running, createdAt: "2026-09-14T10:01:00Z"))
        XCTAssertEqual(activity.status("chat"), .done)
    }

    func testElapsedClockCachesNativeStartAndRejectsAnOlderRunRead() async throws {
        let activity = ChatActivityStore()
        let start = "2026-09-14T10:00:00Z"
        var summary = DaemonChatSummary(chatId: "chat", updatedAt: "2026-09-14T10:05:00Z",
            lastStatus: "running", lastRunId: "one")
        var reads = 0
        activity.receive([summary], workspaceId: "workspace")
        XCTAssertNil(activity.runStartedAt("chat"), "The last message/rename date is not the run start")
        await activity.refreshRunStarts([summary]) { id in
            reads += 1
            return .init(id: id, chatId: "chat", status: .running, createdAt: start)
        }
        XCTAssertEqual(activity.runStartedAt("chat"), RelativeTime.date(start))

        summary.updatedAt = "2026-09-14T10:06:00Z"
        activity.receive([summary], workspaceId: "workspace")
        await activity.refreshRunStarts([summary]) { _ in
            reads += 1
            throw URLError(.unsupportedURL)
        }
        XCTAssertEqual(reads, 1, "List refreshes reuse the start already known for this run")
        XCTAssertEqual(activity.runStartedAt("chat"), RelativeTime.date(start))

        summary.lastRunId = "two"
        activity.receive([summary], workspaceId: "workspace")
        XCTAssertNil(activity.runStartedAt("chat"), "The next run must not inherit the previous clock")
        var newer = DaemonRun(id: "three", chatId: "chat", status: .running, createdAt: "2026-09-14T10:08:00Z")
        await activity.refreshRunStarts([summary]) { id in
            activity.record(newer)
            return .init(id: id, chatId: "chat", status: .running, createdAt: "2026-09-14T10:07:00Z")
        }
        XCTAssertEqual(activity.runStartedAt("chat"), RelativeTime.date(newer.createdAt))
        newer.status = .done
        activity.record(newer)
        XCTAssertNil(activity.runStartedAt("chat"), "Completed runs no longer display a live clock")
    }

    func testWorkspaceSnapshotsAndAgentOwnershipStayIsolated() throws {
        let suite = "chat-activity-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        stores.chats.save(Chat(id: "a", agentId: "codex", projectId: "first", title: "Draft", createdAt: ""))
        stores.chats.save(Chat(id: "b", agentId: "claude", projectId: "second", title: "Named", createdAt: "", titleIsUserSet: true))
        let activity = ChatActivityStore()
        activity.receive([DaemonChatSummary(chatId: "a", title: "Build an app", lastStatus: "running")], workspaceId: "one")
        activity.receive([DaemonChatSummary(chatId: "b", title: "Daemon title", lastStatus: "done")], workspaceId: "two")
        XCTAssertTrue(activity.isRunning(agentId: "codex", stores: stores))
        XCTAssertFalse(activity.isRunning(agentId: "claude", stores: stores))
        XCTAssertFalse(activity.isRunning(agentId: "codex", stores: stores, projectId: "second"))
        XCTAssertEqual(activity.title(try XCTUnwrap(stores.chats.get("a"))), "Build an app")
        XCTAssertEqual(activity.title(try XCTUnwrap(stores.chats.get("b"))), "Named")
        activity.receive([], workspaceId: "two")
        XCTAssertEqual(activity.status("a"), .running)
        XCTAssertNil(activity.status("b"))
    }
}
