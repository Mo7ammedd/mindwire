import SwiftUI
import XCTest
@testable import Mindwire

@MainActor
final class ChatCommandTests: XCTestCase {
    func testSlashParsingKeepsArgumentsAndDoesNotInterceptAbsolutePaths() {
        XCTAssertEqual(DaemonCommandInvocation.parse("/review src\nkeep Arabic العربية"), .init(name: "review", arguments: "src\nkeep Arabic العربية"))
        XCTAssertEqual(DaemonCommandInvocation.parse(" /permissions "), .init(name: "permissions"))
        XCTAssertEqual(DaemonCommandInvocation.query("/perm"), "perm")
        for text in ["/", "/Users/me/project.png", "/tmp/file", "/../file", "ordinary text"] {
            XCTAssertNil(DaemonCommandInvocation.parse(text), "A file path must remain an ordinary message")
        }
    }

    func testPickerSendWaitsForSharedDiscoveryAndRefreshRespectsSettings() async throws {
        let channel = CommandsChannel(held: true)
        let session = DaemonSession(agentId: "codex", transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        let picker = ChatCommandPickerModel()
        let first = Task { await picker.load(session: session, directory: "/repo") }
        for _ in 0..<100 { if await channel.commandReads > 0 { break }; await Task.yield() }
        let send = Task { await picker.load(session: session, directory: "/repo"); return picker.command("/approvals")?.0.kind }
        first.cancel()
        await channel.release()
        await first.value
        let kind = await send.value
        XCTAssertEqual(kind, "settings", "Send must await discovery instead of posting /permissions as model text")
        XCTAssertTrue(picker.loaded)
        XCTAssertFalse(picker.loading)
        _ = try await session.commands(directory: "/repo")
        var reads = await channel.commandReads
        XCTAssertEqual(reads, 1)
        try await session.saveConfig(["model": "changed"])
        _ = try await session.commands(directory: "/repo")
        reads = await channel.commandReads
        XCTAssertEqual(reads, 2, "Changed native settings must invalidate metadata")
        _ = try await session.commands(directory: "/another-project")
        reads = await channel.commandReads
        XCTAssertEqual(reads, 3, "Project skills must not be shared across directories")
    }

    func testTransportPreservesNativeCommandAttachmentsAndCompactionReceipt() async throws {
        let channel = CommandsChannel()
        let transport = ExecDaemonTransport(channel: channel, agentType: "codex")
        _ = try await transport.sendTurn(chatId: "chat", message: "/review src", cwd: "/repo", gitAuth: nil,
                                        requestId: "receipt", attachments: [.init(path: "/repo/image.png", mime: "image/png")],
                                        queueIfRunning: false, command: .init(name: "review", arguments: "src"))
        _ = try await transport.compactChat(chatId: "chat", instructions: "Preserve decisions", requestId: "compact-receipt")
        let posts = await channel.posts
        let turn = try XCTUnwrap(JSONSerialization.jsonObject(with: posts[0].body) as? [String: Any])
        let options = try XCTUnwrap(turn["options"] as? [String: Any])
        XCTAssertEqual(turn["requestId"] as? String, "receipt")
        XCTAssertEqual(options["command"] as? [String: String], ["name": "review", "arguments": "src"])
        XCTAssertEqual((options["attachments"] as? [[String: String]])?.first?["path"], "/repo/image.png")
        let compact = try XCTUnwrap(JSONSerialization.jsonObject(with: posts[1].body) as? [String: String])
        XCTAssertEqual(compact, ["instructions": "Preserve decisions", "requestId": "compact-receipt"])
        XCTAssertTrue(posts.allSatisfy { $0.path.contains("agent=codex") })
    }

    func testCompactionSharesAdmissionAndStopWithoutAnExtraUserMessage() async throws {
        let channel = CommandsChannel()
        let session = DaemonSession(agentId: "codex", transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        _ = try await session.agentInfo() // The chat screen loads the settings/capability metadata on entry.
        let chat = ChatModel(chatId: "chat", session: session)
        defer { chat.dispose() }
        await chat.load()
        XCTAssertTrue(chat.canCompact)
        let original = chat.messages
        await channel.holdCompaction()
        let first = Task { await chat.compact(instructions: "Keep decisions") }
        for _ in 0..<100 {
            if await channel.posts.count > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(chat.submitting)
        let duplicate = await chat.compact(instructions: "Keep decisions")
        XCTAssertFalse(duplicate)
        await channel.releaseCompaction()
        let accepted = await first.value
        XCTAssertTrue(accepted)
        XCTAssertTrue(chat.thinking)
        XCTAssertEqual(chat.messages, original)
        await chat.cancel()
        XCTAssertFalse(chat.thinking)
        let posts = await channel.posts
        XCTAssertEqual(posts.filter { $0.path.contains("/compact?") }.count, 1)
        XCTAssertEqual(posts.filter { $0.path.contains("/cancel?") }.count, 1)
    }

    func testCommandPickerPresentation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let picker = ChatCommandPickerModel()
        picker.catalog = CommandsChannel.catalog
        picker.loaded = true
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            let host = UIHostingController(rootView: ChatCommandsSheet(model: picker, running: false, hasSession: true, agentType: .codex, load: { _ in }, select: { _ in })
                .preferredColorScheme(style == .dark ? .dark : .light))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(180))
            let screenshot = ChatFeedSnapshot.image(host)
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = style == .dark ? "Commands-dark" : "Commands-light"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(screenshot.size.width, 300)
        }
    }
}

