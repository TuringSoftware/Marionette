// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
public import RemoteDesktopCore
import RemoteDesktopSimulated
public import RemoteDesktopTransport
import Synchronization

// MARK: - Seam

/// An authenticated SSH connection, as much of it as MarionetteKit uses: the tunnel a session runs through,
/// the files it moves, and the means to end it. Whoever is handed one closes it.
public protocol SSHSessionHandle: Sendable {
    var server: Endpoint { get }
    /// The path to `peer` through this connection. `hostFromServer` is the peer as the SSH server
    /// reaches it: `localhost` when they are the same machine.
    func makeTunnel(to peer: Endpoint, hostFromServer: String) -> any TransportProvider
    /// File transfer with the SSH server (SFTP).
    func makeFileTransfer() -> any FileTransfer
    /// Ends the connection and everything riding on it. Idempotent.
    func close() async
}

/// Opens SSH connections. The live one talks to a server; tests and the simulated environment
/// script one.
///
/// The contract is ``SSHConnection/establish(_:prompts:hostKeys:connectTimeout:)``'s: check the host
/// key against `hostKeys` and ask `prompts` about a new or changed one (remembering it if told to);
/// then log in with the key if there is one (asking for its passphrase), else by password (up to
/// three attempts, each a `.credentials` prompt in the `.sshTunnel` context) or by answering the
/// server's questions.
public protocol SSHConnecting: Sendable {
    func connect(
        _ login: SSHLogin, prompts: any PromptHandler, hostKeys: any HostKeyStore
    ) async throws(SSHConnectionError) -> any SSHSessionHandle
}

public struct LiveSSHSessionHandle: SSHSessionHandle {
    public let connection: SSHConnection

    public init(connection: SSHConnection) {
        self.connection = connection
    }

    public var server: Endpoint { connection.server }

    public func makeTunnel(to peer: Endpoint, hostFromServer: String) -> any TransportProvider {
        SSHTunnelTransportProvider(connection: connection, peer: peer, hostFromServer: hostFromServer)
    }

    public func makeFileTransfer() -> any FileTransfer {
        SFTPFileTransfer(connection: connection)
    }

    public func close() async {
        await connection.close()
    }
}

public struct LiveSSHConnector: SSHConnecting {
    public var connectTimeout: Duration

    public init(connectTimeout: Duration = .seconds(30)) {
        self.connectTimeout = connectTimeout
    }

    public func connect(
        _ login: SSHLogin, prompts: any PromptHandler, hostKeys: any HostKeyStore
    ) async throws(SSHConnectionError) -> any SSHSessionHandle {
        LiveSSHSessionHandle(
            connection: try await SSHConnection.establish(login, prompts: prompts, hostKeys: hostKeys, connectTimeout: connectTimeout)
        )
    }
}

// MARK: - Services

/// Where to log in over SSH, and as whom.
public struct SSHTarget: Sendable, Hashable {
    public var server: Endpoint
    /// Empty means "ask".
    public var username: String
    /// A key in the ``SSHKeyStore`` to try before a password.
    public var keyName: String?

    public init(server: Endpoint, username: String, keyName: String? = nil) {
        self.server = server
        self.username = username
        self.keyName = keyName
    }
}

extension ComputerConfiguration {
    /// The SSH login of the tunnel this computer is reached through.
    public var tunnelTarget: SSHTarget {
        SSHTarget(server: tunnelServer, username: tunnelUsername, keyName: tunnel.keyName)
    }

    /// The SSH login of the computer itself, for moving files without a tunnel. The tunnel's port,
    /// account and key apply when its SSH server is this computer; otherwise the defaults do.
    public var fileAccessTarget: SSHTarget {
        if tunnelServerIsComputer {
            return SSHTarget(server: Endpoint(host: host, port: tunnel.port), username: tunnelUsername, keyName: tunnel.keyName)
        }
        return SSHTarget(server: Endpoint(host: host, port: 22), username: username)
    }
}

/// Everything SSH needs: how to connect, which hosts are known, and the user's keys.
public struct SSHServices: Sendable {
    public var connector: any SSHConnecting
    public var hostKeys: any KnownHostsStore
    public var keys: SSHKeyStore

    public init(connector: any SSHConnecting = LiveSSHConnector(), hostKeys: any KnownHostsStore, keys: SSHKeyStore) {
        self.connector = connector
        self.hostKeys = hostKeys
        self.keys = keys
    }

