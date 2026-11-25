// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
import Observation
public import RemoteDesktopCore

/// Answers a back end's questions for one session.
///
/// Credentials come from what the user already typed this session, then from the saved secret; only
/// when neither exists, or the server rejected them, does a prompt reach the interface. Secrets are
/// filed by the address they were saved for (``SecretKey/remoteDesktopPassword(for:)``), so a
/// computer whose address changed is asked again. An SSH key's passphrase is answered the same way
/// once the user has asked for it to be remembered, and a reconnect's first session-select offer
/// with the choice the Mac last accepted. Everything else (host keys, the server's own questions)
/// is always put to the user.
///
/// A rung of the connection ladder that uses another protocol than the computer's own (plain VNC
/// for a Mac) is never answered from the computer's saved or cached credentials: that protocol
/// proves nothing about the server and usually encrypts nothing.
@MainActor
@Observable
public final class PromptBroker: PromptHandler, FallbackPromptHandler {
    /// A question waiting for the user.
    public struct Pending: Identifiable, Sendable, Hashable {
        public let id: UUID
        public var prompt: SessionPrompt
        /// Asked by a rung that uses another protocol than the computer's own: the answer serves
        /// that rung for this session and is never saved.
        public var isFromFallbackRung: Bool
    }

    private struct Credentials: Equatable {
        var username: String
        var password: String
    }

    /// The prompt the interface should be showing, if any.
    public private(set) var pending: Pending?

    /// The computer being connected to. Its address decides which saved secrets apply.
    @ObservationIgnored var computer: ComputerConfiguration
    private let secrets: any SecretStore
    private var savedUsername: String
    private var continuation: CheckedContinuation<PromptResponse, Never>?
    /// What was last sent to the server, per secret; kept so a reconnect does not ask again.
    private var sessionCredentials: [SecretKey: Credentials] = [:]
    /// Secrets whose saved value is what ``sessionCredentials`` holds (rather than something typed).
    private var sentSaved: Set<SecretKey> = []
    /// Credentials the user asked to remember, stored once the connection succeeds.
    private var toRemember: [SecretKey: Credentials] = [:]
    /// Saved secrets that a server turned down, or that the user asked to replace: not offered
    /// again this session, and removed once something else has worked (unless that is kept instead).
    private var staleSaved: Set<SecretKey> = []
    /// What the user typed for a fallback rung, kept for that rung's reconnects only.
    private var fallbackCredentials: Credentials?
    /// Key passphrases that were sent, by key name; kept so a reconnect does not ask again.
    private var sessionPassphrases: [String: String] = [:]
    /// Key passphrases the user asked to remember, stored once the connection succeeds.
    private var passphrasesToRemember: [String: String] = [:]
    /// The session-select choice answered on the attempt under way, and the last one that led to a
    /// connection.
    private var pendingChoice: SessionChoice?
    private var acceptedChoice: SessionChoice?
    /// Called with the user name to save alongside a remembered password (empty when the service
    /// asked for a password only). For a computer that is not saved yet, remembering saves it.
    public var onRememberUsername: ((String) -> Void)?
    /// The computer is in the library. When it is not (connected straight from the network), the
    /// sign-in sheet offers to save it instead of only its password.
    public var isComputerSaved = true

    public init(computer: ComputerConfiguration, secrets: any SecretStore) {
        self.computer = computer
        self.savedUsername = computer.username
        self.secrets = secrets
        secrets.migrateLegacySecrets(of: computer)
    }

    // MARK: PromptHandler

