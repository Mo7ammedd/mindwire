import SwiftUI

extension NavigationPath {
    /// SwiftUI lazily resolves decoded paths; its equality can report false for the same
    /// destinations before/after that resolution. Keep notification reuse independent of it.
    func hasSameDestinations(as other: NavigationPath) -> Bool {
        if self == other { return true }
        guard count == other.count, let first = codable, let second = other.codable else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let left = try? encoder.encode(first), let right = try? encoder.encode(second) else { return false }
        return left == right
    }
}

/// Only screen identifiers are archived. Drafts, credentials, alerts, active recordings and
/// network connections remain owned by their existing services and are never replayed here.
struct AppNavigationSnapshot: Codable {
    static let currentVersion = 1
    var version = currentVersion
    let selectedTab: AppTab
    let tabs: [Tab]
    var assistantChatID: String? = nil

    struct Tab: Codable {
        let tab: AppTab
        let path: NavigationPath.CodableRepresentation?
        let sidebar: NavigationPath.CodableRepresentation?
        let sidebarHidden: Bool
        let chatId: String?
    }
}

/// One small atomic file, shared by this process's windows. No timer, workspace request or
/// account is needed. SceneStorage supplies the stable window identity across scene restoration.
@MainActor
final class NavigationRestorationStore {
    static let shared = NavigationRestorationStore(url: location())
    private static let maximumBytes = 1_048_576
    private static let maximumWindows = 12

    private struct Archive: Codable {
        var version = 1
        var recent: String?
        var order: [String] = []
        var windows: [String: Data] = [:]
    }

    private let write: (Data) throws -> Void
    private let encoder: JSONEncoder
    private var archive: Archive
    private var saved: Data?
    private var claimed: Set<String> = []

    init(read: @escaping () -> Data?, write: @escaping (Data) throws -> Void) {
        self.write = write
        encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = read()
        if let data, data.count <= Self.maximumBytes,
           let value = try? JSONDecoder().decode(Archive.self, from: data), value.version == 1 {
            archive = value
            saved = data
        } else { archive = Archive() }
    }

    convenience init(url: URL) {
        self.init(read: {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.maximumBytes else { return nil }
            return try? Data(contentsOf: url)
        }, write: { data in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var file = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? file.setResourceValues(values)
        })
    }

    static func location(previewSuite: String? = nil) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mindwire/Navigation", isDirectory: true)
        if let previewSuite {
            let name = previewSuite.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            return directory.appendingPathComponent("preview-\(name).json")
        }
        return directory.appendingPathComponent("windows.json")
    }

    /// If iOS creates a fresh scene after terminating the app, the first window resumes the
    /// most recent location. Additional new iPad windows start independently, never as clones.
    func restore(windowID: String) -> AppNavigationSnapshot? {
        let first = claimed.isEmpty
        claimed.insert(windowID)
        let data = archive.windows[windowID] ?? (first ? archive.recent.flatMap { archive.windows[$0] } : nil)
        guard let data, data.count <= 65_536,
              let snapshot = try? JSONDecoder().decode(AppNavigationSnapshot.self, from: data),
              snapshot.version == AppNavigationSnapshot.currentVersion else { return nil }
        return snapshot
    }

    @discardableResult
    func save(_ snapshot: AppNavigationSnapshot, windowID: String, makeRecent: Bool) -> Bool {
        guard let data = try? encoder.encode(snapshot), data.count <= 65_536 else { return false }
        archive.windows[windowID] = data
        if makeRecent || archive.recent == nil { archive.recent = windowID }
        archive.order.removeAll { $0 == windowID }
        archive.order.append(windowID)
        // Keep the archive bounded when iOS retires old scene sessions. Live windows still
        // own their in-memory paths and checkpoint again on their next interaction.
        while archive.order.count > Self.maximumWindows,
              let expired = archive.order.first(where: { $0 != archive.recent }) {
            archive.order.removeAll { $0 == expired }
            archive.windows.removeValue(forKey: expired)
        }
        guard let contents = try? encoder.encode(archive), contents.count <= Self.maximumBytes else { return false }
        guard contents != saved else { return true }
        do {
            try write(contents)
            saved = contents
            return true
        } catch {
            APILog.note("navigation: could not save the current screen — \(error.localizedDescription.oneLine())")
            return false
        }
    }
}

/// Coalesces a tab change and its push into one write. Inactive/background transitions flush
/// synchronously, before iOS can suspend the process. Foregrounding never restores a second time.
@MainActor
final class NavigationRestoration {
    private weak var app: AppModel?
    private var store: NavigationRestorationStore?
    private var windowID: String?
    private var active = false
    private var pending: Task<Void, Never>?
    private(set) var started = false

    func start(app: AppModel, store: NavigationRestorationStore, windowID: String, phase: ScenePhase) {
        guard !started else { return }
        started = true
        self.app = app
        self.store = store
        self.windowID = windowID
        active = phase == .active
        if let snapshot = store.restore(windowID: windowID) { app.restoreNavigation(snapshot) }
        app.navigationDidChange = { [weak self] in self?.schedule() }
        schedule()
    }

    func phaseChanged(_ phase: ScenePhase) {
        if phase == .active { active = true }
        flush()
        if phase != .active { active = false }
    }

    func flush() {
        pending?.cancel()
        pending = nil
        guard let app, let store, let windowID else { return }
        store.save(app.navigationSnapshot, windowID: windowID, makeRecent: active)
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}

private struct NavigationRestorationModifier: ViewModifier {
    let app: AppModel
    let store: NavigationRestorationStore?
    @SceneStorage("mindwire.navigation.window") private var windowID = UUID().uuidString
    @State private var restoration = NavigationRestoration()
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let store { restoration.start(app: app, store: store, windowID: windowID, phase: phase) }
            }
            .onChange(of: phase) { _, phase in restoration.phaseChanged(phase) }
            .onDisappear { restoration.flush() }
    }
}

extension View {
    @MainActor
    func restoringNavigation(_ app: AppModel, store: NavigationRestorationStore?) -> some View {
        modifier(NavigationRestorationModifier(app: app, store: store))
    }
}
