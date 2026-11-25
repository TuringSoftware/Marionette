// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDCrypto
public import ARDProtocol
public import Foundation
public import RemoteDesktopCore
import Synchronization

/// One control connection to a Mac: the handshake, the record layer, and the message stream.
///
/// This is the layer below a session. It knows how to get to an encrypted, authenticated
/// connection and how to exchange messages over it; what the messages are used for is the caller's
/// business.
public actor ARDConnection {
    public struct Configuration: Sendable {
        /// Ask for the session-select exchange when someone else is at the console.
        public var requestsSessionSelect = false
        public var viewerMode: ViewerMode = .control
        /// Have the Mac watch its pasteboard and announce changes.
        public var watchesPasteboard = true
        /// Ask for the encrypted record layer. Apple's own viewer leaves the session in clear after
        /// the login unless told otherwise; this client always encrypts outside of experiments.
        public var encryptsSession = true
        /// Identify the viewer to the Mac. Without it the Mac sends no status notifications.
        public var sendsViewerInfo = true
        /// Log in only with SRP, which proves the Mac holds the password; a Mac offering only
        /// type 30 is refused before the password is sent. For a Mac known to offer SRP, where
        /// its absence means something in the middle stripped it.
        public var requiresSRP = false
        /// Refuse a session that would not be encrypted: logins that agree no key (the classic VNC
        /// password) are not used, and a server that will not encrypt the session is refused
        /// before anything but the login is sent. For a computer whose sessions were encrypted before.
        public var requiresEncryption = false
        /// Source of secret random bytes. Replaced in tests to make exchanges reproducible.
        public var random: any RandomSource = SystemRandomSource()
        /// The login types to choose from, most preferred first. For protocol experiments; the
        /// default is ``ARDConnection/supportedSecurityTypes``.
        public var securityTypes: [SecurityType] = ARDConnection.supportedSecurityTypes
        /// Debug builds only: receives the session's secret keys as text lines, so that a capture of
        /// this client's own traffic can be decrypted. Ignored in release builds.
        public var keyLog: (@Sendable (String) -> Void)?
        /// How long the chosen login type stands alone before SRP's first message follows. A Mac's
        /// screensharingd must read the type byte by itself: on macOS 15.6, finding the type byte and
        /// message 1 in one read, it takes four bytes too many, then loops on "SRP invalid step" at
        /// several cores and refuses every later login until the daemon restarts (macOS 27 recovers).
        /// Screen Sharing.app asks for the password in between, so a Mac never sees them together.
        public var pauseAfterLoginType: Duration = .milliseconds(250)
        /// The versions ViewerInfo gives. For protocol experiments.
        public var viewerVersions = ClientMessage.viewerVersions

        public init() {}
    }

    /// What the handshake established.
    public struct Established: Sendable {
        public var serverInit: ServerInit
        public var offeredSecurityTypes: [SecurityType]
        public var usedSecurityType: SecurityType
        /// Whether the record layer encrypts the session.
        public var isEncrypted = true
        /// The key for `EncryptedInputEvent` messages (the record layer's), when the session is
        /// encrypted and the server takes them.
        public var inputKey: Data?
    }

    /// What the first half of the handshake established.
    public struct LoggedIn: Sendable {
        public var serverInit: ServerInit
        public var offeredSecurityTypes: [SecurityType]
        public var usedSecurityType: SecurityType
        /// Present when someone else is using the Mac's display and the viewer asked to choose.
        public var sessionSelect: SessionSelectOffer?
    }

    private let stream: any ByteStream
    /// The login's key: what the rekey and session-select credentials are wrapped under. None
    /// after a VNC-password login.
    private var wrapKey: Data?
    private var loggedIn: LoggedIn?
    private let configuration: Configuration
    private let outbound: ARDOutbound
    private var wire = InboundBuffer()
    private var plain = InboundBuffer()
    private var opener: RecordOpener?
    private var parser = ServerMessageParser()
    private var isClosed = false
    private var isEstablished = false
    private let lastReceipt = Mutex(ContinuousClock.now)

    /// When bytes last arrived from the Mac. A Mac sends a status message about every two seconds
    /// whatever else is going on, so a long silence means the path or the Mac is gone.
    public nonisolated var lastReceivedAt: ContinuousClock.Instant { lastReceipt.withLock { $0 } }

    /// Login types this client can perform, most preferred first. SRP proves the Mac as well as
    /// the viewer, and never exposes the password; type 30 does neither, and is used only with a
    /// Mac that does not offer SRP. (Falling back after a failed SRP login would hand a machine in
    /// the middle the password, so it is never done.)
    ///
    /// Type 2, the classic VNC password, comes last and only where a Mac offers neither of the
    /// others. It proves nothing about the Mac, and it agrees no key: a Mac cannot start the record
    /// layer after it, so the whole session, input and pasteboard included, travels in clear.
    static let supportedSecurityTypes: [SecurityType] = [.srp, .diffieHellman, .vncPassword]

    /// Whether a server offering `types` is a Mac rather than another server of Apple's protocol,
    /// such as wayshare on Linux. Every Mac seen offers types 30 and 33 beside 36; wayshare offers 36
    /// alone (adding 30 only in a development mode this does not cover). The two differ in framing
    /// and timing, never in what is checked: a wrong guess costs the login, not the password.
    static func isMac(offering types: [SecurityType]) -> Bool {
        types.contains(.diffieHellman) || types.contains(.rsa)
    }

    public init(stream: any ByteStream, configuration: Configuration = Configuration()) {
        self.stream = stream
        self.configuration = configuration
        outbound = ARDOutbound(stream: stream) { _ in
            // A failed write shows up as a failed read moments later; nothing to do here.
        }
    }

    // MARK: Handshake

    /// Runs the whole opening exchange: version, login, initialisation, and the switch to the
    /// encrypted record layer. On return, both directions are encrypted and the Mac knows the
    /// viewer; the caller picks a mode next. A Mac that offers session select (only when
    /// ``Configuration/requestsSessionSelect`` is set) makes this fail; use ``logIn(username:password:)``,
    /// ``selectSession(_:viewerName:username:password:)`` and ``open()`` for that.
    public func handshake(username: String, password: String) async throws(ARDError) -> Established {
        let loggedIn = try await logIn(username: username, password: password)
        guard loggedIn.sessionSelect == nil else {
            throw .unsupported("the Mac asks how to share its display, and nobody is here to answer")
        }
        return try await open()
    }

    /// Reads the version the server opens with and refuses anything but Apple's 003.889, before
    /// anything is sent: what is not a Mac is left to another back end. ``logIn(username:password:)``
    /// does this itself if it has not been done; doing it first lets a caller ask for the Mac's
    /// credentials only once it knows a Mac is answering.
    public func expectAppleServer() async throws(ARDError) {
        guard !hasCheckedServerVersion else { return }
        let serverVersion = try await read { (reader: inout WireReader) throws(WireError) in try ProtocolVersion.parse(&reader) }
        guard serverVersion == .apple else {
            throw .otherProtocol(String(localized: "The computer isn’t a Mac with Screen Sharing (it speaks RFB \(serverVersion.description)).", bundle: #bundle))
        }
        hasCheckedServerVersion = true
    }

    private var hasCheckedServerVersion = false

    /// The first half of the opening exchange: version, login, ClientInit and ServerInit, and the
    /// Mac's session-select offer if it sends one.
    public func logIn(username: String, password: String) async throws(ARDError) -> LoggedIn {
        try await expectAppleServer()
        outbound.send(ProtocolVersion.apple.encoded)

        let offered: [SecurityType]
        switch try await read({ (reader: inout WireReader) throws(WireError) in try SecurityOffer.parse(&reader) }) {
        case .refused(let reason):
            throw .refused(reason: reason)
        case .types(let types):
            offered = types
        }
        // A classic VNC password agrees no key, so a session after it cannot be encrypted.
        let usable = configuration.requiresEncryption ? configuration.securityTypes.filter { $0 != .vncPassword } : configuration.securityTypes
        guard let chosen = usable.first(where: offered.contains) else {
            if configuration.requiresEncryption, configuration.securityTypes.contains(where: offered.contains) {
                throw .notEncrypted("the server offers only a login after which the session cannot be encrypted (offered \(offered))")
            }
            throw .unsupported("the server offers no login this client can perform (offered \(offered))")
        }
        guard chosen == .srp || !configuration.requiresSRP else {
            throw .unsupported("the server offers no login that proves its identity (offered \(offered))")
        }
        outbound.send(Data([chosen.rawValue]))
        if chosen == .srp {
            // SRP is the one login where the viewer speaks next; the others wait for the Mac.
            try? await Task.sleep(for: configuration.pauseAfterLoginType)
        }

        let wrapKey: Data?
        switch chosen {
        case .srp:
            wrapKey = try await logInWithSRP(username: username, password: password, repeatsType: Self.isMac(offering: offered))
        case .vncPassword:
            try await logInWithVNCPassword(password)
            wrapKey = nil
        default:
            wrapKey = try await logInWithDiffieHellman(username: username, password: password)
        }

        let result = try await read { (reader: inout WireReader) throws(WireError) in try reader.u32() }
        guard result == 0 else {
            // To a 003.889 viewer the Mac sends the result word alone: no reason follows.
            throw .authenticationFailed
        }

        var flags: ClientInitFlags = [.shared, .extended]
        if configuration.requestsSessionSelect { flags.insert(.sessionSelect) }
        outbound.send(ClientMessage.clientInit(flags))
        let serverInit = try await read { (reader: inout WireReader) throws(WireError) in try ServerInit.parse(&reader, extended: true) }
        guard let serverFlags = serverInit.flags else {
            throw .unsupported("the server did not answer with Apple's extended initialisation")
        }
        parser.pixelFormat = serverInit.pixelFormat
        var offer: SessionSelectOffer?
        if serverFlags.contains(.sessionSelectFollows) {
            guard configuration.requestsSessionSelect else {
                throw .protocolViolation("the Mac sent a session-select offer that was not asked for")
            }
            offer = try await read { (reader: inout WireReader) throws(WireError) in try SessionSelectOffer.parse(&reader) }
        }
        self.wrapKey = wrapKey
        let loggedIn = LoggedIn(serverInit: serverInit, offeredSecurityTypes: offered, usedSecurityType: chosen, sessionSelect: offer)
        self.loggedIn = loggedIn
        return loggedIn
    }

    /// Answers the Mac's session-select offer, and waits for its verdict. Asking the console user
    /// waits for as long as they take to answer; close the connection to give up. After
    /// ``SessionSelectResult/declined(_:)`` the offer stands again and may be answered again.
    public func selectSession(_ command: SessionSelectCommand, viewerName: String, username: String, password: String) async throws(ARDError) -> SessionSelectResult {
        guard loggedIn?.sessionSelect != nil, !isEstablished else {
            throw .protocolViolation("no session-select offer to answer")
        }
        var credentials = Data()
        if command == .logInAsSelf {
            // The credentials are sealed under the login's key, which a VNC-password login has not.
            guard let wrapKey else { throw .unsupported("logging in to a session of one's own needs an account login") }
            do {
                credentials = try DiffieHellmanLogin.sealCredentials(username: username, password: password, key: wrapKey, random: configuration.random)
            } catch {
                throw .credentialTooLong
            }
        }
        outbound.send(SessionSelectAnswer(command: command, viewerName: viewerName, sealedCredentials: credentials).encoded)
        return try await read { (reader: inout WireReader) throws(WireError) in try SessionSelectResult.parse(&reader) }
    }

    /// The second half of the opening exchange: the viewer's prelude and the switch to the
    /// encrypted record layer.
    public func open() async throws(ARDError) -> Established {
        guard let loggedIn, !isEstablished else {
            throw .protocolViolation("the connection is not logged in")
        }
        let serverInit = loggedIn.serverInit
        // A Mac always offers the record layer. wayshare does only when started with
        // `--stream-encryption`; otherwise the session, typing included, goes in clear, which is
        // the server's choice to make. The session then says it is not encrypted, and the front end
        // marks it as not secure.
        let offersRecords = serverInit.acceptedMessages?.contains(ClientMessageType.setEncryption) == true
        // A Mac always offers the record layer after a login with a key. One that says otherwise
        // was told to by something between it and this device: what follows the login (this
        // ServerInit included) is not covered by the login's proof.
        if wrapKey != nil, !offersRecords, Self.isMac(offering: loggedIn.offeredSecurityTypes) {
            throw .notEncrypted("the Mac says it will not encrypt the session, which a Mac always does")
        }
        let encrypts = configuration.encryptsSession && wrapKey != nil && offersRecords
        if configuration.requiresEncryption, !encrypts {
            throw .notEncrypted("the server will not encrypt the session")
        }
        var inputKey: Data?

        // The prelude goes out back to back, in clear. Status notifications only flow once the Mac
        // has seen the viewer's identity, mode and pasteboard request, in that order, and the
        // pasteboard request is ignored if it arrives inside the record layer.
        if configuration.sendsViewerInfo {
            outbound.send(ClientMessage.viewerInfo(versions: configuration.viewerVersions))
        }
        outbound.send(ClientMessage.setMode(configuration.viewerMode))
        if configuration.watchesPasteboard {
            outbound.send(ClientMessage.autoPasteboard(true))
        }
        if encrypts, let wrapKey {
            outbound.send(ClientMessage.startEncryption())
            // wayshare reads the switch of its own input in a task of its own, and drops the
            // connection if the switch overtakes the keys it is sending: it gets it after them.
            let switchesAtOnce = Self.isMac(offering: loggedIn.offeredSecurityTypes)
            if switchesAtOnce { outbound.send(ClientMessage.enableInboundDecryption()) }

            let keys = try await awaitRekey(wrapKey: wrapKey)
            #if DEBUG
            configuration.keyLog?("RECORD key=\(keys.key.hexString) iv=\(keys.iv.hexString)")
            #endif
            do {
                opener = try RecordOpener(keys: keys)
            } catch {
                throw ARDError(error)
            }
            if !switchesAtOnce { outbound.send(ClientMessage.enableInboundDecryption()) }
            try outbound.startSealing(with: keys)
            if serverInit.acceptedMessages?.contains(ClientMessageType.encryptedInputEvent) == true { inputKey = keys.key }
        }
        isEstablished = true

        return Established(
            serverInit: serverInit, offeredSecurityTypes: loggedIn.offeredSecurityTypes, usedSecurityType: loggedIn.usedSecurityType,
            isEncrypted: opener != nil, inputKey: inputKey
        )
    }

    /// Security type 36. Returns the key the rekey is wrapped under, once the Mac has proved it
    /// holds the account's verifier.
    private func logInWithSRP(username: String, password: String, repeatsType: Bool) async throws(ARDError) -> Data {
        do {
            outbound.send(try SRPLogin.firstMessage(username: username, repeatsType: repeatsType))
        } catch {
            throw .credentialTooLong
        }
        let challenge = try await read { (reader: inout WireReader) throws(WireError) in try SRPLogin.Challenge.parse(&reader) }
        // A tenth of a second of PBKDF2 and three 4096-bit exponentiations: off the shared pool.
        let random = configuration.random
        let outcome: Result<SRPLogin.Response, SRPLogin.LoginError> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do throws(SRPLogin.LoginError) {
                    continuation.resume(returning: .success(try SRPLogin.respond(to: challenge, password: password, random: random)))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        let response: SRPLogin.Response
        switch outcome {
        case .success(let value):
            response = value
        case .failure(.credentialTooLong):
            throw .credentialTooLong
        case .failure(.invalidParameters(let detail)):
            throw .protocolViolation(detail)
        case .failure(let error):
            throw .protocolViolation("SRP login: \(error)")
        }
        outbound.send(response.message)
        switch try await read({ (reader: inout WireReader) throws(WireError) in try SRPLogin.parseVerdict(&reader) }) {
        case .refused:
            throw .authenticationFailed
        case .accepted(let serverProof):
            do {
                try SRPLogin.verify(serverProof: serverProof, expected: response.expectedServerProof)
            } catch {
                throw .serverNotAuthenticated
            }
        }
        return response.wrapKey
    }

    /// Security type 2: the server's 16-byte challenge, encrypted with DES under the password.
    private func logInWithVNCPassword(_ password: String) async throws(ARDError) {
        let challenge = try await read { (reader: inout WireReader) throws(WireError) in try reader.take(16) }
        do {
            outbound.send(try VNCPasswordLogin.response(to: challenge, password: password))
        } catch {
            throw .protocolViolation("VNC password login: \(error)")
        }
    }

    /// Security type 30. Returns the key the rekey is wrapped under.
    private func logInWithDiffieHellman(username: String, password: String) async throws(ARDError) -> Data {
        let challenge = try await read { (reader: inout WireReader) throws(WireError) in try DiffieHellmanLogin.Challenge.parse(&reader) }
        // The exchange is a pair of 4096-bit exponentiations: a tenth of a second optimised, seconds
        // unoptimised. It runs on a thread of its own so that it does not hold up the shared pool
        // that timers and every other task run on.
        let random = configuration.random
        let outcome: Result<DiffieHellmanLogin.Response, DiffieHellmanLogin.LoginError> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do throws(DiffieHellmanLogin.LoginError) {
                    continuation.resume(returning: .success(try DiffieHellmanLogin.respond(to: challenge, username: username, password: password, random: random)))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        let response: DiffieHellmanLogin.Response
        do throws(DiffieHellmanLogin.LoginError) {
            response = try outcome.get()
        } catch .credentialTooLong {
            throw .credentialTooLong
        } catch .invalidParameters {
            throw .protocolViolation("unusable Diffie-Hellman parameters")
        } catch {
            throw .protocolViolation("login cryptography failed: \(error)")
        }
        outbound.send(response.message)
        return response.wrapKey
    }

    /// Reads the clear stream until the rekey. Nothing was asked for yet, so all a Mac may send
    /// first is a bell or a status notification.
    private func awaitRekey(wrapKey: Data) async throws(ARDError) -> RecordKeys {
        while true {
            switch try await nextClearEvent() {
            case .bell, .status, .updateEnded, .notice:
                continue
            case .updateBegan(let count):
                guard count <= 1 else {
                    // Everything after the rekey rectangle is ciphertext, so it must be alone.
                    throw .protocolViolation("the rekey update carries \(count) rectangles")
                }
            case .rectangle(let rectangle):
                guard case .rekey(let body) = rectangle.body else {
                    throw .protocolViolation("rectangle \(rectangle.header.encoding) arrived before the record layer")
                }
                do {
                    return try RecordKeys.unwrap(body, wrapKey: wrapKey).keys
                } catch {
                    throw ARDError(error)
                }
            case .cutText, .pasteboard, .drag, .dropDestination, .fileTransfer:
                throw .protocolViolation("unexpected message before the record layer")
            }
        }
    }

    private func nextClearEvent() async throws(ARDError) -> ServerEvent {
        while true {
            do {
                if let event = try parser.next(from: &wire) { return event }
            } catch {
                throw ARDError(error)
            }
            try await fill()
        }
    }

    // MARK: Messages

    /// Queues a message for the Mac. Never blocks; safe from any thread.
    public nonisolated func send(_ message: Data) {
        outbound.send(message)
    }

    /// Bytes queued for the Mac and not yet written.
    public nonisolated var queuedBytes: Int { outbound.queuedBytes }

    /// Waits until fewer than `limit` bytes wait to be written. For bulk senders. Throws when the
    /// connection fails or ends, when the task is cancelled, and after 30 s in which nothing was written.
    public nonisolated func waitForSendRoom(below limit: Int) async throws(ARDError) {
        try await outbound.waitForRoom(below: limit)
    }

    /// Tells the Mac which pixel format to send, and the parser which to expect.
    public func setPixelFormat(_ format: PixelFormat) {
        parser.pixelFormat = format
        outbound.send(ClientMessage.setPixelFormat(format))
    }

    /// The next event from the Mac, or `nil` once it has closed the connection cleanly.
    public func nextEvent() async throws(ARDError) -> ServerEvent? {
        guard isEstablished else { throw .protocolViolation("the handshake has not completed") }
        while true {
            do {
                try opener?.open(from: &wire, into: &plain)
                let event = opener == nil ? try parser.next(from: &wire) : try parser.next(from: &plain)
                if let event {
                    if case .rectangle(let rectangle) = event, case .rekey = rectangle.body {
                        // The Mac rotates keys only when asked, and this client asks once. Following
                        // an unrequested rotation would break records already sealed under the old key.
                        throw ARDError.protocolViolation("the server re-keyed mid-session")
                    }
                    return event
                }
            } catch {
                throw ARDError(error)
            }
            do {
                try await fill()
            } catch .closedByPeer {
                if wire.isEmpty, plain.isEmpty, !parser.isInsideUpdate { return nil }
                throw .closedByPeer
            }
        }
    }

    /// Closes the connection after sending what is already queued, waiting at most `drainLimit`
    /// for it: on a dead path the queue never drains, and closing the stream is what ends the
    /// write that waits.
    public func close(drainLimit: Duration = .seconds(1)) async {
        guard !isClosed else { return }
        isClosed = true
        outbound.finish()
        let outbound = outbound
        let drained = Mutex(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            @Sendable func resumeOnce() {
                let first = drained.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume() }
            }
            Task {
                await outbound.drained()
                resumeOnce()
            }
            Task {
                try? await Task.sleep(for: drainLimit)
                resumeOnce()
            }
        }
        await stream.close()
    }

    // MARK: Reading

    private func fill() async throws(ARDError) {
        let data: Data?
        do {
            data = try await stream.read(upTo: 1 << 18)
        } catch {
            throw ARDError(error)
        }
        guard let data else { throw .closedByPeer }
        lastReceipt.withLock { $0 = .now }
        wire.append(data)
    }

    /// Parses one item off the clear stream, reading more as needed. Handshake only.
    private func read<T: Sendable>(_ parse: (inout WireReader) throws(WireError) -> T) async throws(ARDError) -> T {
        while true {
            do {
                if let value = try wire.parse(parse) { return value }
            } catch {
                throw ARDError(error)
            }
            try await fill()
        }
    }
}

extension Data {
    /// Lower-case hexadecimal, for key logs.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
