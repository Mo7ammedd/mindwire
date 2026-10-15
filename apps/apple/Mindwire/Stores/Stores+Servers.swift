import Foundation

extension Stores {
    @MainActor func savedComputer(matching computer: PairedComputer) -> PairedComputer? {
        connections.list().compactMap(\.pairedComputer).first { $0.samePairing(as: computer) }
    }

    @MainActor func updateComputerDiscovery(_ descriptor: ComputerDirectoryDescriptor?, for computer: PairedComputer) {
        for connection in connections.list() {
            guard case .local(var local) = connection, var saved = local.computer,
                  saved.samePairing(as: computer), saved.discovery != descriptor else { continue }
            saved.discovery = descriptor; local.computer = saved
            connections.save(.local(local))
        }
    }
    @MainActor func computerRoutes(for computer: PairedComputer) -> [ComputerRoute] {
        connections.list().compactMap(\.pairedComputer).first {
            $0.computerId == computer.computerId && $0.fingerprint == computer.fingerprint
                && $0.registryId == computer.registryId && $0.deviceId == computer.deviceId
        }?.routes ?? computer.routes
    }

    /// Refresh the existing connection metadata without creating another connection,
    /// replacing credentials, or resurrecting a computer removed during the request.
    @MainActor func updateComputerRoutes(_ routes: [ComputerRoute], for computer: PairedComputer, policy: ComputerConnectionPolicy? = nil) {
        guard !routes.isEmpty, routes.count <= 12, routes.allSatisfy(\.isValid) else { return }
        for connection in connections.list() {
            guard case .local(var local) = connection, var saved = local.computer,
                  saved.samePairing(as: computer),
                  saved.routes != routes || policy != nil && saved.connection != policy else { continue }
            saved.routes = routes
            if let policy { saved.connection = policy }
            local.computer = saved
            connections.save(.local(local))
        }
    }

    /// One computer identity maps to one connection and workspace, including pairing retries.
    @discardableResult
    @MainActor func savePairedComputer(_ result: ComputerPairingService.Result, name: String) -> Connection {
        let previous = connections.list().compactMap { connection -> LocalConnection? in
            guard case .local(let value) = connection, value.computer?.computerId == result.computer.computerId else { return nil }
            return value
        }.first
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = LocalConnection(id: previous?.id ?? "computer-\(result.computer.computerId)",
            name: name.isEmpty ? (previous?.name ?? result.invitation?.name ?? result.host.hostname) : name,
            deviceName: result.host.hostname, pairingId: result.invitation?.pairingId ?? previous?.pairingId ?? "", computer: result.computer,
            workspace: result.host.directory, createdAt: previous?.createdAt ?? isoNow(), lastUsedAt: isoNow())
        let connection = Connection.local(saved)
        let changed = previous?.computer?.samePairing(as: result.computer) != true || previous?.computer?.routes != result.computer.routes
        if changed, let previous { portForwards.close(connectionId: previous.id) }
        connections.save(connection)
        var workspace = createWorkspace(name: saved.name, runtime: .server(serverId: saved.id))
        workspace.image = result.host.os == "darwin" ? "macos" : result.host.os
        workspaces.save(workspace)
        if changed {
            NotificationCenter.default.post(name: .computerConnectionChanged, object: nil,
                userInfo: ["computerId": result.computer.computerId])
        }
        ComputerPairingService.confirmSaved(result, stores: self)
        return connection
    }

    func workspaces(forServerId id: String) -> [Workspace] {
        workspaces.list().filter { $0.runtime.serverId == id }
    }

    /// Do all network work before saving. A failed or cancelled addition leaves no
    /// placeholder server; a failed edit keeps the original connection and credential.
    @MainActor
    func connectServer(from draft: ServerDraft, editingId: String? = nil, generateKey: Bool = false,
                       onStage: ((ServerConnectionSetup.Stage) -> Void)? = nil) async throws -> Connection {
        let original = editingId.flatMap { connections.get($0) }
        if editingId != nil, original?.remote == nil {
            throw BackendError.message("This connection was removed. Add the server again.")
        }
        let resolved = try ServerConnectionSetup.resolvedDraft(draft, saved: original?.remote)
        var verified = try await ServerConnectionSetup.prepare(resolved, generateKey: generateKey, onStage: onStage)
        try Task.checkCancellation()
        if let original {
            guard connections.get(original.id) == original else {
                throw BackendError.message("This connection changed during setup. Reopen it and try again.")
            }
            if draft.secret.isEmpty, verified.authMethod == draft.authMethod { verified.secret = "" }
            return try updateServer(original.id, from: verified)
        }
        return try saveServer(from: verified)
    }

