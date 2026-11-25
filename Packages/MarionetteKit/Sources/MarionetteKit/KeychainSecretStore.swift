// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Stores secrets as generic passwords in the Keychain, available after first unlock and never
/// synchronised or included in device-to-device migration.
public struct KeychainSecretStore: SecretStore {
    public var service: String

    public init(service: String = "llc.turing.Marionette") {
        self.service = service
    }

    private func baseQuery(_ key: SecretKey) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.account,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    public func secret(for key: SecretKey) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.storeFailure(code: status)
        }
    }

    public func setSecret(_ secret: String, for key: SecretKey) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(baseQuery(key) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.storeFailure(code: update) }
        var attributes = baseQuery(key)
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.storeFailure(code: status) }
    }

    public func removeSecret(for key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.storeFailure(code: status)
        }
    }
}
