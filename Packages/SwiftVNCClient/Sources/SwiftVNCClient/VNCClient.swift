// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import CLibVNCClient
public import Foundation
import Synchronization

/// The bytes a VNC session runs over.
public protocol VNCTransport: Sendable {
    /// Waits for data. Returns at least one byte, or `nil` at end of stream.
    func read(upTo maxLength: Int) async throws -> Data?
    func write(_ data: Data) async throws
    func close() async
}

public struct VNCConfiguration: Sendable {
    /// Leave other viewers connected.
    public var sharesDesktop = true
    /// Encoding names in order of preference, as LibVNCClient spells them. Tight comes first: it is
    /// what most servers compress best, sending photographic areas as JPEG.
    public var encodings = "tight zrle ultra copyrect hextile zlib corre rre raw"
    /// 0 (fast) to 9 (small), for the encodings that compress.
    public var compressionLevel = 6
    /// How faithfully the server is asked to send the desktop; ``VNCQuality/automatic`` follows the
    /// measured throughput of the link.
    public var quality = VNCQuality.automatic
    /// Where the throughput estimate behind ``VNCQuality/automatic`` starts, in bits per second.
    /// For tests.
    package var initialBitsPerSecond = VNCThroughputEstimate.initialBitsPerSecond

    public init() {}
}

public enum VNCCredentialKind: Sendable, Hashable {
    /// Classic VNC authentication: a password alone.
    case password
    /// A user name and password (Apple Remote Desktop, MS-Logon).
    case usernameAndPassword
}

public struct VNCCredential: Sendable {
    public var username: String
    public var password: String

    public init(username: String = "", password: String) {
        self.username = username
        self.password = password
    }
}

public struct VNCRect: Sendable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct VNCServerInfo: Sendable, Hashable {
    public var name: String
    public var width: Int
    public var height: Int
    /// The protocol version the server announced, before the client settled on one it speaks.
    public var majorVersion: Int
    public var minorVersion: Int

    public init(name: String, width: Int, height: Int, majorVersion: Int = 3, minorVersion: Int = 8) {
        self.name = name
        self.width = width
        self.height = height
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
    }

    /// A Mac's own screen sharing server, which announces RFB 3.889. It reads keysyms and pointer
    /// buttons its own way (see `X11Keysym.ModifierStyle.mac`).
    public var isAppleScreenSharing: Bool { majorVersion == 3 && minorVersion == 889 }
}

public enum VNCError: Error, Sendable, Equatable {
    /// The handshake failed, with the library's reason where it gave one.
    case connectionFailed(String)
    /// The server turned the connection away before authentication, in its own words.
    case refused(reason: String)
    /// The server rejected the credentials, with its own words if it sent any.
    case authenticationRejected(reason: String?)
    /// The server rejected the credentials and takes no more attempts for now.
    case tooManyAttempts(reason: String?)
    /// The server offers no authentication the client can do.
    case unsupportedAuthentication(String)
    /// The connection to the server broke during the handshake.
    case transportFailed(String)
    case alreadyStarted
}

public enum VNCDisconnectReason: Sendable, Equatable {
    case requested
    /// The server ended the connection.
    case connectionClosed
    /// The connection to the server broke.
    case connectionLost(String)
    /// The server sent something the client could not make sense of.
    case protocolError(String)
}

/// What the client reports. Every handler runs on the client's own thread, one at a time, and
/// should return promptly: nothing else is read from the server while one runs.
public struct VNCHandlers: Sendable {
    /// Supplies a credential, or `nil` to give up. May block while a person is asked.
    public var credential: @Sendable (VNCCredentialKind) -> VNCCredential? = { _ in nil }
    /// The desktop changed size. The next update repaints all of it.
    public var resized: @Sendable (_ width: Int, _ height: Int) -> Void = { _, _ in }
    /// A framebuffer update finished; `changed` lists what it touched, or all of the desktop when
    /// the update is the first into a new framebuffer, which starts black. Copy what is needed
    /// before returning.
    public var updated: @Sendable (_ framebuffer: VNCFramebuffer, _ changed: [VNCRect]) -> Void = { _, _ in }
    public var cursor: @Sendable (VNCCursor) -> Void = { _ in }
    public var bell: @Sendable () -> Void = {}
    public var clipboard: @Sendable (String) -> Void = { _ in }
    /// The session is over. Called exactly once after a successful connect.
    public var disconnected: @Sendable (VNCDisconnectReason) -> Void = { _ in }

