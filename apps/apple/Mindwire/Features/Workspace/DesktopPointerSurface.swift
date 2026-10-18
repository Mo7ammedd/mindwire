import SwiftUI
import UIKit

struct DesktopPointerSurface: UIViewRepresentable {
    let mode: DesktopPointerMode
    let pixels: CGSize
    let sensitivity: Double
    var scrollSensitivity: Double = 1
    var enabled = true
    let event: (DesktopPointerEvent) -> Void

    func makeUIView(context: Context) -> DesktopPointerSurfaceView { DesktopPointerSurfaceView() }
    func updateUIView(_ view: DesktopPointerSurfaceView, context: Context) {
        view.configure(mode: mode, pixels: pixels, sensitivity: sensitivity, scrollSensitivity: scrollSensitivity,
                       enabled: enabled, event: event)
    }
    static func dismantleUIView(_ view: DesktopPointerSurfaceView, coordinator: ()) { view.cancelInteraction(); view.event = nil }
}

/// UIKit delivers touch movement directly to the cursor, without a SwiftUI render
/// or gesture-recognizer delay. A single click is immediate; two native clicks
/// become a double-click, and the second tap can stay down to drag.
final class DesktopPointerSurfaceView: UIView {
    var event: ((DesktopPointerEvent) -> Void)?
    private var mode = DesktopPointerMode.touchpad
    private var pixels = CGSize.zero
    private var sensitivity = 1.0
    private var scrollSensitivity = 1.0
    private var gesture = DesktopTouchpadGesture()
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0
    private var inactivity: NSObjectProtocol?
    private let thumb = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let pointer = UIImageView(image: AppIconImages.image(.pointer, size: 20, scale: 3))
    private let centerMark = UIImageView(image: AppIconImages.image(.plus, size: 16, scale: 3))
    private let hint = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        backgroundColor = .clear
        thumb.layer.cornerRadius = 19; thumb.clipsToBounds = true
        thumb.isUserInteractionEnabled = false
        pointer.tintColor = .label; thumb.contentView.addSubview(pointer)
        centerMark.tintColor = .secondaryLabel; centerMark.isUserInteractionEnabled = false
        addSubview(centerMark); addSubview(thumb)
        hint.text = "Tap to click · double-tap and drag · two fingers scroll"
        hint.font = .preferredFont(forTextStyle: .caption2)
        hint.textColor = .secondaryLabel; hint.textAlignment = .center
        hint.adjustsFontSizeToFitWidth = true; hint.minimumScaleFactor = 0.8
        hint.isUserInteractionEnabled = false; hint.isAccessibilityElement = false
        addSubview(hint)
        inactivity = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.cancelInteraction() }
        accessibilityHint = "Slide to move. Tap to click. Double-tap to double-click. Double-tap and hold to drag. Two fingers scroll."
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Double-click") { [weak self] _ in self?.event?(.click("left", 2)); return true },
            UIAccessibilityCustomAction(name: "Right-click") { [weak self] _ in self?.event?(.click("right", 1)); return true },
            UIAccessibilityCustomAction(name: "Move left") { [weak self] _ in self?.deliver([.move(CGSize(width: -10, height: 0))]); return true },
            UIAccessibilityCustomAction(name: "Move right") { [weak self] _ in self?.deliver([.move(CGSize(width: 10, height: 0))]); return true },
            UIAccessibilityCustomAction(name: "Move up") { [weak self] _ in self?.deliver([.move(CGSize(width: 0, height: -10))]); return true },
            UIAccessibilityCustomAction(name: "Move down") { [weak self] _ in self?.deliver([.move(CGSize(width: 0, height: 10))]); return true },
            UIAccessibilityCustomAction(name: "Scroll up") { [weak self] _ in self?.event?(.scroll(0, -3)); return true },
            UIAccessibilityCustomAction(name: "Scroll down") { [weak self] _ in self?.event?(.scroll(0, 3)); return true }
        ]
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(mode: DesktopPointerMode, pixels: CGSize, sensitivity: Double, scrollSensitivity: Double = 1, enabled: Bool = true,
                   event: @escaping (DesktopPointerEvent) -> Void) {
        if self.mode != mode || self.pixels != pixels || !enabled { cancelInteraction() }
        self.mode = mode; self.pixels = pixels; self.sensitivity = sensitivity; self.scrollSensitivity = scrollSensitivity
        self.event = enabled ? event : nil
        isUserInteractionEnabled = enabled
        accessibilityLabel = mode.title
        updateAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        thumb.bounds = CGRect(x: 0, y: 0, width: 38, height: 38)
        pointer.frame = CGRect(x: 9, y: 9, width: 20, height: 20)
        centerMark.frame = CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
        hint.frame = CGRect(x: 12, y: bounds.height - 32, width: max(0, bounds.width - 24), height: 20)
        updateAppearance()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { cancelInteraction() } }
    override func accessibilityActivate() -> Bool { event?(.click("left", 1)); return true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let samples = samples(touches, create: true)
        deliver(gesture.began(samples, at: event?.timestamp ?? CACurrentMediaTime()))
        updateAppearance()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(gesture.moved(samples(touches), scrollSensitivity: scrollSensitivity))
        updateAppearance()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(gesture.ended(samples(touches), at: event?.timestamp ?? CACurrentMediaTime(), scrollSensitivity: scrollSensitivity))
        for touch in touches { touchIDs.removeValue(forKey: ObjectIdentifier(touch)) }
        updateAppearance()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelInteraction() }

    func cancelInteraction() {
        deliver(gesture.cancel()); touchIDs.removeAll()
        updateAppearance()
    }
    private func samples(_ touches: Set<UITouch>, create: Bool = false) -> [DesktopTouchpadGesture.Touch] {
        touches.compactMap { touch in
            let identity = ObjectIdentifier(touch)
            if create, touchIDs[identity] == nil { nextTouchID += 1; touchIDs[identity] = nextTouchID }
            guard let id = touchIDs[identity] else { return nil }
            return .init(id: id, point: touch.location(in: self), tapCount: touch.tapCount)
        }
    }
    private func deliver(_ events: [DesktopPointerEvent]) {
        for value in events {
            if case .move(let delta) = value {
                let distance = DesktopPointerMotion.distance(delta, pixels: pixels, sensitivity: sensitivity)
                if distance != .zero { event?(.move(distance)) }
            } else { event?(value) }
        }
    }
    private func updateAppearance() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumb.isHidden = mode != .stick
        centerMark.isHidden = mode != .stick
        hint.isHidden = mode == .stick || gesture.active
        let offset = gesture.translation
        let length = hypot(offset.width, offset.height)
        let radius = min(DesktopPointerMotion.radius, max(0, (min(bounds.width, bounds.height) - 38) / 2))
        let scale = length > radius ? radius / length : 1
        thumb.center = CGPoint(x: bounds.midX + offset.width * scale, y: bounds.midY + offset.height * scale)
        pointer.tintColor = gesture.buttonDown ? UIColor(Palette.accent) : .label
        CATransaction.commit()
    }
    deinit { if let inactivity { NotificationCenter.default.removeObserver(inactivity) } }
}