    /// Opens a connection to `target`, asking everything through `prompts`: the account if the
    /// target names none, an unknown or changed host key, a key's passphrase, the password, the
    /// server's own questions.
    ///
    /// `presetPassword` is tried before the user is asked for one: a password the user already
    /// typed this session for the same account (the remote-desktop one, for file access).
    public func open(
        _ target: SSHTarget, prompts: any PromptHandler, presetPassword: String? = nil, purpose: PromptContext? = nil
    ) async throws(SSHConnectionError) -> any SSHSessionHandle {
        if Task.isCancelled { throw .cancelled }
        var username = target.username.trimmingCharacters(in: .whitespaces)
        var preset = presetPassword.map { PresetPasswordPrompts.Preset(password: $0, isFromUser: false) }
        if username.isEmpty {
            // SSH needs the account before anything else; the password asked along with it is
            // then offered when the server asks.
            let request = CredentialRequest(context: purpose ?? .sshTunnel(host: target.server.host), kind: .usernameAndPassword)
            guard case .credentials(let name, let password) = await prompts.resolve(.credentials(request)) else { throw .cancelled }
            username = name.trimmingCharacters(in: .whitespaces)
            guard !username.isEmpty else { throw .authenticationFailed }
            preset = .init(password: password, isFromUser: true)
        }

        var login = SSHLogin(server: target.server, username: username, purpose: purpose)
        if let keyName = target.keyName, let key = try? keys.privateKey(named: keyName) {
            // A key that has been deleted is simply not offered; the password remains.
            login.privateKey = key
            login.keyName = keyName
        }
        let asking: any PromptHandler = preset.map { PresetPasswordPrompts(base: prompts, preset: $0) } ?? prompts
        let handle: any SSHSessionHandle
        do {
            handle = try await connector.connect(login, prompts: asking, hostKeys: hostKeys)
        } catch {
            // A prompt abandoned because the attempt was cancelled is a cancellation, whatever
            // the prompt was about.
            throw Task.isCancelled ? .cancelled : error
        }
        if Task.isCancelled {
            await handle.close()
            throw .cancelled
        }
        return handle
    }
}

/// Answers the first SSH password request with a password already in hand, then steps aside.
private final class PresetPasswordPrompts: PromptHandler {
    struct Preset {
        var password: String
        /// Whether the user just typed it for this very login. If not (it was borrowed from another
        /// service), its rejection is not the user's mistake and the next request counts as the first.
        var isFromUser: Bool
    }

    private let base: any PromptHandler
    private let preset: Preset
    private let used = Mutex(false)

    init(base: any PromptHandler, preset: Preset) {
        self.base = base
        self.preset = preset
    }

    func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        guard case .credentials(var request) = prompt, request.context.isSSH, request.kind == .passwordOnly else {
            return await base.resolve(prompt)
        }
        let isFirst = used.withLock { used in
            defer { used = true }
            return !used
        }
        if isFirst, request.attempt == 1 {
            return .credentials(username: request.suggestedUsername ?? "", password: preset.password)
        }
        if !preset.isFromUser, request.attempt > 1 {
            request.attempt -= 1
            if request.attempt == 1 { request.previousFailure = nil }
        }
        return await base.resolve(.credentials(request))
    }
}