    public init() {}
}

/// The client's framebuffer, valid only for the duration of the handler call it is passed to.
/// Pixels are four bytes each, B, G, R, X, rows packed with no padding.
public struct VNCFramebuffer: @unchecked Sendable {
    public let pixels: UnsafeRawBufferPointer
    public let width: Int
    public let height: Int
    /// Handed over again by ``VNCClient/republish()``, rather than just changed by the server.
    public var isRepublished = false
    public var bytesPerRow: Int { width * 4 }
}

public struct VNCCursor: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var hotspotX: Int
    public var hotspotY: Int
    /// Premultiplied B, G, R, A.
    public var pixels: Data
}

/// A VNC viewer session, on LibVNCClient.
///
/// LibVNCClient does its own blocking socket I/O and is not thread-safe, so each client gets a
/// thread that makes every library call, and a local socket pair: the library talks to one end, and
/// this class moves bytes between the other end and the transport. That is what lets a session run
/// over anything — a TCP connection or a tunnel.
public final class VNCClient: @unchecked Sendable {
    // @unchecked: `lock` guards the command queue and the lifecycle and transport flags; everything
    // marked "client thread" is touched only there.
    private enum Command {
        case key(UInt32, Bool)
        case pointer(Int, Int, Int)
        case clipboard(String)
        case fullUpdate
        case republish
        case quality(VNCQuality)
        case stop

        /// Input goes out as soon as the client thread can write, even in the middle of an update.
        var isInput: Bool {
            switch self {
            case .key, .pointer: true
            case .clipboard, .fullUpdate, .republish, .quality, .stop: false
            }
        }
    }

    private let transport: any VNCTransport
    private let configuration: VNCConfiguration
    private let handlers: VNCHandlers

    private let lock = NSLock()
    private var commands: [Command] = []
    private var hasStarted = false
    private var wakeWriter: Int32 = -1
    /// Why the transport stopped, as the bridge saw it.
    private var transportFailure: String?
    private var serverClosed = false
    /// Bytes handed to the library from the server so far, for the throughput estimate.
    private let receivedBytes = Atomic<Int>(0)
    /// How many times the app has been about to be suspended (see ``willSuspend()``).
    private let suspensions = Atomic<Int>(0)

    // Client thread only.
    private var handle: OpaquePointer?
    private var framebuffer: UnsafeMutableRawBufferPointer?
    private var framebufferSize = (width: 0, height: 0)
    private var changed: [VNCRect] = []
    /// The framebuffer is a new one, black wherever no update has drawn yet.
    private var isFramebufferNew = false
    private var quality: VNCQuality
    private var throughput: VNCThroughputEstimate
    /// What the server was last asked for.
    private var settings: VNCAdaptiveSettings
    /// When the update under way began, how far the library had read by then, how many bytes had
    /// arrived, and the count of suspensions.
    private var updateStart: (time: ContinuousClock.Instant, bytes: Int, arrived: Int, suspensions: Int)?

    public init(transport: any VNCTransport, configuration: VNCConfiguration = VNCConfiguration(), handlers: VNCHandlers) {
        self.transport = transport
        self.configuration = configuration
        self.handlers = handlers
        quality = configuration.quality
        throughput = VNCThroughputEstimate(bitsPerSecond: configuration.initialBitsPerSecond)
        settings = Self.settings(for: configuration.quality, throughput: throughput)
    }

    // MARK: Connecting

