import Foundation

struct BackendHealth: Hashable {
    var ok: Bool
    var latencyMs: Int?
    var detail: String?
}

enum BackendError: LocalizedError {
    case notImplemented(String)
    case unreachable(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let s): return s
        case .unreachable(let s): return s
        case .message(let s): return s
        }
    }
}

/// The single contract the UI depends on. One implementation per adapter
/// (`CloudBackend` for Oblien Cloud, `SelfHostedBackend` for SSH servers).
protocol Backend: AnyObject {
    var runtime: AgentRuntime { get }
    var server: Connection? { get }          // nil for cloud
    var agents: AgentService { get }
    var workspace: WorkspaceService { get }
    func healthCheck() async -> BackendHealth
    func dispose() async
}
