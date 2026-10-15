import CoreGraphics
import Foundation

enum DesktopPointerEvent: Equatable {
    case move(CGSize)
    case click(String, Int)
    case button(Bool)
    case scroll(Int, Int)
}

/// The same natural-scroll scale on the pad and display. Preserve fractional
/// travel, but never let an old fraction swallow a change of direction.
struct DesktopScrollMotion {
    private var remainder = CGSize.zero
    mutating func consume(_ delta: CGSize, sensitivity: Double = 1) -> (x: Int, y: Int) {
        let scale = CGFloat(min(3, max(0.25, sensitivity.isFinite ? sensitivity : 1))) / 8
        if delta.width * remainder.width > 0 { remainder.width = 0 }
        if delta.height * remainder.height > 0 { remainder.height = 0 }
        remainder.width -= delta.width * scale
        remainder.height -= delta.height * scale
        let x = max(-50, min(50, Int(remainder.width)))
        let y = max(-50, min(50, Int(remainder.height)))
        remainder.width = remainder.width.truncatingRemainder(dividingBy: 1)
        remainder.height = remainder.height.truncatingRemainder(dividingBy: 1)
        return (x, y)
    }
}

/// One gesture state machine serves both the touchpad and compact mouse stick.
/// It follows actual touch deltas: no acceleration, inertia, or repeating timer.
/// Only a second tap can hold the button. Resting before moving never starts a
/// drag, and every end/cancel releases it.
struct DesktopTouchpadGesture {
    struct Touch {
        let id: Int
        let point: CGPoint
        var tapCount = 1
    }
    private var touches: [Int: CGPoint] = [:]
    private var origin = CGPoint.zero
    private var startedAt: TimeInterval = 0
    private var movement: CGFloat = 0
    private var scrollMovement: CGFloat = 0
    private var scroll = DesktopScrollMotion()
    private var scrollCenter: CGPoint?
    private var scrollOrigins: [Int: CGPoint] = [:]
    private var multiple = false
    private var suppressed = false
    private var canRightTap = false
    private var lastTap: (point: CGPoint, time: TimeInterval)?
    private(set) var buttonDown = false
    private(set) var translation = CGSize.zero
    var active: Bool { !touches.isEmpty }

    mutating func began(_ incoming: [Touch], at time: TimeInterval) -> [DesktopPointerEvent] {
        var events: [DesktopPointerEvent] = []
        let first = touches.isEmpty
        if first {
            startedAt = time; origin = incoming.first?.point ?? .zero
        }
        for touch in incoming { touches[touch.id] = touch.point }
        if touches.count == 1, first {
            if let lastTap, let touch = incoming.first, touch.tapCount > 1,
               (0...0.3).contains(time - lastTap.time),
               hypot(touch.point.x - lastTap.point.x, touch.point.y - lastTap.point.y) <= 24 {
                // The first tap has already clicked. The second down/up is the
                // second click, or the start of a double-tap-and-drag. UIKit's
                // tap count alone must not turn a lifted/repositioned glide into
                // a selection when the previous touch never actually clicked.
                buttonDown = true; events.append(.button(true))
            }
            lastTap = nil
        } else if touches.count >= 2 {
            lastTap = nil
            if buttonDown { buttonDown = false; events.append(.button(false)) }
            multiple = true; translation = .zero
            if touches.count == 2, !suppressed {
                canRightTap = movement <= 5 && time - startedAt < 0.35
                scrollCenter = center
                scrollOrigins = touches
            } else { suppressed = true; canRightTap = false }
        }
        return events
    }

    mutating func moved(_ incoming: [Touch], scrollSensitivity: Double = 1) -> [DesktopPointerEvent] {
        let previous = touches.first?.value
        for touch in incoming where touches[touch.id] != nil { touches[touch.id] = touch.point }
        guard !suppressed else { return [] }
        if touches.count == 1, !multiple, let point = touches.first?.value, let previous {
            translation = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            movement = max(movement, hypot(translation.width, translation.height))
            let delta = CGSize(width: point.x - previous.x, height: point.y - previous.y)
            return delta == .zero ? [] : [.move(delta)]
        }
        guard touches.count == 2, multiple, let previous = scrollCenter else { return [] }
        for (id, point) in touches {
            if let origin = scrollOrigins[id], hypot(point.x - origin.x, point.y - origin.y) > 5 { canRightTap = false }
        }
        let current = center
        scrollCenter = current
        let delta = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
        scrollMovement += hypot(delta.x, delta.y)
        let (dx, dy) = scroll.consume(CGSize(width: delta.x, height: delta.y), sensitivity: scrollSensitivity)
        return dx == 0 && dy == 0 ? [] : [.scroll(dx, dy)]
    }

    mutating func ended(_ incoming: [Touch], at time: TimeInterval, scrollSensitivity: Double = 1) -> [DesktopPointerEvent] {
        guard !touches.isEmpty else { return [] }
        var events = moved(incoming, scrollSensitivity: scrollSensitivity)
        for touch in incoming { touches.removeValue(forKey: touch.id) }
        guard touches.isEmpty else {
            scrollCenter = nil // Lifting one scrolling finger must not move the mouse.
            return events
        }
        let tapped = !suppressed && !multiple && movement <= 5 && time - startedAt < 0.3
        if buttonDown { events.append(.button(false)) }
        else if tapped {
            events.append(.click("left", 1))
        } else if !suppressed, multiple, canRightTap, scrollMovement <= 5, time - startedAt < 0.35 {
            events.append(.click("right", 1))
        }
        let completedTap = tapped ? (point: origin, time: time) : nil
        self = .init()
        lastTap = completedTap
        return events
    }

    mutating func cancel() -> [DesktopPointerEvent] {
        let events: [DesktopPointerEvent] = buttonDown ? [.button(false)] : []
        self = .init()
        return events
    }

    private var center: CGPoint {
        let count = CGFloat(max(1, touches.count))
        return CGPoint(x: touches.values.reduce(0) { $0 + $1.x } / count,
                       y: touches.values.reduce(0) { $0 + $1.y } / count)
    }
}
