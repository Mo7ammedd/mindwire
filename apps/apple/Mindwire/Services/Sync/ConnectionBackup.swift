import Foundation
import CryptoKit

/// Only portable connection metadata crosses devices. A computer's approved phone
/// identity, pairing receipts, daemon credentials and discovery keys never do.
struct ConnectionBackup: Codable, Equatable {
    var connection: Connection
    var workspaces: [Workspace]
    var sshHostKey: String?

    init(connection: Connection, workspaces: [Workspace], sshHostKey: String? = nil) {
        self.connection = Self.portable(connection)
        self.workspaces = workspaces.filter { $0.runtime.serverId == connection.id }.map {
            var workspace = $0
            workspace.lastUsedAt = nil
            return workspace
        }.sorted { $0.id < $1.id }
        self.sshHostKey = sshHostKey
    }

    static func portable(_ connection: Connection) -> Connection {
        switch connection {
        case .local(var local):
            local.lastUsedAt = nil
            local.defaultAgent = nil
            local.pairingId = ""
            if let computer = local.computer {
                local.computer = PairedComputer(computerId: computer.computerId, registryId: computer.registryId,
                    deviceId: "", fingerprint: computer.fingerprint, routes: computer.routes,
                    keyRef: "computer.\(computer.computerId).key", tokenRef: "computer.\(computer.computerId).token",
                    operatingSystem: computer.operatingSystem, connection: computer.connection, discovery: computer.discovery)
            }
            return .local(local)
        case .ssh(var remote), .vps(var remote):
            remote.lastUsedAt = nil
            remote.defaultAgent = nil
            return remote.type == .vps ? .vps(remote) : .ssh(remote)
        }
    }

    func validate() throws {
        guard !connection.id.isEmpty, connection.id.count <= 200, connection.name.count <= 512,
              connection == Self.portable(connection), workspaces.count <= 256,
              Set(workspaces.map(\.id)).count == workspaces.count,
              workspaces.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 200 && $0.runtime.serverId == connection.id
                  && ($0.runtime.sandbox?.isValid ?? true) }) else { throw ConnectionSyncError.invalidBackup }
        if let remote = connection.remote {
            _ = try ServerDraft(editing: remote).normalizedRemote()
            if let reference = remote.auth.secretReference {
                let base = KeychainKey.serverSecret(remote.id)
                guard reference == base || reference == KeychainKey.serverKey(remote.id)
                    || reference.hasPrefix(base + ".") && UUID(uuidString: String(reference.dropFirst(base.count + 1))) != nil
                else { throw ConnectionSyncError.invalidBackup }
            }
        } else {
            guard let computer = connection.pairedComputer,
                  !computer.computerId.isEmpty, computer.computerId.count <= 128,
                  !computer.registryId.isEmpty, computer.registryId.count <= 200,
                  computer.deviceId.isEmpty, !computer.routes.isEmpty, computer.routes.count <= 12,
                  computer.routes.allSatisfy(\.isValid), computer.discovery?.isValid != false,
                  Self.isFingerprint(computer.fingerprint) else { throw ConnectionSyncError.invalidBackup }
        }
        if let sshHostKey, !Self.isFingerprint(sshHostKey) { throw ConnectionSyncError.invalidBackup }
    }

    static func isFingerprint(_ value: String) -> Bool {
        value.range(of: "^SHA256:[A-Za-z0-9+/]{43}$", options: .regularExpression) != nil
    }

    static func hostKeyReference(_ remote: RemoteHostConnection) -> String {
        "ssh.host." + Data("\(remote.host.lowercased()):\(remote.port)".utf8).base64EncodedString()
    }
}

extension SshAuthMethod {
    var secretReference: String? {
        switch self { case .key(let ref), .password(let ref): ref; case .agent: nil }
    }
}

enum BackupPreferenceValue: Codable, Equatable {
    case string(String), bool(Bool), number(Double)

    var object: Any {
        switch self { case .string(let v): v; case .bool(let v): v; case .number(let v): v }
    }
}

/// Explicit allowlist: no tokens, project replicas, notification registrations,
/// terminal state or chat caches can accidentally enter a preference backup.
enum BackupPreferences {
    static let strings = ["mindwire.appearance", StorageKey.chatTextSize, StorageKey.locale,
                          "mindwire.files.layout", "mindwire.files.density", "mindwire.desktop.pointerMode"]
    static let booleans = [StorageKey.automaticServiceUpdates, "mindwire.desktop.alignTop"]
    static let numbers = ["mindwire.editor.fontSize"]
    static let library = ["projects.view", "projects.layout", "projects.sort"]

    static func validate(key: String, value: BackupPreferenceValue) -> Bool {
        switch value {
        case .string(let text): (strings.contains(key) || library.contains(key)) && text.utf8.count <= 128
        case .bool: booleans.contains(key)
        case .number(let number): numbers.contains(key) && number.isFinite && (8...48).contains(number)
        }
    }

