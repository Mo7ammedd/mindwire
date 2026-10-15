import Foundation
import Observation

/// A library folder groups projects in the app. It is independent of their filesystem paths.
struct ProjectFolder: Codable, Identifiable, Equatable {
    let id: String
    var name: String
}

enum ProjectLibraryView: String, Codable, CaseIterable {
    case all, folders
    var title: String { t("projects.view.\(rawValue)") }
}

enum ProjectLibraryLayout: String, Codable, CaseIterable {
    case list, grid
    var title: String { t("projects.layout.\(rawValue)") }
}

enum ProjectLibrarySort: String, Codable, CaseIterable {
    case recent, name, custom
    var title: String { t("projects.sort.\(rawValue)") }
}

/// Cached workspace organization, shared by every app window. Local edits and their durable
/// synchronization queue are saved atomically; browsing and idle time never poll a workspace.
@MainActor @Observable
final class ProjectLibrary {
    private struct PendingPlacement: Codable, Equatable {
        let workspaceId: String
        let operationId: String
        let path: String
        let folderId: String
    }

    private struct Snapshot: Codable, Equatable {
        var folders: [ProjectFolder] = []
        var membership: [String: String] = [:]
        var order: [String] = []
        var view: ProjectLibraryView = .all
        var layout: ProjectLibraryLayout = .list
        var sort: ProjectLibrarySort = .recent
        var pending: [PendingPlacement] = []
        var replicas: [String: Replica] = [:]

        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            folders = try values.decodeIfPresent([ProjectFolder].self, forKey: .folders) ?? []
            membership = try values.decodeIfPresent([String: String].self, forKey: .membership) ?? [:]
            order = try values.decodeIfPresent([String].self, forKey: .order) ?? []
            view = try values.decodeIfPresent(ProjectLibraryView.self, forKey: .view) ?? .all
            layout = try values.decodeIfPresent(ProjectLibraryLayout.self, forKey: .layout) ?? .list
            sort = try values.decodeIfPresent(ProjectLibrarySort.self, forKey: .sort) ?? .recent
            pending = try values.decodeIfPresent([PendingPlacement].self, forKey: .pending) ?? []
            replicas = try values.decodeIfPresent([String: Replica].self, forKey: .replicas) ?? [:]
        }
    }

    private struct QueuedEdit: Codable, Equatable {
        let id: String
        var edit: ProjectLibraryEdit
    }

    private struct Replica: Codable, Equatable {
        let identity: String
        var library: DaemonProjectLibrary
        var pending: [QueuedEdit] = []
    }

    private var snapshot: Snapshot
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var knownProjects: [Project] = []
    @ObservationIgnored var syncRequested: (() -> Void)?
    private(set) var syncErrors: [String: String] = [:]
    static let storageKey = "mindwire:project-library:v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        snapshot = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
    }

    var folders: [ProjectFolder] { snapshot.folders }
    var view: ProjectLibraryView { snapshot.view }
    var layout: ProjectLibraryLayout { snapshot.layout }
    var sort: ProjectLibrarySort { snapshot.sort }

    func setView(_ view: ProjectLibraryView) { update(recordEdit: false) { $0.view = view } }
    func setLayout(_ layout: ProjectLibraryLayout) { update(recordEdit: false) { $0.layout = layout } }
    func setSort(_ sort: ProjectLibrarySort) { update(recordEdit: false) { $0.sort = sort } }
    func folder(_ id: String) -> ProjectFolder? { folders.first { $0.id == id } }

    /// All replicas keep the same place when the active workspace changes.
    func key(for project: Project) -> String {
        project.syncId.map { "sync:" + $0 } ?? "project:" + project.id
    }

    func folderId(for project: Project) -> String? {
        let id = snapshot.membership[key(for: project)]
        return id.flatMap { folder($0)?.id }
    }

    func folderId(for entry: ProjectListEntry) -> String? {
        if let project = entry.project { return folderId(for: project) }
        return snapshot.pending.first {
            $0.workspaceId == entry.workspaceId && $0.operationId == entry.operation?.id
        }?.folderId
    }

    func validName(_ name: String, excluding id: String? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.unicodeScalars.count <= 80
            && !name.contains(where: { $0 == "\0" || $0 == "\r" || $0 == "\n" }) && !folders.contains {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    @discardableResult
    func createFolder(name: String) -> ProjectFolder? {
        guard validName(name) else { return nil }
        let folder = ProjectFolder(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        update { $0.folders.append(folder) }
        return folder
    }

    func renameFolder(_ id: String, name: String) {
        guard validName(name, excluding: id), let index = folders.firstIndex(where: { $0.id == id }) else { return }
        update { $0.folders[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Only the grouping disappears. Project metadata, files, chats, and custom order stay intact.
    func deleteFolder(_ id: String) {
        update {
            $0.folders.removeAll { $0.id == id }
            $0.membership = $0.membership.filter { $0.value != id }
            $0.pending.removeAll { $0.folderId == id }
        }
    }

    @discardableResult
    func move(_ projects: [Project], to folderId: String?) -> Bool {
        guard folderId == nil || folder(folderId!) != nil else { return false }
        update { state in
            for project in projects { state.membership[key(for: project)] = folderId }
        }
        return true
    }

    /// A membership picker offers this folder's projects and unassigned projects. Moving between
    /// folders is a separate, explicit action; a stale picker cannot take another folder's project.
    func eligibleMembers(_ projects: [Project], in folderId: String) -> [Project] {
        projects.filter { project in
            let current = self.folderId(for: project)
            return current == nil || current == folderId
        }
    }

    /// Apply only this picker's scope, preserving hidden members and concurrent moves elsewhere.
    func setMembers(_ selected: Set<String>, in folderId: String, candidates: [Project]) {
        guard folder(folderId) != nil else { return }
        update { state in
            for project in candidates {
                let key = key(for: project)
                guard state.membership[key] == nil || state.membership[key] == folderId else { continue }
                if selected.contains(key) { state.membership[key] = folderId }
                else if state.membership[key] == folderId { state.membership.removeValue(forKey: key) }
            }
        }
    }

    func placeCreation(_ operation: ProjectOperation, workspaceId: String, in folderId: String, projects: [Project]) {
        guard folder(folderId) != nil, !operation.removesFiles else { return }
        if let project = projects.first(where: { $0.workspaceId == workspaceId && $0.path == operation.path }) {
            move([project], to: folderId)
        } else {
            update { state in
                state.pending.removeAll { $0.workspaceId == workspaceId && $0.operationId == operation.id }
                state.pending.append(.init(workspaceId: workspaceId, operationId: operation.id,
                                           path: operation.path, folderId: folderId))
            }
        }
    }

    /// Called when authoritative metadata arrives. Migrate a project's local identity when it
    /// gains a sync ID, and resolve accepted creations even if the daemon chose a canonical ID.
    /// Never prune missing rows: an offline workspace or signed-out account is not a deletion.
    func reconcile(projects: [Project], initializing: Bool = false) {
        let previousIDs = Set(knownProjects.map(\.id))
        knownProjects = projects
        update { state in
            for project in projects where project.syncId != nil {
                let old = "project:" + project.id
                let canonical = key(for: project)
                if let membership = state.membership.removeValue(forKey: old), state.membership[canonical] == nil {
                    state.membership[canonical] = membership
                }
                if state.order.contains(old) {
                    state.order = unique(state.order.map { $0 == old ? canonical : $0 })
                }
            }
            var remaining: [PendingPlacement] = []
            for pending in state.pending {
                guard let project = projects.first(where: {
                    $0.workspaceId == pending.workspaceId && $0.path == pending.path
                }) else { remaining.append(pending); continue }
                if state.folders.contains(where: { $0.id == pending.folderId }) {
                    state.membership[key(for: project)] = pending.folderId
                }
            }
            state.pending = remaining
            // A newly imported workspace copy has a new local ID but keeps the logical
            // project's existing group. Persist that placement on its destination daemon too.
            for project in projects where !initializing && !previousIDs.contains(project.id) {
                let key = key(for: project)
                guard let folderId = state.membership[key], snapshot.membership[key] == folderId,
                      let folder = state.folders.first(where: { $0.id == folderId }),
                      let replica = state.replicas[project.workspaceId], replica.library.membership[project.id] != folderId,
                      !replica.pending.contains(where: { $0.edit.placements.contains(where: { $0.projectId == project.id }) }) else { continue }
                var edit = ProjectLibraryEdit(placements: [.init(projectId: project.id, folderId: folderId)])
                if !replica.library.folders.contains(where: { $0.id == folderId }) { edit.folders = [folder] }
                state.replicas[project.workspaceId]?.pending.append(.init(id: UUID().uuidString, edit: edit))
            }
        }
    }

    func sorted(_ projects: [Project]) -> [Project] {
        sorted(projects.map { ProjectListEntry(workspaceId: $0.workspaceId, projectId: $0.id, project: $0) })
            .compactMap(\.project)
    }

    func sorted(_ entries: [ProjectListEntry]) -> [ProjectListEntry] {
        let ranks = Dictionary(snapshot.order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return entries.sorted { lhs, rhs in
            if sort == .custom {
                let left = lhs.project.flatMap { ranks[key(for: $0)] } ?? Int.max
                let right = rhs.project.flatMap { ranks[key(for: $0)] } ?? Int.max
                if left != right { return left < right }
            } else if sort == .name {
                let order = lhs.name.localizedStandardCompare(rhs.name)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return (lhs.date, lhs.id) > (rhs.date, rhs.id)
        }
    }

    /// Reordering one folder replaces only its slots in the global order. Other folders and
    /// temporarily unavailable projects retain their relative positions.
    func reorderProjects(_ projects: [Project], allProjects: [Project]) {
        let requested = unique(projects.map { key(for: $0) })
        guard !requested.isEmpty else { return }
        let live = unique(sorted(allProjects).map { key(for: $0) })
        update(orderingProjects: requested) { state in
            let base = state.sort == .custom ? unique(state.order + live) : unique(live + state.order)
            state.order = reordered(base: unique(base + requested), requested: requested)
            state.sort = .custom
        }
    }

    func reorderFolders(_ ids: [String]) {
        let requested = unique(ids.filter { folder($0) != nil })
        update(orderingFolders: requested) { state in
            let ordered = reordered(base: state.folders.map(\.id), requested: requested)
            let folders = Dictionary(state.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            state.folders = ordered.compactMap { folders[$0] }
        }
    }

    private func unique(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    private func reordered(base: [String], requested: [String]) -> [String] {
        let moving = Set(requested)
        var replacements = requested.makeIterator()
        return base.map { moving.contains($0) ? replacements.next()! : $0 }
    }

    var pendingWorkspaces: [String] { snapshot.replicas.keys.filter { snapshot.replicas[$0]?.pending.isEmpty == false } }
    var savedWorkspaces: [String] { Array(snapshot.replicas.keys) }
    var hasOrganization: Bool { !snapshot.folders.isEmpty || !snapshot.order.isEmpty }

    func isSaved(workspaceId: String) -> Bool { snapshot.replicas[workspaceId] != nil }

    func nextEdit(workspaceId: String) -> (id: String, edit: ProjectLibraryEdit)? {
        guard let replica = snapshot.replicas[workspaceId], let queued = replica.pending.first else { return nil }
        var edit = queued.edit
        edit.expectedRevision = replica.library.revision
        // A project removed while this device was offline cannot receive a placement.
        let ids = Set(knownProjects.filter { $0.workspaceId == workspaceId }.map(\.id))
        edit.placements.removeAll { !ids.contains($0.projectId) }
        edit.order.removeAll { !ids.contains($0) }
        return (queued.id, edit)
    }

    func recordSyncError(_ message: String?, workspaceId: String) { syncErrors[workspaceId] = message }

    func forget(workspaceId: String) {
        update(recordEdit: false) { $0.replicas[workspaceId] = nil }
        syncErrors[workspaceId] = nil
    }

    /// Merge only this workspace's changed fields, then keep any newer local intent on top.
    /// A received snapshot never becomes a new outgoing edit.
    @discardableResult
    func receive(_ remote: DaemonProjectLibrary, workspaceId: String, identity: String,
                 acknowledging id: String? = nil, rejecting: Bool = false, allowReset: Bool = false) -> Bool {
        guard remote.version == 1, remote.revision >= 0 else { return false }
        if let previous = snapshot.replicas[workspaceId], previous.identity == identity,
           remote.revision < previous.library.revision, !allowReset { return false }
        if syncErrors[workspaceId] == t("projects.library.updateRequired") { syncErrors[workspaceId] = nil }
        var removedPendingFolder = false
        update(recordEdit: false) { state in
            let previous = state.replicas[workspaceId].flatMap { $0.identity == identity ? $0 : nil }
            var replica = previous ?? Replica(identity: identity, library: .init())
            let acknowledged = replica.pending.first(where: { $0.id == id })?.edit
            // A one-time import may have lost a race with another phone's first edit.
            // In that case the server's existing library wins, including empty placements.
            let reverted = rejecting || acknowledged?.importIfEmpty == true ? acknowledged : nil
            if let id { replica.pending.removeAll { $0.id == id } }
            let old = replica.library
            let removedIDs = Set(old.folders.map(\.id)).subtracting(remote.folders.map(\.id))
            // A rename or move queued before another client deleted its folder cannot
            // bring that folder back. Other pending edits retain their original order.
            for i in replica.pending.indices {
                let before = replica.pending[i].edit
                replica.pending[i].edit.folders.removeAll { removedIDs.contains($0.id) }
                replica.pending[i].edit.placements.removeAll { $0.folderId.map(removedIDs.contains) == true }
                replica.pending[i].edit.folderOrder.removeAll { removedIDs.contains($0) }
                if before != replica.pending[i].edit { removedPendingFolder = true }
            }
            replica.pending.removeAll { $0.edit.isEmpty }
            let projects = knownProjects.filter { $0.workspaceId == workspaceId }
            if previous == nil && remote.revision == 0 {
                var migration = ProjectLibraryEdit(folders: state.folders,
                    placements: projects.compactMap { project in
                        state.membership[key(for: project)].map { .init(projectId: project.id, folderId: $0) }
                    }, order: projectOrder(state.order, projects: projects), folderOrder: state.folders.map(\.id), importIfEmpty: true)
                // Nothing to migrate in a fresh install; reading it must stay a read.
                if state.order.isEmpty { migration.order = [] }
                if !migration.isEmpty { replica.pending.append(.init(id: UUID().uuidString, edit: migration)) }
            }
            let edits = replica.pending.map(\.edit)
            let protectedFolders = Set(edits.flatMap { $0.folders.map(\.id) + $0.deleteFolders })
            let protectedProjects = Set(edits.flatMap { $0.placements.map(\.projectId) })
            replica.library = remote
            state.replicas[workspaceId] = replica

            for folder in remote.folders where !protectedFolders.contains(folder.id) {
                guard previous == nil || old.folders.first(where: { $0.id == folder.id }) != folder
                    || reverted?.folders.contains(where: { $0.id == folder.id }) == true
                    || reverted?.deleteFolders.contains(folder.id) == true else { continue }
                if let index = state.folders.firstIndex(where: { $0.id == folder.id }) { state.folders[index] = folder }
                else { state.folders.append(folder) }
            }
            let removed = Set(old.folders.map(\.id) + (reverted?.folders.map(\.id) ?? []))
                .subtracting(remote.folders.map(\.id)).subtracting(protectedFolders)
            for folderId in removed where !state.replicas.values.contains(where: {
                $0.library.folders.contains(where: { $0.id == folderId })
                    || $0.pending.contains(where: { $0.edit.folders.contains(where: { $0.id == folderId }) })
            }) {
                state.folders.removeAll { $0.id == folderId }
                state.membership = state.membership.filter { $0.value != folderId }
            }
            for project in projects where !protectedProjects.contains(project.id) {
                if previous == nil || old.membership[project.id] != remote.membership[project.id]
                    || reverted?.placements.contains(where: { $0.projectId == project.id }) == true {
                    state.membership[key(for: project)] = remote.membership[project.id]
                }
            }
            if !edits.contains(where: { !$0.order.isEmpty }), old.order != remote.order || reverted?.order.isEmpty == false {
                let keys = remote.order.compactMap { id in projects.first(where: { $0.id == id }).map { key(for: $0) } }
                state.order = reordered(base: unique(state.order + keys), requested: unique(keys))
                if previous == nil && state.sort == .recent && !keys.isEmpty { state.sort = .custom }
            }
            if !edits.contains(where: { !$0.folderOrder.isEmpty }), old.folders.map(\.id) != remote.folders.map(\.id)
                || reverted?.folderOrder.isEmpty == false {
                let ids = remote.folders.map(\.id).filter { id in state.folders.contains(where: { $0.id == id }) }
                let order = reordered(base: state.folders.map(\.id), requested: ids)
                state.folders = order.compactMap { id in state.folders.first { $0.id == id } }
            }
        }
        if removedPendingFolder { syncErrors[workspaceId] = t("projects.library.folderRemoved") }
        return true
    }

    private func projectOrder(_ keys: [String], projects: [Project]) -> [String] {
        let groups = Dictionary(grouping: projects) { key(for: $0) }
        return keys.flatMap { groups[$0, default: []].map(\.id).sorted() }
    }

    private func queueChanges(from before: Snapshot, to state: inout Snapshot,
                              orderingProjects: [String]?, orderingFolders: [String]?) {
        let folders = state.folders.filter { folder in before.folders.first { $0.id == folder.id } != folder }
        let deleted = before.folders.map(\.id).filter { id in !state.folders.contains { $0.id == id } }
        let changedKeys = Set(before.membership.keys).union(state.membership.keys).filter { before.membership[$0] != state.membership[$0] }
        for workspaceId in state.replicas.keys {
            guard let replica = state.replicas[workspaceId] else { continue }
            let projects = knownProjects.filter { $0.workspaceId == workspaceId }
            var availableFolders = Set(replica.library.folders.map(\.id))
            for queued in replica.pending {
                availableFolders.formUnion(queued.edit.folders.map(\.id))
                availableFolders.subtract(queued.edit.deleteFolders)
            }
            var edit = ProjectLibraryEdit(folders: folders.filter { folder in
                availableFolders.contains(folder.id) || !before.folders.contains(where: { $0.id == folder.id })
            }, deleteFolders: deleted,
                placements: projects.filter { changedKeys.contains(key(for: $0)) }.map { .init(projectId: $0.id, folderId: state.membership[key(for: $0)]) },
                order: before.order == state.order ? [] : projectOrder(
                    before.sort == .custom ? orderingProjects ?? state.order : state.order, projects: projects))
            for folderId in Set(edit.placements.compactMap(\.folderId)) {
                if state.replicas[workspaceId]?.library.folders.contains(where: { $0.id == folderId }) != true,
                   !edit.folders.contains(where: { $0.id == folderId }), let folder = state.folders.first(where: { $0.id == folderId }) {
                    edit.folders.append(folder)
                }
            }
            availableFolders.formUnion(edit.folders.map(\.id))
            availableFolders.subtract(edit.deleteFolders)
            if let orderingFolders, before.folders.map(\.id) != state.folders.map(\.id) {
                edit.folderOrder = orderingFolders.filter(availableFolders.contains)
            }
            if !edit.isEmpty { state.replicas[workspaceId]?.pending.append(.init(id: UUID().uuidString, edit: edit)) }
        }
    }

    private func update(recordEdit: Bool = true, orderingProjects: [String]? = nil, orderingFolders: [String]? = nil,
                        _ change: (inout Snapshot) -> Void) {
        var next = snapshot
        change(&next)
        if recordEdit { queueChanges(from: snapshot, to: &next, orderingProjects: orderingProjects, orderingFolders: orderingFolders) }
        guard next != snapshot, let data = try? JSONEncoder().encode(next) else { return }
        let addedWork = next.replicas.contains { id, replica in replica.pending.count > (snapshot.replicas[id]?.pending.count ?? 0) }
        defaults.set(data, forKey: Self.storageKey)
        snapshot = next
        if addedWork { syncRequested?() }
    }
}
