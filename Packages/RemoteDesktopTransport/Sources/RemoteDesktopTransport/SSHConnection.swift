// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
public import RemoteDesktopCore
import SwiftSSH2
import Synchronization

/// A host key the user has already accepted.
public struct KnownHostKey: Sendable, Hashable, Codable {
    public var algorithm: String
    public var keyData: Data
    public var fingerprint: String

    public init(algorithm: String, keyData: Data, fingerprint: String) {
        self.algorithm = algorithm
        self.keyData = keyData
        self.fingerprint = fingerprint
    }
}

/// Where accepted host keys are remembered. Implemented by the app's storage.
public protocol HostKeyStore: Sendable {
    func knownKey(for server: Endpoint) async -> KnownHostKey?
    func remember(_ key: KnownHostKey, for server: Endpoint) async
}

/// A store that forgets everything when the process ends; for tools and tests.
public actor InMemoryHostKeyStore: HostKeyStore {
    private var keys: [Endpoint: KnownHostKey] = [:]

    public init() {}

    public func knownKey(for server: Endpoint) -> KnownHostKey? { keys[server] }
    public func remember(_ key: KnownHostKey, for server: Endpoint) { keys[server] = key }
}

/// A key whose private half never leaves where it is kept, such as a Secure Enclave.
public struct SSHKeySigner: Sendable {
    /// The public key in SSH wire format.
    public var publicKey: Data
    /// Signs data for the server, returning the signature in SSH's form for the key's algorithm, or
    /// `nil` when the key cannot be used (for one that needs the device owner, before they agreed).
    public var sign: @Sendable (Data) -> Data?

    public init(publicKey: Data, sign: @escaping @Sendable (Data) -> Data?) {
        self.publicKey = publicKey
        self.sign = sign
    }
}

/// How to log in to an SSH server.
public struct SSHLogin: Sendable {
    public var server: Endpoint
    public var username: String
    /// A private key in OpenSSH or PEM format. Tried before asking for a password.
    public var privateKey: Data?
    /// A key that signs without handing over its private half. Tried before asking for a password.
    public var signer: SSHKeySigner?
    /// Shown in the passphrase prompt if the key needs one.
    public var keyName: String
    /// What the password and passphrase prompts say the login is for.
    public var purpose: PromptContext?

    public init(server: Endpoint, username: String, privateKey: Data? = nil, keyName: String? = nil, purpose: PromptContext? = nil) {
        self.server = server
        self.username = username
        self.privateKey = privateKey
        self.keyName = keyName ?? String(localized: "SSH key", bundle: #bundle)
        self.purpose = purpose
    }

    /// The context of this login's prompts: a tunnel unless said otherwise.
    public var promptContext: PromptContext { purpose ?? .sshTunnel(host: server.host) }
}

public enum SSHConnectionError: Error, Sendable, Equatable {
    case unreachable(TransportError)
    /// The user declined the server's host key.
    case hostKeyRejected
    case authenticationFailed
    /// The user dismissed a prompt.
    case cancelled
    case failed(String)

