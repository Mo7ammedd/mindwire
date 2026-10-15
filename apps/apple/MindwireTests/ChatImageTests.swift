import XCTest
import UIKit
import ImageIO
@testable import Mindwire

@MainActor
final class ChatImageTests: XCTestCase {
    func testPhotoImportBoundsDimensionsSizeAndNormalizesFormat() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1800)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1800))
            ("Screenshot detail" as NSString).draw(at: CGPoint(x: 80, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 120)])
        }
        let data = try XCTUnwrap(image.pngData())
        let attachment = try await Task.detached { try ChatImageEncoding.prepare(data, name: "photo.jpg") }.value
        let bytes = try XCTUnwrap(attachment.data)
        XCTAssertLessThanOrEqual(bytes.count, ChatImageEncoding.maximumBytes)
        XCTAssertEqual(attachment.mime, "image/jpeg")
        let decoded = try XCTUnwrap(UIImage(data: bytes))
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 2048)
        XCTAssertNotNil(ChatImageEncoding.thumbnail(attachment))
        XCTAssertThrowsError(try ChatImageEncoding.prepare(Data("not an image".utf8), name: "invalid.jpg"))
    }

    func testCameraAndFilesShareTheDraftWithoutLosingFileBytes() async throws {
        let draft = ChatImageDraft()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        await draft.importCamera(image)
        XCTAssertEqual(draft.attachments.count, 1)
        XCTAssertTrue(draft.attachments[0].isImage)
        XCTAssertNotNil(ChatImageEncoding.thumbnail(draft.attachments[0]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 0x31, count: 700_000)
        let file = root.appendingPathComponent("notes.txt")
        try data.write(to: file)
        let svg = root.appendingPathComponent("logo.svg")
        try Data("<svg/>".utf8).write(to: svg)
        await draft.importFiles([file, svg])
        XCTAssertNil(draft.error)
        XCTAssertEqual(draft.attachments.count, 3)
        XCTAssertEqual(draft.attachments[1].data, data)
        XCTAssertFalse(draft.attachments[2].isImage, "SVG stays a file for the agent to inspect")
        await draft.importFiles([root])
        XCTAssertNotNil(draft.error, "Folders require an explicit archive")
        XCTAssertEqual(draft.attachments.count, 3)
    }

    func testLongToolOutputStaysBoundedButDoesNotAlterSmallOutput() {
        let short = "one\ntwo\n"
        XCTAssertEqual(ToolOutputPreview(short).text, short)
        XCTAssertFalse(ToolOutputPreview(short).isTruncated)
        let long = (0..<20_000).map { "line \($0)" }.joined(separator: "\n")
        let preview = ToolOutputPreview(long)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertLessThan(preview.text.count, 300)
        XCTAssertFalse(preview.text.contains("line 19999"))
        let singleLine = ToolOutputPreview(String(repeating: "x", count: 200_000))
        XCTAssertTrue(singleLine.isTruncated)
        XCTAssertLessThan(singleLine.text.count, 4_010)
    }

    func testImagesUseUnifiedTurnOptionsAndRejectOversizedInputBeforeSending() async throws {
        let channel = ImageTurnChannel()
        let transport = ExecDaemonTransport(channel: channel, agentType: "codex")
        let attachment = DaemonAttachment(name: "image.jpg", mime: "image/jpeg", data: Data([1, 2, 3]))
        _ = try? await transport.sendTurn(chatId: "chat", message: "", cwd: "/project", gitAuth: nil,
            requestId: "receipt", attachments: [attachment])
        let payloads = await channel.payloads
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.message, "")
        XCTAssertEqual(payload.options.attachments, [attachment])
        XCTAssertEqual(payload.requestId, "receipt")
        do {
            _ = try await transport.sendTurn(chatId: "chat", message: String(repeating: "x", count: 1_024 * 1_024),
                cwd: nil, gitAuth: nil, requestId: "oversized", attachments: [attachment])
            XCTFail("Oversized request was sent")
        } catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
        let count = await channel.payloads.count
        XCTAssertEqual(count, 1)
    }

    func testFailedImageSendRestoresDraftAndOnlyUnchangedImagesReuseReceipt() async throws {
        let channel = ImageTurnChannel()
        let model = ChatModel(chatId: "chat", session: DaemonSession(agentId: "image-test",
            transport: ExecDaemonTransport(channel: channel, agentType: "codex")), activity: ChatActivityStore())
        defer { model.dispose() }
        let first = DaemonAttachment(name: "image.jpg", mime: "image/jpeg", data: Data([1, 2, 3]))
        await model.send("", attachments: [first])
        XCTAssertEqual(model.lastFailedInput, "")
        XCTAssertEqual(model.lastFailedAttachments, [first])
        XCTAssertTrue(model.messages.isEmpty)
        await model.send("", attachments: [first])
        var changed = first; changed.data = Data([4, 5, 6])
        await model.send("", attachments: [changed])
        let payloads = await channel.payloads
        XCTAssertEqual(payloads.count, 3)
        guard payloads.count == 3 else { return }
        XCTAssertEqual(payloads[0].requestId, payloads[1].requestId)
        XCTAssertNotEqual(payloads[1].requestId, payloads[2].requestId)
    }

    func testImageOnlyHistorySurvivesCompletionAndDecodeWithoutDuplicateBubble() throws {
        let image = DaemonAttachment(name: "photo.jpg", mime: "image/jpeg", data: Data([1, 2, 3]))
        let message = DaemonMessage(id: "native", chatId: "chat", role: .user, text: "", createdAt: isoNow(), attachments: [image])
        let restored = try JSONDecoder().decode(DaemonMessage.self, from: JSONEncoder().encode(message))
        var pending = message
        pending.attachments = [image]
        let result = ChatTurnCompletion.reconcile(current: [pending], fetched: [restored], live: LiveTurn(),
            run: nil, runId: "run", baselineIDs: [], pendingUser: pending)
        XCTAssertEqual(result.messages, [restored])
        let rows = ChatTranscriptRow.make(messages: result.messages, live: nil, runID: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].message?.attachments, [image])
    }
}

private actor ImageTurnChannel: DaemonChannel {
    nonisolated let label = "image-fixture"
    struct Payload: Decodable {
        struct Options: Decodable { let attachments: [DaemonAttachment] }
        let message: String
        let requestId: String
        let options: Options
    }
    private(set) var payloads: [Payload] = []
    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        switch path.split(separator: "?")[0] {
        case "/healthz": return (200, #"{"ok":true,"turnRequestVersion":1,"imageAttachmentsVersion":1}"#)
        case "/agent": return (200, #"{"version":"test","agentType":"codex","name":"Codex","schema":{"sections":[]},"installedVersion":"test","configured":true,"capabilities":{"imageInput":true}}"#)
        case "/turns":
            payloads.append(try JSONDecoder().decode(Payload.self, from: XCTUnwrap(jsonBody)))
            return (400, #"{"error":"Fixture failed before accepting the turn"}"#)
        default: return (404, "{}")
        }
    }
}
