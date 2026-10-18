import Foundation

struct AppActivityContext: Equatable {
    let active: Bool
    let accountID: String?
}

/// Windows have independent navigation, but share one foreground synchronization loop.
/// Opening another iPad window must not duplicate service checks or notification subscriptions.
@MainActor
final class AppLifecycle {
    private let prepareWork: () async -> Void
    private let activeWork: () async -> Void
    private let activeChanged: (Bool) -> Void
    private var context: AppActivityContext?
    private var preparation: Task<Void, Never>?
    private var prepared = false
    private var activity: Task<Void, Never>?

    init(prepare: @escaping () async -> Void, whileActive: @escaping () async -> Void,
         activeChanged: @escaping (Bool) -> Void = { _ in }) {
        prepareWork = prepare
        activeWork = whileActive
        self.activeChanged = activeChanged
    }

    convenience init(stores: Stores) {
        self.init(prepare: {
            // A cold notification needs workspace metadata before resolving its chat.
            await MindwireAuth.shared.refresh()
            // Register the phone independently of slow or unreachable workspaces.
            async let push: Void = BackendFactory.pushService().start()
            await WorkspaceRepository.shared.refreshIfNeeded()
            await stores.workspaceData.refreshAll(WorkspaceRepository.shared.all)
            await push
        }, whileActive: {
            await BackendFactory.pushService().start()
            guard !Task.isCancelled else { return }
            await DaemonManager.shared.reconcileNotifications()
            var ticks = 0
            while !Task.isCancelled {
                WorkspaceRepository.shared.computerRecovery.synchronize()
                if ticks % 12 == 0 { await WorkspaceRepository.shared.refreshIfNeeded() }
                async let releaseCheck = stores.serviceUpdates.refreshRelease()
                await stores.workspaceData.refreshAll(WorkspaceRepository.shared.all)
                _ = await releaseCheck
                guard !Task.isCancelled else { return }
                if ticks == 0 { stores.preparation.resume(); stores.projectSync.resumePending() }
                stores.serviceUpdates.reconcile(WorkspaceRepository.shared.all)
                stores.gitAuthors.reconcile(WorkspaceRepository.shared.all)
                ticks += 1
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }, activeChanged: { active in
            stores.portForwards.setActive(active)
            stores.workspaceData.botConnections.setActive(active)
            BackendFactory.pushService().setActive(active)
            WorkspaceRepository.shared.computerRecovery.setActive(active)
            if active { Task { await stores.connectionSync.foreground() } }
        })
    }

    func prepare() async {
        if prepared { return }
        if let preparation { await preparation.value; return }
        let job = Task { await prepareWork() }
        preparation = job
        await job.value
        prepared = true
        preparation = nil
    }

    func update(_ next: AppActivityContext) {
        guard context != next else { return }
        context = next
        activity?.cancel()
        activity = nil
        activeChanged(next.active)
        guard next.active else { return }
        activity = Task {
            await prepare()
            guard !Task.isCancelled else { return }
            await activeWork()
        }
    }
}
