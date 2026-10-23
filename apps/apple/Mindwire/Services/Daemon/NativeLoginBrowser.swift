import Foundation

/// Receive a native harness's callback while in-app Safari stays in front. The
/// response travels through the existing authenticated daemon connection, so no
/// runtime needs a separate SSH connection or an exposed callback port.
@MainActor
final class NativeLoginBrowser {
    private var listener: NativeLoginCallbackListener?
    private var closed = false

    static func callback(_ url: URL) -> URL? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "redirect_uri" })?.value,
              let callback = URL(string: value), callback.scheme == "http",
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(callback.host?.lowercased() ?? ""),
              let port = callback.port, (1024...65535).contains(port),
              callback.user == nil, callback.password == nil else { return nil }
        return callback
    }

    func prepare(url: URL, callbackURL: String?, workspace: Workspace?,
                 deliver: @escaping @MainActor @Sendable (URL) async throws -> Void) async throws {
        guard let callback = Self.callback(url) else { return }
        guard !closed else { throw CancellationError() }
        if workspace?.runtime.isLocal == true, ApplePlatform.isDesktop { return }
        guard callbackURL == callback.absoluteString else {
            throw BackendError.message("Update the Mindwire service on this computer to finish browser sign-in.")
        }
        do {
            let listener = NativeLoginCallbackListener(callback: callback, deliver: deliver)
            self.listener = listener
            try await listener.open()
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        closed = true
        listener?.close(); listener = nil
    }
}
