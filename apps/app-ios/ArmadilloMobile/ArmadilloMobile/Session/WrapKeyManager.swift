import Foundation
import CryptoKit
import Security

enum WrapKeyManagerError: Error {
    case keychainError(OSStatus)
    case invalidKeyData
}

enum WrapKeyManager {
    private static let keyTag = "com.armadillo.wrapkey.v1"

    static func getOrCreatePrivateKey() throws -> P256.KeyAgreement.PrivateKey {
        if let existing = try? loadPrivateKey() {
            return existing
        }
        let key = P256.KeyAgreement.PrivateKey()
        try storePrivateKey(key)
        return key
    }

    static func publicKeyBase64(x963: Bool = false) throws -> String {
        let sk = try getOrCreatePrivateKey()
        if x963 {
            return sk.publicKey.x963Representation.base64EncodedString()
        } else {
            return sk.publicKey.rawRepresentation.base64EncodedString()
        }
    }

    // MARK: - Keychain

    private static func loadPrivateKey() throws -> P256.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw WrapKeyManagerError.keychainError(status)
        }
        guard let sk = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            throw WrapKeyManagerError.invalidKeyData
        }
        return sk
    }

    private static func storePrivateKey(_ key: P256.KeyAgreement.PrivateKey) throws {
        let data = key.rawRepresentation
        // Remove any existing
        let delQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag
        ]
        SecItemDelete(delQuery as CFDictionary)

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw WrapKeyManagerError.keychainError(status) }
    }
}


