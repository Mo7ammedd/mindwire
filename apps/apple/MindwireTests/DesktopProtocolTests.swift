import XCTest
import UIKit
import Crypto
import NIOSSH
@testable import Mindwire

@MainActor
final class DesktopProtocolTests: XCTestCase {
    func testFrameBurstCopiesOnlyTheLatestPendingDisplay() async throws {
        let queue = DispatchQueue(label: "desktop-frame-burst-test")
        let delivery = DesktopFrameDelivery<CGImage>(queue: queue)
        defer { delivery.close() }
        let image = try frameImage()
        let shown = expectation(description: "latest display presented")
        var copies = 0
        var selected = -1
        queue.suspend()
        for index in 0..<1000 {
            delivery.submit { copies += 1; selected = index; return image }
        }
        delivery.onFrame = { frame in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(frame === image)
            shown.fulfill()
        }
        queue.resume()
        await fulfillment(of: [shown], timeout: 3)
        XCTAssertEqual(copies, 1, "Dirty regions must not each copy the full Retina display")
        XCTAssertEqual(selected, 999)
    }

    func testSlowPresentationDoesNotQueueCopiesAndKeepsTheFinalUpdate() async throws {
        let queue = DispatchQueue(label: "desktop-frame-backpressure-test")
        let delivery = DesktopFrameDelivery<CGImage>(queue: queue)
        defer { delivery.close() }
        let first = try frameImage()
        let resized = try frameImage(width: 3)
        let shown = expectation(description: "initial and final displays")
        shown.expectedFulfillmentCount = 2
        var copies = 0
        var widths: [Int] = []
        delivery.onFrame = { frame in widths.append(frame.width); shown.fulfill() }
        delivery.submit { copies += 1; return first }
        queue.sync {} // Rendering finishes; the main actor is still busy here.
        for _ in 0..<1000 { delivery.submit { copies += 1; return resized } }
        queue.sync {}
        XCTAssertEqual(copies, 1, "Only one copied frame may wait for the main thread")
        await fulfillment(of: [shown], timeout: 3)
        XCTAssertEqual(copies, 2)
        XCTAssertEqual(widths, [2, 3], "Keep the final update even if no more regions arrive")
    }

    func testClosingDesktopDropsPendingCopiesAndLateFrames() async throws {
        let queue = DispatchQueue(label: "desktop-frame-close-test")
        let delivery = DesktopFrameDelivery<CGImage>(queue: queue)
        let image = try frameImage()
        let shown = expectation(description: "closed viewer must not present")
        shown.isInverted = true
        delivery.onFrame = { _ in shown.fulfill() }
        var copies = 0
        queue.suspend()
        delivery.submit { copies += 1; return image }
        delivery.close()
        delivery.submit { copies += 1; return image }
        queue.resume()
        queue.sync {}
        await fulfillment(of: [shown], timeout: 0.1)
        XCTAssertEqual(copies, 0)
    }

