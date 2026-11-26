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
    /// A password is saved that only the device owner can read. The field stays empty, and
    /// ``password`` with it, until ``unlockPasswords()``; left so, the saved password is kept.
    public private(set) var isPasswordLocked = false
    /// The same for the SSH tunnel's password and ``tunnelPassword``.
    public private(set) var isTunnelPasswordLocked = false
    /// Why the last ``save()`` did not save.
    public var problem: String?
    /// A ``save()`` is under way, perhaps waiting for the owner.
    public private(set) var isSaving = false

    private let original: ComputerConfiguration
    private var originalPassword: String
    private var originalTunnelPassword: String
    private let repository: ComputerRepository
    private let secrets: any SecretStore
    private let clock: any AppClock
    /// Confirms the owner before a protected password is read.
    public let owner: OwnerAuthentication
    private let onSave: () -> Void

    init(
        configuration: ComputerConfiguration,
        isNew: Bool,
        repository: ComputerRepository,
        secrets: any SecretStore,
        clock: any AppClock,
        owner: OwnerAuthentication = .simulated,
        onSave: @escaping () -> Void
    ) {
        self.isNew = isNew
        var configuration = configuration
        // A key that is gone (deleted, or not restored to this device) is shown, and saved, as none.
        if let keyName = configuration.tunnel.keyName, Self.isAbsent(SecretKey(appWide: .sshKeyInfo, name: keyName), from: secrets) {
            configuration.tunnel.keyName = nil
        }
        self.configuration = configuration
        self.original = configuration
        self.repository = repository
        self.secrets = secrets
        self.clock = clock
        self.owner = owner
        self.onSave = onSave
        address = configuration.host
        portText = configuration.port.map(String.init) ?? ""
        tunnelPortText = configuration.tunnel.port == 22 ? "" : String(configuration.tunnel.port)
        secrets.migrateLegacySecrets(of: configuration)
        let (savedPassword, passwordLocked) = Self.load(.remoteDesktopPassword(for: configuration), from: secrets)
        let (savedTunnelPassword, tunnelPasswordLocked) = Self.load(.sshPassword(for: configuration, server: configuration.tunnelServer), from: secrets)
        isPasswordLocked = passwordLocked
        isTunnelPasswordLocked = tunnelPasswordLocked
        password = savedPassword
        tunnelPassword = savedTunnelPassword
        originalPassword = savedPassword
        originalTunnelPassword = savedTunnelPassword
    }

    /// Whether the store says there is nothing for `key`: not merely that it could not be read.
    private static func isAbsent(_ key: SecretKey, from secrets: any SecretStore) -> Bool {
        do {
            return try secrets.secret(for: key) == nil
        } catch {
            return false
        }
    }

    /// A saved password, without asking anyone: empty and locked when only the owner can read it.
    private static func load(_ key: SecretKey, from secrets: any SecretStore) -> (password: String, isLocked: Bool) {
        do {
            return (try secrets.secret(for: key) ?? "", false)
        } catch SecretStoreError.authenticationRequired {
            return ("", true)
        } catch {
            return ("", false)
        }
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

    public var canSave: Bool { isAddressValid && isPortValid && isTunnelPortValid && !isSaving }

    /// Whether a password is saved or typed, the remote-desktop one or the SSH tunnel's, which the
    /// Password Security options apply to.
    public var hasPassword: Bool {
        !password.isEmpty || isPasswordLocked || !tunnelPassword.isEmpty || isTunnelPasswordLocked
    }

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

    /// Asks the device owner once, then shows the saved passwords in their fields. Returns whether
    /// they are unlocked; if the owner declines, the fields stay empty and the passwords saved.
    @discardableResult
    public func unlockPasswords() async -> Bool {
        guard isPasswordLocked || isTunnelPasswordLocked else { return true }
        let access = owner.makeAccess()
        let reason = String(localized: "Show the saved passwords of “\(original.displayName)”.", bundle: #bundle)
        func unlock(_ key: SecretKey) async -> String? {
            (try? await secrets.unlockedSecret(for: key, access: access, reason: reason)) ?? nil
        }
        if isPasswordLocked {
            guard let saved = await unlock(.remoteDesktopPassword(for: original)) else { return false }
            isPasswordLocked = false
            // Unlocking is not editing: the form has no more changes than before.
            if password.isEmpty { password = saved }
            originalPassword = saved
        }
        if isTunnelPasswordLocked {
            guard let saved = await unlock(.sshPassword(for: original, server: original.tunnelServer)) else { return false }
            isTunnelPasswordLocked = false
            if tunnelPassword.isEmpty { tunnelPassword = saved }
            originalTunnelPassword = saved
        }
        return true
    }

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

    /// Stores the computer and its secrets. Returns the saved configuration, or `nil` when it is
    /// invalid or a protected password the new Password Security applies to stayed locked
    /// (``problem`` says so). Password Security applies to both of the computer's passwords.
    @discardableResult
    public func save() async -> ComputerConfiguration? {
        guard canSave else { return nil }
        isSaving = true
        defer { isSaving = false }
        var result = resolved()
        // Nothing can be required on a device without a passcode.
        if owner.check() == .unavailable { result.passwordProtection.requiresUserPresence = false }
        let passwordKey = SecretKey.remoteDesktopPassword(for: result)
        let tunnelPasswordKey = SecretKey.sshPassword(for: result, server: result.tunnelServer)
        let protectionChanged = result.passwordProtection != original.passwordProtection
        // A locked password that stays where it is must be read to be stored the new way.
        let mustUnlock = (passwordKey == .remoteDesktopPassword(for: original) && isPasswordLocked && password.isEmpty)
            || (tunnelPasswordKey == .sshPassword(for: original, server: original.tunnelServer) && isTunnelPasswordLocked && tunnelPassword.isEmpty)
        if protectionChanged, mustUnlock, await !unlockPasswords() {
            problem = String(localized: "Password Security can’t change without unlocking the saved passwords.", bundle: #bundle)
            return nil
        }
        problem = nil
        repository.save(result, now: clock.now)
        store(
            password, original: originalPassword, for: passwordKey, was: .remoteDesktopPassword(for: original),
            protection: result.passwordProtection, keepsLocked: isPasswordLocked, rewrite: protectionChanged
        )
        store(
            tunnelPassword, original: originalTunnelPassword,
            for: tunnelPasswordKey, was: .sshPassword(for: original, server: original.tunnelServer),
            protection: result.passwordProtection, keepsLocked: isTunnelPasswordLocked, rewrite: protectionChanged
        )
        if SecretKey.provenIdentity(for: result) != .provenIdentity(for: original) {
            // Another address may be another machine: it has proved nothing yet, and what it
            // encrypts is its own affair.
            try? secrets.removeSecret(for: .provenIdentity(for: original))
            try? secrets.removeSecret(for: .encryptedBefore(for: original))
        } else if protectionChanged {
            // The marks go where the password goes, so that a device it reaches knows them too.
            for mark in [SecretKey.provenIdentity(for: result), .encryptedBefore(for: result)] {
                if let value = (try? secrets.secret(for: mark)) ?? nil {
                    try? secrets.setSecret(value, for: mark, protection: result.passwordProtection.withoutUserPresence)
                }
            }
        }
        onSave()
        return result
    }

    /// Saves a password for the address it now goes to. A password is filed by address, and one
    /// shown in the form for the old address is not sent to a new one unless the user typed it
    /// again: an edited address may be another machine. An empty field removes the password,
    /// unless it was never unlocked (`keepsLocked`). `rewrite` stores it again as `protection` says.
    private func store(
        _ secret: String, original: String, for key: SecretKey, was oldKey: SecretKey,
        protection: SecretProtection, keepsLocked: Bool, rewrite: Bool
    ) {
        if key != oldKey {
            try? secrets.removeSecret(for: oldKey)
            guard secret != original else { return }
        }
        if secret.isEmpty {
            if !keepsLocked { try? secrets.removeSecret(for: key) }
        } else if secret != original || rewrite {
            try? secrets.setSecret(secret, for: key, protection: protection)
        }
    }
}
