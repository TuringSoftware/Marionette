// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LocalAuthentication
import Security

/// Stores secrets as generic passwords in the Keychain, available after first unlock, kept as each
/// secret's ``SecretProtection`` says. Nothing here ever shows an authentication prompt: a secret
/// that needs the owner is read with the context of a ``SecretAccess`` they agreed through.
public struct KeychainSecretStore: SecretStore {
    public var service: String

    public init(service: String = "llc.turing.Marionette") {
        self.service = service
    }

    /// SSH key descriptions are filed under a service of their own, so that listing them reads
    /// nothing else.
    private func service(for kind: SecretKey.Kind) -> String {
        kind == .sshKeyInfo ? "\(service).ssh-keys" : service
    }

    /// Matches the item whether or not it is in iCloud Keychain, and never asks for the owner.
    private func query(_ key: SecretKey, context: LAContext? = nil) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service(for: key.kind),
            kSecAttrAccount: key.account,
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecUseAuthenticationContext: context ?? AuthenticationContext.silent(),
        ]
    }

    public func secret(for key: SecretKey, access: SecretAccess?) throws -> String? {
        var query = query(key, context: access?.context?.current)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw SecretStoreError.authenticationRequired
        default:
            throw SecretStoreError.storeFailure(code: status)
        }
    }

    public func setSecret(_ secret: String, for key: SecretKey, protection: SecretProtection) throws {
        // Whether an item synchronises and what guards it are fixed when it is added, so it is
        // replaced. If the new one cannot be added, the old one is put back as it was, when it
        // could be read without asking anyone.
        let previous = try storedItem(key)
        try removeSecret(for: key)
        var attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service(for: key.kind),
            kSecAttrAccount: key.account,
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: protection.synchronizes,
            kSecValueData: Data(secret.utf8),
        ]
        let accessible = protection.includedInBackups ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if protection.requiresUserPresence {
            guard let control = SecAccessControlCreateWithFlags(nil, accessible, .userPresence, nil) else {
                throw SecretStoreError.storeFailure(code: errSecParam)
            }
            attributes[kSecAttrAccessControl] = control
        } else {
            attributes[kSecAttrAccessible] = accessible
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            if let previous { SecItemAdd(previous as CFDictionary, nil) }
            throw SecretStoreError.storeFailure(code: status)
        }
    }

    /// The stored item for `key`, as attributes that add it again unchanged; `nil` when there is
    /// none, or its secret cannot be read without the owner.
    private func storedItem(_ key: SecretKey) throws -> [CFString: Any]? {
        var match = query(key)
        match[kSecReturnAttributes] = true
        match[kSecReturnData] = true
        match[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(match as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let found = result as? [CFString: Any], let data = found[kSecValueData] else { return nil }
            var item: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service(for: key.kind),
                kSecAttrAccount: key.account,
                kSecUseDataProtectionKeychain: true,
                kSecAttrSynchronizable: found[kSecAttrSynchronizable] ?? false,
                kSecValueData: data,
            ]
            if let control = found[kSecAttrAccessControl] {
                item[kSecAttrAccessControl] = control
            } else if let accessible = found[kSecAttrAccessible] {
                item[kSecAttrAccessible] = accessible
            }
            return item
        case errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return nil
        default:
            throw SecretStoreError.storeFailure(code: status)
        }
    }

    public func removeSecret(for key: SecretKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.storeFailure(code: status)
        }
    }

    public func names(of kind: SecretKey.Kind) throws -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service(for: kind),
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecUseAuthenticationContext: AuthenticationContext.silent(),
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let prefix = SecretKey(appWide: kind, name: "").account
            let accounts = (result as? [[CFString: Any]] ?? []).compactMap { $0[kSecAttrAccount] as? String }
            return accounts.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        case errSecItemNotFound:
            return []
        default:
            throw SecretStoreError.storeFailure(code: status)
        }
    }
}
