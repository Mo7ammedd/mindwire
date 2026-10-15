import SwiftUI
import ImageIO

private struct DesktopWorkspaceKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var desktopWorkspaceID: String? {
        get { self[DesktopWorkspaceKey.self] }
        set { self[DesktopWorkspaceKey.self] = newValue }
    }
}

struct DesktopToolContent: View {
    let action: DaemonSurfaceToolAction
    @Environment(\.desktopWorkspaceID) private var workspaceID
    @Environment(\.stores) private var stores
    @State private var image: UIImage?
    @State private var error: String?
    @State private var showDesktop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if action.capture != nil {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Saved workspace desktop screenshot")
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Load screenshot") { Task { await loadImage() } }.font(.caption)
                } else { ProgressView().frame(maxWidth: .infinity, minHeight: 70) }
            }
            if let status = action.status {
                Text(status == "dispatched" ? "Input sent" : status == "outcome_unknown" ? "Input may have been sent. Check the desktop before retrying." : status)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if workspaceID != nil {
                Button("Open desktop", icon: .monitor) { showDesktop = true }.font(.subheadline)
            }
        }
        .task(id: action.capture?.artifactId) { await loadImage() }
        .fullScreenCover(isPresented: $showDesktop) {
            if let workspaceID {
                if action.desktopId == nil, WorkspaceRepository.shared.get(workspaceID)?.isCloud == true {
                    DesktopSessionsScreen(workspaceId: workspaceID)
                } else {
                    DesktopScreen(workspaceId: workspaceID, desktopId: action.desktopId)
                }
            }
        }
    }

    @MainActor private func loadImage() async {
        guard let capture = action.capture else { return }
        guard let workspaceID, let workspace = WorkspaceRepository.shared.get(workspaceID) else {
            error = "Open this chat in its workspace to load the screenshot."; return
        }
        let context = WorkspaceConnectionContext(workspace, stores: stores)
        let key = "\(OblienAuth.shared.user?.id ?? 0):\(workspaceID):\(capture.artifactId)"
        if let cached = DesktopImageCache.shared.object(forKey: key as NSString) { image = cached; return }
        do {
            let api = try await stores.workspaceData.desktopHTTP(workspace)
            let artifact: DesktopArtifact = try await api.decode("GET", "/artifacts/\(capture.artifactId)", quiet: true)
            guard artifact.mime == "image/png", artifact.data.count <= 8 * 1024 * 1024,
                  artifact.width > 0, artifact.height > 0, artifact.width * artifact.height <= 16 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(artifact.data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == artifact.width,
                  properties[kCGImagePropertyPixelHeight] as? Int == artifact.height,
                  let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else {
                throw DesktopProblem(code: "image_invalid", message: "This screenshot could not be loaded.")
            }
            try Task.checkCancellation()
            guard context == WorkspaceConnectionContext(workspace, stores: stores), WorkspaceRepository.shared.get(workspaceID) != nil else { return }
            let decoded = UIImage(cgImage: frame)
            DesktopImageCache.shared.setObject(decoded, forKey: key as NSString, cost: frame.width * frame.height * 4)
            image = decoded; error = nil
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private enum DesktopImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
}
