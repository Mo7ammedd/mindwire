import Foundation

/// The computer's CLI owns its service process and verified release download. Never
/// upload a binary or run a Unix bootstrap script through the service being updated.
struct ComputerDaemonInstaller: DaemonInstaller {
    let channel: DaemonChannel
    var poll: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    var pollLimit = 180
    let queuesUpdates = true

    func updateOperation() async throws -> DaemonServiceUpdateOperation? {
        let http = DaemonHTTP(channel: channel, agentType: "")
        var update: DaemonServiceUpdateOperation = try await http.decode("GET", "/computer/update", quiet: true)
        if update.status == "idle" { return nil }
        if update.status == "waiting" {
            update.activity = try? await http.decode("GET", "/service/update", quiet: true)
            if let terminals: [DaemonTerminalState] = try? await http.decode("GET", "/workspace/terminals", quiet: true) {
                update.activity?.openTerminals = terminals.filter(\.running).count
            }
        }
        return update
    }

    func startInstalled(daemonToken: String) async throws {
        let health: DaemonHealth = try await DaemonHTTP(channel: channel, agentType: "").decode("GET", "/healthz", quiet: true)
        guard health.ok else { throw ComputerConnectionError.unreachable }
    }
    func install(agentType: String, cwd: String, target: String, daemonToken: String,
                 requireUpdateLease: Bool, force: Bool, onProgress: (@Sendable (DaemonInstallProgress) -> Void)?) async throws {
        let http = DaemonHTTP(channel: channel, agentType: "")
        onProgress?(.preparing)
        let version = target.hasPrefix("v") ? String(target.dropFirst()) : target
        // Resume the controller's existing request, including after an app restart.
        // A second tap must never reset a download or discard its failure details.
        let existing = try await updateOperation()
        let request: DaemonServiceUpdateOperation
        if let existing, existing.isActive, !force || existing.force == true { request = existing }
        else {
            // Promote the same queued automatic request. The controller retains its
            // download and operation ID; it never launches a second updater.
            request = try await http.decode("POST", "/computer/update", json: [
                "version": existing?.isActive == true ? existing!.version : version, "force": force
            ], quiet: true)
        }
        var last = request
        var closedLegacyTerminals = false
        var legacyWaits = 0
        for _ in 0..<pollLimit {
            try Task.checkCancellation()
            // A service restart briefly drops SSH. The next poll reopens the same pinned identity.
            let observed: DaemonServiceUpdateOperation?
            do { observed = try await updateOperation() }
            catch is CancellationError { throw CancellationError() }
            catch let error as DaemonHTTPError where (400..<500).contains(error.status) { throw error }
            catch {
                last.observationError = error.localizedDescription
                try await poll()
                continue
            }
            guard let update = observed else {
                throw BackendError.message(t("workspace.daemon.updateRequestMissing"))
            }
            last = update
            if let progress = update.progress { onProgress?(progress) }
            if update.status == "failed" {
                throw BackendError.message(update.error ?? t("workspace.daemon.updateFailed"))
            }
            if update.status == "complete" {
                if !DaemonRelease.satisfies(update.version, target: version) {
                    // An earlier request finished first; the newer target still needs its own update.
                    return try await install(agentType: agentType, cwd: cwd, target: version, daemonToken: daemonToken,
                        requireUpdateLease: requireUpdateLease, force: force, onProgress: onProgress)
                }
                return
            }
            guard update.isActive else { throw BackendError.message(t("workspace.daemon.updateStatusUnknown")) }
            if update.status == "waiting", !force { throw DaemonUpdatePending(operation: update) }
            if update.status == "waiting", force, update.force != true {
                // Older published controllers already support closing their own PTYs.
                // Do this only for an explicit update, after its download is ready.
                // An ordinary Terminal.app shell is never enumerated or terminated.
                if !closedLegacyTerminals {
                    let terminals: [DaemonTerminalState] = try await http.decode("GET", "/workspace/terminals", quiet: true)
                    for terminal in terminals where terminal.running {
                        _ = try await http.run("DELETE", "/workspace/terminals/\(terminal.id)", json: nil, quiet: true)
                    }
                    closedLegacyTerminals = true
                }
                legacyWaits += 1
                if legacyWaits > 5, (update.activity?.activeOperations ?? 0) > 0, update.activity?.updating != true {
                    throw BackendError.message(t("workspace.daemon.legacyRestart"))
                }
            }
            try await poll()
        }
        // The request remains durable on the computer. Foreground reconciliation
        // resumes observation instead of calling a long download a failed update.
        throw DaemonUpdatePending(operation: last)
    }
}
