import XCTest
@testable import Mindwire

@MainActor
final class ChatReconnectionTests: XCTestCase {
    private func run(_ status: RunStatus) -> DaemonRun {
        DaemonRun(id: "run", chatId: "chat", status: status, createdAt: "2026-09-14T10:00:00Z")
    }

    func testRepeatedDisconnectsResumeFileOperationsFromLastSequence() async throws {
        var cursors: [Int?] = []
        var live = LiveTurn()
        let terminal = try await ChatRunMonitor.follow(openStreamAfter: { after in
            cursors.append(after)
            let connection = cursors.count
            return AsyncThrowingStream { continuation in
                if connection <= 3 {
                    let tool = DaemonToolEvent(id: "file-\(connection)", name: "apply_patch",
                        action: DaemonToolAction(kind: "file_edit", files: [
                            DaemonFileChange(path: "File\(connection).swift", op: "add", diff: "@@ -0,0 +1 @@\n+let n = \(connection)")
                        ]))
                    continuation.yield(DaemonEvent(type: .tool_use, sequence: connection * 2 - 1, tool: tool))
                    continuation.yield(DaemonEvent(type: .tool_result, sequence: connection * 2, tool: tool))
                } else {
                    continuation.yield(DaemonEvent(type: .text, sequence: 7, text: "Built the app.", delta: true))
                }
                continuation.finish(throwing: URLError(.networkConnectionLost))
            }
        }, getRun: { self.run(cursors.count < 4 ? .running : .done) },
        onEvent: { live.apply($0) }, wait: {})
        XCTAssertEqual(cursors, [nil, 2, 4, 6])
        XCTAssertEqual(terminal.status, .done)
        XCTAssertEqual(live.parts.compactMap(\.tool).flatMap(\.fileEdits).map(\.path),
                       ["File1.swift", "File2.swift", "File3.swift"])
        XCTAssertEqual(live.text, "Built the app.")
    }

    func testSequenceGapRequestsMissingEventsWithoutDuplicatingText() async throws {
        var cursors: [Int?] = []
        var live = LiveTurn()
        _ = try await ChatRunMonitor.follow(openStreamAfter: { after in
            cursors.append(after)
            let sequences = cursors.count == 1 ? [1, 3] : [1, 2, 3]
            return AsyncThrowingStream { continuation in
                for sequence in sequences {
                    continuation.yield(DaemonEvent(type: .text, sequence: sequence, itemId: "reply",
                                                  text: "\(sequence)", delta: true))
                }
                continuation.finish()
            }
        }, getRun: { self.run(cursors.count < 2 ? .running : .done) },
        onEvent: { live.apply($0) }, wait: {})
        XCTAssertEqual(cursors, [nil, 1])
        XCTAssertEqual(live.text, "123")
    }

    func testSavedCursorOpensTheSuffixBeforeRequestingAnySnapshot() async throws {
        var cursors: [Int?] = []
        var snapshots = 0
        var live = LiveTurn()
        live.apply(.init(type: .text, itemId: "answer", text: "Cached ", delta: true))
        _ = try await ChatRunMonitor.follow(openStreamAfter: { after in
            cursors.append(after)
            return AsyncThrowingStream { continuation in
                continuation.yield(.init(type: .text, sequence: 42, itemId: "answer", text: "new", delta: true))
                continuation.finish()
            }
        }, getRun: { self.run(.done) }, getSnapshot: {
            XCTAssertFalse(cursors.isEmpty, "A cached checkpoint must bypass snapshot download on return")
            snapshots += 1
            return nil
        }, after: 41, restore: true, onEvent: { live.apply($0) }, wait: {})
        XCTAssertEqual(cursors, [41])
        XCTAssertEqual(live.text, "Cached new")
        XCTAssertEqual(snapshots, 1, "Terminal reconciliation may still check the final snapshot")
    }

    func testMissingRetainedEventsRecoverASnapshotInsteadOfLoopingOnTheSameGap() async throws {
        var cursors: [Int?] = []
        var live = LiveTurn()
        let terminal = try await ChatRunMonitor.follow(openStreamAfter: { after in
            cursors.append(after)
            return AsyncThrowingStream { continuation in
                continuation.yield(.init(type: .text, sequence: 15, itemId: "answer", text: "new", delta: true))
                continuation.finish()
            }
        }, getRun: { self.run(cursors.count == 1 ? .running : .done) }, getSnapshot: {
            let done = cursors.count > 1
            return DaemonRunSnapshot(run: self.run(done ? .done : .running), sequence: done ? 15 : 14,
                parts: [.init(kind: .text, id: "answer", text: done ? "Recovered new" : "Recovered ")])
        }, after: 10, restore: true, onEvent: { live.apply($0) }, onSnapshot: { live = LiveTurn(snapshot: $0) }, wait: {})
        XCTAssertEqual(terminal.status, .done)
        XCTAssertEqual(cursors, [10, 14])
        XCTAssertEqual(live.text, "Recovered new")
    }

