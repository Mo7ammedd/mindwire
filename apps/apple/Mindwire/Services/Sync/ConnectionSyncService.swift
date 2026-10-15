import Foundation
import Observation
import UIKit

extension Notification.Name {
    static let connectionLibraryRestored = Notification.Name("mindwire.connections.restored")
}

@MainActor @Observable
final class ConnectionSyncService {
    static let storageKey = "mindwire:connection-sync:v1"
    private static let consentKey = "mindwire.sync.device.consent"
    private struct Consent: Codable { var enabled: Bool; var accountID: String? }

    private(set) var enabled = false
    private(set) var syncCredentials = false
    private(set) var busy = false
    private(set) var accountAvailable = false
    private(set) var lastSyncedAt: Date?
    private(set) var error: String?
    private(set) var pendingCount = 0
    private(set) var restoredCount = 0
    @ObservationIgnored private let stores: Stores
    @ObservationIgnored let secrets: any ConnectionSyncSecrets
    @ObservationIgnored private let cloud: any ConnectionCloud
    @ObservationIgnored private var replica: ConnectionSyncReplica
    @ObservationIgnored private var consent: Consent?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var validStorage = true
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var job: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var stopping: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var preferences: [String: BackupPreferenceValue] = [:]
    @ObservationIgnored private var requestedEnable = false