private actor CommandsChannel: StreamingDaemonChannel {
    nonisolated let label = "commands-fixture"
    static let catalog = DaemonCommandCatalog(commands: [
        .init(name: "model", label: "Model", kind: "settings", description: "Choose the model and reasoning effort.", settingCanons: ["model", "reasoningEffort"]),
        .init(name: "permissions", label: "Permissions", kind: "settings", description: "Choose approval rules and sandbox access.", aliases: ["approvals"], settingCanons: ["permissionMode"]),
        .init(name: "compact", label: "Compact conversation", kind: "compact", description: "Summarize earlier context in this conversation.", requiresIdle: true, requiresSession: true),
        .init(name: "review", label: "Review changes", kind: "prompt", description: "Review the changes in this project.", acceptsArguments: true, requiresIdle: true),
    ])
    struct Post { let path: String; let body: Data }
    private(set) var posts: [Post] = []
    private(set) var commandReads = 0
    private var held: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var compactHeld = false
    private var compactGate: CheckedContinuation<Void, Never>?
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var started = false
    private var run = DaemonRun(id: "run", chatId: "chat", status: .running, createdAt: "2026-10-08T00:00:00Z")
    init(held: Bool = false) { self.held = held }
    func release() { held = false; gate?.resume(); gate = nil }
    func holdCompaction() { compactHeld = true }
    func releaseCompaction() { compactHeld = false; compactGate?.resume(); compactGate = nil }

    func stream(method: String, path: String, jsonBody: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        streamContinuation = continuation
        continuation.yield(Data(#"{"type":"replay_done"}"#.utf8))
        return stream
    }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        let endpoint = String(path.split(separator: "?")[0])
        if method == "POST" {
            posts.append(.init(path: path, body: jsonBody ?? Data("{}".utf8)))
            if endpoint == "/runs/run/cancel" {
                run.status = .cancelled
                streamContinuation?.finish()
                return (200, "{}")
            }
            started = true
            if endpoint == "/chats/chat/compact", compactHeld { await withCheckedContinuation { compactGate = $0 } }
            return (202, String(decoding: try JSONEncoder().encode(run), as: UTF8.self))
        }
        switch endpoint {
        case "/chats/chat/run":
            guard started else { return (204, "") }
            return (200, String(decoding: try JSONEncoder().encode(run), as: UTF8.self))
        case "/runs/run": return (200, String(decoding: try JSONEncoder().encode(run), as: UTF8.self))
        case "/runs/run/snapshot": return (404, "")
        case "/chats/chat/messages": return (200, #"[{"id":"previous","chatId":"chat","role":"user","text":"Previous question","createdAt":"2026-10-07T00:00:00Z"}]"#)
        case "/commands":
            commandReads += 1
            if held { await withCheckedContinuation { gate = $0 } }
            return (200, String(decoding: try JSONEncoder().encode(Self.catalog), as: UTF8.self))
        case "/agent":
            return (200, #"{"version":"test","agentType":"codex","name":"Codex","installedVersion":"0.161.0","configured":true,"capabilities":{"commands":true,"compactNow":true},"schema":{"sections":[]}}"#)
        case "/auth/status": return (200, #"{"configured":true}"#)
        case "/setup": return (200, #"{"ok":true,"steps":[]}"#)
        default: return (200, "{}")
        }
    }
}
