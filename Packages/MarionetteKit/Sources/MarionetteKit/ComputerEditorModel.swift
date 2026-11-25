// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
import Observation

/// The add/edit form's state. Works on a copy; nothing is stored until ``save()``.
@MainActor
@Observable
public final class ComputerEditorModel: Identifiable {
    public let id = UUID()
    public let isNew: Bool
    public var configuration: ComputerConfiguration
    /// The address exactly as typed; split into host, port and user name when saved or committed.
    public var address: String
    /// Port as text so the field can be empty ("default").
    public var portText: String
    public var tunnelPortText: String
    public var password: String
    public var tunnelPassword: String

    private let original: ComputerConfiguration
    private let originalPassword: String
    private let originalTunnelPassword: String
    private let repository: ComputerRepository
    private let secrets: any SecretStore
    private let clock: any AppClock
    private let onSave: () -> Void

    init(
        configuration: ComputerConfiguration,
        isNew: Bool,
        repository: ComputerRepository,
        secrets: any SecretStore,
        clock: any AppClock,
        onSave: @escaping () -> Void
    ) {
        self.isNew = isNew
        self.configuration = configuration
        self.original = configuration
        self.repository = repository
        self.secrets = secrets
        self.clock = clock
        self.onSave = onSave
        address = configuration.host
        portText = configuration.port.map(String.init) ?? ""
        tunnelPortText = configuration.tunnel.port == 22 ? "" : String(configuration.tunnel.port)
        secrets.migrateLegacySecrets(of: configuration)
        let savedPassword = ((try? secrets.secret(for: .remoteDesktopPassword(for: configuration))) ?? nil) ?? ""
        let savedTunnelPassword = ((try? secrets.secret(for: .sshPassword(for: configuration, server: configuration.tunnelServer))) ?? nil) ?? ""
        password = savedPassword
        tunnelPassword = savedTunnelPassword
        originalPassword = savedPassword
        originalTunnelPassword = savedTunnelPassword
    }

    // MARK: Derived state

    public var title: String { isNew ? String(localized: "New Computer", bundle: #bundle) : String(localized: "Edit Computer", bundle: #bundle) }

    /// The name shown as the placeholder when the Name field is empty.
    public var namePlaceholder: String {
        ParsedAddress(address)?.host ?? String(localized: "Optional", bundle: #bundle)
    }

    public var isAddressValid: Bool { ParsedAddress(address) != nil }

    public var isPortValid: Bool { portText.isEmpty || (UInt16(portText) ?? 0) > 0 }
    public var isTunnelPortValid: Bool { tunnelPortText.isEmpty || (UInt16(tunnelPortText) ?? 0) > 0 }

    public var canSave: Bool { isAddressValid && isPortValid && isTunnelPortValid }

    public var hasChanges: Bool {
        resolved() != original || password != originalPassword || tunnelPassword != originalTunnelPassword
    }

    /// Shown under the address field once something invalid has been typed.
    public var addressProblem: String? {
        address.trimmingCharacters(in: .whitespaces).isEmpty || isAddressValid
            ? nil
            : String(localized: "Enter a host name or IP address.", bundle: #bundle)
    }

    public var isTunnelEnabled: Bool { configuration.tunnel.isEnabled }

    /// The mode the picker shows: forced to Standard while the tunnel is on, without losing the
    /// user's own choice for when it is turned off again.
    public var effectiveMode: ComputerConfiguration.Mode { configuration.effectiveMode }

    // MARK: Intents

    /// Moves a pasted `user@host:port` into the separate fields.
    public func commitAddress() {
        guard let parsed = ParsedAddress(address) else { return }
        address = parsed.host
        if let port = parsed.port { portText = String(port) }
        if let username = parsed.username, configuration.username.isEmpty { configuration.username = username }
    }

    /// The configuration as it would be saved.
    public func resolved() -> ComputerConfiguration {
        var result = configuration
        if let parsed = ParsedAddress(address) {
            result.host = parsed.host
            result.port = parsed.port ?? UInt16(portText)
            if let username = parsed.username, result.username.isEmpty { result.username = username }
        } else {
            result.host = address.trimmingCharacters(in: .whitespaces)
            result.port = UInt16(portText)
        }
        result.name = result.name.trimmingCharacters(in: .whitespaces)
        result.username = result.username.trimmingCharacters(in: .whitespaces)
        result.tunnel.port = UInt16(tunnelPortText) ?? 22
        result.tunnel.host = result.tunnel.host.trimmingCharacters(in: .whitespaces)
        result.tunnel.username = result.tunnel.username.trimmingCharacters(in: .whitespaces)
        return result
    }

    /// Stores the computer and its secrets. Returns the saved configuration, or `nil` when invalid.
    @discardableResult
    public func save() -> ComputerConfiguration? {
        guard canSave else { return nil }
        let result = resolved()
        repository.save(result, now: clock.now)
        store(password, original: originalPassword, for: .remoteDesktopPassword(for: result), was: .remoteDesktopPassword(for: original))
        store(
            tunnelPassword, original: originalTunnelPassword,
            for: .sshPassword(for: result, server: result.tunnelServer), was: .sshPassword(for: original, server: original.tunnelServer)
        )
        if SecretKey.provenIdentity(for: result) != .provenIdentity(for: original) {
            // Another address may be another machine: it has proved nothing yet, and what it
            // encrypts is its own affair.
            try? secrets.removeSecret(for: .provenIdentity(for: original))
            try? secrets.removeSecret(for: .encryptedBefore(for: original))
        }
        onSave()
        return result
    }

    /// Saves a password for the address it now goes to. A password is filed by address, and one
    /// shown in the form for the old address is not sent to a new one unless the user typed it
    /// again: an edited address may be another machine.
    private func store(_ secret: String, original: String, for key: SecretKey, was oldKey: SecretKey) {
        if key != oldKey {
            try? secrets.removeSecret(for: oldKey)
            guard secret != original else { return }
        }
        if secret.isEmpty {
            try? secrets.removeSecret(for: key)
        } else {
            try? secrets.setSecret(secret, for: key)
        }
    }
}
