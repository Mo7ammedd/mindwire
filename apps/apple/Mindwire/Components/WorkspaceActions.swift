import SwiftUI

@MainActor @Observable
final class WorkspaceActions {
    var running = false
    var error: String?

    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !running else { return }
        running = true
        Task {
            defer { running = false }
            do { try await operation(); error = nil }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct WorkspaceCacheObserver: ViewModifier {
    @Environment(\.stores) private var stores
    let reload: () -> Void
    func body(content: Content) -> some View {
        content.onChange(of: stores.workspaceData.revision) { reload() }
    }
}

extension View {
    func observeWorkspaceCache(_ reload: @escaping () -> Void) -> some View {
        modifier(WorkspaceCacheObserver(reload: reload))
    }

    func workspaceActionAlerts(_ actions: WorkspaceActions) -> some View {
        alert(t("workspace.sync.actionFailed"), isPresented: Binding(
            get: { actions.error != nil }, set: { if !$0 { actions.error = nil } }
        )) {
            Button(t("common.ok"), role: .cancel) {}
        } message: { Text(actions.error ?? "") }
    }
}
