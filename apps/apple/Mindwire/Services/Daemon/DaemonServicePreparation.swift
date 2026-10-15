import Foundation

enum DaemonServiceRecovery {
    /// A stopped listener can be recovered over workspace exec. Cancellation, sign-in
    /// failures and a phone with no network must never launch a recovery attempt.
    static func canStart(after error: Error) -> Bool {
        if error.isRequestCancellation { return false }
        if let response = error as? DaemonHTTPError { return [502, 503, 504].contains(response.status) }
        let network = error as NSError
        if network.domain == NSURLErrorDomain {
            return [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(network.code)
        }
        if case BackendError.unreachable = error { return true }
        return false
    }
}

/// Preparing/reconnecting can start an existing binary or perform a confirmed first install.
/// Replacement is a separate update request, checked again by the installer's idle lease.
@MainActor
enum DaemonServicePreparation {
    static func run(current: DaemonHealth, latest: String?, work: DaemonWorkState,
                    updateRequested: Bool = false,
                    startInstalled: () async throws -> Void,
                    install: (String) async throws -> Void,
                    requireIdle: (DaemonHealth) async throws -> Void,
                    health: () async -> DaemonHealth) async throws -> DaemonHealth {
        var running = current
        if !running.ok {
            work.message = t("agentAuth.stage.startingService")
            do {
                try await startInstalled()
                running = await health()
                guard running.ok else { throw BackendError.message(t("workspace.daemon.unreachable")) }
            } catch DaemonBootstrapError.notInstalled {
                guard let latest else { throw BackendError.message(t("agentAuth.stage.releaseUnreachable")) }
                work.activity = .installingDaemon
                try await install(latest)
                work.receive(.verifying)
                running = await health()
                guard running.ok, DaemonRelease.satisfies(running.version, target: latest) else {
                    throw BackendError.message(t("workspace.daemon.verifyFailed"))
                }
            }
        }

        if updateRequested {
            guard let latest else { throw BackendError.message(t("agentAuth.stage.releaseUnreachable")) }
            guard let installed = running.version else { throw BackendError.message(t("workspace.daemon.verifyFailed")) }
            if latest.compare(installed, options: .numeric) == .orderedDescending {
                try await requireIdle(running)
                work.activity = .updatingDaemon
                work.message = t("agentAuth.stage.updating")
                try await install(latest)
                work.receive(.verifying)
                running = await health()
                guard running.ok, DaemonRelease.satisfies(running.version, target: latest) else {
                    throw BackendError.message(t("workspace.daemon.verifyFailed"))
                }
            }
        }
        return running
    }
}
