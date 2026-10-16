import Foundation

/// Owns only an on-demand temporary export, never a browser or preview cache.
struct DownloadedWorkspaceFile {
    let url: URL
    let directory: URL

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

enum WorkspaceFileDownload {
    // Keep each response below exec output limits, including base64 expansion. All backends
    // already support this binary-safe path; no daemon update or full-file allocation is needed.
    private static let chunkBytes = 512 * 1_024

    static func prepare(workspace: WorkspaceService, path: String,
                        progress: @escaping @MainActor (Int64, Int64) -> Void) async throws -> DownloadedWorkspaceFile {
        try Task.checkCancellation()
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !path.contains("\0") else {
            throw BackendError.message(t("files.download.invalidFile"))
        }
        let quoted = workspace.shell.quote(path)
        let sizeCommand = "test -f \(quoted) && wc -c < \(quoted)"
        let total = try byteCount(await workspace.exec(workspace.shell.command(sizeCommand)))
        try Task.checkCancellation()
        await progress(0, total)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mindwire-download-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let file = DownloadedWorkspaceFile(url: directory.appendingPathComponent(name), directory: directory)
        var completed = false
        defer { if !completed { file.remove() } }
        guard FileManager.default.createFile(atPath: file.url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw BackendError.message(t("files.download.cannotSave"))
        }
        let handle = try FileHandle(forWritingTo: file.url)
        defer { try? handle.close() }

        var received: Int64 = 0
        var block = 0
        while received < total {
            try Task.checkCancellation()
            // pipefail preserves a missing/unreadable file error instead of exporting an empty
            // file. Positional values are quoted through the existing workspace shell.
            let script = "set -o pipefail; dd if=\(quoted) bs=\(chunkBytes) skip=\(block) count=1 2>/dev/null | base64"
            let result = try await workspace.exec(workspace.shell.command(script))
            try Task.checkCancellation()
            try check(result)
            let encoded = result.stdout.filter { !$0.isWhitespace }
            guard let bytes = Data(base64Encoded: encoded),
                  bytes.count == Int(min(Int64(chunkBytes), total - received)) else {
                throw BackendError.message(t("files.download.incomplete"))
            }
            try handle.write(contentsOf: bytes)
            received += Int64(bytes.count)
            block += 1
            await progress(received, total)
        }
        // Never offer a truncated export when the file shrinks or grows during transfer.
        guard try byteCount(await workspace.exec(workspace.shell.command(sizeCommand))) == total else {
            throw BackendError.message(t("files.download.changed"))
        }
        try Task.checkCancellation()
        try handle.synchronize()
        completed = true
        return file
    }

    private static func byteCount(_ result: ExecResult) throws -> Int64 {
        try check(result)
        guard let size = Int64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), size >= 0 else {
            throw BackendError.message(t("files.download.invalidFile"))
        }
        return size
    }

    private static func check(_ result: ExecResult) throws {
        guard result.exitCode == 0, result.truncated != true else {
            throw BackendError.message(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? t("files.download.incomplete") : result.stderr)
        }
    }
}
