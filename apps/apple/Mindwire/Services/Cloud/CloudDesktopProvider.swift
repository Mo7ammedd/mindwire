import Foundation
import OblienKit

struct DesktopLoginCredentials: Decodable {
    let username: String
    let password: String
}

/// Oblien owns capability, enablement and expiring desktop-only SSH grants.
/// The account's session JWT stays in the app; only scoped grants reach Mindwire.
@MainActor
final class CloudDesktopProvider {
    let workspaceId: String
    let desktopId: String?
    private var runtime: RuntimeClient?
    private var runtimeTask: Task<RuntimeClient, Error>?
    private var grant: DesktopSSHGrant?

    init(workspaceId: String, desktopId: String? = nil) { self.workspaceId = workspaceId; self.desktopId = desktopId }

    func gatewayToken(force: Bool = false) async throws -> String {
        let runtime = try await runtimeClient()
        if force { await runtime.invalidate() }
        return try await runtime.token()
    }

    func status() async throws -> DesktopProviderStatus {
        let value = try await perform { try await runtimeClient().desktop.status(sessionId: desktopId) }
        return .init(supported: value.supported, enabled: value.enabled, available: value.available, credentials: value.credentials)
    }
    func credentials() async throws -> DesktopLoginCredentials {
        let value = try await perform { try await runtimeClient().desktop.credentials() }
        guard !value.username.isEmpty, value.username.count <= 255, value.password.utf8.count <= 2048 else {
            throw DesktopProblem(code: "login_unavailable", message: "This workspace did not provide desktop sign-in details.")
        }
        return .init(username: value.username, password: value.password)
    }
    func enable() async throws { _ = try await perform { try await runtimeClient().desktop.enable() } }
    func disable() async throws {
        _ = try await perform { try await runtimeClient().desktop.disable() }
        grant = nil
    }

    /// Match the provider's browser: prepare only its declared Mac desktop
    /// runtime, preserving an existing session, explicit lock or another user.
    func prepareSession() async throws {
        let runtime = try await runtimeClient()
        let token = try await runtime.token()
        let catalog = try await perform { try await DesktopRuntimeCatalog(runtime.runtimes()) }
        guard let target = catalog.desktopTarget(token: token), target.runtime.os == "darwin" else { return }
        let credentials = try await credentials()
        let input = try JSONSerialization.data(withJSONObject: ["username": credentials.username, "password": credentials.password])
        let native = CloudDesktopNativeInput(runtime: runtime)
        let output = try await native.run(target: target.id, command: ["/usr/bin/perl", "-e", DesktopSessionPreparation.script], input: input)
        struct Result: Decodable { let ready: Bool }
        guard try JSONDecoder().decode(Result.self, from: output).ready else {
            throw DesktopProblem(code: "login_unavailable", message: "The Mac session is still starting.")
        }
    }

    func connection() async throws -> DesktopSSHGrant {
        if let grant, (grant.expiresAt?.timeIntervalSinceNow ?? 0) > 300 { return grant }
        let value = try await perform { try await OblienCloud.client.workspace(workspaceId).desktop.sshConnection(sessionId: desktopId) }
        let result = DesktopSSHGrant(expires_at: value.expiresAt,
            ssh: .init(host: value.ssh.host, port: value.ssh.port, username: value.ssh.username,
                       password: value.ssh.password, host_key_fingerprint: value.ssh.hostKeyFingerprint),
            vnc: .init(host: value.vnc.host, port: value.vnc.port, authentication: value.vnc.authentication), session_id: value.sessionId)
        try result.validate(workspaceId: workspaceId, desktopId: desktopId)
        grant = result
        return result
    }

    func prepareSavedDesktop(resuming: Bool) async throws {
        guard let desktopId else { return }
        let api = OblienCloud.client.workspace(workspaceId).desktop
        var saved = try await api.getSession(desktopId).session
        if saved.state == "stopped" || saved.state == "failed" {
            guard !resuming else { throw DesktopProblem(code: "desktop_stopped", message: "This desktop was stopped. Connect to start it again.") }
            saved = try await api.startSession(desktopId).session
        }
        let deadline = Date().addingTimeInterval(45)
        while !saved.available {
            try Task.checkCancellation()
            guard saved.state != "deleting" else { throw DesktopProblem(code: "desktop_deleted", message: "This desktop is being deleted. Choose another desktop.") }
            guard Date() < deadline else { throw DesktopProblem(code: "preparing", message: "This desktop is still starting. Its apps and profile are saved; try connecting again.") }
            try await Task.sleep(for: .milliseconds(500))
            saved = try await api.getSession(desktopId).session
        }
    }

    private func perform<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw Self.problem(for: error)
        }
    }

    static func problem(for error: Error) -> DesktopProblem {
        if let problem = error as? DesktopProblem { return problem }
        switch (error as? OblienError)?.status {
        case 404:
            return .init(code: "unsupported", message: "This workspace image does not provide desktop access.")
        case 401, 403:
            return .init(code: "authorization", message: "Refresh the workspace authorization and try again.")
        case 409:
            return .init(code: "desktop_conflict", message: "This desktop is busy or the session limit was reached. Refresh its status.")
        default:
            return .init(code: "unavailable", message: "The workspace display is unavailable. Check that the workspace is running and try again.")
        }
    }

    private func runtimeClient() async throws -> RuntimeClient {
        if let runtime { return runtime }
        if let runtimeTask { return try await runtimeTask.value }
        let handle = OblienCloud.client.workspace(workspaceId)
        let task = Task {
            guard try await handle.runtimeAccess.status().enabled == true else {
                throw DesktopProblem(code: "runtime_disabled", message: "Set up the Mindwire service in this workspace before connecting to its desktop.")
            }
            return try await handle.runtime(enableIfNeeded: false)
        }
        runtimeTask = task
        defer { runtimeTask = nil }
        let result = try await task.value
        runtime = result
        return result
    }
}

struct DesktopRuntimeCatalog: Decodable {
    struct Target: Decodable {
        struct Runtime: Decodable { let os: String }
        let id: String
        let runtime: Runtime
    }
    let default_target: String
    let targets: [Target]
    init(_ catalog: OblienKit.RuntimeCatalog) {
        default_target = catalog.defaultTarget
        targets = catalog.targets.map { .init(id: $0.id, runtime: .init(os: $0.runtime.os)) }
    }
    func desktopTarget(token: String) -> Target? {
        var selected = default_target
        let parts = token.split(separator: ".")
        if parts.count == 3 {
            var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            if let data = Data(base64Encoded: encoded), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let declared = claims["desktop_runtime"] as? String, !declared.isEmpty { selected = declared }
        }
        guard selected.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil else { return nil }
        return targets.first { $0.id == selected }
    }
}
