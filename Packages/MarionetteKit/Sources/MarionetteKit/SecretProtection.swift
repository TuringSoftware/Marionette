// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LocalAuthentication
import Synchronization

// MARK: - Protection

/// How a secret is kept: whether reading it needs the device owner, and where copies of it may go.
///
/// The options depend on each other, and setting one adjusts the others: iCloud Keychain carries
/// only items that may leave the device and that no access control guards.
public struct SecretProtection: Sendable, Hashable, Codable {
    private var presence: Bool
    private var backups: Bool
    private var sync: Bool

    public init(requiresUserPresence: Bool = false, includedInBackups: Bool = true, synchronizes: Bool = false) {
        presence = false
        backups = false
        sync = false
        // In this order, a conflicting combination resolves to the one that keeps the secret closer.
        self.synchronizes = synchronizes
        self.includedInBackups = includedInBackups
        self.requiresUserPresence = requiresUserPresence
    }

    /// Reading the secret needs Face ID, Touch ID, Optic ID or the device passcode. Turning it on
    /// takes the secret out of iCloud Keychain.
    public var requiresUserPresence: Bool {
        get { presence }
        set {
            presence = newValue
            if newValue { sync = false }
        }
    }

    /// The secret is in encrypted backups of this device, and so moves to a device restored from
    /// one. Turning it off keeps the secret on this device, out of iCloud Keychain too.
    public var includedInBackups: Bool {
        get { backups }
        set {
            backups = newValue
            if !newValue { sync = false }
        }
    }

    /// The secret is in iCloud Keychain, on every device signed in to the same Apple Account.
    /// Turning it on also includes it in backups and drops the owner check.
    public var synchronizes: Bool {
        get { sync }
        set {
            sync = newValue
            if newValue {
                backups = true
                presence = false
            }
        }
    }

    /// What a new password or key gets: on this device and in its backups, not in iCloud Keychain
    /// unless chosen.
    public static let standard = SecretProtection()

    /// On this device only, readable without the owner: what the app keeps for itself.
    public static let thisDeviceOnly = SecretProtection(includedInBackups: false, synchronizes: false)

    /// The same places, readable without the owner: for marks kept beside a password, which the app
    /// reads without asking.
    public var withoutUserPresence: SecretProtection {
        var copy = self
        copy.presence = false
        return copy
    }
}

// MARK: - Owner check

/// How this device confirms its owner, which names the option that requires it.
public enum OwnerCheck: Sendable, Hashable {
    case faceID
    case touchID
    case opticID
    case passcode
    /// No passcode is set, so nothing can be required.
    case unavailable

    /// The check by name: "Face ID", or "Passcode" where there is no biometry.
    public var name: String {
        switch self {
        case .faceID: String(localized: "Face ID", bundle: #bundle)
        case .touchID: String(localized: "Touch ID", bundle: #bundle)
        case .opticID: String(localized: "Optic ID", bundle: #bundle)
        case .passcode, .unavailable: String(localized: "Passcode", bundle: #bundle)
        }
    }

    /// The title of the option that requires the check.
    public var requirementTitle: String {
        switch self {
        case .faceID: String(localized: "Require Face ID", bundle: #bundle)
        case .touchID: String(localized: "Require Touch ID", bundle: #bundle)
        case .opticID: String(localized: "Require Optic ID", bundle: #bundle)
        case .passcode, .unavailable: String(localized: "Require Passcode", bundle: #bundle)
        }
    }
}

/// The device owner's agreement to use protected secrets, asked for at most once while it lasts.
///
/// A session holds one for everything it unlocks: its saved password, its SSH key and the key's
/// passphrase. The first secret that needs the owner asks; the others then open without asking.
public final class SecretAccess: Sendable {
    public typealias Check = @Sendable (_ reason: String) async -> Bool

    private struct State {
        var isGranted = false
        var pending: Task<Bool, Never>?
    }

    private let check: Check
    private let state = Mutex(State())
    /// The authentication context the Keychain and the Secure Enclave are given, for the live one.
    let context: AuthenticationContext?

    /// For tests and the simulated environment: `check` stands in for asking the owner.
    public init(check: @escaping Check) {
        self.check = check
        context = nil
    }

    private init(context: AuthenticationContext) {
        self.context = context
        check = { reason in await context.evaluate(reason: reason) }
    }

    /// Asks the device owner through LocalAuthentication.
    public static func live() -> SecretAccess {
        SecretAccess(context: AuthenticationContext())
    }

    /// Never asks, and never agrees.
    public static var denied: SecretAccess { SecretAccess { _ in false } }

    /// Whether the owner has agreed.
    public var isGranted: Bool { state.withLock { $0.isGranted } }

    /// Asks the owner, unless they already agreed. Callers at the same time share one question.
    /// `reason` is shown where the system shows one (Touch ID and the passcode screen).
    public func authenticate(reason: String) async -> Bool {
        let task = state.withLock { state -> Task<Bool, Never>? in
            if state.isGranted { return nil }
            if let pending = state.pending { return pending }
            let check = check
            let task = Task { await check(reason) }
            state.pending = task
            return task
        }
        guard let task else { return true }
        let granted = await task.value
        state.withLock { state in
            if state.pending == task { state.pending = nil }
            if granted { state.isGranted = true }
        }
        return granted
    }

    /// Ends the agreement: protected secrets need the owner again.
    public func invalidate() {
        state.withLock { $0 = State() }
        context?.invalidate()
    }
}

/// An `LAContext` that never shows anything by itself: the Keychain and the Secure Enclave fail
/// rather than ask, and only ``evaluate(reason:)`` asks. Once it has, they use its answer.
///
/// Sendable because the context is replaced, and its `interactionNotAllowed` changed, only under
/// `lock`; `LAContext` itself may be used from any thread.
final class AuthenticationContext: @unchecked Sendable {
    private let lock = NSLock()
    private var context = AuthenticationContext.silent()

    static func silent() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    /// The context to hand to the Keychain or CryptoKit.
    var current: LAContext { lock.withLock { context } }

    func evaluate(reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let context = lock.withLock {
                self.context.interactionNotAllowed = false
                return self.context
            }
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                self.lock.withLock { self.context.interactionNotAllowed = true }
                continuation.resume(returning: success)
            }
        }
    }

    func invalidate() {
        lock.withLock {
            context.invalidate()
            context = Self.silent()
        }
    }
}

/// What the device offers to confirm its owner, and how a session asks.
public struct OwnerAuthentication: Sendable {
    /// What the device offers now. It changes when the owner sets or removes a passcode.
    public var check: @Sendable () -> OwnerCheck
    /// A new agreement, for one session or one change of settings.
    public var makeAccess: @Sendable () -> SecretAccess

    public init(check: @escaping @Sendable () -> OwnerCheck, makeAccess: @escaping @Sendable () -> SecretAccess) {
        self.check = check
        self.makeAccess = makeAccess
    }

    public static let live = OwnerAuthentication(
        check: {
            let context = LAContext()
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return .unavailable }
            // Biometry that is not enrolled still leaves the passcode.
            _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            return switch context.biometryType {
            case .faceID: .faceID
            case .touchID: .touchID
            case .opticID: .opticID
            default: .passcode
            }
        },
        makeAccess: { .live() }
    )

    /// A device with Face ID whose owner always agrees.
    public static let simulated = OwnerAuthentication(check: { .faceID }, makeAccess: { SecretAccess { _ in true } })
}
