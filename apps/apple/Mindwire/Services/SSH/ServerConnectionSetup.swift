import Foundation

/// Verify a server before publishing its connection to the workspace list.
/// The same SSH transport handles the check, optional key installation and key verification.
enum ServerConnectionSetup {
    enum Stage {
        case checking, installingKey, verifyingKey

        var title: String {
            switch self {
            case .checking: return "Checking connection…"
            case .installingKey: return "Setting up SSH key…"
            case .verifyingKey: return "Verifying SSH key…"
            }
        }
    }

    static func resolvedDraft(_ draft: ServerDraft, saved: RemoteHostConnection? = nil) throws -> ServerDraft {
        var value = try draft.normalizedRemote()
        if value.secret.isEmpty, let saved, ServerDraft(editing: saved).authMethod == value.authMethod {
            switch saved.auth {
            case .password(let ref), .key(let ref): value.secret = Keychain.get(ref) ?? ""
            case .agent: break
            }
        }
        guard !value.secret.isEmpty else {
            throw BackendError.message(value.authMethod == .password ? "Enter the SSH password." : "Enter the SSH private key.")
        }
        if case .unavailable(let message) = SSHConnection.authentication(method: value.authMethod, secret: value.secret) {
            throw BackendError.message(message)
        }
        return value
    }

    @MainActor
    static func prepare(_ draft: ServerDraft, generateKey: Bool = false,
                        onStage: ((Stage) -> Void)? = nil) async throws -> ServerDraft {
        var verified = try resolvedDraft(draft)
        let ssh = connection(for: verified)
        defer { ssh.close() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            onStage?(.checking)
            try await check(ssh)
            if generateKey, verified.authMethod == .password {
                do {
                    onStage?(.installingKey)
                    let key = SSHKey.generate(comment: "mindwire@\(verified.username)")
                    let installed = try await ssh.exec(SSHKey.installCommand(publicLine: key.openSSHPublicLine), timeoutSeconds: 30)
                    guard installed.exitCode == 0 else {
                        throw BackendError.message("The server couldn't install the SSH key.")
                    }
                    try Task.checkCancellation()
                    onStage?(.verifyingKey)
                    verified.authMethod = .key
                    verified.secret = key.privateSeedBase64
                    let keyed = connection(for: verified)
                    defer { keyed.close() }
                    try await withTaskCancellationHandler { try await check(keyed) } onCancel: { keyed.close() }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw BackendError.message("SSH key setup failed: \(error.localizedDescription) Try again, or turn off Set up SSH key to use your password.")
                }
            }
            try Task.checkCancellation()
            return verified
        } onCancel: { ssh.close() }
    }

    private static func connection(for draft: ServerDraft) -> SSHConnection {
        SSHConnection(host: draft.host, port: Int(draft.port)!, username: draft.username,
                      auth: SSHConnection.authentication(method: draft.authMethod, secret: draft.secret))
    }

    private static func check(_ ssh: SSHConnection) async throws {
        let result = try await ssh.exec(["true"], timeoutSeconds: 15)
        guard result.exitCode == 0 else { throw BackendError.message("The server didn't allow an SSH command.") }
    }
}
