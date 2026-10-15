import SwiftUI
import CryptoKit
import ImageIO
import SVGView

/// Small, read-only snapshots. Native Git and the workspace's project metadata remain authoritative.
struct ProjectGitSummary: Codable, Equatable {
    let isRepo: Bool
    let branch: String?
    let detached: Bool
    let changedFiles: Int
    let additions: Int
    let deletions: Int
    let updatedAt: Date

    init(status: GitStatus, at date: Date) {
        isRepo = status.isRepo; branch = status.branch; detached = status.detached
        changedFiles = status.files.count
        additions = status.files.reduce(0) { $0 + ($1.staged?.additions ?? 0) + ($1.unstaged?.additions ?? 0) }
        deletions = status.files.reduce(0) { $0 + ($1.staged?.deletions ?? 0) + ($1.unstaged?.deletions ?? 0) }
        updatedAt = date
    }
}

struct ProjectIconData: Codable, Equatable {
    let path: String
    let mediaType: String
    let content: Data
    let etag: String

    static let extensions: Set<String> = ["svg", "png", "jpg", "jpeg", "gif"]

    /// Rasterize once, preserving alpha and aspect ratio. Rows render a tiny native image,
    /// never parse SVG documents or decode full-resolution photographs while scrolling.
    @MainActor func thumbnail() throws -> UIImage {
        guard !content.isEmpty, content.count <= 1_048_576 else { throw BackendError.message(t("project.icon.invalid")) }
        if mediaType == "image/svg+xml" {
            let svg = SVGView(data: content)
            guard svg.svg != nil else { throw BackendError.message(t("project.icon.invalid")) }
            let renderer = ImageRenderer(content: svg.frame(width: 128, height: 128))
            renderer.scale = 2
            guard let image = renderer.uiImage else { throw BackendError.message(t("project.icon.invalid")) }
            return image
        }
        guard let source = CGImageSourceCreateWithData(content as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else { throw BackendError.message(t("project.icon.invalid")) }
        return UIImage(cgImage: cgImage)
    }
}

@MainActor @Observable
final class ProjectPresentationCache {
    private struct Entry: Codable, Equatable {
        let workspaceId: String
        let registryId: String
        let path: String
        var iconPath: String?
        var git: ProjectGitSummary?
        var iconETag: String?
        var iconUpdatedAt: Date?
    }
    private struct Job {
        let ticket: UUID
        let task: Task<Void, Never>
    }
    private var entries: [String: Entry]
    private var images: [String: UIImage] = [:]
    private(set) var loading: Set<String> = []
    @ObservationIgnored private var jobs: [String: Job] = [:]
    @ObservationIgnored private var gitRevisions: [String: Int] = [:]
    @ObservationIgnored private var attempts: [String: Date] = [:]
    @ObservationIgnored private var dirtyGit: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let now: () -> Date
    private static let key = "mindwire:project-presentation:v1"
    static let maxAge: TimeInterval = 180

    init(defaults: UserDefaults, directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Mindwire/ProjectIcons", directoryHint: .isDirectory)
        entries = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        for (id, entry) in entries where entry.iconETag != nil {
            images[id] = UIImage(contentsOfFile: imageURL(id, entry).path)
        }
    }

    func git(for project: Project) -> ProjectGitSummary? { matching(project)?.git }
    func icon(for project: Project) -> UIImage? {
        guard let entry = matching(project), let path = project.iconPath, entry.iconPath == path else { return nil }
        return images[project.id]
    }

    private func matching(_ project: Project) -> Entry? {
        guard let entry = entries[project.id], entry.workspaceId == project.workspaceId, entry.path == project.path else { return nil }
        return entry
    }

    /// Snapshot reconciliation only touches local data. No row's rendering starts a remote check.
    func reconcile(projects: [Project], workspaceId: String, registryId: String) {
        let before = entries
        let ids = Set(projects.map(\.id))
        for id in Array(entries.keys) where entries[id]?.workspaceId == workspaceId && !ids.contains(id) { remove(id) }
        for project in projects {
            let old = entries[project.id]
            if old?.workspaceId != project.workspaceId || old?.registryId != registryId || old?.path != project.path {
                remove(project.id)
                entries[project.id] = Entry(workspaceId: workspaceId, registryId: registryId, path: project.path, iconPath: project.iconPath)
            } else if old?.iconPath != project.iconPath {
                cancel(project.id)
                if let old { try? FileManager.default.removeItem(at: imageURL(project.id, old)) }
                images[project.id] = nil
                entries[project.id]?.iconPath = project.iconPath
                entries[project.id]?.iconETag = nil
                entries[project.id]?.iconUpdatedAt = nil
                attempts[project.id] = nil
            }
        }
        if entries != before { persist() }
    }

