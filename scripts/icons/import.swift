// Run from the repository root. Only imports the reviewed catalog, never the whole library.
// swift scripts/icons/import.swift /path/to/png-icons /path/to/openship/apps/dashboard/public/icons
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

struct Catalog: Decodable {
    let version: Int
    let theme: String
    let icons: [String: Source]
}
struct Source: Decodable {
    let file: String
    let origin: String
    let sha256: String
    let inset: Double
    let label: String
}
struct ImportError: Error, CustomStringConvertible { let description: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ImportError(description: message) }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let arguments = CommandLine.arguments
try require(arguments.count == 3, "Usage: swift scripts/icons/import.swift <png-icons directory> <Openship public/icons directory>")
let catalogURL = root.appendingPathComponent("scripts/icons/catalog.json")
let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
try require(catalog.version == 1, "Unsupported catalog version")
let output = root.appendingPathComponent("apps/apple/Mindwire/Resources/InterfaceIcons.xcassets")
let generated = root.appendingPathComponent("apps/apple/Mindwire/DesignSystem/AppIconName.swift")
let jsonOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
func writeJSON(_ value: Any, to url: URL) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: jsonOptions)
    data.append(10)
    try data.write(to: url, options: .atomic)
}
func assetName(_ key: String) -> String { "ui-" + key }

struct Imported {
    let key: String
    let source: Source
    let data: Data
    let bounds: CGRect
}
var imported: [Imported] = []
var seen: Set<String> = []
// Validate everything before touching the app's asset catalog.
for key in catalog.icons.keys.sorted() {
    let spec = catalog.icons[key]!
    try require(key.range(of: "^[a-z][A-Za-z0-9]*$", options: .regularExpression) != nil, "Invalid Swift icon ID: \(key)")
    try require(spec.file == (spec.file as NSString).lastPathComponent && spec.file.hasSuffix(".png"), "Invalid icon filename")
    try require((0..<12).contains(spec.inset), "Invalid optical inset for \(key)")
    try require(!spec.label.trimmingCharacters(in: .whitespaces).isEmpty, "Missing accessibility label for \(key)")
    try require(["collection", "openship"].contains(spec.origin), "Unknown source for \(key)")
    let directory = URL(fileURLWithPath: arguments[spec.origin == "collection" ? 1 : 2])
    let data = try Data(contentsOf: directory.appendingPathComponent(spec.file))
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try require(hash == spec.sha256, "Source changed: \(key). Review the new artwork before updating its checksum.")
    try require(seen.insert(hash).inserted, "Duplicate artwork: \(key). Reuse the existing catalog ID.")
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ImportError(description: "Cannot decode \(key)")
    }
    let width = image.width, height = image.height
    try require(width > 0 && height > 0 && width <= 1024 && height <= 1024, "Icon dimensions are excessive: \(key)")
    let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
    defer { pixels.deallocate() }
    pixels.initialize(repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw ImportError(description: "Cannot measure \(key)")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var left = width, top = height, right = 0, bottom = 0
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
            left = min(left, x); top = min(top, y); right = max(right, x + 1); bottom = max(bottom, y + 1)
        }
    }
    try require(right > left && bottom > top, "Empty artwork: \(key)")
    let bounds = CGRect(x: Double(left) / Double(width), y: Double(top) / Double(height),
                        width: Double(right - left) / Double(width), height: Double(bottom - top) / Double(height))
    imported.append(Imported(key: key, source: spec, data: data, bounds: bounds))
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let expectedSets = Set(imported.map { assetName($0.key) + ".imageset" })
for previous in try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
    where previous.pathExtension == "imageset" && previous.lastPathComponent.hasPrefix("ui-")
        && !expectedSets.contains(previous.lastPathComponent) {
    try FileManager.default.removeItem(at: previous)
}
try writeJSON(["info": ["author": "xcode", "version": 1]], to: output.appendingPathComponent("Contents.json"))
var swift = """
// Generated by scripts/icons/import.swift from scripts/icons/catalog.json. Do not edit by hand.
import CoreGraphics

/// Stable, typed UI icon IDs. Artwork is bundled and never fetched over the network.
enum AppIconName: String, CaseIterable, Sendable {

"""
for item in imported { swift += "    case \(item.key)\n" }
swift += """

    var assetName: String { "ui-" + rawValue }

    var accessibilityTitle: String {
        switch self {

"""
for item in imported { swift += "        case .\(item.key): \(String(reflecting: item.source.label))\n" }
swift += """
        }
    }

    /// Alpha bounds on the source canvas; all glyphs fit the same optical slot.
    var artwork: AppIconArtwork {
        switch self {

"""
for item in imported {
    let set = output.appendingPathComponent(assetName(item.key) + ".imageset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    // Original source bytes and filename are preserved, including transparent negative space.
    try item.data.write(to: set.appendingPathComponent(item.source.file), options: .atomic)
    for previous in try FileManager.default.contentsOfDirectory(at: set, includingPropertiesForKeys: nil)
        where previous.pathExtension == "png" && previous.lastPathComponent != item.source.file {
        try FileManager.default.removeItem(at: previous)
    }
    try writeJSON([
        "images": [["filename": item.source.file, "idiom": "universal", "scale": "1x"]],
        "info": ["author": "xcode", "version": 1],
        "properties": ["template-rendering-intent": "template"]
    ], to: set.appendingPathComponent("Contents.json"))
    let b = item.bounds
    swift += "        case .\(item.key): .init(bounds: CGRect(x: \(b.minX), y: \(b.minY), width: \(b.width), height: \(b.height)), inset: \(item.source.inset))\n"
}
swift += """
        }
    }

    var mirrorsInRightToLeftLayout: Bool {
        switch self {
        case .arrowUpRight, .chevronLeft, .chevronRight, .externalLink, .login, .logout, .sidebarOpen, .sidebarClose, .undo:
            true
        default:
            false
        }
    }
}

struct AppIconArtwork: Sendable {
    let bounds: CGRect
    let inset: CGFloat
}

"""
try Data(swift.utf8).write(to: generated, options: .atomic)
if imported.contains(where: { $0.source.origin == "openship" }) {
    let license = URL(fileURLWithPath: arguments[2]).appendingPathComponent("LICENSE.lucide")
    try Data(contentsOf: license).write(to: root.appendingPathComponent("apps/apple/Mindwire/Resources/InterfaceIcons-LICENSE.txt"), options: .atomic)
}
let bytes = imported.reduce(0) { $0 + $1.data.count }
print("Imported \(imported.count) icons (\(bytes) PNG bytes); generated typed catalog and measured alpha bounds.")
