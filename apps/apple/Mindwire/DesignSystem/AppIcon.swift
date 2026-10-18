import SwiftUI

enum AppIconContext {
    case content, menu, toolbar
}

enum AppIconMetrics {
    // Native menus own a fixed slot; source PNG margins never contribute to its size.
    static let menuSize: CGFloat = ApplePlatform.isDesktop ? 14 : 22
    static let toolbarReduction: CGFloat = 2
}

private struct AppIconContextKey: EnvironmentKey {
    static let defaultValue: AppIconContext = .content
}

extension EnvironmentValues {
    var appIconContext: AppIconContext {
        get { self[AppIconContextKey.self] }
        set { self[AppIconContextKey.self] = newValue }
    }
}

/// A bundled template image that follows the surrounding font, Dynamic Type and tint.
/// Body-text controls use 22-point icons; explicit image slots can supply their own size.
/// The body resolves to a native Image so menus, buttons and tab labels retain UIKit behavior.
struct AppIcon: View {
    let name: AppIconName
    private let size: CGFloat?
    private let decorative: Bool
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(\.imageScale) private var imageScale
    @Environment(\.displayScale) private var displayScale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.appIconContext) private var context

    init(_ name: AppIconName, size: CGFloat? = nil, decorative: Bool = false) {
        self.name = name
        self.size = size
        self.decorative = decorative
    }

    var body: some View {
        let pointSize = (font ?? .body).resolve(in: fontContext).pointSize
        let factor: CGFloat = imageScale == .large ? 1.2 : (imageScale == .small ? 0.85 : 1)
        let baseSize = size ?? (context == .menu ? AppIconMetrics.menuSize : pointSize * 22 / 17 * factor)
        let iconSize = context == .toolbar ? max(1, baseSize - AppIconMetrics.toolbarReduction) : baseSize
        let image = Image(uiImage: AppIconImages.image(name, size: iconSize, scale: displayScale,
                                                       mirrored: layoutDirection == .rightToLeft))
        if context == .menu {
            // UIKit extracts the image from a native menu Label. Hiding that image from
            // accessibility also hides the entire menu action; the Label supplies its title.
            image
        } else {
            image
                .accessibilityLabel(Text(name.accessibilityTitle))
                .accessibilityHidden(decorative)
        }
    }

    /// Explicit image slots (project rows and previews) already own their dimensions.
    func resizable() -> Image {
        Image(uiImage: AppIconImages.image(name, size: 44, scale: 3)).resizable()
    }
}

/// Header controls keep their native hit targets and toolbar behavior. Only their
/// custom glyphs shrink; navigation actions use neutral tint independently of the brand accent.
struct AppToolbarItem<Content: View>: ToolbarContent {
    var placement: ToolbarItemPlacement = .automatic
    @ViewBuilder let content: () -> Content

    var body: some ToolbarContent {
        ToolbarItem(placement: placement) {
            content().environment(\.appIconContext, .toolbar).tint(.primary)
        }
    }
}

struct AppToolbarItemGroup<Content: View>: ToolbarContent {
    var placement: ToolbarItemPlacement = .automatic
    @ViewBuilder let content: () -> Content

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: placement) {
            content().environment(\.appIconContext, .toolbar).tint(.primary)
        }
    }
}

/// Shared raster cache. Changing tint never creates a new bitmap; the template is colored by iOS.
@MainActor
enum AppIconImages {
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 512
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    static func image(_ name: AppIconName, size: CGFloat, scale: CGFloat, mirrored: Bool = false) -> UIImage {
        let scale = max(1, scale)
        let size = max(1, (size * scale).rounded()) / scale
        let flip = mirrored && name.mirrorsInRightToLeftLayout
        let key = "\(name.rawValue):\(size):\(scale):\(flip)" as NSString
        if let image = images.object(forKey: key) { return image }
        guard let source = UIImage(named: name.assetName)?.cgImage else {
            assertionFailure("Missing bundled UI icon: \(name.assetName)")
            return UIImage()
        }
        let artwork = name.artwork
        let rect = CGRect(x: artwork.bounds.minX * CGFloat(source.width),
                          y: artwork.bounds.minY * CGFloat(source.height),
                          width: artwork.bounds.width * CGFloat(source.width),
                          height: artwork.bounds.height * CGFloat(source.height)).integral
        guard let cropped = source.cropping(to: rect) else { return UIImage() }
        // Crop the source padding and keep only one physical pixel for edge filtering.
        // Additional optical insets are explicit catalog exceptions, not a blanket margin.
        let inset = max(1 / scale, size * artwork.inset / 24)
        let extent = max(1 / scale, size - 2 * inset)
        let ratio = extent / max(rect.width, rect.height)
        let drawing = CGRect(x: (size - rect.width * ratio) / 2, y: (size - rect.height * ratio) / 2,
                             width: rect.width * ratio, height: rect.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            if flip {
                context.cgContext.translateBy(x: size, y: 0)
                context.cgContext.scaleBy(x: -1, y: 1)
            }
            UIImage(cgImage: cropped).draw(in: drawing)
        }.withRenderingMode(.alwaysTemplate)
        images.setObject(image, forKey: key, cost: Int(size * scale) * Int(size * scale) * 4)
        return image
    }
}

extension Label where Title == Text, Icon == AppIcon {
    init(_ title: String, icon: AppIconName) {
        self.init { Text(title) } icon: { AppIcon(icon, decorative: true) }
    }
}

extension Button where Label == SwiftUI.Label<Text, AppIcon> {
    init(_ title: String, icon: AppIconName, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, icon: icon) }
    }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, AppIcon>, Description == Text?, Actions == EmptyView {
    init(_ title: String, icon: AppIconName, description: Text? = nil) {
        self.init { SwiftUI.Label(title, icon: icon) } description: { description }
    }
}
