import Foundation
import Observation

/// The phone exchanges public daemon identities, then steps out of the path. Bots use their
/// own pinned SSH keys to communicate while the app is closed. Provisioning has a separate
/// connection queue and never delays history, chat streams or user registry mutations.
@MainActor @Observable
final class BotPeerCoordinator {
    private(set) var syncing = false
    private(set) var issues: [String: String] = [:]
    private(set) var configured: Set<String> = []
    private(set) var outgoingOnly: Set<String> = []
    private(set) var masterWorkspaceID: String?
    private(set) var pendingRevocations = 0
    private let stores: Stores
    private let makeRemote: (Workspace) -> WorkspaceRegistryRemote
    private static let storageKey = "mindwire.bot-peer-links.v1"
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requested: [Workspace] = []
    @ObservationIgnored private var lastInput: [Input]?
    @ObservationIgnored private var bindings: [String: Binding]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var active = true

    private struct Input: Equatable {
        let id: String
        let name: String
        let runtime: AgentRuntime
        let connection: Connection?
        let accountID: String?
        let master: Bool
    }
    private struct Binding: Codable {
        let owner: String
        let peer: String
        let registryId: String
        var ownerRegistryId: String? = nil
        var revoking: Bool
        var key: String { owner + "\u{1f}" + peer }
    }
    private struct Prepared {
        let workspace: Workspace
        let remote: WorkspaceRegistryRemote
        let endpoint: BotPeerEndpoint?
    }

    init(stores: Stores, makeRemote: @escaping (Workspace) -> WorkspaceRegistryRemote) {
        self.stores = stores
        self.makeRemote = makeRemote
        let saved = stores.defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([Binding].self, from: $0) } ?? []
        bindings = Dictionary(saved.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        pendingRevocations = saved.filter(\.revoking).count
    }

    func setActive(_ value: Bool) {
        active = value
        if value {
            // Foregrounding retries incomplete work. There is no timer or idle polling loop.
            if !issues.isEmpty || pendingRevocations > 0 { lastInput = nil }
        } else {
            generation += 1
            task?.cancel(); task = nil
            syncing = false
            lastInput = nil
        }
    }

    func schedule(_ workspaces: [Workspace], force: Bool = false) {
        requested = workspaces
        guard active else { return }
        let masters = Set(stores.bots.list().filter { $0.isMaster && !$0.archived }.map(\.workspaceId))
        let connections = Dictionary(stores.connections.list().map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let input = workspaces.sorted { $0.id < $1.id }.map {
            Input(id: $0.id, name: $0.name, runtime: $0.runtime,
                  connection: $0.runtime.serverId.flatMap { connections[$0] },
                  accountID: $0.isCloud ? MindwireAuth.shared.user?.id : nil,
                  master: masters.contains($0.id))
        }
        guard force || lastInput != input else { return }
        lastInput = input
        generation += 1
        let token = generation
        task?.cancel()
        task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await reconcile(workspaces, masters: masters, generation: token)
        }
    }

    func retry() { schedule(requested, force: true) }

    /// Persist removal before trying the network. An offline peer cannot silently keep a
    /// discarded approval forever; the revocation stays visible and retries on reconnect.
    func forget(_ workspaceId: String, remaining workspaces: [Workspace]) {
        generation += 1
        task?.cancel(); task = nil
        syncing = false
        for key in Array(bindings.keys) where bindings[key]?.owner == workspaceId || bindings[key]?.peer == workspaceId {
            bindings[key]?.revoking = true
        }
        persist()
        configured.remove(workspaceId)
        lastInput = nil
        schedule(workspaces.filter { $0.id != workspaceId }, force: true)
    }

