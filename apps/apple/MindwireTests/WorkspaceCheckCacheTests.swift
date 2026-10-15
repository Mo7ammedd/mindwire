import XCTest
@testable import Mindwire

@MainActor
final class WorkspaceCheckCacheTests: XCTestCase {
    func testSuccessfulControlChecksAreReusedUntilExpiryOrManualRefresh() async {
        let backend = WorkspaceControlFixture()
        var now = Date()
        let model = WorkspaceModel(backend: backend, now: { now })
        await model.load()
        await model.load()
        XCTAssertEqual(backend.healthCalls, 1)
        XCTAssertEqual(backend.statusCalls, 1)
        XCTAssertEqual(model.status?.power, .running)
        XCTAssertFalse(model.loading)

        await model.load(force: true)
        XCTAssertEqual(backend.healthCalls, 2)
        now.addTimeInterval(61)
        await model.load()
        XCTAssertEqual(backend.healthCalls, 3)
    }

    func testFailedControlCheckKeepsTheSnapshotAndManualRetryBypassesCooldown() async {
        let backend = WorkspaceControlFixture()
        let model = WorkspaceModel(backend: backend)
        await model.load()
        backend.statusError = URLError(.networkConnectionLost)
        await model.load(force: true)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.status?.power, .running)
        await model.load()
        XCTAssertEqual(backend.statusCalls, 2)
        backend.statusError = nil
        await model.load(force: true)
        XCTAssertEqual(backend.statusCalls, 3)
        XCTAssertNil(model.error)
    }

    func testPowerActionInvalidatesChecksAndAnOlderResponseCannotUndoStoppedStatus() async throws {
        let backend = WorkspaceControlFixture()
        var invalidations = 0
        let model = WorkspaceModel(backend: backend, onChange: { invalidations += 1 })
        await model.load()
        backend.holdNextStatus = true
        let old = Task { await model.load(force: true) }
        for _ in 0..<100 where backend.statusGate == nil { await Task.yield() }
        XCTAssertNotNil(backend.statusGate)
        defer { backend.releaseStatus() }
        await model.power(.stop)
        XCTAssertEqual(model.status?.power, .stopped)
        backend.releaseStatus()
        await old.value
        XCTAssertEqual(model.status?.power, .stopped)
        XCTAssertGreaterThan(invalidations, 0)
        await model.load()
        XCTAssertEqual(backend.healthCalls, 3, "Power changes invalidate the successful pre-action check")
        XCTAssertEqual(model.status?.power, .stopped)
    }

    func testOverlappingNavigationChecksShareOneRequest() async {
        let backend = WorkspaceControlFixture()
        backend.holdNextStatus = true
        let model = WorkspaceModel(backend: backend)
        let first = Task { await model.load() }
        for _ in 0..<100 where backend.statusGate == nil { await Task.yield() }
        let second = Task { await model.load() }
        await Task.yield()
        backend.releaseStatus()
        await first.value
        await second.value
        XCTAssertEqual(backend.healthCalls, 1)
        XCTAssertEqual(backend.statusCalls, 1)
    }

    func testStoppedStatusIsAvailableEvenWhenOptionalPortsCannotLoad() async {
        let backend = WorkspaceControlFixture()
        backend.currentPower = .stopped
        backend.portsError = URLError(.cannotConnectToHost)
        let model = WorkspaceModel(backend: backend)
        await model.load()
        XCTAssertTrue(model.available, "The management API can start a stopped VM")
        XCTAssertEqual(model.status?.power, .stopped)
        XCTAssertNotNil(model.error)
    }

    func testStartWaitsForActualVMAndServiceAndSurvivesNavigationCancellation() async throws {
        let backend = WorkspaceControlFixture()
        backend.currentPower = .stopped
        backend.afterPower = .starting
        var finishBoot: CheckedContinuation<Void, Never>?
        var serviceChecks = 0
        let model = WorkspaceModel(backend: backend, wait: {
            if backend.currentPower != .running {
                await withCheckedContinuation { finishBoot = $0 }
                backend.currentPower = .running
            }
        }, verifyService: {
            serviceChecks += 1
            return serviceChecks >= 3
        })
        await model.load()
        let firstView = Task { await model.power(.start) }
        for _ in 0..<200 where finishBoot == nil { await Task.yield() }
        XCTAssertNotNil(finishBoot)
        XCTAssertEqual(model.powerAction, .start)
        XCTAssertEqual(model.status?.power, .starting)
        XCTAssertEqual(serviceChecks, 0, "A starting VM should not be reported as an unavailable daemon")
        firstView.cancel() // leaving the screen cancels its waiter, not the workspace-owned action
        let secondView = Task { await model.power(.start) }
        await Task.yield()
        finishBoot?.resume(); finishBoot = nil
        await firstView.value
        await secondView.value
        XCTAssertEqual(backend.powerCalls, [.start])
        XCTAssertEqual(model.status?.power, .running)
        XCTAssertNil(model.powerAction)
        XCTAssertEqual(serviceChecks, 3, "A failed first service probe must not end recovery")
    }

    func testFailedPowerCommandDoesNotLeaveAStartingSpinnerOrStaleErrorAfterRetry() async {
        let backend = WorkspaceControlFixture()
        backend.currentPower = .stopped
        backend.powerError = URLError(.cannotConnectToHost)
        let model = WorkspaceModel(backend: backend)
        await model.load()
        await model.power(.start)
        XCTAssertEqual(model.status?.power, .stopped)
        XCTAssertNil(model.powerAction)
        XCTAssertNotNil(model.error)
        backend.powerError = nil
        await model.power(.start)
        XCTAssertEqual(model.status?.power, .running)
        XCTAssertNil(model.error)
    }
}

