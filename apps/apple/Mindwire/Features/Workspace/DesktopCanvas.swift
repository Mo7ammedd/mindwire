import SwiftUI
import UIKit

struct DesktopCanvas: UIViewRepresentable {
    let image: CGImage
    let canControl: Bool
    var sourceSize: CGSize?
    var alignTop = true
    var cursor: DesktopCursor?
    var scrollSensitivity: Double = 1
    let send: (DesktopInput) -> Void

    func makeUIView(context: Context) -> DesktopCanvasView { DesktopCanvasView() }
    func updateUIView(_ view: DesktopCanvasView, context: Context) {
        view.send = canControl ? send : nil
        view.alignTop = alignTop
        view.inputPixels = sourceSize
        view.cursor = cursor
        view.scrollSensitivity = scrollSensitivity
        view.show(image)
    }
    static func dismantleUIView(_ view: DesktopCanvasView, coordinator: ()) { view.cursor = nil; view.send = nil }
}

/// Pinch to zoom; two fingers pan the magnified display. Tap/double-tap click,
/// a swipe scrolls remotely, and a long press can right-click or drag.
final class DesktopCanvasView: UIScrollView, UIScrollViewDelegate {
    var send: ((DesktopInput) -> Void)?
    var inputPixels: CGSize?
    var scrollSensitivity: Double = 1
    var alignTop = true { didSet { if oldValue != alignTop { centerDisplay() } } }
    var pointer: CGPoint? { didSet { positionCursor() } }
    var cursor: DesktopCursor? {
        didSet {
            guard oldValue !== cursor else { return }
            oldValue?.detach(from: self)
            cursor?.attach(to: self)
        }
    }
    private let desktop = UIImageView()
    private let cursorImage = UIImageView(image: AppIconImages.image(.pointer, size: 24, scale: 3))
    private var cursorShape: DesktopCursorShape?
    private(set) var cursorPressed = false
    private var scrollMotion = DesktopScrollMotion()
    private var currentImage: CGImage?
    private var pixels = CGSize.zero
    private var lastBounds = CGSize.zero
    private var dragStart: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        delegate = self
        contentInsetAdjustmentBehavior = .never // SwiftUI already supplies the viewport's safe area.
        minimumZoomScale = 1; maximumZoomScale = 5
        bouncesZoom = true; showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        panGestureRecognizer.minimumNumberOfTouches = 2
        desktop.isUserInteractionEnabled = true
        desktop.contentMode = .scaleAspectFit
        desktop.accessibilityLabel = "Workspace desktop"
        desktop.accessibilityHint = "Tap to click. Swipe to scroll. Hold to right-click or drag. Pinch to zoom."
        addSubview(desktop)
        cursorImage.tintColor = .white
        cursorImage.layer.shadowColor = UIColor.black.cgColor; cursorImage.layer.shadowOpacity = 1
        cursorImage.layer.shadowRadius = 1; cursorImage.layer.shadowOffset = .zero
        let artwork = AppIconName.pointer.artwork
        let extent = (24 - 2 * artwork.inset) / 24
        let longestSide = max(artwork.bounds.width, artwork.bounds.height)
        cursorImage.layer.anchorPoint = CGPoint(x: (1 - artwork.bounds.width / longestSide * extent) / 2,
                                           y: (1 - artwork.bounds.height / longestSide * extent) / 2)
        cursorImage.isHidden = true
        desktop.addSubview(cursorImage)
        let tap = UITapGestureRecognizer(target: self, action: #selector(click(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleClick(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        desktop.addGestureRecognizer(tap); desktop.addGestureRecognizer(double)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
        hold.minimumPressDuration = 0.4; hold.allowableMovement = 16
        desktop.addGestureRecognizer(hold)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(remoteScroll(_:)))
        scroll.maximumNumberOfTouches = 1
        scroll.require(toFail: hold)
        desktop.addGestureRecognizer(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: CGImage) {
        guard currentImage !== image else { return }
        currentImage = image
        desktop.image = UIImage(cgImage: image)
        let size = CGSize(width: image.width, height: image.height)
        if pixels != size { pixels = size; layoutDisplay(reset: true) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if lastBounds != bounds.size { lastBounds = bounds.size; layoutDisplay(reset: false) }
        centerDisplay()
    }
    private func layoutDisplay(reset: Bool) {
        guard pixels.width > 0, pixels.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let previousZoom = reset ? 1 : zoomScale
        setZoomScale(1, animated: false)
        let scale = min(bounds.width / pixels.width, bounds.height / pixels.height)
        desktop.frame = CGRect(origin: .zero, size: CGSize(width: pixels.width * scale, height: pixels.height * scale))
        contentSize = desktop.frame.size
        setZoomScale(previousZoom, animated: false)
        centerDisplay()
    }
    private func centerDisplay() {
        desktop.center = CGPoint(x: max(contentSize.width, bounds.width) / 2,
                                 y: (alignTop ? contentSize.height : max(contentSize.height, bounds.height)) / 2)
        positionCursor()
    }
    var displayedFrame: CGRect { desktop.frame }
    func updateCursor(shape: DesktopCursorShape?, pressed: Bool) {
        if let shape, cursorShape?.image !== shape.image {
            cursorShape = shape
            cursorImage.image = UIImage(cgImage: shape.image).withRenderingMode(.alwaysOriginal)
            cursorImage.layer.anchorPoint = CGPoint(x: shape.hotspot.x / CGFloat(shape.image.width),
                                                     y: shape.hotspot.y / CGFloat(shape.image.height))
        }
        cursorPressed = pressed
        positionCursor()
    }
    private func positionCursor() {
        guard let pointer, pixels.width > 0 else { cursorImage.isHidden = true; return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorImage.isHidden = false
        let size = cursorShape.map { CGSize(width: $0.image.width, height: $0.image.height) } ?? CGSize(width: 22, height: 22)
        let scale = (cursorPressed ? 20.0 : 22.0) / max(size.width, size.height) / zoomScale
        cursorImage.bounds = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
        cursorImage.layer.position = CGPoint(x: pointer.x * desktop.bounds.width, y: pointer.y * desktop.bounds.height)
        CATransaction.commit()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { desktop }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerDisplay() }

    static func pixelPoint(_ point: CGPoint, displayedSize: CGSize, pixels: CGSize) -> CGPoint? {
        guard displayedSize.width > 0, displayedSize.height > 0, pixels.width > 0, pixels.height > 0,
              point.x >= 0, point.y >= 0, point.x < displayedSize.width, point.y < displayedSize.height else { return nil }
        return CGPoint(x: floor(point.x / displayedSize.width * pixels.width), y: floor(point.y / displayedSize.height * pixels.height))
    }
    private func point(_ recognizer: UIGestureRecognizer) -> CGPoint? {
        Self.pixelPoint(recognizer.location(in: desktop), displayedSize: desktop.bounds.size, pixels: inputPixels ?? pixels)
    }
    @objc private func click(_ recognizer: UITapGestureRecognizer) { click(recognizer, count: 1) }
    @objc private func doubleClick(_ recognizer: UITapGestureRecognizer) { click(recognizer, count: 2) }
    private func click(_ recognizer: UIGestureRecognizer, count: Int) {
        guard let p = point(recognizer) else { return }
        send?(.init(kind: "click", x: Int(p.x), y: Int(p.y), count: count))
    }
    @objc private func hold(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began: dragStart = point(recognizer)
        case .ended:
            defer { dragStart = nil }
            guard let start = dragStart, let end = point(recognizer) else { return }
            if hypot(start.x - end.x, start.y - end.y) > 8 {
                send?(.init(kind: "drag", x: Int(start.x), y: Int(start.y), toX: Int(end.x), toY: Int(end.y)))
            } else { send?(.init(kind: "click", x: Int(end.x), y: Int(end.y), button: "right")) }
        case .cancelled, .failed: dragStart = nil
        default: break
        }
    }
    @objc private func remoteScroll(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { scrollMotion = .init() }
        if recognizer.state == .cancelled || recognizer.state == .failed { scrollMotion = .init(); return }
        guard recognizer.state == .changed || recognizer.state == .ended, let p = point(recognizer) else { return }
        let delta = recognizer.translation(in: self)
        let (dx, dy) = scrollMotion.consume(CGSize(width: delta.x, height: delta.y), sensitivity: scrollSensitivity)
        recognizer.setTranslation(.zero, in: self)
        if dx != 0 || dy != 0 {
            send?(.init(kind: "scroll", x: Int(p.x), y: Int(p.y), deltaX: dx, deltaY: dy))
        }
        if recognizer.state == .ended { scrollMotion = .init() }
    }
}
