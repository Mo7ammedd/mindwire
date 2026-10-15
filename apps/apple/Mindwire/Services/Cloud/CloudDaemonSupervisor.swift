import Foundation
import OblienKit

/// Stable, workspace-scoped ID makes registration idempotent across phones. Names alone
/// are not ownership: never replace a user's similarly named workload.
struct CloudDaemonSupervisor: DaemonSupervisor {
    static let workloadID = "mindwire-service"
    let workspaceId: String

    func ensureRunning(destination: DaemonBootstrap.Destination) async throws {
        let workloads = OblienCloud.client.workspace(workspaceId).workloads
        try await Self.ensure(destination: destination,
            get: { try await workloads.get(Self.workloadID) },
            create: { try await workloads.create($0) },
            patch: { _ = try await workloads.patch(Self.workloadID, $0) },
            start: { try await workloads.start(Self.workloadID) })
    }

    static func parameters(destination: DaemonBootstrap.Destination) -> WorkloadCreateParams {
        // Platform log defaults are bounded. Sending optional retention fields would
        // make service startup depend on a newer Oblien runtime's log-controls feature.
        .init(name: "Mindwire service", cmd: command(destination), restartPolicy: .always,
              maxRestarts: 0, workingDir: destination.directory,
              labels: ["app": "mindwire", "component": "workspace-service"],
              user: destination.user, restartDelay: 2, restartBackoff: true,
              enabled: true, id: workloadID)
    }

    static func ensure(destination: DaemonBootstrap.Destination,
                       get: () async throws -> Workload,
                       create: (WorkloadCreateParams) async throws -> Workload,
                       patch: (WorkloadCreateParams) async throws -> Void,
                       start: () async throws -> Void) async throws {
        var workload: Workload
        do { workload = try await get() }
        catch let error as OblienError where error.status == 404 {
            do { workload = try await create(parameters(destination: destination)) }
            catch {
                // A competing phone, or a lost create response, may already have registered it.
                // Reading the fixed ID proves that before allowing another lifecycle action.
                let original = error
                do { workload = try await get() }
                catch { throw original }
            }
        }
        guard owns(workload, destination: destination) else {
            throw BackendError.message("A different workload uses the Mindwire service ID. Rename that workload before setting up Mindwire.")
        }
        if workload.restartPolicy != .always || workload.enabled == false || (workload.maxRestarts ?? 0) != 0 {
            try await patch(.init(restartPolicy: .always, maxRestarts: 0,
                                  restartDelay: 2, restartBackoff: true, enabled: true))
        }
        if !isStarted(workload) {
            do { try await start() }
            catch {
                let original = error
                // Two phones can observe a stopped workload. A successful start by
                // the other phone (or a lost response) is already the desired result.
                guard let confirmed = try? await get(), owns(confirmed, destination: destination),
                      isStarted(confirmed) else { throw original }
            }
        }
    }

    private static func owns(_ workload: Workload, destination: DaemonBootstrap.Destination) -> Bool {
        workload.id == workloadID && (workload.cmd ?? workload.command) == command(destination)
    }

    private static func isStarted(_ workload: Workload) -> Bool {
        ["running", "starting", "pending", "restarting"].contains((workload.state ?? workload.status ?? "").lowercased())
    }

    private static func command(_ destination: DaemonBootstrap.Destination) -> [String] {
        ["/bin/bash", destination.directory + "/service-runner.sh"]
    }
}
