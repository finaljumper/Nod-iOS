import Foundation
import Security

/// One secret in the Keychain. It stays on this device: it is not synced and not included in
/// backups that are restored to another device.
struct KeychainStore {
    var service = "com.example.NodCompanion.nod"
    var account = "authentication-key"

    struct Failure: Error {
        var status: OSStatus
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func save(_ secret: String) throws {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func read() -> String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    var exists: Bool {
        var item = query
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(item as CFDictionary, nil) == errSecSuccess
    }

    func remove() {
        SecItemDelete(query as CFDictionary)
    }
}
