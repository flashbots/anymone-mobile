import AnymoneKit
import Foundation
import Security

/// Keychain-backed identity storage.
///
/// `afterFirstUnlockThisDeviceOnly` is what the client needs and no more: the
/// item is readable while the app runs in the background after one unlock, never
/// leaves this device, and is absent from backups and device transfers. Losing it
/// means losing the identity, which is the intended trade — a copied identity is
/// worse than a lost one.
final class KeychainSecretStore: SecretStore {
    private let account = "net.flashbots.anymone.identity"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "anymone",
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw SecretStoreError.Failed(message: "keychain returned no data")
            }
            return data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            // Before first unlock; retrying after unlock is the fix, and minting
            // a new identity here would silently abandon the enrolled one.
            throw SecretStoreError.Unavailable(message: "device locked since boot")
        default:
            throw SecretStoreError.Failed(message: "keychain read failed: \(status)")
        }
    }

    func store(secrets: Data) throws {
        var item = query
        item[kSecValueData as String] = secrets
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.Failed(message: "keychain write failed: \(status)")
        }
    }
}
