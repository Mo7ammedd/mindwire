import XCTest
@testable import Mindwire

@MainActor
final class NativeChatTests: XCTestCase {
    func testColdHistoryAppearsBeforeSlowNativeOwnershipAndConcurrentOpenersShareTheRead() async throws {
        let channel = NativeOwnerChannel()
        let saved = DaemonMessage(id: "saved", chatId: "chat", role: .assistant,
            text: "Previously saved reply", createdAt: "2026-10-11T00:00:00Z")
        await channel.seedHistory([saved])
        await channel.holdNativeActivity()
        let model = makeModel(channel)
        let loading = Task { await model.load() }
        defer {
            model.dispose()
            Task { await channel.releaseNativeActivity() }
        }
        try await eventually { await channel.nativeReads == 1 && model.hasLoadedHistory }
        XCTAssertEqual(model.transcriptMessages, [saved])
        XCTAssertFalse(model.loadingHistory, "Reading saved messages must finish independently of native discovery")
        XCTAssertFalse(model.canSendToConversation, "An unresolved terminal owner must still gate Send")
        XCTAssertFalse(model.canStartVoice)
        let sent = await model.send("Do not launch a second process")
        XCTAssertFalse(sent)
        let reopening = Task { await model.load() }
        await Task.yield()
        let nativeReads = await channel.nativeReads
        let historyReads = await channel.historyReads
        let actions = await channel.actions
        let mutations = await channel.mutations
        XCTAssertEqual(nativeReads, 1)
        XCTAssertEqual(historyReads, 1)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(mutations, 0, "Send must not reach either mutation endpoint before ownership is known")
        await channel.releaseNativeActivity()
        await loading.value
        await reopening.value
        try await eventually { model.nativeState.connected }
        XCTAssertTrue(model.canSendToConversation)
        let opens = await channel.opens
        XCTAssertEqual(opens, 1)
    }

