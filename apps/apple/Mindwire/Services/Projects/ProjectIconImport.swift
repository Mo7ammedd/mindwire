import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Prepare device images off the main thread. Uploaded raster icons retain alpha
/// and omit camera metadata; SVGs use the daemon's existing validation on save.
enum ProjectIconImport {
    private static let maximumSourceBytes = 25 * 1_024 * 1_024
    private static let maximumIconBytes = 1_048_576

    nonisolated static func file(_ url: URL) throws -> ProjectIconData {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var result: Result<ProjectIconData, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { file in
            result = Result {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard info.isRegularFile == true, (info.fileSize ?? 0) <= maximumSourceBytes else {
                    throw BackendError.message(t("project.icon.invalid"))
                }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maximumSourceBytes + 1) ?? Data()
                return try prepare(data, name: file.lastPathComponent)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw BackendError.message(t("project.icon.invalid")) }
        return try result.get()
    }

    nonisolated static func prepare(_ data: Data, name: String) throws -> ProjectIconData {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumSourceBytes else { throw BackendError.message(t("project.icon.invalid")) }
        if (name as NSString).pathExtension.lowercased() == "svg" {
            guard data.count <= maximumIconBytes else { throw BackendError.message(t("project.icon.invalid")) }
            return icon(data, name: (name as NSString).lastPathComponent, mediaType: "image/svg+xml")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw BackendError.message(t("project.icon.invalid"))
        }
        for dimension in [512, 384, 256] {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension, kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { break }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination), encoded.length <= maximumIconBytes {
                return icon(encoded as Data, name: (name as NSString).deletingPathExtension + ".png", mediaType: "image/png")
            }
        }
        throw BackendError.message(t("project.icon.invalid"))
    }

    nonisolated private static func icon(_ data: Data, name: String, mediaType: String) -> ProjectIconData {
        ProjectIconData(path: name, mediaType: mediaType, content: data,
            etag: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
