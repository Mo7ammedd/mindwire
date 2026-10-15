import XCTest
import SwiftUI
import UIKit
@testable import Mindwire

/// Uses the real Codex CLI and daemon HTTP fixture, with a local model that cannot finish each
/// block until this client has displayed its partial update. No cloud account or real key is used.
@MainActor
final class CodexStreamingTests: XCTestCase {
    func testFoundryTurnsStreamIntoSharedFeed() async throws {
        guard let address = ProcessInfo.processInfo.environment["MINDWIRE_CODEX_STREAM_URL"],
              let baseURL = URL(string: address) else {
            throw XCTSkip("Run the daemon's TestCodexStreamingIOSFixture and set MINDWIRE_CODEX_STREAM_URL")
        }
        let credentials = FixtureCredentials(baseURL: baseURL)
        let channel = URLSessionDaemonChannel { method, path, body, force in
            await credentials.request(method: method, path: path, body: body, force: force)
        }
        let transport = ExecDaemonTransport(channel: channel, agentType: "codex")
        var history: [DaemonMessage] = []
        var finalParts: [DaemonMessagePart] = []

        do {
            for turn in 1...3 {
                if turn == 3 {
                    history = try await nativeModelTurn(transport: transport, channel: channel, turn: turn, cancelling: false)
                    finalParts = try XCTUnwrap(history.last?.parts)
                    continue
                }
                let baseline = Set(history.map(\.id))
                let run = try await transport.sendTurn(chatId: "ios-stream-chat",
                                                      message: "Stream probe \(turn)", cwd: nil)
                var live = LiveTurn()
                var seen: Set<String> = []
                var acknowledgements: [Task<Void, Error>] = []
                var streamOpens = 0
                var cursors: [Int?] = []
                let completed = try await ChatRunMonitor.follow(
                    openStreamAfter: { after in
                        streamOpens += 1
                        cursors.append(after)
                        guard let source = transport.streamRun(run.id, after: after) else { return nil }
                        // Disconnect during thinking, then during two different file operations.
                        // Each reconnect must resume the native run without losing or repeating parts.
                        let connection = streamOpens
                        return turn == 1 && connection <= 3 ? self.drop(source) { event in
                            if connection == 1 { return event.type == .thinking }
                            let marker = connection == 2 ? "+Hello from Codex streaming" : "+Updated while streaming"
                            return event.tool?.action?.files?.contains { $0.diff?.contains(marker) == true } == true
                        } : source
                    },
                    getRun: { try await transport.getRun(run.id) },
                    onEvent: { event in
                        live.apply(event)
                        var phase: String?
                        switch event.type {
                        case .thinking where event.text == "Checking ":
                            phase = "thinking"
                            XCTAssertEqual(live.parts.last?.text, "Checking ")
                        case .text where event.text == "Inspecting ":
                            phase = "commentary"
                            XCTAssertEqual(live.parts.last?.text, "Inspecting ")
                        case .text where event.text == "Finished ":
                            phase = "final"
                            XCTAssertEqual(live.parts.last?.text, "Finished ")
                        case .tool_use where event.tool?.output?.contains("tool output one") == true
                            && event.tool?.output?.contains("tool output two") != true:
                            phase = "tool"
                            XCTAssertTrue(live.parts.contains { $0.tool?.output?.contains("tool output one") == true })
                        default:
                            phase = nil
                        }
                        for file in event.tool?.action?.files ?? [] {
                            if file.diff?.contains("+Updated while streaming") == true { phase = "edit" }
                            else if file.diff?.contains("+Hello from Codex streaming") == true { phase = "create" }
                            else if file.diff?.contains("+let value239 = 239") == true { phase = "files" }
                        }
                        if let phase, seen.insert(phase).inserted {
                            let visibleParts = live.parts
                            acknowledgements.append(Task {
                                let current = try await transport.getRun(run.id)
                                XCTAssertEqual(current.status, .running, "\(phase) must be visible before completion")
                                if turn == 1, phase == "files" {
                                    let ids = Set(visibleParts.compactMap { $0.tool?.id })
                                    try await self.renderSharedFeed(visibleParts, expanded: ids, name: "Codex live file operations")
                                }
                                let response = try await channel.perform(method: "POST",
                                    path: "/fixture/ack/\(phase)-\(turn)", jsonBody: nil)
                                XCTAssertEqual(response.status, 204)
                            })
                        }
                    }
                )
                for acknowledgement in acknowledgements { try await acknowledgement.value }
                XCTAssertEqual(seen, ["thinking", "commentary", "tool", "create", "edit", "files", "final"])
                XCTAssertEqual(completed.status, .done, completed.error ?? "")
                XCTAssertNil(live.error)
                XCTAssertEqual(streamOpens, turn == 1 ? 4 : 1)
                XCTAssertNil(cursors[0])
                let resumed = cursors.compactMap { $0 }
                XCTAssertTrue(zip(resumed, resumed.dropFirst()).allSatisfy { $0 < $1 })
                assertParts(live.parts, turn: turn)

                let fetched = try await transport.listMessages(chatId: "ios-stream-chat", limit: nil, before: nil)
                let completion = ChatTurnCompletion.reconcile(current: history, fetched: fetched, live: live,
                    run: completed, runId: run.id, baselineIDs: baseline, pendingUser: nil)
                XCTAssertNil(completion.error)
                history = completion.messages
                XCTAssertEqual(history.count, turn * 2, "Every turn has one user and one assistant message")
                finalParts = try XCTUnwrap(history.last?.parts)
                assertParts(finalParts, turn: turn)
            }
            _ = try await nativeModelTurn(transport: transport, channel: channel, turn: 4, cancelling: true)
            let refreshes = await credentials.refreshes
            XCTAssertEqual(refreshes, 1, "An expired SSE gateway token must be refreshed once")
            let response = try await channel.perform(method: "GET", path: "/fixture/status", jsonBody: nil)
            let status = try JSONDecoder().decode(FixtureStatus.self, from: Data(response.body.utf8))
            XCTAssertEqual(status.requests, 20, "Three completed turns and an interrupted fourth retain provider authentication")
            XCTAssertTrue(status.errors?.isEmpty ?? true, "\(status.errors ?? [])")
            try await renderSharedFeed(finalParts)
        } catch {
            _ = try? await channel.perform(method: "POST", path: "/fixture/finish", jsonBody: nil)
            throw error
        }
        _ = try await channel.perform(method: "POST", path: "/fixture/finish", jsonBody: nil)
    }