    func testNativeDiscoveryFailurePreservesSavedHistoryAndRetryRestoresItsControls() async throws {
        let channel = NativeOwnerChannel()
        let saved = DaemonMessage(id: "saved", chatId: "chat", role: .assistant,
            text: "Read this even when the native bridge is unavailable", createdAt: "2026-10-11T00:00:00Z")
        await channel.seedHistory([saved])
        await channel.failNativeActivity(true)
        let model = makeModel(channel)
        defer { model.dispose() }
        await model.load()
        XCTAssertEqual(model.transcriptMessages, [saved])
        XCTAssertTrue(model.hasLoadedHistory)
        XCTAssertFalse(model.loadingHistory)
        XCTAssertNotNil(model.loadError)
        XCTAssertTrue(model.needsOwnershipRetry)
        XCTAssertFalse(model.canSendToConversation)
        let sent = await model.send("Wait for ownership verification")
        XCTAssertFalse(sent)
        await channel.failNativeActivity(false)
        await model.load(force: true)
        try await eventually { model.nativeState.connected }
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.needsOwnershipRetry)
        XCTAssertTrue(model.canSendToConversation)
    }

    func testDisposedChatCannotAttachFromALateNativeDiscoveryResponse() async throws {
        let channel = NativeOwnerChannel()
        await channel.holdNativeActivity()
        let model = makeModel(channel)
        let loading = Task { await model.load() }
        defer {
            model.dispose()
            Task { await channel.releaseNativeActivity() }
        }
        try await eventually { await channel.nativeReads == 1 && model.hasLoadedHistory }
        model.dispose()
        await channel.releaseNativeActivity()
        await loading.value
        XCTAssertFalse(model.nativeState.ownsConversation)
        XCTAssertFalse(model.thinking)
        let opens = await channel.opens
        XCTAssertEqual(opens, 0, "Late discovery must not revive a removed conversation")
    }

    func testReplayRetainsTheProjectionAndRejectsAGapWithoutAdvancingItsCursor() throws {
        var state = NativeChatState()
        let active = nativeActivity()
        try state.apply(.init(type: "snapshot", snapshot: .init(connectionId: "epoch", sequence: 4,
            turnId: "turn", activity: active, parts: [.init(kind: .text, id: "answer", text: "A")])))
        var nowIdle = active
        nowIdle.state = "idle"
        nowIdle.turnId = nil
        try state.apply(.init(type: "resume", snapshot: .init(connectionId: "epoch", sequence: 4, activity: nowIdle)))
        XCTAssertTrue(state.isRunning, "A resume only acknowledges the saved cursor")
        XCTAssertEqual(state.live?.text, "A")
        let update = NativeSessionFrame(type: "update", update: .init(connectionId: "epoch", sequence: 5,
            event: .init(type: .text, itemId: "answer", text: "B", delta: true)))
        try state.apply(update)
        try state.apply(update)
        XCTAssertEqual(state.live?.text, "AB", "Replayed event IDs cannot duplicate text")
        XCTAssertThrowsError(try state.apply(.init(type: "update", update: .init(connectionId: "epoch", sequence: 7))))
        XCTAssertEqual(state.cursor, "epoch:5")
        try state.apply(.init(type: "update", update: .init(connectionId: "epoch", sequence: 6,
            activity: nowIdle, historyChanged: true)))
        state.historyAdopted([])
        XCTAssertEqual(state.live?.text, "AB", "Completion cannot erase output before history catches up")
        state.historyAdopted([.init(id: "saved", chatId: "chat", role: .assistant, text: "AB\n",
                                   createdAt: "", nativeTurnId: "turn")])
        XCTAssertNil(state.live)
    }

    func testBoundedSnapshotRetainsLoadedHistoryAndClaudeNeverCreatesAnEmptyLiveTurn() throws {
        var state = NativeChatState()
        let tool = DaemonMessagePart(kind: .tool, tool: .init(id: "command", name: "exec", output: "Done"))
        try state.apply(.init(type: "snapshot", snapshot: .init(connectionId: "epoch", sequence: 1,
            turnId: "turn", activity: nativeActivity(), parts: [tool, .init(kind: .text, text: "Newest")], historyRequired: true, partial: true)))
        let history = [DaemonMessage(id: "saved", chatId: "chat", role: .assistant, text: "Earlier",
            createdAt: "", parts: [.init(kind: .text, text: "Earlier"), tool], nativeTurnId: "turn")]
        XCTAssertEqual(state.live(in: history)?.parts.count, 3)
        XCTAssertEqual(state.live(in: history)?.text, "EarlierNewest")
        try state.apply(.init(type: "snapshot", snapshot: .init(connectionId: "claude", sequence: 0,
            activity: nativeActivity(controllable: false))))
        XCTAssertTrue(state.isRunning)
        XCTAssertNil(state.live, "Claude streams saved history and status, not an empty assistant bubble")
        XCTAssertFalse(state.canSend)
        XCTAssertFalse(state.canStop)
    }

    func testReopeningSharesOneObserverAndOnlyReplaysNewNativeOutput() async throws {
        let channel = NativeOwnerChannel()
        let activity = ChatActivityStore()
        let model = makeModel(channel, activity: activity)
        let viewer = UUID()
        defer { model.dispose() }
        model.viewDidAppear(viewer)
        await model.load()
        try await eventually { model.nativeState.connected }
        XCTAssertTrue(model.thinking)
        XCTAssertNil(model.activeRunID, "A native process has no fabricated daemon run")
        XCTAssertEqual(activity.status("chat"), .running)
        XCTAssertEqual(model.transcriptLive?.text, "A")
        await model.load()
        let opens = await channel.opens
        XCTAssertEqual(opens, 1)
        model.viewDidDisappear(viewer)
        try await eventually { await channel.viewerCount == 0 }
        try await channel.appendText("B")
        XCTAssertEqual(activity.status("chat"), .running, "Back preserves the recently observed native badge")
        model.viewDidAppear(viewer)
        await model.load()
        try await eventually { model.nativeState.connected && model.transcriptLive?.text == "AB" }
        let cursors = await channel.cursors
        XCTAssertEqual(cursors, [nil, "epoch:1"])
        let actions = await channel.actions
        XCTAssertTrue(actions.isEmpty, "Leaving a viewer must never stop its native owner")
    }

    func testNativeInputRetryKeepsItsReceiptAndStopTargetsTheExactTurn() async throws {
        let channel = NativeOwnerChannel(loseAcknowledgement: true)
        let model = makeModel(channel)
        defer { model.dispose() }
        await model.load()
        try await eventually { model.nativeState.canSend }
        let first = await model.send("Continue from my phone")
        XCTAssertFalse(first)
        let firstActions = await channel.actions
        XCTAssertEqual(firstActions.count, 1, "The transport must not automatically resend an uncertain input")
        let second = await model.send("Continue from my phone")
        XCTAssertTrue(second)
        let sends = await channel.actions
        XCTAssertEqual(sends.count, 2)
        XCTAssertEqual(sends[0], sends[1])
        try await eventually { model.nativeState.projection.parts.compactMap(\.input).count == 1 }
        XCTAssertTrue(model.queuedInputs.isEmpty)
        await model.cancel()
        let actions = await channel.actions
        XCTAssertEqual(actions.last?["kind"], .string("interrupt"))
        XCTAssertEqual(actions.last?["expectedTurnId"], .string("turn"))
        XCTAssertEqual(actions.last?["connectionId"], .string("epoch"))
        try await eventually { !model.thinking }
    }

    func testClaudeTerminalOwnershipBlocksSendAndStopBeforeAnyMutation() async throws {
        let channel = NativeOwnerChannel(controllable: false)
        let model = makeModel(channel)
        defer { model.dispose() }
        await model.load()
        try await eventually { model.nativeState.connected }
        XCTAssertTrue(model.thinking)
        XCTAssertFalse(model.canSendToConversation)
        let sent = await model.send("Do not launch another Claude process")
        XCTAssertFalse(sent)
        await model.cancel()
        let actions = await channel.actions
        XCTAssertTrue(actions.isEmpty)
    }

    func testNextTerminalTurnKeepsReceivedOutputUntilHistoryContainsItsAnswer() async throws {
        let channel = NativeOwnerChannel()
        let model = makeModel(channel)
        defer { model.dispose() }
        await model.load()
        try await eventually { model.nativeState.connected }
        let user = DaemonMessage(id: "old-user", chatId: "chat", role: .user, text: "Build", createdAt: "", nativeTurnId: "turn")
        await channel.seedHistory([user])
        try await channel.startNextTurn()
        try await channel.appendText("Next")
        try await eventually { model.nativeState.turnId == "next" && model.transcriptLive?.text == "Next" }
        await model.load(force: true)
        XCTAssertEqual(model.transcriptMessages.map(\.text), ["A"], "A lagging prompt-only page cannot erase the previous live answer")
        await channel.seedHistory([user, .init(id: "old-answer", chatId: "chat", role: .assistant, text: "A",
                                              createdAt: "", nativeTurnId: "turn")])
        await model.load(force: true)
        XCTAssertEqual(model.transcriptMessages.map(\.id), ["old-user", "old-answer"])
    }

    private func makeModel(_ channel: NativeOwnerChannel, activity: ChatActivityStore? = nil) -> ChatModel {
        ChatModel(chatId: "chat", session: DaemonSession(agentId: "codex",
            transport: ExecDaemonTransport(channel: channel, agentType: "codex")), activity: activity ?? ChatActivityStore())
    }

    private func eventually(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Native state did not settle", file: file, line: line)
        throw URLError(.timedOut)
    }
}

