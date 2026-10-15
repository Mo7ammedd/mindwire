import Foundation

/// A transport channel to one workspace's Mindwire runtime (`mindwired` on `127.0.0.1:<port>`). It performs
/// a single HTTP request and returns the HTTP status + body text. The daemon-HTTP semantics
/// (success/error, decode, logging) live ONCE in `DaemonHTTP` on top of this — so adding a channel
/// (curl-over-exec, SSH tunnel, an Oblien runtime proxy later) never touches that logic.
///
/// `perform` returns `(status, body)` for ANY completed HTTP round-trip (including 4xx/5xx — the
/// caller maps those). It throws ONLY on a genuine transport failure (no round-trip: connection
/// refused, DNS, the daemon down).
protocol DaemonChannel {
    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String)
    /// Short label for logs (e.g. "curl", "ssh-tunnel").
    var label: String { get }
}

/// A channel that can also open a live **SSE** stream — one raw `data:` JSON payload (as `Data`)
/// per element, until the server closes. Cloud and SSH both use native URLSession streaming;
/// only the legacy curl-over-exec fallback requires polling.
protocol StreamingDaemonChannel: DaemonChannel {
    func stream(method: String, path: String, jsonBody: Data?) async throws -> AsyncThrowingStream<Data, Error>
}

// MARK: - curl over exec (cloud + universal fallback)

/// Talks to the daemon by exec'ing `curl http://127.0.0.1:<port>` inside the workspace. Works
/// identically on cloud and self-hosted (any `WorkspaceService.exec`). Robust to the workspace
/// runtime's quirks: the exec exit code is unreliable and newlines are stripped from captured
/// stdout, so the HTTP status is delimited by an explicit `HTTPSTATUS:` text marker, not a newline.
struct CurlExecChannel: DaemonChannel {
    let workspace: WorkspaceService
    let port: Int
    let token: String?

    var label: String { "curl" }

    init(workspace: WorkspaceService, port: Int = AppConstants.daemonPort, token: String? = nil) {
        self.workspace = workspace
        self.port = port
        self.token = token
    }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        let url = "http://127.0.0.1:\(port)\(path)"
        var cmd = "curl -sS -w 'HTTPSTATUS:%{http_code}' -X \(method) \(shq(url))"
        if let jsonBody {
            let bodyStr = String(data: jsonBody, encoding: .utf8) ?? "{}"
            cmd += " -H 'Content-Type: application/json' --data-raw \(shq(bodyStr))"
        }
        if let token, !token.isEmpty {
            cmd += " -H \(shq("Authorization: Bearer \(token)"))"
        }
        let result = try await workspace.exec(["bash", "-lc", cmd])
        let out = result.stdout

        // Split on the last `HTTPSTATUS:` marker (newline-independent — see note above).
        if let r = out.range(of: "HTTPSTATUS:", options: .backwards) {
            let statusStr = out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(out[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let status = Int(statusStr), status > 0 {
                return (status, body)
            }
        }
        // No status marker ⇒ curl couldn't complete a round-trip.
        APILog.note("daemon ✗ \(method) \(path): no-status [curl] (exit=\(result.exitCode.map(String.init) ?? "nil") bytes=\(out.count))")
        let message = !result.stderr.isEmpty ? result.stderr
            : (!out.isEmpty ? out : "Mindwire service unavailable")
        throw BackendError.message(message)
    }

    /// POSIX single-quote an interpolated value for `bash -lc`.
    private func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
