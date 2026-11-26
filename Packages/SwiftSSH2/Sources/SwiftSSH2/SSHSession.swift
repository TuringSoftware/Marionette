// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CLibSSH2
import CryptoKit
public import Foundation
import Synchronization

/// The bytes an SSH session runs over: a TCP connection, or a channel of another SSH session.
public protocol SSHTransport: Sendable {
    /// Waits for data. Returns at least one byte, or `nil` at end of stream.
    func read(upTo maxLength: Int) async throws -> Data?
    func write(_ data: Data) async throws
    func close() async
}

public enum SSHError: Error, Sendable, Equatable {
    /// The connection underneath ended.
    case transportClosed
    case transportFailed(String)
    /// The two sides could not agree on a secure connection.
    case handshakeFailed(String)
    /// The server rejected the credentials. ``SSHSession/authenticationMethods(for:)`` says what
    /// it would still accept.
    case authenticationFailed
    /// The private key could not be read: wrong passphrase, or not a key this client understands.
    case unusableKey(String)
    /// The server refused to open the channel (for a tunnel: it could not reach the destination).
    case channelRefused(String)
    case sftp(SFTPStatus)
    case library(code: Int32, message: String)
    case disconnected
    /// The server did not answer in time, and the session was ended.
    case timedOut
}

/// Status codes of the SFTP protocol that callers act on.
public enum SFTPStatus: Sendable, Equatable {
    case noSuchFile
    case permissionDenied
    case failure
    case other(code: UInt)

    init(code: UInt) {
        switch code {
        case 2: self = .noSuchFile
        case 3: self = .permissionDenied
        case 4: self = .failure
        default: self = .other(code: code)
        }
    }
}

/// The key a server proved it holds during the handshake.
public struct SSHHostKey: Sendable, Hashable {
    /// The key algorithm, for example "ssh-ed25519".
    public var algorithm: String
    /// The public key in SSH wire format.
    public var keyData: Data
    /// "SHA256:" and the unpadded base64 digest of the key, as OpenSSH prints it.
    public var fingerprint: String

    /// The key as a line of an OpenSSH `known_hosts` file.
    public func knownHostsLine(host: String, port: UInt16 = 22) -> String {
        let name = port == 22 ? host : "[\(host)]:\(port)"
        return "\(name) \(algorithm) \(keyData.base64EncodedString())"
    }
}

public struct SSHKeyboardInteractiveChallenge: Sendable, Hashable {
    public struct Prompt: Sendable, Hashable {
        public var text: String
        public var echoesInput: Bool
    }

    public var name: String
    public var instruction: String
    public var prompts: [Prompt]
}

public enum SSHAuthentication: Sendable {
    case password(String)
    /// A private key in OpenSSH or PEM format, with its passphrase if it has one.
    case privateKey(Data, passphrase: String?)
    /// The server asks questions and the responder answers them, one answer per prompt.
    case keyboardInteractive(@Sendable (SSHKeyboardInteractiveChallenge) async -> [String])
    /// A key whose private half is kept elsewhere, such as in a Secure Enclave. `publicKey` is the
    /// public key in SSH wire format; `sign` returns the signature of the data it is given, in the
    /// form the key's algorithm defines inside SSH's signature blob (for ECDSA,
    /// ``ecdsaSignature(raw:)``), or `nil` to refuse. It is called on the session's queue and may
    /// block it.
    case signer(publicKey: Data, sign: @Sendable (Data) -> Data?)

    /// An ECDSA signature as SSH carries it, from the raw form (`r` then `s`, each the curve's
    /// size) that CryptoKit produces.
    public static func ecdsaSignature(raw: Data) -> Data {
        let half = raw.count / 2
        var blob = Data()
        for part in [raw.prefix(half), raw.suffix(half)] {
            // An mpint: big-endian, no leading zeros, and a zero in front when the top bit is set.
            var bytes = Data(part.drop { $0 == 0 })
            if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { blob.append(contentsOf: $0) }
            blob.append(bytes)
        }
        return blob
    }
}

