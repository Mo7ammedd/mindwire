import Foundation

/// Docker owns environment existence; the phone only caches managed container
/// identities and display aliases. Project/agent/chat metadata stays in mindwired.
final class DockerWorkspaceAdapter: WorkspaceAdapter {
    typealias Inventory = (RemoteHostConnection) async throws -> [DockerWorkspaceHost.Snapshot]
    typealias Remove = (RemoteHostConnection, ServerSandbox) async throws -> Void
    private let stores: Stores
    private let inventory: Inventory
    private let remove: Remove
    private let lock = NSLock()
    private var generation = 0
    private var deleted: Set<String> = []

    init(stores: Stores, inventory: @escaping Inventory = { remote in
        let ssh = SSHConnection.make(for: remote)
        defer { ssh.close() }
        return try await DockerWorkspaceHost(ssh: ssh).list()
    }, remove: @escaping Remove = { remote, sandbox in
        let ssh = SSHConnection.make(for: remote)
        defer { ssh.close() }
        try await DockerWorkspaceHost(ssh: ssh).remove(sandbox)
    }) {
        self.stores = stores; self.inventory = inventory; self.remove = remove
    }

    func owns(_ workspace: Workspace) -> Bool { workspace.runtime.sandbox != nil }
    func current() -> [Workspace] { stores.workspaces.list().filter(owns) }
    func confirmsDeletion(_ id: String) async -> Bool { lock.withLock { deleted.contains(id) } }

    func refresh() async throws {
        let (remotes, expectedGeneration, cached) = await MainActor.run {
            (stores.connections.list().compactMap(\.remote), lock.withLock { generation }, current())
        }
        let results = await withTaskGroup(of: (RemoteHostConnection, Result<[DockerWorkspaceHost.Snapshot], Error>).self) { group in
            for remote in remotes {
                group.addTask { [inventory] in
                    do { return (remote, .success(try await inventory(remote))) }
                    catch { return (remote, .failure(error)) }
                }
            }
            var results: [(RemoteHostConnection, Result<[DockerWorkspaceHost.Snapshot], Error>)] = []
            for await result in group { results.append(result) }
            return results
        }
        try Task.checkCancellation()
        await MainActor.run {
            lock.withLock {
                // A response started before adoption/deletion cannot undo that mutation.
                guard generation == expectedGeneration else { return }
                for (remote, result) in results {
                    guard stores.connections.get(remote.id)?.remote == remote,
                          case .success(let snapshots) = result else { continue }
                    let known = current().filter { $0.runtime.serverId == remote.id }
                    let found = snapshots.compactMap { info -> Workspace? in
                        let old = known.first { $0.runtime.sandbox?.id == info.owner }
                        // A manually changed image is not evidence that the container was deleted.
                        guard let sandbox = info.sandbox ?? old?.runtime.sandbox else { return nil }
                        return Workspace(id: old?.id ?? sandbox.id,
                            name: old?.name ?? info.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? "Docker workspace",
                            runtime: .container(serverId: remote.id, sandbox: sandbox),
                            spec: .init(cpus: Int(info.nanoCPUs / 1_000_000_000), memoryMb: Int(info.memory / 1_048_576),
                                        diskMb: 0, persistent: true),
                            createdAt: info.created, lastUsedAt: old?.lastUsedAt, image: "docker")
                    }
                    let foundIDs = Set(found.map(\.id))
                    for old in known where !foundIDs.contains(old.id) {
                        stores.workspaces.remove(old.id)
                        deleted.insert(old.id)
                    }
                    for workspace in found {
                        stores.workspaces.save(workspace)
                        deleted.remove(workspace.id)
                    }
                }
            }
        }
        // Docker is optional on a Direct host. Failures only concern hosts with
        // known containers, and never turn an unreachable host into a deletion.
        for (remote, result) in results where cached.contains(where: { $0.runtime.serverId == remote.id }) {
            if case .failure(let error) = result { throw error }
        }
    }

    func adopt(name: String, runtime: AgentRuntime, spec: WorkspaceSpec?) async -> Workspace? {
        guard runtime.sandbox != nil else { return nil }
        return await MainActor.run {
            lock.withLock {
                generation &+= 1
                let workspace = stores.createWorkspace(name: name, runtime: runtime, spec: spec)
                deleted.remove(workspace.id)
                return workspace
            }
        }
    }

    func rename(_ id: String, to name: String) async {
        await MainActor.run { lock.withLock { generation &+= 1; stores.renameWorkspace(id, name: name) } }
    }

    func delete(_ id: String) async throws {
        guard let workspace = stores.workspaces.get(id),
              case .container(let serverID, let sandbox) = workspace.runtime else { return }
        guard let remote = stores.connections.get(serverID)?.remote else {
            throw BackendError.message("Reconnect this server before deleting its Docker workspace.")
        }
        lock.withLock { generation &+= 1 }
        try await remove(remote, sandbox)
        await MainActor.run {
            lock.withLock { generation &+= 1; stores.workspaces.remove(id); deleted.insert(id) }
        }
    }
}
