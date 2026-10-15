import XCTest
@testable import Mindwire

@MainActor
final class AppLifecycleTests: XCTestCase {
    func testMultipleWindowsSharePreparationAndOnlyOneForegroundLoop() async throws {
        var preparations = 0
        var starts = 0
        var stops = 0
        let lifecycle = AppLifecycle(prepare: {
            preparations += 1
            try? await Task.sleep(for: .milliseconds(30))
        }, whileActive: {
            starts += 1
            do { try await Task.sleep(for: .seconds(3_600)) } catch { }
            stops += 1
        })
        let active = AppActivityContext(active: true, accountID: 1)
        lifecycle.update(active)
        lifecycle.update(active)
        async let firstWindow: Void = lifecycle.prepare()
        async let secondWindow: Void = lifecycle.prepare()
        _ = await (firstWindow, secondWindow)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(starts, 1)

        lifecycle.update(.init(active: false, accountID: 1))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(stops, 1)
        lifecycle.update(active)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(starts, 2)

        lifecycle.update(.init(active: true, accountID: 2))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(starts, 3, "Switching accounts renews the shared subscription")
        XCTAssertEqual(stops, 2)
        lifecycle.update(.init(active: false, accountID: 2))
    }
}
