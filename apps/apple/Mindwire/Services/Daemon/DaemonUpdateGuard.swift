import Foundation

enum DaemonUpdateError: LocalizedError, Equatable {
    case busy, unsupported

    var errorDescription: String? {
        t(self == .busy ? "workspace.daemon.busy" : "workspace.daemon.autoUpdateRequired")
    }
}

struct DaemonServiceUpdateState: Decodable, Sendable {
    let idle: Bool
    let updating: Bool
    let activeOperations: Int
    var openTerminals: Int?

    var waitingMessage: String {
        if let openTerminals, openTerminals > 0 {
            return t(openTerminals == 1 ? "workspace.daemon.waitingTerminal" : "workspace.daemon.waitingTerminals",
                     ["count": "\(openTerminals)"])
        }
        return t("workspace.daemon.updateWaiting")
    }
}

/// A durable update owned by the computer's controller. Observing or leaving a
/// screen never cancels it; only the controller may replace the idle service.
struct DaemonServiceUpdateOperation: Decodable, Sendable {
    let id: String
    let version: String
    var status: String
    var force: Bool? = nil
    var error: String?
    var updatedAt: String?
    var activity: DaemonServiceUpdateState?
    var observationError: String?

    var isActive: Bool { ["queued", "downloading", "waiting", "restarting"].contains(status) }
    var progress: DaemonInstallProgress? {
        switch status {
        case "queued": return .preparing
        case "downloading": return .downloading(nil)
        case "waiting": return force == true ? .starting : .waiting
        case "restarting": return .starting
        case "complete": return .verifying
        default: return nil
        }
    }
}

/// Accepted remotely, but not yet complete. This is pending work, never an
/// installation failure or permission to restart a busy computer.
struct DaemonUpdatePending: LocalizedError {
    let operation: DaemonServiceUpdateOperation
    var errorDescription: String? { operation.activity?.waitingMessage ?? t("workspace.daemon.updateQueued") }
}

/// Both workspace and agent entry points use this check before replacing their shared daemon.
enum DaemonUpdateGuard {
    static func requireIdle(http: DaemonHTTP, health: DaemonHealth) async throws {
        if (health.serviceUpdateVersion ?? 0) >= 1 {
            let state: DaemonServiceUpdateState = try await http.decode("GET", "/service/update", quiet: true)
            guard state.idle, !state.updating, state.activeOperations == 0 else { throw DaemonUpdateError.busy }
            return
        }
        if (health.gitAccessVersion ?? 0) >= 1 {
            let git: WorkspaceGitState = try await http.decode("GET", "/workspace/git", quiet: true)
            guard (git.activeOperations ?? 0) == 0 else { throw busy }
        }
        if (health.projectOperationsVersion ?? 0) >= 1 {
            struct Operations: Decodable { let operations: [ProjectOperation] }
            let active: Operations = try await http.decode("GET", "/workspace/operations?active=true", quiet: true)
            guard !active.operations.contains(where: \.isActive) else { throw busy }
        }
        let catalog: DaemonCatalog = try await http.decode("GET", "/catalog", quiet: true)
        for agent in catalog.agents {
            let scoped = DaemonHTTP(channel: http.channel, agentType: agent.id.rawValue)
            let chats: [DaemonChatSummary] = try await scoped.decode("GET", "/chats", quiet: true)
            guard !chats.contains(where: { $0.lastStatus == "running" }) else { throw busy }
            let setup: DaemonSetupResult = try await scoped.decode("GET", "/setup", quiet: true)
            guard setup.running != true else { throw busy }
        }
    }

    private static var busy: DaemonUpdateError { .busy }
}
