import SwiftUI
import XCTest
@testable import Mindwire

@MainActor
final class ChatForkTests: XCTestCase {
    private let message = DaemonMessage(id: "native-message", chatId: "source", role: .user,
        text: "Original prompt", createdAt: "2026-10-01T10:00:00Z", canFork: true)

    func testDuplicateTapsShareOneBranchAndCompletedDraftCannotResend() async throws {
        var requests: [ChatForkDraft.Submission] = []
        var release: CheckedContinuation<Void, Never>?
        let draft = ChatForkDraft(message: message) { request in
            requests.append(request)
            await withCheckedContinuation { release = $0 }
            return request.chatId
        }
        draft.text = "Edited prompt"
        let first = Task { await draft.send() }
        while release == nil { await Task.yield() }
        let duplicate = await draft.send()
        XCTAssertNil(duplicate)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(draft.submitting)
        release?.resume()
        let id = await first.value
        let replay = await draft.send()
        XCTAssertEqual(id, replay)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(message.text, "Original prompt")
    }

    func testForkAndResendApplyAuthoritativeCacheAndRecoverLostSendReceipt() async throws {
        let suite = "fork-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let channel = ChatForkChannel()
        try stores.workspaceData.apply(await channel.snapshot(), workspaceId: "connection")
        let source = try XCTUnwrap(stores.chats.get("source"))
        let activity = ChatActivityStore()
        let session = DaemonSession(agentId: "profile", transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        let model = ChatModel(chatId: source.id, session: session, activity: activity, stores: stores)
        defer { model.dispose() }
        var imagePrompt = message
        imagePrompt.attachments = [.init(name: "context.png", mime: "image/png", data: Data([1, 2, 3]))]
        let draft = model.forkDraft(for: imagePrompt)
        draft.text = "Use the new design"
        let failed = await draft.send()
        XCTAssertNil(failed)
        XCTAssertNotNil(draft.error)
        XCTAssertTrue(model.forkDraft(for: imagePrompt) === draft, "Closing and reopening the sheet must retain receipts")
        draft.text = "A changed retry must not double-submit"
        let submittedId = await draft.send()
        let id = try XCTUnwrap(submittedId)
        XCTAssertNotEqual(id, source.id)
        XCTAssertEqual(stores.chats.get("source"), source)
        XCTAssertEqual(stores.chats.list().count, 2)
        XCTAssertEqual(stores.chats.get(id)?.projectId, source.projectId)
        XCTAssertEqual(stores.chats.get(id)?.agentId, source.agentId)
        XCTAssertEqual(activity.status(id), .running)
        XCTAssertNil(activity.status(source.id))
        let forks = await channel.forks
        XCTAssertEqual(forks.count, 2)
        XCTAssertEqual(forks[0], forks[1])
        XCTAssertEqual(forks[0]["beforeMessageId"], message.id)
        let sends = await channel.sends
        XCTAssertEqual(sends.count, 2)
        XCTAssertEqual(sends[0], sends[1])
        XCTAssertEqual(sends[0].chatId, id)
        XCTAssertEqual(sends[0].message, "Use the new design")
        XCTAssertEqual(sends[0].options.attachments, imagePrompt.attachments)
        let acceptedTurns = await channel.acceptedTurns
        XCTAssertEqual(acceptedTurns, 1)
    }

    func testOldDaemonCannotIgnoreTheForkBoundary() async throws {
        let channel = ChatForkChannel(supportsFork: false)
        let session = DaemonSession(agentId: "profile", transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        do {
            _ = try await session.forkChat("source", newChatId: "branch", beforeMessageId: message.id)
            XCTFail("An older service could silently fork the whole conversation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Update the Mindwire service")) }
        let forks = await channel.forks, sends = await channel.sends
        XCTAssertTrue(forks.isEmpty)
        XCTAssertTrue(sends.isEmpty)
    }

    func testBlankPromptRequiresAnAttachment() {
        let draft = ChatForkDraft(message: message) { $0.chatId }
        draft.text = " \n "
        XCTAssertFalse(draft.canSubmit)
        var image = message
        image.attachments = [.init(name: "photo.jpg", mime: "image/jpeg", data: Data([1]))]
        let attached = ChatForkDraft(message: image) { $0.chatId }
        attached.text = ""
        XCTAssertTrue(attached.canSubmit)
    }

    func testEditSheetShowsTheOriginalPromptAndExplainsTheNewChat() async throws {
        let draft = ChatForkDraft(message: message) { $0.chatId }
        let host = UIHostingController(rootView: ChatForkSheet(draft: draft, onSent: { _ in })
            .preferredColorScheme(.dark))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let image = ChatFeedSnapshot.image(host)
        let visible = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(visible.localizedCaseInsensitiveContains("Original prompt"), visible)
        XCTAssertTrue(visible.localizedCaseInsensitiveContains("new chat"), visible)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/mindwire-chat-fork-sheet.png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = "Edit and resend"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRecycledMenusEnableAfterLoadingAndDisableDuringWorkWithoutReloadingReplies() async throws {
        let feed = ForkMenuFeed(messages: [message,
            .init(id: "reply", chatId: "source", role: .assistant, text: "Original reply", createdAt: "")])
        let host = UIHostingController(rootView: ForkMenuFeedView(feed: feed))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(feed.rendered[message.id]?.last, false)
        let replyRenders = feed.rendered["reply"]?.count
        feed.ready = true
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(feed.rendered[message.id]?.last, true, "Existing cells must gain the action when preparation finishes")
        XCTAssertEqual(feed.rendered["reply"]?.count, replyRenders, "Changing a user menu must not redraw completed replies")
        feed.ready = false
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(feed.rendered[message.id]?.last, false, "The action must disappear while the source is running")
        XCTAssertEqual(feed.rendered["reply"]?.count, replyRenders)
    }
}

@MainActor @Observable
private final class ForkMenuFeed {
    let messages: [DaemonMessage]
    var ready = false
    @ObservationIgnored var rendered: [String: [Bool]] = [:]
    init(messages: [DaemonMessage]) { self.messages = messages }
}

private struct ForkMenuFeedView: View {
    let feed: ForkMenuFeed
    var body: some View {
        let rows = ChatTranscriptRow.make(messages: feed.messages, live: nil, runID: nil, canForkHistory: feed.ready)
        ChatTranscriptScrollView(rows: rows, isRunning: false) { row in
            let _ = feed.rendered[row.id.messageID, default: []].append(row.canFork)
            ChatTranscriptRowView(row: row, onEditMessage: row.canFork ? { _ in } : nil)
        }
    }
}

private actor ChatForkChannel: DaemonChannel {
    nonisolated let label = "fork-fixture"
    struct Send: Decodable, Equatable {
        struct Options: Decodable, Equatable { let attachments: [DaemonAttachment] }
        let chatId: String
        let message: String
        let requestId: String
        let options: Options
    }
    let supportsFork: Bool
    private(set) var forks: [[String: String]] = []
    private(set) var sends: [Send] = []
    private(set) var acceptedTurns = 0
    private var branchId: String?
    init(supportsFork: Bool = true) { self.supportsFork = supportsFork }

    func snapshot() -> WorkspaceMetadata {
        let created = "2026-10-01T10:00:00Z"
        var chats = [Chat(id: "source", agentId: "profile", projectId: "project", title: "Original conversation",
                          createdAt: created, sessionId: "original-native", revision: 1)]
        if let branchId {
            chats.append(Chat(id: branchId, agentId: "profile", projectId: "project", title: "Original conversation",
                              createdAt: created, sessionId: nil, revision: 2))
        }
        return WorkspaceMetadata(version: 1, workspaceId: "database", revision: branchId == nil ? 1 : 2, full: true,
            agents: [Agent(id: "profile", name: "Codex", agentType: .codex, workspaceId: "database", createdAt: created, revision: 1)],
            projects: [Project(id: "project", name: "App", workspaceId: "database", path: "/work/app", createdAt: created, revision: 1)],
            chats: chats, deleted: [])
    }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        switch path.split(separator: "?")[0] {
        case "/healthz": return (200, "{\"ok\":true,\"chatForkVersion\":\(supportsFork ? 1 : 0),\"turnRequestVersion\":1,\"imageAttachmentsVersion\":1}")
        case "/agent": return (200, #"{"version":"test","agentType":"codex","name":"Codex","installedVersion":"test","schema":{"sections":[]},"configured":true,"capabilities":{"fork":true,"imageInput":true}}"#)
        case "/chats/source/fork":
            let input = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(jsonBody))
            forks.append(input)
            branchId = input["newChatId"]
            let value: [String: Any] = ["chatId": branchId!, "snapshot": try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot()))]
            return (200, String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        case "/turns":
            let input = try JSONDecoder().decode(Send.self, from: XCTUnwrap(jsonBody))
            sends.append(input)
            if sends.count == 1 { acceptedTurns += 1; return (400, #"{"error":"Fixture lost the send acknowledgement. Retry."}"#) }
            return (202, "{\"id\":\"run\",\"chatId\":\"\(input.chatId)\",\"status\":\"running\",\"createdAt\":\"2026-10-01T12:00:00Z\"}")
        default: return (404, "{}")
        }
    }
}
