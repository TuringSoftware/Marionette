// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
import Observation

/// The form that makes a new SSH key or brings in an existing one. Nothing is stored until
/// ``save()``.
@MainActor
@Observable
public final class SSHKeyFormModel: Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A key made here.
        case new
        /// A private key the user pastes or picks from a file.
        case importing
    }

    public let id = UUID()
    public let kind: Kind
    /// Empty means a generic name (``namePlaceholder``).
    public var name = ""
    public var type: SSHKeyType = .ed25519 {
        didSet { if type != oldValue { bits = type.defaultSize } }
    }
    public var bits = SSHKeyType.ed25519.defaultSize
    public var storage = SSHKeyStorage()
    /// The private key to import, pasted or read from a file.
    public var text = ""
    /// Why the last ``save()`` failed.
    public private(set) var problem: String?
    public private(set) var isSaving = false

    private let store: SSHKeyStore
    /// How the device confirms its owner, which names the option that requires it.
    public let ownerCheck: OwnerCheck

    public init(kind: Kind, store: SSHKeyStore, ownerCheck: OwnerCheck) {
        self.kind = kind
        self.store = store
        self.ownerCheck = ownerCheck
    }

    /// What will be made: always ECDSA P-256 in the Secure Enclave.
    public var algorithm: SSHKeyAlgorithm {
        storage.isInSecureEnclave ? .secureEnclave : SSHKeyAlgorithm(type: type, bits: bits)
    }

    /// Only a new key can be made in the Secure Enclave, and only where there is one.
    public var offersSecureEnclave: Bool { kind == .new && store.hardware.isAvailable }

    /// The name the key gets if the field is left empty.
    public var namePlaceholder: String {
        store.availableName(basedOn: kind == .new ? SSHKeyStore.defaultName(for: algorithm, storage: storage) : SSHKeyStore.defaultImportName)
    }

    public var canSave: Bool {
        !isSaving && (kind == .new || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Fills the paste box with a key file's contents, if the file holds a private key; otherwise
    /// says why not and leaves the box as it was.
    public func loadFile(at url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        // A key file is a few kilobytes; anything far larger is not one.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1 << 20,
              let data = try? Data(contentsOf: url), let contents = String(data: data, encoding: .utf8)
        else {
            problem = SSHKeyError.notAPrivateKey.message
            return
        }
        do throws(SSHKeyError) {
            _ = try SSHPrivateKeyFile(text: contents)
            text = contents
            problem = nil
        } catch {
            problem = error.message
        }
    }

    /// Makes or imports the key. Returns it, or `nil` with ``problem`` saying why not.
    @discardableResult
    public func save() async -> SSHKeyInfo? {
        guard canSave else { return nil }
        isSaving = true
        defer { isSaving = false }
        var storage = storage
        // Nothing can be required on a device without a passcode.
        if ownerCheck == .unavailable { storage.protection.requiresUserPresence = false }
        let (store, kind, name, text, algorithm) = (store, kind, name, text, algorithm)
        // A large RSA key takes a moment to make; the form stays responsive meanwhile.
        let result = await Task.detached { () -> Result<SSHKeyInfo, SSHKeyError> in
            do throws(SSHKeyError) {
                return switch kind {
                case .new: .success(try store.generate(named: name, algorithm: algorithm, storage: storage))
                case .importing: .success(try store.importKey(named: name, text: text, protection: storage.protection))
                }
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let info):
            problem = nil
            return info
        case .failure(let error):
            problem = error.message
            return nil
        }
    }
}
