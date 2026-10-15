import Foundation
import Network
import UIKit

/// One path monitor for computer transports. Navigation doesn't trigger probes;
/// only a changed route or a return from the background invalidates old sockets.
final class ComputerNetworkMonitor: @unchecked Sendable {
    struct Path: Equatable {
        let reachable: Bool
        var interfaces: [String] = []
        var gateways: [String] = []
    }
    struct State: Equatable {
        let revision: UInt64
        let reachable: Bool
    }
    final class Observation {
        private let cancelAction: () -> Void
        init(_ cancel: @escaping () -> Void) { cancelAction = cancel }
        func cancel() { cancelAction() }
        deinit { cancel() }
    }

    static let shared = ComputerNetworkMonitor()
    private let lock = NSLock()
    private var path: Path?
    private var revision: UInt64 = 0
    private var observers: [UUID: (State) -> Void] = [:]
    private var monitor: NWPathMonitor?
    private var foregroundObserver: NSObjectProtocol?
    var state: State { lock.withLock { currentState } }
    private var currentState: State { State(revision: revision, reachable: path?.reachable ?? true) }

    init(observeSystem: Bool = true) {
        guard observeSystem else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(Path(reachable: path.status == .satisfied,
                interfaces: path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                    .map { "\($0.index):\($0.name)" }.sorted(),
                gateways: path.gateways.map { String(describing: $0) }.sorted()))
        }
        monitor.start(queue: DispatchQueue(label: "mindwire.computer.network"))
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.returnedToForeground() }
    }

    func observe(_ handler: @escaping (State) -> Void) -> Observation {
        let id = UUID()
        let initial = lock.withLock { observers[id] = handler; return currentState }
        handler(initial)
        return Observation { [weak self] in self?.lock.withLock { self?.observers.removeValue(forKey: id) } }
    }

    func update(_ next: Path) {
        let event: (State, [(State) -> Void])? = lock.withLock {
            guard path != next else { return nil }
            // The first healthy path describes the current connection; it isn't
            // a handoff. An initial offline path must still cancel an open attempt.
            if path != nil || !next.reachable { revision += 1 }
            path = next
            return (currentState, Array(observers.values))
        }
        if let event { event.1.forEach { $0(event.0) } }
    }

    func returnedToForeground() {
        let event = lock.withLock { revision += 1; return (currentState, Array(observers.values)) }
        event.1.forEach { $0(event.0) }
    }

    func waitUntilReachable() async throws {
        try Task.checkCancellation()
        if state.reachable { return }
        let stream = AsyncStream<State> { continuation in
            let observation = observe { continuation.yield($0) }
            continuation.onTermination = { _ in observation.cancel() }
        }
        for await value in stream {
            try Task.checkCancellation()
            if value.reachable && state.reachable { return }
        }
        throw CancellationError()
    }

    deinit {
        monitor?.cancel()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }
}
