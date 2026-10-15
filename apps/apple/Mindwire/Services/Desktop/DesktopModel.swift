import Foundation
import Observation
import UIKit

@MainActor @Observable
final class DesktopModel {
    let workspace: Workspace
    let desktopId: String?
    let cursor = DesktopCursor()
    private(set) var providerStatus: DesktopProviderStatus?
    private(set) var snapshot: DesktopSnapshot?
    private(set) var image: CGImage?
    private(set) var hasFrame = false
    private(set) var displaySize = CGSize.zero
    private(set) var streamSettings = DesktopStreamSettings()
    private(set) var changingStream = false
    private(set) var connected = false
    private(set) var busy = false
    private(set) var stage = ""
    private(set) var error: String?
    private(set) var needsUpdate = false
    private(set) var inputBusy = false
    private(set) var controlBusy = false
    private(set) var signInBusy = false
    private(set) var signInNotice: String?
    private(set) var reconnecting = false
    private(set) var checkingStatus = false
    private(set) var recovery = DesktopRecovery()
    private(set) var keepsControlLayout = false
    private(set) var controlReachable = true
    private(set) var inputSynchronizing = false
    private let stores: Stores
    private let context: WorkspaceConnectionContext
    private let provider: any WorkspaceDesktopProvider
    private let makeViewer: () -> any DesktopViewing
    private var http: DaemonHTTP?
    private var session: DesktopSession?
    private var displayConnection: DesktopDisplayConnection?
    private var viewer: (any DesktopViewing)?
    private var viewerGeneration = UUID()
    private var viewerHasFrame = false
    private var automaticControlTask: Task<Void, Never>?
    private var wantsControl = true
    private var waitingForDisplayGeometry = false
    private var connectTask: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var events: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputGeneration = UUID()
    private var queuedInputs = DesktopInputBuffer()
    private var lifecycle = DesktopConnectionLifecycle()
    private var generation = UUID()
    private var checkedAt = Date.distantPast
    private var statusTask: Task<DesktopProviderStatus, Error>?
    private var retryTask: Task<Void, Never>?
    private var retryCount = 0
    private var recoveryTask: Task<Void, Never>?
    private var heartbeat = DesktopHeartbeat()
    private var inputProgress = DesktopInputProgress()
    private var inputWatchdog: Task<Void, Never>?
    private var latestPointerAck: TimeInterval = 0
    @ObservationIgnored private var remoteCursorID: String?
    @ObservationIgnored private var snapshotRevision: Int64 = -1

    init(workspace: Workspace, stores: Stores, provider: (any WorkspaceDesktopProvider)? = nil, desktopId: String? = nil,
         makeViewer: @escaping () -> any DesktopViewing = { NativeDesktopConnection() }) {
        self.workspace = workspace; self.stores = stores
        self.desktopId = desktopId
        self.makeViewer = makeViewer
        context = WorkspaceConnectionContext(workspace, stores: stores)
        self.provider = provider ?? WorkspaceDesktopProviders.make(workspace, stores: stores, desktopId: desktopId)
    }

    var usesLocalSetup: Bool { provider.usesLocalSetup }
    var needsLocalSetup: Bool { usesLocalSetup && providerStatus?.setup != nil }

