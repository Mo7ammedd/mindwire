import Foundation

/// Supported adapters are release metadata, shared by every workspace. Keep the last good list
/// across launches and share an in-flight refresh so opening pickers never starts workspace setup.
actor ReleaseCatalog {
    static let shared = ReleaseCatalog()

    private struct Cache: Codable {
        let catalog: DaemonCatalog
        let fetchedAt: Date
    }

    private let defaults: UserDefaults
    private let fetch: () async throws -> DaemonCatalog
    private let maxAge: TimeInterval
    private var cache: Cache?
    private var refresh: Task<DaemonCatalog, Error>?

    init(defaults: UserDefaults = .standard, maxAge: TimeInterval = 3600,
         fetch: @escaping () async throws -> DaemonCatalog = { try await DaemonRelease.latestCatalog() }) {
        self.defaults = defaults
        self.maxAge = maxAge
        self.fetch = fetch
        if let data = defaults.data(forKey: StorageKey.releaseCatalog),
           let saved = try? JSONDecoder().decode(Cache.self, from: data), !saved.catalog.agents.isEmpty {
            cache = saved
        }
    }

    func cached() -> DaemonCatalog? { cache?.catalog }

    func load(maxAge requestedAge: TimeInterval? = nil, allowStale: Bool = true) async throws -> DaemonCatalog {
        if let cache, Date().timeIntervalSince(cache.fetchedAt) < (requestedAge ?? maxAge) { return cache.catalog }
        do {
            if let refresh { return try await refresh.value }
            let task = Task { try await self.fetchLatest() }
            refresh = task
            defer { refresh = nil }
            return try await task.value
        } catch {
            // Pickers can use the last catalog offline. An explicit update must verify
            // the current release rather than silently report success against an old cache.
            if allowStale, let cache { return cache.catalog }
            throw error
        }
    }

    private func fetchLatest() async throws -> DaemonCatalog {
        let catalog = try await fetch()
        guard !catalog.agents.isEmpty else {
            throw BackendError.message("Couldn't load the available agents. Please try again.")
        }
        cache = Cache(catalog: catalog, fetchedAt: Date())
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: StorageKey.releaseCatalog) }
        return catalog
    }
}
