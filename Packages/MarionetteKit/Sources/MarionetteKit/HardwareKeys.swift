// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
public import Foundation
import LocalAuthentication
import Security
import Synchronization

/// Makes and uses P-256 signing keys whose private half never leaves where it was made.
public protocol HardwareKeys: Sendable {
    var isAvailable: Bool { get }
    /// A new key. `handle` is what is stored to use it again, on this device only; `publicKey` is
    /// the public key in X9.63 form.
    func makeKey(requiresUserPresence: Bool) throws -> (handle: Data, publicKey: Data)
    /// The raw signature (`r` then `s`) of `data`, hashed with SHA-256; `nil` when the key refuses,
    /// as one that requires the owner does until they agreed through `access`.
    func sign(_ data: Data, handle: Data, access: SecretAccess?) -> Data?
}

/// Keys in this device's Secure Enclave.
public struct SecureEnclaveKeys: HardwareKeys {
    public init() {}

    public var isAvailable: Bool { SecureEnclave.isAvailable }

    public func makeKey(requiresUserPresence: Bool) throws -> (handle: Data, publicKey: Data) {
        var flags: SecAccessControlCreateFlags = .privateKeyUsage
        if requiresUserPresence { flags.insert(.userPresence) }
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil) else {
            throw SecretStoreError.storeFailure(code: errSecParam)
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: control)
        return (key.dataRepresentation, key.publicKey.x963Representation)
    }

    public func sign(_ data: Data, handle: Data, access: SecretAccess?) -> Data? {
        let context = access?.context?.current ?? AuthenticationContext.silent()
        guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle, authenticationContext: context) else { return nil }
        return try? key.signature(for: data).rawRepresentation
    }
}

/// Ordinary keys that behave as hardware ones do, for tests and the simulated environment.
public struct SimulatedHardwareKeys: HardwareKeys {
    public init() {}

    public var isAvailable: Bool { true }

    public func makeKey(requiresUserPresence: Bool) throws -> (handle: Data, publicKey: Data) {
        let key = P256.Signing.PrivateKey()
        return (Data([requiresUserPresence ? 1 : 0]) + key.rawRepresentation, key.publicKey.x963Representation)
    }

    public func sign(_ data: Data, handle: Data, access: SecretAccess?) -> Data? {
        guard let flag = handle.first, let key = try? P256.Signing.PrivateKey(rawRepresentation: handle.dropFirst()) else { return nil }
        if flag == 1, access?.isGranted != true { return nil }
        return try? key.signature(for: data).rawRepresentation
    }
}