    var controlsDesktop: Bool {
        connected && !controlBusy && snapshot?.controller?.sessionId == session?.id && session?.id != nil
    }
    var acceptsInput: Bool {
        controlsDesktop && hasFrame && (!recovery.active || viewerHasFrame) && !waitingForDisplayGeometry
    }
    var canMovePointer: Bool {
        keepsControlLayout && hasFrame && displaySize.width > 1 && displaySize.height > 1
    }
    var showsConnectionOverlay: Bool {
        !hasFrame || (!connected && (recovery.timedOut || !busy && !checkingStatus && !reconnecting && !recovery.active))
    }
    var showsInitialConnectionProgress: Bool {
        !hasFrame && (busy || checkingStatus || reconnecting || recovery.active)
    }
    var showsConnectionIndicator: Bool {
        hasFrame && !showsConnectionOverlay && (recovery.active || inputSynchronizing || controlBusy)
    }
    var connectionLabel: String { hasFrame ? "Reconnecting…" : "Connecting…" }
    var controllerLabel: String {
        if controlsDesktop { return "You’re in control" }
        if let controller = snapshot?.controller { return "\(controller.name) is in control" }
        return "Viewing desktop"
    }
    private func isCurrent(_ expected: UUID) -> Bool {
        expected == generation && context == WorkspaceConnectionContext(workspace, stores: stores)
    }
    private func requireContext(_ expected: UUID) throws {
        guard isCurrent(expected), !Task.isCancelled else {
            throw CancellationError()
        }
    }

    func load(force: Bool = false) async {
        guard !busy else { return }
        let expected = generation
        do {
            _ = try await readStatus(maxAge: force ? 0 : 60)
            try requireContext(expected)
            error = nil; needsUpdate = false
        } catch is CancellationError {} catch {
            guard isCurrent(expected) else { return }
            self.error = error.localizedDescription
            needsUpdate = (error as? DesktopProblem)?.code == "update_required"
            if (error as? DesktopProblem)?.code == "unsupported" {
                providerStatus = .init(supported: false, enabled: false, available: false, credentials: nil)
                checkedAt = Date()
            }
        }
    }

    /// Navigation reuses recent status. Explicit checks and connection attempts
    /// join one request, so a slow Mac never accumulates parallel probes.
    private func readStatus(maxAge: TimeInterval) async throws -> DesktopProviderStatus {
        if let statusTask { return try await statusTask.value }
        if let providerStatus, Date().timeIntervalSince(checkedAt) < maxAge { return providerStatus }
        let expected = generation
        let task = Task { @MainActor in
            defer { if isCurrent(expected) { statusTask = nil; checkingStatus = false } }
            try requireContext(expected)
            let status = try await provider.status()
            try requireContext(expected)
            providerStatus = status; checkedAt = Date()
            return status
        }
        statusTask = task; checkingStatus = true
        return try await task.value
    }

    /// One connection job per workspace. Acquire an available controller by
    /// default; an existing controller still requires an explicit takeover.
    func connect(automaticallySignIn: Bool = true, automaticallyControl: Bool = true, resuming: Bool = false) async {
        if let connectTask { await connectTask.value; return }
        guard !connected, viewer == nil else { return }
        if !resuming { wantsControl = automaticallyControl }
        retryTask?.cancel(); retryTask = nil
        lifecycle.connect()
        beginRecovery()
        let expected = generation
        let task = Task { @MainActor in
            busy = true; needsUpdate = false; error = nil; signInNotice = nil
            defer { if isCurrent(expected) { busy = viewer != nil && !connected; connectTask = nil } }
            do {
                try requireContext(expected)
                stage = "Connecting to Mindwire…"
                let api = try await stores.workspaceData.desktopHTTP(workspace).selectingDesktop(desktopId)
                try requireContext(expected); http = api
                stage = "Preparing desktop…"
                let status = try await readStatus(maxAge: resuming ? 0 : 5)
                try requireContext(expected); providerStatus = status
                guard status.supported else { throw DesktopProblem(code: "unsupported", message: "This workspace image does not provide a desktop.") }
                try requireContext(expected)
                stage = "Authorizing connection…"
                let bound = try await provider.authorize(api: api, status: status, resuming: resuming)
                try requireContext(expected); snapshot = bound
                if !usesLocalSetup, automaticallySignIn, !resuming, bound.os == "darwin", bound.controller == nil {
                    stage = "Opening your Mac session…"
                    do { try await provider.prepareSession() }
                    catch is CancellationError { throw CancellationError() }
                    catch { signInNotice = "Automatic sign-in could not finish. Use Desktop sign-in to retry or sign in on the Mac." }
                    try requireContext(expected)
                }
                let opened: DesktopSession = try await api.decode("POST", "/surfaces/desktop/sessions",
                    json: ["requestId": UUID().uuidString, "name": UIDevice.current.name, "mode": "view"], quiet: true)
                // If cancelled after the server accepted the session, close that exact session.
                do { try requireContext(expected) } catch {
                    _ = try? await api.run("DELETE", "/surfaces/desktop/sessions/\(opened.id)", json: nil, quiet: true); throw error
                }
                session = opened
                stage = "Opening display…"
                let display = try await provider.openDisplay(api: api, session: opened)
                do { try requireContext(expected) } catch { display.close(); throw error }
                displayConnection = display
                openViewer(expected: expected)
                try await refreshSnapshot(expected)
                startMonitoring(expected)
            } catch is CancellationError { if isCurrent(expected) { disconnect() } } catch {
                guard isCurrent(expected) else { return }
                needsUpdate = (error as? DesktopProblem)?.code == "update_required"
                if usesLocalSetup, DesktopReconnectPolicy.requiresSetup(error) {
                    providerStatus?.setup = .init(reason: "authentication", command: "mindwire desktop enable")
                }
                connectionFailed(error)
            }
        }
        connectTask = task
        await task.value
    }

