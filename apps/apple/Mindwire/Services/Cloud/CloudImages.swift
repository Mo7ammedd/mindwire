import Foundation
import OblienKit

/// A selectable Oblien Cloud base image. `image` is the Docker ref that `POST /workspace` wants
/// (e.g. `node:22`) — NOT `id` (`node-22`), which is just the catalog key.
struct WorkspaceImage: Identifiable, Sendable {
    let id: String          // catalog key (stable selection/display id)
    let label: String
    let description: String?
    let category: String?
    let image: String       // Docker image ref — the value sent on create
    let logo: String?       // logo URL (png / ico / svg)
    let color: String?      // brand hex, e.g. "#5FA04E"
    var preset: String? = nil
    var minimumCPUs: Int = 1
    var minimumMemoryMb: Int = 1024
    var minimumDiskMb: Int = 1024
    var vmDefaults: WorkspaceConfig? = nil
    var diskTargets: [DiskTarget]? = nil
    var capabilities: [String] = []

    struct DiskTarget: Identifiable, Sendable {
        let id: String
        var label: String
        var formats: [String]
    }

    init?(catalogImage value: OblienKit.Image) {
        guard let reference = value.image?.nonBlank else { return nil }
        id = value.id; label = value.label ?? value.id; description = value.description
        category = value.category; image = reference; logo = value.logo; color = value.color
        preset = value.preset
        minimumCPUs = max(1, value.minimumResources?.cpus ?? 1)
        minimumMemoryMb = max(1024, value.minimumResources?.memoryMb ?? value.minimumMemoryMb ?? 1024)
        minimumDiskMb = max(1024, value.minimumResources?.diskSizeMb ?? 1024)
        vmDefaults = value.vmDefaults
        diskTargets = value.diskTargets?.map { .init(id: $0.id, label: $0.label ?? $0.id, formats: $0.formats ?? []) }
        capabilities = value.capabilities ?? []
    }
}

@MainActor
enum CloudImages {
    /// Session cache so lightweight callers (e.g. the workspace image footer) don't re-fetch the
    /// whole catalog on every open.
    private static var cache: [WorkspaceImage] = []
    private static var hasLoaded = false
    private static var pending: Task<[WorkspaceImage], Error>?
    private static var retryAfter = Date.distantPast
    private static var loadedAt = Date.distantPast

    /// Available base images via the SDK (`workspaces.images()` — management API). An image with no
    /// Docker ref can't be created, so it's dropped.
    static func list(force: Bool = false) async throws -> [WorkspaceImage] {
        if let pending { return try await pending.value }
        if !force, hasLoaded, Date().timeIntervalSince(loadedAt) < 3600 { return cache }
        let task = Task { @MainActor in
            defer { pending = nil }
            do {
                let imageList = try await OblienCloud.client.workspaces.images()
                let result = imageList.images.compactMap(WorkspaceImage.init(catalogImage:))
                cache = result
                hasLoaded = true
                loadedAt = Date()
                APILog.note("images: \(result.count) (e.g. \(result.first.map { "\($0.id)→\($0.image)" } ?? "—"))")
                return result
            } catch {
                retryAfter = Date().addingTimeInterval(30)
                throw error
            }
        }
        pending = task
        return try await task.value
    }

    /// Catalog from the session cache, fetching once if empty. Use for logo lookups that shouldn't
    /// trigger a network call on every screen.
    static func cached() async -> [WorkspaceImage] {
        if hasLoaded || Date() < retryAfter { return cache }
        return (try? await list()) ?? cache
    }

    /// A workspace may retain an older image tag. Reuse that image family's logo
    /// without requiring a new request or confusing it with a similarly named image.
    static func match(_ image: String, in catalog: [WorkspaceImage]) -> WorkspaceImage? {
        catalog.first { $0.image == image }
            ?? catalog.first { repository($0.image) == repository(image) }
    }

    static func repository(_ image: String) -> String {
        let reference = String(image.split(separator: "@", maxSplits: 1).first ?? "")
        let lastComponent = reference.split(separator: "/").last.map(String.init) ?? reference
        guard let tag = lastComponent.firstIndex(of: ":") else { return reference.lowercased() }
        return String(reference.dropLast(lastComponent.distance(from: tag, to: lastComponent.endIndex))).lowercased()
    }

    static func operatingSystem(_ image: String) -> String? {
        let name = repository(image).split(separator: "/").last.map(String.init) ?? ""
        let systems = [("macos", "macOS"), ("ubuntu", "Ubuntu"), ("debian", "Debian"),
                       ("alpine", "Alpine Linux"), ("fedora", "Fedora"), ("archlinux", "Arch Linux"),
                       ("nixos", "NixOS"), ("rockylinux", "Rocky Linux"), ("almalinux", "AlmaLinux"),
                       ("linuxmint", "Linux Mint"), ("windows", "Windows")]
        return systems.first { name == $0.0 || name.hasPrefix($0.0 + "-") }?.1
    }

    static func displayName(_ image: String, in catalog: [WorkspaceImage]) -> String {
        if let system = operatingSystem(image) { return system }
        if let exact = catalog.first(where: { $0.image == image }) { return exact.label }
        // Do not label an older tag with the current catalog entry's version.
        return image.split(separator: "/").last.map(String.init) ?? image
    }
}