    public nonisolated func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        await answer(prompt, onFallbackRung: false)
    }

    nonisolated func resolveOnFallbackRung(_ prompt: SessionPrompt) async -> PromptResponse {
        await answer(prompt, onFallbackRung: true)
    }

    private func answer(_ prompt: SessionPrompt, onFallbackRung: Bool) async -> PromptResponse {
        switch prompt {
        case .credentials(let request) where onFallbackRung && !request.context.isSSH:
            if request.attempt == 1, let known = fallbackCredentials {
                return .credentials(username: known.username, password: known.password)
            }
            fallbackCredentials = nil
            return await present(prompt, fromFallbackRung: true)
        case .credentials(let request):
            let key = secretKey(for: request.context)
            if request.attempt == 1 {
                if let known = sessionCredentials[key] {
                    return .credentials(username: known.username, password: known.password)
                }
                if !staleSaved.contains(key), let saved = savedCredentials(key: key, request: request) {
                    sessionCredentials[key] = saved
                    sentSaved.insert(key)
                    return .credentials(username: saved.username, password: saved.password)
                }
            } else {
                // Whatever was sent is wrong. Forget it so it is not offered again; a saved one
                // stays saved until something else has worked.
                if sentSaved.remove(key) != nil { staleSaved.insert(key) }
                sessionCredentials[key] = nil
                toRemember[key] = nil
            }
        case .keyPassphrase(let request):
            if request.attempt == 1 {
                if let known = sessionPassphrases[request.keyName] ?? savedPassphrase(for: request.keyName) {
                    sessionPassphrases[request.keyName] = known
                    return .passphrase(known)
                }
            } else {
                sessionPassphrases[request.keyName] = nil
                passphrasesToRemember[request.keyName] = nil
            }
        case .sessionSelect(let request):
            // A reconnect after a short drop should not wait on the chooser, in the background or
            // not: the Mac's first offer gets what it accepted last time. Once the person at the
            // Mac has turned a request down, the choice is the user's again.
            if !request.previousRequestDeclined, let choice = acceptedChoice, request.choices.contains(choice) {
                pendingChoice = choice
                return .sessionChoice(choice)
            }
        case .hostKey, .keyboardInteractive:
            break
        }
        return await present(prompt, fromFallbackRung: onFallbackRung)
    }

    private func savedPassphrase(for keyName: String) -> String? {
        guard let passphrase = try? secrets.secret(for: SecretKey(appWide: .keyPassphrase, name: keyName)), !passphrase.isEmpty else {
            return nil
        }
        return passphrase
    }

    private func savedCredentials(key: SecretKey, request: CredentialRequest) -> Credentials? {
        guard let password = savedSecret(key) else { return nil }
        let username = key.kind == .remoteDesktopPassword ? savedUsername : (request.suggestedUsername ?? savedUsername)
        if request.kind == .usernameAndPassword, username.isEmpty { return nil }
        return Credentials(username: username, password: password)
    }

    private func savedSecret(_ key: SecretKey) -> String? {
        guard let secret = (try? secrets.secret(for: key)) ?? nil, !secret.isEmpty else { return nil }
        return secret
    }

    private func present(_ prompt: SessionPrompt, fromFallbackRung: Bool) async -> PromptResponse {
        // A back end asks one question at a time; a second one replaces a stale first.
        finish(with: .cancel)
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancel)
                    return
                }
                self.continuation = continuation
                self.pending = Pending(id: id, prompt: prompt, isFromFallbackRung: fromFallbackRung)
            }
        } onCancel: {
            Task { @MainActor in
                if self.pending?.id == id { self.finish(with: .cancel) }
            }
        }
    }

    private func finish(with response: PromptResponse) {
        guard let continuation else { return }
        self.continuation = nil
        pending = nil
        continuation.resume(returning: response)
    }

    // MARK: Interface

    /// The user's answer to ``pending``. `remember` applies to credentials and passphrases.
    public func reply(_ response: PromptResponse, remember: Bool = false) {
        guard let pending else { return }
        switch (pending.prompt, response) {
        case (.credentials, .credentials(let username, let password)) where pending.isFromFallbackRung:
            fallbackCredentials = Credentials(username: username, password: password)
        case (.credentials(let request), .credentials(let username, let password)):
            let key = secretKey(for: request.context)
            let credentials = Credentials(username: username, password: password)
            sessionCredentials[key] = credentials
            sentSaved.remove(key)
            toRemember[key] = remember ? credentials : nil
        case (.keyPassphrase(let request), .passphrase(let passphrase)):
            sessionPassphrases[request.keyName] = passphrase
            passphrasesToRemember[request.keyName] = remember ? passphrase : nil
        case (.sessionSelect, .sessionChoice(let choice)):
            pendingChoice = choice
        default:
            break
        }
        finish(with: response)
    }

    /// Declines the pending prompt, which ends the connection attempt.
    public func cancelPending() {
        finish(with: .cancel)
    }

    /// The name to pre-fill in a credential prompt.
    public func suggestedUsername(for request: CredentialRequest) -> String {
        request.suggestedUsername ?? sessionCredentials[secretKey(for: request.context)]?.username ?? savedUsername
    }

    /// What was last sent to a service this session: typed by the user or taken from the saved
    /// secret. `nil` before the service has asked. File access uses the remote-desktop password to
    /// sign in over SSH without asking again.
    public func knownCredentials(for context: PromptContext) -> (username: String, password: String)? {
        sessionCredentials[secretKey(for: context)].map { ($0.username, $0.password) }
    }

    // MARK: Session life cycle

    /// The connection was established: whatever was sent is right. This is the only place saved
    /// secrets change: what the user asked to keep replaces them, and a saved one that was turned
    /// down (or that the user asked to replace) goes once something else has worked.
    public func connectionSucceeded() {
        for key in staleSaved {
            guard let working = sessionCredentials[key], toRemember[key] == nil else { continue }
            if savedSecret(key) != working.password { try? secrets.removeSecret(for: key) }
            staleSaved.remove(key)
        }
        for (key, credentials) in toRemember {
            try? secrets.setSecret(credentials.password, for: key)
            staleSaved.remove(key)
            if key.kind == .remoteDesktopPassword {
                if !credentials.username.isEmpty { savedUsername = credentials.username }
                onRememberUsername?(credentials.username)
            }
        }
        toRemember.removeAll()
        // A passphrase belongs to its key, not to this computer: every computer using the key gets it.
        for (keyName, passphrase) in passphrasesToRemember {
            try? secrets.setSecret(passphrase, for: SecretKey(appWide: .keyPassphrase, name: keyName))
        }
        passphrasesToRemember.removeAll()
        if let pendingChoice {
            acceptedChoice = pendingChoice
            self.pendingChoice = nil
        }
    }

    /// Makes the next attempt ask for the remote-desktop password, and for an SSH password the
    /// server turned down, instead of using what was typed or saved. Nothing saved is removed
    /// here: that happens only once different credentials have worked (``connectionSucceeded()``),
    /// so cancelling the prompt loses nothing.
    public func forgetCredentials() {
        staleSaved.insert(secretKey(for: .remoteDesktop(host: "")))
        sessionCredentials.removeAll()
        sentSaved.removeAll()
        toRemember.removeAll()
        fallbackCredentials = nil
        sessionPassphrases.removeAll()
        passphrasesToRemember.removeAll()
    }

    /// The saved secret that answers a service's credential prompt.
    private func secretKey(for context: PromptContext) -> SecretKey {
        switch context {
        case .remoteDesktop: .remoteDesktopPassword(for: computer)
        case .sshTunnel: .sshPassword(for: computer, server: computer.tunnelServer)
        case .fileAccess: .sshPassword(for: computer, server: computer.fileAccessTarget.server)
        }
    }
}