    /// Called by successful workspace synchronization, bounded to two Git reads at a time.
    /// Reads share the already connected workspace backend and survive navigation away.
    func refresh(projects: [Project], registryId: String, force: Bool = false,
                 status: @escaping @MainActor (Project) async throws -> GitStatus?,
                 icon: @escaping @MainActor (Project) async throws -> ProjectIconData) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, project) in projects.enumerated() {
                if index >= 2 { await group.next() }
                group.addTask { await self.refresh(project, registryId: registryId, force: force, status: status, icon: icon) }
            }
        }
    }

    private func refresh(_ project: Project, registryId: String, force: Bool,
                         status: @escaping @MainActor (Project) async throws -> GitStatus?,
                         icon: @escaping @MainActor (Project) async throws -> ProjectIconData) async {
        guard let context = matching(project), context.registryId == registryId, context.iconPath == project.iconPath else { return }
        if let job = jobs[project.id] {
            await job.task.value
            if dirtyGit.contains(project.id) { await refresh(project, registryId: registryId, force: false, status: status, icon: icon) }
            return
        }
        if !force, let attempt = attempts[project.id], now().timeIntervalSince(attempt) < 30 { return }
        let needsGit = force || dirtyGit.contains(project.id) || (context.git.map { now().timeIntervalSince($0.updatedAt) >= Self.maxAge } ?? true)
        let needsIcon = project.iconPath != nil && (force || images[project.id] == nil
            || (context.iconUpdatedAt.map { now().timeIntervalSince($0) >= Self.maxAge } ?? true))
        guard needsGit || needsIcon else { return }
        let ticket = UUID(), revision = gitRevisions[project.id, default: 0]
        attempts[project.id] = now()
        loading.insert(project.id)
        let task = Task {
            defer {
                if jobs[project.id]?.ticket == ticket { jobs[project.id] = nil; loading.remove(project.id) }
            }
            if needsGit, let status = try? await status(project), !Task.isCancelled,
               jobs[project.id]?.ticket == ticket, gitRevisions[project.id, default: 0] == revision {
                record(status: status, for: project)
            }
            if needsIcon, let payload = try? await icon(project), !Task.isCancelled,
               jobs[project.id]?.ticket == ticket {
                try? record(icon: payload, for: project)
            }
        }
        jobs[project.id] = Job(ticket: ticket, task: task)
        await task.value
    }

    /// Source Control publishes its existing status reads instead of causing another request.
    func record(status: GitStatus, for project: Project) {
        guard matching(project) != nil else { return }
        gitRevisions[project.id, default: 0] += 1
        entries[project.id]?.git = ProjectGitSummary(status: status, at: now())
        dirtyGit.remove(project.id)
        persist()
    }

    func record(icon: ProjectIconData, for project: Project) throws {
        guard let entry = matching(project), entry.iconPath == icon.path, project.iconPath == icon.path else { return }
        if entry.iconETag != icon.etag || images[project.id] == nil {
            let image = try icon.thumbnail()
            images[project.id] = image
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? image.pngData()?.write(to: imageURL(project.id, entry), options: .atomic)
        }
        entries[project.id]?.iconETag = icon.etag
        entries[project.id]?.iconUpdatedAt = now()
        persist()
    }

    /// A completed agent run can change files without going through Source Control.
    func invalidateGit(_ projectId: String) {
        gitRevisions[projectId, default: 0] += 1
        attempts[projectId] = nil
        dirtyGit.insert(projectId) // Keep the last snapshot visible while replacing it.
    }

    func forget(workspaceId: String) {
        for id in Array(entries.keys) where entries[id]?.workspaceId == workspaceId { remove(id) }
        persist()
    }

    private func remove(_ id: String) {
        cancel(id)
        if let entry = entries.removeValue(forKey: id) { try? FileManager.default.removeItem(at: imageURL(id, entry)) }
        images[id] = nil; attempts[id] = nil; dirtyGit.remove(id)
    }
    private func cancel(_ id: String) {
        jobs.removeValue(forKey: id)?.task.cancel()
        loading.remove(id)
        gitRevisions[id, default: 0] += 1
    }
    private func imageURL(_ id: String, _ entry: Entry) -> URL {
        let key = [id, entry.workspaceId, entry.registryId, entry.path, entry.iconPath ?? ""].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".png")
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}