    func testTerminalStatusReconcilesEvenWhenStreamNeverCloses() async throws {
        let closed = expectation(description: "Stream reader is cancelled at completion")
        let terminal = try await ChatRunMonitor.follow(openStreamAfter: { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(DaemonEvent(type: .text, sequence: 1, text: "Partial", delta: true))
                continuation.onTermination = { _ in closed.fulfill() }
            }
        }, getRun: { self.run(.done) }, onEvent: { _ in }, checkInterval: .milliseconds(10))
        XCTAssertEqual(terminal.status, .done)
        await fulfillment(of: [closed], timeout: 1)
    }

    func testLeavingCancelsObservationWithoutCancellingTheDaemonRun() async throws {
        let opened = expectation(description: "Open stream")
        let closed = expectation(description: "Close local stream")
        var opens = 0, polls = 0
        let task = Task {
            try await ChatRunMonitor.follow(openStreamAfter: { _ in
                opens += 1
                return AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in closed.fulfill() }
                    opened.fulfill()
                }
            }, getRun: { polls += 1; return self.run(.running) }, onEvent: { _ in })
        }
        await fulfillment(of: [opened], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must end observation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [closed], timeout: 1)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(polls, 0)
    }

    func testQuietOpenStreamRecoversMissingFileFromDaemonSnapshot() async throws {
        var cursors: [Int?] = []
        var live = LiveTurn()
        let file = DaemonMessagePart(kind: .tool, tool: DaemonToolCall(id: "file", name: "apply_patch",
            action: DaemonToolAction(kind: "file_edit", files: [DaemonFileChange(path: "App.swift", op: "create", diff: "@@ -0,0 +1 @@\n+let value = 1")])) )
        let terminal = try await ChatRunMonitor.follow(openStreamAfter: { after in
            cursors.append(after)
            return AsyncThrowingStream { continuation in
                if after == nil {
                    continuation.yield(DaemonEvent(type: .text, sequence: 1, itemId: "answer", text: "Creating files.", delta: true))
                    // The connection stays open but the proxy never delivers event 2.
                } else {
                    continuation.yield(DaemonEvent(type: .text, sequence: 3, itemId: "final", text: "Done.", delta: true))
                    continuation.finish()
                }
            }
        }, getRun: { self.run(cursors.count > 1 ? .done : .running) }, getSnapshot: {
            let done = cursors.count > 1
            return DaemonRunSnapshot(run: self.run(done ? .done : .running), sequence: done ? 3 : 2,
                parts: [.init(kind: .text, id: "answer", text: "Creating files."), file] + (done ? [.init(kind: .text, id: "final", text: "Done.")] : []))
        }, onEvent: { live.apply($0) }, onSnapshot: { live = LiveTurn(snapshot: $0) },
           checkInterval: .milliseconds(10), quietInterval: .milliseconds(15), wait: {})
        XCTAssertEqual(terminal.status, .done)
        XCTAssertEqual(cursors, [nil, 2])
        XCTAssertEqual(live.parts.compactMap(\.tool).flatMap(\.fileEdits).map(\.path), ["App.swift"])
        XCTAssertEqual(live.text, "Creating files.Done.")
    }

    func testTerminalSnapshotIncludesOutputStillQueuedWhenStopCompletes() async throws {
        var live = LiveTurn()
        _ = try await ChatRunMonitor.follow(openStreamAfter: { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(DaemonEvent(type: .text, sequence: 1, itemId: "answer", text: "Partial", delta: true))
            }
        }, getRun: { self.run(.cancelled) }, getSnapshot: {
            DaemonRunSnapshot(run: self.run(.cancelled), sequence: 2,
                              parts: [.init(kind: .text, id: "answer", text: "Partial output received before stopping")])
        }, onEvent: { live.apply($0) }, onSnapshot: { live = LiveTurn(snapshot: $0) }, checkInterval: .milliseconds(10))
        XCTAssertEqual(live.text, "Partial output received before stopping")
    }

    func testResultOnlySnapshotMaterializesTheAnswerOnce() {
        for parts: [DaemonMessagePart] in [[], [.init(kind: .text, text: "Complete answer")]] {
            let snapshot = DaemonRunSnapshot(run: run(.done), sequence: 1, parts: parts,
                                             result: DaemonResultInfo(text: "Complete answer", isError: false))
            let live = LiveTurn(snapshot: snapshot)
            XCTAssertEqual(live.parts.count, 1)
            XCTAssertEqual(live.text, "Complete answer")
        }
    }
}
