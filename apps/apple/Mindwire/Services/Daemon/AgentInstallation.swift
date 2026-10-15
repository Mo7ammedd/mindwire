import Foundation

/// Uses the service's shared /setup job for every harness. A successful job is only ready once
/// /agent confirms that its executable can actually be found in the workspace.
@MainActor
enum AgentInstallation {
    @discardableResult
    static func ensure(transport: AgentTransport, work: DaemonWorkState,
                       initial: DaemonSetupResult? = nil, retryFailed: Bool = false) async throws -> DaemonAgentInfo {
        let existing: DaemonSetupResult
        if let initial { existing = initial } else { existing = try await transport.setupStatus() }
        if existing.running == true {
            try await waitForCompletion(transport: transport, initial: existing, work: work)
        } else if retryFailed, existing.started == true, !existing.ok {
            // Only an explicit Retry restarts a failed native job. Successful checks and opening
            // a page must never replay it; the daemon owns the new job and its progress.
            try requireManagedInstaller(try await transport.agentInfo())
            let started = try await transport.setup()
            try await waitForCompletion(transport: transport, initial: started, work: work)
        } else {
            let info = try await transport.agentInfo()
            let installed = !info.installedVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if installed && info.software?.needsSetup != true {
                work.installedVersion = info.installedVersion
                work.requiresVerification = false
                return info
            }
            if installed {
                // New dependencies must not obstruct history/Stop for a turn already in flight.
                let chats = try await transport.listChats()
                if chats.contains(where: { $0.lastStatus == "running" }) { return info }
                if existing.started == true, !existing.ok {
                    // A failed repair follows the same explicit Retry flow as a failed install.
                    try await waitForCompletion(transport: transport, initial: existing, work: work)
                }
            }
            work.installedVersion = installed ? info.installedVersion : nil
            try requireManagedInstaller(info)
            work.activity = .installingTools
            work.message = t("agentAuth.stage.toolchain")
            let started = try await transport.setup()
            try await waitForCompletion(transport: transport, initial: started, work: work)
        }

        work.message = t("agentUpdates.verifying")
        let info = try await transport.agentInfo()
        guard !info.installedVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackendError.message(t("agentUpdates.verifyFailed"))
        }
        if let missing = info.software?.missingDependencies, !missing.isEmpty {
            throw BackendError.message(t("agentUpdates.dependenciesMissing", ["tools": missing.joined(separator: ", ")]))
        }
        work.installedVersion = info.installedVersion
        work.requiresVerification = false
        work.message = nil
        return info
    }

    /// Old services still allow existing CLIs to run, but a new install must not use their
    /// unrestricted latest-version path. Updating the service enables the managed policy.
    static func requireManagedInstaller(_ info: DaemonAgentInfo) throws {
        guard info.software?.supportsUpdates == true else {
            throw BackendError.message(t("agentUpdates.policyRequired"))
        }
    }

    /// Short requests keep proxy connections responsive; the remote job outlives its observers.
    static func waitForCompletion(transport: AgentTransport, initial: DaemonSetupResult,
                                  work: DaemonWorkState) async throws {
        var status = initial
        // The daemon bounds setup at 20 minutes. A client must not declare it failed halfway
        // through that native window; short individual reads still detect connectivity loss.
        let deadline = ContinuousClock.now.advanced(by: .seconds(21 * 60))
        while ContinuousClock.now < deadline {
            work.receive(status)
            work.running = true // The coordinator settles this after validation, including fast jobs.
            if status.running != true {
                guard status.ok else {
                    let detail = status.steps.first { $0.status == "failed" }?.output?.oneLine() ?? ""
                    throw BackendError.message(t("agentAuth.stage.setupFailed") + (detail.isEmpty ? "" : "\n\n\(detail)"))
                }
                return
            }
            try await Task.sleep(for: .milliseconds(1_500))
            status = try await transport.setupStatus()
        }
        throw BackendError.message(t("agentUpdates.setupTimeout"))
    }
}
