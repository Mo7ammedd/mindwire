import XCTest
@testable import Mindwire

@MainActor
final class ChatRunTests: XCTestCase {
    private func run(_ status: RunStatus, error: String? = nil) -> DaemonRun {
        DaemonRun(id: "run", chatId: "chat", status: status, error: error,
                  createdAt: "2026-09-11T10:00:00Z", endedAt: "2026-09-11T10:00:10Z")
    }

    private func event(_ json: String) throws -> DaemonEvent {
        try JSONDecoder().decode(DaemonEvent.self, from: Data(json.utf8))
    }

    func testGreetingHistoryMatchesDifferentTransportIDs() throws {
        for count in [1, 2] {
            var live = LiveTurn()
            for index in 0..<count {
                live.apply(DaemonEvent(type: .text, itemId: "item_\(index)", text: "Hi!", delta: true))
            }
            let history = DaemonMessage(id: "reply", chatId: "chat", role: .assistant,
                text: Array(repeating: "Hi!", count: count).joined(separator: "\n\n"), createdAt: "2026-09-11T10:00:10Z",
                parts: (0..<count).map { .init(kind: .text, id: "native-\($0)", text: "Hi!") })
            let completion = ChatTurnCompletion.reconcile(current: [], fetched: [history], live: live,
                run: run(.done), runId: "run", baselineIDs: [], pendingUser: nil)
            XCTAssertEqual(completion.messages[0].parts, history.parts,
                           "Pair the two representations without collapsing legitimately repeated items")
        }
    }

