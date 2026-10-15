import XCTest
import SwiftUI
import OblienKit
@testable import Mindwire

@MainActor
final class WorkspaceManagementTests: XCTestCase {
    func testSuccessfulReadsAreCachedAndManualRefreshRetainsValuesOnFailure() async {
        var now = Date()
        let state = WorkspaceControlValue<Int>(now: { now })
        var reads = 0
        let read = { @MainActor in reads += 1; return reads }
        await state.load(read: read)
        await state.load(read: read)
        XCTAssertEqual(reads, 1)
        now.addTimeInterval(301)
        await state.load(read: read)
        XCTAssertEqual(state.value, 2)
        await state.load(force: true) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(state.value, 2)
        XCTAssertNotNil(state.error)
        await state.load(force: true, read: read)
        XCTAssertEqual(state.value, 3)
        XCTAssertNil(state.error)
    }

    func testInvalidationDuringJoinedReadCannotRestoreAnOldValue() async {
        let state = WorkspaceControlValue<Int>()
        let gate = WorkspaceControlsGate()
        let first = Task { await state.load { await gate.wait(); return 1 } }
        await eventually { gate.waiting }
        state.invalidate()
        let second = Task { await state.load(force: true) { 2 } }
        await Task.yield()
        gate.release()
        await first.value; await second.value
        XCTAssertEqual(state.value, 2)
    }

    func testDisposingAnInFlightReadCannotRestartIt() async {
        let state = WorkspaceControlValue<Int>()
        let gate = WorkspaceControlsGate()
        var reads = 0
        let first = Task { await state.load { reads += 1; await gate.wait(); return 1 } }
        await eventually { gate.waiting }
        let second = Task { await state.load(force: true) { reads += 1; return 2 } }
        await Task.yield()
        state.cancel()
        gate.release()
        await first.value; await second.value
        XCTAssertEqual(reads, 1)
        XCTAssertNil(state.value)
        XCTAssertFalse(state.loading)
    }

    func testDuplicateWorkspaceActionsJoinAndConflictingActionsCannotRun() async {
        let service = WorkspaceControlsService()
        let gate = WorkspaceControlsGate()
        service.gate = gate
        let model = WorkspaceManagementModel(service: service)
        defer { model.dispose() }
        let first = Task { await model.execute(.sshAccess(true), title: "Enabling") }
        await eventually { gate.waiting }
        var duplicateStarted = false
        let duplicate = Task { duplicateStarted = true; return await model.execute(.sshAccess(true), title: "Enabling") }
        await eventually { duplicateStarted }
        let conflicting = await model.execute(.sshAccess(false), title: "Disabling")
        XCTAssertNil(conflicting)
        XCTAssertEqual(service.commands.count, 1)
        gate.release()
        let result = await first.value
        let joined = await duplicate.value
        XCTAssertNotNil(result); XCTAssertNotNil(joined)
        XCTAssertEqual(service.commands.count, 1)
        XCTAssertFalse(model.isBusy)
    }

    func testUncertainDiskActionRetainsItsKeyUntilAcknowledged() async {
        let service = WorkspaceControlsService()
        let model = WorkspaceManagementModel(service: service)
        defer { model.dispose() }
        let action = WorkspaceDiskAction(kind: .create, name: "Files", sizeMb: 1024, format: "ext4")
        service.failNextCommand = true
        let failed = await model.diskAction(action)
        XCTAssertFalse(failed)
        let retry = await model.diskAction(action)
        XCTAssertTrue(retry)
        let next = await model.diskAction(action)
        XCTAssertTrue(next)
        let keys = service.commands.compactMap { command -> String? in
            if case .disk(_, let key) = command { return key }; return nil
        }
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(keys[0], keys[1])
        XCTAssertNotEqual(keys[1], keys[2])
    }

    func testOpeningStorageResumesServerOwnedOperationAndRefreshesWhenDone() async {
        let service = WorkspaceControlsService()
        let gate = WorkspaceControlsGate()
        service.pendingOperation = true
        let model = WorkspaceManagementModel(service: service, wait: { await gate.wait() })
        defer { model.dispose() }
        await model.refresh(.disks)
        XCTAssertTrue(model.isBusy)
        await eventually { gate.waiting }
        service.pendingOperation = false
        gate.release()
        await eventually { !model.isBusy && model.disks.value?.operationId == nil }
        XCTAssertEqual(model.operations["operation"]?.state, "done")
        XCTAssertGreaterThanOrEqual(service.diskReads, 2)
    }

