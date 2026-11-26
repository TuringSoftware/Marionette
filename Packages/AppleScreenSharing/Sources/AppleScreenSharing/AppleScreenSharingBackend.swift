// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import ARDProtocol
import Foundation
import Network
public import RemoteDesktopCore
import RemoteDesktopDecode
import Synchronization

/// The back end for the Screen Sharing server built into macOS: Apple's RFB 003.889, in
/// High Performance mode where the Mac and the path allow it and Standard mode otherwise.
public struct AppleScreenSharingBackend: RemoteDesktopBackend {
    public static let backendID = "apple-screen-sharing"

    /// How long the opening exchange may take, and how long a mode may take to show its first picture.
    public var handshakeTimeout: Duration = .seconds(20)
    public var firstPictureTimeout: Duration = .seconds(20)
    /// How long a High Performance stream may send pictures that all arrive broken before the
    /// path is called too lossy for it. The Mac makes one keyframe a second and resends nothing,
    /// so this is about five tries; a path that fails them all would give a poor session anyway,
    /// and Standard mode, which travels over TCP, is the better choice there.
    public var mediaStartTimeout: Duration = .seconds(6)
    /// Receives a line for each step of a session's set-up and each media event worth a note:
    /// for tools and support logs. Called from any thread; must not block.
    public var diagnostics: (@Sendable (String) -> Void)?

    /// Which picture codec to ask a Mac for in High Performance.
    public enum VideoCodecPreference: Sendable, Hashable {
        /// HEVC 4:4:4 where this device decodes it in hardware, H.264 elsewhere.
        case automatic
        /// HEVC Range Extensions 4:4:4: sharper text and colour, half the bit rate of H.264.
        case hevc
        /// H.264 4:2:0, which every device decodes. A Mac makes no refresh pictures in H.264, so
        /// every lost packet costs a keyframe.
        case h264
    }

    public var videoCodec: VideoCodecPreference = .automatic

    /// The time limits sessions run by; tests shorten them.
    var sessionTiming = SessionTiming()

    /// The login types to choose from in place of the usual order. For protocol experiments only
    /// (`marionettectl --login vnc`): the app always prefers a login that proves the Mac.
    @_spi(Diagnostics) public var loginTypes: [SecurityType]?
    /// The versions ViewerInfo gives (protocol experiments).
    @_spi(Diagnostics) public var viewerVersions: (application: [UInt32], system: [UInt32])?

    /// The media configuration High Performance starts in. For measuring the constrained one
    /// (`marionettectl`); sessions step down to it on their own.
    @_spi(Diagnostics) public var startsConstrained: Bool {
        get { sessionTiming.bandwidthProfile == .constrained }
        set { sessionTiming.bandwidthProfile = newValue ? .constrained : .full }
    }

    /// Debug builds only: receives every secret key a session uses (the record layer's, and each
    /// media offer's SRTP master keys) as text lines, so a capture of this client's own traffic can
    /// be decrypted. Release builds never call it.
    @_spi(Diagnostics) public var keyLog: (@Sendable (String) -> Void)? {
        get { sessionTiming.keyLog }
        set { sessionTiming.keyLog = newValue }
    }

    /// Whether Standard mode tells the Mac it shows every display (`SetDisplay` with none named),
    /// as Screen Sharing.app does. Off only for protocol experiments (`marionettectl`).
    @_spi(Diagnostics) public var saysEveryDisplay: Bool {
        get { sessionTiming.saysEveryDisplay }
        set { sessionTiming.saysEveryDisplay = newValue }
    }

    /// Whether keys and pointer events are sent encrypted (`EncryptedInputEvent`) when the Mac
    /// takes them. Off only to compare with plain events (`marionettectl`).
    @_spi(Diagnostics) public var encryptsInput: Bool {
        get { sessionTiming.encryptsInput }
        set { sessionTiming.encryptsInput = newValue }
    }

    /// Whether input is held around High Performance display changes, which a Mac otherwise
    /// discards. Off only to measure that loss (`marionettectl`).
    @_spi(Diagnostics) public var holdsInputAroundDisplayChanges: Bool {
        get { sessionTiming.holdsInputAroundDisplayChanges }
        set { sessionTiming.holdsInputAroundDisplayChanges = newValue }
    }

    public init() {}

