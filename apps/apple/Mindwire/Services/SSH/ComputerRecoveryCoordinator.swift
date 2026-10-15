import Foundation
import Observation

/// Event-driven recovery for saved computers. Successful checks stay cached;
/// navigation never starts probes. Only failed connections use a bounded backoff.
@MainActor @Observable
final class ComputerRecoveryCoordinator {
    enum State: Equatable {
        case connecting, waiting, offline, paused
        case needsAttention(String)

        var message: String {
            switch self {
            case .connecting: "Reconnecting…"
            case .waiting: "Will retry automatically"
            case .offline: "Waiting for internet"
            case .paused: "Automatic retry paused"
            case .needsAttention(let message): message
            }
        }
    }
    private(set) var states: [String: State] = [:]
    @ObservationIgnored private let connections: () -> [Connection]
    @ObservationIgnored private let attempt: (String) async throws -> Void
    @ObservationIgnored private let cancelAttempt: (String) -> Void
    @ObservationIgnored private let network: ComputerNetworkMonitor
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var observation: ComputerNetworkMonitor.Observation?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var jobs: [String: (id: UUID, running: Bool, task: Task<Void, Never>)] = [:]
    private(set) var healthy: Set<String> = []
    @ObservationIgnored private var paused: Set<String> = []
    @ObservationIgnored private var blocked: Set<String> = []
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private var active = false
    @ObservationIgnored private var path: ComputerNetworkMonitor.State

    init(network: ComputerNetworkMonitor = .shared,
         connections: @escaping () -> [Connection],
         attempt: @escaping (String) async throws -> Void,
         cancelAttempt: @escaping (String) -> Void,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.network = network; self.path = network.state
        self.connections = connections; self.attempt = attempt; self.cancelAttempt = cancelAttempt; self.sleep = sleep
        observation = network.observe { [weak self] state in Task { @MainActor in self?.pathChanged(state) } }
        notifications.append(NotificationCenter.default.addObserver(forName: .computerTransportFailed, object: nil, queue: .main) { [weak self] event in
            let computer = event.userInfo?["computer"] as? PairedComputer
            let error = event.userInfo?["error"] as? Error ?? ComputerConnectionError.unreachable
            Task { @MainActor in
                guard let self, let computer,
                      let connection = self.connections().first(where: { $0.pairedComputer?.samePairing(as: computer) == true }) else { return }
                self.failed(connection.id, error: error)
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .computerTransportRecovered, object: nil, queue: .main) { [weak self] event in
            let computer = event.userInfo?["computer"] as? PairedComputer
            Task { @MainActor in
                guard let self, let computer,
                      let connection = self.connections().first(where: { $0.pairedComputer?.samePairing(as: computer) == true }) else { return }
                self.succeeded(connection.id)
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .computerConnectionChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.synchronize() }
        })
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if value {
            paused.removeAll()
            healthy.removeAll() // A foreground is a genuine lifecycle event.
            path = network.state
            synchronize()
        } else {
            for id in Array(jobs.keys) { cancelJob(id) }
            for id in states.keys where !blocked.contains(id) { states[id] = nil }
        }
    }

    /// Called by the existing app reconcile loop. No work for unchanged healthy
    /// connections, and deleting a computer cancels all delayed/in-flight work.
    func synchronize() {
        let computers = connections().filter { $0.pairedComputer != nil }
        let ids = Set(computers.map(\.id))
        for id in Set(states.keys).union(jobs.keys).union(healthy).subtracting(ids) { forget(id) }
        for connection in computers where connection.pairedComputer?.needsDeviceApproval == true {
            cancelJob(connection.id)
            healthy.remove(connection.id)
            blocked.insert(connection.id)
            states[connection.id] = .needsAttention("Approve this device on your computer to connect.")
        }
        guard active else { return }
        for id in ids where !healthy.contains(id) && !paused.contains(id) && !blocked.contains(id) {
            schedule(id, after: .zero)
        }
    }

    func manualRetry(_ id: String) {
        paused.remove(id); blocked.remove(id); failures[id] = nil; healthy.remove(id)
        // A manual request joins an in-flight attempt and bypasses only a delay.
        if jobs[id]?.running == false { cancelJob(id) }
        states[id] = nil
    }

    func pause(_ id: String) {
        paused.insert(id); healthy.remove(id)
        cancelJob(id)
        states[id] = .paused
    }

    func forget(_ id: String) {
        cancelJob(id)
        healthy.remove(id); paused.remove(id); blocked.remove(id)
        failures[id] = nil; states[id] = nil
    }

    func succeeded(_ id: String) {
        healthy.insert(id); blocked.remove(id); failures[id] = nil; states[id] = nil
        if jobs[id]?.running == false { cancelJob(id) }
    }

    func failed(_ id: String, error: Error) {
        guard !(error is CancellationError), connections().contains(where: { $0.id == id && $0.pairedComputer != nil }) else { return }
        healthy.remove(id)
        guard jobs[id] == nil else { return } // This shared attempt reports its own outcome.
        if !Self.canRetry(error) {
            blocked.insert(id); states[id] = .needsAttention(error.localizedDescription)
            return
        }
        guard active, !paused.contains(id), !blocked.contains(id) else { return }
        failures[id, default: 0] += 1
        schedule(id, after: Self.retryDelay(failures[id, default: 1]))
    }

    static func retryDelay(_ failures: Int) -> Duration {
        .seconds(min(60, 1 << min(6, max(0, failures - 1))))
    }
    static func canRetry(_ error: Error) -> Bool {
        if let error = error as? ComputerConnectionError { return error.canRetryConnection }
        if error is SSHIdentityError || error is SSHAuthenticationError { return false }
        if let error = error as? DaemonHTTPError, error.status == 401 || error.status == 403 { return false }
        return !(error is CancellationError)
    }

    private func pathChanged(_ next: ComputerNetworkMonitor.State) {
        guard path != next else { return }
        path = next
        guard active else { return }
        for id in Array(jobs.keys) { cancelJob(id) }
        healthy.removeAll()
        synchronize()
    }

    private func schedule(_ id: String, ticket: UUID = UUID(), after delay: Duration) {
        guard active, jobs[id] == nil, !paused.contains(id), !blocked.contains(id),
              connections().contains(where: { $0.id == id && $0.pairedComputer != nil }) else { return }
        guard path.reachable else { states[id] = .offline; return }
        states[id] = delay == .zero ? .connecting : .waiting
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if delay > .zero { try await sleep(delay) }
                try Task.checkCancellation()
                guard active, jobs[id]?.id == ticket, path.reachable else { return }
                jobs[id]?.running = true
                states[id] = .connecting
                try await attempt(id)
                try Task.checkCancellation()
                guard jobs[id]?.id == ticket else { return }
                jobs[id] = nil
                succeeded(id)
            } catch {
                guard jobs[id]?.id == ticket else { return }
                jobs[id] = nil
                if error is CancellationError { states[id] = nil; return }
                failed(id, error: error)
            }
        }
        jobs[id] = (ticket, false, task)
    }

    private func cancelJob(_ id: String) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.task.cancel()
        if job.running { cancelAttempt(id) }
    }

    deinit {
        observation?.cancel()
        notifications.forEach(NotificationCenter.default.removeObserver)
        jobs.values.forEach { $0.task.cancel() }
    }
}
