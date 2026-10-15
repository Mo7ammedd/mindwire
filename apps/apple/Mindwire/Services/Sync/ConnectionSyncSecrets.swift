import Foundation
import Security

protocol ConnectionSyncSecrets {
    func local(_ key: String) -> String?
    @discardableResult func setLocal(_ value: String, key: String) -> Bool
    @discardableResult func removeLocal(_ key: String) -> Bool
    func synced(_ reference: String, account: String) -> String?
    func setSynced(_ value: String, reference: String, account: String) throws
    func removeSynced(reference: String, account: String) throws
    func removeAllSynced(account: String) throws
}

struct KeychainConnectionSyncSecrets: ConnectionSyncSecrets {
    private let service = "com.oblien.mindwire.synced-credentials"

    func local(_ key: String) -> String? { Keychain.get(key) }
    func setLocal(_ value: String, key: String) -> Bool { Keychain.set(value, for: key) }
    func removeLocal(_ key: String) -> Bool { Keychain.delete(key) }

    private func query(reference: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: ConnectionSyncRecord.digest(account) + "." + reference,
         kSecAttrSynchronizable as String: true]
    }

    func synced(_ reference: String, account: String) -> String? {
        var query = query(reference: reference, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSynced(_ value: String, reference: String, account: String) throws {
        // Paired computers are independent phone identities, never cloud credentials.
        guard reference.hasPrefix("mindwire.server."), !value.isEmpty else { throw ConnectionSyncError.invalidBackup }
        let query = query(reference: reference, account: account)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else { throw ConnectionSyncError.keychain }
        var item = query
        item.merge(attributes) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess || added == errSecDuplicateItem
            && SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
        else { throw ConnectionSyncError.keychain }
    }

    func removeSynced(reference: String, account: String) throws {
        let result = SecItemDelete(query(reference: reference, account: account) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw ConnectionSyncError.keychain }
    }

    func removeAllSynced(account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: true,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw ConnectionSyncError.keychain }
        let prefix = ConnectionSyncRecord.digest(account) + "."
        for item in items {
            guard let name = item[kSecAttrAccount as String] as? String, name.hasPrefix(prefix) else { continue }
            try removeSynced(reference: String(name.dropFirst(prefix.count)), account: account)
        }
    }
}

extension PairedComputer {
    var deviceIdentityReference: String { "computer.\(computerId).identity" }
    var needsDeviceApproval: Bool { deviceId.isEmpty }

    func matchesComputer(_ other: PairedComputer) -> Bool {
        computerId == other.computerId && registryId == other.registryId && fingerprint == other.fingerprint
    }
}

/// Restore a saved connection with this phone's credentials, never another phone's
/// approval. Retained Keychain metadata also makes a same-phone reinstall resumable.
extension ConnectionBackup {
    func restored(existing: Connection?, secrets: any ConnectionSyncSecrets) throws -> Connection {
        try validate()
        if let remote = connection.remote, let sshHostKey {
            let ref = Self.hostKeyReference(remote)
            if let saved = secrets.local(ref), saved != sshHostKey { throw ComputerConnectionError.identityChanged }
            guard secrets.setLocal(sshHostKey, key: ref) else { throw ConnectionSyncError.keychain }
        }
        guard case .local(var local) = connection, let portable = local.computer else { return connection }
        let retained = secrets.local(portable.deviceIdentityReference)?.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(PairedComputer.self, from: $0) }
        if let old = existing?.pairedComputer, !old.matchesComputer(portable) { throw ComputerConnectionError.identityChanged }
        if let saved = existing?.pairedComputer ?? retained,
           saved.matchesComputer(portable), !saved.deviceId.isEmpty,
           secrets.local(saved.keyRef) != nil, secrets.local(saved.tokenRef) != nil {
            local.computer = PairedComputer(computerId: portable.computerId, registryId: portable.registryId,
                deviceId: saved.deviceId, fingerprint: portable.fingerprint, routes: portable.routes,
                keyRef: saved.keyRef, tokenRef: saved.tokenRef, operatingSystem: portable.operatingSystem,
                connection: portable.connection, discovery: portable.discovery)
        }
        return .local(local)
    }
}