    public var descriptor: BackendDescriptor {
        BackendDescriptor(
            id: Self.backendID,
            displayName: String(localized: "Mac Screen Sharing", bundle: #bundle),
            defaultPort: 5900,
            bonjourServiceType: "_rfb._tcp",
            supportedModes: [.highPerformance, .standard]
        )
    }

    public func connect(_ request: ConnectionRequest) async throws(ConnectionFailure) -> any RemoteSession {
        let transport = request.transport
        let host = transport.peer.host
        var previousFailure: String?

        for attempt in 1...3 {
            // A refused login leaves the connection unusable, so each attempt is a new connection.
            // Phases are reported in their documented order and never go back: a second attempt
            // at the password is still part of signing in.
            if attempt == 1 {
                if transport.isTunnelled { request.progress(.openingTunnel) }
                request.progress(.reachingHost)
            }
            let stream: any ByteStream
            do {
                stream = try await transport.openStream(port: transport.peer.port)
            } catch {
                throw Self.failure(for: error, host: host)
            }
            if Task.isCancelled {
                await stream.close()
                throw .cancelled
            }

            if attempt == 1 { request.progress(.negotiating) }
            var configuration = ARDConnection.Configuration()
            configuration.viewerMode = Self.viewerMode(request.options.controlMode)
            configuration.watchesPasteboard = request.options.wantsClipboard
            // As Screen Sharing.app does: when someone else is using the Mac, the person connecting
            // chooses between asking them and a session of their own.
            configuration.requestsSessionSelect = true
            configuration.keyLog = keyLog
            if let loginTypes { configuration.securityTypes = loginTypes }
            if let viewerVersions { configuration.viewerVersions = viewerVersions }
            configuration.requiresSRP = request.options.requiresServerAuthentication
            // Through a tunnel the tunnel encrypts; the requirement is about the network.
            configuration.requiresEncryption = request.options.requiresEncryption && !request.transport.isTunnelled
            let connection = ARDConnection(stream: stream, configuration: configuration)

            // What answers is checked before anything is asked: a server that is not a Mac is left
            // to another back end, without a question about a Mac's account first.
            do throws(TimedError) {
                try await Self.withTimeout(handshakeTimeout, phase: .negotiating, onTimeout: { await stream.close() }) {
                    () async throws(ARDError) in try await connection.expectAppleServer()
                }
            } catch {
                await connection.close()
                if case .failed(let failure) = error { throw failure }
                throw .timedOut(phase: .negotiating)
            }

            let prompt = SessionPrompt.credentials(CredentialRequest(
                context: .remoteDesktop(host: host), attempt: attempt, previousFailure: previousFailure
            ))
            guard case .credentials(let username, let password) = await request.prompts.resolve(prompt) else {
                await connection.close()
                throw .cancelled
            }

            // The opening exchange is a few bytes; the time goes on the login's key agreement.
            // Choosing a session waits on people, so it runs outside the handshake's time limit.
            request.progress(.authenticating)
            let established: ARDConnection.Established
            var pictureTimeout = firstPictureTimeout
            do {
                let loggedIn = try await Self.withTimeout(handshakeTimeout, phase: .negotiating, onTimeout: { await stream.close() }) {
                    () async throws(ARDError) in try await connection.logIn(username: username, password: password)
                }
                if let offer = loggedIn.sessionSelect {
                    let command = try await selectSession(
                        offer, accountLogin: loggedIn.usedSecurityType != .vncPassword, connection: connection, stream: stream,
                        request: request, username: username, password: password
                    )
                    // A session of one's own may be a first login, with a home folder to set up.
                    if command == .logInAsSelf { pictureTimeout = max(pictureTimeout, sessionLoginTimeout) }
                }
                established = try await Self.withTimeout(handshakeTimeout, phase: .negotiating, onTimeout: { await stream.close() }) {
                    () async throws(ARDError) in try await connection.open()
                }
            } catch {
                await connection.close()
                switch error {
                case .authenticationFailed:
                    previousFailure = String(localized: "The user name or password is incorrect, or this account is not allowed to share the screen.", bundle: #bundle)
                    continue
                case .credentialTooLong:
                    previousFailure = String(localized: "The user name and password must each be shorter than 64 bytes.", bundle: #bundle)
                    continue
                case .timedOut:
                    throw .timedOut(phase: .negotiating)
                case .failed(let failure):
                    throw failure
                }
            }

            let mode: SessionMode
            do throws(ConnectionFailure) {
                mode = try Self.resolveMode(request.options.mode, serverInit: established.serverInit, transport: transport, isEncrypted: established.isEncrypted)
            } catch {
                await connection.close()
                throw error
            }

            request.progress(.preparingDisplays)
            var timing = sessionTiming
            // A cellular or metered path rarely carries the full 20–60 Mbit/s: start lighter there.
            if mode == .highPerformance, timing.bandwidthProfile == .full, await Self.pathIsMetered() {
                diagnostics?("on a cellular or metered network: starting in the constrained media profile")
                timing.bandwidthProfile = .constrained
            }
            let session = ARDSession(
                connection: connection, transport: transport, serverInit: established.serverInit, mode: mode,
                options: request.options,
                security: established.isEncrypted ? "\(established.usedSecurityType), AES-128 records" : "\(established.usedSecurityType), not encrypted",
                isEncrypted: established.isEncrypted,
                serverAuthenticated: established.usedSecurityType == .srp,
                videoCodec: mode == .highPerformance ? resolvedVideoCodec : .hevc,
                // wayshare reads Meta, a Mac's Option, as Command, and its own Option from Alt.
                keyStyle: ARDConnection.isMac(offering: established.offeredSecurityTypes) ? .mac : .standard,
                inputKey: established.inputKey, timing: timing, diagnostics: diagnostics
            )
            await session.start()
            if mode == .highPerformance { request.progress(.startingMedia) }
            // The session is handed over once it has a picture to show. The gate takes the first
            // result it is given, so the timer and cancellation simply race the engine for it.
            let gate = session.core.ready
            let timeoutFailure: ConnectionFailure = mode == .highPerformance
                ? .modeUnavailable(mode: .highPerformance, reason: .notSupportedByServer)
                : .timedOut(phase: .preparingDisplays)
            // A step down to the constrained profile starts the stream again, with time of its own.
            let deadline = Mutex(ContinuousClock.now + pictureTimeout)
            let timer = Task {
                while !Task.isCancelled {
                    let until = deadline.withLock { $0 }
                    guard ContinuousClock.now < until else {
                        // Pictures that came but could not be decoded are this device's doing.
                        let noDecoder = mode == .highPerformance && session.core.shared.withLock { $0.foundNoDecoder }
                        gate.resolve(.failure(noDecoder ? .modeUnavailable(mode: .highPerformance, reason: .notSupportedByDevice) : timeoutFailure))
                        return
                    }
                    try? await Task.sleep(until: until)
                }
            }
            defer { timer.cancel() }
            // While a media session starts, watch what arrives on every leg. A stream whose pictures
            // keep arriving broken will not start, a leg on which nothing arrives at all is blocked,
            // and waiting out the long timer helps nobody.
            let watcher: Task<Void, Never>? = mode != .highPerformance ? nil : Task { [weak core = session.core, weak session, mediaStartTimeout, pictureTimeout] in
                var ticks = 0
                var steppedDownAt: ContinuousClock.Instant?
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    ticks += 1
                    guard !Task.isCancelled, let core,
                          let (receiver, legs, answeredAt) = core.shared.withLock({ shared in
                              shared.mediaReceiver.map { ($0, shared.legDisplays.count, shared.lastAnswerAt) }
                          })
                    else { continue }
                    if let (failure, why) = Self.startupFailure(receiver: receiver, legs: legs, answeredAt: answeredAt, core: core, mediaStartTimeout: mediaStartTimeout, report: ticks % 4 == 0) {
                        if failure == .modeUnavailable(mode: .highPerformance, reason: .unreliableNetwork) {
                            // The constrained stream gets its own time to start.
                            if let steppedDownAt, ContinuousClock.now - steppedDownAt < mediaStartTimeout + .seconds(2) { continue }
                            if steppedDownAt == nil, await session?.stepDown() == true {
                                core.note(why)
                                steppedDownAt = .now
                                deadline.withLock { $0 = max($0, .now + pictureTimeout) }
                                continue
                            }
                        }
                        core.note(why)
                        gate.resolve(.failure(failure))
                        return
                    }
                }
            }
            defer { watcher?.cancel() }
            do throws(ConnectionFailure) {
                try await withTaskCancellationHandler { () async throws(ConnectionFailure) in
                    try await gate.wait()
                } onCancel: {
                    gate.resolve(.failure(.cancelled))
                }
            } catch {
                await session.disconnect()
                throw error.withHost(host)
            }
            if Task.isCancelled {
                await session.disconnect()
                throw .cancelled
            }
            return session
        }
        throw .authenticationFailed(detail: previousFailure)
    }

    /// Whether the device's current network path is cellular or marked expensive.
    static func pathIsMetered() async -> Bool {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        let answer = Mutex<CheckedContinuation<Bool, Never>?>(nil)
        return await withCheckedContinuation { continuation in
            answer.withLock { $0 = continuation }
            monitor.pathUpdateHandler = { path in
                answer.withLock { $0.take() }?.resume(returning: path.isExpensive || path.usesInterfaceType(.cellular))
            }
            monitor.start(queue: DispatchQueue(label: "llc.turing.marionette.path"))
            // The first update comes at once; never wait long for it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                answer.withLock { $0.take() }?.resume(returning: false)
            }
        }
    }

    /// Why a High Performance stream that is starting will not start, if it is clear yet.
    static func startupFailure(
        receiver: MediaStreamReceiver, legs: Int, answeredAt: ContinuousClock.Instant?, core: ARDSessionCore, mediaStartTimeout: Duration, report: Bool
    ) -> (failure: ConnectionFailure, why: String)? {
        let now = ContinuousClock.now
        for leg in 0..<legs {
            let video = receiver.videoStatistics(leg: leg)
            if report {
                core.note("starting, leg \(leg): \(video.packets) of \(video.expectedPackets) picture packets, \(video.pictures) pictures, \(video.keyframes) keyframes, \(video.spoiledPictures) broken, \(video.withheldPictures) whole but not a start \(video.lastWithheld), \(video.rejected) rejected; sound \(receiver.audioStatistics.packets) packets")
            }
            // A Mac reports on every leg once a second from its answer on, so a leg that has heard
            // nothing authentic since is cut off: by a firewall, a NAT, or a path that carries TCP only.
            if let answeredAt, now - answeredAt >= core.timing.mediaArrivalLimit,
               (video.lastAuthenticPacket ?? answeredAt) <= answeredAt {
                return (.modeUnavailable(mode: .highPerformance, reason: .mediaBlocked), "leg \(leg): nothing arrived in \(core.timing.mediaArrivalLimit) after the answer: the media path is blocked")
            }
            // Keyframes that keep arriving broken, or never arrive whole while packets go missing
            // (a link too slow for them drops their tails): this stream will not start here.
            let lost = video.expectedPackets - video.packets
            let starved = video.keyframes == 0 && video.expectedPackets > 0 && lost * 10 >= video.expectedPackets
            if let started = video.streamStartedAt, now - started >= mediaStartTimeout, video.spoiledPictures >= 3 || starved {
                return (.modeUnavailable(mode: .highPerformance, reason: .unreliableNetwork), "leg \(leg): no picture arrived whole in \(mediaStartTimeout): the path is too lossy for this stream")
            }
        }
        return nil
    }

    // MARK: Mode

    static func resolveMode(
        _ preference: SessionOptions.ModePreference,
        serverInit: ServerInit,
        transport: any TransportProvider,
        isEncrypted: Bool = true
    ) throws(ConnectionFailure) -> SessionMode {
        let highPerformanceBlocker: UnavailableReason? = {
            if transport.isTunnelled || !transport.supportsDatagrams { return .tunnelled }
            // The media offer carries the stream's keys; in a session in clear anyone on the path
            // could read them, and the pictures with them.
            if !isEncrypted { return .notPermitted }
            if !serverInit.supportsHighPerformance { return .notSupportedByServer }
            return nil
        }()
        switch preference {
        case .automatic:
            return highPerformanceBlocker == nil ? .highPerformance : .standard
        case .require(.standard):
            return .standard
        case .require(.highPerformance):
            if let highPerformanceBlocker {
                throw .modeUnavailable(mode: .highPerformance, reason: highPerformanceBlocker)
            }
            return .highPerformance
        }
    }

    static func viewerMode(_ mode: ControlMode) -> ViewerMode {
        switch mode {
        case .observe: .observe
        case .control: .control
        case .exclusive: .exclusiveControl
        }
    }

    /// The codec to offer, with the automatic choice worked out on this device.
    var resolvedVideoCodec: MediaVideoCodec {
        switch videoCodec {
        case .hevc: .hevc
        case .h264: .h264
        case .automatic: DecoderCapabilities.decodesHEVC444InHardware ? .hevc : .h264
        }
    }

    // MARK: Errors

    static func failure(for error: any Error, host: String) -> ConnectionFailure {
        if error is CancellationError { return .cancelled }
        switch ARDError(error) {
        case .transport(.localNetworkDenied): return .localNetworkDenied
        case .transport(.timedOut): return .timedOut(phase: .reachingHost)
        case .transport(.tunnel(let detail)): return .tunnelFailed(detail: detail)
        case .transport(.unreachable(let detail)), .transport(.other(let detail)), .transport(.unsupported(let detail)):
            return .unreachable(host: host, detail: detail)
        case .transport(.addressInUse(let port)): return .busy(detail: String(localized: "Port \(port) is in use on this device.", bundle: #bundle))
        case .transport(.closed), .closedByPeer: return .unreachable(host: host, detail: String(localized: "The Mac closed the connection.", bundle: #bundle))
        case .refused(let reason): return .permissionDenied(detail: reason)
        case .authenticationFailed, .credentialTooLong: return .authenticationFailed(detail: nil)
        case .unsupported(let detail): return .unsupportedServer(detail: detail)
        case .otherProtocol(let detail): return .otherProtocol(detail: detail)
        case .protocolViolation(let detail): return .protocolViolation(detail: detail)
        case .serverNotAuthenticated: return .serverNotAuthenticated(detail: ARDError.serverNotAuthenticatedExplanation)
        case .notEncrypted(let detail): return .notEncrypted(detail: detail)
        case .cancelled: return .cancelled
        }
    }

    /// What the console user is told a request to share comes from.
    public var viewerName = String(localized: "Marionette", bundle: #bundle)
    /// How long a Mac may take to log the account in to a session of its own. A first login, with
    /// a new home folder, takes about three seconds (measured).
    public var sessionLoginTimeout: Duration = .seconds(90)
    /// How long to wait for the console user to answer. The Mac sets no limit, and the person
    /// connecting can cancel at any time; this only bounds a request nobody will ever see.
    public var consoleAnswerTimeout: Duration = .seconds(600)

    /// Puts the Mac's session-select offer to the user until the Mac accepts an answer.
    private func selectSession(
        _ firstOffer: SessionSelectOffer,
        accountLogin: Bool,
        connection: ARDConnection,
        stream: any ByteStream,
        request: ConnectionRequest,
        username: String,
        password: String
    ) async throws(TimedError) -> SessionSelectCommand {
        var offer = firstOffer
        var declined = false
        var triedConsole = false
        while true {
            diagnostics?("the Mac offers a choice of session (commands 0x\(String(offer.commands.rawValue, radix: 16))), \(offer.consoleUser) at the console")
            let command: SessionSelectCommand
            if offer.commands.contains(.connectToConsole), !triedConsole {
                // The Mac offers the console's session outright: nothing to ask anyone. (Taken
                // whenever offered, as rootshell-vnc does; unverified, as macOS 27 never offers it.)
                triedConsole = true
                command = .connectToConsole
            } else {
                let choices = Self.choices(for: offer, accountLogin: accountLogin)
                guard !choices.isEmpty else {
                    throw .failed(.permissionDenied(detail: String(localized: "\(offer.consoleUser) is using this Mac, and it offers no way to share it with this account.", bundle: #bundle)))
                }
                let prompt = SessionSelectRequest(consoleUser: offer.consoleUser, choices: choices, previousRequestDeclined: declined)
                guard case .sessionChoice(let choice) = await request.prompts.resolve(.sessionSelect(prompt)), choices.contains(choice) else {
                    throw .failed(.cancelled)
                }
                command = choice == .logInAsSelf ? .logInAsSelf : .askConsoleUser
                if command == .askConsoleUser { request.progress(.waitingForRemoteUser) }
            }
            let viewerName = viewerName
            let result: SessionSelectResult
            do {
                result = try await Self.withTimeout(
                    command == .logInAsSelf ? sessionLoginTimeout : consoleAnswerTimeout,
                    phase: .waitingForRemoteUser,
                    onTimeout: { await stream.close() }
                ) { () async throws(ARDError) in
                    try await connection.selectSession(command, viewerName: viewerName, username: username, password: password)
                }
            } catch .timedOut {
                throw .failed(.timedOut(phase: .waitingForRemoteUser))
            }
            switch result {
            case .accepted:
                return command
            case .declined(let next):
                if !next.commands.isEmpty { offer = next }
                declined = true
            }
        }
    }

    /// What the user may choose. A session of one's own needs the account's name and password,
    /// sealed under a login key that a VNC-password login does not have.
    static func choices(for offer: SessionSelectOffer, accountLogin: Bool = true) -> [SessionChoice] {
        var choices: [SessionChoice] = []
        if offer.commands.contains(.askConsoleUser) { choices.append(.askToShareConsole) }
        if offer.commands.contains(.logInAsSelf), accountLogin { choices.append(.logInAsSelf) }
        return choices
    }

    enum TimedError: Error {
        case timedOut
        case authenticationFailed
        case credentialTooLong
        case failed(ConnectionFailure)
    }

    /// Runs `operation`, giving up after `timeout`. `onTimeout` must make the operation return, for
    /// example by closing the stream it is reading.
    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        phase: ConnectionPhase,
        onTimeout: @escaping @Sendable () async -> Void,
        _ operation: @escaping @Sendable () async throws(ARDError) -> T
    ) async throws(TimedError) -> T {
        let work = Task { () -> Result<T, ARDError> in
            do throws(ARDError) {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            await onTimeout()
            work.cancel()
            return true
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
            Task { await onTimeout() }
        }
        timer.cancel()
        let timedOut = await timer.value
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            if timedOut { throw .timedOut }
            // Cancelling closes the stream, so the operation fails as if the Mac had hung up.
            if Task.isCancelled { throw .failed(.cancelled) }
            switch error {
            case .authenticationFailed: throw .authenticationFailed
            case .credentialTooLong: throw .credentialTooLong
            case .cancelled: throw .failed(.cancelled)
            default: throw .failed(failure(for: error, host: ""))
            }
        }
    }
}

extension ConnectionFailure {
    /// Fills in the host for failures raised below the layer that knows it.
    func withHost(_ host: String) -> ConnectionFailure {
        if case .unreachable("", let detail) = self { return .unreachable(host: host, detail: detail) }
        return self
    }
}

/// A live session with a Mac.
public final class ARDSession: RemoteSession {
    let core: ARDSessionCore
    private let engine: ARDEngine

    init(
        connection: ARDConnection, transport: any TransportProvider, serverInit: ServerInit, mode: SessionMode, options: SessionOptions,
        security: String, isEncrypted: Bool = true, serverAuthenticated: Bool = false, videoCodec: MediaVideoCodec = .hevc,
        keyStyle: X11Keysym.ModifierStyle = .mac, inputKey: Data? = nil, timing: SessionTiming = SessionTiming(),
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        core = ARDSessionCore(
            connection: connection, transport: transport, serverInit: serverInit, mode: mode, options: options, security: security,
            isEncrypted: isEncrypted, serverAuthenticated: serverAuthenticated, videoCodec: videoCodec, keyStyle: keyStyle,
            inputKey: inputKey, timing: timing, diagnostics: diagnostics
        )
        engine = ARDEngine(core: core)
    }

    deinit {
        core.finish(.userInitiated)
    }

    func start() async {
        core.shared.withLock { shared in
            shared.capabilities = makeCapabilities()
            // Settled by the first layout.
            shared.capabilities.curtain = core.curtainCapability(for: shared)
            shared.capabilities.touch = core.touchCapability(for: shared)
        }
        await engine.start()
        let task = Task { [engine] in await engine.run() }
        core.shared.withLock { $0.engineTask = task }
        // Ends with the session: the loop holds the core weakly and stops once it is over.
        Task { [weak core, engine] in
            while true {
                do {
                    guard let core, !core.shared.withLock({ $0.state.isDisconnected }) else { return }
                    core.checkControlHealth()
                    if core.info.mode == .highPerformance {
                        if core.checkMediaHealth() { await engine.restartStream() }
                        if core.isLosingTooMuch(), await !engine.stepDown() {
                            core.note("the path loses too much even for the constrained media profile")
                            core.finish(.mediaStalled(.lossy))
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public var info: SessionInfo { core.info }
    public var state: SessionState { core.shared.withLock { $0.state } }
    public var layout: DesktopLayout { core.shared.withLock { $0.layout } }
    public var capabilities: SessionCapabilities { core.shared.withLock { $0.capabilities } }
    public var input: any InputSink { core }

    public func events() -> AsyncStream<SessionEvent> { core.events.subscribe() }
    public func cursor() -> AsyncStream<CursorState> { core.cursorUpdates.subscribe() }

    public func frames(for display: DisplayID) -> FrameMailbox {
        if let hub = core.shared.withLock({ $0.hubs[display] }) {
            return hub.subscribe()
        }
        let empty = FrameMailbox()
        empty.finish()
        return empty
    }

    public func suspend() async {
        if core.setSuspended(true) {
            await engine.suspendUpdates()
        }
    }

    public func resume() async {
        if core.setSuspended(false) {
            await engine.resumeMedia()
        }
    }

    /// Returns once the connection is closed (or has had its bounded time to send what was queued).
    public func disconnect() async {
        core.finish(.userInitiated)
        await core.closed()
    }

    /// Steps the stream down to the constrained media profile; false if it is there already.
    func stepDown() async -> Bool {
        await engine.stepDown()
    }

    /// How long since anything arrived on the control connection, and on each picture leg (`nil`
    /// before the first packet): for diagnosing a session that seems stuck.
    @_spi(Diagnostics) public var silence: (control: Duration, pictureLegs: [Duration?]) {
        let now = ContinuousClock.now
        let (receiver, legs) = core.shared.withLock { ($0.mediaReceiver, $0.legDisplays.count) }
        let pictures = (0..<legs).map { leg in receiver?.videoStatistics(leg: leg).lastAuthenticPacket.map { now - $0 } }
        return (now - core.connection.lastReceivedAt, pictures)
    }

    /// Sends messages built for the pointer's last position on the wire, in order with other input.
    /// For protocol experiments (`marionettectl`); the app never sends anything this way.
    @_spi(Diagnostics) public func sendRawInput(_ build: (_ x: UInt16, _ y: UInt16) -> [Data]) {
        let position = core.shared.withLock { $0.lastPointer }
        core.deliverRawInput(build(position.x, position.y))
    }

    private func makeCapabilities() -> SessionCapabilities {
        var capabilities = SessionCapabilities()
        let isHighPerformance = core.info.mode == .highPerformance
        let mayControl = core.serverInit.flags?.contains(.observeOnly) != true

        capabilities.clipboard = core.options.wantsClipboard
            ? .available(ARDClipboard(core: core))
            : .unavailable(.notConfigured(detail: String(localized: "Clipboard sharing is switched off for this computer.", bundle: #bundle)))
        capabilities.displayConfiguration = .available(ARDDisplayConfiguration(core: core, engine: engine))
        capabilities.control = mayControl ? .available(ARDControl(core: core)) : .unavailable(.notPermitted)
        if isHighPerformance {
            capabilities.audio = .available(ARDAudio(core: core))
            capabilities.statistics = .available(ARDStatistics(core: core))
            // High Performance has no quality choice: the Mac's rate control is automatic.
            capabilities.quality = .unavailable(.requiresMode(.standard))
        } else {
            capabilities.audio = .unavailable(core.info.isTunnelled ? .tunnelled : .requiresMode(.highPerformance))
            capabilities.statistics = .unavailable(.requiresMode(.highPerformance))
            capabilities.quality = .available(ARDQuality(engine: engine))
        }
        capabilities.fileTransfer = mayControl ? .available(core.fileTransfers) : .unavailable(.notPermitted)
        // A Mac starts a viewer's drag only when that viewer's pointer events are encrypted.
        if !mayControl {
            capabilities.fileDrag = .unavailable(.notPermitted)
        } else if core.inputCipher == nil {
            capabilities.fileDrag = .unavailable(.notSupportedByServer)
        } else {
            capabilities.fileDrag = .available(core.fileDrags)
        }
        capabilities.remoteActions = .unavailable(.notSupportedByBackend)
        return capabilities
    }
}

// MARK: - Capabilities

/// Capability objects refer to the session weakly: the session's state holds them.
final class ARDClipboard: ClipboardSync {
    private weak let core: ARDSessionCore?

    init(core: ARDSessionCore) {
        self.core = core
    }

    func remoteOffers() -> AsyncStream<RemoteClipboardOffer> {
        core?.clipboardOffers.subscribe() ?? AsyncStream { $0.finish() }
    }

    func sendToRemote(_ items: [ClipboardItem]) async throws {
        guard let core, !core.shared.withLock({ $0.state.isDisconnected }) else { throw ARDError.closedByPeer }
        core.connection.send(try PasteboardArchive.message(items))
    }
}

final class ARDDisplayConfiguration: DisplayConfiguration {
    private weak let core: ARDSessionCore?
    private let engine: ARDEngine

    init(core: ARDSessionCore, engine: ARDEngine) {
        self.core = core
        self.engine = engine
    }

    var limits: DisplayConfigurationLimits {
        let isHighPerformance = core?.info.mode == .highPerformance
        let legs = core?.shared.withLock { $0.legDisplays.count } ?? 0
        return DisplayConfigurationLimits(
            // The number of virtual displays is fixed when the session starts.
            maximumVirtualDisplays: isHighPerformance ? max(1, legs) : 0,
            minimumPointSize: PixelSize(width: Int(VirtualDisplayMode.minimumPointSideAt1x), height: Int(VirtualDisplayMode.minimumPointSideAt1x)),
            minimumHiDPIPointSize: PixelSize(width: Int(VirtualDisplayMode.minimumPointWidth), height: Int(VirtualDisplayMode.minimumPointHeight)),
            maximumPixelSize: PixelSize(width: Int(VirtualDisplayMode.maximumPixelWidth), height: Int(VirtualDisplayMode.maximumPixelHeight)),
            canSelectPhysicalDisplays: !isHighPerformance
        )
    }

    func setVirtualDisplays(_ requests: [VirtualDisplayRequest]) async throws {
        try await engine.setVirtualDisplays(requests)
    }

    func selectPhysicalDisplays(_ selection: PhysicalDisplaySelection) async throws {
        try await engine.selectPhysicalDisplays(selection)
    }
}

final class ARDQuality: QualityControl {
    private let engine: ARDEngine

    init(engine: ARDEngine) {
        self.engine = engine
    }

    var supportedPresets: [QualityPreset] { [.adaptive, .full] }

    func setPreset(_ preset: QualityPreset) async throws {
        await engine.setQuality(preset)
    }
}

final class ARDControl: SessionControl {
    private weak let core: ARDSessionCore?

    init(core: ARDSessionCore) {
        self.core = core
    }

    var supportedModes: [ControlMode] { ControlMode.allCases }

    func setControlMode(_ mode: ControlMode) async throws {
        guard let core else { throw ARDError.closedByPeer }
        core.setControlMode(mode)
    }
}

/// A snapshot: the session publishes a new one whenever the Mac's layout reports a change.
final class ARDCurtain: CurtainControl {
    private weak let core: ARDSessionCore?
    let isCurtained: Bool

    init(core: ARDSessionCore, isCurtained: Bool) {
        self.core = core
        self.isCurtained = isCurtained
    }

    func setCurtained(_ curtained: Bool, note: String) async throws {
        guard let core, !core.shared.withLock({ $0.state.isDisconnected }) else { throw ARDError.closedByPeer }
        core.note(curtained ? "asked the Mac to raise the curtain" : "asked the Mac to lower the curtain")
        core.connection.send(Curtain.message(curtained: curtained, note: note))
    }
}

final class ARDAudio: AudioOutput {
    private weak let core: ARDSessionCore?

    init(core: ARDSessionCore) {
        self.core = core
    }

    func chunks() -> AsyncStream<AudioChunk> {
        // Sound is decoded only while someone is listening.
        AsyncStream(bufferingPolicy: .bufferingNewest(100)) { continuation in
            guard let core else {
                continuation.finish()
                return
            }
            let previous: AsyncStream<AudioChunk>.Continuation? = core.shared.withLock { shared in
                guard !shared.state.isDisconnected else { return continuation }
                defer { shared.audio = continuation }
                return shared.audio
            }
            previous?.finish()
        }
    }
}

final class ARDStatistics: SessionStatisticsSource {
    private weak let core: ARDSessionCore?

    init(core: ARDSessionCore) {
        self.core = core
    }

    func statistics() -> AsyncStream<SessionStatistics> {
        AsyncStream { continuation in
            let task = Task { [weak core] in
                var previous: [MediaLegStatistics] = []
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    guard let core, let (receiver, legs) = core.shared.withLock({ shared in shared.mediaReceiver.map { ($0, shared.legDisplays.count) } }) else { break }
                    let current = (0..<legs).map { receiver.videoStatistics(leg: $0) }
                    // Every leg's figures, summed or the worst of them: the session is as smooth as
                    // its slowest display and as lossy as its lossiest.
                    var framesPerSecond: Double?
                    var bits = 0.0
                    var loss: Double?
                    for (leg, now) in current.enumerated() {
                        let before = leg < previous.count ? previous[leg] : MediaLegStatistics()
                        // A new stream starts its counters again; that second says nothing.
                        guard now.packets >= before.packets else { continue }
                        let expected = now.expectedPackets - before.expectedPackets
                        let arrived = now.packets - before.packets
                        framesPerSecond = min(framesPerSecond ?? .infinity, Double(now.pictures - before.pictures))
                        bits += Double(now.bytes - before.bytes) * 8
                        // A straggler can make a second look better than perfect; never below zero.
                        if expected > 0 { loss = max(loss ?? 0, min(1, max(0, 1 - Double(arrived) / Double(expected)))) }
                    }
                    continuation.yield(SessionStatistics(
                        framesPerSecond: framesPerSecond ?? 0,
                        bitrate: bits,
                        packetLoss: loss,
                        roundTripTime: nil,
                        decodeLatency: nil,
                        videoCodec: current.first?.codec.map { $0 == .hevc ? "HEVC 4:4:4" : "H.264" }
                    ))
                    previous = current
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
