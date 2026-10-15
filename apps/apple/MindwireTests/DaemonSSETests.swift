import XCTest
@testable import Mindwire

final class DaemonSSETests: XCTestCase {
    func testEventsDispatchAtBlankSeparatorsWhileConnectionRemainsOpen() throws {
        for separator in ["\n", "\r\n", "\r"] {
            var decoder = DaemonSSEDecoder()
            var events: [Data] = []
            let wire = "\u{FEFF}: heartbeat\(separator)event: update\(separator)data: {\"text\":\"مرحبا 👋\"}\(separator)\(separator)"
            for byte in wire.utf8 {
                if let event = try decoder.append(byte) { events.append(event) }
            }
            XCTAssertEqual(events.map { String(decoding: $0, as: UTF8.self) }, ["{\"text\":\"مرحبا 👋\"}"])
            XCTAssertEqual(decoder.eventType, "update")
            // No EOF and no subsequent event is needed to deliver the first payload.
            for byte in "data: {\"text\":\"next\"}\(separator)\(separator)".utf8 {
                if let event = try decoder.append(byte) { events.append(event) }
            }
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(decoder.eventType, "", "An event name must not leak into the next unnamed event.")
        }
    }

    func testMultilineEmptyDataCommentsAndIncompleteFrames() throws {
        var decoder = DaemonSSEDecoder()
        let wire = ": ping\n\nevent: ignored\n\ndata: first\ndata:  second\ndata\n\ndata: incomplete"
        let events = try wire.utf8.compactMap { try decoder.append($0) }
        XCTAssertEqual(events.map { String(decoding: $0, as: UTF8.self) }, ["first\n second\n"])
    }

    func testLargeUnicodeEventAndSizeLimit() throws {
        let text = String(repeating: "工具 👋 ", count: 100_000)
        var decoder = DaemonSSEDecoder()
        let events = try ("data: " + text + "\n\n").utf8.compactMap { try decoder.append($0) }
        XCTAssertEqual(events, [Data(text.utf8)])
        var limited = DaemonSSEDecoder(maximumEventBytes: 32)
        XCTAssertThrowsError(try ("data: " + String(repeating: "x", count: 33)).utf8.forEach { _ = try limited.append($0) })
    }
}
