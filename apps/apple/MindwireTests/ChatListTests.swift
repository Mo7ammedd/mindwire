import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class ChatListTests: XCTestCase {
    func testRelativeChatTimeUsesLatestNativeActivityAcrossDateFormats() throws {
        let activity = ChatActivityStore()
        let chat = Chat(id: "native", agentId: "codex", projectId: "project", title: "From this Mac",
                        createdAt: "2026-09-01T10:00:00Z", updatedAt: "2026-09-25T06:00:00.123456789Z")
        let now = try XCTUnwrap(RelativeTime.date("2026-09-25T12:00:00Z"))
        XCTAssertEqual(RelativeTime.text(try XCTUnwrap(activity.lastActivity(chat)), now: now), "5h ago")
        activity.receive([.init(chatId: chat.id, updatedAt: "2026-09-25T10:00:00Z")], workspaceId: "workspace")
        XCTAssertEqual(RelativeTime.text(try XCTUnwrap(activity.lastActivity(chat)), now: now), "2h ago")
        XCTAssertEqual(RelativeTime.text(now.addingTimeInterval(-6 * 3600), now: now), "6h ago")
        XCTAssertEqual(RelativeTime.text(now.addingTimeInterval(-2 * 86400), now: now), "2d ago")
        XCTAssertEqual(RelativeTime.text(now.addingTimeInterval(60), now: now), "just now")
        XCTAssertNil(RelativeTime.date("invalid date"))
        for (seconds, expected) in [(1, "1s"), (59, "59s"), (60, "1m"), (3599, "59m"), (3600, "1h"), (86400, "24h")] {
            XCTAssertEqual(RelativeTime.elapsed(now.addingTimeInterval(-Double(seconds)), now: now), expected)
        }
        XCTAssertEqual(RelativeTime.elapsed(now.addingTimeInterval(60), now: now), "0s")
    }

    private func stores() throws -> Stores {
        let suite = "chat-list-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func session(_ channel: ChatListChannel) -> DaemonSession {
        DaemonSession(agentId: UUID().uuidString,
                      transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
    }

    func testPreviewReadsRecentHistoryAndSnapshotWithoutPreparingOrSubscribing() async throws {
        let channel = ChatListChannel()
        let session = session(channel)
        let preview = try await session.readChatPreview("chat")
        let run = try await session.readRunActivity("run")
        XCTAssertEqual(run.createdAt, "2026-09-16T01:00:00Z")
        XCTAssertEqual(preview.map(\.role), [.user, .assistant])
        XCTAssertEqual(preview.last?.parts?.first?.text, "Current response from snapshot")
        XCTAssertEqual(preview.last?.parts?.compactMap(\.tool).count, 1)
        let requests = await channel.requests
        XCTAssertEqual(Set(requests), Set([
            "GET /chats/chat/messages?limit=6&paged=true&maxBytes=1048576&agent=codex",
            "GET /chats/chat/run?agent=codex",
            "GET /runs/run/snapshot?agent=codex",
            "GET /runs/run?agent=codex"
        ]), "Preview must only make bounded reads; no /setup, /healthz or /stream")
    }

    func testFailedDeleteRetainsChatThenRetryStopsRunAndRemovesBothRecords() async throws {
        let stores = try stores()
        let chat = stores.createChat(agentId: "agent", projectId: "project", title: "Keep until confirmed")
        let channel = ChatListChannel()
        await channel.failNextDelete()
        let session = session(channel)
        let actions = ChatListActions()
        let activity = ChatActivityStore()
        activity.receive([DaemonChatSummary(chatId: chat.id, lastStatus: "running", lastRunId: "run")], workspaceId: "workspace")
        do {
            try await actions.delete(chat, stores: stores, session: session, activity: activity)
            XCTFail("Expected the server to reject the first delete")
        } catch {}
        XCTAssertNotNil(stores.chats.get(chat.id))
        XCTAssertTrue(actions.pending.isEmpty)
        try await actions.delete(chat, stores: stores, session: session, activity: activity)
        XCTAssertNil(stores.chats.get(chat.id))
        XCTAssertNil(activity.status(chat.id))
        activity.receive([DaemonChatSummary(chatId: chat.id, lastStatus: "running")], workspaceId: "workspace", since: [:])
        XCTAssertNil(activity.status(chat.id), "A pre-delete list read cannot resurrect the row")
        let requests = await channel.requests
        let cancel = try XCTUnwrap(requests.firstIndex(of: "POST /runs/run/cancel?agent=codex"))
        let deletion = try XCTUnwrap(requests.firstIndex(where: { $0.hasPrefix("DELETE ") }))
        XCTAssertLessThan(cancel, deletion)
        XCTAssertEqual(requests.filter { $0 == "POST /runs/run/cancel?agent=codex" }.count, 1)
    }

    func testDuplicateDeleteSharesPendingMutationAndRenameCommitsOnlyOnSuccess() async throws {
        let stores = try stores()
        let chat = stores.createChat(agentId: "agent", projectId: "project", title: "Before")
        let channel = ChatListChannel()
        let session = session(channel)
        let actions = ChatListActions()
        await channel.failNextRename()
        do { try await actions.rename(chat, title: "After", stores: stores, session: session); XCTFail() } catch {}
        XCTAssertEqual(stores.chats.get(chat.id)?.title, "Before")
        try await actions.rename(chat, title: "After", stores: stores, session: session)
        XCTAssertEqual(stores.chats.get(chat.id)?.title, "After")
        XCTAssertEqual(stores.chats.get(chat.id)?.titleIsUserSet, true)

        await channel.holdDelete()
        let first = Task { try await actions.delete(chat, stores: stores, session: session) }
        for _ in 0..<200 {
            if await channel.deletePending { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(actions.pending.contains(chat.id))
        try await actions.delete(chat, stores: stores, session: session)
        let pendingRequests = await channel.requests
        XCTAssertEqual(pendingRequests.filter { $0.hasPrefix("DELETE ") }.count, 1)
        await channel.releaseDelete()
        try await first.value
        XCTAssertNil(stores.chats.get(chat.id))
    }

    func testProjectHistoryIncludesOlderChatsAndExcludesOtherProjects() async throws {
        let stores = try stores()
        let codex = stores.createAgent(.init(name: "Codex", agentType: .codex, workspaceId: "workspace"))
        let claude = stores.createAgent(.init(name: "Claude", agentType: .claudeCode, workspaceId: "workspace"))
        for index in 0..<9 {
            let chat = Chat(id: UUID().uuidString, agentId: index.isMultiple(of: 2) ? codex.id : claude.id,
                projectId: "project", title: index == 0 ? "Original project chat" : "Project chat \(index)",
                createdAt: "2026-09-24T10:00:0\(index)Z")
            stores.chats.save(chat)
            if index == 8 {
                ChatActivityStore.shared.record(.init(id: "clock", chatId: chat.id, status: .running,
                    createdAt: Date.now.addingTimeInterval(-75).ISO8601Format()))
                addTeardownBlock { @MainActor in ChatActivityStore.shared.remove(chat.id) }
            }
        }
        stores.createChat(agentId: codex.id, projectId: "elsewhere", title: "Different project chat")
        let host = UIHostingController(rootView: ChatHistorySheet(projectId: "project")
            .environment(\.stores, stores).environment(AppModel(stores: stores))
            .environment(\.scenePhase, .inactive))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(400))
        let initialImage = ChatFeedSnapshot.image(host)
        try initialImage.pngData()?.write(to: URL(fileURLWithPath: "/tmp/mindwire-chat-elapsed-time.png"))
        let initial = try ChatFeedSnapshot.visibleText(in: initialImage)
        XCTAssertTrue(initial.contains("Project chat 8"), initial)
        XCTAssertTrue(initial.contains("1m"), initial)
        XCTAssertFalse(initial.contains(t("chat.running")), initial)
        XCTAssertFalse(initial.contains("Different project chat"), initial)
        func scroll(in view: UIView) -> UIScrollView? {
            (view as? UIScrollView) ?? view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scroll(in: host.view))
        scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
        try await Task.sleep(for: .milliseconds(200))
        let image = ChatFeedSnapshot.image(host)
        let text = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(text.contains("Original project chat"), "History must include chats beyond the three recent rows: \(text)")
        XCTAssertFalse(text.contains("Different project chat"), text)
        let attachment = XCTAttachment(image: image)
        attachment.name = "mindwire-project-full-chat-history"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPreviewStartsAtLatestContentWithCollapsedToolCards() async throws {
        let parts: [DaemonMessagePart] = [
            .init(kind: .tool, tool: DaemonToolCall(id: "shell", name: "shell", output: String(repeating: "Log output\n", count: 100),
                action: DaemonToolAction(kind: "shell", shell: DaemonShellCommand(command: "swift build")))),
            .init(kind: .tool, tool: DaemonToolCall(id: "file", name: "apply_patch", action: DaemonToolAction(kind: "file_edit",
                files: [DaemonFileChange(path: "App.swift", op: "add", diff: "+private detail\n")]))),
            .init(kind: .text, text: "Latest response")
        ]
        let messages = (0..<8).map { DaemonMessage(id: "\($0)", chatId: "chat", role: .user,
            text: "An older question \($0)", createdAt: "") } + [
                DaemonMessage(id: "last", chatId: "chat", role: .assistant, text: "Latest response", createdAt: "", parts: parts)
            ]
        let host = UIHostingController(rootView: ChatPreviewContent(title: "Project chat", agent: nil, messages: messages))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 330, height: 420))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        host.view.layoutIfNeeded()
        func scroll(in view: UIView) -> UIScrollView? {
            (view as? UIScrollView) ?? view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scroll(in: host.view))
        XCTAssertLessThanOrEqual(scroll.contentSize.height - scroll.contentOffset.y - scroll.bounds.height, 5)
        XCTAssertLessThan(scroll.contentSize.height, 1500, "Tool output must stay collapsed in previews")
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let visible = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(visible.contains("Latest response"), "The preview's latest answer must fit inside its visible bounds: \(visible)")
        XCTAssertFalse(visible.contains("Log output"), "Shell output stays collapsed")
        XCTAssertFalse(visible.contains("private detail"), "File diffs stay collapsed")
        let header = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: 0, y: 0,
            width: image.size.width * image.scale, height: 45 * image.scale)))
        let headerText = try ChatFeedSnapshot.visibleText(in: UIImage(cgImage: header))
        XCTAssertFalse(headerText.contains("older question"), "Scrolled content must not draw over the preview header")
        let attachment = XCTAttachment(image: image)
        attachment.name = "Native chat preview at latest response"
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mindwire-chat-preview.png"))
    }
}

