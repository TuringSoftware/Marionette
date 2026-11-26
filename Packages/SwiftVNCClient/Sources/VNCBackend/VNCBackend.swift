// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
public import RemoteDesktopCore
import SwiftVNCClient
import Synchronization

/// The back end for ordinary VNC servers: anything that speaks standard RFB. A Mac can be reached
/// this way too, without any of Apple's extensions, as a last resort.
public struct VNCBackend: RemoteDesktopBackend {
    public static let backendID = "vnc"

    public var firstFrameTimeout: Duration = .seconds(20)
    /// How long a Mac's server ignores input after a login; input until then is held. A Mac
    /// discards keyboard and pointer events for about two seconds (measured on macOS 27.0.1 on its
    /// own protocol, the same daemon serving this one).
    public var inputSettlingTimeForMacs: Duration = .milliseconds(2600)
    /// After a return from the background, an end within this long, before any new picture, is put
    /// down to the time away and is worth a reconnect. A connection the system took from the
    /// suspended app fails as soon as it is read again.
    public var resumeGraceTime: Duration = .seconds(5)

    public init() {}

    public var descriptor: BackendDescriptor {
        BackendDescriptor(id: Self.backendID, displayName: "VNC", defaultPort: 5900, bonjourServiceType: "_rfb._tcp", supportedModes: [.standard])
    }

