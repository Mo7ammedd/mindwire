import CoreGraphics
import Foundation
import ImageIO
import RoyalVNCKit

struct DesktopStreamSettings: Equatable {
    var quality: DesktopStreamQuality = .balanced
    var framesPerSecond = 30

    static let frameRates = [15, 30, 60]
    var frameRate: Int { Self.frameRates.contains(framesPerSecond) ? framesPerSecond : 30 }
}

enum DesktopStreamQuality: String, CaseIterable, Identifiable {
    case dataSaver, balanced, original
    var id: Self { self }
    var title: String {
        switch self {
        case .dataSaver: "Data saver"
        case .balanced: "Balanced"
        case .original: "Original"
        }
    }
    var detail: String {
        switch self {
        case .dataSaver: "Compact image, lower bandwidth"
        case .balanced: "Clear text, lighter streaming"
        case .original: "Full resolution and color"
        }
    }
    // Request fewer color bits over RFB as well as a smaller presentation image.
    // The host's monitor resolution and other viewers are never changed.
    var colorDepth: VNCConnection.Settings.ColorDepth { self == .original ? .depth24Bit : .depth16Bit }
    var maximumDimension: Int? {
        switch self {
        case .dataSaver: 1280
        case .balanced: 1920
        case .original: nil
        }
    }
    // Tight servers also honor JPEG quality hints. Other encodings ignore them.
    var jpegQuality: Int32? {
        switch self {
        case .dataSaver: 5
        case .balanced: 8
        case .original: nil
        }
    }
    func imageSize(for source: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0, let maximumDimension else { return source }
        let scale = min(1, CGFloat(maximumDimension) / max(source.width, source.height))
        return CGSize(width: max(1, floor(source.width * scale)), height: max(1, floor(source.height * scale)))
    }
}

struct DesktopDisplayFrame {
    let image: CGImage
    let sourceSize: CGSize
    var requestedAt: TimeInterval = 0
}

struct DesktopCursorShape {
    let image: CGImage
    let hotspot: CGPoint

    init(image: CGImage, hotspot: CGPoint) { self.image = image; self.hotspot = hotspot }

    init?(remote: DesktopRemoteCursor) {
        guard (1...256).contains(remote.width), (1...256).contains(remote.height),
              (0..<remote.width).contains(remote.hotspotX), (0..<remote.height).contains(remote.hotspotY),
              remote.png.count <= 300_000,
              let source = CGImageSourceCreateWithData(remote.png as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == remote.width,
              properties[kCGImagePropertyPixelHeight] as? Int == remote.height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.image = image
        hotspot = CGPoint(x: remote.hotspotX, y: remote.hotspotY)
    }
}

enum DesktopPointerMode: String, CaseIterable, Identifiable {
    case touchpad, stick, screen
    var id: Self { self }
    var title: String {
        switch self {
        case .touchpad: "Touchpad"
        case .stick: "Mouse stick"
        case .screen: "Screen only"
        }
    }
    func active(fullscreen: Bool, keyboard: Bool, fullscreenStick: Bool) -> Self {
        if self == .screen { return .screen }
        if keyboard { return .stick }
        if fullscreen { return fullscreenStick ? .stick : .screen }
        return self
    }
}
