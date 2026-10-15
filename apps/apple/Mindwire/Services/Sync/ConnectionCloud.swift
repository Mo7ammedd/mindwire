import CloudKit
import Foundation

struct ConnectionCloudRecord {
    let value: ConnectionSyncRecord
    let systemFields: Data?
}

enum ConnectionCloudEvent {
    case state(Data)
    case received([ConnectionCloudRecord])
    case saved([ConnectionCloudRecord])
    case conflict(ConnectionCloudRecord)
    case account(String?)
    case erased
    case failed(Error)
    case activity(Bool)
}

@MainActor protocol ConnectionCloud: AnyObject {
    func accountID() async throws -> String
    func hasBackup() async throws -> Bool
    func start(state: Data?, receive: @escaping @MainActor (ConnectionCloudEvent) -> Void,
               record: @escaping @MainActor (String) -> ConnectionCloudRecord?) throws
    func schedule(_ ids: Set<String>)
    func fetch() async throws
    func send() async throws
    func stop() async
    func erase() async throws
}

/// CKSyncEngine owns the subscription, change tokens, retry/backoff and pending
/// sends. Each private record holds one encrypted connection or preference.
@MainActor final class CloudKitConnectionCloud: ConnectionCloud, CKSyncEngineDelegate {
    nonisolated static let containerID = "iCloud.com.oblien.mindwire"
    nonisolated static let zoneName = "MindwireConnections"
    nonisolated static let recordType = "MindwireConnection"
    private let container: CKContainer
    private let zoneID: CKRecordZone.ID
    private var engine: CKSyncEngine?
    private var receive: (@MainActor (ConnectionCloudEvent) -> Void)?
    private var record: (@MainActor (String) -> ConnectionCloudRecord?)?
    private var operationError: Error?
    private var invalidData = false
    private var activities = 0

    init(container: CKContainer = CKContainer(identifier: containerID), zoneName: String = zoneName) {
        self.container = container
        zoneID = CKRecordZone.ID(zoneName: zoneName)
    }