    public func connect(_ request: ConnectionRequest) async throws(ConnectionFailure) -> any RemoteSession {
        if case .require(.highPerformance) = request.options.mode {
            throw .modeUnavailable(mode: .highPerformance, reason: .notSupportedByBackend)
        }
        // No VNC login proves that the server knows the password, so a computer that has proved
        // itself before is not even contacted this way: an impostor would get the password.
        if request.options.requiresServerAuthentication {
            throw .identityUnverifiable(detail: String(localized: "Plain VNC cannot prove that this is the computer it says it is.", bundle: #bundle))
        }
        if request.options.requiresEncryption, !request.transport.isTunnelled {
            throw .notEncrypted(detail: String(localized: "Plain VNC does not encrypt the session.", bundle: #bundle))
        }
        let transport = request.transport
        let host = transport.peer.host
        var previousFailure: String?

        // A rejected password ends the connection, so each attempt is a new one.
        for attempt in 1...3 {
            // Phases are reported in their documented order and never go back.
            if attempt == 1 {
                if transport.isTunnelled { request.progress(.openingTunnel) }
                request.progress(.reachingHost)
            }
            let stream: any ByteStream
            do {
                stream = try await transport.openStream(port: transport.peer.port)
            } catch let error as TransportError {
                if Task.isCancelled { throw .cancelled }
                throw Self.failure(for: error, host: host)
            } catch {
                if error is CancellationError || Task.isCancelled { throw .cancelled }
                throw .unreachable(host: host, detail: String(describing: error))
            }

            if attempt == 1 { request.progress(.negotiating) }
            let core = VNCSessionCore(options: request.options, remoteHost: host, isTunnelled: transport.isTunnelled, resumeGraceTime: resumeGraceTime)
            let asked = Mutex(false)
            var handlers = core.handlers()
            let (prompts, progress, failureText) = (request.prompts, request.progress, previousFailure)
            handlers.credential = { kind in
                // Called on the client's thread, which waits here while the person is asked.
                asked.withLock { $0 = true }
                progress(.authenticating)
                let prompt = SessionPrompt.credentials(CredentialRequest(
                    context: .remoteDesktop(host: host),
                    kind: kind == .password ? .passwordOnly : .usernameAndPassword,
                    attempt: attempt, previousFailure: failureText
                ))
                let answer = Mutex<PromptResponse?>(nil)
                let done = DispatchSemaphore(value: 0)
                Task {
                    let response = await prompts.resolve(prompt)
                    answer.withLock { $0 = response }
                    done.signal()
                }
                done.wait()
                guard case .credentials(let username, let password) = answer.withLock({ $0 }) else {
                    core.markCancelled()
                    return nil
                }
                return VNCCredential(username: username, password: password)
            }
            var configuration = VNCConfiguration()
            configuration.sharesDesktop = true
            configuration.quality = VNCQualityControl.quality(for: request.options.quality)
            let client = VNCClient(transport: ByteStreamTransport(stream: stream), configuration: configuration, handlers: handlers)

            let info: VNCServerInfo
            do {
                info = try await client.connect()
            } catch {
                await stream.close()
                if core.wasCancelled || Task.isCancelled { throw .cancelled }
                switch error as? VNCError {
                case .authenticationRejected(let reason):
                    guard asked.withLock({ $0 }) else { throw .authenticationFailed(detail: reason) }
                    previousFailure = reason ?? String(localized: "The password was not accepted.", bundle: #bundle)
                    continue
                case .tooManyAttempts(let reason):
                    throw .authenticationFailed(detail: reason ?? String(localized: "The server takes no more attempts for now.", bundle: #bundle))
                case .refused(let reason):
                    throw Self.failure(forRefusal: reason)
                case .unsupportedAuthentication(let detail):
                    throw .unsupportedServer(detail: detail)
                case .transportFailed(let detail):
                    throw .unreachable(host: host, detail: detail)
                case .connectionFailed(let detail):
                    throw .unsupportedServer(detail: detail)
                case .alreadyStarted, nil:
                    throw .unsupportedServer(detail: String(describing: error))
                }
            }

            request.progress(.preparingDisplays)
            core.setServer(info, inputSettlingTime: inputSettlingTimeForMacs)
            let session = VNCSession(core: core, client: client, info: info)
            let gate = core.ready
            let timer = Task { [firstFrameTimeout] in
                try? await Task.sleep(for: firstFrameTimeout)
                if !Task.isCancelled { gate.resolve(.failure(.timedOut(phase: .preparingDisplays))) }
            }
            defer { timer.cancel() }
            do throws(ConnectionFailure) {
                try await withTaskCancellationHandler { () async throws(ConnectionFailure) in
                    try await gate.wait()
                } onCancel: {
                    gate.resolve(.failure(.cancelled))
                }
            } catch {
                await session.disconnect()
                throw error
            }
            return session
        }
        throw .authenticationFailed(detail: previousFailure)
    }

    /// A server that turned the connection away before authentication, by what it said. TigerVNC
    /// and RealVNC refuse with "Too many security failures" or "Too many authentication failures"
    /// for a while after wrong passwords; asking for the password again would only extend that.
    static func failure(forRefusal reason: String) -> ConnectionFailure {
        let text = reason.lowercased()
        if text.contains("too many") { return .authenticationFailed(detail: reason) }
        if text.contains("security type") || text.contains("authentication scheme") || text.contains("not supported") {
            return .unsupportedServer(detail: reason)
        }
        if text.contains("busy") || text.contains("already") || text.contains("in use") { return .busy(detail: reason) }
        return .permissionDenied(detail: reason.isEmpty ? nil : reason)
    }

    private static func failure(for error: TransportError, host: String) -> ConnectionFailure {
        switch error {
        case .localNetworkDenied: .localNetworkDenied
        case .timedOut: .timedOut(phase: .reachingHost)
        case .tunnel(let detail): .tunnelFailed(detail: detail)
        case .unreachable(let detail), .other(let detail), .unsupported(let detail): .unreachable(host: host, detail: detail)
        case .addressInUse(let port): .busy(detail: String(localized: "Port \(port) is in use on this device.", bundle: #bundle))
        case .closed: .unreachable(host: host, detail: String(localized: "The server closed the connection.", bundle: #bundle))
        }
    }
}

/// A `ByteStream` as the transport of a VNC client.
struct ByteStreamTransport: VNCTransport {
    let stream: any ByteStream

    func read(upTo maxLength: Int) async throws -> Data? { try await stream.read(upTo: maxLength) }
    func write(_ data: Data) async throws { try await stream.write(data) }
    func close() async { await stream.close() }
}

/// Resolves once a session has its first frame, or fails with the reason it never will.
final class FirstFrameGate: Sendable {
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

/// State shared by a VNC session's public face and the client's handlers.
final class VNCSessionCore: Sendable, InputSink {
    static let displayID = DisplayID(1)

    struct Shared {
        var state: SessionState = .connected
        var layout: DesktopLayout = .empty
        var capabilities = SessionCapabilities()
        var hub = FrameHub()
        var cursor = CursorState()
        var controlMode: ControlMode
        var isSuspended = false
        /// Resumed, and neither a picture from the server nor the grace time has come since: an end
        /// now means the connection did not survive the time in the background.
        var awaitsPictureAfterResume = false
        /// Counts returns from the background, so that a grace time ends only the one it began with.
        var resumes = 0
        /// How Option and Command go out: a Mac's own server reads keysyms its own way.
        var keyStyle: X11Keysym.ModifierStyle = .standard
        /// Input is held until then, and sent in order when the time comes (see `setServer`).
        var inputHeldUntil: ContinuousClock.Instant?
        var heldInput: [@Sendable (VNCClient) -> Void] = []
        var keysDown: [KeyCode: UInt32] = [:]
        var symbolsDown: Set<UInt32> = []
        var buttons: PointerButtons = []
        var lastPointer = (x: 0, y: 0)
        var scrollRemainder = (x: 0.0, y: 0.0)
        var client: VNCClient?
        var wasCancelled = false
        var cursorID: UInt64 = 0
        var clipboardChangeCount: UInt64 = 0
        /// Where pictures are made: reused buffers, a few at most (see ``SnapshotBuffers``).
        var snapshotBuffers = SnapshotBuffers()
        /// What changed in pictures that could not be published (every buffer was still in use);
        /// published with the next one.
        var pendingDamage: [PixelRect] = []
        var isRetryingPicture = false
    }

    let options: SessionOptions
    let remoteHost: String
    let isTunnelled: Bool
    /// See ``VNCBackend/resumeGraceTime``.
    let resumeGraceTime: Duration
    let shared: Mutex<Shared>
    let events = Broadcaster<SessionEvent>()
    let cursorUpdates = Broadcaster<CursorState>(replaysLatest: true, bufferingPolicy: .bufferingNewest(1))
    let clipboardOffers = Broadcaster<RemoteClipboardOffer>(replaysLatest: true, bufferingPolicy: .bufferingNewest(1))
    let ready = FirstFrameGate()

    /// Remote pixels of scrolling that make one wheel notch.
    static let pixelsPerNotch = 40.0

    init(options: SessionOptions, remoteHost: String, isTunnelled: Bool, resumeGraceTime: Duration) {
        self.options = options
        self.remoteHost = remoteHost
        self.isTunnelled = isTunnelled
        self.resumeGraceTime = resumeGraceTime
        shared = Mutex(Shared(controlMode: options.controlMode))
        // Until the server sends a shape the viewer draws its own arrow where it last put the pointer.
        cursorUpdates.send(CursorState())
    }

    var wasCancelled: Bool { shared.withLock { $0.wasCancelled } }
    func markCancelled() { shared.withLock { $0.wasCancelled = true } }

    /// Adapts input to the server. A Mac's server announces RFB 3.889 even though the client then
    /// speaks 3.8, and takes Alt as Command, so Option goes as Meta. Its buttons, unlike on its own
    /// protocol, are RFB's over 3.8 (right is bit 2; macOS 27).
    ///
    /// A Mac also silently drops input for about two seconds after a login, on this protocol as on
    /// its own (macOS 27). Input from that time is held and sent, in order, once
    /// `inputSettlingTime` has passed, so it is late rather than lost.
    func setServer(_ info: VNCServerInfo, inputSettlingTime: Duration) {
        let until = ContinuousClock.now + inputSettlingTime
        shared.withLock { shared in
            shared.keyStyle = info.isAppleScreenSharing ? .mac : .standard
            if info.isAppleScreenSharing { shared.inputHeldUntil = until }
        }
        guard info.isAppleScreenSharing else { return }
        Task { [weak self] in
            try? await Task.sleep(until: until)
            self?.sendHeldInput()
        }
    }

    private func sendHeldInput() {
        let (held, client): ([@Sendable (VNCClient) -> Void], VNCClient?) = shared.withLock { shared in
            shared.inputHeldUntil = nil
            defer { shared.heldInput.removeAll() }
            return (shared.heldInput, shared.client)
        }
        guard let client else { return }
        for action in held { action(client) }
    }

    // MARK: Handlers (client thread)

    func handlers() -> VNCHandlers {
        var handlers = VNCHandlers()
        handlers.resized = { [self] width, height in resized(width: width, height: height) }
        handlers.updated = { [self] framebuffer, changed in updated(framebuffer, changed) }
        handlers.cursor = { [self] cursor in
            let state: CursorState = shared.withLock { shared in
                shared.cursorID += 1
                shared.cursor.image = CursorImage(
                    id: shared.cursorID, pixelSize: PixelSize(width: cursor.width, height: cursor.height),
                    bgraPixels: cursor.pixels, hotspot: PixelPoint(x: Double(cursor.hotspotX), y: Double(cursor.hotspotY))
                )
                return shared.cursor
            }
            cursorUpdates.send(state)
        }
        handlers.bell = { [self] in events.send(.notice(.bell)) }
        handlers.clipboard = { [self] text in
            let count: UInt64 = shared.withLock { shared in
                shared.clipboardChangeCount += 1
                return shared.clipboardChangeCount
            }
            clipboardOffers.send(RemoteClipboardOffer(changeCount: count, typeIdentifiers: ["public.utf8-plain-text"]) { [ClipboardItem(text: text)] })
        }
        handlers.disconnected = { [self] reason in finish(disconnectReason(for: reason)) }
        return handlers
    }

    /// Only an end the user asked for, or one the server chose while the app was in the
    /// foreground, is final; a broken connection, or one that did not survive the app being in the
    /// background (iOS takes the sockets of a suspended app), is worth reconnecting.
    func disconnectReason(for reason: VNCDisconnectReason) -> DisconnectReason {
        switch reason {
        case .requested:
            return .userInitiated
        case .connectionLost(let detail):
            return .connectionLost(detail: detail)
        case .connectionClosed:
            let afterSuspend = shared.withLock { $0.isSuspended || $0.awaitsPictureAfterResume }
            return afterSuspend ? .connectionLost(detail: String(localized: "The connection did not survive the app being in the background.", bundle: #bundle)) : .remoteClosed(detail: nil)
        case .protocolError(let detail):
            return .protocolViolation(detail: detail)
        }
    }

    private func resized(width: Int, height: Int) {
        let layout: DesktopLayout = shared.withLock { shared in
            let display = RemoteDisplay(
                id: Self.displayID, name: String(localized: "Screen", bundle: #bundle), kind: .physical,
                frameInDesktop: PixelRect(x: 0, y: 0, width: width, height: height), scale: 1
            )
            shared.layout = DesktopLayout(generation: shared.layout.generation + 1, displays: [display])
            return shared.layout
        }
        events.send(.layoutChanged(layout))
    }

    private func updated(_ framebuffer: VNCFramebuffer, _ changed: [VNCRect]) {
        let changedRects = changed.map { PixelRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        let (hub, generation, suspended, buffer, pending) = shared.withLock { shared in
            if !shared.isSuspended, !framebuffer.isRepublished { shared.awaitsPictureAfterResume = false }
            let buffer = shared.isSuspended ? nil : shared.snapshotBuffers.buffer(width: framebuffer.width, height: framebuffer.height)
            let pending = shared.pendingDamage + changedRects
            shared.pendingDamage = buffer == nil && !shared.isSuspended ? pending : []
            return (shared.hub, shared.layout.generation, shared.isSuspended, buffer, pending)
        }
        guard !suspended else { return }
        guard let buffer, let surface = Self.fill(buffer, from: framebuffer) else {
            // Every buffer is still in use. A still screen would send nothing more to carry this
            // picture, so the client hands it over again shortly. The client has it already;
            // asking the server would also freeze the colour depth (see `requestFullUpdate`).
            let retry = shared.withLock { shared in
                defer { shared.isRetryingPicture = true }
                return shared.isRetryingPicture ? nil : shared.client
            }
            if let retry {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(30))
                    self?.shared.withLock { $0.isRetryingPicture = false }
                    retry.republish()
                }
            }
            return
        }
        let size = PixelSize(width: framebuffer.width, height: framebuffer.height)
        let damage = DamageRegion(pending).clipped(to: PixelRect(size: size))
        hub.publish(DisplayFrame(display: Self.displayID, surface: surface, pixelSize: size, damage: damage, layoutGeneration: generation))
        ready.resolve(.success(()))
    }

    /// Copies the client's framebuffer into `buffer`, which then becomes immutable.
    private static func fill(_ buffer: CVPixelBuffer, from framebuffer: VNCFramebuffer) -> CVReadOnlyPixelBuffer? {
        guard let source = framebuffer.pixels.baseAddress else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let destination = CVPixelBufferGetBaseAddress(buffer) {
            let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
            if destinationStride == framebuffer.bytesPerRow {
                destination.copyMemory(from: source, byteCount: framebuffer.bytesPerRow * framebuffer.height)
            } else {
                for row in 0..<framebuffer.height {
                    (destination + row * destinationStride).copyMemory(from: source + row * framebuffer.bytesPerRow, byteCount: framebuffer.bytesPerRow)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return .adopting(buffer)
    }

    // MARK: Input

    func send(_ event: InputEvent) {
        var actions: [@Sendable (VNCClient) -> Void] = []
        var cursor: CursorState?
        let client: VNCClient? = shared.withLock { shared in
            guard !shared.state.isDisconnected, !shared.isSuspended, shared.controlMode != .observe else { return nil }
            switch event {
            case .key(let key):
                if key.phase == .down {
                    guard var keysym = X11Keysym.forEvent(key, style: shared.keyStyle) else { return nil }
                    // A key already down goes down again only as a repeat, and as what it was pressed as.
                    if let code = key.key {
                        if let pressed = shared.keysDown[code] {
                            guard key.isRepeat else { return nil }
                            keysym = pressed
                        } else {
                            shared.keysDown[code] = keysym
                        }
                    } else if !shared.symbolsDown.insert(keysym).inserted, !key.isRepeat {
                        return nil
                    }
                    actions.append { [keysym] in $0.sendKey(keysym: keysym, isDown: true) }
                } else {
                    let keysym: UInt32?
                    if let code = key.key {
                        keysym = shared.keysDown.removeValue(forKey: code)
                    } else {
                        keysym = X11Keysym.forEvent(key, style: shared.keyStyle).flatMap { shared.symbolsDown.remove($0) }
                    }
                    guard let keysym else { return nil }
                    actions.append { $0.sendKey(keysym: keysym, isDown: false) }
                }
            case .text(let text):
                for keysym in text.flatMap({ X11Keysym.keysyms(for: $0, style: shared.keyStyle) }) {
                    actions.append { $0.sendKey(keysym: keysym, isDown: true) }
                    actions.append { $0.sendKey(keysym: keysym, isDown: false) }
                }
            case .pointer(let pointer):
                guard pointer.layoutGeneration == shared.layout.generation, let frame = shared.layout[pointer.display]?.frameInDesktop else { return nil }
                let x = Int(min(max(pointer.position.x, 0), Double(frame.width - 1)))
                let y = Int(min(max(pointer.position.y, 0), Double(frame.height - 1)))
                shared.lastPointer = (x, y)
                shared.buttons = pointer.buttons
                let mask = Self.mask(pointer.buttons)
                actions.append { $0.sendPointer(x: x, y: y, buttonMask: mask) }
                shared.cursor.position = PixelPoint(x: pointer.position.x, y: pointer.position.y)
                cursor = shared.cursor
            case .scroll(let scroll):
                guard scroll.layoutGeneration == shared.layout.generation else { return nil }
                // RFB has no scroll distance, only wheel clicks: buttons 4–7, pressed and released.
                let unit = scroll.isPrecise ? Self.pixelsPerNotch : 1
                // What was left over from the last gesture must not add a notch to this one.
                if scroll.phase == .began { shared.scrollRemainder = (0, 0) }
                let x = scroll.deltaX / unit + shared.scrollRemainder.x
                let y = scroll.deltaY / unit + shared.scrollRemainder.y
                let (notchesX, notchesY) = (Int(x.rounded(.towardZero)), Int(y.rounded(.towardZero)))
                shared.scrollRemainder = (x - Double(notchesX), y - Double(notchesY))
                let held = Self.mask(shared.buttons)
                let position = shared.lastPointer
                func click(_ bit: Int, times: Int) {
                    for _ in 0..<min(times, 20) {
                        actions.append { $0.sendPointer(x: position.x, y: position.y, buttonMask: held | bit) }
                        actions.append { $0.sendPointer(x: position.x, y: position.y, buttonMask: held) }
                    }
                }
                // Positive deltas move content down or right: wheel up (bit 3) and wheel left (bit 5).
                click(notchesY > 0 ? 1 << 3 : 1 << 4, times: abs(notchesY))
                click(notchesX > 0 ? 1 << 5 : 1 << 6, times: abs(notchesX))
            case .gesture:
                // RFB has no gestures. Stand-ins (a modifier with the wheel for a pinch, say) mean
                // different things to different desktops, so none is sent.
                break
            case .releaseAll:
                actions = Self.releaseEverything(&shared)
            }
            if shared.inputHeldUntil != nil {
                shared.heldInput += actions
                actions.removeAll()
            }
            return shared.client
        }
        if let client {
            for action in actions { action(client) }
        }
        if let cursor { cursorUpdates.send(cursor) }
    }

    /// RFB's button numbering: left, middle, right.
    private static func mask(_ buttons: PointerButtons) -> Int {
        var mask = 0
        if buttons.contains(.primary) { mask |= 1 }
        if buttons.contains(.middle) { mask |= 2 }
        if buttons.contains(.secondary) { mask |= 4 }
        return mask
    }

    private static func releaseEverything(_ shared: inout Shared) -> [@Sendable (VNCClient) -> Void] {
        var actions: [@Sendable (VNCClient) -> Void] = []
        for keysym in Array(shared.keysDown.values) + Array(shared.symbolsDown) {
            actions.append { $0.sendKey(keysym: keysym, isDown: false) }
        }
        shared.keysDown.removeAll()
        shared.symbolsDown.removeAll()
        if !shared.buttons.isEmpty {
            shared.buttons = []
            let position = shared.lastPointer
            actions.append { $0.sendPointer(x: position.x, y: position.y, buttonMask: 0) }
        }
        return actions
    }

    // MARK: Lifecycle

    func setSuspended(_ suspended: Bool) -> Bool {
        var actions: [@Sendable (VNCClient) -> Void] = []
        let result: (changed: Bool, client: VNCClient?) = shared.withLock { shared in
            guard !shared.state.isDisconnected, shared.isSuspended != suspended else { return (false, nil) }
            if suspended {
                actions = Self.releaseEverything(&shared)
                // Releases follow the presses they release, even presses still held back.
                if shared.inputHeldUntil != nil {
                    shared.heldInput += actions
                    actions.removeAll()
                }
            }
            shared.isSuspended = suspended
            shared.awaitsPictureAfterResume = !suspended
            if !suspended { shared.resumes += 1 }
            shared.state = suspended ? .suspended : .connected
            return (true, shared.client)
        }
        if let client = result.client {
            for action in actions { action(client) }
            if suspended {
                client.willSuspend()
            } else {
                // The client went on reading while the app was away; what it has is the picture to
                // show. Asking the server instead would freeze the colour depth
                // (see `requestFullUpdate`).
                client.republish()
                let resume = shared.withLock { $0.resumes }
                Task { [weak self, resumeGraceTime] in
                    try? await Task.sleep(for: resumeGraceTime)
                    self?.shared.withLock { shared in
                        if shared.resumes == resume, !shared.isSuspended { shared.awaitsPictureAfterResume = false }
                    }
                }
            }
        }
        if result.changed { events.send(.stateChanged(suspended ? .suspended : .connected)) }
        return result.changed
    }

    func finish(_ reason: DisconnectReason) {
        let hub: FrameHub? = shared.withLock { shared in
            guard !shared.state.isDisconnected else { return nil }
            shared.state = .disconnected(reason)
            shared.capabilities = SessionCapabilities()
            shared.client = nil
            return shared.hub
        }
        guard let hub else { return }
        hub.finish()
        events.send(.stateChanged(.disconnected(reason)))
        events.finish()
        cursorUpdates.finish()
        clipboardOffers.finish()
        ready.resolve(.failure(.unreachable(host: remoteHost, detail: String(localized: "The server closed the connection.", bundle: #bundle))))
    }
}

/// A live VNC session.
public final class VNCSession: RemoteSession {
    let core: VNCSessionCore
    private let client: VNCClient
    public let info: SessionInfo

    init(core: VNCSessionCore, client: VNCClient, info: VNCServerInfo) {
        self.core = core
        self.client = client
        self.info = SessionInfo(
            backendID: VNCBackend.backendID, mode: .standard, remoteName: info.name,
            securityDescription: core.isTunnelled ? String(localized: "VNC through a tunnel", bundle: #bundle) : String(localized: "VNC, not encrypted", bundle: #bundle),
            isTunnelled: core.isTunnelled
        )
        var capabilities = SessionCapabilities()
        capabilities.clipboard = core.options.wantsClipboard
            ? .available(VNCClipboard(core: core))
            : .unavailable(.notConfigured(detail: String(localized: "Clipboard sharing is switched off for this computer.", bundle: #bundle)))
        capabilities.control = .available(VNCControl(core: core))
        capabilities.audio = .unavailable(.notSupportedByBackend)
        capabilities.quality = .available(VNCQualityControl(core: core))
        capabilities.displayConfiguration = .unavailable(.notSupportedByBackend)
        core.shared.withLock { shared in
            // The handshake may already have ended the session; do not revive it.
            guard !shared.state.isDisconnected else { return }
            shared.client = client
            shared.capabilities = capabilities
        }
    }

    deinit {
        client.disconnect()
    }

    public var state: SessionState { core.shared.withLock { $0.state } }
    public var layout: DesktopLayout { core.shared.withLock { $0.layout } }
    public var capabilities: SessionCapabilities { core.shared.withLock { $0.capabilities } }
    public var input: any InputSink { core }

    public func events() -> AsyncStream<SessionEvent> { core.events.subscribe() }
    public func cursor() -> AsyncStream<CursorState> { core.cursorUpdates.subscribe() }

    public func frames(for display: DisplayID) -> FrameMailbox {
        let hub: FrameHub? = core.shared.withLock { shared in
            display == VNCSessionCore.displayID && !shared.state.isDisconnected ? shared.hub : nil
        }
        if let hub { return hub.subscribe() }
        let empty = FrameMailbox()
        empty.finish()
        return empty
    }

    public func suspend() async { _ = core.setSuspended(true) }
    public func resume() async { _ = core.setSuspended(false) }

    public func disconnect() async {
        guard !state.isDisconnected else { return }
        let ended = core.events.subscribe()
        // Let go of held keys and buttons, then stop; the client's handler marks the session ended.
        core.send(.releaseAll)
        client.disconnect()
        for await event in ended {
            if case .stateChanged(.disconnected) = event { break }
        }
    }
}

final class VNCClipboard: ClipboardSync {
    private weak let core: VNCSessionCore?

    init(core: VNCSessionCore) {
        self.core = core
    }

    func remoteOffers() -> AsyncStream<RemoteClipboardOffer> {
        core?.clipboardOffers.subscribe() ?? AsyncStream { $0.finish() }
    }

    func sendToRemote(_ items: [ClipboardItem]) async throws {
        guard let client = core?.shared.withLock({ $0.client }) else { throw TransportError.closed }
        // VNC carries plain text only. A clipboard without text (an image) is not sent at all:
        // sending it as empty text would wipe the remote clipboard.
        guard let text = items.lazy.compactMap(\.text).first else { return }
        client.sendClipboard(text)
    }
}

/// Adaptive follows the link, lowering JPEG quality and then colours as it slows; Full is lossless.
final class VNCQualityControl: QualityControl {
    private weak let core: VNCSessionCore?

    init(core: VNCSessionCore) {
        self.core = core
    }

    static func quality(for preset: QualityPreset) -> VNCQuality {
        switch preset {
        case .adaptive: .automatic
        case .full: .lossless
        }
    }

    var supportedPresets: [QualityPreset] { [.adaptive, .full] }

    func setPreset(_ preset: QualityPreset) async throws {
        guard let client = core?.shared.withLock({ $0.client }) else { throw TransportError.closed }
        client.setQuality(Self.quality(for: preset))
    }
}

final class VNCControl: SessionControl {
    private weak let core: VNCSessionCore?

    init(core: VNCSessionCore) {
        self.core = core
    }

    // A VNC server has no notion of locking out its own keyboard.
    var supportedModes: [ControlMode] { [.observe, .control] }

    func setControlMode(_ mode: ControlMode) async throws {
        core?.shared.withLock { $0.controlMode = mode == .observe ? .observe : .control }
    }
}