    @MainActor static func values(in stores: Stores) -> [String: BackupPreferenceValue] {
        var values: [String: BackupPreferenceValue] = [:]
        for key in strings { if let value = stores.defaults.string(forKey: key) { values[key] = .string(value) } }
        for key in booleans where stores.defaults.object(forKey: key) != nil { values[key] = .bool(stores.defaults.bool(forKey: key)) }
        for key in numbers where stores.defaults.object(forKey: key) != nil { values[key] = .number(stores.defaults.double(forKey: key)) }
        values["projects.view"] = .string(stores.projectLibrary.view.rawValue)
        values["projects.layout"] = .string(stores.projectLibrary.layout.rawValue)
        values["projects.sort"] = .string(stores.projectLibrary.sort.rawValue)
        return values
    }

    @MainActor static func apply(key: String, value: BackupPreferenceValue, to stores: Stores) {
        guard validate(key: key, value: value) else { return }
        switch (key, value) {
        case ("projects.view", .string(let raw)):
            if let value = ProjectLibraryView(rawValue: raw), stores.projectLibrary.view != value { stores.projectLibrary.setView(value) }
        case ("projects.layout", .string(let raw)):
            if let value = ProjectLibraryLayout(rawValue: raw), stores.projectLibrary.layout != value { stores.projectLibrary.setLayout(value) }
        case ("projects.sort", .string(let raw)):
            if let value = ProjectLibrarySort(rawValue: raw), stores.projectLibrary.sort != value { stores.projectLibrary.setSort(value) }
        default: stores.defaults.set(value.object, forKey: key)
        }
    }
}

enum ConnectionSyncPayload: Codable, Equatable {
    case connection(ConnectionBackup)
    case preference(key: String, value: BackupPreferenceValue)
    case settings(syncCredentials: Bool)

    var id: String {
        switch self {
        case .connection(let backup): "connection." + ConnectionSyncRecord.digest(backup.connection.id)
        case .preference(let key, _): "preference." + ConnectionSyncRecord.digest(key)
        case .settings: "settings"
        }
    }

    func validate() throws {
        switch self {
        case .connection(let backup): try backup.validate()
        case .preference(let key, let value):
            guard BackupPreferences.validate(key: key, value: value) else { throw ConnectionSyncError.invalidBackup }
        case .settings: break
        }
    }
}

struct ConnectionSyncRecord: Codable, Equatable {
    var version = 1
    let id: String
    let clock: Int64
    let changeID: String
    var payload: ConnectionSyncPayload? // durable tombstone when nil

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func isNewer(than other: Self) -> Bool {
        clock != other.clock ? clock > other.clock : changeID > other.changeID
    }

    func validate() throws {
        guard version == 1, clock >= 0, UUID(uuidString: changeID) != nil,
              id == "settings" || id.range(of: "^(connection|preference)\\.[a-f0-9]{64}$", options: .regularExpression) != nil,
              payload == nil || payload?.id == id else { throw ConnectionSyncError.invalidBackup }
        try payload?.validate()
    }
}

/// The durable outbox and received records commit in the same local write.
/// Per-item logical clocks retain deletions and resolve offline edits consistently.
struct ConnectionSyncReplica: Codable {
    var accountID: String?
    var records: [String: ConnectionSyncRecord] = [:]
    var pending: Set<String> = []
    var unapplied: Set<String> = []
    var systemFields: [String: Data] = [:]
    var engineState: Data?
    var clock: Int64 = 0
    var lastSyncedAt: Date?

    mutating func edit(_ payload: ConnectionSyncPayload, now: Date = .now) {
        guard records[payload.id]?.payload != payload else { return }
        change(id: payload.id, payload: payload, now: now)
    }

    mutating func remove(_ id: String, now: Date = .now) {
        guard records[id]?.payload != nil else { return }
        change(id: id, payload: nil, now: now)
    }

    private mutating func change(id: String, payload: ConnectionSyncPayload?, now: Date) {
        clock = max(clock + 1, Int64(now.timeIntervalSince1970 * 1000))
        records[id] = ConnectionSyncRecord(id: id, clock: clock, changeID: UUID().uuidString, payload: payload)
        pending.insert(id)
    }

    @discardableResult mutating func receive(_ remote: ConnectionSyncRecord) throws -> Bool {
        try remote.validate()
        clock = max(clock, remote.clock)
        if let local = records[remote.id], local != remote, !remote.isNewer(than: local) {
            pending.insert(local.id)
            return false
        }
        let changed = records[remote.id] != remote
        records[remote.id] = remote
        pending.remove(remote.id)
        return changed
    }
}

enum ConnectionSyncError: LocalizedError {
    case invalidBackup, unavailable, accountChanged, keychain, storage, newerVersion
    var errorDescription: String? {
        switch self {
        case .invalidBackup: "This backup could not be verified. Your saved connections have been kept."
        case .unavailable: "Sign in to iCloud in Settings and enable iCloud Drive to sync your connections."
        case .accountChanged: "Your Apple Account changed. Turn on sync to use this account. Your local connections are kept."
        case .keychain: "Secure storage is unavailable. Unlock this device and try again."
        case .storage: "The sync state could not be saved. Your previous backup is kept."
        case .newerVersion: "This backup needs a newer version of Mindwire. Update the app before restoring it."
        }
    }
}
