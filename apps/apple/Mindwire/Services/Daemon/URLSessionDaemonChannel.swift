import Foundation

/// Native HTTP/SSE transport. Both requests and stream opens refresh credentials once after a 401.
actor URLSessionDaemonChannel: StreamingDaemonChannel {
    typealias RequestBuilder = @Sendable (String, String, Data?, Bool) async throws -> URLRequest

    nonisolated let label: String
    private let session: URLSession
    private let makeRequest: RequestBuilder

    init(label: String = "http", session: URLSession = .shared, makeRequest: @escaping RequestBuilder) {
        self.label = label
        self.session = session
        self.makeRequest = makeRequest
    }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        do {
            for attempt in 0..<2 {
                let request = try await makeRequest(method, path, jsonBody, attempt > 0)
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw BackendError.unreachable("invalid Mindwire HTTP response")
                }
                if http.statusCode == 401, attempt == 0 { continue }
                return (http.statusCode, String(decoding: data, as: UTF8.self))
            }
            throw BackendError.message("Mindwire authentication failed")
        } catch {
            if Task.isCancelled || error.isRequestCancellation { throw CancellationError() }
            throw BackendError.unreachable(error.localizedDescription)
        }
    }

    func stream(method: String, path: String, jsonBody: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for attempt in 0..<2 {
                        try Task.checkCancellation()
                        var request = try await makeRequest(method, path, jsonBody, attempt > 0)
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        let (bytes, response) = try await session.bytes(for: request)
                        defer { bytes.task.cancel() }
                        guard let http = response as? HTTPURLResponse else {
                            throw BackendError.unreachable("invalid Mindwire stream response")
                        }
                        if http.statusCode == 401, attempt == 0 {
                            continue
                        }
                        guard (200...299).contains(http.statusCode) else {
                            throw BackendError.message("Mindwire stream returned HTTP \(http.statusCode)")
                        }
                        guard http.mimeType == "text/event-stream" else {
                            throw BackendError.message("Mindwire returned an invalid event stream")
                        }
                        var decoder = DaemonSSEDecoder()
                        // AsyncBytes.lines omits empty lines, which are SSE's event boundaries.
                        // Read bytes so every event reaches the feed as soon as its separator arrives.
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            if let payload = try decoder.append(byte) {
                                continuation.yield(payload)
                            }
                        }
                        continuation.finish()
                        return
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Byte framing preserves LF/CRLF/CR separators, split UTF-8 sequences and multiline data fields.
/// An unfinished event at EOF is discarded; the run monitor reconnects and replays the full event.
struct DaemonSSEDecoder {
    private(set) var eventType = ""
    private var pendingType = ""
    private let maximumEventBytes: Int
    private var line: [UInt8] = []
    private var payload = Data()
    private var hasData = false
    private var previousWasCR = false
    private var firstLine = true

    init(maximumEventBytes: Int = 16 * 1024 * 1024) {
        self.maximumEventBytes = maximumEventBytes
    }

    mutating func append(_ byte: UInt8) throws -> Data? {
        if byte == 10 {
            if previousWasCR { previousWasCR = false; return nil }
            return finishLine()
        }
        previousWasCR = byte == 13
        if previousWasCR { return finishLine() }
        guard line.count + payload.count < maximumEventBytes else {
            throw BackendError.message("Mindwire event exceeds the 16 MiB stream limit")
        }
        line.append(byte)
        return nil
    }

    private mutating func finishLine() -> Data? {
        defer { line.removeAll(keepingCapacity: true) }
        if firstLine {
            firstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        if line.isEmpty {
            guard hasData else { pendingType = ""; return nil }
            let event = payload
            eventType = pendingType
            pendingType = ""
            payload = Data()
            hasData = false
            return event
        }
        if line.starts(with: Array("event:".utf8)) {
            pendingType = String(decoding: line.dropFirst(6), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return nil
        }
        guard line.starts(with: [100, 97, 116, 97]), // "data"
              line.count == 4 || line[4] == 58 else { return nil }
        var start = min(5, line.count)
        if start < line.count, line[start] == 32 { start += 1 }
        if hasData { payload.append(10) }
        payload.append(contentsOf: line[start...])
        hasData = true
        return nil
    }
}