    private func reconcile(_ workspaces: [Workspace], masters: Set<String>, generation token: Int) async {
        guard token == generation, !Task.isCancelled else { return }
        syncing = true
        defer { if token == generation { syncing = false; task = nil } }
        let ids = Set(workspaces.map(\.id))
        let sources = masters.intersection(ids)
        var desired: Set<String> = []
        for source in sources {
            for peer in ids where peer != source {
                desired.insert(source + "\u{1f}" + peer)
                desired.insert(peer + "\u{1f}" + source)
            }
        }
        for key in Array(bindings.keys) where !desired.contains(key) { bindings[key]?.revoking = true }
        persist()
        configured = []
        outgoingOnly = []
        issues = [:]
        masterWorkspaceID = BotPresentation.visibleBots(stores.bots.list().filter { ids.contains($0.workspaceId) },
            preferredAgentId: stores.experience.assistantAgentID, projectIDs: stores.experience.projectIDs)
            .first(where: \.isMaster)?.workspaceId
        let revoking = bindings.values.filter(\.revoking)
        let recoveredOwners = workspaces.filter { workspace in
            guard let identity = stores.workspaceData.identity(workspaceId: workspace.id) else { return false }
            return revoking.contains { $0.ownerRegistryId == identity }
        }.map(\.id)
        let involved = Set(desired.flatMap { $0.components(separatedBy: "\u{1f}") })
            .union(revoking.map(\.owner)).union(recoveredOwners)
        var prepared: [String: Prepared] = [:]
        // Small bounded fan-out, completely independent of workspace refresh ordering.
        await withTaskGroup(of: (String, Prepared?, String?).self) { group in
            let candidates = workspaces.filter { involved.contains($0.id) }
            for (index, workspace) in candidates.enumerated() {
                if group.isCancelled { break }
                if index >= 2, let value = await group.next() { receive(value, into: &prepared, generation: token) }
                group.addTask { @MainActor in
                    let remote = self.makeRemote(workspace)
                    do {
                        try await remote.prepare(allowInstall: false)
                        try Task.checkCancellation()
                        do {
                            let endpoint = try await remote.botPeerEndpoint()
                            if let expected = self.stores.workspaceData.identity(workspaceId: workspace.id),
                               expected != endpoint.identity.workspaceId { throw ComputerConnectionError.identityChanged }
                            try Task.checkCancellation()
                            return (workspace.id, Prepared(workspace: workspace, remote: remote, endpoint: endpoint), endpoint.routingIssue)
                        } catch {
                            return (workspace.id, Prepared(workspace: workspace, remote: remote, endpoint: nil),
                                    error.isRequestCancellation ? nil : error.localizedDescription)
                        }
                    } catch {
                        await remote.dispose()
                        return (workspace.id, nil, error.isRequestCancellation ? nil : error.localizedDescription)
                    }
                }
            }
            for await value in group { receive(value, into: &prepared, generation: token) }
        }
        defer { for value in prepared.values { Task { await value.remote.dispose() } } }
        guard token == generation, !Task.isCancelled else { return }
        for key in Array(bindings.keys).sorted() {
            guard let binding = bindings[key], binding.revoking else { continue }
            let recovered = prepared.values.first { value in
                guard let expected = binding.ownerRegistryId else { return false }
                return self.stores.workspaceData.identity(workspaceId: value.workspace.id) == expected
            }
            guard let owner = prepared[binding.owner] ?? recovered else { continue }
            do {
                try await owner.remote.revokeBotPeer(binding.registryId)
                guard token == generation, !Task.isCancelled else { return }
                bindings.removeValue(forKey: key)
                persist()
            } catch { issues[binding.owner] = error.localizedDescription }
        }
        var registered: Set<String> = []
        for key in desired.sorted() {
            guard token == generation, !Task.isCancelled else { return }
            let pair = key.components(separatedBy: "\u{1f}")
            guard pair.count == 2, let owner = prepared[pair[0]], let peer = prepared[pair[1]] else { continue }
            guard let ownerEndpoint = owner.endpoint, let peerEndpoint = peer.endpoint,
                  ownerEndpoint.identity.workspaceId != peerEndpoint.identity.workspaceId else { continue }
            do {
                if let old = bindings[key], old.registryId != peerEndpoint.identity.workspaceId {
                    try await owner.remote.revokeBotPeer(old.registryId)
                }
                let identity = peerEndpoint.identity
                try await owner.remote.registerBotPeer(identity.workspaceId, registration: .init(name: peer.workspace.name,
                    publicKey: identity.publicKey, hostKeyFingerprint: identity.hostKeyFingerprint, routes: peerEndpoint.routes))
                // Record acknowledged approvals even if navigation or an inventory refresh cancelled
                // this pass; otherwise later removal could lose track of a successfully saved grant.
                bindings[key] = .init(owner: owner.workspace.id, peer: peer.workspace.id, registryId: identity.workspaceId,
                    ownerRegistryId: ownerEndpoint.identity.workspaceId, revoking: token != generation || Task.isCancelled)
                persist()
                if token != generation || Task.isCancelled {
                    if active { schedule(requested, force: true) }
                    return
                }
                registered.insert(key)
            } catch {
                if token == generation, !error.isRequestCancellation { issues[owner.workspace.id] = error.localizedDescription }
            }
        }
        guard token == generation, !Task.isCancelled else { return }
        guard let source = masterWorkspaceID, let owner = prepared[source], let ownerEndpoint = owner.endpoint else { return }
        let candidates = ids.sorted().filter { peer in
            peer != source && registered.contains(source + "\u{1f}" + peer)
                && registered.contains(peer + "\u{1f}" + source)
                && prepared[peer]?.endpoint?.routes.isEmpty == false
        }
        // Check from the master itself, not from the phone: a phone reaching a workspace
        // does not prove that the two computers can reach each other through their firewalls.
        await withTaskGroup(of: (String, String?).self) { group in
            for (index, peer) in candidates.enumerated() {
                guard let endpoint = prepared[peer]?.endpoint else { continue }
                if index >= 2, let result = await group.next() { receiveCheck(result, generation: token) }
                group.addTask { @MainActor in
                    do {
                        let check = try await owner.remote.checkBotPeer(endpoint.identity.workspaceId)
                        guard check.workspaceId == endpoint.identity.workspaceId else { throw ComputerConnectionError.identityChanged }
                        return (peer, check.reachable ? nil : check.error ?? t("bots.connections.unreachable"))
                    } catch { return (peer, error.localizedDescription) }
                }
            }
            for await result in group { receiveCheck(result, generation: token) }
        }
        if token == generation, ownerEndpoint.routes.isEmpty, !configured.isEmpty { outgoingOnly.insert(source) }
    }

    private func receive(_ result: (String, Prepared?, String?), into prepared: inout [String: Prepared], generation token: Int) {
        if let value = result.1 { prepared[result.0] = value }
        if token == generation, let issue = result.2 { issues[result.0] = issue }
    }

    private func receiveCheck(_ result: (String, String?), generation token: Int) {
        guard token == generation, !Task.isCancelled else { return }
        if let issue = result.1 { issues[result.0] = issue }
        else { configured.insert(result.0); issues[result.0] = nil }
    }

    private func persist() {
        pendingRevocations = bindings.values.filter(\.revoking).count
        if let data = try? JSONEncoder().encode(bindings.values.sorted { $0.key < $1.key }) {
            stores.defaults.set(data, forKey: Self.storageKey)
        }
    }
}
