import XCTest
import UIKit
import UserNotifications
@testable import Mindwire

@MainActor
final class CommunicationNotificationTests: XCTestCase {
    func testBundledHarnessArtworkProducesVisibleTransparentAvatars() throws {
        for harness in ["codex", "claude-code", "grok", "opencode", "future-harness"] {
            let data = try CommunicationNotification.avatarPNG(for: AgentBrand.resolve(harness))
            let image = try XCTUnwrap(UIImage(data: data), harness)
            let cgImage = try XCTUnwrap(image.cgImage, harness)
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 32, height: 32,
                                                      bitsPerComponent: 8, bytesPerRow: 32 * 4,
                                                      space: CGColorSpaceCreateDeviceRGB(),
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            let ink = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 32 }.count
            XCTAssertGreaterThan(ink, 20, "\(harness) must contain artwork, not an empty SVG rasterization")
            let transparent = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] == 0 }.count
            XCTAssertGreaterThan(transparent, 100, "\(harness) must preserve transparency without an added background")
            let attachment = XCTAttachment(image: image)
            attachment.name = "notification-avatar-\(harness)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testHarnessIsTheSenderAndChatIsTheConversation() throws {
        for (id, name, nested) in [("codex", "Codex", false), ("claude-code", "Claude Code", true)] {
            let content = UNMutableNotificationContent()
            content.body = "Your changes are ready."
            let data = ["agent": id, "chatId": "chat-123", "target_type": "chat", "target_id": "chat-123"]
            content.userInfo = nested ? ["data": data] : data
            let intent = try XCTUnwrap(CommunicationNotification.intent(for: content))
            XCTAssertEqual(intent.sender?.displayName, name)
            XCTAssertNotNil(intent.sender?.image)
            XCTAssertEqual(intent.conversationIdentifier, "chat-123")
            XCTAssertEqual(intent.content, content.body)
            XCTAssertTrue(intent.recipients?.isEmpty ?? true)
            XCTAssertEqual(PushTarget(payload: content.userInfo), .chat("chat-123"))
        }
    }

    func testNonHarnessNotificationsKeepTheirOriginalPresentation() async throws {
        let content = UNMutableNotificationContent()
        content.title = "Workspace update"
        content.body = "Your workspace is ready."
        content.userInfo = ["workspace_id": "workspace-123"]
        XCTAssertNil(try CommunicationNotification.intent(for: content))
        let updated = try await CommunicationNotification.content(from: content)
        XCTAssertEqual(updated.title, content.title)
        XCTAssertEqual(updated.body, content.body)
        XCTAssertEqual(PushTarget(payload: updated.userInfo), .workspace("workspace-123"))
    }
}