    private func frameImage(width: Int = 2) throws -> CGImage {
        let bytes = Data(repeating: 128, count: width * 2 * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        return try XCTUnwrap(CGImage(width: width, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testPointerMappingAndOutsideDisplay() {
        XCTAssertEqual(DesktopCanvasView.pixelPoint(CGPoint(x: 75, y: 50), displayedSize: CGSize(width: 100, height: 100),
            pixels: CGSize(width: 1920, height: 1080)), CGPoint(x: 1440, y: 540))
        XCTAssertNil(DesktopCanvasView.pixelPoint(CGPoint(x: 100, y: 20), displayedSize: CGSize(width: 100, height: 100),
            pixels: CGSize(width: 1920, height: 1080)))
        XCTAssertNil(DesktopCanvasView.pixelPoint(CGPoint(x: -1, y: 20), displayedSize: CGSize(width: 100, height: 100),
            pixels: CGSize(width: 1920, height: 1080)))
    }

    func testGrantIsBoundToDesktopWorkspaceAndExpires() throws {
        let valid = DesktopSSHGrant(expires_at: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
            ssh: .init(host: "ssh.oblien.com", port: 22, username: "desktop-163119cc95a4dddc-test", password: "fixture", host_key_fingerprint: "SHA256:test"),
            vnc: .init(host: "127.0.0.1", port: 5900, authentication: "none"))
        try valid.validate(workspaceId: "163119cc95a4dddc")
        XCTAssertThrowsError(try valid.validate(workspaceId: "0000000000000000"))
        let old = DesktopSSHGrant(expires_at: "2020-01-01T00:00:00Z", ssh: valid.ssh, vnc: valid.vnc)
        XCTAssertThrowsError(try old.validate(workspaceId: "163119cc95a4dddc"))
        let shell = DesktopSSHGrant(expires_at: valid.expires_at,
            ssh: .init(host: "arbitrary.example", port: 22, username: valid.ssh.username, password: "fixture", host_key_fingerprint: "SHA256:test"), vnc: valid.vnc)
        XCTAssertThrowsError(try shell.validate(workspaceId: "163119cc95a4dddc"))
    }

    func testFingerprintUsesSSHWireKeyRatherThanText() {
        let privateKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let key = privateKey.publicKey
        let serialized = String(openSSHPublicKey: key).split(separator: " ")
        let raw = Data(base64Encoded: String(serialized[1]))!
        let expected = "SHA256:" + Data(SHA256.hash(data: raw)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(PinnedSSHHostKey.fingerprint(key), expected)
    }

    func testSurfaceToolCardDecodesForLiveAndHistory() throws {
        let data = Data(#"{"id":"tool-1","name":"mcp__mindwire_desktop__surface_capture","action":{"kind":"mcp","title":"Capture desktop","surface":{"surfaceId":"desktop","operation":"capture","capture":{"id":"frame","artifactId":"image","width":1920,"height":1080}}}}"#.utf8)
        let call = try JSONDecoder().decode(DaemonToolCall.self, from: data)
        XCTAssertEqual(call.action?.surface?.capture?.artifactId, "image")
        let reloaded = try JSONDecoder().decode(DaemonToolCall.self, from: JSONEncoder().encode(call))
        XCTAssertEqual(call.action, reloaded.action)
    }

    /// Starts against TestNativeViewerFixture in packages/daemon/internal/surface/rfb_test.go.
    /// Exercises the production NIOSSH bridge and RoyalVNCKit decoder, including resize.
    func testNativeVNCThroughPinnedSSH() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portValue = env["MINDWIRE_NATIVE_SSH_PORT"], let port = Int(portValue),
              let fingerprint = env["MINDWIRE_NATIVE_SSH_FINGERPRINT"] else { throw XCTSkip("Opt in with the local SSH/RFB fixture.") }
        let connection = SSHConnection(host: "127.0.0.1", port: port, username: "fixture", auth: .password("fixture"), expectedHostKey: fingerprint)
        defer { connection.close() }
        let tunnel = try await connection.forwardLocal(host: "127.0.0.1", port: 5900)
        defer { tunnel.close() }
        let viewer = NativeDesktopConnection()
        defer { viewer.disconnect() }
        let frame = expectation(description: "native decoded resized frame")
        var received = false
        viewer.onFrame = { displayFrame in
            let image = displayFrame.image
            guard !received, image.width == 3 else { return }
            received = true
            XCTAssertEqual(image.height, 2)
            if let data = image.dataProvider?.data as Data? {
                XCTAssertEqual(Array(data.prefix(3)), [40, 30, 200])
            } else { XCTFail("No native frame pixels") }
            frame.fulfill()
        }
        viewer.onState = { ready, message in
            if !ready && !received { received = true; XCTFail(message ?? "Native connection closed before its first frame."); frame.fulfill() }
        }
        viewer.connect(port: tunnel.port, settings: .init(quality: .original))
        await fulfillment(of: [frame], timeout: 25)
    }
}
