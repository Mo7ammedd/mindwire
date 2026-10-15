import Foundation
import Observation
import SwiftUI

/// One statistics subscription per visible workspace. Screens share ownership, so a
/// list-to-detail transition cannot open competing streams or leave one in the background.
@Observable @MainActor
final class WorkspaceWorkloadActivity {
    private(set) var metrics: [String: WorkspaceWorkloadMetrics] = [:]
    private(set) var connected = false
    private(set) var error: String?
    @ObservationIgnored private let service: WorkspaceManagementService
    @ObservationIgnored private var observers: Set<UUID> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var disposed = false

    init(service: WorkspaceManagementService) { self.service = service }

    func value(for id: String) -> WorkspaceWorkloadMetrics? { connected ? metrics[id] : nil }

    func observe(_ id: UUID, active: Bool) {
        guard !disposed else { return }
        if active {
            let inserted = observers.insert(id).inserted
            if inserted { start() }
        } else {
            observers.remove(id)
            if observers.isEmpty { stop() }
        }
    }

    func reconnect() { stop(); start() }
    func dispose() { disposed = true; observers.removeAll(); stop() }

    private func start() {
        guard !disposed, task == nil, !observers.isEmpty else { return }
        let token = UUID(); generation = token
        error = nil; connected = false
        task = Task { @MainActor in
            defer { if token == generation { connected = false; task = nil } }
            do {
                for try await values in service.workloadStatsStream() {
                    try Task.checkCancellation()
                    guard token == generation else { return }
                    metrics = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                    connected = true
                }
                if !Task.isCancelled, token == generation { error = "Live metrics disconnected. Refresh to reconnect." }
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                self.error = WorkspaceControlError.describe(error)
            }
        }
    }

    private func stop() {
        generation = UUID(); task?.cancel(); task = nil; connected = false
    }
}

private struct WorkspaceWorkloadObservation: ViewModifier {
    let activity: WorkspaceWorkloadActivity
    let enabled: Bool
    @State private var observer = UUID()
    @State private var visible = false
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; update() }
            .onDisappear { visible = false; update() }
            .onChange(of: phase) { _, _ in update() }
            .onChange(of: enabled) { _, _ in update() }
    }
    private func update() { activity.observe(observer, active: enabled && visible && phase != .background) }
}

extension View {
    func workloadActivity(_ activity: WorkspaceWorkloadActivity, enabled: Bool = true) -> some View {
        modifier(WorkspaceWorkloadObservation(activity: activity, enabled: enabled))
    }
}