/// Carries a signer into libssh2's signing callback.
private final class SignerBox {
    let sign: @Sendable (Data) -> Data?
    init(_ sign: @escaping @Sendable (Data) -> Data?) { self.sign = sign }
}

/// A pointer libssh2 handed out. Only ever dereferenced by libssh2, on the owning session's queue.
struct LibraryPointer: @unchecked Sendable {
    let raw: OpaquePointer
}

/// What one attempt at a libssh2 call came to.
enum Step<Value: Sendable>: Sendable {
    case done(Value)
    /// libssh2 needs more data from the peer, or room to send; try again when something moves.
    case again
    case failed(SSHError)
}

/// An SSH connection.
///
/// libssh2 is driven in non-blocking mode on one serial queue per session, which is the only place
/// its session, channels and SFTP handles are ever touched. libssh2 reads from and writes to
/// buffers owned here; two tasks move bytes between those buffers and the transport. A call that
/// cannot finish yet is parked and tried again whenever bytes arrive or the outbound queue drains.
public final class SSHSession: @unchecked Sendable {
    // @unchecked: every stored property below `queue` is read and written only on `queue`.
    let queue: DispatchQueue
    private let transport: any SSHTransport
    private var session: OpaquePointer?
    private var placeholderSocket: Int32 = -1

    private var inbound = Data()
    private var inboundOffset = 0
    private var transportEnded: SSHError?
    private var outbound = Data()
    private var outboundInFlight = 0
    private var outboundContinuation: AsyncStream<Data>.Continuation?
    private var parked: [Parked] = []
    private var nextParkedID: UInt64 = 0
    /// Counts arrivals from the server, so that a caller can tell "nothing new since I looked"
    /// from "something came while I was looking elsewhere". Only touched on the queue.
    private(set) var arrivals: UInt64 = 0
    private var tasks: [Task<Void, Never>] = []
    private var keyboardResponder: (@Sendable (SSHKeyboardInteractiveChallenge) async -> [String])?
    private var isClosed = false

    /// Bytes queued for the transport above which channel writes wait, so a fast producer cannot
    /// buffer without bound in front of a slow link.
    static let outboundHighWater = 1 << 20

    /// The receive window a tunnel opens with, instead of libssh2's 2 MiB. A remote screen's
    /// encoder only slows down once the window is full, so whatever the window holds is picture
    /// the viewer sees late: 2 MiB is 4 s at 4 Mbit/s. libssh2 tops the window back up to this
    /// size plus the read size (at most 64 KiB here), so this bounds it. rootshell-vnc measured
    /// 512 KiB through a jump host as matching a direct connection.
    public static let tunnelWindow: UInt32 = 512 * 1024

    /// How long closing waits for the peer's part before going ahead regardless: a dead peer
    /// never answers.
    static let closeGrace = Duration.seconds(2)

    private struct Parked {
        let id: UInt64
        let attempt: () -> Bool
        let fail: (SSHError) -> Void
    }

    public private(set) var hostKey: SSHHostKey?

    private static let libraryReady: Bool = libssh2_init(0) == 0

    private init(transport: any SSHTransport) {
        self.transport = transport
        queue = DispatchQueue(label: "llc.turing.SwiftSSH2.session")
    }

    deinit {
        // Normally `disconnect()` has done this; a session dropped without it is torn down here.
        if let session { libssh2_session_free(session) }
        if placeholderSocket >= 0 { Darwin.close(placeholderSocket) }
        outboundContinuation?.finish()
        for task in tasks { task.cancel() }
    }

    // MARK: Connecting