    /// The same failure in the vocabulary of a connection attempt.
    public func connectionFailure(server: Endpoint) -> ConnectionFailure {
        switch self {
        case .unreachable(.localNetworkDenied): .localNetworkDenied
        case .unreachable(let error): .tunnelFailed(detail: String(localized: "Could not reach \(server): \(error)", bundle: #bundle))
        case .hostKeyRejected: .hostKeyRejected(host: server.host)
        case .authenticationFailed: .authenticationFailed(detail: String(localized: "The SSH server did not accept the login.", bundle: #bundle))
        case .cancelled: .cancelled
        case .failed(let detail): .tunnelFailed(detail: detail)
        }
    }
}

/// A login that worked, kept so that a second connection to the same server can log in the same
/// way without asking the user again. Answers to the server's questions are not kept: they may
/// be one-time codes.
enum ReplayableLogin: Sendable {
    case none
    case privateKey(Data, passphrase: String?)
    case signer(SSHKeySigner)
    case password(String)
}

/// An authenticated SSH connection, shared by everything that rides on it: the tunnel a session
/// runs through and, unless it gets one of its own, the SFTP client that moves files.
public final class SSHConnection: Sendable {
    public let server: Endpoint
    public let hostKey: KnownHostKey
    private let session: SSHSession
    private let username: String
    private let replay: ReplayableLogin?
    private let timeouts: Timeouts
    private let state = Mutex(State())

    private struct State {
        var carriesStreams = false
        var dedicated: [SSHConnection] = []
        var isClosed = false
    }

    struct Timeouts {
        var connect: Duration
        var handshake: Duration
    }

    private init(server: Endpoint, hostKey: KnownHostKey, session: SSHSession, username: String, replay: ReplayableLogin?, timeouts: Timeouts) {
        self.server = server
        self.hostKey = hostKey
        self.session = session
        self.username = username
        self.replay = replay
        self.timeouts = timeouts
    }

    /// Connects, checks the server's key against `hostKeys` (asking through `prompts` about a new
    /// or changed one), and logs in: with the private key if there is one, otherwise by asking for
    /// a password or answering the server's questions.
    ///
    /// Each exchange with the server (the handshake, and each step of logging in) must finish
    /// within `handshakeTimeout`, or the attempt fails as ``SSHConnectionError/unreachable(_:)``
    /// with ``TransportError/timedOut``; time the user spends answering prompts does not count.
    /// Cancelling the calling task ends the attempt at once.
    public static func establish(
        _ login: SSHLogin,
        prompts: any PromptHandler,
        hostKeys: any HostKeyStore,
        connectTimeout: Duration = .seconds(30),
        handshakeTimeout: Duration = .seconds(15)
    ) async throws(SSHConnectionError) -> SSHConnection {
        let timeouts = Timeouts(connect: connectTimeout, handshake: handshakeTimeout)
        let session = try await handshake(with: login.server, timeouts: timeouts)
        let watchdog = Watchdog(session: session, timeout: handshakeTimeout)
        do throws(SSHConnectionError) {
            let (key, replay) = try await withTaskCancellationHandler { () async throws(SSHConnectionError) -> (KnownHostKey, ReplayableLogin?) in
                let key = try await verifyHostKey(of: session, server: login.server, prompts: prompts, hostKeys: hostKeys)
                let replay = try await authenticate(session, login: login, prompts: prompts, watchdog: watchdog)
                return (key, replay)
            } onCancel: {
                session.abort()
            }
            return SSHConnection(server: login.server, hostKey: key, session: session, username: login.username, replay: replay, timeouts: timeouts)
        } catch {
            await session.disconnect()
            if Task.isCancelled { throw .cancelled }
            if watchdog.fired { throw .unreachable(.timedOut) }
            throw error
        }
    }

    private static func handshake(with server: Endpoint, timeouts: Timeouts) async throws(SSHConnectionError) -> SSHSession {
        let stream: TCPByteStream
        do {
            stream = try await TCPByteStream.connect(to: server, timeout: timeouts.connect)
        } catch let error as TransportError {
            throw .unreachable(error)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .failed(String(describing: error))
        }
        do {
            return try await SSHSession.connect(over: ByteStreamTransport(stream: stream), timeout: timeouts.handshake)
        } catch SSHError.timedOut {
            throw .unreachable(.timedOut)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .failed(String(localized: "The SSH handshake with \(server) failed: \(String(describing: error))", bundle: #bundle))
        }
    }

    /// Ends the session if one exchange with the server takes too long. Armed around each exchange
    /// and never while the user is being asked something.
    private final class Watchdog: Sendable {
        private let session: SSHSession
        private let timeout: Duration
        private let didFire = Mutex(false)

        init(session: SSHSession, timeout: Duration) {
            self.session = session
            self.timeout = timeout
        }

        var fired: Bool { didFire.withLock { $0 } }

        func guarding<Value>(_ body: () async throws -> Value) async throws -> Value {
            let timer = Task { [self] in
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                didFire.withLock { $0 = true }
                session.abort()
            }
            defer { timer.cancel() }
            return try await body()
        }
    }

    private static func verifyHostKey(
        of session: SSHSession, server: Endpoint, prompts: any PromptHandler, hostKeys: any HostKeyStore
    ) async throws(SSHConnectionError) -> KnownHostKey {
        guard let presented = session.hostKey else { throw .failed(String(localized: "The SSH server presented no host key.", bundle: #bundle)) }
        let key = KnownHostKey(algorithm: presented.algorithm, keyData: presented.keyData, fingerprint: presented.fingerprint)
        let known = await hostKeys.knownKey(for: server)
        if let known, known.keyData == key.keyData, known.algorithm == key.algorithm {
            return key
        }
        let challenge = HostKeyChallenge(
            host: server.host, port: server.port, algorithm: key.algorithm, fingerprint: key.fingerprint,
            status: known.map { .changed(previousFingerprint: $0.fingerprint) } ?? .unknown
        )
        guard case .trustHostKey(let remember) = await prompts.resolve(.hostKey(challenge)) else {
            throw .hostKeyRejected
        }
        if remember { await hostKeys.remember(key, for: server) }
        return key
    }

    /// Logs in, and returns how, if the same login could be made again without the user.
    private static func authenticate(
        _ session: SSHSession, login: SSHLogin, prompts: any PromptHandler, watchdog: Watchdog
    ) async throws(SSHConnectionError) -> ReplayableLogin? {
        let context = login.promptContext
        var methods: [String]
        do {
            methods = try await watchdog.guarding { try await session.authenticationMethods(for: login.username) }
        } catch {
            throw .failed(String(localized: "The SSH server closed the connection: \(String(describing: error))", bundle: #bundle))
        }
        if methods.isEmpty { return ReplayableLogin.none }

        if let signer = login.signer, methods.contains("publickey") {
            do {
                try await watchdog.guarding {
                    try await session.authenticate(username: login.username, with: .signer(publicKey: signer.publicKey, sign: signer.sign))
                }
                return .signer(signer)
            } catch SSHError.authenticationFailed, SSHError.unusableKey {
                // The server does not know the key, or it could not sign: a password may still do.
            } catch {
                throw .failed(String(localized: "SSH key login failed: \(String(describing: error))", bundle: #bundle))
            }
            methods = (try? await watchdog.guarding { try await session.authenticationMethods(for: login.username) }) ?? methods
        }

        if let key = login.privateKey, methods.contains("publickey") {
            var passphrase: String?
            for attempt in 1...4 {
                do {
                    try await watchdog.guarding {
                        try await session.authenticate(username: login.username, with: .privateKey(key, passphrase: passphrase))
                    }
                    return .privateKey(key, passphrase: passphrase)
                } catch SSHError.unusableKey {
                    // Most often a passphrase is needed, or the one given was wrong.
                    guard attempt < 4,
                          case .passphrase(let entered) = await prompts.resolve(.keyPassphrase(KeyPassphraseRequest(keyName: login.keyName, attempt: attempt)))
                    else { break }
                    passphrase = entered
                } catch SSHError.authenticationFailed {
                    break
                } catch {
                    throw .failed(String(localized: "SSH key login failed: \(String(describing: error))", bundle: #bundle))
                }
            }
            methods = (try? await watchdog.guarding { try await session.authenticationMethods(for: login.username) }) ?? methods
        }

        if methods.contains("password") {
            var previousFailure: String?
            for attempt in 1...3 {
                let request = CredentialRequest(context: context, kind: .passwordOnly, suggestedUsername: login.username, attempt: attempt, previousFailure: previousFailure)
                guard case .credentials(_, let password) = await prompts.resolve(.credentials(request)) else { throw .cancelled }
                do {
                    try await watchdog.guarding { try await session.authenticate(username: login.username, with: .password(password)) }
                    return .password(password)
                } catch SSHError.authenticationFailed {
                    previousFailure = String(localized: "The password is incorrect.", bundle: #bundle)
                } catch {
                    throw .failed(String(localized: "SSH password login failed: \(String(describing: error))", bundle: #bundle))
                }
            }
            throw .authenticationFailed
        }

        if methods.contains("keyboard-interactive") {
            let cancelled = CancelFlag()
            do {
                try await session.authenticate(username: login.username, with: .keyboardInteractive { challenge in
                    guard !challenge.prompts.isEmpty else { return [] }
                    let request = KeyboardInteractiveRequest(
                        context: context, title: challenge.name, instruction: challenge.instruction,
                        questions: challenge.prompts.map { .init(text: $0.text, echoesInput: $0.echoesInput) }
                    )
                    guard case .answers(let answers) = await prompts.resolve(.keyboardInteractive(request)) else {
                        cancelled.set()
                        return []
                    }
                    return answers
                })
                return nil
            } catch {
                throw cancelled.isSet ? .cancelled : .authenticationFailed
            }
        }
        throw .authenticationFailed
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    // MARK: Use

    /// Opens a stream from the SSH server to `host:port`, failing with ``TransportError/timedOut``
    /// if the server has not connected within `timeout`.
    public func openStream(toHost host: String, port: UInt16, timeout: Duration = .seconds(15)) async throws -> any ByteStream {
        state.withLock { $0.carriesStreams = true }
        do {
            return SSHChannelStream(channel: try await session.openTunnel(toHost: host, port: port, timeout: timeout))
        } catch SSHError.timedOut {
            throw TransportError.timedOut
        } catch SSHError.channelRefused(let detail) {
            throw TransportError.unreachable(detail: String(localized: "the SSH server could not connect to \(host):\(port) (\(detail))", bundle: #bundle))
        } catch SSHError.transportClosed, SSHError.disconnected {
            throw TransportError.closed
        } catch {
            throw TransportError.tunnel(detail: String(describing: error))
        }
    }

    public func run(_ command: String) async throws -> (output: Data, errors: Data, status: Int32) {
        let result = try await session.run(command)
        return (result.standardOutput, result.standardError, result.exitStatus)
    }

    func openSFTP() async throws -> SFTPClient {
        try await session.openSFTP()
    }

    /// Whether streams of a remote-desktop session ride on this connection.
    var carriesStreams: Bool { state.withLock { $0.carriesStreams } }

    /// A second connection to the same server, logged in the same way without asking anyone, for
    /// bulk work that should not queue in front of the session's input; `nil` if the login cannot
    /// be repeated (answers to the server's questions are not kept). It refuses a server whose key
    /// differs from this connection's. Closed with this connection.
    func openDedicated() async throws -> SSHConnection? {
        guard let replay else { return nil }
        let session = try await Self.handshake(with: server, timeouts: timeouts)
        let watchdog = Watchdog(session: session, timeout: timeouts.handshake)
        do {
            guard let presented = session.hostKey, presented.keyData == hostKey.keyData, presented.algorithm == hostKey.algorithm else {
                throw SSHConnectionError.hostKeyRejected
            }
            try await watchdog.guarding {
                switch replay {
                case .none:
                    _ = try await session.authenticationMethods(for: username)
                case .privateKey(let key, let passphrase):
                    try await session.authenticate(username: username, with: .privateKey(key, passphrase: passphrase))
                case .signer(let signer):
                    try await session.authenticate(username: username, with: .signer(publicKey: signer.publicKey, sign: signer.sign))
                case .password(let password):
                    try await session.authenticate(username: username, with: .password(password))
                }
            }
        } catch {
            await session.disconnect()
            throw error
        }
        let dedicated = SSHConnection(server: server, hostKey: hostKey, session: session, username: username, replay: replay, timeouts: timeouts)
        let keep = state.withLock { state in
            if !state.isClosed { state.dedicated.append(dedicated) }
            return !state.isClosed
        }
        guard keep else {
            await dedicated.close()
            throw TransportError.closed
        }
        return dedicated
    }

    public func close() async {
        let dedicated = state.withLock { state in
            state.isClosed = true
            defer { state.dedicated.removeAll() }
            return state.dedicated
        }
        for connection in dedicated { await connection.close() }
        await session.disconnect()
    }
}

/// A `ByteStream` as the transport of an SSH session.
struct ByteStreamTransport: SSHTransport {
    let stream: any ByteStream

    func read(upTo maxLength: Int) async throws -> Data? { try await stream.read(upTo: maxLength) }
    func write(_ data: Data) async throws { try await stream.write(data) }
    func close() async { await stream.close() }
}

/// An SSH channel as a `ByteStream`.
struct SSHChannelStream: ByteStream {
    let channel: SSHChannel

    func read(upTo maxLength: Int) async throws -> Data? {
        do {
            return try await channel.read(upTo: maxLength)
        } catch let error as SSHError {
            throw Self.map(error)
        }
    }

    func write(_ data: Data) async throws {
        do {
            try await channel.write(data)
        } catch let error as SSHError {
            throw Self.map(error)
        }
    }

    func close() async {
        await channel.close()
    }

    private static func map(_ error: SSHError) -> TransportError {
        switch error {
        case .transportClosed, .disconnected: .closed
        default: .tunnel(detail: String(describing: error))
        }
    }
}

/// Reaches a machine through an SSH server. Streams are channels of the SSH connection; datagrams
/// are not possible, so sessions through it cannot use modes that need them.
public struct SSHTunnelTransportProvider: TransportProvider {
    public let connection: SSHConnection
    /// The machine the session is for, as the user addressed it.
    public let peer: Endpoint
    /// The same machine as the SSH server reaches it: often `localhost`, when the SSH server is
    /// the machine itself.
    public let hostFromServer: String

    public init(connection: SSHConnection, peer: Endpoint, hostFromServer: String) {
        self.connection = connection
        self.peer = peer
        self.hostFromServer = hostFromServer
    }

    public var isTunnelled: Bool { true }
    public var supportsDatagrams: Bool { false }

    public func openStream(port: UInt16) async throws -> any ByteStream {
        try await connection.openStream(toHost: hostFromServer, port: port)
    }

    public func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel {
        throw TransportError.unsupported(detail: String(localized: "An SSH tunnel carries streams only.", bundle: #bundle))
    }
}
