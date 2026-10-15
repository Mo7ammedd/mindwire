import Foundation
import Observation

/// Review is action-scoped. Navigation shares this model; selecting paths
/// cancels stale previews and never starts a file export or service installation.
@MainActor @Observable
final class ProjectSyncFileReview {
    private(set) var preview: ProjectSyncFilePreview?
    private(set) var includeIgnored: [String] = []
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var error: String?
    private let projectId: String
    @ObservationIgnored private let makeRemote: () async throws -> ProjectSyncRemote
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(projectId: String, makeRemote: @escaping () async throws -> ProjectSyncRemote) {
        self.projectId = projectId; self.makeRemote = makeRemote
    }
    var ready: Bool { preview != nil && !loading && error == nil }
    var customPaths: [String] { includeIgnored.filter { path in !(preview?.ignored.contains { $0.path == path } ?? false) } }
    func includes(_ path: String) -> Bool { includeIgnored.contains { path == $0 || path.hasPrefix($0 + "/") } }
    func partiallyIncludes(_ path: String) -> Bool { !includes(path) && includeIgnored.contains { $0.hasPrefix(path + "/") } }

    func setIncluded(_ path: String, _ included: Bool) {
        let paths = includeIgnored.filter { $0 != path && !$0.hasPrefix(path + "/") && (included || !path.hasPrefix($0 + "/")) }
        let next = ProjectSyncSelection.normalized(included ? paths + [path] : paths)
        guard next != includeIgnored else { return }
        includeIgnored = next
        refresh(replace: true)
    }

    func refresh(replace: Bool = false) {
        if loading && !replace { return }
        task?.cancel(); generation += 1
        let expected = generation, selection = includeIgnored
        loading = true; loadingMore = false; error = nil
        task = Task {
            defer { if generation == expected { loading = false; task = nil } }
            do {
                let remote = try await makeRemote()
                let result = try await remote.preview(projectId: projectId, includeIgnored: selection, cursor: 0)
                try Task.checkCancellation()
                guard generation == expected else { return }
                guard result.version >= 2, result.selectionToken.count == 64, ProjectSyncSelection.normalized(result.includeIgnored) == selection else { throw ProjectTransferError.invalidData }
                preview = result
            } catch is CancellationError { }
            catch { if generation == expected { self.error = error.localizedDescription } }
        }
    }

    func loadMore() async {
        guard !loading, !loadingMore, let cursor = preview?.next, cursor > 0 else { return }
        let expected = generation, selection = includeIgnored
        loadingMore = true
        defer { if generation == expected { loadingMore = false } }
        do {
            let remote = try await makeRemote()
            let result = try await remote.preview(projectId: projectId, includeIgnored: selection, cursor: cursor)
            guard expected == generation else { return }
            guard result.version >= 2, ProjectSyncSelection.normalized(result.includeIgnored) == selection else { throw ProjectTransferError.invalidData }
            var seen = Set(preview?.ignored.map(\.path) ?? [])
            preview?.ignored.append(contentsOf: result.ignored.filter { seen.insert($0.path).inserted })
            preview?.next = result.next
        } catch is CancellationError { }
        catch { if generation == expected { self.error = error.localizedDescription } }
    }
}