@MainActor
final class WorkspaceControlFixture: @preconcurrency Backend, @preconcurrency WorkspaceService, @preconcurrency AgentService {
    var runtime: AgentRuntime { .server(serverId: "control-fixture") }
    var server: Connection? { nil }
    var agents: AgentService { self }
    var workspace: WorkspaceService { self }
    var capabilities: WorkspaceCapabilities { .full }
    var healthCalls = 0
    var statusCalls = 0
    var currentPower: WorkspacePower = .running
    var statusError: Error?
    var portsError: Error?
    var powerError: Error?
    var afterPower: WorkspacePower?
    var powerCalls: [PowerAction] = []
    var holdNextStatus = false
    var statusGate: CheckedContinuation<Void, Never>?

    func healthCheck() async -> BackendHealth { healthCalls += 1; return .init(ok: true) }
    func dispose() async {}
    func status() async throws -> WorkspaceStatus {
        statusCalls += 1
        let snapshot = currentPower
        if holdNextStatus {
            holdNextStatus = false
            await withCheckedContinuation { statusGate = $0 }
        }
        if let statusError { throw statusError }
        return .init(power: snapshot)
    }
    func releaseStatus() { statusGate?.resume(); statusGate = nil }
    func power(_ action: PowerAction) async throws {
        powerCalls.append(action)
        if let powerError { throw powerError }
        currentPower = afterPower ?? (action == .stop ? .stopped : .running)
    }
    func getResources() async throws -> WorkspaceResources { .init(cpus: 2, memoryMb: 2048, diskMb: 8192) }
    func updateResources(_ patch: WorkspaceResourcePatch) async throws -> WorkspaceResources { try await getResources() }
    func listPorts() async throws -> [ExposedPort] {
        if let portsError { throw portsError }
        return []
    }
    func exposePort(_ input: ExposePortInput) async throws -> ExposedPort { throw URLError(.unsupportedURL) }
    func unexposePort(_ port: Int) async throws {}
    func listFiles(_ path: String) async throws -> [FileEntry] { [] }
    func readFile(_ path: String) async throws -> FileContent { throw URLError(.unsupportedURL) }
    func writeFile(_ path: String, content: String) async throws {}
    func deleteFile(_ path: String) async throws {}
    func exec(_ cmd: [String]) async throws -> ExecResult { throw URLError(.unsupportedURL) }
    func terminalEndpoint() async throws -> WorkspaceTerminalEndpoint { throw URLError(.unsupportedURL) }
    func listSessions() async throws -> [AgentSession] { [] }
    func getSession(_ id: String) async throws -> AgentSession? { nil }
    func startSession(_ input: StartAgentInput) async throws -> AgentSession { throw URLError(.unsupportedURL) }
    func stopSession(_ id: String) async throws {}
}
