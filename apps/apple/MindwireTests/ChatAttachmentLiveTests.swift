import XCTest
import UIKit
import AVFoundation
@testable import Mindwire

/// Opt-in physical-device check through the saved computer pairing. The host runs
/// TestNativeQueuedInput with MINDWIRE_IPHONE_ATTACHMENT_FIXTURE pointing to a private handoff.
@MainActor
final class ChatAttachmentLiveTests: XCTestCase {
    private struct Fixture: Decodable {
        let port: Int, token: String, cwd: String, fileMarker: String, computerId: String
    }
    private struct State: Decodable { let started: Bool, image: Bool, audio: Bool, fileRead: Bool, blocked: Bool }

    func testPhoneUploadsFilesAndImagesToNativeCodexThenStopsAndSends() async throws {
        guard let value = ProcessInfo.processInfo.environment["MINDWIRE_ATTACHMENT_FIXTURE"] else {
            throw XCTSkip("Provide the isolated native attachment fixture to run on a paired iPhone.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("This check uses the physical phone's saved SSH pairing.")
        #else
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(value.utf8))
        let connection = try XCTUnwrap(Stores.shared.connections.list().first {
            $0.pairedComputer?.computerId == fixture.computerId
        }, "The phone must already be paired with this Mac")
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }

        // Reuse the production grant and native SSH forwarding implementation.
        let forward = ConnectionPortForward(connection: connection, port: fixture.port)
        defer { forward.stop() }
        let localPort = try await forward.ready()
        let base = URL(string: "http://127.0.0.1:\(localPort)")!
        let channel = URLSessionDaemonChannel(label: "attachment-live-ssh") { method, path, body, _ in
            var request = URLRequest(url: URL(string: path, relativeTo: base)!)
            request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 25
            request.setValue("Bearer \(fixture.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return request
        }
        let http = DaemonHTTP(channel: channel, agentType: "codex")
        let transport = ExecDaemonTransport(channel: channel, agentType: "codex")
        let session = DaemonSession(agentId: "attachment-live-test", transport: transport)
        let health = await transport.health()
        XCTAssertEqual(health.attachmentUploadVersion, 1)

        let draft = ChatImageDraft()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            ("MindWire attachment check" as NSString).draw(at: CGPoint(x: 32, y: 32),
                withAttributes: [.font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.white])
        }
        await draft.importCamera(image)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        let fileData = Data((fixture.fileMarker + "\n").utf8) + Data(repeating: 65, count: 700_000)
        try fileData.write(to: file)
        let recording = directory.appendingPathComponent("voice.m4a")
        try writeAudioFixture(to: recording)
        let audioData = try Data(contentsOf: recording)
        await draft.importFiles([recording, file])
        XCTAssertNil(draft.error)
        XCTAssertEqual(draft.attachments.count, 3)
        var progress: [Double] = []
        let chatID = "phone-attachment-check"
        let first = try await session.sendTurn(chatId: chatID, message: "MW_INPUT_INITIAL: inspect my image, recording and notes",
            cwd: fixture.cwd, requestId: "phone-initial", attachments: draft.attachments,
            attachmentProgress: { progress.append($0) })
        try await eventually { let state: State = try await http.decode("GET", "/__fixture/state"); return state.started }
        XCTAssertEqual(progress.last, 1)
        XCTAssertGreaterThan(progress.count, 2, "A file larger than one chunk reports real transfer progress")
        _ = try await http.run("POST", "/__fixture/release", json: nil)
        let finished = try await terminal(first.id, transport: transport)
        XCTAssertEqual(finished.status, .done, finished.error ?? "Native turn failed")
        let state: State = try await http.decode("GET", "/__fixture/state")
        XCTAssertTrue(state.image, "Codex receives native image input")
        XCTAssertTrue(state.audio, "An audio-capable model receives the phone's original M4A through native Codex audio input")
        XCTAssertTrue(state.fileRead, "Codex actually reads the uploaded file with its command tool")

        // A fresh transport reads the durable history and previews over the tunnel.
        let reopened = ExecDaemonTransport(channel: channel, agentType: "codex")
        let history = try await reopened.listMessages(chatId: chatID, limit: 50, before: nil)
        let sent = try XCTUnwrap(history.first { $0.role == .user })
        let attachments = try XCTUnwrap(sent.attachments)
        XCTAssertEqual(attachments.count, 3)
        XCTAssertFalse(sent.text.contains("Attached files:"))
        for attachment in attachments {
            XCTAssertNil(attachment.data, "History must contain references, not large copied payloads")
            let bytes = try await reopened.attachmentData(XCTUnwrap(attachment.artifactId))
            if attachment.isImage { XCTAssertNotNil(UIImage(data: bytes)) }
            else if attachment.isAudio { XCTAssertEqual(bytes, audioData) }
            else { XCTAssertEqual(bytes, fileData) }
        }

        let blocked = try await session.sendTurn(chatId: chatID, message: "MW_INPUT_BLOCK", cwd: fixture.cwd,
                                                requestId: "phone-stop-check")
        try await eventually { let state: State = try await http.decode("GET", "/__fixture/state"); return state.blocked }
        try await transport.cancelRun(blocked.id)
        let cancelled = try await terminal(blocked.id, transport: transport)
        XCTAssertEqual(cancelled.status, .cancelled)
        let next = try await session.sendTurn(chatId: chatID, message: "MW_INPUT_FOLLOW_AFTER_STOP", cwd: fixture.cwd,
                                             requestId: "phone-after-stop")
        XCTAssertNotEqual(next.id, blocked.id)
        let nextResult = try await terminal(next.id, transport: transport)
        XCTAssertEqual(nextResult.status, .done, nextResult.error ?? "Send after Stop failed")
        _ = try await http.run("POST", "/__fixture/finish", json: nil)
        print("Physical iPhone: image, original AAC audio, multi-chunk file, native Codex read, history preview, and Stop → Send passed over paired SSH.")
        #endif
    }

    /// The same AAC format as recording, generated locally without opening the microphone.
    private func writeAudioFixture(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 24_000)) * 0.05 }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ])
        try file.write(from: buffer)
    }

    private func terminal(_ id: String, transport: ExecDaemonTransport) async throws -> DaemonRun {
        for _ in 0..<120 {
            let run = try await transport.getRun(id)
            if run.status != .running { return run }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw NSError(domain: "ChatAttachmentLiveTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Native run did not reach its terminal state"])
    }

    private func eventually(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw NSError(domain: "ChatAttachmentLiveTests", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Native model request did not arrive"])
    }
}
