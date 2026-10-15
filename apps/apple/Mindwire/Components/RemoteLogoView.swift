import SwiftUI
import SVGView

/// Renders a remote brand logo URL: SVG (incl. extension-less `cdn.simpleicons.org`) via the
/// pure-SwiftUI `SVGView`, raster (png/ico) via `AsyncImage`. While loading or on failure it shows
/// a branded chip (brand colour + initial). No WebKit. Reusable wherever a logo URL is shown.
struct RemoteLogoView: View {
    let logo: String?
    let brandHex: String?
    let label: String
    var size: CGFloat = 26

    var body: some View {
        content
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private var content: some View {
        if let logo, logo.hasPrefix("http"), let url = URL(string: logo) {
            if isSVG(logo) {
                RemoteSVGView(url: url) { chip }
            } else {
                AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { chip }
            }
        } else {
            chip
        }
    }

    private func isSVG(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains(".svg") || lower.contains("simpleicons.org")
    }

    private var chip: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Self.color(fromHex: brandHex) ?? Palette.surfaceAlt)
            .overlay(
                Text(String(label.first.map(Character.init) ?? "?").uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            )
    }

    /// Parse `#RRGGBB` / `RRGGBB` into a `Color`.
    static func color(fromHex hex: String?) -> Color? {
        guard var h = hex else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8) & 0xff) / 255,
                     blue: Double(v & 0xff) / 255)
    }
}

/// Fetches an SVG document once (cached in memory) and renders it via `SVGView`; shows `fallback`
/// until the document arrives or if the fetch fails.
private struct RemoteSVGView<Fallback: View>: View {
    let url: URL
    @ViewBuilder let fallback: Fallback
    @State private var svg: String?

    var body: some View {
        ZStack {
            if let svg { SVGView(string: svg) } else { fallback }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        if svg != nil { return }
        if let cached = SVGCache.shared.get(url.absoluteString) { svg = cached; return }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let text = String(data: data, encoding: .utf8) else { return }
        SVGCache.shared.set(url.absoluteString, text)
        svg = text
    }
}

/// Tiny in-memory SVG document cache (thread-safe via `NSCache`).
private final class SVGCache {
    static let shared = SVGCache()
    private let cache = NSCache<NSString, NSString>()
    func get(_ key: String) -> String? { cache.object(forKey: key as NSString) as String? }
    func set(_ key: String, _ value: String) { cache.setObject(value as NSString, forKey: key as NSString) }
}
