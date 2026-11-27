// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDCrypto
import ARDProtocol
import Foundation
import RemoteDesktopCore
import RemoteDesktopDecode
import Synchronization

/// Resolves once a session has its first picture, or fails with the reason it never will.
final class ReadyGate: Sendable {
    private struct State {
        var result: Result<Void, ConnectionFailure>?
        var waiter: CheckedContinuation<Result<Void, ConnectionFailure>, Never>?
    }

    private let state = Mutex(State())

    func resolve(_ result: Result<Void, ConnectionFailure>) {
        let waiter: CheckedContinuation<Result<Void, ConnectionFailure>, Never>? = state.withLock { state in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: result)
    }

    var isResolved: Bool { state.withLock { $0.result != nil } }

    func wait() async throws(ConnectionFailure) {
        let result: Result<Void, ConnectionFailure> = await withCheckedContinuation { continuation in
            let ready: Result<Void, ConnectionFailure>? = state.withLock { state in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        try result.get()
    }
}

/// The time limits a session runs by. Tests shorten them.
struct SessionTiming: Sendable {
    /// A Mac silently discards keyboard and pointer events for about two seconds after a login
    /// (measured on macOS 27.0.1: events up to 0.5 s after the first frame are lost, events from 1 s
    /// on arrive). Input before this much time has passed since the handshake is held and sent, in
    /// order, when it has, so a tap made the moment the screen appears is late rather than lost.
    var inputSettlingTime: Duration = .milliseconds(2600)
    /// How long input is held after the layout of a High Performance display change arrives. A
    /// Mac discards input from the moment the change is asked for until about half a second after
    /// that layout (measured on macOS 27.0.1: lost up to 0.45–0.52 s after it, arriving from
    /// 0.52–0.64 s); input is held from the request until this long after the layout.
    var displayChangeInputHold: Duration = .seconds(1)
    var holdsInputAroundDisplayChanges = true
    /// How long High Performance waits for the Mac's own layout before making its displays like
    /// those. A Mac answers at once (in a few milliseconds on the LAN).
    var physicalLayoutGrace: Duration = .seconds(2)
    /// How long the Mac may take to lay out a display configuration and name its ports.
    var displayChangeTimeout: Duration = .seconds(15)
    /// How long the Mac may take to answer a media offer. It answers within a third of a second.
    var offerTimeout: Duration = .seconds(10)
    /// How long a picture leg may be silent, and how long it may go unrepaired, before the session
    /// is given up as stalled. A Mac reports on each leg every second, and a repair takes one to
    /// two seconds on a path that works at all.
    var mediaSilenceLimit: Duration = .seconds(8)
    var mediaRepairLimit: Duration = .seconds(15)
    /// How long after an answer a leg may stay without one authenticated datagram before the
    /// media path counts as blocked. A Mac reports on every leg once a second from the answer on.
    var mediaArrivalLimit: Duration = .seconds(3)
    /// How long the Mac may send nothing at all before the connection counts as lost. A Mac sends
    /// a heartbeat (status 4) about every 2.1 s in every mode, idle or not.
    var controlSilenceLimit: Duration = .seconds(15)
    /// How long closing waits for queued messages to be written. A dead path never takes them.
    var closeDrainLimit: Duration = .seconds(1)
    /// How long a pasteboard fetch waits for the Mac's answer while nothing at all arrives.
    var pasteboardFetchLimit: Duration = .seconds(10)
    /// The media configuration the first offer asks for; later ones step down from it as the path demands.
    var bandwidthProfile: MediaOffer.BandwidthProfile = .full
    /// The length of each window the loss rule looks at.
    var lossWindow: Duration = .seconds(5)
    /// The fewest packets a window must expect for its loss to count.
    var lossWindowPackets = 200
    /// A stall within this long of a restart for an earlier one ends the session.
    var stallRestartMemory: Duration = .seconds(60)
    /// After longer than this in the background a High Performance stream is started afresh rather
    /// than asked for a keyframe: its numbering has moved on too far to follow.
    var resumeRestartThreshold: Duration = .seconds(1)
    /// Whether keys and pointer events go as `EncryptedInputEvent` messages when the Mac takes
    /// them, as Screen Sharing.app sends them. Off only for protocol experiments (`marionettectl`).
    var encryptsInput = true
    /// Standard mode says it shows every display, as Screen Sharing.app does. Off only for experiments.
    var saysEveryDisplay = true
    /// How long the Mac may take to name the folder under a dropped drag of files. It answers
    /// within a quarter of a second when it answers at all.
    var dropAnswerLimit: Duration = .seconds(3)
    /// Debug builds only: where secret keys are logged (see `AppleScreenSharingBackend.keyLog`).
    var keyLog: (@Sendable (String) -> Void)?
}

/// Where a display sits in what the Mac addresses pointer events in.
struct DisplayPlacement: Sendable {
    /// The display's top-left corner in framebuffer pixels.
    var originX: Int
    var originY: Int
    /// Pixels per point of the display as sent.
    var scale: Double
    /// Server-side scaling in force; the Mac reads pointer positions in unscaled pixels.
    var serverScale: Double
    /// The Mac's own id for the display, which touches are addressed to.
    var screen: UInt32
}

/// State and plumbing shared by a session's public face, its engine, its capabilities and the
/// media callbacks. Everything here is safe to touch from any thread.
final class ARDSessionCore: Sendable, InputSink {
    enum KeyIdentity: Hashable {
        case position(KeyCode)
        case symbol(UInt32)
    }

    /// What a move that may replace an earlier one moves: only a move of the same kind does.
    enum MoveKind {
        case pointer
        /// The same fingers, all still touching.
        case touch
    }

    struct Shared {
        var state: SessionState = .connected
        /// This device found no decoder for the stream the Mac sends: its pictures arrive and cannot
        /// be shown. A stream that never starts then says so, rather than blaming the Mac.
        var foundNoDecoder = false
        /// This device found no decoder for an HDR stream: the displays are to be asked for in SDR.
        /// Taken by ``takeHDRRefusal()``.
        var refusedHDR = false
        var layout: DesktopLayout = .empty
        var capabilities = SessionCapabilities()
        var hubs: [DisplayID: FrameHub] = [:]
        var cursor = CursorState()
        var placements: [DisplayID: DisplayPlacement] = [:]
        var controlMode: ControlMode = .control
        var isSuspended = false
        var keysDown: [KeyIdentity: UInt32] = [:]
        var buttonsDown: PointerButtons = []
        var lastPointer: (x: UInt16, y: UInt16) = (0, 0)
        /// When the last key or pointer event was made; an encrypted event says how long before it
        /// the one before was.
        var lastInputAt: ContinuousClock.Instant?
        var scrollRemainder: (x: Double, y: Double) = (0, 0)
        /// A scroll began without moving; it is sent with the first movement.
        var isScrollBeginHeld = false
        var audio: AsyncStream<AudioChunk>.Continuation?
        /// High Performance: which display each picture leg carries, by leg index.
        var legDisplays: [DisplayID] = []
        var pasteboardWaiters: [UInt32: CheckedContinuation<Result<[ClipboardItem], ARDError>, Never>] = [:]
        var nextPasteboardToken: UInt32 = 1
        var clipboardChangeCount: UInt64 = 0
        /// High Performance: a display change is out and its layout has not arrived, so pictures
        /// still in flight are of displays about to be replaced.
        var awaitingNewLayout = false
        /// High Performance: the displays that were live when the display change now out was asked
        /// for. They are live again if the Mac never takes the change up.
        var liveBeforeChange: Set<DisplayID> = []
        /// High Performance: the displays are the ones the session asked for, not the opening ones.
        var hasSessionDisplays = false
        /// High Performance: when the Mac answered the latest offer, while no display change is out.
        /// Its reports on every leg follow within a second.
        var lastAnswerAt: ContinuousClock.Instant?
        var isSecureInputActive: Bool?
        /// The Mac's own displays are asleep (status 5) rather than awake (status 6).
        var areRemoteDisplaysAsleep = false
        /// The Mac said it takes no input from this viewer (status 10) and has not said otherwise since.
        var isControlRefused = false
        /// Curtain mode as the latest layout tells it; `nil` before the first.
        var curtainState: DisplayLayout.CurtainState?
        /// The latest layout says the session is on the Mac's own screen, not one of its own.
        var isOnConsole = false
        /// The fingers on the Mac's touch screen as the last report left them; `nil` when none.
        var touches: (screen: UInt32, contacts: [DigitizerReport.Contact])?
        /// Input is held until the later of these: the Mac discards it for a while after a login,
        /// and after a High Performance display change.
        var inputHeldUntil: ContinuousClock.Instant
        var displayChangeHoldUntil: ContinuousClock.Instant?
        var inputOpensAt: ContinuousClock.Instant { max(inputHeldUntil, displayChangeHoldUntil ?? inputHeldUntil) }
        /// Input sealed-in-order but not yet sent, while the Mac is not taking input.
        var heldInput: [Data] = []
        /// The latest pointer or touch move, waiting for a backed-up connection to drain.
        var pendingMove: (message: Data, kind: MoveKind)?
        var moveFlush: Task<Void, Never>?
        var inputFlush: Task<Void, Never>?
        /// Closes the connection once the session has ended; ``ARDSessionCore/closed()`` waits for it.
        var closing: Task<Void, Never>?
        var engineTask: Task<Void, Never>?
        var mediaReceiver: MediaStreamReceiver?
        /// The media watchdog counts from here: the session's start, or its return from the background.
        var mediaWatchEpoch = ContinuousClock.now
        /// The watchdog starts once the session has shown its first picture; getting that far is
        /// the connection attempt's business, with its own time limits.
        var isMediaWatchArmed = false
        /// Packet counts at the start of the current loss window, and how many windows in a row lost too much.
        var lossWindow: (start: ContinuousClock.Instant, packets: Int, expected: Int)?
        var lossyWindows = 0
        /// When the stream was last started again because it had stalled.
        var streamRestartedForStallAt: ContinuousClock.Instant?
        var suspendedAt: ContinuousClock.Instant?
        /// The control connection's silence counts from here: the start, or the return from the
        /// background, where sockets do not run.
        var controlWatchEpoch = ContinuousClock.now
    }

    /// Tells subscribers the layout as it is now. The engine and each display's decoder change it
    /// from threads of their own; were each to send the layout as it left it, an older one could
    /// arrive last, and a display would stay reconfiguring for good on a still desktop.
    func announceLayout() {
        layoutAnnouncements.withLock { _ in
            events.send(.layoutChanged(shared.withLock { $0.layout }))
        }
    }

    /// Ends the wait for the session's displays and arms the media watchdog, once every one of them
    /// is live.
    func displaysMayBeReady() {
        let isReady = shared.withLock { $0.hasSessionDisplays && $0.layout.displays.allSatisfy { $0.state == .live } }
        guard isReady else { return }
        if !shared.withLock({ $0.isMediaWatchArmed }) { restartMediaWatch(arming: true) }
        ready.resolve(.success(()))
    }

    /// Starts the watchdog's clock again: at the first picture, when the app returns from the
    /// background, and whenever the displays change, since each of those stops the stream a while.
    func restartMediaWatch(arming: Bool = false) {
        shared.withLock { shared in
            shared.mediaWatchEpoch = .now
            if arming { shared.isMediaWatchArmed = true }
        }
    }

    var mediaSilenceLimit: Duration { timing.mediaSilenceLimit }
    var mediaRepairLimit: Duration { timing.mediaRepairLimit }

    /// Whether this device has found it cannot decode an HDR stream since last asked.
    func takeHDRRefusal() -> Bool {
        shared.withLock { shared in
            defer { shared.refusedHDR = false }
            return shared.refusedHDR
        }
    }

    /// Ends a High Performance session whose pictures have stopped for good: the control
    /// connection can outlive the media path (a network change, a firewall, a sleeping access
    /// point), and without this the picture would simply freeze.
    ///
    /// The first stall is answered with a fresh stream on the same connection (the caller restarts
    /// it when this returns true); only a stall again soon after ends the session.
    func checkMediaHealth(at now: ContinuousClock.Instant = .now) -> Bool {
        let (receiver, legs, epoch, watching): (MediaStreamReceiver?, Int, ContinuousClock.Instant, Bool) = shared.withLock {
            ($0.mediaReceiver, $0.legDisplays.count, $0.mediaWatchEpoch, $0.isMediaWatchArmed && $0.state == .connected && !$0.isSuspended)
        }
        guard watching, let receiver else { return false }
        for leg in 0..<legs {
            let cause: MediaStallCause
            switch receiver.videoStatistics(leg: leg).health(at: now, since: epoch, silenceLimit: mediaSilenceLimit, repairLimit: mediaRepairLimit) {
            case .healthy:
                continue
            case .silent:
                note("leg \(leg): nothing has arrived for \(mediaSilenceLimit); the media path is gone")
                cause = .silent
            case .unrepaired:
                note("leg \(leg): no whole picture for \(mediaRepairLimit); the path loses too much")
                cause = .lossy
            }
            let restart: Bool = shared.withLock { shared in
                guard shared.streamRestartedForStallAt.map({ now - $0 >= timing.stallRestartMemory }) ?? true else { return false }
                shared.streamRestartedForStallAt = now
                shared.mediaWatchEpoch = now
                return true
            }
            if restart {
                note("starting the stream again on the same connection")
            } else {
                finish(.mediaStalled(cause))
            }
            return restart
        }
        return false
    }

    /// Ends a session whose Mac has sent nothing for too long, in any mode: a Mac that lost power or
    /// a path that went away leaves TCP waiting for minutes, and the picture would simply freeze.
    func checkControlHealth(at now: ContinuousClock.Instant = .now) {
        let (watching, epoch) = shared.withLock { ($0.state == .connected && !$0.isSuspended, $0.controlWatchEpoch) }
        guard watching else { return }
        let silence = now - max(connection.lastReceivedAt, epoch)
        guard silence >= timing.controlSilenceLimit else { return }
        note("nothing has arrived from the Mac for \(silence); the connection is gone")
        finish(.connectionLost(detail: String(localized: "The Mac stopped responding.", bundle: #bundle)))
    }

    /// Whether the stream has lost too much for long enough that a lighter one should be tried:
    /// two windows in a row of at least 200 expected packets with a fifth or more of them lost
    /// (after rootshell-vnc's rule). A Mac resends nothing, so such a path shows a picture that
    /// mends itself less often than it breaks.
    func isLosingTooMuch(at now: ContinuousClock.Instant = .now) -> Bool {
        // Starting is the connection attempt's business, with rules of its own.
        let (receiver, legs, watching) = shared.withLock { ($0.mediaReceiver, $0.legDisplays.count, $0.isMediaWatchArmed && $0.state == .connected && !$0.isSuspended) }
        guard watching, let receiver else {
            shared.withLock { $0.lossWindow = nil }
            return false
        }
        let totals = (0..<legs).map { receiver.videoStatistics(leg: $0) }.reduce((packets: 0, expected: 0)) { ($0.packets + $1.packets, $0.expected + $1.expectedPackets) }
        return shared.withLock { shared in
            guard let window = shared.lossWindow, totals.packets >= window.packets, totals.expected >= window.expected else {
                shared.lossWindow = (now, totals.packets, totals.expected)
                return false
            }
            guard now - window.start >= timing.lossWindow else { return false }
            let expected = totals.expected - window.expected
            let lost = expected - (totals.packets - window.packets)
            shared.lossWindow = (now, totals.packets, totals.expected)
            if expected >= timing.lossWindowPackets, Double(lost) >= 0.2 * Double(expected) {
                shared.lossyWindows += 1
            } else {
                shared.lossyWindows = 0
            }
            guard shared.lossyWindows >= 2 else { return false }
            shared.lossyWindows = 0
            return true
        }
    }

    let connection: ARDConnection
    let transport: any TransportProvider
    let serverInit: ServerInit
    let options: SessionOptions
    let info: SessionInfo
    /// How keys become keysyms: a Mac's own table, or plain X11 for other servers (wayshare).
    let keyStyle: X11Keysym.ModifierStyle
    /// Seals keys and pointer events; `nil` when they go as plain messages (no record layer, or a
    /// server that does not take the encrypted kind).
    let inputCipher: InputCipher?
    let shared: Mutex<Shared>
    let timing: SessionTiming
    let events = Broadcaster<SessionEvent>()
    let cursorUpdates = Broadcaster<CursorState>(replaysLatest: true, bufferingPolicy: .bufferingNewest(1))
    let clipboardOffers = Broadcaster<RemoteClipboardOffer>(replaysLatest: true, bufferingPolicy: .bufferingNewest(1))
    let ready = ReadyGate()
    /// Screen Sharing's own file transfer, which rides on this connection.
    let fileTransfers: ARDFileTransfers
    let fileDrags = ARDFileDrags()

    /// Held while a layout is read and sent, so that announcements arrive in the order of the
    /// layouts they carry; see ``announceLayout()``.
    private let layoutAnnouncements = Mutex<Void>(())
    /// One decoder per picture leg, fed from that leg's media queue and replaced by the engine for
    /// each offer. The lock guards only the list: no call into VideoToolbox is made under it.
    let videoDecoders = Mutex<[LegDecoder]>([])
    private let audioDecoder = Mutex<AudioDecoding>(AudioDecoding())
    /// Where a decoder that failed is rebuilt: never on the VideoToolbox thread that reported the
    /// failure, since rebuilding waits for that thread's pictures to finish.
    private let decoderRecovery = DispatchQueue(label: "llc.turing.marionette.decoder-recovery", qos: .userInitiated)

    init(
        connection: ARDConnection, transport: any TransportProvider, serverInit: ServerInit, mode: SessionMode, options: SessionOptions,
        security: String, isEncrypted: Bool = true, serverAuthenticated: Bool = false, videoCodec: MediaVideoCodec = .hevc,
        allowsHDR: Bool = false, keyStyle: X11Keysym.ModifierStyle = .mac, inputKey: Data? = nil, timing: SessionTiming = SessionTiming(),
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        self.videoCodec = videoCodec
        self.allowsHDR = allowsHDR && videoCodec == .hevc
        self.keyStyle = keyStyle
        inputCipher = timing.encryptsInput ? inputKey.flatMap { try? InputCipher(key: $0) } : nil
        self.timing = timing
        shared = Mutex(Shared(inputHeldUntil: .now + timing.inputSettlingTime))
        self.diagnostics = diagnostics
        self.connection = connection
        fileTransfers = ARDFileTransfers(connection: connection, diagnostics: diagnostics)
        self.transport = transport
        self.serverInit = serverInit
        self.options = options
        info = SessionInfo(
            backendID: AppleScreenSharingBackend.backendID,
            mode: mode,
            remoteName: serverInit.name,
            securityDescription: security,
            isTunnelled: transport.isTunnelled,
            // The record layer encrypts both directions, except after a VNC-password login.
            isEncrypted: isEncrypted,
            isServerAuthenticated: serverAuthenticated
        )
        shared.withLock { $0.controlMode = options.controlMode }
        // A Mac sends its cursor's shape when it first changes, which on a still screen may be a
        // long time. Until then the viewer draws its own arrow where it last put the pointer.
        cursorUpdates.send(CursorState())
        fileDrags.attach(to: self)
    }

    // MARK: Input

    func send(_ event: InputEvent) {
        var messages: [Data] = []
        var move: MoveKind?
        shared.withLock { shared in
            guard !shared.state.isDisconnected, !shared.isSuspended, shared.controlMode != .observe else { return }
            switch event {
            case .key(let key):
                let identity: KeyIdentity? = key.key.map(KeyIdentity.position)
                if key.phase == .down {
                    guard let keysym = Keysym.forEvent(key, style: keyStyle) else { return }
                    let slot = identity ?? .symbol(keysym)
                    // A key already down goes down again only as a repeat (the Mac does not repeat a
                    // key a viewer holds), and as what it was pressed as.
                    if let pressed = shared.keysDown[slot] {
                        guard key.isRepeat else { return }
                        messages.append(keyMessage(keysym: pressed, isDown: true, &shared))
                        return
                    }
                    shared.keysDown[slot] = keysym
                    messages.append(keyMessage(keysym: keysym, isDown: true, &shared))
                } else {
                    // Release the keysym that was pressed, whatever the event now says it types.
                    let slot = identity ?? Keysym.forEvent(key, style: keyStyle).map(KeyIdentity.symbol)
                    guard let slot, let keysym = shared.keysDown.removeValue(forKey: slot) else { return }
                    messages.append(keyMessage(keysym: keysym, isDown: false, &shared))
                }
            case .text(let text):
                for keysym in text.flatMap({ X11Keysym.keysyms(for: $0, style: keyStyle) }) {
                    messages.append(keyMessage(keysym: keysym, isDown: true, &shared))
                    messages.append(keyMessage(keysym: keysym, isDown: false, &shared))
                }
            case .pointer(let pointer):
                guard pointer.layoutGeneration == shared.layout.generation,
                      let position = Self.wirePosition(pointer.position, on: pointer.display, in: shared)
                else {
                    // A position on displays that no longer exist means nothing, but a press or
                    // release does: a lost release leaves the Mac's button down. It goes where
                    // the pointer last was.
                    guard pointer.buttons != shared.buttonsDown else { return }
                    shared.buttonsDown = pointer.buttons
                    messages.append(pointerMessage(
                        buttonMask: AppleButtonMask.encode(pointer.buttons), x: shared.lastPointer.x, y: shared.lastPointer.y, &shared
                    ))
                    break
                }
                shared.lastPointer = position
                move = pointer.buttons == shared.buttonsDown ? .pointer : nil
                shared.buttonsDown = pointer.buttons
                messages.append(pointerMessage(buttonMask: AppleButtonMask.encode(pointer.buttons), x: position.x, y: position.y, &shared))
                if !shared.cursor.isCompositedInFrames, let placement = shared.placements[pointer.display] {
                    // The pointer is drawn by the client, at once, where the user put it.
                    shared.cursor.position = PixelPoint(
                        x: Double(placement.originX) + pointer.position.x,
                        y: Double(placement.originY) + pointer.position.y
                    )
                }
            case .scroll(let scroll):
                guard scroll.layoutGeneration == shared.layout.generation,
                      let position = Self.wirePosition(scroll.position, on: scroll.display, in: shared),
                      let placement = shared.placements[scroll.display]
                else { return }
                // The Mac scrolls by a distance in points. Wheel notches count ten points each.
                let unit = scroll.isPrecise ? 1 / placement.scale : 10
                if scroll.phase == .began { shared.scrollRemainder = (0, 0) }
                let x = scroll.deltaX * unit + shared.scrollRemainder.x
                let y = scroll.deltaY * unit + shared.scrollRemainder.y
                let wholeX = x.rounded(.towardZero)
                let wholeY = y.rounded(.towardZero)
                shared.scrollRemainder = (x - wholeX, y - wholeY)
                // A phase change matters even without distance: swipe navigation and rubber-banding
                // in the Mac's apps follow the phases, and do nothing without them.
                var phase = Self.scrollPhase(scroll.phase)
                let momentum = Self.momentumPhase(scroll.momentumPhase)
                // The Mac's apps take a swipe's direction from its first event, as a trackpad
                // reports it: "began" carries the first movement. One without is held until then.
                let moves = wholeX != 0 || wholeY != 0
                switch phase {
                case .began where !moves:
                    shared.isScrollBeginHeld = true
                    return
                case .changed where shared.isScrollBeginHeld:
                    guard moves else { return }
                    shared.isScrollBeginHeld = false
                    phase = .began
                case .ended, .cancelled:
                    // Fingers that touched and lifted without moving scrolled nothing.
                    if shared.isScrollBeginHeld {
                        shared.isScrollBeginHeld = false
                        return
                    }
                default:
                    break
                }
                guard moves || phase != .none || momentum != .none else { return }
                messages.append(ClientMessage.scroll(
                    deltaX: Int32(clamping: Int(wholeX)), deltaY: Int32(clamping: Int(wholeY)), x: position.x, y: position.y,
                    phase: phase.rawValue, momentumPhase: momentum.rawValue, flags: scroll.isPrecise ? .continuous : []
                ))
            case .gesture(let gesture):
                guard gesture.layoutGeneration == shared.layout.generation,
                      let position = Self.wirePosition(gesture.position, on: gesture.display, in: shared)
                else { return }
                messages.append(contentsOf: Self.gestureMessages(gesture, x: position.x, y: position.y))
            case .touch(let touch):
                guard shared.capabilities.touch.isAvailable else { return }
                guard touch.layoutGeneration == shared.layout.generation,
                      let placement = shared.placements[touch.display],
                      let frame = shared.layout[touch.display]?.frameInDesktop
                else {
                    // Fingers on displays that no longer exist mean nothing; the ones still down
                    // where they last were are let go, or they would stay down on the Mac.
                    messages = releaseTouches(&shared)
                    return
                }
                if let held = shared.touches, held.screen != placement.screen {
                    messages = releaseTouches(&shared)
                }
                let contacts = Self.digitizerContacts(touch.contacts, in: frame)
                guard !contacts.isEmpty else { return }
                let down = contacts.filter(\.isTouching)
                if let held = shared.touches, down.count == contacts.count, down.map(\.identifier) == held.contacts.map(\.identifier) {
                    move = .touch
                }
                shared.touches = down.isEmpty ? nil : (placement.screen, down)
                messages.append(ClientMessage.hidReport(display: placement.screen, report: DigitizerReport(contacts: contacts).data))
            case .releaseAll:
                messages = releaseEverything(&shared)
            }
        }
        deliverInput(messages, move: move)
        if case .pointer = event {
            cursorUpdates.send(shared.withLock { $0.cursor })
        }
    }

    func deliverRawInput(_ messages: [Data]) {
        guard shared.withLock({ !$0.state.isDisconnected }) else { return }
        deliverInput(messages)
    }

    /// How much may wait to be written before pointer moves are coalesced: a few hundred moves'
    /// worth, well under a second on any path the session works on at all.
    static let inputBacklogLimit = 16 << 10

    /// Sends input messages now, or holds them until the Mac takes input. Order is kept either way.
    ///
    /// A pointer or touch move while the connection is backed up (a stalled TCP path) replaces the
    /// move of the same kind before it that has not gone out yet: the Mac would otherwise replay the
    /// whole old path once the path clears. Presses, releases, fingers landing or lifting, keys and
    /// gestures are never dropped, and a waiting move goes out ahead of them.
    private func deliverInput(_ messages: [Data], move: MoveKind? = nil) {
        guard !messages.isEmpty else { return }
        let now = ContinuousClock.now
        let backlog = connection.queuedBytes
        let sendNow: [Data] = shared.withLock { shared in
            if now >= shared.inputOpensAt {
                if let move, backlog >= Self.inputBacklogLimit, let last = messages.last {
                    let other = shared.pendingMove.flatMap { $0.kind == move ? nil : $0.message }
                    shared.pendingMove = (last, move)
                    scheduleMoveFlush(&shared)
                    return other.map { [$0] } ?? []
                }
                defer {
                    shared.heldInput.removeAll()
                    shared.pendingMove = nil
                }
                return shared.heldInput + (shared.pendingMove.map { [$0.message] } ?? []) + messages
            }
            shared.heldInput.append(contentsOf: messages)
            scheduleInputFlush(&shared)
            return []
        }
        for message in sendNow { connection.send(message) }
    }

    /// Holds input around a display change until `instant`, replacing the hold of an earlier one.
    /// The hold after the login still applies on its own.
    func holdInputAfterDisplayChange(until instant: ContinuousClock.Instant) {
        guard timing.holdsInputAroundDisplayChanges else { return }
        let flushNow: Bool = shared.withLock { shared in
            shared.displayChangeHoldUntil = instant
            // The waiting flush was timed for the old hold; time it for this one.
            guard shared.inputFlush != nil else { return false }
            shared.inputFlush?.cancel()
            shared.inputFlush = nil
            guard shared.inputOpensAt > .now else { return true }
            scheduleInputFlush(&shared)
            return false
        }
        if flushNow { flushHeldInput() }
    }

    /// Sends the waiting pointer move once the backlog has drained.
    private func scheduleMoveFlush(_ shared: inout Shared) {
        guard shared.moveFlush == nil else { return }
        shared.moveFlush = Task { [weak self, connection] in
            try? await connection.waitForSendRoom(below: Self.inputBacklogLimit)
            guard let self else { return }
            self.shared.withLock { shared in
                shared.moveFlush = nil
                guard !shared.state.isDisconnected, let move = shared.pendingMove else { return }
                shared.pendingMove = nil
                // Inside the lock, so nothing sent meanwhile can overtake it.
                self.connection.send(move.message)
            }
        }
    }

    private func scheduleInputFlush(_ shared: inout Shared) {
        guard shared.inputFlush == nil else { return }
        let until = shared.inputOpensAt
        shared.inputFlush = Task { [weak self] in
            try? await ContinuousClock().sleep(until: until)
            guard !Task.isCancelled else { return }
            self?.flushHeldInput()
        }
    }

    private func flushHeldInput() {
        let held: [Data] = shared.withLock { shared in
            shared.inputFlush = nil
            guard !shared.state.isDisconnected else { return [] }
            // The hold may have been extended meanwhile.
            if ContinuousClock.now < shared.inputOpensAt {
                if !shared.heldInput.isEmpty { scheduleInputFlush(&shared) }
                return []
            }
            defer { shared.heldInput.removeAll() }
            return shared.heldInput
        }
        for message in held { connection.send(message) }
    }

    /// The Mac's pointer moved without this viewer: the pointer is drawn there, and the viewer's
    /// own pointer goes on from there.
    func movePointerFromRemote(x: UInt16, y: UInt16) {
        let state: CursorState? = shared.withLock { shared in
            // The Mac reports this viewer's own moves too, once they have taken effect.
            guard (x, y) != shared.lastPointer else { return nil }
            shared.lastPointer = (x, y)
            let scale = shared.placements.values.first?.serverScale ?? 1
            shared.cursor.position = PixelPoint(x: Double(x) * scale, y: Double(y) * scale)
            shared.cursor.remoteMoves &+= 1
            return shared.cursor
        }
        if let state { cursorUpdates.send(state) }
    }

    private static func wirePosition(_ position: PixelPoint, on display: DisplayID, in shared: Shared) -> (x: UInt16, y: UInt16)? {
        guard let placement = shared.placements[display], let frame = shared.layout[display]?.frameInDesktop else { return nil }
        let localX = min(max(position.x, 0), Double(frame.width - 1))
        let localY = min(max(position.y, 0), Double(frame.height - 1))
        let x = (Double(placement.originX) + localX) / placement.serverScale
        let y = (Double(placement.originY) + localY) / placement.serverScale
        return (UInt16(clamping: Int(x.rounded(.down))), UInt16(clamping: Int(y.rounded(.down))))
    }

    static func scrollPhase(_ phase: ScrollEvent.Phase) -> ScrollPhase {
        switch phase {
        case .none: .none
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        }
    }

    static func momentumPhase(_ phase: ScrollEvent.Phase) -> MomentumPhase {
        switch phase {
        case .none: .none
        case .began: .begin
        case .changed: .continue
        case .ended, .cancelled: .end
        }
    }

    static func gesturePhase(_ phase: ScrollEvent.Phase) -> GesturePhase {
        switch phase {
        // A lone event with no phase is a step of a gesture already under way.
        case .none, .changed: .changed
        case .began: .began
        case .ended: .ended
        case .cancelled: .cancelled
        }
    }

    /// What Screen Sharing.app sends for each trackpad gesture, as on macOS 27.0.1 (see the
    /// protocol notes).
    static func gestureMessages(_ gesture: GestureEvent, x: UInt16, y: UInt16) -> [Data] {
        switch gesture.kind {
        case .magnify(let magnification):
            return [ClientMessage.gestureMagnify(magnification, phase: gesturePhase(gesture.phase).rawValue, x: x, y: y)]
        case .rotate(let degrees):
            return [ClientMessage.gestureRotate(degrees: degrees, phase: gesturePhase(gesture.phase).rawValue, x: x, y: y)]
        case .smartMagnify:
            return [ClientMessage.gestureSmartMagnify(x: x, y: y)]
        case .quickLook:
            return [ClientMessage.gestureLookUp(x: x, y: y)]
        case .swipe(let dx, _):
            // A navigation swipe is a horizontal page swipe: mask 4, with the direction in the sign
            // of the progress (positive goes back). The Mac reads the phase from the motion field:
            // 2 while under way, then 1 to finish it.
            guard dx != 0, dx.isFinite else { return [] }
            let direction: Float = dx > 0 ? 1 : -1
            func swipe(_ motion: UInt32, _ progress: Float) -> Data {
                ClientMessage.gesturePageSwipe(PageSwipe(motion: motion, swipeMask: 4, progress: progress), x: x, y: y)
            }
            return [swipe(2, 0), swipe(2, direction / 2), swipe(2, direction), swipe(1, direction)]
        }
    }

    private func releaseEverything(_ shared: inout Shared) -> [Data] {
        var messages = shared.keysDown.values.map { keyMessage(keysym: $0, isDown: false, &shared) }
        shared.keysDown.removeAll()
        if !shared.buttonsDown.isEmpty {
            shared.buttonsDown = []
            messages.append(pointerMessage(buttonMask: 0, x: shared.lastPointer.x, y: shared.lastPointer.y, &shared))
        }
        messages += releaseTouches(&shared)
        return messages
    }

    /// Takes every finger still down off the Mac's touch screen, as cancelled: what they started
    /// is abandoned rather than finished.
    private func releaseTouches(_ shared: inout Shared) -> [Data] {
        guard let held = shared.touches else { return [] }
        shared.touches = nil
        let contacts = held.contacts.map { contact in
            var contact = contact
            contact.isTouching = false
            contact.isInRange = false
            contact.isCancelled = true
            return contact
        }
        return [ClientMessage.hidReport(display: held.screen, report: DigitizerReport(contacts: contacts).data)]
    }

    /// Fingers as a Mac's touch screen reads them: positions as fractions of the display, at most
    /// as many fingers as it follows, each by an identifier it can hold.
    static func digitizerContacts(_ contacts: [TouchEvent.Contact], in frame: PixelRect) -> [DigitizerReport.Contact] {
        let ids = 0..<DigitizerReport.maximumContacts
        let width = Double(max(frame.width - 1, 1))
        let height = Double(max(frame.height - 1, 1))
        var result: [DigitizerReport.Contact] = []
        for contact in contacts where ids.contains(contact.id) && result.count < DigitizerReport.maximumContacts {
            let x = DigitizerReport.Contact.scaled(contact.position.x / width)
            let y = DigitizerReport.Contact.scaled(contact.position.y / height)
            result.append(DigitizerReport.Contact(
                identifier: UInt8(contact.id), isTouching: contact.phase == .touching, isCancelled: contact.phase == .cancelled, x: x, y: y
            ))
        }
        return result
    }

    /// The microseconds since the key or pointer event before this one, as an encrypted event
    /// carries them, and notes this one's time.
    private static func elapsedMicroseconds(_ shared: inout Shared) -> UInt32 {
        let now = ContinuousClock.now
        defer { shared.lastInputAt = now }
        guard let last = shared.lastInputAt else { return 0 }
        let elapsed = now - last
        let microseconds = elapsed.components.seconds * 1_000_000 + elapsed.components.attoseconds / 1_000_000_000_000
        return UInt32(clamping: microseconds)
    }

    /// One key event on the wire: encrypted when the session can, as Screen Sharing.app sends it.
    func keyMessage(keysym: UInt32, isDown: Bool, _ shared: inout Shared) -> Data {
        guard let inputCipher else { return ClientMessage.keyEvent(keysym: keysym, isDown: isDown) }
        let block = EncryptedInputEvent.keyBlock(keysym: keysym, isDown: isDown, elapsedMicroseconds: Self.elapsedMicroseconds(&shared))
        return inputCipher.message(flags: EncryptedInputEvent.plainFlags, block: block)
    }

    func pointerMessage(buttonMask: UInt8, x: UInt16, y: UInt16, _ shared: inout Shared) -> Data {
        guard let inputCipher else { return ClientMessage.pointerEvent(buttonMask: buttonMask, x: x, y: y) }
        let block = EncryptedInputEvent.pointerBlock(buttonMask: buttonMask, x: x, y: y, elapsedMicroseconds: Self.elapsedMicroseconds(&shared))
        return inputCipher.message(flags: EncryptedInputEvent.plainFlags, block: block)
    }

    // MARK: Media (called on the media legs' receive queues)

    func prepareDecoders(legs: Int) {
        let retired: [LegDecoder] = videoDecoders.withLock { decoders in
            defer { decoders = (0..<legs).map { LegDecoder(leg: $0, core: self) } }
            return decoders
        }
        // Dropping a decoder waits for its pictures in flight, so it happens outside the lock.
        for old in retired { old.decoder.invalidate() }
        audioDecoder.withLock { $0.restart() }
    }

    /// The picture codec High Performance asks the Mac for.
    let videoCodec: MediaVideoCodec
    /// Whether this device takes HDR pictures at all: displays asked for HDR get it only then.
    let allowsHDR: Bool

    let diagnostics: (@Sendable (String) -> Void)?

    func note(_ text: @autoclosure () -> String) {
        diagnostics?(text())
    }

    func handleMedia(_ event: MediaStreamEvent) {
        switch event {
        case .picture(let leg, let unit, _):
            if diagnostics != nil, unit.isKeyframe || unit.isRefresh {
                note("leg \(leg): \(unit.isKeyframe ? "keyframe" : "refresh picture"), \(unit.nalUnits.reduce(0) { $0 + $1.count }) bytes")
            }
            // Nothing is decoded, or acknowledged, while the app cannot show it.
            guard !shared.withLock({ $0.isSuspended }),
                  let slot = videoDecoders.withLock({ $0.indices.contains(leg) ? $0[leg] : nil })
            else { return }
            decode(unit, with: slot)
        case .audio(let payload, let timestamp, let arrival):
            let (continuation, suspended) = shared.withLock { ($0.audio, $0.isSuspended) }
            guard let continuation, !suspended else { return }
            let decoded = audioDecoder.withLock { $0.decode(payload, timestamp: timestamp, arrival: arrival) }
            switch decoded {
            case .success(let chunk?):
                continuation.yield(chunk)
            case .success(nil):
                break
            case .failure(let failure):
                if failure.count == 1 || failure.count.isMultiple(of: 500) {
                    note("sound: \(failure.count) frame(s) failed to decode, latest \(failure.status)")
                }
            }
        case .pictureLoss(let leg):
            note("leg \(leg): packets lost; asked the Mac for a picture to restart from")
        case .failed(let error):
            finish(.connectionLost(detail: String(localized: "media stream: \(error)", bundle: #bundle)))
        }
    }

    /// Submits one picture, and deals with what the decoder says at once.
    private func decode(_ unit: AccessUnit, with slot: LegDecoder) {
        let receiver = shared.withLock { $0.mediaReceiver }
        let picture = EncodedPicture(
            codec: unit.codec == .hevc ? .hevc : .h264, nalUnits: unit.nalUnits, isKeyframe: unit.isKeyframe,
            timestamp: unit.timestamp, source: unit.ssrc
        )
        do {
            try slot.decoder.decode(picture)
            slot.health.withLock { $0.stall.noteSubmitted() }
        } catch .needsKeyframe {
            receiver?.requestKeyframe(leg: slot.leg)
        } catch .pictureSkipped(let status) {
            note("leg \(slot.leg): the decoder skipped a picture (\(status)); asked for a refresh")
            receiver?.requestRefresh(leg: slot.leg)
        } catch .unsupportedStream(let status) {
            // A device that decodes the Mac's 8-bit pictures but not its HDR ones can go on in SDR.
            if (VideoDecoder.bitsPerComponent(of: picture) ?? 8) > 8 {
                shared.withLock { $0.refusedHDR = true }
            } else {
                shared.withLock { $0.foundNoDecoder = true }
            }
            rebuild(slot, because: "decoding failed (unsupportedStream(status: \(status)))")
        } catch {
            rebuild(slot, because: "decoding failed (\(error))")
        }
        if slot.health.withLock({ $0.stall.isStalled(at: .now) }) {
            rebuild(slot, because: "the decoder took pictures for a second and gave nothing back")
        }
    }

    /// Starts a leg's decoder over and asks for a keyframe for it: at most once in a short while,
    /// since one failure is often followed by more from pictures already in flight.
    private func rebuild(_ slot: LegDecoder, because reason: String) {
        let now = ContinuousClock.now
        let due = slot.health.withLock { health -> Bool in
            guard health.lastRebuild.map({ now - $0 >= LegDecoder.rebuildCooldown }) ?? true else { return false }
            health.lastRebuild = now
            return true
        }
        if due {
            note("leg \(slot.leg): \(reason); rebuilt the decoder and asked for a keyframe")
            slot.decoder.invalidate()
        }
        shared.withLock { $0.mediaReceiver }?.requestKeyframe(leg: slot.leg)
    }

    /// A decoder's result, on a VideoToolbox thread.
    fileprivate func decoded(_ result: Result<DecodedPicture, VideoDecoderError>, leg: Int, token: UInt64) {
        guard let slot = videoDecoders.withLock({ $0.indices.contains(leg) && $0[leg].token == token ? $0[leg] : nil }) else { return }
        slot.health.withLock { $0.stall.noteDelivered() }
        switch result {
        case .failure(.noImage):
            // A picture the decoder dropped, or one not meant for output: nothing to show or mend.
            let count = slot.health.withLock { health -> Int in
                health.imagelessPictures += 1
                return health.imagelessPictures
            }
            if count == 1 || count.isMultiple(of: 500) { note("leg \(leg): \(count) picture(s) decoded to no image") }
        case .failure(.pictureSkipped(let status)):
            note("leg \(leg): the decoder skipped a picture (\(status)); asked for a refresh")
            shared.withLock { $0.mediaReceiver }?.requestRefresh(leg: leg)
        case .failure(let error):
            decoderRecovery.async { [weak self] in self?.rebuild(slot, because: "decoding failed (\(error))") }
        case .success(let picture):
            // The Mac may now predict a refresh picture from this one, which the decoder holds.
            shared.withLock { $0.mediaReceiver }?.acknowledge(leg: leg, ssrc: picture.source, timestamp: picture.timestamp)
            let isHDR = picture.isHDR
            let target: (hub: FrameHub, id: DisplayID, generation: UInt64, layoutChanged: Bool)? = shared.withLock { shared in
                guard shared.legDisplays.indices.contains(leg) else { return nil }
                let id = shared.legDisplays[leg]
                guard let hub = shared.hubs[id], let display = shared.layout[id] else { return nil }
                // A picture of the size the layout promises is the display coming up.
                guard display.pixelSize == PixelSize(width: picture.width, height: picture.height),
                      let index = shared.layout.displays.firstIndex(where: { $0.id == id })
                else { return nil }
                var changed = false
                if display.state != .live, !shared.awaitingNewLayout {
                    shared.layout.displays[index].state = .live
                    changed = true
                }
                // Whether a display is HDR is what its pictures are, whatever was asked for.
                if display.isHDR != isHDR {
                    shared.layout.displays[index].isHDR = isHDR
                    changed = true
                }
                return (hub, id, shared.layout.generation, changed)
            }
            guard let target else { return }
            let size = PixelSize(width: picture.width, height: picture.height)
            target.hub.publish(DisplayFrame(display: target.id, surface: picture.surface, pixelSize: size, damage: .full(size), layoutGeneration: target.generation))
            if target.layoutChanged { announceLayout() }
            displaysMayBeReady()
        }
    }

    // MARK: Pasteboard

    /// Asks the Mac for its pasteboard and waits for the reply, for a while: a fetch nobody
    /// answers must not hold up the clipboard for the rest of the session.
    func fetchPasteboard() async throws -> [ClipboardItem] {
        let token: UInt32 = shared.withLock { shared in
            defer { shared.nextPasteboardToken &+= 1 }
            return shared.nextPasteboardToken
        }
        // The answer travels behind whatever the Mac is already sending (a large picture on a slow
        // link takes a while), so the fetch is given up when the connection has gone quiet for the
        // limit, or after six times the limit whatever arrives.
        let timer = Task { [weak self, limit = timing.pasteboardFetchLimit, connection] in
            let started = ContinuousClock.now
            while !Task.isCancelled {
                let now = ContinuousClock.now
                if now - max(started, connection.lastReceivedAt) >= limit || now - started >= limit * 6 {
                    self?.abandonPasteboardFetch(token, with: .transport(.timedOut))
                    return
                }
                try? await Task.sleep(for: min(limit / 4, .seconds(1)))
            }
        }
        defer { timer.cancel() }
        let result: Result<[ClipboardItem], ARDError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let stillOpen: Bool = shared.withLock { shared in
                    guard !shared.state.isDisconnected else { return false }
                    shared.pasteboardWaiters[token] = continuation
                    return true
                }
                if stillOpen {
                    connection.send(ClientMessage.pasteboardFetch(token: token))
                    // Cancelled before the waiter was registered: the handler found nothing to remove.
                    if Task.isCancelled { abandonPasteboardFetch(token, with: .cancelled) }
                } else {
                    continuation.resume(returning: .failure(.closedByPeer))
                }
            }
        } onCancel: {
            abandonPasteboardFetch(token, with: .cancelled)
        }
        return try result.get()
    }

    private func abandonPasteboardFetch(_ token: UInt32, with error: ARDError) {
        shared.withLock { $0.pasteboardWaiters.removeValue(forKey: token) }?.resume(returning: .failure(error))
    }

    func deliverPasteboard(_ data: PasteboardData) {
        if diagnostics != nil { note(PasteboardArchive.describe(data)) }
        let waiter = shared.withLock { $0.pasteboardWaiters.removeValue(forKey: data.token) }
        guard let waiter else { return }
        do {
            waiter.resume(returning: .success(try PasteboardArchive.items(from: data)))
        } catch {
            waiter.resume(returning: .failure(ARDError(error)))
        }
    }

    func announceRemotePasteboardChange() {
        let count: UInt64 = shared.withLock { shared in
            shared.clipboardChangeCount += 1
            return shared.clipboardChangeCount
        }
        clipboardOffers.send(RemoteClipboardOffer(changeCount: count, typeIdentifiers: []) { [weak self] in
            guard let self else { throw ARDError.closedByPeer }
            return try await self.fetchPasteboard()
        })
    }

    // MARK: Lifecycle

    func setSuspended(_ suspended: Bool) -> Bool {
        let (changed, messages): (Bool, [Data]) = shared.withLock { shared in
            guard !shared.state.isDisconnected, shared.isSuspended != suspended else { return (false, []) }
            // Nothing may stay held on the Mac while the app cannot see it.
            let releases = suspended ? releaseEverything(&shared) : []
            shared.isSuspended = suspended
            shared.state = suspended ? .suspended : .connected
            if suspended { shared.suspendedAt = .now }
            if !suspended {
                shared.mediaWatchEpoch = .now
                shared.controlWatchEpoch = .now
            }
            return (true, releases)
        }
        for message in messages { connection.send(message) }
        if changed { events.send(.stateChanged(suspended ? .suspended : .connected)) }
        return changed
    }

    func finish(_ reason: DisconnectReason) {
        struct Teardown {
            var hubs: [FrameHub]
            var task: Task<Void, Never>?
            var receiver: MediaStreamReceiver?
            var audio: AsyncStream<AudioChunk>.Continuation?
            var waiters: [CheckedContinuation<Result<[ClipboardItem], ARDError>, Never>]
            var releases: [Data]
        }
        let teardown: Teardown? = shared.withLock { shared in
            guard !shared.state.isDisconnected else { return nil }
            let releases = releaseEverything(&shared)
            shared.state = .disconnected(reason)
            // Capability objects refer back to this core.
            shared.capabilities = SessionCapabilities()
            shared.inputFlush?.cancel()
            shared.moveFlush?.cancel()
            shared.heldInput.removeAll()
            defer {
                shared.hubs.removeAll()
                shared.engineTask = nil
                shared.mediaReceiver = nil
                shared.audio = nil
                shared.pasteboardWaiters.removeAll()
            }
            return Teardown(
                hubs: Array(shared.hubs.values), task: shared.engineTask, receiver: shared.mediaReceiver,
                audio: shared.audio, waiters: Array(shared.pasteboardWaiters.values), releases: releases
            )
        }
        guard let teardown else { return }
        fileTransfers.close()
        fileDrags.close()
        // Let go of held keys and buttons before the connection closes. Whatever ended the session,
        // the connection may still carry them (a stalled stream or a bad message leaves it working),
        // and where it cannot they are dropped unsent.
        for message in teardown.releases { connection.send(message) }
        teardown.receiver?.stop()
        teardown.task?.cancel()
        teardown.audio?.finish()
        for waiter in teardown.waiters { waiter.resume(returning: .failure(.closedByPeer)) }
        let decoders: [LegDecoder] = videoDecoders.withLock { decoders in
            defer { decoders = [] }
            return decoders
        }
        for slot in decoders { slot.decoder.invalidate() }
        for hub in teardown.hubs { hub.finish() }
        events.send(.stateChanged(.disconnected(reason)))
        events.finish()
        cursorUpdates.finish()
        clipboardOffers.finish()
        ready.resolve(.failure(Self.connectionFailure(for: reason)))
        let closing = Task { [connection, limit = timing.closeDrainLimit] in await connection.close(drainLimit: limit) }
        shared.withLock { $0.closing = closing }
    }

    /// Waits until the connection of a session that has ended is closed, so that a new connection
    /// to the same Mac does not find this one still holding it.
    func closed() async {
        await shared.withLock { $0.closing }?.value
    }

    /// The Mac's word on whether it takes this viewer's input. Without it the control capability is
    /// withdrawn, so a front end can say so instead of sending input that goes nowhere.
    func setRemoteControlAllowed(_ allowed: Bool) {
        let update: (capabilities: SessionCapabilities, release: [Data])? = shared.withLock { shared in
            guard !shared.state.isDisconnected, shared.isControlRefused == allowed else { return nil }
            shared.isControlRefused = !allowed
            shared.capabilities.control = allowed && serverInit.flags?.contains(.observeOnly) != true
                ? .available(ARDControl(core: self))
                : .unavailable(.notPermitted)
            shared.capabilities.curtain = curtainCapability(for: shared)
            shared.capabilities.touch = touchCapability(for: shared)
            // Touches stop being sent here, so fingers still down are let go now.
            let release = shared.capabilities.touch.isAvailable ? [] : releaseTouches(&shared)
            return (shared.capabilities, release)
        }
        guard let update else { return }
        deliverInput(update.release)
        let capabilities = update.capabilities
        note(allowed ? "the Mac takes this viewer's input again" : "the Mac takes no input from this viewer")
        events.send(.capabilitiesChanged(capabilities))
    }

    /// HDR became impossible for the rest of the session: the stream stepped down to the
    /// constrained profile, or this device cannot decode the Mac's HDR pictures.
    func setHDRUnavailable(_ reason: UnavailableReason) {
        let capabilities: SessionCapabilities? = shared.withLock { shared in
            guard !shared.state.isDisconnected, shared.capabilities.highDynamicRange.isAvailable else { return nil }
            shared.capabilities.highDynamicRange = .unavailable(reason)
            return shared.capabilities
        }
        guard let capabilities else { return }
        events.send(.capabilitiesChanged(capabilities))
    }

    /// Curtain mode as a layout tells it. The Mac never answers a curtain request, so this is the
    /// only word on whether one was carried out.
    func setCurtainState(_ state: DisplayLayout.CurtainState) {
        let capabilities: SessionCapabilities? = shared.withLock { shared in
            guard !shared.state.isDisconnected, shared.curtainState != state else { return nil }
            shared.curtainState = state
            shared.capabilities.curtain = curtainCapability(for: shared)
            return shared.capabilities
        }
        guard let capabilities else { return }
        note("curtain mode: \(state)")
        events.send(.capabilitiesChanged(capabilities))
    }

    /// Whether the session is on the Mac's own screen, as a layout tells it.
    func setOnConsole(_ isOnConsole: Bool) {
        let update: (capabilities: SessionCapabilities, release: [Data])? = shared.withLock { shared in
            guard !shared.state.isDisconnected, shared.isOnConsole != isOnConsole else { return nil }
            shared.isOnConsole = isOnConsole
            shared.capabilities.touch = touchCapability(for: shared)
            let release = shared.capabilities.touch.isAvailable ? [] : releaseTouches(&shared)
            return (shared.capabilities, release)
        }
        guard let update else { return }
        deliverInput(update.release)
        events.send(.capabilitiesChanged(update.capabilities))
    }

    /// Touches, where the Mac takes them (macOS 27.3 and later lists ``ClientMessageType/hidReport``).
    /// It passes them on only for a session on its own screen, in High Performance as well; a
    /// session of one's own gets none.
    func touchCapability(for shared: Shared) -> Capability<TouchInput> {
        guard serverInit.acceptedMessages?.contains(ClientMessageType.hidReport) == true else { return .unavailable(.notSupportedByServer) }
        guard !shared.isControlRefused, serverInit.flags?.contains(.observeOnly) != true else { return .unavailable(.notPermitted) }
        guard shared.isOnConsole else { return .unavailable(.notSupportedByServer) }
        return .available(TouchInput(maximumContacts: DigitizerReport.maximumContacts))
    }

    /// Curtain mode, offered where the Mac offers it. A Mac does so only for a session on its own
    /// screen, never for High Performance's virtual displays: forcing it there stops the picture,
    /// and the virtual display outlives the session with the Mac's own display dark (macOS 27.0.1).
    func curtainCapability(for shared: Shared) -> Capability<any CurtainControl> {
        guard info.mode == .standard else { return .unavailable(.requiresMode(.standard)) }
        guard !shared.isControlRefused, serverInit.flags?.contains(.observeOnly) != true else { return .unavailable(.notPermitted) }
        switch shared.curtainState {
        case .available:
            return .available(ARDCurtain(core: self, isCurtained: false))
        case .curtained:
            return .available(ARDCurtain(core: self, isCurtained: true))
        case .unavailable(let flags) where !flags.isDisjoint(with: [.lockScreen, .loginWindow]):
            return .unavailable(.remoteScreenLocked)
        case .unavailable(let flags) where flags.contains(.onConsole) && !flags.contains(.onVirtualDisplay):
            // On the console's own screen, logged in and unlocked, the Mac withholds it only when
            // Remote Management is off.
            return .unavailable(.notConfigured(detail: String(localized: "Turn on Remote Management in the Mac’s Sharing settings to use curtain mode.", bundle: #bundle)))
        case .unavailable, nil:
            // The session is not on the Mac's own screen (a session of one's own), so there is
            // nothing to hide.
            return .unavailable(.notSupportedByServer)
        }
    }

    /// Switches control mode. Nothing stays held on the Mac when the viewer stops controlling it:
    /// an observer's input is dropped, its releases included.
    func setControlMode(_ mode: ControlMode) {
        let releases: [Data] = shared.withLock { shared in
            defer { shared.controlMode = mode }
            return mode == .observe && shared.controlMode != .observe ? releaseEverything(&shared) : []
        }
        for message in releases { connection.send(message) }
        connection.send(ClientMessage.setMode(AppleScreenSharingBackend.viewerMode(mode)))
    }

    static func disconnectReason(for error: ARDError) -> DisconnectReason {
        switch error {
        case .closedByPeer: .remoteClosed(detail: nil)
        case .transport(let transport): .connectionLost(detail: String(describing: transport))
        case .cancelled: .userInitiated
        case .protocolViolation(let detail): .protocolViolation(detail: detail)
        case .refused(let reason): .remoteClosed(detail: reason)
        case .authenticationFailed, .credentialTooLong: .remoteClosed(detail: nil)
        case .unsupported(let detail), .otherProtocol(let detail), .notEncrypted(let detail): .protocolViolation(detail: detail)
        case .serverNotAuthenticated: .protocolViolation(detail: ARDError.serverNotAuthenticatedExplanation)
        }
    }

    /// What a session that ended before it was ready means for the connection attempt.
    static func connectionFailure(for reason: DisconnectReason) -> ConnectionFailure {
        switch reason {
        case .userInitiated: .cancelled
        case .remoteClosed(let detail): .unreachable(host: "", detail: detail ?? String(localized: "the Mac closed the connection", bundle: #bundle))
        case .connectionLost(let detail): .unreachable(host: "", detail: detail)
        case .mediaStalled: .modeUnavailable(mode: .highPerformance, reason: .notSupportedByServer)
        case .protocolViolation(let detail): .protocolViolation(detail: detail)
        }
    }
}

/// One picture leg's decoder and how it is doing.
final class LegDecoder: Sendable {
    struct Health {
        var stall = DecodeStallDetector()
        var lastRebuild: ContinuousClock.Instant?
        /// Pictures that decoded without an image to show, for diagnostics.
        var imagelessPictures = 0
    }

    /// One failure is often followed by more, from pictures already in flight; the decoder is
    /// rebuilt for the first of them only.
    static let rebuildCooldown: Duration = .milliseconds(250)

    private static let tokens = Atomic<UInt64>(0)

    let leg: Int
    /// Tells this decoder's results from those of the one it replaced, or that replaced it.
    let token: UInt64
    let decoder: VideoDecoder
    let health = Mutex(Health())

    init(leg: Int, core: ARDSessionCore) {
        let token = Self.tokens.add(1, ordering: .relaxed).newValue
        self.leg = leg
        self.token = token
        // A Mac's stream is more than a software decoder keeps up with; where the hardware
        // refuses it, failing is the honest answer (except in the simulator, which has no
        // hardware decoder of its own; see DecoderCapabilities.liveStreamsNeedHardware).
        decoder = VideoDecoder(allowsSoftwareDecoding: !DecoderCapabilities.liveStreamsNeedHardware) { [weak core] result in
            core?.decoded(result, leg: leg, token: token)
        }
    }
}

/// The sound leg's decoder, and the clock its frames are placed on.
struct AudioDecoding {
    private var decoder: AACELDDecoder?
    /// An RTP timestamp and when it arrived: the frames after it are placed by their timestamps.
    private var anchor: (timestamp: UInt32, arrival: ContinuousClock.Instant)?
    private var expected: UInt32?
    private var failures = 0

    static let clockRate: UInt32 = 48_000
    static let samplesPerFrame: UInt32 = 480

    /// Forgets the stream: for a new offer, whose sound starts over.
    mutating func restart() {
        if decoder == nil { decoder = try? AACELDDecoder() }
        decoder?.reset()
        anchor = nil
        expected = nil
    }

    struct Failure: Error {
        var status: AudioDecoderError
        var count: Int
    }

    /// Decodes one frame, in order. Its presentation time follows the sender's timestamps from the
    /// first frame, so that a player sees gaps and jumps for what they are; a jump of more than a
    /// second, or back, starts the clock and the decoder afresh.
    mutating func decode(_ payload: Data, timestamp: UInt32, arrival: ContinuousClock.Instant) -> Result<AudioChunk?, Failure> {
        if decoder == nil { decoder = try? AACELDDecoder() }
        guard let decoder else { return .success(nil) }
        if let expected, timestamp &- expected >= Self.clockRate {
            decoder.reset()
            anchor = nil
        }
        expected = timestamp &+ Self.samplesPerFrame
        if anchor == nil { anchor = (timestamp, arrival) }
        let samples: Data
        do {
            samples = try decoder.decode(payload)
        } catch {
            failures += 1
            return .failure(Failure(status: error, count: failures))
        }
        guard !samples.isEmpty, let anchor else { return .success(nil) }
        let offset = Double(timestamp &- anchor.timestamp) / Double(Self.clockRate)
        return .success(AudioChunk(
            sampleRate: Double(Self.clockRate), channelCount: 2, samples: samples,
            presentationTime: anchor.arrival + .seconds(offset)
        ))
    }
}