    func testCatalogSelectionKeepsPresetMinimumsDefaultsAndStableCreationKey() throws {
        let model = NewWorkspaceModel()
        model.name = "My Mac"
        model.images = [try catalogImage(id: "macos", cpus: 2, memory: 11264),
                        try catalogImage(id: "macos-xcode", cpus: 8, memory: 24576, preset: "macos-xcode")]
        model.selectedImageID = "macos"
        XCTAssertEqual(model.minimumMemoryGb, 11)
        model.selectedImageID = "macos-xcode"
        XCTAssertEqual(model.customCPUs, 8)
        XCTAssertEqual(model.customMemoryGb, 24)
        let first = try model.cloudOptions()
        let request = first.request(name: model.name, spec: model.spec)
        XCTAssertEqual(request.preset, "macos-xcode")
        XCTAssertEqual(request.image, "oblien/macos:26")
        XCTAssertEqual(request.config?.macos?.agent, "native")
        XCTAssertEqual(request.waitReady, false, "The workspace should be visible as soon as creation is accepted")
        XCTAssertEqual(first.idempotencyKey, try model.cloudOptions().idempotencyKey)
        model.customMemoryGb = 25
        XCTAssertNotEqual(first.idempotencyKey, try model.cloudOptions().idempotencyKey)
    }

    func testRetainedRootAndAdditionalDiskReachCreationWithoutOverwritingBootDefinition() throws {
        let model = NewWorkspaceModel()
        model.images = [try catalogImage(id: "macos", cpus: 2, memory: 11264)]
        model.selectedImageID = "macos"
        let root = disk(id: "root", namespace: "team", kind: "root", format: nil,
                        permissions: ["create_workspace": true], image: "oblien/macos:26")
        model.selectRoot(root)
        model.storage.attachments = [.init(disk: disk(id: "data", namespace: "team", format: "raw"), target: "macos")]
        let request = try model.cloudOptions().request(name: "Project", spec: model.spec)
        XCTAssertEqual(request.namespace, "team")
        XCTAssertEqual(request.config?.rootDiskId, "root")
        XCTAssertNil(request.image)
        XCTAssertNil(request.config?.macos)
        XCTAssertNil(request.config?.diskSizeMb)
        XCTAssertEqual(request.config?.disks?.first?.target, "macos")
        XCTAssertEqual(request.config?.disks?.first?.diskId, "data")
    }