    init(stores: Stores, cloud: (any ConnectionCloud)? = nil,
         secrets: any ConnectionSyncSecrets = KeychainConnectionSyncSecrets()) {
        self.stores = stores
        self.cloud = cloud ?? CloudKitConnectionCloud()
        self.secrets = secrets
        if let data = stores.defaults.data(forKey: Self.storageKey) {
            if let saved = try? JSONDecoder().decode(ConnectionSyncReplica.self, from: data) { replica = saved }
            else { replica = .init(); validStorage = false; error = ConnectionSyncError.storage.localizedDescription }
        } else { replica = .init() }
        consent = secrets.local(Self.consentKey).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(Consent.self, from: $0) }
        enabled = consent?.enabled ?? false
        lastSyncedAt = replica.lastSyncedAt
        pendingCount = replica.pending.count
        do { try ConnectionFileBackup.finishPendingRestore(in: stores) }
        catch { validStorage = false; self.error = ConnectionSyncError.storage.localizedDescription }
        preferences = BackupPreferences.values(in: stores)
        stores.connections.didChange = { [weak self] in Task { @MainActor in self?.localDidChange() } }
        stores.workspaces.didChange = { [weak self] in Task { @MainActor in self?.localDidChange() } }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: stores.defaults, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.preferencesDidChange() }
        }
        rememberDeviceIdentities()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var savedConnectionCount: Int { stores.connections.list().count }
    var status: String {
        if busy { return "Syncing…" }
        if error != nil { return "Needs attention" }
        if !enabled { return "Off" }
        if pendingCount > 0 { return "Waiting to sync" }
        return lastSyncedAt == nil ? "Ready" : "Up to date"
    }

    /// Cold installs only look for an existing private backup. Uploading starts
    /// after opting in, or restoring that same user's previously enabled backup.
    func foreground() async {
        if let job { await job.task.value; return }
        guard consent?.enabled != false, validStorage else { return }
        await performJob {
            let account = try await self.cloud.accountID()
            try Task.checkCancellation()
            self.accountAvailable = true
            if let previous = self.consent?.accountID, previous != account { throw ConnectionSyncError.accountChanged }
            if self.consent == nil {
                guard try await self.cloud.hasBackup() else { return }
                try Task.checkCancellation()
                try self.saveConsent(enabled: true, account: account)
            }
            try await self.activate(account: account)
            try await self.synchronize()
        }
    }

    func setEnabled(_ value: Bool) async {
        requestedEnable = value
        if !value {
            let stopped = suspendOperations()
            enabled = false
            error = nil
            do { try saveConsent(enabled: false, account: consent?.accountID) }
            catch { self.error = ConnectionSyncError.message(for: error) }
            await stopped.value
            return
        }
        await performJob(coalescing: false) {
            guard self.validStorage else { throw ConnectionSyncError.storage }
            let account = try await self.cloud.accountID()
            try Task.checkCancellation()
            self.accountAvailable = true
            if self.replica.accountID != nil && self.replica.accountID != account {
                await self.cloud.stop()
                try Task.checkCancellation()
                self.started = false
                self.replica = .init()
            }
            try self.saveConsent(enabled: true, account: account)
            self.requestedEnable = false
            try await self.activate(account: account)
            try await self.synchronize()
        }
    }

    func syncNow() async {
        guard enabled else { await foreground(); return }
        await performJob {
            let account = try await self.cloud.accountID()
            try Task.checkCancellation()
            self.accountAvailable = true
            guard self.consent?.accountID == account else { throw ConnectionSyncError.accountChanged }
            try await self.activate(account: account)
            try await self.synchronize()
        }
    }

    func retry() async {
        if requestedEnable, !enabled { await setEnabled(true) }
        else { await syncNow() }
    }

    func setSyncCredentials(_ value: Bool) async {
        guard enabled else { return }
        await performJob(coalescing: false) {
            let account = try await self.cloud.accountID()
            try Task.checkCancellation()
            guard self.enabled, self.consent?.accountID == account else { throw ConnectionSyncError.accountChanged }
            // Removing synchronized copies never deletes the working local key.
            if !value { try self.secrets.removeAllSynced(account: account) }
            self.syncCredentials = value
            self.replica.edit(.settings(syncCredentials: value))
            try self.persist()
            try self.synchronizeCredentials()
            self.cloud.schedule(self.replica.pending)
            try await self.cloud.send()
            self.markSyncedIfComplete()
        }
    }

    func deleteCloudData() async {
        await performJob(coalescing: false) {
            let account = try await self.cloud.accountID()
            try Task.checkCancellation()
            guard account == self.replica.accountID else { throw ConnectionSyncError.accountChanged }
            await self.cloud.stop()
            self.started = false; self.ready = false
            try await self.cloud.erase()
            try Task.checkCancellation()
            try self.secrets.removeAllSynced(account: account)
            try self.saveConsent(enabled: false, account: account)
            self.replica = ConnectionSyncReplica(accountID: account)
            self.lastSyncedAt = nil; self.syncCredentials = false
            try self.persist()
        }
    }

    func localDidChange() {
        guard !applying else { return }
        rememberDeviceIdentities()
        guard ready, validStorage else { return }
        // Coalesce a connection and its workspace into one atomic cloud record.
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self else { return }
            do {
                try self.captureChanges()
                if self.enabled {
                    try self.synchronizeCredentials()
                    self.cloud.schedule(self.replica.pending)
                }
            } catch { self.error = ConnectionSyncError.message(for: error) }
        }
    }

    private func preferencesDidChange() {
        guard !applying else { return }
        let next = BackupPreferences.values(in: stores)
        guard next != preferences else { return }
        preferences = next
        localDidChange()
    }

    private func activate(account: String) async throws {
        if let stopping {
            await stopping.value
            try Task.checkCancellation()
            self.stopping = nil
        }
        guard enabled else { return }
        if replica.accountID == nil { replica.accountID = account }
        guard replica.accountID == account else { throw ConnectionSyncError.accountChanged }
        guard !started else { return }
        let current = generation
        try cloud.start(state: replica.engineState, receive: { [weak self] event in
            guard let self, self.generation == current else { return }
            self.receive(event)
        }, record: { [weak self] id in
            guard let self, self.enabled, self.ready, self.generation == current,
                  self.replica.pending.contains(id), let record = self.replica.records[id] else { return nil }
            return ConnectionCloudRecord(value: record, systemFields: self.replica.systemFields[id])
        })
        started = true
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func synchronize() async throws {
        guard enabled else { return }
        try applyPending()
        // Preserve genuine offline edits before applying a newer cloud snapshot.
        if !replica.records.isEmpty { try captureChanges() }
        if !ready { try await cloud.send() } // create the private zone before its first fetch
        try await cloud.fetch()
        try Task.checkCancellation()
        guard enabled else { return }
        try applyPending()
        ready = true
        if case .settings(let value) = replica.records["settings"]?.payload { syncCredentials = value }
        else { replica.edit(.settings(syncCredentials: false)) }
        try captureChanges()
        try synchronizeCredentials()
        cloud.schedule(replica.pending)
        try await cloud.send()
        markSyncedIfComplete()
    }

    private func captureChanges() throws {
        guard !applying, validStorage else { return }
        guard replica.unapplied.isEmpty else { throw ConnectionSyncError.storage }
        rememberDeviceIdentities()
        let connections = stores.connections.list()
        var present = Set<String>()
        for connection in connections {
            guard connection.remote != nil || connection.pairedComputer != nil else { continue }
            let pin = connection.remote.flatMap { secrets.local(ConnectionBackup.hostKeyReference($0)) }
            let backup = ConnectionBackup(connection: connection, workspaces: stores.workspaces(forServerId: connection.id), sshHostKey: pin)
            try backup.validate()
            let value = ConnectionSyncPayload.connection(backup)
            present.insert(value.id)
            replica.edit(value)
        }
        for record in Array(replica.records.values) {
            guard case .connection(let old) = record.payload, !present.contains(record.id) else { continue }
            if syncCredentials, let ref = old.connection.remote?.auth.secretReference, let account = replica.accountID {
                try secrets.removeSynced(reference: ref, account: account)
            }
            replica.remove(record.id)
        }
        for (key, value) in BackupPreferences.values(in: stores) { replica.edit(.preference(key: key, value: value)) }
        try persist()
    }

    private func rememberDeviceIdentities() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for computer in stores.connections.list().compactMap(\.pairedComputer) where !computer.deviceId.isEmpty {
            guard let data = try? encoder.encode(computer) else { continue }
            let value = String(decoding: data, as: UTF8.self)
            if secrets.local(computer.deviceIdentityReference) != value {
                if !secrets.setLocal(value, key: computer.deviceIdentityReference) { error = ConnectionSyncError.keychain.localizedDescription }
            }
        }
    }

    private func synchronizeCredentials() throws {
        guard syncCredentials, let account = replica.accountID else { return }
        var restored: [String] = []
        defer {
            if !restored.isEmpty {
                NotificationCenter.default.post(name: .connectionLibraryRestored, object: stores,
                    userInfo: ["credentialConnections": restored])
            }
        }
        for connection in stores.connections.list() {
            guard let ref = connection.remote?.auth.secretReference else { continue }
            if let local = secrets.local(ref) {
                if secrets.synced(ref, account: account) != local { try secrets.setSynced(local, reference: ref, account: account) }
            } else if let saved = secrets.synced(ref, account: account) {
                guard secrets.setLocal(saved, key: ref) else { throw ConnectionSyncError.keychain }
                restored.append(connection.id)
            }
        }
    }

    private func receive(_ event: ConnectionCloudEvent) {
        do {
            switch event {
            case .state(let state): replica.engineState = state
            case .received(let records):
                if ready { try captureChanges() }
                // Settings precede credentials; all records persist before applying
                // them to the visible library, so an interrupted restore is replayable.
                for record in records {
                    replica.systemFields[record.value.id] = record.systemFields
                    if try replica.receive(record.value) { replica.unapplied.insert(record.value.id) }
                }
                try persist()
                if case .settings(let value) = replica.records["settings"]?.payload { syncCredentials = value }
                try applyPending()
                try synchronizeCredentials()
                if ready { cloud.schedule(replica.pending) }
            case .saved(let records):
                for record in records {
                    replica.systemFields[record.value.id] = record.systemFields
                    if replica.records[record.value.id] == record.value { replica.pending.remove(record.value.id) }
                    else { cloud.schedule([record.value.id]) }
                }
                if !records.isEmpty, replica.pending.isEmpty { error = nil }
                markSyncedIfComplete()
            case .conflict(let record):
                replica.systemFields[record.value.id] = record.systemFields
                if try replica.receive(record.value) { replica.unapplied.insert(record.value.id) }
                try persist()
                try applyPending()
                cloud.schedule(replica.pending)
            case .account(let account):
                guard account == replica.accountID else {
                    _ = suspendOperations()
                    accountAvailable = account != nil
                    error = (account == nil ? ConnectionSyncError.unavailable : .accountChanged).localizedDescription
                    if account != nil { try saveConsent(enabled: false, account: consent?.accountID) }
                    return
                }
            case .erased:
                _ = suspendOperations()
                try saveConsent(enabled: false, account: consent?.accountID)
                replica = ConnectionSyncReplica(accountID: replica.accountID)
                lastSyncedAt = nil; syncCredentials = false; error = nil
            case .failed(let failure): error = ConnectionSyncError.message(for: failure)
            case .activity(let active): if job == nil { busy = active }
            }
            try persist()
        } catch { self.error = ConnectionSyncError.message(for: error) }
    }

    private func applyPending() throws {
        for id in replica.unapplied.sorted() {
            if let record = replica.records[id] { try apply(record) }
            replica.unapplied.remove(id)
            try persist()
        }
    }

    private func apply(_ record: ConnectionSyncRecord) throws {
        applying = true
        defer { applying = false; preferences = BackupPreferences.values(in: stores) }
        switch record.payload {
        case .settings(let value): syncCredentials = value
        case .preference(let key, let value): BackupPreferences.apply(key: key, value: value, to: stores)
        case .connection(let backup):
            let restored = try backup.restored(existing: stores.connections.get(backup.connection.id), secrets: secrets)
            let new = stores.connections.get(restored.id) == nil
            stores.connections.save(restored)
            for workspace in backup.workspaces { stores.workspaces.save(workspace) }
            // These are local links only; workspace files/registries are untouched.
            let valid = Set(backup.workspaces.map(\.id))
            for workspace in stores.workspaces(forServerId: restored.id) where !valid.contains(workspace.id) {
                stores.deleteWorkspace(workspace.id)
            }
            if new { restoredCount += 1 }
            NotificationCenter.default.post(name: .connectionLibraryRestored, object: stores)
        case nil:
            for connection in stores.connections.list() where ConnectionSyncPayload.connection(
                ConnectionBackup(connection: connection, workspaces: [])).id == record.id {
                stores.deleteServer(connection.id)
            }
            NotificationCenter.default.post(name: .connectionLibraryRestored, object: stores)
        }
    }

    private func saveConsent(enabled: Bool, account: String?) throws {
        let value = Consent(enabled: enabled, accountID: account)
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        guard secrets.setLocal(encoded, key: Self.consentKey) else { throw ConnectionSyncError.keychain }
        consent = value
        self.enabled = enabled
    }

    private func persist() throws {
        guard validStorage else { throw ConnectionSyncError.storage }
        let data = try JSONEncoder().encode(replica)
        stores.defaults.set(data, forKey: Self.storageKey)
        pendingCount = replica.pending.count
    }

    private func markSyncedIfComplete() {
        guard replica.pending.isEmpty, error == nil else { return }
        replica.lastSyncedAt = .now
        lastSyncedAt = replica.lastSyncedAt
        try? persist()
    }

    private func suspendOperations() -> Task<Void, Never> {
        generation = UUID()
        job?.task.cancel()
        job = nil
        scanTask?.cancel()
        ready = false; started = false; busy = false
        let previous = stopping
        let task = Task {
            await previous?.value
            await cloud.stop()
        }
        stopping = task
        return task
    }

    private func performJob(coalescing: Bool = true, _ work: @escaping @MainActor () async throws -> Void) async {
        // Repeated refreshes share a request. User changes queue behind it so a
        // credential toggle or deletion can never be silently dropped.
        let waitingGeneration = generation
        while let previous = job {
            await previous.task.value
            if job?.id == previous.id { job = nil; busy = false }
            if coalescing || Task.isCancelled || generation != waitingGeneration { return }
        }
        guard !Task.isCancelled else { return }
        let id = UUID()
        let current = generation
        busy = true
        error = nil
        let task = Task {
            do { try await work() }
            catch {
                guard current == self.generation, !Task.isCancelled else { return }
                self.error = ConnectionSyncError.message(for: error)
                if case ConnectionSyncError.unavailable = error { self.accountAvailable = false }
            }
        }
        job = (id, task)
        await task.value
        if job?.id == id { job = nil; busy = false }
    }
}