private actor ChatListChannel: DaemonChannel {
    nonisolated let label = "chat-list-fixture"
    private(set) var requests: [String] = []
    private var run = DaemonRun(id: "run", chatId: "chat", status: .running, replyId: "reply", createdAt: "2026-09-16T01:00:00Z")
    private var deleteFails = false
    private var renameFails = false
    private var hold = false
    private var deleteGate: CheckedContinuation<Void, Never>?
    var deletePending: Bool { deleteGate != nil }
    func failNextDelete() { deleteFails = true }
    func failNextRename() { renameFails = true }
    func holdDelete() { hold = true }
    func releaseDelete() { hold = false; deleteGate?.resume(); deleteGate = nil }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        requests.append("\(method) \(path)")
        let route = URLComponents(string: path)?.path ?? path
        if method == "GET", route.hasSuffix("/messages") {
            return try response([
                DaemonMessage(id: "user", chatId: "chat", role: .user, text: "Build an app", createdAt: run.createdAt),
                DaemonMessage(id: "reply", chatId: "chat", role: .assistant, text: "Current response", createdAt: run.createdAt,
                    parts: [.init(kind: .text, text: "Current response")])
            ])
        }
        if method == "GET", route.hasSuffix("/snapshot") {
            return try response(DaemonRunSnapshot(run: run, sequence: 2, parts: [
                .init(kind: .text, text: "Current response from snapshot"),
                .init(kind: .tool, tool: DaemonToolCall(id: "file", name: "apply_patch"))
            ]))
        }
        if method == "GET", route.hasSuffix("/run") || route == "/runs/run" { return try response(run) }
        if method == "POST", route == "/runs/run/cancel" { run.status = .cancelled; return (200, "{}") }
        if method == "DELETE" {
            if hold { await withCheckedContinuation { deleteGate = $0 } }
            if deleteFails { deleteFails = false; return (409, #"{"error":"Delete rejected"}"#) }
            return (200, #"{"deleted":true}"#)
        }
        if method == "PUT" {
            if renameFails { renameFails = false; return (400, #"{"error":"Rename rejected"}"#) }
            return try response(DaemonChatSummary(chatId: "chat", title: "After"))
        }
        throw URLError(.unsupportedURL)
    }

    private func response<T: Encodable>(_ value: T) throws -> (Int, String) {
        (200, String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }
}