    /// FPS changes take effect in the request pacer immediately. Pixel format
    /// changes negotiate a fresh viewer inside the same forward and session,
    /// keeping the last image and control lease. This avoids decoding an in-flight
    /// frame using a different pixel format.
    func configureStream(_ settings: DesktopStreamSettings) {
        guard streamSettings != settings else { return }
        let qualityChanged = streamSettings.quality != settings.quality
        streamSettings = settings
        if qualityChanged, displayConnection != nil, viewer != nil {
            openViewer(expected: generation)
        } else { viewer?.setFrameRate(settings.frameRate) }
    }

    private func openViewer(expected: UUID) {
        guard let displayConnection, isCurrent(expected) else { return }
        viewerGeneration = UUID()
        viewerHasFrame = false
        let stream = viewerGeneration
        viewer?.disconnect()
        changingStream = connected
        let client = makeViewer()
        viewer = client
        client.onFrame = { [weak self] frame in
            guard let self, self.isCurrent(expected), self.viewerGeneration == stream else { return }
            if self.displaySize != frame.sourceSize {
                if self.displaySize != .zero { self.cancelInput() }
                self.displaySize = frame.sourceSize
            }
            if self.waitingForDisplayGeometry, self.matchesDisplay(self.snapshot?.geometry) {
                self.waitingForDisplayGeometry = false
            }
            self.image = frame.image
            self.viewerHasFrame = true
            if !self.hasFrame { self.hasFrame = true }
            self.inputProgress.displayed(requestedAt: frame.requestedAt)
            if self.connected, self.controlReachable { self.finishRecovery() }
            if self.changingStream { self.changingStream = false }
        }
        client.onState = { [weak self] ready, message in
            guard let self, self.isCurrent(expected), self.viewerGeneration == stream else { return }
            let justConnected = ready && !self.connected
            self.connected = ready; self.busy = false
            if ready {
                self.reconnecting = false; self.retryCount = 0; self.error = nil
                self.controlReachable = true; self.heartbeat.recovered()
                if self.viewerHasFrame { self.finishRecovery() }
                if justConnected { self.acquireAvailableControl(expected: expected) }
            } else {
                self.connectionFailed(DesktopProblem(code: "disconnected", message: message ?? "The desktop connection ended."))
            }
        }
        client.onCursor = { [weak self] shape, requestedAt in
            guard let self, self.isCurrent(expected), self.viewerGeneration == stream,
                  self.remoteCursorID == nil,
                  requestedAt >= self.latestPointerAck else { return }
            self.cursor.show(shape)
        }
        client.connect(port: displayConnection.port, settings: streamSettings, debugLogging: false)
    }

