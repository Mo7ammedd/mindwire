import CommonCrypto
import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionFileBackup: Codable {
    var version = 1
    var createdAt = Date()
    var connections: [ConnectionBackup]
    var preferences: [String: BackupPreferenceValue]
    var credentials: [String: String]

    func validate() throws {
        guard version == 1 else { throw ConnectionFileError.newerVersion }
        guard connections.count <= 1_000, Set(connections.map { $0.connection.id }).count == connections.count,
              connections.reduce(0, { $0 + $1.workspaces.count }) <= 10_000,
              preferences.allSatisfy({ BackupPreferences.validate(key: $0.key, value: $0.value) }) else {
            throw ConnectionSyncError.invalidBackup
        }
        try connections.forEach { try $0.validate() }
        let allowed = Set(connections.compactMap { $0.connection.remote?.auth.secretReference })
        guard credentials.allSatisfy({ allowed.contains($0.key) && !$0.value.isEmpty && $0.value.utf8.count <= 128 * 1024 })
        else { throw ConnectionSyncError.invalidBackup }
    }

    @MainActor static func capture(stores: Stores, secrets: any ConnectionSyncSecrets, includeCredentials: Bool) throws -> Self {
        let connections = stores.connections.list().filter { $0.remote != nil || $0.pairedComputer != nil }.map { connection in
            ConnectionBackup(connection: connection, workspaces: stores.workspaces(forServerId: connection.id),
                sshHostKey: connection.remote.flatMap { secrets.local(ConnectionBackup.hostKeyReference($0)) })
        }
        var credentials: [String: String] = [:]
        if includeCredentials {
            for connection in connections {
                if let ref = connection.connection.remote?.auth.secretReference, let value = secrets.local(ref) { credentials[ref] = value }
            }
        }
        let backup = Self(connections: connections, preferences: BackupPreferences.values(in: stores), credentials: credentials)
        try backup.validate()
        return backup
    }

    @MainActor func credentialsToRestore(in stores: Stores, secrets: any ConnectionSyncSecrets) -> [String: String] {
        var result: [String: String] = [:]
        for backup in connections {
            guard let incoming = backup.connection.remote, let ref = incoming.auth.secretReference,
                  secrets.local(ref) == nil, let value = credentials[ref] else { continue }
            if let current = stores.connections.get(incoming.id)?.remote {
                // Renaming is harmless; a changed address, account or credential
                // reference may refer to another server and must keep its state.
                guard current.host.lowercased() == incoming.host.lowercased(), current.port == incoming.port,
                      current.username == incoming.username, current.auth == incoming.auth else { continue }
            } else if stores.connections.get(incoming.id) != nil { continue }
            result[incoming.id] = value
        }
        return result
    }

    /// Missing connections are added; existing connections and their current
    /// credentials win. No workspace command or remote deletion occurs.
    @MainActor func restore(to stores: Stores, secrets: any ConnectionSyncSecrets, restorePreferences: Bool) throws -> Int {
        try validate()
        try Self.finishPendingRestore(in: stores)
        let existing = stores.connections.list()
        let ids = Set(existing.map(\.id))
        let missing = connections.filter { !ids.contains($0.connection.id) }
        var restored: [Connection] = []
        var workspaces = stores.workspaces.list()
        for backup in missing {
            for workspace in backup.workspaces {
                if let current = workspaces.first(where: { $0.id == workspace.id }) {
                    guard current.runtime.serverId == backup.connection.id else { throw ConnectionSyncError.invalidBackup }
                } else { workspaces.append(workspace) }
            }
            restored.append(try backup.restored(existing: nil, secrets: secrets))
        }
        // Store credentials before publishing references. No working key is
        // replaced, including a key retained across reinstalling this device.
        let credentialValues = credentialsToRestore(in: stores, secrets: secrets)
        for connection in existing + restored {
            if let ref = connection.remote?.auth.secretReference, let value = credentialValues[connection.id] {
                guard secrets.setLocal(value, key: ref) else { throw ConnectionSyncError.keychain }
            }
        }
        let commit = RestoreCommit(connections: existing + restored, workspaces: workspaces,
            preferences: restorePreferences ? preferences : [:], credentialsChanged: Array(credentialValues.keys))
        let encoded = try JSONEncoder().encode(commit)
        stores.defaults.set(encoded, forKey: Self.restoreKey)
        try Self.finishPendingRestore(in: stores)
        return restored.count
    }

    // A single durable journal makes a multi-list restore replayable if iOS
    // terminates the app between its local writes. Secrets stay in Keychain.
    private static let restoreKey = "mindwire:connection-file-restore:v1"
    private struct RestoreCommit: Codable {
        var connections: [Connection]
        var workspaces: [Workspace]
        var preferences: [String: BackupPreferenceValue]
        var credentialsChanged: [String]?
    }
    @MainActor static func finishPendingRestore(in stores: Stores) throws {
        guard let data = stores.defaults.data(forKey: restoreKey) else { return }
        let commit = try JSONDecoder().decode(RestoreCommit.self, from: data)
        stores.connections.replaceAll(commit.connections)
        stores.workspaces.replaceAll(commit.workspaces)
        for (key, value) in commit.preferences { BackupPreferences.apply(key: key, value: value, to: stores) }
        stores.defaults.removeObject(forKey: restoreKey)
        NotificationCenter.default.post(name: .connectionLibraryRestored, object: stores,
            userInfo: ["credentialConnections": commit.credentialsChanged ?? []])
    }
}

