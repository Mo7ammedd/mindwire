import XCTest
import UIKit
@testable import Mindwire

@MainActor
final class DesktopTouchpadTests: XCTestCase {
    func testCursorSurvivesOverlappingCanvasLayoutHandoffs() {
        let cursor = DesktopCursor()
        let visible = DesktopCanvasView()
        var replacement: DesktopCanvasView? = DesktopCanvasView()
        visible.cursor = cursor
        replacement?.cursor = cursor
        XCTAssertEqual(visible.pointer, cursor.normalized)
        cursor.move(CGSize(width: 20, height: 10), pixels: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(visible.pointer, cursor.normalized)
        XCTAssertEqual(replacement?.pointer, cursor.normalized)
        replacement?.cursor = nil
        replacement = nil
        cursor.move(CGSize(width: 20, height: 10), pixels: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(visible.pointer, cursor.normalized, "Dismantling a transient replacement must not hide the visible cursor")
        visible.cursor = nil
        XCTAssertNil(visible.pointer)
    }

    private func touch(_ id: Int = 1, _ x: CGFloat = 40, _ y: CGFloat = 40, taps: Int = 1) -> DesktopTouchpadGesture.Touch {
        .init(id: id, point: CGPoint(x: x, y: y), tapCount: taps)
    }

    func testTapIsImmediateAndDoubleTapDoesNotAddAnExtraClick() {
        var gesture = DesktopTouchpadGesture()
        XCTAssertEqual(gesture.began([touch()], at: 0), [])
        XCTAssertEqual(gesture.ended([touch()], at: 0.1), [.click("left", 1)])
        // First click is already sent. Second tap must be one down/up, not two more clicks.
        XCTAssertEqual(gesture.began([touch(taps: 2)], at: 0.2), [.button(true)])
        XCTAssertEqual(gesture.ended([touch(taps: 2)], at: 0.27), [.button(false)])
        XCTAssertFalse(gesture.active)
        XCTAssertFalse(gesture.buttonDown)
    }

    func testRestingThenMovingNeverPressesTheMouseButton() {
        var gesture = DesktopTouchpadGesture()
        let cursor = DesktopCursor()
        let pixels = CGSize(width: 1600, height: 1000)
        var sent: [DesktopInput] = []
        func deliver(_ events: [DesktopPointerEvent]) {
            for event in events { cursor.handle(event, pixels: pixels) { sent.append($0) } }
        }
        deliver(gesture.began([touch()], at: 0))
        // A slow start and resting between movements must remain ordinary hover.
        deliver(gesture.moved([touch(1, 42, 40)]))
        for _ in 0..<120 {
            XCTAssertEqual(gesture.moved([touch(1, 42, 40)]), [], "A stationary finger must stop immediately")
        }
        deliver(gesture.moved([touch(1, 52, 36)]))
        deliver(gesture.ended([touch(1, 52, 36)], at: 3))
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(sent.allSatisfy { $0.kind == "pointer" && $0.buttons == 0 }, "A one-finger glide must never select text")
        XCTAssertEqual(cursor.buttons, 0)
        XCTAssertFalse(gesture.buttonDown)
        XCTAssertEqual(gesture.cancel(), [])
    }

    func testDoubleTapAndHoldStartsDraggingWithoutAnotherLongPressDelay() {
        var gesture = DesktopTouchpadGesture()
        _ = gesture.began([touch()], at: 0)
        _ = gesture.ended([touch()], at: 0.1)
        XCTAssertEqual(gesture.began([touch(taps: 2)], at: 0.2), [.button(true)])
        XCTAssertEqual(gesture.moved([touch(1, 41, 42)]), [.move(CGSize(width: 1, height: 2))])
        for _ in 0..<120 { XCTAssertEqual(gesture.moved([touch(1, 41, 42)]), []) }
        XCTAssertEqual(gesture.ended([touch(1, 41, 42)], at: 2), [.button(false)])
        XCTAssertFalse(gesture.buttonDown)
    }

    func testOrdinaryMovementCancelsTapAndNewStrokeDoesNotJumpOrDrag() {
        var gesture = DesktopTouchpadGesture()
        _ = gesture.began([touch()], at: 0)
        XCTAssertEqual(gesture.moved([touch(1, 70, 40)]), [.move(CGSize(width: 30, height: 0))])
        XCTAssertEqual(gesture.ended([touch(1, 70, 40)], at: 0.1), [])
        XCTAssertEqual(gesture.began([touch(2, 250, 130, taps: 2)], at: 0.2), [], "Repositioning a glide is not a second click")
        XCTAssertEqual(gesture.moved([touch(2, 251, 129)]), [.move(CGSize(width: 1, height: -1))])
        XCTAssertFalse(gesture.buttonDown)
    }

    func testStationaryHoldAndTinyDriftDoNotClickOrPrimeADrag() {
        var gesture = DesktopTouchpadGesture()
        XCTAssertEqual(gesture.began([touch()], at: 0), [])
        _ = gesture.moved([touch(1, 42, 40)])
        XCTAssertEqual(gesture.ended([touch(1, 42, 40)], at: 2), [])
        XCTAssertEqual(gesture.began([touch(taps: 2)], at: 2.1), [])
        XCTAssertFalse(gesture.buttonDown)
    }

    func testDistantOrExpiredSecondTouchDoesNotDrag() {
        for (time, point) in [(1.0, CGPoint(x: 40, y: 40)), (0.2, CGPoint(x: 180, y: 40))] {
            var gesture = DesktopTouchpadGesture()
            _ = gesture.began([touch()], at: 0)
            XCTAssertEqual(gesture.ended([touch()], at: 0.1), [.click("left", 1)])
            XCTAssertEqual(gesture.began([touch(2, point.x, point.y, taps: 2)], at: time), [])
            XCTAssertFalse(gesture.buttonDown)
        }
    }

    func testTwoFingersScrollBothAxesWithoutMovingCursorOrClickingOnLift() {
        var gesture = DesktopTouchpadGesture()
        _ = gesture.began([touch()], at: 0)
        _ = gesture.began([touch(2, 80, 40)], at: 0.05)
        XCTAssertEqual(gesture.moved([touch(1, 52, 64), touch(2, 92, 64)]), [.scroll(-1, -3)])
        XCTAssertEqual(gesture.moved([touch(1, 52, 64), touch(2, 92, 64)]), [])
        XCTAssertEqual(gesture.ended([touch(2, 92, 64)], at: 0.2), [])
        XCTAssertEqual(gesture.moved([touch(1, 110, 110)]), [], "The remaining finger must not jump into mouse movement")
        XCTAssertEqual(gesture.ended([touch(1, 110, 110)], at: 0.25), [])
    }

    func testTwoFingerTapRightClicksAndSecondFingerReleasesDrag() {
        var gesture = DesktopTouchpadGesture()
        _ = gesture.began([touch(), touch(2, 80, 40)], at: 0)
        XCTAssertEqual(gesture.ended([touch(), touch(2, 80, 40)], at: 0.1), [.click("right", 1)])
        _ = gesture.began([touch()], at: 1)
        _ = gesture.ended([touch()], at: 1.1)
        XCTAssertEqual(gesture.began([touch(taps: 2)], at: 1.2), [.button(true)])
        XCTAssertEqual(gesture.began([touch(2, 80, 40)], at: 1.6), [.button(false)])
        XCTAssertEqual(gesture.cancel(), [])
    }

    func testPinchingOnTheTouchpadDoesNotAccidentallyRightClick() {
        var gesture = DesktopTouchpadGesture()
        _ = gesture.began([touch(), touch(2, 80, 40)], at: 0)
        XCTAssertEqual(gesture.moved([touch(1, 30, 40), touch(2, 90, 40)]), [])
        XCTAssertEqual(gesture.ended([touch(1, 30, 40), touch(2, 90, 40)], at: 0.2), [])
    }

    func testCancelledOrInterruptedTouchNeverClicksAndAlwaysReleases() {
        var gesture = DesktopTouchpadGesture()
        _ = gesture.began([touch()], at: 0)
        XCTAssertEqual(gesture.cancel(), [])
        _ = gesture.began([touch()], at: 1)
        _ = gesture.ended([touch()], at: 1.1)
        _ = gesture.began([touch(taps: 2)], at: 1.2)
        XCTAssertEqual(gesture.cancel(), [.button(false)])
        XCTAssertEqual(gesture.began([touch(taps: 3)], at: 1.3), [], "Cancellation must reset the completed tap history")
        XCTAssertEqual(gesture.cancel(), [])
    }

    func testDragQueueRetainsMouseDownAtTheOriginalPositionUnderBackpressure() {
        var buffer = DesktopInputBuffer()
        XCTAssertTrue(buffer.append(.init(kind: "pointer", x: 50, y: 100, buttons: 1)))
        for x in 51...500 { XCTAssertTrue(buffer.append(.init(kind: "pointer", x: x, y: 100, buttons: 1))) }
        XCTAssertTrue(buffer.append(.init(kind: "pointer", x: 500, y: 100, buttons: 0)))
        XCTAssertEqual(buffer.pending, [
            .init(kind: "pointer", x: 50, y: 100, buttons: 1),
            .init(kind: "pointer", x: 500, y: 100, buttons: 1),
            .init(kind: "pointer", x: 500, y: 100, buttons: 0)
        ])
    }

    func testTouchpadPointerAndClickUseFullDesktopCoordinatesForReducedImage() {
        let cursor = DesktopCursor()
        let desktop = CGSize(width: 3024, height: 1964)
        var input: [DesktopInput] = []
        cursor.handle(.button(true), pixels: desktop) { input.append($0) }
        cursor.handle(.move(CGSize(width: 120, height: -60)), pixels: desktop) { input.append($0) }
        cursor.handle(.button(false), pixels: desktop) { input.append($0) }
        XCTAssertEqual(input.map(\.buttons), [1, 1, 0])
        XCTAssertEqual(input.first?.x, 1512)
        XCTAssertEqual(input.last?.x, 1632)
        XCTAssertEqual(input.last?.y, 922)
        XCTAssertEqual(DesktopCanvasView.pixelPoint(CGPoint(x: 500, y: 250),
            displayedSize: CGSize(width: 1000, height: 500), pixels: desktop), CGPoint(x: 1512, y: 982))
        cursor.release(pixels: desktop) { input.append($0) }
        XCTAssertEqual(input.count, 3, "Repeated release must not enqueue another event")
    }

    func testMouseUpKeepsItsPositionAfterAnIdleHoldAndFitsInAFullQueue() {
        var buffer = DesktopInputBuffer()
        XCTAssertTrue(buffer.append(.init(kind: "pointer", x: 50, y: 100, buttons: 1)))
        _ = buffer.next() // The down event finished; the user keeps holding.
        XCTAssertTrue(buffer.append(.init(kind: "pointer", x: 50, y: 100, buttons: 0)))
        XCTAssertTrue(buffer.append(.init(kind: "pointer", x: 100, y: 100, buttons: 0)))
        XCTAssertEqual(buffer.pending.count, 2, "The new stroke must not replace the drag's release position")
        buffer.removeAll()
        for _ in 0..<(DesktopInputBuffer.capacity - 1) { XCTAssertTrue(buffer.append(.init(kind: "key", keys: ["a"]))) }
        XCTAssertFalse(buffer.append(.init(kind: "key", keys: ["b"])))
        XCTAssertTrue(buffer.append(.init(kind: "pointer", x: 50, y: 100, buttons: 0)), "Always leave room for a mouse-up")
        XCTAssertEqual(buffer.pending.count, DesktopInputBuffer.capacity)
    }

    func testScrollSensitivityKeepsFractionalTravelAndReversesWithoutInertia() {
        var normal = DesktopScrollMotion(), fast = DesktopScrollMotion()
        var total = 0
        for _ in 0..<16 { total += normal.consume(CGSize(width: 0, height: 1)).y }
        XCTAssertEqual(total, -2)
        XCTAssertEqual(fast.consume(CGSize(width: 0, height: 16), sensitivity: 2).y, -4)
        for _ in 0..<100 { XCTAssertEqual(fast.consume(.zero, sensitivity: 2).y, 0) }
        _ = normal.consume(CGSize(width: 0, height: -7))
        XCTAssertEqual(normal.consume(CGSize(width: 0, height: 8)).y, -1, "The old fraction must not slow a direction change.")
        XCTAssertEqual(normal.consume(CGSize(width: 0, height: 100_000)).y, -50)
        XCTAssertEqual(normal.consume(.zero).y, 0, "Oversized motion must not queue later wheel events.")
    }

    func testKeyboardAndFullscreenChooseCompactControlsWithoutDisablingDirectTouch() {
        XCTAssertEqual(DesktopPointerMode.touchpad.active(fullscreen: false, keyboard: false, fullscreenStick: false), .touchpad)
        XCTAssertEqual(DesktopPointerMode.touchpad.active(fullscreen: false, keyboard: true, fullscreenStick: false), .stick)
        XCTAssertEqual(DesktopPointerMode.touchpad.active(fullscreen: true, keyboard: false, fullscreenStick: false), .screen)
        XCTAssertEqual(DesktopPointerMode.touchpad.active(fullscreen: true, keyboard: false, fullscreenStick: true), .stick)
        XCTAssertEqual(DesktopPointerMode.screen.active(fullscreen: false, keyboard: true, fullscreenStick: true), .screen)
    }

    func testTouchpadLayoutFitsPortraitAndMovesBesideLandscapeVideo() {
        let pixels = CGSize(width: 3024, height: 1964)
        for size in [CGSize(width: 390, height: 580), CGSize(width: 402, height: 410), CGSize(width: 800, height: 900)] {
            let layout = DesktopControlLayout(available: size, pixels: pixels, mode: .touchpad, fullscreen: false)
            XCTAssertTrue(layout.hasSeparatePad)
            XCTAssertGreaterThanOrEqual(layout.padHeight, 144)
            XCTAssertLessThanOrEqual(layout.videoHeight + layout.padHeight + 32, size.height)
        }
        let landscape = DesktopControlLayout(available: CGSize(width: 844, height: 260), pixels: pixels, mode: .touchpad, fullscreen: false)
        XCTAssertTrue(landscape.sideBySide)
        XCTAssertFalse(landscape.hasSeparatePad)
        let full = DesktopControlLayout(available: CGSize(width: 844, height: 360), pixels: pixels, mode: .stick, fullscreen: true)
        XCTAssertFalse(full.hasSeparatePad)
        XCTAssertFalse(full.sideBySide)
    }
}
