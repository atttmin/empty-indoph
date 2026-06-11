//
//  KeychainStore.swift
//  Empty
//

import Foundation
import Security

nonisolated enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let code):
            "Keychain operation failed (\(code))."
        }
    }
}

/// Minimal generic-password store for provider API keys (BYOK).
/// Secrets never touch UserDefaults or the SwiftData stores.
///
/// Deliberately not using `kSecUseDataProtectionKeychain`: local Debug
/// builds may be ad-hoc signed (no keychain entitlement), and the login
/// keychain works for both signing styles on macOS; iOS always uses the
/// data-protection keychain anyway.
nonisolated enum KeychainStore {
    private static let service = "davirian.Empty.ai-provider"

    static func save(_ secret: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(secret.utf8)
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func read(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