    /// Runs the SSH handshake over `transport`. The server is not yet trusted and the user not yet
    /// authenticated: check ``hostKey``, then call ``authenticate(username:with:)``.
    ///
    /// Gives up with ``SSHError/timedOut`` after `timeout`, and with `CancellationError` when the
    /// caller is cancelled: a server that accepts the connection and never speaks would otherwise
    /// hold the caller for as long as the connection lasts.
    public static func connect(over transport: any SSHTransport, timeout: Duration? = nil) async throws -> SSHSession {
        guard libraryReady else { throw SSHError.library(code: -1, message: "libssh2 failed to initialise") }
        let session = SSHSession(transport: transport)
        do {
            let expired = Latch()
            let timer = timeout.map { timeout in
                Task { [weak session] in
                    try await Task.sleep(for: timeout)
                    expired.set()
                    session?.abort()
                }
            }
            defer { timer?.cancel() }
            do {
                try await withTaskCancellationHandler {
                    try await session.start()
                } onCancel: {
                    session.abort()
                }
            } catch {
                if expired.isSet { throw SSHError.timedOut }
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } catch {
            await session.disconnect()
            throw error
        }
        return session
    }

    private func start() async throws {
        try await onQueue { session in
            let abstract = Unmanaged.passUnretained(session).toOpaque()
            guard let created = marionette_ssh2_session_init(abstract) else {
                throw SSHError.library(code: -6, message: "libssh2 could not allocate a session")
            }
            session.session = created
            libssh2_session_set_blocking(created, 0)
            // libssh2 insists on a socket to mark non-blocking; all real I/O goes through the callbacks.
            session.placeholderSocket = socket(AF_UNIX, SOCK_STREAM, 0)

            let send: @convention(c) (libssh2_socket_t, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { _, buffer, length, _, abstract in
                guard let buffer, let owner = abstract?.pointee else { return -Int(EBADF) }
                let session = Unmanaged<SSHSession>.fromOpaque(owner).takeUnretainedValue()
                // Always accepted: a partial send would oblige the caller to retry that exact call.
                session.outbound.append(buffer.assumingMemoryBound(to: UInt8.self), count: length)
                return length
            }
            let receive: @convention(c) (libssh2_socket_t, UnsafeMutableRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { _, buffer, length, _, abstract in
                guard let buffer, let owner = abstract?.pointee else { return -Int(EBADF) }
                let session = Unmanaged<SSHSession>.fromOpaque(owner).takeUnretainedValue()
                let available = session.inbound.count - session.inboundOffset
                guard available > 0 else {
                    // Zero tells libssh2 the peer hung up.
                    return session.transportEnded == nil ? -Int(EAGAIN) : 0
                }
                let count = min(available, length)
                session.inbound.withUnsafeBytes { bytes in
                    buffer.copyMemory(from: bytes.baseAddress! + session.inboundOffset, byteCount: count)
                }
                session.inboundOffset += count
                if session.inboundOffset == session.inbound.count {
                    session.inbound.removeAll(keepingCapacity: true)
                    session.inboundOffset = 0
                }
                return count
            }
            _ = libssh2_session_callback_set2(created, LIBSSH2_CALLBACK_SEND, unsafeBitCast(send, to: (@convention(c) () -> Void).self))
            _ = libssh2_session_callback_set2(created, LIBSSH2_CALLBACK_RECV, unsafeBitCast(receive, to: (@convention(c) () -> Void).self))
            session.startPumps()
        }

        try await perform(abandonable: false) { session -> Step<Void> in
            guard let pointer = session.session else { return .failed(.disconnected) }
            let status = libssh2_session_handshake(pointer, session.placeholderSocket)
            if status == LIBSSH2_ERROR_EAGAIN { return .again }
            if status != 0 { return .failed(.handshakeFailed(session.lastErrorMessage())) }
            return .done(())
        }

        try await onQueue { session in
            guard let pointer = session.session else { throw SSHError.disconnected }
            var length = 0
            var type: Int32 = 0
            guard let key = libssh2_session_hostkey(pointer, &length, &type), length > 0,
                  let digest = libssh2_hostkey_hash(pointer, LIBSSH2_HOSTKEY_HASH_SHA256)
            else { throw SSHError.handshakeFailed("the server presented no host key") }
            let algorithm = libssh2_session_methods(pointer, LIBSSH2_METHOD_HOSTKEY).map { String(cString: $0) } ?? "unknown"
            let fingerprint = Data(bytes: digest, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
            session.hostKey = SSHHostKey(algorithm: algorithm, keyData: Data(bytes: key, count: length), fingerprint: "SHA256:" + fingerprint)
        }
    }

    /// Lets the pump tasks reach the session without keeping it alive.
    private final class WeakSession: @unchecked Sendable {
        weak var session: SSHSession?
        let queue: DispatchQueue

        init(_ session: SSHSession) {
            self.session = session
            queue = session.queue
        }

        /// Runs `body` on the session's queue if the session still exists.
        func enqueue(_ body: @escaping @Sendable (SSHSession) -> Void) {
            queue.async { [self] in
                if let session { body(session) }
            }
        }
    }

    private func startPumps() {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        outboundContinuation = continuation
        let transport = transport
        let reference = WeakSession(self)
        tasks.append(Task {
            for await chunk in stream {
                do {
                    try await transport.write(chunk)
                } catch {
                    let description = String(describing: error)
                    reference.enqueue { $0.transportDidEnd(.transportFailed(description)) }
                    return
                }
                let count = chunk.count
                reference.enqueue { session in
                    session.outboundInFlight -= count
                    session.retryParked()
                }
            }
        })
        tasks.append(Task {
            while !Task.isCancelled {
                do {
                    guard let data = try await transport.read(upTo: 1 << 16) else {
                        reference.enqueue { $0.transportDidEnd(.transportClosed) }
                        return
                    }
                    reference.enqueue { session in
                        session.inbound.append(data)
                        session.arrivals &+= 1
                        session.retryParked()
                    }
                } catch {
                    let description = String(describing: error)
                    reference.enqueue { $0.transportDidEnd(.transportFailed(description)) }
                    return
                }
            }
        })
    }

    /// Ends the session now, without saying goodbye: closes the transport and fails every call
    /// waiting on the server. For a server that has stopped answering; ``disconnect()`` still
    /// tidies up afterwards.
    public func abort() {
        queue.async { self.transportDidEnd(.disconnected) }
        let transport = transport
        Task { await transport.close() }
    }

    private func transportDidEnd(_ error: SSHError) {
        guard transportEnded == nil else { return }
        transportEnded = error
        // Let parked calls see the end through libssh2, which reports what it was in the middle of.
        retryParked()
        let stranded = parked
        parked.removeAll()
        for entry in stranded { entry.fail(error) }
    }

    // MARK: Running libssh2 calls

    func onQueue<Value: Sendable>(_ body: @escaping @Sendable (SSHSession) throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body(self) })
            }
        }
    }