/// A portable, authenticated file. Derivation runs off the UI thread; the file
/// provider receives ciphertext only, including when credentials are included.
enum ConnectionFileEncryption {
    static let maxFileBytes = 16 * 1024 * 1024
    private static let rounds = 600_000
    private static let context = Data("MindwireConnectionBackup:v1:pbkdf2-sha256:600000".utf8)
    private struct Envelope: Codable {
        var format = "MindwireConnectionBackup"
        var version = 1
        var iterations = rounds
        var salt: Data
        var sealed: Data
    }

    static func encrypt(_ backup: ConnectionFileBackup, password: String) throws -> Data {
        guard password.count >= 12, password.utf8.count <= 1_024 else { throw ConnectionFileError.passwordLength }
        try backup.validate()
        let plaintext = try JSONEncoder().encode(backup)
        guard plaintext.count <= 8 * 1024 * 1024 else { throw ConnectionFileError.tooLarge }
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(plaintext, using: key(password, salt: salt), authenticating: context)
        guard let combined = sealed.combined else { throw ConnectionSyncError.storage }
        return try JSONEncoder().encode(Envelope(salt: salt, sealed: combined))
    }

    static func decrypt(_ data: Data, password: String) throws -> ConnectionFileBackup {
        guard data.count <= maxFileBytes else { throw ConnectionFileError.tooLarge }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.format == "MindwireConnectionBackup" else {
            throw ConnectionSyncError.invalidBackup
        }
        guard envelope.version == 1 else { throw ConnectionFileError.newerVersion }
        guard envelope.iterations == rounds, envelope.salt.count == 32, envelope.sealed.count >= 28 else {
            throw ConnectionSyncError.invalidBackup
        }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            plaintext = try AES.GCM.open(box, using: key(password, salt: envelope.salt), authenticating: context)
        } catch { throw ConnectionFileError.cannotUnlock }
        guard plaintext.count <= 8 * 1024 * 1024 else { throw ConnectionFileError.tooLarge }
        let backup = try JSONDecoder().decode(ConnectionFileBackup.self, from: plaintext)
        try backup.validate()
        return backup
    }

    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxFileBytes else { throw ConnectionFileError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maxFileBytes else { throw ConnectionFileError.tooLarge }
        return data
    }

    private static func key(_ password: String, salt: Data) throws -> SymmetricKey {
        guard !password.isEmpty, password.utf8.count <= 1_024 else { throw ConnectionFileError.cannotUnlock }
        var pass = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = Data(count: 32)
        defer { pass.resetBytes(in: pass.indices); derived.resetBytes(in: derived.indices) }
        let status = pass.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self), passwordBytes.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                        output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw ConnectionSyncError.keychain }
        return SymmetricKey(data: derived)
    }
}

extension UTType {
    static let mindwireBackup = UTType(exportedAs: "com.oblien.mindwire.connection-backup", conformingTo: .data)
}

struct ConnectionBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.mindwireBackup] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ConnectionSyncError.invalidBackup }
        guard data.count <= ConnectionFileEncryption.maxFileBytes else { throw ConnectionFileError.tooLarge }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum ConnectionFileError: LocalizedError {
    case passwordLength, cannotUnlock, tooLarge, newerVersion
    var errorDescription: String? {
        switch self {
        case .passwordLength: "Use a backup password with at least 12 characters."
        case .cannotUnlock: "The password is incorrect or the backup is damaged. Try again."
        case .tooLarge: "This file is too large to be a connection backup."
        case .newerVersion: "Update Mindwire to open this newer backup format."
        }
    }
}