    /// Runs the handshake and authentication. Returns once the server has described its desktop;
    /// updates start arriving through the handlers straight away.
    public func connect() async throws -> VNCServerInfo {
        let alreadyStarted: Bool = lock.withLock {
            defer { hasStarted = true }
            return hasStarted
        }
        guard !alreadyStarted else { throw VNCError.alreadyStarted }

        var sockets: [Int32] = [0, 0]
        var wake: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0, pipe(&wake) == 0 else {
            throw VNCError.connectionFailed(String(localized: "could not create local sockets: \(String(cString: strerror(errno)))", bundle: #bundle))
        }
        let (librarySocket, bridgeSocket) = (sockets[0], sockets[1])
        var one: Int32 = 1
        setsockopt(bridgeSocket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let (wakeReader, wakeWriterEnd) = (wake[0], wake[1])
        // A write after the reader is gone fails rather than raising SIGPIPE, which would end the
        // process; and one into a full pipe returns at once, as a byte waiting already wakes the loop.
        _ = fcntl(wakeWriterEnd, F_SETNOSIGPIPE, 1)
        _ = fcntl(wakeWriterEnd, F_SETFL, fcntl(wakeWriterEnd, F_GETFL) | O_NONBLOCK)
        lock.withLock { wakeWriter = wakeWriterEnd }
        startBridge(bridgeSocket)

        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { [self] in
                run(librarySocket: librarySocket, wakeReader: wakeReader, connected: continuation)
            }
            thread.name = "llc.turing.SwiftVNCClient"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    /// Records why the transport stopped; the first reason wins.
    private func transportEnded(failure: (any Error)?) {
        lock.withLock {
            if let failure {
                if transportFailure == nil, !serverClosed { transportFailure = String(describing: failure) }
            } else if transportFailure == nil {
                serverClosed = true
            }
        }
    }

    /// Moves bytes between the transport and the bridge end of the socket pair.
    ///
    /// The two directions end at different times, and the bridge is closed only once both have:
    /// a descriptor number used after its close may already belong to another session's socket.
    private func startBridge(_ bridge: Int32) {
        let transport = transport
        let directionsRunning = Mutex(2)
        @Sendable func directionEnded() {
            let remaining = directionsRunning.withLock {
                $0 -= 1
                return $0
            }
            if remaining == 0 { Darwin.close(bridge) }
        }
        let writeQueue = DispatchQueue(label: "llc.turing.SwiftVNCClient.bridge.in")
        Task {
            while true {
                let data: Data?
                do {
                    data = try await transport.read(upTo: 1 << 16)
                } catch {
                    transportEnded(failure: error)
                    break
                }
                guard let data else {
                    transportEnded(failure: nil)
                    break
                }
                let delivered: Bool = await withCheckedContinuation { continuation in
                    writeQueue.async {
                        var offset = 0
                        while offset < data.count {
                            // In slices, so that the count lags what is in the socket by at most one
                            // (see `consumedBytes`).
                            let slice = min(data.count - offset, Self.bridgeSlice)
                            let sent = data.withUnsafeBytes { Darwin.send(bridge, $0.baseAddress! + offset, slice, 0) }
                            if sent <= 0 {
                                if sent < 0, errno == EINTR { continue }
                                continuation.resume(returning: false)
                                return
                            }
                            offset += sent
                            self.receivedBytes.add(sent, ordering: .relaxed)
                        }
                        continuation.resume(returning: true)
                    }
                }
                if !delivered { break }
            }
            // No more from the server: the library sees end of stream.
            shutdown(bridge, SHUT_WR)
            directionEnded()
        }
        // Library → transport. Reads block on a thread of their own; writes go out in order.
        let (outgoing, continuation) = AsyncStream.makeStream(of: Data.self)
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let count = recv(bridge, &buffer, buffer.count, 0)
                if count > 0 {
                    continuation.yield(Data(buffer[0..<count]))
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            continuation.finish()
        }
        reader.name = "llc.turing.SwiftVNCClient.bridge.out"
        reader.start()
        Task {
            for await data in outgoing {
                do {
                    try await transport.write(data)
                } catch {
                    transportEnded(failure: error)
                    break
                }
            }
            // The library closed its end (or the transport failed): everything is over. Closing the
            // transport also ends the other direction's read.
            await transport.close()
            directionEnded()
        }
    }

    // MARK: Client thread

    private func run(librarySocket: Int32, wakeReader: Int32, connected: CheckedContinuation<VNCServerInfo, any Error>) {
        var callbacks = marionette_vnc_callbacks()
        callbacks.context = Unmanaged.passUnretained(self).toOpaque()
        callbacks.resize = { context, width, height in
            VNCClient.from(context).resize(width: Int(width), height: Int(height))
        }
        callbacks.started = { context in
            let client = VNCClient.from(context)
            client.updateStart = (
                ContinuousClock.now, client.consumedBytes(), client.receivedBytes.load(ordering: .relaxed),
                client.suspensions.load(ordering: .relaxed)
            )
        }
        callbacks.update = { context, x, y, width, height in
            let client = VNCClient.from(context)
            client.changed.append(VNCRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height)))
            // A large update over a slow link takes a while; input should not wait for all of it.
            client.sendQueuedInput()
        }
        callbacks.finished = { context in VNCClient.from(context).finishUpdate() }
        callbacks.password = { context in
            VNCClient.from(context).handlers.credential(.password).flatMap { strdup($0.password) }
        }
        callbacks.credential = { context, username, password in
            guard let credential = VNCClient.from(context).handlers.credential(.usernameAndPassword) else { return 0 }
            username?.pointee = strdup(credential.username)
            password?.pointee = strdup(credential.password)
            return 1
        }
        callbacks.cursor = { context, hotspotX, hotspotY, width, height, pixels, mask in
            guard let pixels, let mask, width > 0, height > 0 else { return }
            let count = Int(width) * Int(height)
            var premultiplied = Data(count: count * 4)
            premultiplied.withUnsafeMutableBytes { output in
                for index in 0..<count where mask[index] != 0 {
                    output[index * 4] = pixels[index * 4]
                    output[index * 4 + 1] = pixels[index * 4 + 1]
                    output[index * 4 + 2] = pixels[index * 4 + 2]
                    output[index * 4 + 3] = 255
                }
            }
            VNCClient.from(context).handlers.cursor(VNCCursor(
                width: Int(width), height: Int(height), hotspotX: Int(hotspotX), hotspotY: Int(hotspotY), pixels: premultiplied
            ))
        }
        callbacks.bell = { context in VNCClient.from(context).handlers.bell() }
        callbacks.clipboard = { context, text, length, isUTF8 in
            guard let text, length > 0 else { return }
            let string = VNCClient.clipboardText(UnsafeRawBufferPointer(start: text, count: Int(length)), isUTF8: isUTF8 != 0)
            guard !string.isEmpty else { return }
            VNCClient.from(context).handlers.clipboard(string)
        }

        func closeDescriptors() {
            Darwin.close(librarySocket)
            // The writer first, under the lock commands are written under: once it is closed no
            // command can write to it, nor to a descriptor that has since taken its number.
            lock.withLock {
                if wakeWriter >= 0 { Darwin.close(wakeWriter) }
                wakeWriter = -1
            }
            Darwin.close(wakeReader)
        }

        guard let client = marionette_vnc_create(&callbacks) else {
            closeDescriptors()
            connected.resume(throwing: VNCError.connectionFailed(String(localized: "LibVNCClient could not create a client", bundle: #bundle)))
            return
        }
        marionette_vnc_set_encodings(client, configuration.encodings, Int32(configuration.compressionLevel), Int32(settings.jpegQuality ?? -1))
        _ = marionette_vnc_set_full_colour(client, settings.isFullColour ? 1 : 0, 0)
        guard marionette_vnc_connect(client, librarySocket, configuration.sharesDesktop ? 1 : 0) != 0 else {
            // The library destroyed the client on its way out.
            releaseFramebuffer()
            closeDescriptors()
            connected.resume(throwing: handshakeFailure())
            return
        }
        handle = client
        var major: Int32 = 0
        var minor: Int32 = 0
        marionette_vnc_server_version(&major, &minor)
        let info = VNCServerInfo(
            name: String(cString: marionette_vnc_desktop_name(client)),
            width: Int(marionette_vnc_width(client)), height: Int(marionette_vnc_height(client)),
            majorVersion: Int(major), minorVersion: Int(minor)
        )
        // A Mac's server takes only 16 or 32 bits a pixel, and ends the session when asked for 8
        // ("Only 16 or 32 bit pixels supported", macOS 27).
        if info.isAppleScreenSharing { marionette_vnc_keep_full_colour(client) }
        // So does a server older than RFB 3.8, whatever was asked.
        if marionette_vnc_can_change_colour(client) == 0 { settings.isFullColour = true }
        connected.resume(returning: info)

        var requested = false
        loop: while true {
            let ready = marionette_vnc_wait(client, wakeReader, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready & 2 != 0 {
                var scratch = [UInt8](repeating: 0, count: 64)
                _ = read(wakeReader, &scratch, scratch.count)
                let pending: [Command] = lock.withLock {
                    defer { commands.removeAll(keepingCapacity: true) }
                    return commands
                }
                for command in pending {
                    if case .stop = command {
                        requested = true
                        break loop
                    }
                    perform(command, on: client)
                }
            }
            if ready & 1 != 0, marionette_vnc_process(client) == 0 {
                break
            }
        }
        let reason = requested ? .requested : endReason()
        handle = nil
        marionette_vnc_destroy(client)
        releaseFramebuffer()
        // Closing the library's end ends the bridge, which closes the transport.
        closeDescriptors()
        handlers.disconnected(reason)
    }

    private func perform(_ command: Command, on client: OpaquePointer) {
        switch command {
        case .key(let keysym, let isDown):
            _ = marionette_vnc_send_key(client, keysym, isDown ? 1 : 0)
        case .pointer(let x, let y, let mask):
            _ = marionette_vnc_send_pointer(client, Int32(x), Int32(y), Int32(mask))
        case .clipboard(let text):
            let utf8 = Array(text.utf8)
            // Classic cut text is Latin-1; what does not fit becomes a question mark.
            let latin1 = text.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }
            utf8.withUnsafeBytes { utf8Bytes in
                latin1.withUnsafeBytes { latin1Bytes in
                    _ = marionette_vnc_send_clipboard(
                        client,
                        utf8Bytes.bindMemory(to: CChar.self).baseAddress, Int32(utf8.count),
                        latin1Bytes.bindMemory(to: CChar.self).baseAddress, Int32(latin1.count)
                    )
                }
            }
        case .fullUpdate:
            _ = marionette_vnc_request_update(client, 0, 0, marionette_vnc_width(client), marionette_vnc_height(client), 0)
        case .republish:
            guard let framebuffer, framebufferSize != (0, 0), announcedSize == framebufferSize else { return }
            handlers.updated(
                VNCFramebuffer(pixels: UnsafeRawBufferPointer(framebuffer), width: framebufferSize.width, height: framebufferSize.height, isRepublished: true),
                [VNCRect(x: 0, y: 0, width: framebufferSize.width, height: framebufferSize.height)]
            )
        case .quality(let quality):
            self.quality = quality
            applySettings(on: client)
        case .stop:
            break
        }
    }

    private static func settings(for quality: VNCQuality, throughput: VNCThroughputEstimate, isFullColour: Bool = true) -> VNCAdaptiveSettings {
        switch quality {
        case .automatic: .automatic(bitsPerSecond: throughput.bitsPerSecond, isFullColour: isFullColour)
        case .lossless: .lossless
        }
    }

    /// Asks the server for what the quality and the throughput now call for, if it differs.
    private func applySettings(on client: OpaquePointer) {
        var wanted = Self.settings(for: quality, throughput: throughput, isFullColour: settings.isFullColour)
        // Lossless asks for exact pixels, so what came in 256 colours comes again; following the
        // link does not, or every rise past the threshold would cost a whole desktop.
        if wanted.isFullColour != settings.isFullColour,
           marionette_vnc_set_full_colour(client, wanted.isFullColour ? 1 : 0, quality == .lossless ? 1 : 0) == 0 {
            wanted.isFullColour = settings.isFullColour
        }
        guard wanted != settings else { return }
        qualityLog.info("\(self.throughput.bitsPerSecond / 1000) kbit/s: JPEG quality \(wanted.jpegQuality.map(String.init) ?? "none", privacy: .public), \(wanted.isFullColour ? "full colour" : "256 colours", privacy: .public)")
        if wanted.jpegQuality != settings.jpegQuality {
            _ = marionette_vnc_set_quality(client, Int32(wanted.jpegQuality ?? -1))
        }
        settings = wanted
    }

    /// Size of the pieces the bridge hands to the library's socket.
    private static let bridgeSlice = 4096

    /// How far into the server's stream the library has read. Bytes arrive ahead of being read, in
    /// the socket and in LibVNCClient's buffer; a small update often lies there whole before its
    /// header is read, and counting arrivals would make it look empty. A slice the bridge is handing
    /// over at the time can put the position out by at most that slice.
    private func consumedBytes() -> Int {
        guard let handle else { return receivedBytes.load(ordering: .relaxed) }
        let unread = Int(marionette_vnc_unread_bytes(handle))
        return receivedBytes.load(ordering: .relaxed) - unread
    }

    /// Folds the update that just ended into the throughput estimate.
    private func measureUpdate() {
        guard let start = updateStart else { return }
        updateStart = nil
        // An update that was here whole before its header was read crossed the network earlier,
        // while the client was busy with another; its time says nothing about the link. Counted, a
        // run of them takes a few milliseconds and lifts the estimate by about 8 bit/s per byte:
        // on a 200 kbit/s link, from about 250 to over 320 kbit/s in a second.
        guard receivedBytes.load(ordering: .relaxed) != start.arrived else { return }
        // Time the app spent suspended is not time the link took.
        guard suspensions.load(ordering: .relaxed) == start.suspensions else { return }
        throughput.add(bytes: consumedBytes() - start.bytes, elapsed: ContinuousClock.now - start.time)
    }

    /// Sends the input at the front of the queue, from inside an update. Other commands wait for
    /// the update to finish, and so does input queued behind them, so the order holds.
    private func sendQueuedInput() {
        guard let handle else { return }
        let input: [Command] = lock.withLock {
            let count = commands.prefix { $0.isInput }.count
            defer { commands.removeFirst(count) }
            return Array(commands.prefix(count))
        }
        for command in input { perform(command, on: handle) }
    }

    private func handshakeFailure() -> VNCError {
        var reasonText: UnsafePointer<CChar>?
        let kind = marionette_vnc_last_failure(&reasonText)
        let reason = reasonText.map { String(cString: $0) } ?? ""
        let error = String(cString: marionette_vnc_last_error())
        switch kind {
        case MARIONETTE_VNC_FAILURE_REFUSED:
            return .refused(reason: reason)
        case MARIONETTE_VNC_FAILURE_REJECTED:
            return .authenticationRejected(reason: reason.isEmpty ? nil : reason)
        case MARIONETTE_VNC_FAILURE_TOO_MANY_ATTEMPTS:
            return .tooManyAttempts(reason: reason.isEmpty ? nil : reason)
        case MARIONETTE_VNC_FAILURE_UNSUPPORTED_AUTHENTICATION:
            return .unsupportedAuthentication(error)
        default:
            if let failure = lock.withLock({ transportFailure }) { return .transportFailed(failure) }
            return .connectionFailed(error.isEmpty ? String(localized: "the server ended the handshake", bundle: #bundle) : error)
        }
    }

    private func endReason() -> VNCDisconnectReason {
        let (failure, closed) = lock.withLock { (transportFailure, serverClosed) }
        if let failure { return .connectionLost(failure) }
        if closed { return .connectionClosed }
        // The connection is still up, so the library gave up on what the server sent.
        let error = String(cString: marionette_vnc_last_error())
        return .protocolError(error.isEmpty ? String(localized: "the server sent something the client could not read", bundle: #bundle) : error)
    }

    /// Clipboard text as a server sent it.
    ///
    /// The extended clipboard is UTF-8; classic cut text should be Latin-1, but many servers send
    /// UTF-8 anyway, so it is read as UTF-8 when it is valid UTF-8. Line ends become line feeds
    /// (the extended clipboard and Windows servers use CR LF), and the NUL that ends extended
    /// clipboard text is dropped.
    static func clipboardText(_ bytes: UnsafeRawBufferPointer, isUTF8: Bool) -> String {
        var end = bytes.count
        while end > 0, bytes[end - 1] == 0 { end -= 1 }
        let content = UnsafeRawBufferPointer(rebasing: bytes[0..<end])
        let text = isUTF8
            ? String(decoding: content, as: UTF8.self)
            : String(validating: content, as: UTF8.self) ?? String(content.map { Character(UnicodeScalar($0)) })
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func from(_ context: UnsafeMutableRawPointer?) -> VNCClient {
        Unmanaged<VNCClient>.fromOpaque(context!).takeUnretainedValue()
    }

    /// Largest desktop accepted, in pixels a side and in all. Guards the allocation against a
    /// hostile size: 64 M pixels is 256 MB, which a phone can still hold, and three 6K displays side
    /// by side fit in it.
    static let maximumDimension = 32_768
    static let maximumPixels = 1 << 26

    /// Allocates the framebuffer for a new desktop size and hands it to the library.
    ///
    /// Some servers have nothing to show at first and say 0 × 0 (KDE's KRFB until its screen
    /// capture starts), then send their real size as a desktop resize. Such a desktop gets storage
    /// for one pixel, which nothing is drawn into, and is not announced.
    private func resize(width: Int, height: Int) -> UnsafeMutablePointer<UInt8>? {
        guard width >= 0, height >= 0, width <= Self.maximumDimension, height <= Self.maximumDimension,
              width * height <= Self.maximumPixels
        else { return nil }
        releaseFramebuffer()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(width * height, 1) * 4, alignment: 64)
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        framebuffer = buffer
        framebufferSize = width > 0 && height > 0 ? (width, height) : (0, 0)
        changed.removeAll()
        isFramebufferNew = true
        return buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
    }

    private func releaseFramebuffer() {
        framebuffer?.deallocate()
        framebuffer = nil
        framebufferSize = (0, 0)
    }

    private var announcedSize = (width: 0, height: 0)

    private func finishUpdate() {
        measureUpdate()
        if let handle { applySettings(on: handle) }
        guard let framebuffer, framebufferSize != (0, 0) else { return }
        if announcedSize != framebufferSize {
            announcedSize = framebufferSize
            handlers.resized(framebufferSize.width, framebufferSize.height)
        }
        guard !changed.isEmpty else { return }
        defer { changed.removeAll(keepingCapacity: true) }
        if isFramebufferNew {
            isFramebufferNew = false
            changed = [VNCRect(x: 0, y: 0, width: framebufferSize.width, height: framebufferSize.height)]
        }
        handlers.updated(
            VNCFramebuffer(pixels: UnsafeRawBufferPointer(framebuffer), width: framebufferSize.width, height: framebufferSize.height),
            changed
        )
    }

    // MARK: Commands (any thread)

    private func enqueue(_ command: Command) {
        lock.withLock {
            guard wakeWriter >= 0 else { return }
            // A move that has not gone out yet is replaced by the next one with the same buttons:
            // only the latest position matters, and a burst of moves must not hold up a click.
            if case .pointer(_, _, let mask) = command, case .pointer(_, _, let queuedMask) = commands.last, mask == queuedMask {
                commands[commands.count - 1] = command
            } else {
                commands.append(command)
            }
            // Under the lock, so that the session ending cannot close the pipe in between.
            var byte: UInt8 = 1
            _ = write(wakeWriter, &byte, 1)
        }
    }

    public func sendKey(keysym: UInt32, isDown: Bool) {
        enqueue(.key(keysym, isDown))
    }

    /// `buttonMask` is RFB's: bit 0 left, bit 1 middle, bit 2 right, bits 3–6 the wheel.
    public func sendPointer(x: Int, y: Int, buttonMask: Int) {
        enqueue(.pointer(x, y, buttonMask))
    }

    public func sendClipboard(_ text: String) {
        enqueue(.clipboard(text))
    }

    /// Asks the server to send the whole desktop again, at once, whether or not it has changed.
    /// The colour depth then stays as it is for the rest of the session: the server may answer
    /// with one update or two, and an update in flight across a change of depth would be misread.
    public func requestFullUpdate() {
        enqueue(.fullUpdate)
    }

    /// Hands the desktop as the client has it to `updated` again, all of it, without asking the
    /// server.
    public func republish() {
        enqueue(.republish)
    }

    /// The app is about to be suspended: the update under way, if any, does not count towards the
    /// throughput estimate, since it will seem to take as long as the app is away. Any thread.
    public func willSuspend() {
        suspensions.add(1, ordering: .relaxed)
    }

    /// Changes how faithfully the server is asked to send the desktop. JPEG quality changes at once;
    /// a colour depth change waits for the end of the next update.
    public func setQuality(_ quality: VNCQuality) {
        enqueue(.quality(quality))
    }

    /// Ends the session. The `disconnected` handler follows.
    public func disconnect() {
        enqueue(.stop)
    }
}
