import Foundation

enum DaemonBootstrapError: LocalizedError {
    case notInstalled

    var errorDescription: String? { t("workspace.daemon.notInstalled") }
}

enum DaemonInstallProgress: Sendable {
    case preparing, downloading(Double?), uploading(Double?), waiting, starting, verifying

    var transferFraction: Double? {
        switch self {
        case .downloading(let value), .uploading(let value):
            guard let value, value.isFinite else { return nil }
            return min(1, max(0, value))
        case .preparing, .waiting, .starting, .verifying: return nil
        }
    }

    var phase: Int {
        switch self {
        case .preparing: return 0
        case .downloading: return 1
        case .uploading: return 2
        case .waiting: return 3
        case .starting: return 4
        case .verifying: return 5
        }
    }

    var label: String {
        switch self {
        case .preparing: return t("workspace.daemon.progress.preparing")
        case .downloading: return t("workspace.daemon.progress.downloading")
        case .uploading: return t("workspace.daemon.progress.uploading")
        case .waiting: return t("workspace.daemon.progress.waiting")
        case .starting: return t("workspace.daemon.progress.starting")
        case .verifying: return t("workspace.daemon.progress.verifying")
        }
    }

    var fraction: Double {
        transferFraction ?? 0
    }

    var message: String {
        switch self {
        case .preparing: return t("agentAuth.stage.preparingService")
        case .downloading: return t("agentAuth.stage.installing")
        case .uploading: return t("agentAuth.stage.uploadingService")
        case .waiting: return t("workspace.daemon.progress.waiting")
        case .starting: return t("agentAuth.stage.startingService")
        case .verifying: return t("agentAuth.stage.verifyingService")
        }
    }
}

/// How a daemon binary gets INTO a workspace and launched. One interface, one impl per backend
/// family — resolved by `BackendFactory.daemonInstaller(forBackend:)`, exactly like the daemon
/// transport. `DaemonSession` calls `install(...)` and never branches on backend type.
protocol DaemonInstaller {
    /// A managed computer accepts a durable request before its final replacement lease.
    var queuesUpdates: Bool { get }
    func updateOperation() async throws -> DaemonServiceUpdateOperation?
    /// Install `target` (download if needed) and launch it, replacing any running instance.
    /// Progress identifies the actual transfer/start phase and measured transfer fraction.
    func install(agentType: String, cwd: String, target: String, daemonToken: String,
                 requireUpdateLease: Bool, force: Bool,
                 onProgress: (@Sendable (DaemonInstallProgress) -> Void)?) async throws
    func startInstalled(daemonToken: String) async throws
    func configureStartup(daemonToken: String) async throws
}

extension DaemonInstaller {
    var queuesUpdates: Bool { false }
    func updateOperation() async throws -> DaemonServiceUpdateOperation? { nil }
    func install(agentType: String, cwd: String, target: String, daemonToken: String,
                 requireUpdateLease: Bool = false,
                 onProgress: (@Sendable (DaemonInstallProgress) -> Void)?) async throws {
        try await install(agentType: agentType, cwd: cwd, target: target, daemonToken: daemonToken,
                          requireUpdateLease: requireUpdateLease, force: false, onProgress: onProgress)
    }
    func startInstalled(daemonToken: String) async throws { throw BackendError.notImplemented("Service start is unavailable") }
    func configureStartup(daemonToken: String) async throws {}
}

/// Oblien Cloud: the runtime-exec path can't do outbound HTTPS, so the DEVICE downloads the binary
/// and it's pushed in over the runtime files API, then launched by a local (no-network) exec.
struct UploadDaemonInstaller: DaemonInstaller {
    let workspace: WorkspaceService
    func configureStartup(daemonToken: String) async throws {
        try await DaemonBootstrap.configureStartup(workspace: workspace, daemonToken: daemonToken)
    }
    func startInstalled(daemonToken: String) async throws {
        try await DaemonBootstrap.startInstalled(workspace: workspace, daemonToken: daemonToken)
    }
    func install(agentType: String, cwd: String, target: String, daemonToken: String,
                 requireUpdateLease: Bool, force: Bool,
                 onProgress: (@Sendable (DaemonInstallProgress) -> Void)?) async throws {
        try await DaemonBootstrap.installViaUpload(workspace: workspace, agentType: agentType, cwd: cwd,
                                                   target: target, daemonToken: daemonToken,
                                                   requireUpdateLease: requireUpdateLease, force: force, onProgress: onProgress)
    }
}

/// Self-hosted (SSH to a real box): normal TLS, so the workspace `curl`s the binary from the release
/// host directly over the exec/SSH seam. The native SSH stream carries curl's measured progress.
struct ExecDaemonInstaller: DaemonInstaller {
    let workspace: WorkspaceService
    func configureStartup(daemonToken: String) async throws {
        try await DaemonBootstrap.configureStartup(workspace: workspace, daemonToken: daemonToken)
    }
    func startInstalled(daemonToken: String) async throws {
        try await DaemonBootstrap.startInstalled(workspace: workspace, daemonToken: daemonToken)
    }
    func install(agentType: String, cwd: String, target: String, daemonToken: String,
                 requireUpdateLease: Bool, force: Bool,
                 onProgress: (@Sendable (DaemonInstallProgress) -> Void)?) async throws {
        try await DaemonBootstrap.installViaExec(workspace: workspace, agentType: agentType, cwd: cwd,
            target: target, daemonToken: daemonToken, requireUpdateLease: requireUpdateLease, force: force,
            onProgress: onProgress)
    }
}