    private func acquireAvailableControl(expected: UUID) {
        guard wantsControl, automaticControlTask == nil else { return }
        automaticControlTask = Task { @MainActor in
            defer { if isCurrent(expected) { automaticControlTask = nil } }
            do {
                try await refreshSnapshot(expected)
                guard wantsControl, connected, snapshot?.controller == nil else { return }
                await changeControl("acquire") // The server atomically refuses an occupied lease.
            } catch is CancellationError {} catch {
                if isCurrent(expected) { self.error = error.localizedDescription }
            }
        }
    }

    func takeControl() async {
        guard !controlsDesktop else { return }
        wantsControl = true
        await changeControl(snapshot?.controller == nil ? "acquire" : "takeover")
    }
    func releaseControl() async {
        wantsControl = false
        keepsControlLayout = false
        automaticControlTask?.cancel(); automaticControlTask = nil
        await changeControl("release")
    }
    private func changeControl(_ action: String) async {
        guard !controlBusy, let api = http, let session, connected else { return }
        let expected = generation
        controlBusy = true
        cancelInput()
        defer { if isCurrent(expected) { controlBusy = false } }
        do {
            try requireContext(expected)
            let updated: DesktopSession = try await api.decode("POST", "/surfaces/desktop/sessions/\(session.id)/control",
                json: ["action": action], quiet: true)
            try requireContext(expected)
            self.session = updated
            queuedInputs.removeAll()
            try await refreshSnapshot(expected)
            keepsControlLayout = snapshot?.controller?.sessionId == self.session?.id
            error = nil
        } catch is CancellationError {} catch {
            guard isCurrent(expected) else { return }
            self.error = error.localizedDescription
            try? await refreshSnapshot(expected)
        }
    }

    func send(_ input: DesktopInput) {
        send([input])
    }
    func handlePointer(_ event: DesktopPointerEvent) {
        guard canMovePointer else { return }
        if !acceptsInput {
            // The pointer stays local and responsive even while the transport
            // recovers. A disconnected/changed session cannot receive clicks.
            if case .move(let delta) = event { cursor.move(delta, pixels: displaySize) }
            else if event == .button(false) { cursor.release(pixels: displaySize, send: send) }
            return
        }
        // Capture coordinates now, before enqueueing; later pointer movement
        // must never retarget an earlier click or button transition.
        cursor.handle(event, pixels: displaySize, send: send)
    }
    private func send(_ inputs: [DesktopInput]) {
        var inputs = inputs
        if !acceptsInput {
            guard controlsDesktop, inputs.allSatisfy(\.releasesButtons) else { return }
            // Releasing is always safe, but a stale hover's coordinates are not.
            inputs = [.init(kind: "release")]
        }
        if waitingForDisplayGeometry, inputs.contains(where: { ["pointer", "click", "drag", "scroll"].contains($0.kind) }) { return }
        guard queuedInputs.append(contentsOf: inputs) else {
            // Backpressure must not erase already accepted clicks or typing.
            // End a held local gesture using the reserved mouse-up slot.
            cursor.release(pixels: displaySize) { _ = queuedInputs.append($0) }
            error = "Input queue is full. Let pending input finish before trying again."
            return
        }
        guard inputTask == nil else { return }
        let expected = generation
        let inputEpoch = inputGeneration
        inputBusy = true
        inputTask = Task { @MainActor in
            defer { if isCurrent(expected), inputGeneration == inputEpoch { inputBusy = false; inputTask = nil } }
            while isCurrent(expected), inputGeneration == inputEpoch, !Task.isCancelled, controlsDesktop, let input = queuedInputs.next() {
                do {
                    inputProgress.began(at: ProcessInfo.processInfo.systemUptime)
                    watchInput(expected: expected, inputEpoch: inputEpoch)
                    let receipt = try await action(input, expected: expected)
                    guard inputGeneration == inputEpoch else { return }
                    let receivedAt = ProcessInfo.processInfo.systemUptime
                    inputProgress.acknowledged(at: receivedAt, changesDisplay: input.changesDisplay)
                    if input.x != nil { latestPointerAck = receivedAt }
                    if inputSynchronizing { viewer?.requestFreshFrame() }
                    if input.kind == "clipboard_read", inputGeneration == inputEpoch, let text = receipt.text {
                        UIPasteboard.general.string = text
                    }
                }
                catch {
                    guard isCurrent(expected), inputGeneration == inputEpoch, !Task.isCancelled else { return }
                    queuedInputs.removeAll(); inputProgress.reset()
                    self.error = error.localizedDescription
                    // The failed input may have run. Release held buttons once,
                    // then recover the display; never replay the original action.
                    _ = try? await action(.init(kind: "release"), expected: expected)
                    if DesktopReconnectPolicy.shouldRetry(error) { connectionFailed(error) }
                    else { try? await refreshSnapshot(expected) }
                    return
                }
            }
            // A drained queue still remembers which buttons are held remotely.
            // Only cancellation/control changes reset that state; a later mouse-up
            // must remain a transition even after an otherwise idle long press.
        }
    }