    /// These fixtures are exported by the daemon's production parser and runner from real CLI runs.
    /// The UI consumes the same protocol for every provider; there is no Codex rendering branch.
    func testCapturedDaemonTurnsUseSharedChatComponents() throws {
        struct Capture: Decodable {
            let events: [DaemonEvent]
            let messages: [DaemonMessage]?
        }
        for name in ["hello", "activity", "structured", "plan"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "codex-\(name)", withExtension: "json"))
            let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: url))
            var live = LiveTurn()
            capture.events.forEach { live.apply($0) }
            let completion = ChatTurnCompletion.reconcile(current: [], fetched: capture.messages, live: live,
                run: run(.done), runId: "run", baselineIDs: [], pendingUser: nil)
            let replies = completion.messages.filter { $0.role == .assistant }
            XCTAssertEqual(replies.count, 1, name)
            let parts = try XCTUnwrap(replies.first?.parts)
            XCTAssertNil(completion.error, name)
            switch name {
            case "hello":
                XCTAssertEqual(parts.count, 1)
                XCTAssertEqual(parts[0].text, "Hi! What can I help you with?")
            case "activity":
                XCTAssertEqual(parts.count, 9)
                let calls = parts.compactMap(\.tool)
                XCTAssertEqual(calls.count, 5)
                XCTAssertEqual(Set(calls.map(\.id)).count, 5)
                let edits = calls.flatMap(\.fileEdits)
                XCTAssertEqual(edits.map(\.path), ["/workspace/answer.txt", "/workspace/hello.txt"])
                XCTAssertTrue(edits.allSatisfy { $0.unifiedDiff?.isEmpty == false })
                XCTAssertEqual(calls.filter { $0.isError == true }.count, 1)
                XCTAssertEqual(calls.first { $0.isError == true }?.action?.shell?.exitCode, 7)
            case "structured":
                XCTAssertEqual(parts.map(\.kind), [.thinking, .text])
                let reply = try XCTUnwrap(parts.last?.text?.data(using: .utf8))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
                XCTAssertEqual(object["greeting"] as? String, "Hello")
                XCTAssertEqual(object["items"] as? [Int], [1, 2, 3])
                XCTAssertEqual(live.result?.usage?.cacheWriteTokens, 9571)
            case "plan":
                let plans = parts.compactMap(\.interaction).filter { $0.kind == "plan" }
                XCTAssertEqual(plans.count, 1)
                XCTAssertTrue(plans[0].detail?.contains("test_add.py") == true)
                XCTAssertEqual(parts.compactMap(\.tool).count, 1)
            default: break
            }
        }
    }

    func testLargeToolOutputSurvivesDecodingAndCompletion() throws {
        let output = String(repeating: "output 👋\n", count: 100_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "tool_result", "tool": ["id": "large", "name": "shell", "output": output]
        ])
        var live = LiveTurn()
        live.apply(try JSONDecoder().decode(DaemonEvent.self, from: data))
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: nil, live: live,
            run: run(.done), runId: "run", baselineIDs: [], pendingUser: nil)
        XCTAssertEqual(completion.messages.last?.parts?.first?.tool?.output, output)
    }

    func testGreetingResultDoesNotRepeatStreamedTextWithTrailingWhitespace() throws {
        var live = LiveTurn()
        live.apply(try event(#"{"type":"text","itemId":"answer","text":"Hi! How can I help?\n","delta":true}"#))
        live.apply(try event(#"{"type":"result","result":{"text":"Hi! How can I help?"}}"#))

        XCTAssertEqual(live.parts.filter { $0.kind == .text }.count, 1)
        let history = DaemonMessage(id: "reply", chatId: "chat", role: .assistant,
            text: "Hi! How can I help?", createdAt: "2026-09-11T10:00:10Z",
            parts: [.init(kind: .text, id: "answer", text: "Hi! How can I help?\n")])
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: [history], live: live,
            run: run(.done), runId: "run", baselineIDs: [], pendingUser: nil)
        XCTAssertEqual(completion.messages.count, 1)
        XCTAssertEqual(completion.messages[0].parts?.filter { $0.kind == .text }.count, 1)
    }

    func testGreetingHistoryDoesNotRepeatAWhitespaceVariantOfThePreview() throws {
        var live = LiveTurn()
        live.apply(try event(#"{"type":"text","text":"\nHi! How can I help?","delta":true}"#))
        let history = DaemonMessage(id: "reply", chatId: "chat", role: .assistant,
            text: "Hi! How can I help?", createdAt: "2026-09-11T10:00:10Z",
            parts: [.init(kind: .text, text: "Hi! How can I help?")])
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: [history], live: live,
            run: run(.done), runId: "run", baselineIDs: [], pendingUser: nil)
        XCTAssertEqual(completion.messages[0].parts, history.parts)
    }

    func testResultCompletesPartialTextWithoutRepeatingItsLeadingWhitespace() throws {
        var live = LiveTurn()
        live.apply(try event(#"{"type":"text","itemId":"answer","text":"\nHi!","delta":true}"#))
        live.apply(try event(#"{"type":"result","result":{"text":"Hi! How can I help?"}}"#))
        XCTAssertEqual(live.parts.count, 1)
        XCTAssertEqual(live.text, "Hi! How can I help?")
        XCTAssertEqual(live.parts.first?.id, "answer")
    }

    func testRepeatedTextFromDistinctItemsIsPreserved() throws {
        var live = LiveTurn()
        live.apply(try event(#"{"type":"text","itemId":"first","text":"Hello","delta":true}"#))
        live.apply(try event(#"{"type":"text","itemId":"second","text":"Hello","delta":true}"#))
        live.apply(try event(#"{"type":"result","result":{"text":"Hello"}}"#))
        let history = DaemonMessage(id: "reply", chatId: "chat", role: .assistant,
            text: "Hello\n\nHello", createdAt: "2026-09-11T10:00:10Z", parts: live.parts)
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: [history], live: live,
            run: run(.done), runId: "run", baselineIDs: [], pendingUser: nil)
        XCTAssertEqual(completion.messages[0].parts?.map(\.id), ["first", "second"])
    }

    func testWarningsAndItemFailuresSurviveSuccessfulCompletionAndReload() throws {
        var live = LiveTurn()
        try [
            #"{"type":"interaction","interaction":{"id":"warning","kind":"warning","title":"Configuration warning","detail":"An optional setting was ignored."}}"#,
            #"{"type":"interaction","interaction":{"id":"item-error","kind":"error","title":"Codex error","detail":"One lookup failed."}}"#,
            #"{"type":"text","itemId":"answer","delta":true,"text":"Finished with the available data."}"#,
            #"{"type":"result","result":{"text":"Finished with the available data.","isError":false}}"#
        ].forEach { live.apply(try event($0)) }
        XCTAssertNil(live.error)
        XCTAssertEqual(live.parts.compactMap { $0.interaction?.kind }, ["warning", "error"])
        let history = DaemonMessage(id: "reply", chatId: "chat", role: .assistant, text: live.text,
                                    createdAt: "2026-09-11T10:00:10Z", parts: live.parts)
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: [history], live: live,
            run: run(.done), runId: "run", baselineIDs: [], pendingUser: nil)
        XCTAssertEqual(completion.messages.count, 1)
        XCTAssertEqual(completion.messages[0].parts?.count, 3)
        XCTAssertNil(completion.error)
    }

    func testMCPProgressAndHookFailureUpdateTheirExistingComponents() throws {
        var live = LiveTurn()
        try [
            #"{"type":"tool_use","tool":{"id":"mcp","name":"docs.search","output":"Connecting"}}"#,
            #"{"type":"tool_use","tool":{"id":"mcp","name":"docs.search","output":"Fetched 3 results."}}"#,
            #"{"type":"interaction","interaction":{"id":"hook","kind":"info","title":"Hook: preToolUse","detail":"running"}}"#,
            #"{"type":"interaction","interaction":{"id":"hook","kind":"error","title":"Hook: preToolUse","detail":"Hook blocked this command."}}"#,
            #"{"type":"tool_result","tool":{"id":"mcp","name":"docs.search","output":"Authentication expired (HTTP 401)","isError":true}}"#
        ].forEach { live.apply(try event($0)) }
        XCTAssertEqual(live.parts.count, 2)
        XCTAssertEqual(live.parts[0].tool?.output, "Authentication expired (HTTP 401)")
        XCTAssertEqual(live.parts[0].tool?.isError, true)
        XCTAssertEqual(live.parts[1].interaction?.kind, "error")
        XCTAssertEqual(live.parts[1].interaction?.detail, "Hook blocked this command.")
        XCTAssertNotEqual(live.parts[1].interaction?.needsResponse, true)
    }

    func testPollingReturnsTheActualRunError() async throws {
        var polls = 0
        let terminal = try await ChatRunMonitor.follow(openStream: { nil }, getRun: {
            polls += 1
            return polls == 1 ? self.run(.running) : self.run(.error, error: "Deployment not found (HTTP 404)")
        }, onEvent: { _ in XCTFail("No stream expected") }, wait: {})
        XCTAssertEqual(terminal.status, .error)
        XCTAssertEqual(terminal.error, "Deployment not found (HTTP 404)")
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: [], live: LiveTurn(),
            run: terminal, runId: "run", baselineIDs: [], pendingUser: nil)
        XCTAssertEqual(completion.error, terminal.error)
        XCTAssertEqual(completion.messages.last?.parts?.last?.interaction?.detail, terminal.error)
    }

    func testDisconnectedStreamKeepsReconnectingWhileTheRunIsActive() async throws {
        var streams = 0, polls = 0
        let terminal = try await ChatRunMonitor.follow(openStream: {
            streams += 1
            return AsyncThrowingStream { $0.finish(throwing: URLError(.networkConnectionLost)) }
        }, getRun: {
            polls += 1
            return self.run(polls < 3 ? .running : .done)
        }, onEvent: { _ in }, wait: {})
        XCTAssertEqual(streams, 3)
        XCTAssertEqual(polls, 3)
        XCTAssertEqual(terminal.status, .done)
    }

    func testPollingFailureDoesNotBecomeAnEmptySuccess() async {
        do {
            _ = try await ChatRunMonitor.follow(openStream: { nil },
                getRun: { throw URLError(.notConnectedToInternet) }, onEvent: { _ in }, wait: {})
            XCTFail("The status failure must reach chat")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testEmptyOrPartialReplayNeverErasesVisibleContent() async throws {
        let sentinel = try event(#"{"type":"status","meta":{"stream":"open"}}"#)
        let first = try event(#"{"type":"text","itemId":"answer","text":"The answer","delta":true}"#)
        let second = try event(#"{"type":"text","itemId":"answer","text":" is here.","delta":true}"#)
        for replay in [[DaemonEvent](), [first]] {
            var streams = 0, polls = 0
            var live = LiveTurn()
            let terminal = try await ChatRunMonitor.follow(openStream: {
                streams += 1
                let events = [sentinel] + (streams == 1 ? [first, second] : replay)
                return AsyncThrowingStream { continuation in
                    for event in events { continuation.yield(event) }
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                }
            }, getRun: {
                polls += 1
                return self.run(polls == 1 ? .running : .done)
            }, onEvent: { live.apply($0) }, wait: {})
            let completion = ChatTurnCompletion.reconcile(current: [], fetched: nil, live: live,
                run: terminal, runId: "run", baselineIDs: [], pendingUser: nil)
            XCTAssertEqual(live.text, "The answer is here.")
            XCTAssertEqual(completion.messages.last?.text, "The answer is here.")
            XCTAssertNil(completion.error)
        }
    }

    func testReplaySkipsOnlyPreviouslyDeliveredEvents() async throws {
        let first = try event(#"{"type":"text","itemId":"answer","text":"Hello","delta":true}"#)
        let second = try event(#"{"type":"text","itemId":"answer","text":" world","delta":true}"#)
        var streams = 0, polls = 0
        var live = LiveTurn()
        _ = try await ChatRunMonitor.follow(openStream: {
            streams += 1
            return AsyncThrowingStream { continuation in
                continuation.yield(first)
                if streams == 2 { continuation.yield(second) }
                continuation.finish()
            }
        }, getRun: {
            polls += 1
            return self.run(polls == 1 ? .running : .done)
        }, onEvent: { live.apply($0) }, wait: {})
        XCTAssertEqual(live.text, "Hello world")
        XCTAssertEqual(live.parts.count, 1)
    }

    func testRepeatedQuestionSurvivesLaggingHistory() {
        let earlier = DaemonMessage(id: "earlier", chatId: "chat", role: .user, text: "Try again", createdAt: "2026-09-11T09:00:00Z")
        let pending = DaemonMessage(id: "pending", chatId: "chat", role: .user, text: "Try again", createdAt: "2026-09-11T10:00:00Z")
        let completion = ChatTurnCompletion.reconcile(current: [earlier, pending], fetched: [earlier], live: LiveTurn(),
            run: run(.error, error: "Offline"), runId: "run", baselineIDs: ["earlier", "pending"], pendingUser: pending)
        XCTAssertEqual(completion.messages.filter { $0.role == .user }.map(\.id), ["earlier", "pending"])
    }

    func testNativeQuestionReplacesPendingDespiteDeviceClockSkew() {
        let pending = DaemonMessage(id: "pending", chatId: "chat", role: .user, text: "Hello", createdAt: "2026-09-11T10:00:30Z")
        let native = DaemonMessage(id: "native", chatId: "chat", role: .user, text: "Hello", createdAt: "2026-09-11T10:00:00Z")
        let completion = ChatTurnCompletion.reconcile(current: [pending], fetched: [native], live: LiveTurn(),
            run: run(.cancelled), runId: "run", baselineIDs: ["pending"], pendingUser: pending)
        XCTAssertEqual(completion.messages, [native])
    }

    func testPartialLiveComponentsCannotReplaceCompleteHistory() throws {
        let committed = DaemonMessage(id: "reply", chatId: "chat", role: .assistant, text: "A complete answer",
            createdAt: "2026-09-11T10:00:05Z", parts: [
                .init(kind: .tool, tool: .init(id: "tool", name: "shell", output: "Complete output")),
                .init(kind: .text, id: "answer", text: "A complete answer")
            ])
        var live = LiveTurn()
        live.apply(try event(#"{"type":"thinking","itemId":"reasoning","text":"Checking","delta":true}"#))
        live.apply(try event(#"{"type":"tool_use","tool":{"id":"tool","name":"shell"}}"#))
        live.apply(try event(#"{"type":"text","itemId":"answer","text":"A comp","delta":true}"#))
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: [committed], live: live,
            run: run(.done), runId: "run", baselineIDs: [], pendingUser: nil)
        let parts = try XCTUnwrap(completion.messages.last?.parts)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].text, "Checking")
        XCTAssertEqual(parts[1].tool?.output, "Complete output")
        XCTAssertEqual(parts[2].text, "A complete answer")
    }

    func testTransportFailurePreservesPartialReplyAndReportsError() throws {
        var live = LiveTurn()
        live.apply(try event(#"{"type":"text","text":"Partial response","delta":true}"#))
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: nil, live: live,
            run: nil, runId: "run", baselineIDs: [], pendingUser: nil, transportError: "Connection lost after stopping")
        XCTAssertEqual(completion.messages.last?.parts?.first?.text, "Partial response")
        XCTAssertEqual(completion.error, "Connection lost after stopping")
        XCTAssertEqual(completion.messages.last?.parts?.last?.interaction?.detail, completion.error)
    }

    func testCompactionDoesNotDuplicateEarlierTurnComponents() throws {
        let before = DaemonMessage(id: "before", chatId: "chat", role: .assistant, text: "Before", createdAt: "2026-09-11T10:00:01Z",
            parts: [.init(kind: .text, id: "first", text: "Before")])
        let marker = DaemonMessage(id: "compact", chatId: "chat", role: .system, text: "", createdAt: "2026-09-11T10:00:02Z",
            parts: [.init(kind: .compaction, compaction: .init(summary: "Earlier context"))])
        let after = DaemonMessage(id: "after", chatId: "chat", role: .assistant, text: "After", createdAt: "2026-09-11T10:00:03Z",
            parts: [.init(kind: .text, id: "last", text: "After")])
        var live = LiveTurn()
        live.apply(try event(#"{"type":"text","itemId":"first","text":"Before","delta":true}"#))
        live.apply(try event(#"{"type":"compaction","compaction":{"trigger":"auto"}}"#))
        live.apply(try event(#"{"type":"text","itemId":"last","text":"After","delta":true}"#))
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: [before, marker, after], live: live,
            run: run(.done), runId: "run", baselineIDs: [], pendingUser: nil)
        XCTAssertEqual(completion.messages, [before, marker, after])
    }

    func testNativeErrorIsNotDuplicatedAtCompletion() {
        let committed = DaemonMessage(id: "reply", chatId: "chat", role: .assistant, text: "", createdAt: "2026-09-11T10:00:05Z",
            parts: [.init(kind: .interaction, interaction: .init(kind: "error", detail: "Invalid API key"))])
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: [committed], live: LiveTurn(),
            run: run(.error, error: "Invalid API key"), runId: "run", baselineIDs: [], pendingUser: nil)
        XCTAssertEqual(completion.messages.last?.parts?.count, 1)
    }

    func testResultOnlyReplySurvivesMissingHistory() throws {
        var live = LiveTurn()
        live.apply(try event(#"{"type":"result","result":{"text":"Here is the answer."}}"#))
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: nil, live: live,
            run: run(.done), runId: "run", baselineIDs: [], pendingUser: nil, transportError: "History unavailable")
        XCTAssertNil(completion.error)
        XCTAssertEqual(completion.messages.last?.text, "Here is the answer.")
        XCTAssertEqual(completion.messages.last?.parts?.first?.text, "Here is the answer.")
    }

    func testFailedTurnNeverGraftsPartsOntoAnEarlierReply() throws {
        let old = DaemonMessage(id: "old", chatId: "chat", role: .assistant, text: "Old answer", createdAt: "2026-09-11T09:00:00Z")
        let user = DaemonMessage(id: "user", chatId: "chat", role: .user, text: "New question", createdAt: "2026-09-11T10:00:00Z")
        var live = LiveTurn()
        live.apply(try event(#"{"type":"thinking","text":"Checking","delta":true}"#))
        let completion = ChatTurnCompletion.reconcile(current: [old, user], fetched: [old, user], live: live,
            run: run(.error, error: "Invalid API key"), runId: "run", baselineIDs: ["old", "user"], pendingUser: user)
        XCTAssertNil(completion.messages[0].parts)
        XCTAssertEqual(completion.messages[0].text, "Old answer")
        XCTAssertEqual(completion.messages.last?.parts?.first?.kind, .thinking)
        XCTAssertEqual(completion.messages.last?.parts?.last?.interaction?.detail, "Invalid API key")
    }

    func testEmptyCompletedRunShowsAnError() {
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: [], live: LiveTurn(),
            run: run(.done), runId: "run", baselineIDs: [], pendingUser: nil)
        XCTAssertNotNil(completion.error)
        XCTAssertEqual(completion.messages.last?.parts?.last?.interaction?.kind, "error")
    }

    func testTextSnapshotCorrectsTheOriginalItemAfterATool() throws {
        var live = LiveTurn()
        live.apply(try event(#"{"type":"text","itemId":"answer","text":"Draft","delta":true}"#))
        live.apply(try event(#"{"type":"tool_use","tool":{"id":"tool","name":"shell"}}"#))
        live.apply(try event(#"{"type":"text","itemId":"answer","text":"Final","delta":false}"#))
        XCTAssertEqual(live.parts.count, 2)
        XCTAssertEqual(live.parts[0].text, "Final")
        XCTAssertEqual(live.parts[1].kind, .tool)
    }

    func testToolUpdatesKeepNormalizedDiffsAndFailure() throws {
        var live = LiveTurn()
        live.apply(try event(#"{"type":"tool_use","tool":{"id":"edit","name":"apply_patch"}}"#))
        live.apply(try event(#"{"type":"tool_use","tool":{"id":"edit","name":"apply_patch","output":"Applying"}}"#))
        live.apply(try event(#"{"type":"tool_result","tool":{"id":"edit","output":"Permission denied","isError":true,"action":{"kind":"file_edit","files":[{"path":"a.go","op":"edit","diff":"@@ -1 +1 @@\n-old\n+new"},{"path":"b.go","op":"delete"}]}}}"#))
        XCTAssertEqual(live.parts.count, 1)
        let tool = try XCTUnwrap(live.parts.first?.tool)
        XCTAssertEqual(tool.fileEdits.count, 2)
        XCTAssertTrue(tool.fileEdits[0].unifiedDiff?.contains("+new") == true)
        XCTAssertEqual(tool.output, "Permission denied")
        XCTAssertEqual(tool.isError, true)
    }

    func testPlanSnapshotsUpdateOneComponent() throws {
        var live = LiveTurn()
        live.apply(try event(#"{"type":"interaction","interaction":{"id":"plan","kind":"plan","detail":"Draft"}}"#))
        live.apply(try event(#"{"type":"interaction","interaction":{"id":"plan","kind":"plan","detail":"Final plan"}}"#))
        XCTAssertEqual(live.parts.count, 1)
        XCTAssertEqual(live.parts[0].interaction?.detail, "Final plan")
    }

    func testRecoveredErrorDoesNotFailASuccessfulTurn() throws {
        var live = LiveTurn()
        live.apply(try event(#"{"type":"error","error":"Connection reset"}"#))
        live.apply(try event(#"{"type":"result","result":{"text":"Recovered"}}"#))
        XCTAssertNil(live.error)
        XCTAssertEqual(live.text, "Recovered")
    }

    func testCompactionDoesNotBreakHistoryDecoding() throws {
        let json = #"[{"id":"compact","chatId":"chat","role":"system","text":"","createdAt":"2026-09-11T10:00:00Z","parts":[{"type":"compaction","compaction":{"summary":"Earlier context"}}]}]"#
        let messages = try JSONDecoder().decode([DaemonMessage].self, from: Data(json.utf8))
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].parts?[0].kind, .compaction)
        XCTAssertEqual(messages[0].parts?[0].compaction?.summary, "Earlier context")
    }
}
