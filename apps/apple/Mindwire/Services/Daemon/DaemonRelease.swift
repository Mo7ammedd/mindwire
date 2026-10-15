import Foundation

/// Device-side access to the daemon release channel.
///
/// The Oblien **runtime-exec** path (how the app runs shell in a cloud workspace) can't do outbound
/// HTTPS — `curl https://…` there fails the TLS handshake ("wrong version number"), so the workspace
/// cannot fetch the catalog or the binary itself. The **device**, however, reaches the release host
/// fine. So the device does the HTTPS: it reads the published version here and downloads the binary,
/// which `DaemonBootstrap` then pushes into the workspace over the runtime files API (no
/// workspace→internet hop). Daemon *comms* are unaffected — those ride the runtime proxy.
enum DaemonRelease {
    enum Platform: String {
        case linux, darwin

        init?(uname: String) {
            self.init(rawValue: uname.lowercased())
        }
    }

    static func satisfies(_ version: String?, target: String) -> Bool {
        guard let version, !version.isEmpty else { return false }
        return version.compare(target, options: .numeric) != .orderedAscending
    }

    /// The latest stable Mindwire GitHub release version. `nil` = host unreachable.
    static func latestVersion(session: URLSession = .shared) async -> String? {
        guard let url = URL(string: AppConstants.mindwireReleaseAPI) else { return nil }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 15
            let (data, resp) = try await session.data(for: request)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                APILog.note("release: catalog HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            struct Release: Decodable {
                let tagName: String
                enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            return version.isEmpty ? nil : version
        } catch {
            APILog.note("release: catalog fetch failed — \(error.localizedDescription.oneLine())")
            return nil
        }
    }

    /// The release sidecar is generated from the same adapters as GET /catalog. Fetching it on
    /// the device lets a fresh workspace offer agents before a daemon or CLI has been installed.
    static func latestCatalog(session: URLSession = .shared) async throws -> DaemonCatalog {
        guard let version = await latestVersion(session: session),
              let url = URL(string: "https://github.com/\(AppConstants.mindwireRepository)/releases/download/v\(version)/catalog-v\(version).json") else {
            throw BackendError.message("Couldn't load the available agents. Please try again.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BackendError.message("Couldn't load the available agents. Please try again.")
        }
        let catalog = try JSONDecoder().decode(DaemonCatalog.self, from: data)
        guard catalog.version == version, !catalog.agents.isEmpty else {
            APILog.note("release: invalid catalog for version \(version)")
            throw BackendError.message("Couldn't load the available agents. Please try again.")
        }
        return catalog
    }

    /// Download the daemon for the workspace's OS and architecture, not the device's platform.
    /// `nil` on any failure. The device has working TLS, so this is the reliable side of the fetch.
    ///
    /// RETRIES on a dropped/partial transfer (the release host occasionally closes mid-download →
    /// `-1005` / "strict content length check" — that used to fail the whole chat load). A
    /// `URLSessionDownloadTask` streams to disk (memory-safe for the ~7 MB binary) and reports live
    /// progress via `onProgress` (0…1) so the UI can show a real bar.
    static func binary(version: String, platform: Platform, arch: String,
                       onProgress: (@Sendable (Double) -> Void)? = nil) async -> Data? {
        let asset = "mindwired-v\(version)-\(platform.rawValue)-\(arch)"
        let urlStr = "https://github.com/\(AppConstants.mindwireRepository)/releases/download/v\(version)/\(asset)"
        guard let url = URL(string: urlStr) else { return nil }
        let attempts = 4
        for attempt in 1...attempts {
            do {
                let data = try await download(url, onProgress: onProgress)
                guard !data.isEmpty else { throw URLError(.zeroByteResource) }
                APILog.note("release: downloaded \(platform.rawValue)-\(arch) binary (\(data.count)b) on device [attempt \(attempt)]")
                onProgress?(1)
                return data
            } catch {
                let httpStatus = (error as? DaemonRelease_DownloadError)?.status
                APILog.note("release: binary fetch attempt \(attempt)/\(attempts) failed — \(error.localizedDescription.oneLine())")
                if let httpStatus, !(500...599).contains(httpStatus) { return nil } // 404 etc. — not transient
                onProgress?(0)                        // reset the bar for the retry
                if attempt < attempts {
                    try? await Task.sleep(for: .seconds(Double(attempt)))   // 1s, 2s, 3s backoff
                }
            }
        }
        return nil
    }

    /// One download attempt with progress, backed by a `URLSessionDownloadTask` (disk-streamed).
    private static func download(_ url: URL, onProgress: (@Sendable (Double) -> Void)?) async throws -> Data {
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        return try await withCheckedThrowingContinuation { cont in
            delegate.completion = { cont.resume(with: $0) }
            session.downloadTask(with: req).resume()
        }
    }
}

/// Bridges a `URLSessionDownloadTask`'s progress + completion to async/await. Reads the finished
/// file synchronously in the delegate callback (the temp URL is deleted once it returns).
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (@Sendable (Double) -> Void)?
    var completion: ((Result<Data, Error>) -> Void)?

    init(onProgress: (@Sendable (Double) -> Void)?) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        onProgress?(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            completion?(.failure(DaemonRelease_DownloadError(status: http.statusCode))); completion = nil; return
        }
        do { completion?(.success(try Data(contentsOf: location))) }
        catch { completion?(.failure(error)) }
        completion = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { completion?(.failure(error)); completion = nil }   // network drop / truncation
    }
}

/// File-scope twin of DaemonRelease.DownloadError (delegate can't see the private nested type).
private struct DaemonRelease_DownloadError: Error { let status: Int? }
