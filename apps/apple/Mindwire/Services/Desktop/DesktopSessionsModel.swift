import Foundation
import Observation
import OblienKit

typealias SavedWorkspaceDesktop = OblienKit.DesktopSession

struct DesktopCreationDraft: Codable, Equatable {
    var requestId = UUID().uuidString
    var name: String
    var resolution: DesktopResolution?
}

@MainActor
protocol DesktopSessionsRemote {
    func list() async throws -> DesktopSessionList
    func create(_ draft: DesktopCreationDraft) async throws -> SavedWorkspaceDesktop
    func ensureProject() async throws -> SavedWorkspaceDesktop
    func update(_ id: String, name: String, resolution: DesktopResolution?) async throws -> SavedWorkspaceDesktop
    func start(_ id: String) async throws -> SavedWorkspaceDesktop
    func stop(_ id: String) async throws -> SavedWorkspaceDesktop
    func delete(_ id: String) async throws -> SavedWorkspaceDesktop?
}

/// OblienKit lists/creates workspace desktops. Project associations and lifecycle
/// mutations use the daemon so every viewer and agent shares controller state.
@MainActor
final class CloudDesktopSessionsClient: DesktopSessionsRemote {
    let workspace: Workspace
    let projectId: String?
    private let stores: Stores
    private var api: DesktopSessionsAPI { OblienCloud.client.workspace(workspace.id).desktop.sessions }

    init(workspace: Workspace, projectId: String?, stores: Stores) {
        self.workspace = workspace; self.projectId = projectId; self.stores = stores
    }

    func list() async throws -> DesktopSessionList {
        guard let projectId else { return try await api.list() }
        return try await request("GET", "/surfaces/desktop/catalog?projectId=\(encQuery(projectId))")
    }
    func create(_ draft: DesktopCreationDraft) async throws -> SavedWorkspaceDesktop {
        guard let projectId else {
            return try await api.create(.init(name: draft.name, resolution: draft.resolution, idempotencyKey: draft.requestId)).session
        }
        var body: [String: Any] = ["requestId": draft.requestId, "projectId": projectId, "name": draft.name]
        if let size = draft.resolution { body["resolution"] = ["width": size.width, "height": size.height] }
        let result: DesktopSessionResult = try await request("POST", "/surfaces/desktop/catalog", json: body)
        return result.session
    }
    func ensureProject() async throws -> SavedWorkspaceDesktop {
        guard let projectId else { throw DesktopProblem(code: "project_required", message: "Choose a project first.") }
        let result: DesktopSessionResult = try await request("POST", "/surfaces/desktop/projects/\(encQuery(projectId))/ensure")
        return result.session
    }
    func update(_ id: String, name: String, resolution: DesktopResolution?) async throws -> SavedWorkspaceDesktop {
        var body: [String: Any] = ["name": name]
        if let resolution { body["resolution"] = ["width": resolution.width, "height": resolution.height] }
        let result: DesktopSessionResult = try await request("PATCH", path(id), json: body)
        return result.session
    }
    func start(_ id: String) async throws -> SavedWorkspaceDesktop {
        let result: DesktopSessionResult = try await request("POST", path(id) + "/start")
        return result.session
    }
    func stop(_ id: String) async throws -> SavedWorkspaceDesktop {
        let result: DesktopSessionResult = try await request("POST", path(id) + "/stop")
        return result.session
    }
    func delete(_ id: String) async throws -> SavedWorkspaceDesktop? {
        let result: DesktopSessionDeletion = try await request("DELETE", path(id))
        return result.session
    }
    private func path(_ id: String) -> String { "/surfaces/desktop/catalog/\(encQuery(id))" }
    private func encQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? value
    }
    private func request<T: Decodable>(_ method: String, _ path: String, json: Any? = nil) async throws -> T {
        let http = try await stores.workspaceData.desktopCatalogHTTP(workspace)
        let body = try await http.run(method, path, json: json, quiet: true)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(body.utf8))
    }
}

@MainActor @Observable
final class DesktopSessionsModel {
    private(set) var sessions: [SavedWorkspaceDesktop] = []
    private(set) var capabilities: DesktopSessionCapabilities?
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var busy = false
    private(set) var activeId: String?
    private(set) var loadError: String?
    var operationError: String?
    private(set) var pendingCreation: DesktopCreationDraft?
    @ObservationIgnored private let remote: any DesktopSessionsRemote
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let recoveryKey: String
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lastLoaded: Date?
    @ObservationIgnored private var mutationRevision = 0

    init(remote: any DesktopSessionsRemote, recoveryKey: String, defaults: UserDefaults = .standard) {
        self.remote = remote; self.recoveryKey = recoveryKey; self.defaults = defaults
        pendingCreation = defaults.data(forKey: recoveryKey).flatMap { try? JSONDecoder().decode(DesktopCreationDraft.self, from: $0) }
    }

    var isConsole: Bool { capabilities?.mode == "console" }
    var hasPendingSessions: Bool { sessions.contains { $0.isTransitioning } }
    var canCreate: Bool { !busy && (pendingCreation != nil || capabilities?.canCreate == true) }

    func draft(name: String) -> DesktopCreationDraft {
        pendingCreation ?? .init(name: name, resolution: isConsole ? nil : capabilities?.resolution?.default)
    }

