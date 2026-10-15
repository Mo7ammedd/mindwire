import SwiftUI
import UIKit

struct DesktopPointerPosition: Equatable {
    var normalized = CGPoint(x: 0.5, y: 0.5)

    mutating func move(_ delta: CGSize, pixels: CGSize) {
        guard pixels.width > 1, pixels.height > 1 else { return }
        normalized.x = min(1 - 1 / pixels.width, max(0, normalized.x + delta.width / pixels.width))
        normalized.y = min(1 - 1 / pixels.height, max(0, normalized.y + delta.height / pixels.height))
    }
    func pixel(in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, size.width - 1), max(0, floor(normalized.x * size.width))),
                y: min(max(0, size.height - 1), max(0, floor(normalized.y * size.height))))
    }
}

/// Cursor position goes straight to the canvas. It never waits for a frame or
/// invalidates the SwiftUI screen, toolbars and keyboard on every pointer tick.
@MainActor
final class DesktopCursor {
    private var position = DesktopPointerPosition()
    // SwiftUI can keep the outgoing canvas alive while constructing its new
    // layout. Each attached canvas needs the cursor until that view detaches;
    // a single weak slot let an offscreen replacement hide the visible cursor.
    private let canvases = NSHashTable<DesktopCanvasView>.weakObjects()
    var normalized: CGPoint { position.normalized }
    private(set) var buttons = 0
    private(set) var shape: DesktopCursorShape?
    private var clickPulse = false
    private var clickTask: Task<Void, Never>?

    func attach(to canvas: DesktopCanvasView) {
        canvases.add(canvas)
        canvas.pointer = normalized
        canvas.updateCursor(shape: shape, pressed: buttons != 0 || clickPulse)
    }
    func detach(from canvas: DesktopCanvasView) {
        canvases.remove(canvas)
        canvas.pointer = nil
    }
    func move(_ delta: CGSize, pixels: CGSize) {
        position.move(delta, pixels: pixels)
        for canvas in canvases.allObjects { canvas.pointer = normalized }
    }
    func place(at point: CGPoint, pixels: CGSize) {
        guard pixels.width > 1, pixels.height > 1 else { return }
        position.normalized = CGPoint(x: min(pixels.width - 1, max(0, point.x)) / pixels.width,
                                      y: min(pixels.height - 1, max(0, point.y)) / pixels.height)
        for canvas in canvases.allObjects { canvas.pointer = normalized }
    }
    func pixel(in size: CGSize) -> CGPoint { position.pixel(in: size) }

    func show(_ shape: DesktopCursorShape) {
        guard self.shape?.image !== shape.image || self.shape?.hotspot != shape.hotspot else { return }
        self.shape = shape
        updateAppearance()
    }
    private func updateAppearance() {
        for canvas in canvases.allObjects { canvas.updateCursor(shape: shape, pressed: buttons != 0 || clickPulse) }
    }

    func handle(_ event: DesktopPointerEvent, pixels: CGSize, send: (DesktopInput) -> Void) {
        guard pixels.width > 1, pixels.height > 1 else { return }
        switch event {
        case .move(let delta):
            let previous = pixel(in: pixels)
            move(delta, pixels: pixels)
            let point = pixel(in: pixels)
            if point != previous { send(.init(kind: "pointer", x: Int(point.x), y: Int(point.y), buttons: buttons)) }
        case .button(let down):
            let value = down ? 1 : 0
            guard buttons != value else { return }
            buttons = value
            updateAppearance()
            let point = pixel(in: pixels)
            send(.init(kind: "pointer", x: Int(point.x), y: Int(point.y), buttons: buttons))
        case .click(let button, let count):
            release(pixels: pixels, send: send)
            clickTask?.cancel(); clickPulse = true; updateAppearance()
            clickTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
                self?.clickPulse = false; self?.updateAppearance(); self?.clickTask = nil
            }
            let point = pixel(in: pixels)
            send(.init(kind: "click", x: Int(point.x), y: Int(point.y), button: button, count: count))
        case .scroll(let dx, let dy):
            let point = pixel(in: pixels)
            send(.init(kind: "scroll", x: Int(point.x), y: Int(point.y), deltaX: dx, deltaY: dy))
        }
    }
    func release(pixels: CGSize, send: (DesktopInput) -> Void) {
        guard buttons != 0 else { return }
        handle(.button(false), pixels: pixels, send: send)
    }
}

struct DesktopPointerMotion {
    static let radius: CGFloat = 32
    private var previousTranslation = CGSize.zero

    /// Finger travel maps linearly to desktop distance, independent of touch
    /// frequency or how long the finger is held. At normal sensitivity, 320 points
    /// span the longest display dimension at any desktop resolution.
    mutating func update(translation: CGSize, pixels: CGSize, sensitivity: Double = 1) -> CGSize {
        let travel = CGSize(width: translation.width - previousTranslation.width,
                            height: translation.height - previousTranslation.height)
        previousTranslation = translation
        return Self.distance(travel, pixels: pixels, sensitivity: sensitivity)
    }

    static func distance(_ travel: CGSize, pixels: CGSize, sensitivity: Double = 1) -> CGSize {
        guard pixels.width > 1, pixels.height > 1, sensitivity > 0 else { return .zero }
        let scale = max(pixels.width, pixels.height) / 320 * CGFloat(sensitivity)
        return CGSize(width: travel.width * scale, height: travel.height * scale)
    }

    mutating func reset() { previousTranslation = .zero }
}

/// One right-click button accompanies either surface. Primary clicks and drag
/// gestures happen on the surface itself, including in the compact keyboard mode.
struct DesktopPointerPad: View {
    let mode: DesktopPointerMode
    let pixels: CGSize
    var sensitivity: Double = 1
    var scrollSensitivity: Double = 1
    var enabled = true
    var stickSize: CGFloat = 96
    let event: (DesktopPointerEvent) -> Void

    var body: some View {
        HStack(spacing: 12) {
            DesktopPointerSurface(mode: mode, pixels: pixels, sensitivity: sensitivity,
                                  scrollSensitivity: scrollSensitivity, enabled: enabled, event: event)
                .frame(maxWidth: mode == .stick ? stickSize : .infinity, maxHeight: .infinity)
                .frame(width: mode == .stick ? stickSize : nil, height: mode == .stick ? stickSize : nil)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: mode == .stick ? 48 : 22))
                .overlay {
                    RoundedRectangle(cornerRadius: mode == .stick ? 48 : 22)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5).allowsHitTesting(false)
                }
            Button { event(.click("right", 1)) } label: {
                VStack(spacing: 4) {
                    AppIcon(.pointerClick).font(.body)
                    Text("Right").font(.caption2)
                }.frame(width: 30, height: 42)
            }
            .buttonStyle(.glass)
            .background(Color(.secondarySystemBackground), in: .capsule)
            .tint(.primary)
            .accessibilityLabel("Right-click")
            .disabled(!enabled)
        }
        .frame(maxWidth: mode == .stick ? nil : .infinity)
        .accessibilityElement(children: .contain)
    }
}