    func testCreationProgressUsesDurableStateBeforeRuntimeHealth() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let pending = try decoder.decode(OblienKit.Workspace.self, from: Data(#"{"id":"workspace","status":"stopped","ready":false,"provisioning":{"state":"running","phase":"booting","stage":"preparing_image"}}"#.utf8))
        let creating = WorkspaceStatus(cloud: pending)
        XCTAssertEqual(creating.power, .starting)
        XCTAssertEqual(creating.provisioning?.stage, "preparing_image")
        let failed = try decoder.decode(OblienKit.Workspace.self, from: Data(#"{"id":"workspace","status":"failed","provisioning":{"state":"failed","error":{"message":"Image download failed","code":"IMAGE_FAILED"}}}"#.utf8))
        let status = WorkspaceStatus(cloud: failed)
        XCTAssertEqual(status.power, .stopped)
        XCTAssertTrue(status.provisioning?.isFailed == true)
        XCTAssertEqual(status.provisioning?.error, "Image download failed")
        let restored = try JSONDecoder().decode(WorkspaceStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(restored, status)
    }

    func testStoragePermissionsNamespaceImageAndRuntimeAreRequired() throws {
        let image = try catalogImage(id: "macos", cpus: 2, memory: 11264)
        let storage = WorkspaceCreationStorage()
        storage.namespace = "team"
        storage.attachments = [.init(disk: disk(id: "data", namespace: "team", format: "raw"), target: "missing")]
        XCTAssertNotNil(storage.validation(image: image))
        storage.attachments[0].target = "macos"
        XCTAssertNil(storage.validation(image: image))
        storage.namespace = "another"
        XCTAssertNotNil(storage.validation(image: image))
        XCTAssertFalse(disk(id: "missing-permission", permissions: [:]).canAttachToNewWorkspace(image: image.image, namespace: nil))
        let layer = disk(id: "layer", kind: "root", format: nil, image: "different", immutable: true)
        XCTAssertFalse(layer.canAttachToNewWorkspace(image: image.image, namespace: nil))
        XCTAssertFalse(layer.canCreateWorkspace)
    }

    func testMoveDestinationsRequireColdStoppedCompatibleWorkspace() {
        var disk = disk(id: "data", namespace: "team", permissions: ["move": true])
        disk.attachments = [.init(workspaceId: "source")]
        var destination = WorkspaceControlsService.info
        destination.namespace = "team"
        XCTAssertTrue(disk.canMove(to: destination, from: "source"))
        destination.info?.status = "suspended"
        XCTAssertFalse(disk.canMove(to: destination, from: "source"))
        destination.info?.status = "stopped"
        destination.namespace = "other"
        XCTAssertFalse(disk.canMove(to: destination, from: "source"))
    }

    func testDesktopErrorsKeepNativeRecoveryCodesAndHideGatewayDetails() {
        let unsupported = OblienError(kind: .notFound, status: 404, code: nil, message: nil, details: nil)
        XCTAssertEqual(CloudDesktopProvider.problem(for: unsupported).code, "unsupported")
        let failure = OblienError(kind: .transport, status: 503, code: nil, message: "dial tcp 127.0.0.1 secret", details: nil)
        let message = CloudDesktopProvider.problem(for: failure)
        XCTAssertEqual(message.code, "unavailable")
        XCTAssertFalse(message.message.contains("127.0.0.1"))
    }

    func testWorkloadViewsShareOneStreamAndIgnoreClosedStreamEvents() async {
        let service = WorkspaceControlsService()
        let activity = WorkspaceWorkloadActivity(service: service)
        defer { activity.dispose() }
        let list = UUID(), detail = UUID()
        activity.observe(list, active: true)
        activity.observe(detail, active: true)
        activity.observe(list, active: true)
        await eventually { service.metricsFeed.opened == 1 }
        service.metricsFeed.send([.init(id: "process", state: "running", cpuPercent: 0, memoryBytes: 1024)])
        await eventually { activity.connected }
        XCTAssertEqual(activity.value(for: "process")?.cpuLabel, "0%")
        activity.observe(list, active: false)
        XCTAssertTrue(activity.connected)
        activity.observe(detail, active: false)
        XCTAssertNil(activity.value(for: "process"), "A closed stream must not present its measurements as live")
        await eventually { service.metricsFeed.closed == 1 }
        activity.observe(detail, active: true)
        await eventually { service.metricsFeed.opened == 2 }
        service.metricsFeed.send([.init(id: "process", state: "stopped")])
        await eventually { activity.value(for: "process")?.state == "stopped" }
        activity.observe(detail, active: false)
        await eventually { service.metricsFeed.closed == 2 }
    }

    func testNativeWorkspaceControlsSnapshots() async throws {
        let suite = "workspace-controls-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let repository = WorkspaceRepository(stores: stores, adapters: [])
        let model = WorkspaceManagementModel(service: WorkspaceControlsService())
        defer { model.dispose() }
        model.network.replace(.init(ip: "10.0.0.8", allowInternet: true, publicAccess: false,
                                    ingressPorts: [3000, 8080], egress: ["*"], outboundMode: "managed", privateLinks: []))
        try await snapshot(WorkspaceNetworkScreen(model: model, workspaceId: "workspace", repository: repository), name: "workspace-controls-network")
        model.workloads.replace([
            .init(id: "web", name: "Preview server", state: "running", command: ["npm", "run", "dev"], restartPolicy: "always"),
            .init(id: "build", name: "Build", state: "stopped", command: ["npm", "run", "build"], exitCode: 0)
        ])
        try await snapshot(WorkspaceWorkloadsScreen(model: model), name: "workspace-controls-workloads")
        let draft = NewWorkspaceModel()
        draft.images = [try catalogImage(id: "macos", cpus: 2, memory: 11264)]
        draft.selectedImageID = "macos"
        draft.storage.namespaces.replace([.init(id: "team", name: "Team")])
        draft.storage.disks.replace([])
        try await snapshot(WorkspaceCreationStorageScreen(model: draft), name: "workspace-controls-creation-storage")
    }

    private func snapshot<V: View>(_ content: V, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: NavigationStack { content }.preferredColorScheme(.dark))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(450))
        let image = ChatFeedSnapshot.image(host)
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
        try image.pngData()?.write(to: url)
        print("WORKSPACE_CONTROL_SNAPSHOT_PATH=\(url.path)")
    }

    private func eventually(_ check: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if check() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected asynchronous state was not reached", file: file, line: line)
    }

    private func catalogImage(id: String, cpus: Int, memory: Int, preset: String? = nil) throws -> WorkspaceImage {
        var fields: [String: Any] = ["id": id, "image": "oblien/macos:26", "label": id,
            "minimum_resources": ["cpus": cpus, "memory_mb": memory, "disk_size_mb": 8192],
            "vm_defaults": ["macos": ["agent": "native"]],
            "disk_targets": [["id": "macos", "label": "macOS", "formats": ["raw"]]]]
        if let preset { fields["preset"] = preset }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(OblienKit.Image.self, from: JSONSerialization.data(withJSONObject: fields))
        return try XCTUnwrap(WorkspaceImage(catalogImage: value))
    }

    private func disk(id: String, namespace: String? = nil, kind: String = "data", format: String? = "ext4",
                      permissions: [String: Bool] = ["attach": true], image: String? = nil, immutable: Bool = false) -> WorkspaceManagedDisk {
        .init(id: id, name: id, namespace: namespace, state: "ready", kind: kind, format: format, sizeMb: 16384,
              immutable: immutable, rootImage: image, permissions: permissions)
    }
}

@MainActor private final class WorkspaceControlsGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var released = false
    var waiting: Bool { !continuations.isEmpty }
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        let waiting = continuations; continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

@MainActor private final class WorkspaceControlsService: WorkspaceManagementService {
    nonisolated let features = Set(WorkspaceManagementFeature.allCases)
    nonisolated let metricsFeed = WorkspaceMetricsTestFeed()
    static let info = ManagedWorkspace(id: "workspace", name: "Development", image: "oblien/ubuntu:24.04", info: .init(status: "stopped", isRunning: false))
    var commands: [WorkspaceManagementCommand] = []
    var gate: WorkspaceControlsGate?
    var failNextCommand = false
    var pendingOperation = false
    var diskReads = 0
    func workspace() async throws -> ManagedWorkspace { Self.info }
    func workspaces() async throws -> [ManagedWorkspace] { [Self.info] }
    func disks() async throws -> WorkspaceDiskList { diskReads += 1; return .init(disks: [], operationId: pendingOperation ? "operation" : nil) }
    func allDisks() async throws -> [WorkspaceManagedDisk] { [] }
    func software() async throws -> [WorkspaceSoftware] { [] }
    func diskOperation(_ id: String) async throws -> WorkspaceDiskOperation { .init(id: id, state: pendingOperation ? "running" : "done") }
    func desktopInstallation() async throws -> WorkspaceDesktopInstallation { .init(phase: "not_installed") }
    func desktopStatus() async throws -> WorkspaceDesktopAccess { .init(supported: true, enabled: false, available: false) }
    func workloads() async throws -> [WorkspaceManagedWorkload] { [] }
    func workloadTargets() async throws -> [WorkspaceExecutionTarget] { [.init(id: "local", label: "Workspace Host", available: true, isDefault: true)] }
    nonisolated func workloadStatsStream() -> AsyncThrowingStream<[WorkspaceWorkloadMetrics], Error> { metricsFeed.open() }
    func network() async throws -> WorkspaceNetwork { .init(allowInternet: true, publicAccess: false) }
    func outboundIPs() async throws -> [WorkspaceOutboundIP] { [] }
    func publicPorts() async throws -> [Mindwire.ExposedPort] { [] }
    func domain() async throws -> WorkspaceDomain? { nil }
    func ssh() async throws -> WorkspaceSSHAccess { .init(supported: true, sshEnabled: false) }
    func runtimeAccess() async throws -> WorkspaceRuntimeAccess { .init(enabled: true) }
    func lifecycle() async throws -> WorkspaceLifecycle { .init(mode: "permanent", status: "stopped") }
    func archives() async throws -> [WorkspaceArchive] { [] }
    func images() async throws -> [WorkspaceImageOption] { [] }
    func logConfig(_ id: String) async throws -> WorkspaceLogConfig { .init(maxLogSizeMb: 1, logRetentionHours: 1) }
    func logs(_ source: WorkspaceLogSource) async throws -> [WorkspaceLogEntry] { [] }
    nonisolated func logStream(_ source: WorkspaceLogSource) -> AsyncThrowingStream<WorkspaceLogEvent, Error> { .init { $0.finish() } }
    func perform(_ command: WorkspaceManagementCommand) async throws -> WorkspaceManagementResult {
        commands.append(command)
        if let gate { await gate.wait() }
        if failNextCommand { failNextCommand = false; throw URLError(.networkConnectionLost) }
        return .completed
    }
}

private final class WorkspaceMetricsTestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var opens = 0
    private var closes = 0
    private var continuation: AsyncThrowingStream<[WorkspaceWorkloadMetrics], Error>.Continuation?
    var opened: Int { lock.withLock { opens } }
    var closed: Int { lock.withLock { closes } }
    func open() -> AsyncThrowingStream<[WorkspaceWorkloadMetrics], Error> {
        AsyncThrowingStream { value in
            lock.withLock { opens += 1; continuation = value }
            value.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.closes += 1 }
            }
        }
    }
    func send(_ values: [WorkspaceWorkloadMetrics]) {
        let value = lock.withLock { continuation }
        value?.yield(values)
    }
}
