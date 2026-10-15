import Foundation

struct DaemonHTTPError: LocalizedError {
    let status: Int
    let message: String
    var code: String? = nil
    var errorDescription: String? { message }
}

/// The daemon-HTTP semantics layer: one place for JSON encode/decode, HTTP-status → success/error
/// mapping, and logging. It is transport-agnostic — the actual bytes ride a pluggable
/// `DaemonChannel` (Oblien runtime proxy for cloud, an SSH direct-tcpip tunnel for self-hosted, or
/// curl-over-exec fallback). `ExecDaemonTransport` (chat/agent control) rides this.
///
/// Durable Git mutations also use this transport; read-only Git queries use workspace exec.
struct DaemonHTTP {
    let channel: DaemonChannel
    /// The agent type this transport speaks for — appended to every call as `?agent=<type>` so the
    /// one per-workspace daemon (which hosts all adapters) routes to the right one.
    let agentType: String
    let desktopId: String?

    init(channel: DaemonChannel, agentType: String, desktopId: String? = nil) {
        self.channel = channel
        self.agentType = agentType
        self.desktopId = desktopId
    }

    func selectingDesktop(_ id: String?) -> DaemonHTTP {
        .init(channel: channel, agentType: agentType, desktopId: id)
    }

    /// Bounded typed events on the existing authenticated channel. Ending
    /// observation only closes this request; mutations have their own receipts.
    func decodedStream<Value: Decodable>(_ path: String) -> AsyncThrowingStream<Value, Error>? {
        guard let streaming = channel as? StreamingDaemonChannel else { return nil }
        let scopedPath = scoped(path)
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            let task = Task {
                do {
                    for try await data in try await streaming.stream(method: "GET", path: scopedPath, jsonBody: nil) {
                        try Task.checkCancellation()
                        let event = try JSONDecoder().decode(Value.self, from: data)
                        if case .dropped = continuation.yield(event) {
                            throw BackendError.message("Reconnect to catch up with the conversation.")
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Append the agent selector to a daemon path (the daemon hosts all adapters + routes on it).
    func scoped(_ path: String) -> String {
        var result = path
        if !agentType.isEmpty { result += "\(result.contains("?") ? "&" : "?")agent=\(encQuery(agentType))" }
        if let desktopId, path.hasPrefix("/surfaces/desktop") {
            result += "\(result.contains("?") ? "&" : "?")desktopId=\(encQuery(desktopId))"
        }
        return result
    }

    /// Run a request and decode its JSON body. `quiet` suppresses the per-call success log (used for
    /// tight poll loops like GET /setup, which would otherwise spam one line every poll).
    func decode<T: Decodable>(_ method: String, _ path: String, json: Any? = nil, quiet: Bool = false) async throws -> T {
        let body = try await run(method, path, json: json, quiet: quiet)
        guard let data = body.data(using: .utf8), !body.isEmpty else {
            throw BackendError.message("The Mindwire service returned an empty response.")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // A raw DecodingError surfaces as the opaque "data couldn't be read…". Log the actual
            // body + turn it into a clear, actionable message (usually a stale/mismatched daemon).
            APILog.note("daemon ✗ \(method) \(path): decode \(T.self) failed — \(String(body.prefix(240)).oneLine())")
            throw BackendError.message("Unexpected response from the Mindwire service (\(method) \(path)). It may be out of date.")
        }
    }

    /// Run a request, returning the response body. The channel does the transport + status
    /// extraction; here we apply the HTTP-status semantics (2xx = success, else a daemon error) and
    /// log. A thrown channel error is a genuine transport failure (no round-trip completed).
    func run(_ method: String, _ path: String, json: Any?, quiet: Bool = false, missingIsEmpty: Bool = false) async throws -> String {
        let jsonBody = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let path = scoped(path)   // route to this agent's adapter on the shared daemon
        let status: Int
        let body: String
        do {
            (status, body) = try await channel.perform(method: method, path: path, jsonBody: jsonBody)
        } catch {
            APILog.note("daemon ✗ \(method) \(path): transport [\(channel.label)] (\(error.localizedDescription.oneLine()))")
            throw error
        }
        if missingIsEmpty && (status == 404 || status == 405) { return "" }
        if !(200...299).contains(status) {
            // The daemon returns errors as {"error":...} JSON or plaintext (e.g. "unauthorized").
            let parsed = body.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            APILog.note("daemon ✗ \(method) \(path) → HTTP \(status): \(body.oneLine())")
            throw DaemonHTTPError(status: status, message: parsed?["error"] ?? (body.isEmpty ? "Mindwire service returned HTTP \(status)" : body), code: parsed?["code"])
        }
        if !quiet {
            APILog.note("daemon ✓ \(method) \(path) → \(status) (\(body.count)b) [\(channel.label)]")
        }
        return body
    }

    /// Live SSE stream of unified daemon events for `path` (scoped to this agent). Returns nil when
    /// the underlying channel can't stream (legacy curl) — the caller then falls back to polling.
    /// Channels already remove SSE framing/heartbeats. Malformed event data triggers the same
    /// recovery path as a stream disconnect, instead of silently dropping chat components.
    func stream(_ path: String) -> AsyncThrowingStream<DaemonEvent, Error>? {
        guard let streaming = channel as? StreamingDaemonChannel else { return nil }
        let scopedPath = scoped(path)
        let label = channel.label
        return AsyncThrowingStream { continuation in
            let task = Task {
                // SSE liveness diagnostic: timestamp each event as it arrives so the console reveals
                // whether the runtime proxy streams per-event or buffers. On daemon ≥0.1.13 the first
                // event is the 33ms "stream open" sentinel, so `first +Nms` is a direct proxy probe:
                // tens of ms = live; several seconds then a tight burst = the proxy buffered the SSE.
                let t0 = Date()
                var count = 0, firstMs = 0, lastMs = 0
                func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
                do {
                    let raw = try await streaming.stream(method: "GET", path: scopedPath, jsonBody: nil)
                    for try await data in raw {
                        let at = ms(); count += 1; lastMs = at
                        if count == 1 { firstMs = at; APILog.note("daemon ◦ stream \(scopedPath) [\(label)]: first event +\(at)ms") }
                        if let ev = try? JSONDecoder().decode(DaemonEvent.self, from: data) {
                            #if DEBUG
                            APILog.note("daemon ◦ [\(label)] +\(at)ms \(ev.logLine)")
                            #endif
                            continuation.yield(ev)
                        } else {
                            // Not a buffering/proxy issue — the bytes arrived but the Swift client
                            // couldn't decode them (schema drift / partial frame). Surfaced so a
                            // parse problem is never mistaken for "no stream".
                            let preview = String(data: data, encoding: .utf8)?.oneLine().prefix(120) ?? "<binary>"
                            APILog.note("daemon ◦ stream \(scopedPath): undecodable event +\(at)ms (\(preview))")
                            throw BackendError.message("The Mindwire service sent an unreadable chat update.")
                        }
                    }
                    // Verdict (needs >1 event): a big first-event delay followed by a tight burst means
                    // the proxy withheld everything then flushed at close — i.e. it does NOT stream SSE.
                    let spread = lastMs - firstMs
                    if count > 1 {
                        let verdict = (firstMs > 3000 && spread < 250)
                            ? "BUFFERED — proxy withheld \(firstMs)ms then dumped \(count) events in \(spread)ms (no live SSE)"
                            : "live — \(count) events over \(spread)ms, first +\(firstMs)ms"
                        APILog.note("daemon ◦ stream \(scopedPath) [\(label)]: \(verdict)")
                    }
                    continuation.finish()
                } catch {
                    APILog.note("daemon ✗ GET \(scopedPath): stream [\(label)] (\(error.localizedDescription.oneLine()))")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Percent-encode a path segment (IDs, file paths) for use in a URL path.
    func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    /// Percent-encode a query-parameter VALUE (encodes `&`, `=`, `+`, `?`, … that
    /// `.urlQueryAllowed` would leave intact and break the query).
    func encQuery(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