    /// Secrets must be saved successfully before their connection becomes visible.
    @discardableResult
    func saveServer(from draft: ServerDraft) throws -> Connection {
        let draft = try ServerConnectionSetup.resolvedDraft(draft)
        let id = newId()
        let ref = KeychainKey.serverSecret(id)
        guard Keychain.set(draft.secret, for: ref) else { throw ComputerConnectionError.keyStorage }
        let connection = Connection.ssh(RemoteHostConnection(
            id: id, name: draft.name, type: .ssh, host: draft.host,
            port: Int(draft.port)!, username: draft.username,
            auth: draft.authMethod == .key ? .key(secretRef: ref) : .password(secretRef: ref),
            workspace: nil, createdAt: isoNow(), lastUsedAt: nil, defaultAgent: nil
        ))
        connections.save(connection)
        return connection
    }

    /// Edit in place so workspaces, projects and terminal destinations keep their identity.
    @MainActor
    func updateServer(_ id: String, from draft: ServerDraft) throws -> Connection {
        guard var remote = connections.get(id)?.remote else {
            throw BackendError.message("This connection was removed. Add the server again.")
        }
        let resolved = try draft.normalizedRemote()
        var replacedSecret: String?
        if !draft.secret.isEmpty {
            let credential = try ServerConnectionSetup.resolvedDraft(resolved)
            // A new reference also invalidates cached SSH authentication when
            // only the password/key changes, without putting secrets in caches.
            let ref = KeychainKey.serverSecret(id) + "." + UUID().uuidString
            guard Keychain.set(credential.secret, for: ref) else { throw ComputerConnectionError.keyStorage }
            let previous = remote.auth
            remote.auth = resolved.authMethod == .key ? .key(secretRef: ref) : .password(secretRef: ref)
            switch previous {
            case .key(let key), .password(let key): replacedSecret = key
            case .agent: break
            }
        } else if ServerDraft(editing: remote).authMethod != resolved.authMethod {
            throw BackendError.message("Enter the new credential before saving.")
        }
        remote.host = resolved.host; remote.port = Int(resolved.port)!; remote.username = resolved.username
        remote.name = resolved.name
        let connection: Connection = remote.type == .vps ? .vps(remote) : .ssh(remote)
        portForwards.close(connectionId: id)
        connections.save(connection)
        if let replacedSecret { Keychain.delete(replacedSecret) }
        return connection
    }

    func renameServer(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let conn = connections.get(id) else { return }
        let renamed: Connection
        switch conn {
        case .local(var c): c.name = trimmed; renamed = .local(c)
        case .ssh(var c): c.name = trimmed; renamed = .ssh(c)
        case .vps(var c): c.name = trimmed; renamed = .vps(c)
        }
        connections.save(renamed)
    }

    /// Deleting a server tears down the workspaces hosted on it (which in turn detaches their
    /// agents back to Oblien Cloud), then removes the connection.
    @MainActor func deleteServer(_ id: String) {
        portForwards.close(connectionId: id)
        switch connections.get(id)?.remote?.auth {
        case .key(let ref), .password(let ref): Keychain.delete(ref)
        default: break
        }
        if case .local(let local) = connections.get(id), let computer = local.computer {
            NotificationCenter.default.post(name: .computerConnectionChanged, object: nil,
                userInfo: ["computerId": computer.computerId, "removed": true])
            Keychain.delete(computer.keyRef)
            Keychain.delete(computer.tokenRef)
            Keychain.delete(computer.directoryKeyRef)
            Keychain.delete(computer.deviceIdentityReference)
            ComputerPairingService.forgetPendingPairing(for: computer.computerId)
        }
        for workspace in workspaces(forServerId: id) {
            deleteWorkspace(workspace.id)
        }
        Keychain.delete(KeychainKey.serverSecret(id))
        Keychain.delete(KeychainKey.serverKey(id))
        connections.remove(id)
    }

    /// Use the same verified setup as Add Server, preserving the saved password
    /// unless installing and authenticating with the new key both succeed.
    @MainActor
    func setUpServerKey(_ id: String) async throws {
        guard let remote = connections.get(id)?.remote else {
            throw BackendError.message("Not a remote server.")
        }
        _ = try await connectServer(from: ServerDraft(editing: remote), editingId: id, generateKey: true)
    }
}