    private func cancelInput() {
        inputGeneration = UUID()
        inputTask?.cancel(); inputTask = nil; inputBusy = false
        queuedInputs.removeAll()
        inputWatchdog?.cancel(); inputWatchdog = nil
        inputProgress.reset(); inputSynchronizing = false
    }

    private func watchInput(expected: UUID, inputEpoch: UUID) {
        guard inputWatchdog == nil else { return }
        inputWatchdog = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if isCurrent(expected), inputGeneration == inputEpoch { inputWatchdog = nil } }
            while isCurrent(expected), inputGeneration == inputEpoch, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                guard isCurrent(expected), inputGeneration == inputEpoch else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if inputProgress.needsRefresh(at: now) { viewer?.requestFreshFrame() }
                if inputProgress.stalled(at: now), !inputSynchronizing {
                    inputSynchronizing = true
                    viewer?.requestFreshFrame()
                }
                if inputProgress.displayStalled(at: now), !changingStream {
                    // Refresh only the viewer. Keep the control lease and its
                    // ordered input queue alive while replacing stalled video.
                    openViewer(expected: expected)
                }
                if !inputProgress.pending {
                    inputSynchronizing = false
                    return
                }
            }
        }
    }

    func type(_ text: String, modifiers: [String] = []) {
        guard text.utf8.count <= 65536 else { error = "Paste up to 64 KiB at a time from the keyboard."; return }
        let inputs = DesktopTyping.inputs(text, modifiers: modifiers, keyboardText: snapshot?.capabilities.keyboardText == true)
        if modifiers.isEmpty, inputs.count >= DesktopInputBuffer.capacity {
            // A large/multiline paste is one complete text operation, never a
            // partially accepted queue of individual keys on older services.
            send(.init(kind: "text", text: text))
        } else {
            send(inputs)
        }
    }

    private func action(_ input: DesktopInput, expected: UUID) async throws -> DesktopReceipt {
        try requireContext(expected)
        guard let api = http, let session, let control = snapshot?.controller, control.sessionId == session.id else {
            throw DesktopProblem(code: "control_lost", message: "Take control before sending input.")
        }
        let intendedSize = displaySize
        var geometryRevision = snapshot?.geometry?.revision ?? 0
        var refreshed = false
        while true {
            let request = DesktopActionRequest(requestId: UUID().uuidString, sessionId: session.id,
                controlGeneration: control.generation, geometryRevision: geometryRevision, action: input)
            do {
                // Network failures and failed receipts are never repeated: input may have run.
                let receipt: DesktopReceipt = try await desktopDeadline(input.kind == "text" ? 15 : 4) {
                    try await api.decode("POST", "/surfaces/desktop/actions", json: request.desktopJSON(), quiet: true)
                }
                try requireContext(expected)
                if let error = receipt.error { throw error }
                return receipt
            } catch let refusal as DaemonHTTPError where !refreshed && refusal.code == "stale_frame" {
                // This explicit validation refusal happens BEFORE the service applies input.
                // Reconcile once only if the same visible desktop and controller still apply.
                // This handles a native viewer learning the initial size before the controller.
                refreshed = true
                try await refreshSnapshot(expected)
                try requireContext(expected)
                guard self.session?.id == session.id, snapshot?.controller?.generation == control.generation,
                      snapshot?.controller?.sessionId == session.id, displaySize == intendedSize,
                      let geometry = snapshot?.geometry, matchesDisplay(geometry) else { throw refusal }
                geometryRevision = geometry.revision
            }
        }
    }
    func copyClipboard() { send(.init(kind: "clipboard_read")) }
    func loginCredentials() async throws -> DesktopLoginCredentials {
        let expected = generation
        try requireContext(expected)
        let credentials = try await provider.credentials()
        try requireContext(expected)
        return credentials
    }
    func signIn() async {
        guard !signInBusy, connected, snapshot?.controller == nil || controlsDesktop else { return }
        let expected = generation
        signInBusy = true; signInNotice = nil
        defer { if isCurrent(expected) { signInBusy = false } }
        do {
            try await provider.prepareSession()
            try requireContext(expected)
        } catch is CancellationError {} catch {
            if isCurrent(expected) { signInNotice = "Automatic sign-in could not finish. You can still sign in on the Mac." }
        }
    }
    func updateService() async {
        guard !busy else { return }
        let reconnect = connected
        if reconnect { tearDown(keepFrame: true) }
        let expected = generation
        busy = true; stage = "Updating Mindwire…"
        defer { if isCurrent(expected), viewer == nil { busy = false } }
        do {
            try requireContext(expected)
            try await stores.workspaceData.updateDaemon(workspaceId: workspace.id)
            try requireContext(expected); needsUpdate = false; error = nil
            if reconnect {
                busy = false
                await connect(automaticallySignIn: false, resuming: true)
            }
        } catch is CancellationError {} catch {
            if isCurrent(expected) { self.error = error.localizedDescription }
        }
    }

    private func acceptSnapshot(_ current: DesktopSnapshot, expected: UUID) throws {
        try requireContext(expected)
        guard desktopId == nil || current.desktopId == desktopId else {
            throw DesktopProblem(code: "session_mismatch", message: "The desktop selection changed. Reopen this desktop.")
        }
        if let prior = snapshot {
            guard prior.instanceId == current.instanceId else {
                throw DesktopProblem(code: "restarted", message: "The workspace service restarted. Reconnect to its desktop.")
            }
            guard current.revision >= max(prior.revision, snapshotRevision) else { return }
            if prior.controller?.sessionId != current.controller?.sessionId
                || prior.controller?.generation != current.controller?.generation
                || (prior.geometry != current.geometry && !matchesDisplay(current.geometry)) { cancelInput() }
            if prior.geometry != current.geometry, displaySize != .zero {
                // A geometry event can arrive before its pixels. Do not stamp
                // old-screen coordinates with the newer revision in that gap.
                waitingForDisplayGeometry = !matchesDisplay(current.geometry)
            }
            if prior.controller?.sessionId == session?.id, current.controller != nil,
               current.controller?.sessionId != session?.id {
                wantsControl = false // Do not fight another controller after it takes over.
                keepsControlLayout = false
            }
        }
        snapshotRevision = current.revision
        if let remote = current.cursor, remote.id != remoteCursorID,
           let shape = DesktopCursorShape(remote: remote) {
            remoteCursorID = remote.id
            cursor.show(shape)
        }
        var stateChanged = true
        if let prior = snapshot {
            var state = current
            state.revision = prior.revision
            state.cursor = prior.cursor
            // Shape changes go straight to UIKit; do not redraw the SwiftUI
            // screen, keyboard and controls for every animation of a busy cursor.
            stateChanged = state != prior
        }
        if stateChanged { snapshot = current }
        if usesLocalSetup, !current.enabled || current.setup != nil {
            providerStatus = .init(supported: current.supported, enabled: current.enabled, available: current.available,
                                   credentials: false, setup: current.setup ?? .init(reason: "disabled", command: "mindwire desktop enable"))
            throw DesktopProblem(code: "desktop_setup_required", message: "Desktop access was turned off on your Mac.")
        }
        if !controlsDesktop { cancelInput() }
        if wantsControl, connected, current.controller == nil { acquireAvailableControl(expected: expected) }
    }
    private func matchesDisplay(_ geometry: DesktopGeometry?) -> Bool {
        guard let geometry, displaySize.width > 0, displaySize.height > 0 else { return false }
        return CGFloat(geometry.width) == displaySize.width && CGFloat(geometry.height) == displaySize.height
    }
    private func refreshSnapshot(_ expected: UUID) async throws {
        try requireContext(expected)
        guard let api = http else { return }
        let current: DesktopSnapshot = try await api.decode("GET", "/surfaces/desktop", quiet: true)
        try acceptSnapshot(current, expected: expected)
    }
    private func startMonitoring(_ expected: UUID) {
        monitor?.cancel()
        monitor = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(heartbeat.failedAt == nil ? 5 : 1))
                    try requireContext(expected)
                    if controlBusy { continue }
                    guard let api = http, let session else { return }
                    let controlGeneration = snapshot?.controller?.sessionId == session.id ? snapshot?.controller?.generation ?? 0 : 0
                    let renewed: DesktopSession = try await desktopDeadline(4) {
                        try await api.decode("POST", "/surfaces/desktop/sessions/\(session.id)/control",
                            json: ["action": "renew", "generation": controlGeneration], quiet: true)
                    }
                    try requireContext(expected); self.session = renewed
                    try await refreshSnapshot(expected)
                    heartbeat.recovered(); controlReachable = true
                    if connected, viewerHasFrame { finishRecovery() }
                } catch is CancellationError { return } catch {
                    guard isCurrent(expected) else { return }
                    if DesktopReconnectPolicy.code(error) == "control_lost" {
                        // A takeover or an expired lease changes control, not the
                        // display. Reconcile it without replacing the open screen.
                        do {
                            try await refreshSnapshot(expected)
                            heartbeat.recovered(); controlReachable = true
                            if wantsControl, snapshot?.controller == nil { acquireAvailableControl(expected: expected) }
                            if connected, viewerHasFrame { finishRecovery() }
                        } catch {
                            if isCurrent(expected), !error.isRequestCancellation { connectionFailed(error); return }
                        }
                        continue
                    }
                    guard DesktopReconnectPolicy.shouldRetry(error) else { connectionFailed(error); return }
                    heartbeat.failed(at: ProcessInfo.processInfo.systemUptime)
                    if heartbeat.exhausted(at: ProcessInfo.processInfo.systemUptime) {
                        connectionFailed(error); return
                    }
                    controlReachable = false
                    beginRecovery()
                }
            }
        }
        if let streaming = http?.channel as? StreamingDaemonChannel {
            events = Task { @MainActor in
                var attempts = 0
                while isCurrent(expected), !Task.isCancelled {
                    do {
                        for try await data in try await streaming.stream(method: "GET", path: http?.scoped("/surfaces/desktop/events") ?? "/surfaces/desktop/events", jsonBody: nil) {
                            try requireContext(expected)
                            let fresh = try JSONDecoder().decode(DesktopSnapshot.self, from: data)
                            try acceptSnapshot(fresh, expected: expected)
                            attempts = 0
                        }
                    } catch {
                        guard isCurrent(expected), !Task.isCancelled else { return }
                        if (error as? DesktopProblem)?.code == "restarted" {
                            connectionFailed(error); return
                        }
                    }
                    // Restore cursor/control events independently; a dropped SSE
                    // stream must not interrupt the healthy video or input lease.
                    attempts += 1
                    do { try await Task.sleep(for: .seconds(min(5, DesktopReconnectPolicy.delay(attempt: attempts)))) }
                    catch { return }
                }
            }
        }
    }

    func disconnect() {
        lifecycle.disconnect()
        finishRecovery(); keepsControlLayout = false
        tearDown()
        wantsControl = true
    }

    /// Inactive (Control Center, notification shade, interruptions) is handled by
    /// the screen without closing anything. Only actual backgrounding suspends.
    func suspend() {
        guard lifecycle.background() else { return }
        finishRecovery()
        tearDown(keepFrame: true)
    }
    func resume() async {
        guard lifecycle.resume() else { return }
        await connect(automaticallySignIn: false, resuming: true)
    }
    func retryConnection() {
        // An explicit retry joins a current attempt rather than stacking opens.
        if recovery.timedOut { tearDown(keepFrame: true) }
        else if connectTask != nil { return }
        retryTask?.cancel(); retryTask = nil
        Task { await connect(automaticallySignIn: false, resuming: true) }
    }
    private func connectionFailed(_ failure: Error) {
        // Preserve a pending foreground resume if an old callback races suspension.
        let retry = lifecycle.requested && !lifecycle.suspended && DesktopReconnectPolicy.shouldRetry(failure)
        tearDown(keepFrame: true)
        error = failure.localizedDescription
        guard retry else { finishRecovery(); keepsControlLayout = false; return }
        beginRecovery()
        reconnecting = true; stage = "Reconnecting…"
        retryCount += 1
        let expected = generation
        let delay = DesktopReconnectPolicy.delay(attempt: retryCount)
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.isCurrent(expected), self.lifecycle.requested, !self.lifecycle.suspended else { return }
            self.retryTask = nil
            await self.connect(automaticallySignIn: false, resuming: true)
        }
    }
    private func beginRecovery() {
        guard recovery.begin(at: ProcessInfo.processInfo.systemUptime) else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(DesktopRecovery.grace)) } catch { return }
            self?.recovery.advance(to: ProcessInfo.processInfo.systemUptime)
            self?.recoveryTask = nil
        }
    }
    private func finishRecovery() {
        recoveryTask?.cancel(); recoveryTask = nil
        if recovery.active { recovery.finish() }
    }
    private func tearDown(keepFrame: Bool = false) {
        generation = UUID()
        statusTask?.cancel(); statusTask = nil; checkingStatus = false
        retryTask?.cancel(); retryTask = nil; reconnecting = false
        connectTask?.cancel(); connectTask = nil
        monitor?.cancel(); monitor = nil; events?.cancel(); events = nil
        automaticControlTask?.cancel(); automaticControlTask = nil
        cancelInput()
        viewerGeneration = UUID(); changingStream = false
        viewerHasFrame = false
        waitingForDisplayGeometry = false
        snapshotRevision = -1; remoteCursorID = nil
        heartbeat.recovered(); controlReachable = true
        viewer?.disconnect(); viewer = nil
        displayConnection?.close(); displayConnection = nil
        if let session, let api = http {
            // Give lease release time to reach the service before iOS suspends us.
            let background = DesktopSessionClose(api: api, sessionId: session.id)
            background.start()
        }
        session = nil; http = nil
        if !keepFrame { image = nil; hasFrame = false; displaySize = .zero }
        connected = false; busy = false; inputBusy = false; controlBusy = false; signInBusy = false
    }
}

@MainActor
private final class DesktopSessionClose {
    private let api: DaemonHTTP
    private let sessionId: String
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var task: Task<Void, Never>?
    init(api: DaemonHTTP, sessionId: String) { self.api = api; self.sessionId = sessionId }
    func start() {
        background = UIApplication.shared.beginBackgroundTask(withName: "Release desktop control") { [weak self] in
            self?.task?.cancel(); self?.finish()
        }
        task = Task {
            _ = try? await api.run("DELETE", "/surfaces/desktop/sessions/\(sessionId)", json: nil, quiet: true)
            finish()
        }
    }
    private func finish() {
        if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
        task = nil
    }
}