    func refresh(force: Bool = false) async {
        if let loadTask { await loadTask.value; return }
        if !force, let lastLoaded, Date().timeIntervalSince(lastLoaded) < 10 { return }
        let revision = mutationRevision
        let task = Task { @MainActor in
            loading = true
            defer { loading = false }
            do {
                let result = try await remote.list()
                guard !Task.isCancelled else { return }
                capabilities = result.capabilities
                // A list started before a mutation must not overwrite its result.
                if revision == mutationRevision { sessions = result.sessions; lastLoaded = Date() }
                loaded = true; loadError = nil
            } catch {
                if !error.isRequestCancellation { loadError = error.localizedDescription }
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// Called only while the picker is visible and the app is active. There is
    /// no workspace-wide timer and no idle polling for running desktops.
    func observeTransitions() async {
        await refresh()
        while !Task.isCancelled, hasPendingSessions, loadError == nil {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            await refresh(force: true)
        }
    }

    func invalidate() { lastLoaded = nil; mutationRevision += 1 }

    func create(_ draft: DesktopCreationDraft) async -> SavedWorkspaceDesktop? {
        guard !busy else { return nil }
        if let pendingCreation, pendingCreation != draft {
            operationError = "Retry the pending desktop creation before creating another. Its name and size can be changed afterward."
            return nil
        }
        // Persist before sending. Reopening the sheet or app retries the same
        // key and body, including when the server accepted a lost response.
        do { defaults.set(try JSONEncoder().encode(draft), forKey: recoveryKey) }
        catch { operationError = error.localizedDescription; return nil }
        pendingCreation = draft
        return await perform {
            do {
                let value = try await self.remote.create(draft)
                self.clearPendingCreation()
                return value
            } catch {
                // A validation response confirms that nothing was created.
                // Transport/server failures retain the same key and body.
                if let error = error as? OblienError, error.kind == .validation {
                    self.clearPendingCreation()
                } else if let error = error as? DaemonHTTPError, [400, 422].contains(error.status) {
                    self.clearPendingCreation()
                }
                throw error
            }
        }
    }

    private func clearPendingCreation() {
        pendingCreation = nil
        defaults.removeObject(forKey: recoveryKey)
    }

    func ensureProject() async -> SavedWorkspaceDesktop? { await perform { try await self.remote.ensureProject() } }
    func save(_ desktop: SavedWorkspaceDesktop, name: String, resolution: DesktopResolution?) async -> SavedWorkspaceDesktop? {
        let current = sessions.first { $0.id == desktop.id } ?? desktop
        let changedSize = resolution == current.resolution ? nil : resolution
        if changedSize != nil, !current.canChangeResolution {
            operationError = "Stop this desktop before changing its resolution."
            return nil
        }
        return await perform(id: desktop.id) { try await self.remote.update(desktop.id, name: name, resolution: changedSize) }
    }
    func start(_ desktop: SavedWorkspaceDesktop) async { _ = await perform(id: desktop.id) { try await self.remote.start(desktop.id) } }
    func stop(_ desktop: SavedWorkspaceDesktop) async { _ = await perform(id: desktop.id) { try await self.remote.stop(desktop.id) } }
    func delete(_ desktop: SavedWorkspaceDesktop) async {
        guard !busy else { return }
        busy = true; activeId = desktop.id; operationError = nil; mutationRevision += 1
        defer { busy = false; activeId = nil }
        do {
            if let value = try await remote.delete(desktop.id) { upsert(value) }
            else { sessions.removeAll { $0.id == desktop.id } }
            lastLoaded = nil
        } catch { if !error.isRequestCancellation { operationError = error.localizedDescription } }
    }
    private func perform(id: String? = nil, _ work: () async throws -> SavedWorkspaceDesktop) async -> SavedWorkspaceDesktop? {
        guard !busy else { return nil }
        busy = true; activeId = id; operationError = nil; mutationRevision += 1
        defer { busy = false; activeId = nil }
        do {
            let value = try await work()
            upsert(value); lastLoaded = nil
            return value
        } catch {
            if !error.isRequestCancellation { operationError = error.localizedDescription }
            return nil
        }
    }
    private func upsert(_ value: SavedWorkspaceDesktop) {
        if let index = sessions.firstIndex(where: { $0.id == value.id }) { sessions[index] = value }
        else { sessions.append(value) }
    }
}

extension SavedWorkspaceDesktop {
    var isTransitioning: Bool { deletionPending == true || ["starting", "stopping", "deleting", "creating"].contains(state) }
    var canConnect: Bool { state != "deleting" && deletionPending != true && state != "stopping" }
    var isStopped: Bool { state == "stopped" || state == "failed" }
    var displayState: String {
        switch state {
        case "starting", "creating": "Starting"
        case "stopping": "Stopping"
        case "deleting": "Deleting"
        case "failed": "Needs attention"
        case "stopped": "Stopped"
        case "running", "ready": "Running"
        default: state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var supportsResize: Bool { canResize ?? (id != "console" && mode != "console") }
    var canChangeResolution: Bool { supportsResize && state == "stopped" }
    var supportsDelete: Bool { canDelete ?? true }
    var sizeLabel: String? { resolution.map { "\($0.width) × \($0.height)" } }
}
