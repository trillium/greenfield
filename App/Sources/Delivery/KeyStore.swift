import Foundation
import Security

/// Where each Mac's secret key lives. Keys never go in preferences, logs or the outbox.
protocol KeyStore: Sendable {
    func key(for id: UUID) -> String?
    func setKey(_ key: String?, for id: UUID) throws
}

/// In-memory keys, for tests and previews.
final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: String] = [:]

    func key(for id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[id]
    }

    func setKey(_ key: String?, for id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        keys[id] = key
    }
}

/// Keychain generic passwords, one per Mac: readable after the first unlock (so a locked phone can still resend), this device only.
struct KeychainKeyStore: KeyStore {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error \(status)" }
    }

    var service = "dictation.mac-key"

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    func key(for id: UUID) -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setKey(_ key: String?, for id: UUID) throws {
        let status: OSStatus
        if let key, !key.isEmpty {
            var attributes = query(id)
            attributes[kSecValueData as String] = Data(key.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemDelete(query(id) as CFDictionary)
            status = SecItemAdd(attributes as CFDictionary, nil)
        } else {
            let removed = SecItemDelete(query(id) as CFDictionary)
            status = removed == errSecItemNotFound ? errSecSuccess : removed
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
}