    func accountID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw ConnectionSyncError.unavailable }
        return try await container.userRecordID().recordName
    }

    func hasBackup() async throws -> Bool {
        do {
            let value = try await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: "settings", zoneID: zoneID))
            _ = try decode(value)
            return true
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return false
        }
    }

    func start(state: Data?, receive: @escaping @MainActor (ConnectionCloudEvent) -> Void,
               record: @escaping @MainActor (String) -> ConnectionCloudRecord?) throws {
        guard engine == nil else { return }
        invalidData = false
        operationError = nil
        self.receive = receive
        self.record = record
        let serialization = try state.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
            stateSerialization: serialization, delegate: self)
        configuration.automaticallySync = true
        configuration.subscriptionID = "mindwire-connection-sync." + zoneID.zoneName
        engine = CKSyncEngine(configuration)
        // Only a new replica creates a zone. Existing devices must respect a
        // backup deleted elsewhere rather than recreating it on their next send.
        if state == nil { engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
    }

    func schedule(_ ids: Set<String>) {
        engine?.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
    }

    func fetch() async throws {
        guard let engine else { return }
        operationError = nil
        try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
        if let operationError { throw operationError }
    }

    func send() async throws {
        guard let engine else { return }
        operationError = nil
        try await engine.sendChanges(.init(scope: .zoneIDs([zoneID])))
        if let operationError { throw operationError }
    }

    func stop() async {
        let previous = engine
        engine = nil
        receive = nil
        record = nil
        activities = 0
        await previous?.cancelOperations()
    }

    func erase() async throws {
        do { _ = try await container.privateCloudDatabase.deleteRecordZone(withID: zoneID) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem { }
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        .init(scope: .zoneIDs([zoneID]))
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard engine === syncEngine, !invalidData else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        var records: [CKRecord] = []
        for change in pending.prefix(100) {
            guard case .saveRecord(let id) = change, id.zoneID == zoneID else { continue }
            guard let value = record?(id.recordName) else {
                syncEngine.state.remove(pendingRecordZoneChanges: [change])
                continue
            }
            do { records.append(try encode(value)) }
            catch { fail(error); return nil }
        }
        return records.isEmpty ? nil : .init(recordsToSave: records)
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard engine === syncEngine else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                if !invalidData { receive?(.state(try JSONEncoder().encode(update.stateSerialization))) }
            case .accountChange(let event):
                switch event.changeType {
                case .signIn(let user): receive?(.account(user.recordName))
                case .switchAccounts(_, let user): receive?(.account(user.recordName))
                case .signOut: receive?(.account(nil))
                @unknown default: receive?(.account(nil))
                }
            case .fetchedRecordZoneChanges(let changes):
                let records = try changes.modifications.filter { $0.record.recordID.zoneID == zoneID }.map { try decode($0.record) }
                receive?(.received(records))
                // We retain tombstones. An out-of-band zone/record deletion must
                // never cause a different device to silently recreate the backup.
                if changes.deletions.contains(where: { $0.recordID.zoneID == zoneID }) { receive?(.erased) }
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == zoneID }) { receive?(.erased) }
            case .sentRecordZoneChanges(let changes):
                receive?(.saved(try changes.savedRecords.map(decode)))
                for failure in changes.failedRecordSaves {
                    if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord {
                        receive?(.conflict(try decode(server)))
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    } else if failure.error.code == .zoneNotFound || failure.error.code == .userDeletedZone {
                        receive?(.erased)
                    } else { fail(failure.error) }
                }
            case .sentDatabaseChanges(let changes):
                for failure in changes.failedZoneSaves { fail(failure.error) }
            case .didFetchRecordZoneChanges(let event):
                if let error = event.error {
                    if error.code == .zoneNotFound || error.code == .userDeletedZone { receive?(.erased) }
                    else { fail(error) }
                }
            case .willFetchChanges, .willSendChanges:
                activities += 1
                receive?(.activity(true))
            case .didFetchChanges, .didSendChanges:
                activities = max(0, activities - 1)
                receive?(.activity(activities > 0))
            default: break
            }
        } catch {
            invalidData = true
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        operationError = error
        receive?(.failed(error))
    }

    private func decode(_ record: CKRecord) throws -> ConnectionCloudRecord {
        guard record.recordType == Self.recordType,
              let data = record.encryptedValues["payload"] as? Data, data.count <= 512 * 1024 else { throw ConnectionSyncError.invalidBackup }
        let value = try JSONDecoder().decode(ConnectionSyncRecord.self, from: data)
        guard value.version <= 1 else { throw ConnectionSyncError.newerVersion }
        try value.validate()
        guard value.id == record.recordID.recordName else { throw ConnectionSyncError.invalidBackup }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return ConnectionCloudRecord(value: value, systemFields: archiver.encodedData)
    }

    private func encode(_ value: ConnectionCloudRecord) throws -> CKRecord {
        try value.value.validate()
        let record: CKRecord
        if let data = value.systemFields {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }
            guard let saved = CKRecord(coder: unarchiver), saved.recordType == Self.recordType,
                  saved.recordID == CKRecord.ID(recordName: value.value.id, zoneID: zoneID) else { throw ConnectionSyncError.invalidBackup }
            record = saved
        } else { record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: value.value.id, zoneID: zoneID)) }
        let data = try JSONEncoder().encode(value.value)
        guard data.count <= 512 * 1024 else { throw ConnectionSyncError.storage }
        record.encryptedValues["payload"] = data as CKRecordValue
        return record
    }
}

extension ConnectionSyncError {
    /// CloudKit wraps per-record errors in partialFailure. Surface the actionable
    /// cause, not its generic "Failed to send changes" wrapper or record IDs.
    static func message(for error: Error) -> String {
        if let cloud = error as? CKError {
            if cloud.code == .partialFailure, let failures = cloud.partialErrorsByItemID {
                let errors = Array(failures.values)
                if errors.contains(where: { ($0 as? CKError)?.code == .quotaExceeded }) {
                    return message(for: CKError(.quotaExceeded))
                }
                if let first = errors.first { return message(for: first) }
            }
            switch cloud.code {
            case .quotaExceeded:
                return "Your iCloud storage is full. Free some space in Settings → Apple Account → iCloud, then try again. Your connections are kept on this device."
            case .notAuthenticated: return ConnectionSyncError.unavailable.localizedDescription
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return "Waiting for iCloud. Your changes are saved on this device and will sync when the connection is available."
            case .permissionFailure, .badContainer, .missingEntitlement:
                return "iCloud is unavailable for this version of Mindwire. Your connections are kept on this device."
            default: break
            }
        }
        if let network = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(network.code) {
            return "Waiting for a connection. Your changes are saved on this device and will sync when you’re back online."
        }
        return error.localizedDescription
    }
}