    private func nativeModelTurn(transport: ExecDaemonTransport, channel: URLSessionDaemonChannel,
                                 turn: Int, cancelling: Bool) async throws -> [DaemonMessage] {
        let chat = ChatModel(chatId: "ios-stream-chat",
            session: DaemonSession(agentId: "codex", transport: transport), activity: ChatActivityStore())
        let host = UIHostingController(rootView: ChatTranscriptView(model: chat))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 680))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        defer { chat.dispose(); window.isHidden = true }
        await chat.load()
        await chat.send("Create a test project and explain the result")
        var seen: Set<String> = []
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, let live = chat.live {
            var phases: [String] = []
            if live.parts.contains(where: { $0.kind == .thinking && $0.text?.hasPrefix("Checking ") == true }) { phases.append("thinking") }
            if live.parts.contains(where: { $0.kind == .text && $0.text?.hasPrefix("Inspecting ") == true }) { phases.append("commentary") }
            if live.parts.contains(where: { $0.tool?.output?.contains("tool output one") == true }) { phases.append("tool") }
            let files = live.parts.compactMap(\.tool).flatMap(\.fileEdits)
            for (phase, marker) in [("create", "+Hello from Codex streaming"), ("edit", "+Updated while streaming"), ("files", "+let value239 = 239")] {
                if files.contains(where: { $0.unifiedDiff?.contains(marker) == true }) { phases.append(phase) }
            }
            if live.parts.last?.text == "Finished " { phases.append("final") }
            for phase in phases where seen.insert(phase).inserted {
                if phase == "files" {
                    XCTAssertEqual(files.count, 4)
                    XCTAssertTrue(files.contains { ($0.unifiedDiff?.utf8.count ?? 0) > 64000 }, "Exercise a large file event over URLSession")
                    if cancelling {
                        chat.dispose()
                        await chat.load()
                        for _ in 0..<400 {
                            if chat.live?.parts.compactMap(\.tool).flatMap(\.fileEdits).count == 4 && !chat.restoringRun { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        XCTAssertTrue(chat.thinking, "The daemon's running status restores Stop")
                        XCTAssertEqual(chat.live?.parts.compactMap(\.tool).flatMap(\.fileEdits).count, 4)
                        XCTAssertTrue(chat.autoExpandedToolIDs.isEmpty, "Reopened file cards are history")
                    }
                }
                if phase == "final", cancelling {
                    // Stop before the model completes its answer; do not release the final gate.
                    await chat.cancel()
                } else {
                    _ = try await channel.perform(method: "POST", path: "/fixture/ack/\(phase)-\(turn)", jsonBody: nil)
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(chat.thinking, "Native turn stalled; phases: \(seen)")
        XCTAssertEqual(seen, ["thinking", "commentary", "tool", "create", "edit", "files", "final"])
        XCTAssertNil(chat.turnError)
        XCTAssertEqual(chat.messages.count, turn * 2)
        let parts = try XCTUnwrap(chat.messages.last?.parts)
        if cancelling {
            XCTAssertEqual(parts.filter { $0.kind == .text }.map(\.text), ["Inspecting files.", "Finished "])
            XCTAssertEqual(parts.compactMap(\.tool).flatMap(\.fileEdits).count, 4)
        } else {
            assertParts(parts, turn: turn)
        }
        try await Task.sleep(for: .milliseconds(350))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: image).contains(cancelling ? "Finished" : "Finished turn \(turn)."),
                      "The latest answer must remain visible when live output becomes history")
        let attachment = XCTAttachment(image: image)
        attachment.name = "Native Codex \(cancelling ? "stopped" : "completed") transcript"
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/mindwire-native-\(cancelling ? "stopped" : "completed").png"))

        chat.dispose()
        await chat.load()
        XCTAssertFalse(chat.thinking)
        XCTAssertNil(chat.loadError)
        XCTAssertEqual(chat.messages.count, turn * 2)
        XCTAssertTrue(chat.autoExpandedToolIDs.isEmpty)
        let reopened = try XCTUnwrap(chat.messages.last?.parts)
        if cancelling {
            XCTAssertEqual(reopened.filter { $0.kind == .text }.map(\.text), ["Inspecting files.", "Finished "])
            XCTAssertEqual(reopened.compactMap(\.tool).flatMap(\.fileEdits).count, 4)
        } else {
            assertParts(reopened, turn: turn)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host)).contains(cancelling ? "Finished" : "Finished turn \(turn)."),
                      "Reopening must show the latest saved answer immediately")

        // Open a completely new model/view against a freshly loaded daemon store.
        // There is no old LiveTurn, activity cache, message array or SSE buffer to fall back to.
        chat.dispose()
        let persisted = ExecDaemonTransport(channel: PersistedHistoryChannel(channel: channel), agentType: "codex")
        let cold = ChatModel(chatId: "ios-stream-chat",
            session: DaemonSession(agentId: "codex", transport: persisted), activity: ChatActivityStore())
        defer { cold.dispose() }
        XCTAssertTrue(cold.messages.isEmpty)
        XCTAssertNil(cold.live)
        let coldHost = UIHostingController(rootView: ChatTranscriptView(model: cold))
        window.rootViewController = coldHost
        coldHost.view.frame = window.bounds
        coldHost.view.layoutIfNeeded()
        await cold.load()
        XCTAssertNil(cold.loadError)
        XCTAssertFalse(cold.thinking)
        XCTAssertEqual(cold.messages.count, turn * 2)
        XCTAssertTrue(cold.autoExpandedToolIDs.isEmpty)
        let saved = try XCTUnwrap(cold.messages.last?.parts)
        if cancelling {
            XCTAssertEqual(saved.filter { $0.kind == .text }.map(\.text), ["Inspecting files.", "Finished "])
            XCTAssertEqual(saved.compactMap(\.tool).flatMap(\.fileEdits).count, 4)
        } else {
            assertParts(saved, turn: turn)
        }
        try await Task.sleep(for: .milliseconds(150))
        let coldImage = ChatFeedSnapshot.image(coldHost)
        let visible = try ChatFeedSnapshot.visibleText(in: coldImage)
        XCTAssertTrue(visible.contains(cancelling ? "Finished" : "Finished turn \(turn)."),
                      "A new screen must draw the saved answer without any cached live output")
        XCTAssertTrue(visible.contains("notes-\(turn).md"), "The latest saved file card must also be visible")
        let coldAttachment = XCTAttachment(image: coldImage)
        coldAttachment.name = "Codex history loaded from disk into a new chat screen (turn \(turn))"
        coldAttachment.lifetime = .keepAlways
        add(coldAttachment)
        try coldImage.pngData()?.write(to: URL(fileURLWithPath: "/tmp/mindwire-cold-history-\(turn).png"))
        return cold.messages
    }

    private func assertParts(_ parts: [DaemonMessagePart], turn: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(parts.filter { $0.kind == .thinking }.map(\.text), ["Checking the workspace."], file: file, line: line)
        XCTAssertEqual(parts.filter { $0.kind == .text }.map(\.text), ["Inspecting files.", "Finished turn \(turn)."], file: file, line: line)
        let tools = parts.compactMap(\.tool)
        let commands = tools.filter { $0.action?.kind == "shell" }
        XCTAssertEqual(commands.count, 1, "The same tool is updated instead of repeated", file: file, line: line)
        XCTAssertTrue(commands.first?.output?.contains("tool output one") == true, file: file, line: line)
        XCTAssertTrue(commands.first?.output?.contains("tool output two") == true, file: file, line: line)
        XCTAssertFalse(tools.contains { $0.isError == true }, file: file, line: line)
        let files = tools.flatMap(\.fileEdits)
        XCTAssertEqual(files.count, 4, "Creates, updates and multi-file patches use common diff cards", file: file, line: line)
        XCTAssertTrue(files.first?.path.hasSuffix("result-\(turn).txt") == true, file: file, line: line)
        XCTAssertTrue(files.first?.unifiedDiff?.contains("+Hello from Codex streaming") == true, file: file, line: line)
        XCTAssertTrue(files.contains { $0.unifiedDiff?.contains("+Updated while streaming") == true }, file: file, line: line)
        XCTAssertTrue(files.contains { $0.unifiedDiff?.contains("+let value239 = 239") == true }, file: file, line: line)
    }

    private func drop(_ source: AsyncThrowingStream<DaemonEvent, Error>, when shouldDrop: @escaping (DaemonEvent) -> Bool) -> AsyncThrowingStream<DaemonEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source {
                        continuation.yield(event)
                        if shouldDrop(event) {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func renderSharedFeed(_ parts: [DaemonMessagePart], expanded: Set<String> = [], name: String = "Codex shared chat feed") async throws {
        let host = UIHostingController(rootView:
            ScrollView {
                TurnPartsView(parts: parts, autoExpandedToolIDs: expanded).padding(20)
            }
            .frame(width: 390, height: 680)
            .background(Color(.systemBackground))
        )
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 680)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/mindwire-codex-feed.png"))
    }
}

private struct FixtureStatus: Decodable {
    let requests: Int
    let errors: [String]?
}

/// The fixture rebuilds the real daemon read API from its saved state at this prefix.
private struct PersistedHistoryChannel: DaemonChannel {
    let channel: URLSessionDaemonChannel
    var label: String { "persisted-codex-history" }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        try await channel.perform(method: method, path: "/fixture/persisted" + path, jsonBody: jsonBody)
    }
}

private actor FixtureCredentials {
    let baseURL: URL
    private(set) var refreshes = 0
    private var token = "gateway-old"

    init(baseURL: URL) { self.baseURL = baseURL }

    func request(method: String, path: String, body: Data?, force: Bool) -> URLRequest {
        if force {
            refreshes += 1
            token = "gateway-fresh"
        }
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("local-daemon-token", forHTTPHeaderField: "X-Mindwire-Token")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
}
