import Foundation

struct GitDiffPreviewKey: Hashable {
    let path: String
    let staged: Bool
}

/// One small cached excerpt per file/side. Scrolling detaches a reader without restarting its read.
@MainActor @Observable
final class GitDiffPreviewState {
    static let lineLimit = 8
    private(set) var lines: [DiffLine] = []
    private(set) var notice: String?
    private(set) var footer: String?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var hasResult = false
    @ObservationIgnored private var completed: GitDiffRequest?
    @ObservationIgnored private var requested: GitDiffRequest?
    @ObservationIgnored private var task: Task<Void, Never>?

    func load(model: GitModel, request: GitDiffRequest, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        if !force, completed == request { return }
        if requested == request, let task { await task.value; return }
        task?.cancel()
        requested = request
        isLoading = true
        error = nil
        let pending = Task {
            do {
                let result = try await DiffParser.lines(model: model, change: request.change, staged: request.staged)
                try Task.checkCancellation()
                // Keep only what the preview can display. Full files are read by the opened diff.
                lines = result.lines.prefix(Self.lineLimit).map {
                    DiffLine(id: $0.id, kind: $0.kind, oldNumber: $0.oldNumber, newNumber: $0.newNumber,
                             text: String($0.text.prefix(1024)))
                }
                notice = result.binary ? t("git.diff.binary") : result.lines.isEmpty ? t("git.diff.noChanges.body") : nil
                footer = result.truncated ? t("git.diff.truncated") : result.lines.count > Self.lineLimit
                    ? t("git.diff.moreLines", ["count": "\(result.lines.count - Self.lineLimit)"]) : nil
                hasResult = true
                completed = request
            } catch {
                if !Task.isCancelled && !error.isRequestCancellation { self.error = error.localizedDescription }
            }
            if !Task.isCancelled, requested == request {
                isLoading = false
                requested = nil
                task = nil
            }
        }
        task = pending
        await pending.value
    }

    func cancel() {
        task?.cancel()
        task = nil
        requested = nil
        isLoading = false
    }
}