    /// What a cancelled caller may do about a libssh2 call that has not finished.
    enum Abandonment<Value: Sendable>: Sendable {
        /// Nothing: the call holds session-wide state (the handshake, authenticating), so it must
        /// finish or the session is unusable. The caller waits; ``abort()`` ends the wait.
        case forbidden
        /// Walk away and forget it: the call holds no state between attempts (a read, a write).
        case drop
        /// Walk away at once while the call goes on to completion, because libssh2 cannot be
        /// stopped half-way through it; what it produces after the caller left goes to the handler,
        /// on the session's queue, to be cleaned up.
        case finishInBackground(@Sendable (Value) -> Void)
    }

    /// Runs a libssh2 call to completion, retrying it each time the connection makes progress.
    func perform<Value: Sendable>(abandonable: Bool, _ body: @escaping @Sendable (SSHSession) -> Step<Value>) async throws -> Value {
        try await perform(abandonable ? .drop : .forbidden, body)
    }

    /// Runs a libssh2 call to completion, retrying it each time the connection makes progress;
    /// `abandonment` says what happens if the caller is cancelled first.
    func perform<Value: Sendable>(_ abandonment: Abandonment<Value>, _ body: @escaping @Sendable (SSHSession) -> Step<Value>) async throws -> Value {
        let ticket = Ticket<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                if case .finishInBackground = abandonment, ticket.arm(continuation) {
                    // Cancelled before it began: the caller leaves now, the call still runs.
                    ticket.resume(throwing: CancellationError())
                } else {
                    _ = ticket.arm(continuation)
                }
                queue.async {
                    self.nextParkedID += 1
                    let id = self.nextParkedID
                    let attempt: () -> Bool = {
                        if case .drop = abandonment, ticket.isCancelled {
                            ticket.resume(throwing: CancellationError())
                            return true
                        }
                        let step = body(self)
                        self.flushOutbound()
                        switch step {
                        case .done(let value):
                            if !ticket.resume(returning: value), case .finishInBackground(let late) = abandonment {
                                late(value)
                            }
                            return true
                        case .failed(let error):
                            ticket.resume(throwing: error)
                            return true
                        case .again:
                            return false
                        }
                    }
                    if attempt() { return }
                    if let ended = self.transportEnded {
                        ticket.resume(throwing: ended)
                        return
                    }
                    self.parked.append(Parked(id: id, attempt: attempt, fail: { ticket.resume(throwing: $0) }))
                }
            }
        } onCancel: {
            switch abandonment {
            case .forbidden:
                return
            case .drop:
                ticket.cancel()
                queue.async { self.retryParked() }
            case .finishInBackground:
                ticket.cancel()
                ticket.resume(throwing: CancellationError())
            }
        }
    }

    /// Runs `body`, cancelling it after `timeout` and then failing with ``SSHError/timedOut``.
    func cancelling<Value: Sendable>(after timeout: Duration?, _ body: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard let timeout else { return try await body() }
        let expired = Latch()
        let work = Task { try await body() }
        let timer = Task {
            try await Task.sleep(for: timeout)
            expired.set()
            work.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch {
            if expired.isSet { throw SSHError.timedOut }
            throw error
        }
    }

    /// Shared between a caller and the queue: whether the caller gave up, and its continuation,
    /// resumed once whichever side gets there first.
    private final class Ticket<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, any Error>?
        private var cancelledFlag = false

        var isCancelled: Bool { lock.withLock { cancelledFlag } }

        /// Stores the continuation; returns whether the caller was already cancelled.
        func arm(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
            lock.withLock {
                self.continuation = continuation
                return cancelledFlag
            }
        }

        func cancel() {
            lock.withLock { cancelledFlag = true }
        }

        /// Returns false if the caller had already been answered.
        @discardableResult
        func resume(returning value: Value) -> Bool {
            guard let continuation = take() else { return false }
            continuation.resume(returning: value)
            return true
        }

        func resume(throwing error: any Error) {
            take()?.resume(throwing: error)
        }

        private func take() -> CheckedContinuation<Value, any Error>? {
            lock.withLock {
                defer { continuation = nil }
                return continuation
            }
        }
    }

    private func retryParked() {
        guard !parked.isEmpty else { return }
        let waiting = parked
        parked.removeAll()
        // Attempts run in the order the calls were made; ones still not done go back in that order.
        var still: [Parked] = []
        for entry in waiting where !entry.attempt() {
            still.append(entry)
        }
        parked = still + parked
    }

    /// Hands what libssh2 wrote to the transport's writer.
    func flushOutbound() {
        guard !outbound.isEmpty, let outboundContinuation else { return }
        outboundInFlight += outbound.count
        outboundContinuation.yield(outbound)
        outbound = Data()
    }

    var isOutboundCongested: Bool { outboundInFlight > Self.outboundHighWater }

    var pointer: OpaquePointer? { session }

    func lastErrorMessage() -> String {
        guard let session else { return "disconnected" }
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        libssh2_session_last_error(session, &message, &length, 0)
        return message.map { String(cString: $0) } ?? "unknown error"
    }

    func lastError() -> Int32 {
        session.map { libssh2_session_last_errno($0) } ?? LIBSSH2_ERROR_SOCKET_DISCONNECT
    }

    // MARK: Authentication

    /// The authentication methods the server accepts for `username`. Empty if it accepts the user
    /// with no authentication at all.
    public func authenticationMethods(for username: String) async throws -> [String] {
        try await perform(abandonable: false) { session -> Step<[String]> in
            guard let pointer = session.session else { return .failed(.disconnected) }
            if let list = libssh2_userauth_list(pointer, username, UInt32(username.utf8.count)) {
                return .done(String(cString: list).split(separator: ",").map(String.init))
            }
            if libssh2_userauth_authenticated(pointer) != 0 { return .done([]) }
            if session.lastError() == LIBSSH2_ERROR_EAGAIN { return .again }
            return .failed(.library(code: session.lastError(), message: session.lastErrorMessage()))
        }
    }

    public var isAuthenticated: Bool {
        get async {
            (try? await onQueue { session in session.session.map { libssh2_userauth_authenticated($0) != 0 } ?? false }) ?? false
        }
    }

    public func authenticate(username: String, with method: SSHAuthentication) async throws {
        if case .keyboardInteractive(let responder) = method {
            try await onQueue { $0.keyboardResponder = responder }
        }
        defer { queue.async { self.keyboardResponder = nil } }

        try await perform(abandonable: false) { session -> Step<Void> in
            guard let pointer = session.session else { return .failed(.disconnected) }
            let status: Int32
            switch method {
            case .password(let password):
                status = marionette_ssh2_userauth_password(pointer, username, password)
            case .privateKey(let key, let passphrase):
                status = key.withUnsafeBytes { bytes in
                    libssh2_userauth_publickey_frommemory(
                        pointer, username, username.utf8.count, nil, 0,
                        bytes.bindMemory(to: CChar.self).baseAddress, bytes.count, passphrase
                    )
                }
            case .signer(let publicKey, let sign):
                // The callback runs within the call, so the box lives exactly as long as it.
                let box = Unmanaged.passRetained(SignerBox(sign))
                defer { box.release() }
                var abstract: UnsafeMutableRawPointer? = box.toOpaque()
                status = publicKey.withUnsafeBytes { bytes in
                    libssh2_userauth_publickey(
                        pointer, username, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                        { _, signature, signatureLength, data, dataLength, abstract in
                            guard let owner = abstract?.pointee, let signature, let signatureLength, let data else { return -1 }
                            let box = Unmanaged<SignerBox>.fromOpaque(owner).takeUnretainedValue()
                            guard let signed = box.sign(Data(bytes: data, count: dataLength)), !signed.isEmpty,
                                  let buffer = malloc(signed.count)?.assumingMemoryBound(to: UInt8.self)
                            else { return -1 }
                            // libssh2 frees it with its allocator, which is malloc's.
                            signed.copyBytes(to: buffer, count: signed.count)
                            signature.pointee = buffer
                            signatureLength.pointee = signed.count
                            return 0
                        },
                        &abstract
                    )
                }
            case .keyboardInteractive:
                status = marionette_ssh2_userauth_keyboard_interactive(pointer, username) { name, nameLength, instruction, instructionLength, count, prompts, responses, abstract in
                    guard let owner = abstract?.pointee, count > 0, let prompts, let responses else { return }
                    let session = Unmanaged<SSHSession>.fromOpaque(owner).takeUnretainedValue()
                    func text(_ pointer: UnsafePointer<CChar>?, _ length: Int32) -> String {
                        guard let pointer, length > 0 else { return "" }
                        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
                    }
                    let challenge = SSHKeyboardInteractiveChallenge(
                        name: text(name, nameLength), instruction: text(instruction, instructionLength),
                        prompts: (0..<Int(count)).map { index in
                            let prompt = prompts[index]
                            let bytes = UnsafeRawBufferPointer(start: prompt.text, count: Int(prompt.length))
                            return .init(text: String(decoding: bytes, as: UTF8.self), echoesInput: prompt.echo != 0)
                        }
                    )
                    // libssh2 wants the answers before this callback returns. The session's queue has
                    // nothing else to do during authentication, so it waits here for the responder.
                    guard let responder = session.keyboardResponder else { return }
                    let answers = AnswerBox()
                    let done = DispatchSemaphore(value: 0)
                    Task {
                        answers.values = await responder(challenge)
                        done.signal()
                    }
                    done.wait()
                    for index in 0..<Int(count) {
                        let answer = index < answers.values.count ? answers.values[index] : ""
                        // libssh2 frees these with free().
                        responses[index].text = strdup(answer)
                        responses[index].length = UInt32(answer.utf8.count)
                    }
                }
            }
            switch status {
            case 0:
                return .done(())
            case LIBSSH2_ERROR_EAGAIN:
                return .again
            case LIBSSH2_ERROR_AUTHENTICATION_FAILED, LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED, LIBSSH2_ERROR_PASSWORD_EXPIRED:
                return .failed(.authenticationFailed)
            case LIBSSH2_ERROR_FILE, LIBSSH2_ERROR_KEYFILE_AUTH_FAILED, LIBSSH2_ERROR_METHOD_NONE, LIBSSH2_ERROR_ALGO_UNSUPPORTED:
                return .failed(.unusableKey(session.lastErrorMessage()))
            default:
                return .failed(.library(code: status, message: session.lastErrorMessage()))
            }
        }
    }

    /// Carries the responder's answers from its task back to the waiting callback.
    private final class AnswerBox: @unchecked Sendable {
        var values: [String] = []
    }

    // MARK: Channels

    /// Opens a connection from the server to `host:port` and returns it as a byte stream: one end
    /// of a tunnel, with a receive window of ``tunnelWindow``.
    ///
    /// The server answers once its own connection succeeds or fails, which for a destination that
    /// drops packets takes the server's connect timeout (a minute or more). After `timeout`, or
    /// when the caller is cancelled, this gives up with ``SSHError/timedOut`` or
    /// `CancellationError`; the open still runs out in the background, and the channel is closed
    /// if it opens. libssh2 opens one channel at a time, so later opens wait for it too.
    public func openTunnel(toHost host: String, port: UInt16, timeout: Duration? = nil) async throws -> SSHChannel {
        let channel = try await cancelling(after: timeout) {
            try await self.perform(.finishInBackground({ late in
                let orphan = SSHChannel(session: self, channel: late)
                Task { await orphan.close() }
            })) { session -> Step<LibraryPointer> in
                guard let pointer = session.session else { return .failed(.disconnected) }
                if let channel = marionette_ssh2_channel_direct_tcpip(pointer, host, Int32(port), "127.0.0.1", 0, Self.tunnelWindow) {
                    return .done(LibraryPointer(raw: channel))
                }
                let code = session.lastError()
                if code == LIBSSH2_ERROR_EAGAIN { return .again }
                if code == LIBSSH2_ERROR_CHANNEL_FAILURE { return .failed(.channelRefused(session.lastErrorMessage())) }
                return .failed(.library(code: code, message: session.lastErrorMessage()))
            }
        }
        return SSHChannel(session: self, channel: channel)
    }

    public struct CommandResult: Sendable, Equatable {
        public var standardOutput: Data
        public var standardError: Data
        public var exitStatus: Int32

        public init(standardOutput: Data, standardError: Data, exitStatus: Int32) {
            self.standardOutput = standardOutput
            self.standardError = standardError
            self.exitStatus = exitStatus
        }
    }

    /// Runs a command on the server and collects what it prints.
    public func run(_ command: String) async throws -> CommandResult {
        let pointer = try await perform(abandonable: false) { session -> Step<LibraryPointer> in
            guard let pointer = session.session else { return .failed(.disconnected) }
            if let channel = marionette_ssh2_channel_open_session(pointer) { return .done(LibraryPointer(raw: channel)) }
            let code = session.lastError()
            return code == LIBSSH2_ERROR_EAGAIN ? .again : .failed(.channelRefused(session.lastErrorMessage()))
        }
        let channel = SSHChannel(session: self, channel: pointer)
        do {
            try await perform(abandonable: false) { session -> Step<Void> in
                let status = marionette_ssh2_channel_exec(pointer.raw, command)
                if status == LIBSSH2_ERROR_EAGAIN { return .again }
                return status == 0 ? .done(()) : .failed(.channelRefused(session.lastErrorMessage()))
            }
            var output = Data()
            var errors = Data()
            var outputOpen = true
            var errorsOpen = true
            while outputOpen || errorsOpen {
                // Noted before looking: reading one stream takes in whatever has arrived for both,
                // so "nothing to read" on the first may be out of date by the time the second answers.
                let seen = try await onQueue { $0.arrivals }
                var progressed = false
                if outputOpen {
                    if let data = try await channel.read(upTo: 1 << 15, stream: 0, waits: !errorsOpen) {
                        output.append(data)
                        progressed = progressed || !data.isEmpty
                    } else {
                        outputOpen = false
                    }
                }
                if errorsOpen {
                    if let data = try await channel.read(upTo: 1 << 15, stream: 1, waits: !outputOpen) {
                        errors.append(data)
                        progressed = progressed || !data.isEmpty
                    } else {
                        errorsOpen = false
                    }
                }
                if outputOpen, errorsOpen, !progressed { try await channel.waitForArrival(after: seen) }
            }
            // The exit status travels just ahead of the server's close; wait for that before asking.
            try await perform(abandonable: false) { session -> Step<Void> in
                guard session.session != nil else { return .failed(.disconnected) }
                return libssh2_channel_close(pointer.raw) == LIBSSH2_ERROR_EAGAIN ? .again : .done(())
            }
            try await perform(abandonable: false) { session -> Step<Void> in
                guard session.session != nil else { return .failed(.disconnected) }
                return libssh2_channel_wait_closed(pointer.raw) == LIBSSH2_ERROR_EAGAIN ? .again : .done(())
            }
            let status = try await onQueue { session in
                session.session == nil ? -1 : libssh2_channel_get_exit_status(pointer.raw)
            }
            await channel.close()
            return CommandResult(standardOutput: output, standardError: errors, exitStatus: status)
        } catch {
            await channel.close()
            throw error
        }
    }

    public func openSFTP() async throws -> SFTPClient {
        let pointer = try await perform(abandonable: false) { session -> Step<LibraryPointer> in
            guard let pointer = session.session else { return .failed(.disconnected) }
            if let sftp = libssh2_sftp_init(pointer) { return .done(LibraryPointer(raw: sftp)) }
            let code = session.lastError()
            return code == LIBSSH2_ERROR_EAGAIN ? .again : .failed(.library(code: code, message: session.lastErrorMessage()))
        }
        return SFTPClient(session: self, sftp: pointer)
    }

    // MARK: Disconnecting

    /// Says goodbye and closes the transport. Channels and SFTP clients of this session stop working.
    public func disconnect() async {
        let wasOpen = (try? await onQueue { session -> Bool in
            guard !session.isClosed else { return false }
            session.isClosed = true
            return true
        }) ?? false
        guard wasOpen else { return }
        _ = try? await perform(abandonable: false) { session -> Step<Void> in
            guard let pointer = session.session, session.transportEnded == nil else { return .done(()) }
            return marionette_ssh2_session_disconnect(pointer, "bye") == LIBSSH2_ERROR_EAGAIN ? .again : .done(())
        }
        let (tasks, continuation) = (try? await onQueue { session -> ([Task<Void, Never>], AsyncStream<Data>.Continuation?) in
            if let pointer = session.session {
                libssh2_session_free(pointer)
                session.session = nil
            }
            if session.placeholderSocket >= 0 {
                Darwin.close(session.placeholderSocket)
                session.placeholderSocket = -1
            }
            let stranded = session.parked
            session.parked.removeAll()
            for entry in stranded { entry.fail(.disconnected) }
            defer {
                session.tasks = []
                session.outboundContinuation = nil
            }
            return (session.tasks, session.outboundContinuation)
        }) ?? ([], nil)
        // Let the goodbye reach the wire, then stop; but not for longer than a peer that is still
        // there needs: on a dead path the writer may never finish.
        continuation?.finish()
        let transport = transport
        await withTaskGroup(of: Void.self) { group in
            if let writer = tasks.first { group.addTask { await writer.value } }
            group.addTask { try? await Task.sleep(for: Self.closeGrace) }
            await group.next()
            group.cancelAll()
            for task in tasks { task.cancel() }
            // Closing ends a write still in progress, and with it the writer.
            await transport.close()
        }
    }
}

/// Set once, read from anywhere.
final class Latch: Sendable {
    private let state = Mutex(false)

    var isSet: Bool { state.withLock { $0 } }

    func set() {
        state.withLock { $0 = true }
    }
}