extension SSHConnectionError {
    /// The failure of an SSH tunnel as a connection failure, in words fit for the failure screen.
    public func tunnelFailure(server: Endpoint) -> ConnectionFailure {
        switch self {
        case .unreachable(.localNetworkDenied):
            .localNetworkDenied
        case .unreachable(.timedOut):
            .tunnelFailed(detail: String(localized: "The SSH server at \(server) didn’t answer.", bundle: #bundle))
        case .unreachable(.unreachable(let detail)):
            .tunnelFailed(detail: detail.isEmpty
                ? String(localized: "The SSH server at \(server) couldn’t be reached.", bundle: #bundle)
                : String(localized: "The SSH server at \(server) couldn’t be reached (\(detail)).", bundle: #bundle))
        case .unreachable(let error):
            .tunnelFailed(detail: String(localized: "The SSH server at \(server) couldn’t be reached (\(error)).", bundle: #bundle))
        case .hostKeyRejected:
            .hostKeyRejected(host: server.host)
        case .authenticationFailed:
            .authenticationFailed(detail: String(localized: "The SSH server at “\(server.host)” didn’t accept the sign-in.", bundle: #bundle))
        case .cancelled:
            .cancelled
        case .failed(let detail):
            .tunnelFailed(detail: detail)
        }
    }

    /// The failure of signing in for file access, for the Files panel.
    public func fileAccessMessage(server: Endpoint) -> String {
        switch self {
        case .unreachable(.localNetworkDenied):
            ConnectionFailure.localNetworkMessage
        case .unreachable:
            String(localized: "“\(server.host)” didn’t answer over SSH. Check that Remote Login is turned on.", bundle: #bundle)
        case .hostKeyRejected:
            String(localized: "Sign-in was stopped because the identity of “\(server.host)” wasn’t trusted.", bundle: #bundle)
        case .authenticationFailed:
            String(localized: "“\(server.host)” didn’t accept the sign-in.", bundle: #bundle)
        case .cancelled:
            String(localized: "Sign-in was cancelled.", bundle: #bundle)
        case .failed(let detail):
            detail
        }
    }
}

// MARK: - Scripted

/// An SSH server that exists only in memory, for tests and simulated environments. It asks what a
/// real connection would ask, in the same order, and hands out connections that go nowhere.
public final class ScriptedSSHConnector: SSHConnecting {
    public struct Server: Sendable {
        public var hostKey = KnownHostKey(
            algorithm: "ssh-ed25519", keyData: Data(repeating: 0x5A, count: 51),
            fingerprint: "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"
        )
        /// Fails every connection before the host key is seen.
        public var failure: SSHConnectionError?
        /// Private keys that log in, with the passphrase each needs (`nil` for none).
        public var authorizedKeys: [Data: String?] = [:]
        /// The password that logs in, if passwords are accepted.
        public var password: String?
        /// A question-and-answer login, offered when passwords are not.
        public var keyboardInteractive: (request: KeyboardInteractiveRequest, answers: [String])?
        /// What the handed-out connections offer as file transfer.
        public var files: (any FileTransfer)?
        public var delay: Duration = .zero

        public init() {}
    }

    /// A pretend connection. Tests look at what became of it.
    public final class Handle: SSHSessionHandle {
        public let server: Endpoint
        public let login: SSHLogin
        private let files: (any FileTransfer)?
        private let closed = Mutex(false)

        init(login: SSHLogin, files: (any FileTransfer)?) {
            server = login.server
            self.login = login
            self.files = files
        }

        public var isClosed: Bool { closed.withLock { $0 } }

        public func makeTunnel(to peer: Endpoint, hostFromServer: String) -> any TransportProvider {
            SimulatedTransport(peer: peer, isTunnelled: true)
        }

        public func makeFileTransfer() -> any FileTransfer {
            files ?? NoFiles()
        }

        public func close() async {
            closed.withLock { $0 = true }
        }
    }

    private struct NoFiles: FileTransfer {
        struct Unavailable: Error {}
        var canBrowse: Bool { true }
        func defaultUploadDirectory() async throws -> String { "/" }
        func list(directory: String) async throws -> [RemoteFileEntry] { [] }
        func upload(from localFile: URL, toDirectory remoteDirectory: String) -> AsyncThrowingStream<TransferProgress, any Error> {
            AsyncThrowingStream { $0.finish(throwing: Unavailable()) }
        }
        func download(_ remotePath: String, to localFile: URL) -> AsyncThrowingStream<TransferProgress, any Error> {
            AsyncThrowingStream { $0.finish(throwing: Unavailable()) }
        }
    }

    public let server: Server
    private let state = Mutex<(logins: [SSHLogin], handles: [Handle])>(([], []))

    public init(_ server: Server = Server()) {
        self.server = server
    }

    /// Every login attempted, in order.
    public var logins: [SSHLogin] { state.withLock { $0.logins } }
    /// Every connection handed out, in order.
    public var handles: [Handle] { state.withLock { $0.handles } }

    public func connect(
        _ login: SSHLogin, prompts: any PromptHandler, hostKeys: any HostKeyStore
    ) async throws(SSHConnectionError) -> any SSHSessionHandle {
        state.withLock { $0.logins.append(login) }
        if server.delay > .zero {
            do { try await Task.sleep(for: server.delay) } catch { throw .cancelled }
        }
        if let failure = server.failure { throw failure }

        let known = await hostKeys.knownKey(for: login.server)
        if known?.keyData != server.hostKey.keyData || known?.algorithm != server.hostKey.algorithm {
            let challenge = HostKeyChallenge(
                host: login.server.host, port: login.server.port, algorithm: server.hostKey.algorithm,
                fingerprint: server.hostKey.fingerprint,
                status: known.map { .changed(previousFingerprint: $0.fingerprint) } ?? .unknown
            )
            guard case .trustHostKey(let remember) = await prompts.resolve(.hostKey(challenge)) else { throw .hostKeyRejected }
            if remember { await hostKeys.remember(server.hostKey, for: login.server) }
        }

        try await authenticate(login, prompts: prompts)
        let handle = Handle(login: login, files: server.files)
        state.withLock { $0.handles.append(handle) }
        return handle
    }

    private func authenticate(_ login: SSHLogin, prompts: any PromptHandler) async throws(SSHConnectionError) {
        let context = login.promptContext
        if server.authorizedKeys.isEmpty, server.password == nil, server.keyboardInteractive == nil { return }

        if let key = login.privateKey, !server.authorizedKeys.isEmpty {
            if let needed = server.authorizedKeys[key] {
                var passphrase: String?
                for attempt in 1...4 {
                    if needed == nil || needed == passphrase { return }
                    guard attempt < 4,
                          case .passphrase(let entered) = await prompts.resolve(.keyPassphrase(KeyPassphraseRequest(keyName: login.keyName, attempt: attempt)))
                    else { break }
                    passphrase = entered
                }
            }
        }

        if let password = server.password {
            var previousFailure: String?
            for attempt in 1...3 {
                let request = CredentialRequest(
                    context: context, kind: .passwordOnly, suggestedUsername: login.username, attempt: attempt, previousFailure: previousFailure
                )
                guard case .credentials(_, let entered) = await prompts.resolve(.credentials(request)) else { throw .cancelled }
                if entered == password { return }
                previousFailure = String(localized: "The password is incorrect.", bundle: #bundle)
            }
            throw .authenticationFailed
        }

        if let (request, answers) = server.keyboardInteractive {
            var asked = request
            asked.context = context
            guard case .answers(let given) = await prompts.resolve(.keyboardInteractive(asked)) else { throw .cancelled }
            if given == answers { return }
        }
        throw .authenticationFailed
    }
}
