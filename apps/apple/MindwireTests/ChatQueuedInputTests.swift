import XCTest
@testable import Mindwire

@MainActor
final class ChatQueuedInputTests: XCTestCase {
    private struct Capture: Decodable {
        var run: DaemonRun
        var events: [DaemonEvent]
        var messages: [DaemonMessage]
    }

    private func capture(_ name: String) throws -> Capture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "\(name)-queued-input", withExtension: "json"))
        return try JSONDecoder().decode(Capture.self, from: Data(contentsOf: url))
    }

    /// Production daemon events and native history from the real Codex and Claude
    /// executables, using an isolated local model. Claude combines the two inputs.
    func testNativeQueuedTurnsReconcileWithoutDuplicatingMessagesOrResponses() throws {
        for harness in ["codex", "claude-code"] {
            let fixture = try capture(harness)
            var live = LiveTurn()
            fixture.events.forEach { live.apply($0) }
            let inputs = live.parts.compactMap(\.input)
            XCTAssertEqual(inputs.map(\.id), ["follow-one", "follow-two"], harness)
            XCTAssertEqual(inputs.last?.attachments?.count, 1, harness)
            let rows = ChatTranscriptRow.make(messages: [], live: live, runID: fixture.run.id)
            XCTAssertEqual(rows.compactMap { $0.message?.role == .user ? $0.message?.id : nil },
                           ["input-follow-one", "input-follow-two"], harness)

            let completion = ChatTurnCompletion.reconcile(current: [], fetched: fixture.messages, live: live,
                run: fixture.run, runId: fixture.run.id, baselineIDs: [], pendingUser: nil)
            XCTAssertNil(completion.error, harness)
            XCTAssertEqual(completion.messages.map(\.id), fixture.messages.map(\.id), harness)
            XCTAssertEqual(completion.messages.filter { $0.role == .user }, fixture.messages.filter { $0.role == .user }, harness)
            XCTAssertEqual(visibleText(completion.messages), visibleText(fixture.messages), harness)
        }
    }

    func testLaggingHistoryRetainsEveryAcceptedInputAndImage() throws {
        for harness in ["codex", "claude-code"] {
            let fixture = try capture(harness)
            var live = LiveTurn()
            fixture.events.forEach { live.apply($0) }
            let initial = try XCTUnwrap(fixture.messages.first)
            let histories: [[DaemonMessage]?] = [nil, [initial]]
            for fetched in histories {
                let completion = ChatTurnCompletion.reconcile(current: [initial], fetched: fetched, live: live,
                    run: fixture.run, runId: fixture.run.id, baselineIDs: [initial.id], pendingUser: nil)
                let users = completion.messages.filter { $0.role == .user }
                XCTAssertEqual(users.map(\.text), ["MW_INPUT_INITIAL", "MW_INPUT_FOLLOW_ONE", "MW_INPUT_FOLLOW_TWO"], harness)
                XCTAssertEqual(users.last?.attachments?.count, 1, harness)
                XCTAssertEqual(visibleText(completion.messages), visibleText(fixture.messages), harness)
                XCTAssertNil(completion.error, harness)
            }
        }
    }

    func testQueuedAndFailedInputsDoNotAppearSentUntilNativeAcceptance() throws {
        let fixture = try capture("codex")
        var live = LiveTurn()
        let input = try XCTUnwrap(fixture.run.inputs?.first)
        var queued = input
        queued.status = "queued"
        live.apply(DaemonEvent(type: .input, input: queued))
        queued.status = "failed"
        live.apply(DaemonEvent(type: .input, input: queued))
        XCTAssertTrue(live.parts.isEmpty)
        live.apply(DaemonEvent(type: .input, input: input))
        live.apply(DaemonEvent(type: .input, input: input))
        XCTAssertEqual(live.parts.compactMap(\.input).map(\.id), [input.id])
    }

    func testRepeatedFollowupsRemainDistinctAndRecoverMissingLastOccurrence() {
        let run = DaemonRun(id: "run", chatId: "chat", status: .done, createdAt: "2026-10-06T10:00:00Z")
        let original = DaemonMessage(id: "original", chatId: "chat", role: .user, text: "Again", createdAt: run.createdAt)
        var live = LiveTurn()
        live.apply(DaemonEvent(type: .text, itemId: "first", text: "First answer"))
        let inputs = (1...2).map { DaemonUserInput(id: "\($0)", text: "Again",
            createdAt: "2026-10-06T10:00:0\($0)Z", status: "accepted") }
        for input in inputs { live.apply(DaemonEvent(type: .input, input: input)) }
        live.apply(DaemonEvent(type: .text, itemId: "last", text: "Last answer"))
        let partial = [original, inputs[0].message(chatId: "chat")]
        let completion = ChatTurnCompletion.reconcile(current: partial, fetched: partial, live: live,
            run: run, runId: run.id, baselineIDs: [original.id], pendingUser: nil)
        XCTAssertEqual(completion.messages.filter { $0.role == .user }.map(\.id), [original.id, "input-1", "input-2"])
        XCTAssertEqual(visibleText(completion.messages), ["First answer", "Last answer"])
    }

    private func visibleText(_ messages: [DaemonMessage]) -> [String] {
        messages.filter { $0.role == .assistant }.flatMap { message in
            message.parts?.compactMap { $0.kind == .text ? $0.text : nil } ?? [message.text]
        }
    }
}