private func nativeActivity(controllable: Bool = true) -> NativeSessionActivity {
    .init(sessionId: "session", cwd: "/project", owner: "native", state: "running",
          turnId: controllable ? "turn" : nil, startedAt: "2026-10-11T00:00:00Z",
          capabilities: .init(status: true, observe: true, input: controllable, interrupt: controllable, respond: controllable))
}

/// Exercises the real HTTP mapping, session, and chat lifecycle. Only native
/// protocol responses are simulated; no duplicate implementation of the client.
private actor NativeOwnerChannel: StreamingDaemonChannel {
    nonisolated let label = "native-owner-fixture"
    private var activity: NativeSessionActivity
    private var sequence = 1
    private var text = "A"
    private var replay: [(Int, Data)] = []
    private var subscribers: [UUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var accepted: Set<String> = []
    private var history: [DaemonMessage] = []
    private var loseAcknowledgement: Bool
    private var nativeHeld = false
    private var nativeGate: CheckedContinuation<Void, Never>?
    private var nativeFails = false
    private(set) var nativeReads = 0
    private(set) var historyReads = 0
    private(set) var mutations = 0
    private(set) var actions: [JSONValue] = []
    private(set) var cursors: [String?] = []
    var opens: Int { cursors.count }
    var viewerCount: Int { subscribers.count }

    init(controllable: Bool = true, loseAcknowledgement: Bool = false) {
        activity = nativeActivity(controllable: controllable)
        self.loseAcknowledgement = loseAcknowledgement
    }

    func holdNativeActivity() { nativeHeld = true }
    func releaseNativeActivity() { nativeHeld = false; nativeGate?.resume(); nativeGate = nil }
    func failNativeActivity(_ fail: Bool) { nativeFails = fail }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        if method != "GET" { mutations += 1 }
        let endpoint = String(path.split(separator: "?")[0])
        switch (method, endpoint) {
        case ("GET", "/healthz"): return (200, #"{"ok":true,"nativeSessionVersion":1}"#)
        case ("GET", "/setup"): return (200, #"{"ok":true,"steps":[]}"#)
        case ("GET", "/agent"):
            return try response(DaemonAgentInfo(version: "native-test", agentType: "codex", name: "Codex", schema: .empty,
                                              installedVersion: "fixture", configured: true))
        case ("GET", "/chats/chat/run"): return (204, "")
        case ("GET", "/chats/chat/native"):
            nativeReads += 1
            if nativeHeld { await withCheckedContinuation { nativeGate = $0 } }
            if nativeFails { return (409, #"{"code":"native_session_unavailable","message":"Native status unavailable"}"#) }
            return try response(activity)
        case ("GET", "/chats/chat/messages"):
            historyReads += 1
            struct Page: Encodable { var messages: [DaemonMessage]; let hasMore = false }
            return try response(Page(messages: history))
        case ("POST", "/chats/chat/native/actions"):
            let value = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(jsonBody))
            actions.append(value)
            let id = try XCTUnwrap(value["requestId"]?.string)
            if value["kind"]?.string == "input", accepted.insert(id).inserted {
                try publish(event: .init(type: .input, input: .init(id: id, text: value["text"]?.string ?? "",
                    createdAt: "2026-10-11T00:00:01Z", status: "accepted")))
            }
            if loseAcknowledgement {
                loseAcknowledgement = false
                throw URLError(.networkConnectionLost)
            }
            if value["kind"]?.string == "interrupt" {
                activity.state = "idle"
                activity.turnId = nil
                try publish(event: nil)
            }
            return (200, "{\"requestId\":\"\(id)\",\"status\":\"accepted\",\"turnId\":\"turn\"}")
        default: return (404, #"{"error":"No fixture endpoint"}"#)
        }
    }

    func stream(method: String, path: String, jsonBody: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        let cursor = URLComponents(string: path)?.queryItems?.first { $0.name == "cursor" }?.value
        cursors.append(cursor)
        let after = cursor.flatMap { Int($0.split(separator: ":").last ?? "") }
        var snapshot: [String: Any] = ["connectionId": "epoch", "sequence": after ?? sequence,
            "activity": try object(activity), "parts": activity.capabilities.input ? [["type": "text", "id": "answer", "text": text]] : []]
        if activity.capabilities.input { snapshot["turnId"] = activity.turnId ?? "turn" }
        let initial = try JSONSerialization.data(withJSONObject: ["type": after == nil ? "snapshot" : "resume", "snapshot": snapshot])
        let id = UUID()
        return AsyncThrowingStream { continuation in
            subscribers[id] = continuation
            continuation.yield(initial)
            if let after { for (seq, data) in replay where seq > after { continuation.yield(data) } }
            continuation.onTermination = { [weak self] _ in Task { await self?.removeViewer(id) } }
        }
    }

    func appendText(_ suffix: String) throws {
        text += suffix
        try publish(event: .init(type: .text, itemId: "answer", text: suffix, delta: true))
    }

    func seedHistory(_ messages: [DaemonMessage]) { history = messages }

    func startNextTurn() throws {
        activity.turnId = "next"
        text = ""
        sequence += 1
        let update: [String: Any] = ["connectionId": "epoch", "sequence": sequence, "turnId": "next",
                                    "reset": true, "activity": try object(activity)]
        let data = try JSONSerialization.data(withJSONObject: ["type": "update", "update": update])
        replay.append((sequence, data))
        for subscriber in subscribers.values { subscriber.yield(data) }
    }

    private func publish(event: DaemonEvent?) throws {
        sequence += 1
        var update: [String: Any] = ["connectionId": "epoch", "sequence": sequence, "turnId": activity.turnId ?? "turn"]
        if let event { update["event"] = try object(event) }
        else { update["activity"] = try object(activity); update["historyChanged"] = true }
        let data = try JSONSerialization.data(withJSONObject: ["type": "update", "update": update])
        replay.append((sequence, data))
        for subscriber in subscribers.values { subscriber.yield(data) }
    }

    private func removeViewer(_ id: UUID) { subscribers[id] = nil }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func response<T: Encodable>(_ value: T) throws -> (status: Int, body: String) {
        (200, String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }
}
