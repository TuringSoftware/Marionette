// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

@testable import ARDCrypto
import ARDProtocol
import BigInt
import CoreMedia
import CoreVideo
import Foundation
import RemoteDesktopCore
import SwiftSRTP
import Synchronization
import VideoToolbox
import zlib

/// One direction of an in-memory byte pipe.
actor PipeHalf {
    private var buffer = Data()
    private var isClosed = false
    private var waiter: CheckedContinuation<Void, Never>?
    /// While set, writes wait, as on a path whose window is shut.
    private var isStalled = false
    private var stalledWriters: [CheckedContinuation<Void, Never>] = []

    func setStalled(_ stalled: Bool) {
        isStalled = stalled
        if !stalled {
            for writer in stalledWriters { writer.resume() }
            stalledWriters.removeAll()
        }
    }

    func append(_ data: Data) async {
        while isStalled, !isClosed { await withCheckedContinuation { stalledWriters.append($0) } }
        guard !isClosed else { return }
        buffer.append(data)
        waiter?.resume()
        waiter = nil
    }

    func close() {
        isClosed = true
        waiter?.resume()
        waiter = nil
        for writer in stalledWriters { writer.resume() }
        stalledWriters.removeAll()
    }

    var availableCount: Int { buffer.count }

    var firstAvailableByte: UInt8? { buffer.first }

    func takeAvailable() -> Data {
        defer { buffer.removeAll() }
        return buffer
    }

    func read(upTo maxLength: Int) async -> Data? {
        while buffer.isEmpty {
            if isClosed { return nil }
            await withCheckedContinuation { waiter = $0 }
        }
        let chunk = buffer.prefix(maxLength)
        buffer.removeFirst(chunk.count)
        return Data(chunk)
    }
}

/// One end of an in-memory connection. `chunkLimit` caps how much a read returns, to show the
/// reader every way a stream can be split.
final class PipeStream: ByteStream {
    private let incoming: PipeHalf
    private let outgoing: PipeHalf
    private let chunkLimit: Int

    init(incoming: PipeHalf, outgoing: PipeHalf, chunkLimit: Int = .max) {
        self.incoming = incoming
        self.outgoing = outgoing
        self.chunkLimit = chunkLimit
    }

    static func pair(clientChunkLimit: Int = .max) -> (client: PipeStream, server: PipeStream) {
        let (a, b) = (PipeHalf(), PipeHalf())
        return (PipeStream(incoming: a, outgoing: b, chunkLimit: clientChunkLimit), PipeStream(incoming: b, outgoing: a))
    }

    func read(upTo maxLength: Int) async throws -> Data? {
        await incoming.read(upTo: max(1, min(maxLength, chunkLimit)))
    }

    func write(_ data: Data) async throws {
        await outgoing.append(data)
    }

    func readAvailable() async -> Data {
        await incoming.takeAvailable()
    }

    func availableCount() async -> Int {
        await incoming.availableCount
    }

    /// The next byte to be read, if it has arrived, without reading it.
    func peekFirstByte() async -> UInt8? {
        await incoming.firstAvailableByte
    }

    func close() async {
        await outgoing.close()
        await incoming.close()
    }

    func stallIncoming(_ stalled: Bool) async {
        await incoming.setStalled(stalled)
    }

    func readExactly(_ count: Int) async throws -> Data {
        var collected = Data()
        while collected.count < count {
            guard let chunk = try await read(upTo: count - collected.count) else { throw ScriptedMac.Failure.viewerHungUp }
            collected.append(chunk)
        }
        return collected
    }
}

/// A deflate stream kept open across rectangles and flushed at the end of each, as a Mac's is.
final class DeflateStream {
    private var stream = z_stream()

    init(level: Int32 = 6) {
        deflateInit_(&stream, level, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    deinit {
        deflateEnd(&stream)
    }

    func chunk(_ data: Data) -> Data {
        var output = Data()
        var input = [UInt8](data)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = UInt32(source.count)
            repeat {
                buffer.withUnsafeMutableBufferPointer { destination in
                    stream.next_out = destination.baseAddress
                    stream.avail_out = UInt32(destination.count)
                    deflate(&stream, Z_SYNC_FLUSH)
                    output.append(destination.baseAddress!, count: destination.count - Int(stream.avail_out))
                }
            } while stream.avail_out == 0
        }
        return output
    }
}

/// The server's end of Apple's protocol, enough of it to carry a Standard-mode session: the
/// version exchange, the Diffie-Hellman login, the extended initialisation, the switch to
/// encrypted records, a display layout, and the picture as zlib or as Adaptive tiles.
///
/// Written from the protocol notes, not from the client (though it shares the client's crypto
/// primitives). The live suite proves the client against a real Mac; this covers what a real Mac
/// cannot be made to do on demand: refusals, wrong passwords, hang-ups, streams cut at every byte.
final class ScriptedMac: Sendable {
    enum Failure: Error {
        case viewerHungUp
        case unexpected(String)
    }

    struct Options: Sendable {
        var username = "tester"
        var password = "s3cret"
        var name = "Scripted Mac"
        var width = 64
        var height = 48
        /// What the Mac says first. A viewer must see `RFB 003.889` to speak Apple's dialect.
        var version = "RFB 003.889\n"
        /// A real Mac also offers 36 (SRP). Left out by default: SRP's 4096-bit arithmetic takes
        /// seconds in an unoptimised build, and most tests are about what comes after the login.
        var securityTypes: [UInt8] = [30, 33, 35]
        /// SRP only: screensharingd on macOS 15.6, which never recovers from misreading message 1:
        /// the login goes no further and the Mac records it (``Record/misreadFirstMessage``).
        var loopsOnAMisreadFirstMessage = false
        /// A Mac whose ServerInit had "set encryption" (0x12) taken out of its message list on the
        /// way, by something between it and the viewer.
        var stripsSetEncryption = false
        /// SRP only: answer a correct proof with a wrong one, as something posing as the Mac would.
        var forgesSRPProof = false
        /// SRP only: the options the Mac insists on, as screensharingd does.
        var requiredSRPOptions = ["replay_detection", "kdf=SALTED-SHA512-PBKDF2"]
        /// Set to refuse every viewer before the login, with this reason.
        var refusal: String?
        /// Answers ClientInit with a plain RFB name instead of Apple's extended initialisation.
        var answersInPlainForm = false
        /// Serves as wayshare does on Linux: SRP over RFC 5054's 2048-bit group, message 1 without
        /// the type byte again, a flags word that is only the display count, and a bitmap with
        /// `SetEncryption` only when `wayshareEncrypts`. Offer `[36]` with it.
        var isWayshare = false
        /// wayshare only: offer the record layer, as `--stream-encryption` does. It sends the keys
        /// once the viewer asks, and drops a viewer whose switch to records comes before them.
        var wayshareEncrypts = true
        /// Someone else is at the console: a viewer that asks gets a session-select offer.
        var consoleUser: String?
        /// The console user's answers to successive requests to share; true lets the viewer in.
        /// Once they run out, requests go unanswered, as a Mac leaves them.
        var consoleAnswers: [Bool] = [true]
        /// What the session-select offer lets the viewer do.
        var sessionSelectCommands: [SessionSelectCommand] = [.askConsoleUser, .logInAsSelf]
        /// Send a display layout (`0x451`). Older servers send none, only pixels.
        var sendsLayout = true
        /// Standard mode's layout flags. With `.curtain` (Remote Management on) the Mac acts on
        /// curtain requests as a real Mac does: curtained, the session leaves the console
        /// (`.onVirtualDisplay`, `.curtain`); lowered, it returns to a locked console.
        var standardLayoutFlags: DisplayLayout.Flags = [.onConsole]
        /// How often the Mac sends its heartbeat (status 4); a Mac sends one about every 2.1 s.
        /// `nil` for one that has gone quiet.
        var heartbeatInterval: Duration? = .seconds(2)
        var highPerformance = HighPerformanceScript()
        /// Name `EncryptedInputEvent` (`0x10`) among the messages the Mac takes, as a Mac does. A
        /// viewer then seals every key and pointer event under the record layer's key.
        var takesEncryptedInput = true
        /// Refuse control in the initialisation's flags: the viewer may only watch.
        var isObserveOnly = false
        /// Name ``ClientMessageType/hidReport`` among the messages the Mac takes, as macOS 27.3 does:
        /// a viewer may then send touches.
        var takesTouches = false
        /// The folder under a viewer's drag when it is let go, which the Mac then names. `nil` for
        /// something that takes no files (an app's window, the Dock): the Mac says nothing at all.
        var dropFolder: String? = "/Users/tester/Desktop"
    }

    /// What a Mac does with virtual displays and media offers. The defaults are what a Mac on
    /// macOS 27 does (see the protocol notes): a layout, then its ports, for every display
    /// configuration; an answer for every offer; pictures once the stream runs.
    struct HighPerformanceScript: Sendable {
        /// How long the Mac takes to make the displays of a configuration (about two seconds on
        /// a real Mac; short here so tests are quick).
        var layoutDelay: Duration = .milliseconds(20)
        var portsBeforeLayout = false
        /// Port messages repeated after the first, as a Mac does while it waits.
        var repeatedPortMessages = 0
        var namesOneVideoPort = false
        /// The ports named: sound, then the two picture legs.
        var ports: [UInt16] = [5900, 5901, 5902]
        /// Display configurations, counted from 0 (the opening one), that the Mac never answers.
        var unansweredConfigurations: Set<Int> = []
        /// Offers, counted from 0, that the Mac refuses with a failure of this kind and sub-code.
        var refusedOffers: [Int: (kind: UInt32, subCode: UInt32)] = [:]
        /// The layout's flags. Without `.onVirtualDisplay` the displays are not the session's.
        var layoutFlags: DisplayLayout.Flags = [.onVirtualDisplay, .onConsole]
        /// Configurations from this one on (counted from 0) are laid out without
        /// `.onVirtualDisplay`, as at the Login Window after a logout.
        var physicalFromConfiguration = Int.max
        /// Send pictures and reports once a stream of the session's own displays runs.
        var sendsMedia = true
        /// Picture legs, by index, that never send anything.
        var silentLegs: Set<Int> = []
        /// Extra bytes appended to every answer, as a later macOS might add a field.
        var answerTrailer = Data()
        /// Send a keyframe on every leg this often while a stream runs, as a moving screen would.
        var pictureInterval: Duration?
        /// The most bytes of picture in one packet; small ones make many packets of a picture.
        var packetPayload = 1100
    }

    enum Received: Sendable, Equatable {
        case setPixelFormat
        case encodings([Int32])
        case updateRequest(incremental: Bool, x: Int, y: Int, width: Int, height: Int)
        case key(keysym: UInt32, isDown: Bool)
        case pointer(mask: UInt8, x: Int, y: Int)
        case mode(UInt16)
        case autoUpdate(interval: UInt32, width: Int, height: Int)
        case autoPasteboard
        case setDisplay(UInt32?)
        case encryption(command: UInt16)
        case framed(type: UInt8, length: Int)
        case pasteboardFetch(token: UInt32)
        /// An event message (scroll, gesture): its kind and the whole message as sent.
        case event(kind: UInt16, message: Data)
        /// The requested mode of each virtual display, and whether they may be resized live.
        case displayConfiguration([VirtualDisplayMode], dynamic: Bool)
        case mediaOffer(videoKeys: [MediaLegKeys])
        case curtain(curtained: Bool, note: String)
        /// A drag entering the picture, by the names of the files it carries. No names: the drag is over.
        case drag(token: UInt32, names: [String])
        /// A request for what the drag held on the Mac carries (`0x0e`).
        case dragRequest(token: UInt32)
        /// A touch screen report for the display with the Mac's id `display`.
        case touch(display: UInt32, report: DigitizerReport)
    }

    /// A key or pointer event that came as an `EncryptedInputEvent`, with what the plain form
    /// does not carry.
    struct SealedInput: Sendable, Equatable {
        var event: Received
        var flags: UInt8
        /// The block as decrypted with the record layer's key.
        var block: Data

        /// The microseconds since the viewer's event before this one (bytes 6–9 of either block).
        var elapsedMicroseconds: UInt32 {
            block.dropFirst(6).prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
        }
    }

    struct Record: Sendable {
        var logins: [(username: String, password: String)] = []
        var srpLogins: [(username: String, proofAccepted: Bool)] = []
        /// SRP's first message was misread: it came with the login type yet began with the type
        /// again (``Options/loopsOnAMisreadFirstMessage``).
        var misreadFirstMessage = false
        /// The session-select answers, with the name and password of a request to log in.
        var sessionSelectAnswers: [SessionSelectAnswer] = []
        var sessionLogins: [(username: String, password: String)] = []
        /// VNC-password logins, and whether the response was right.
        var vncPasswordLogins: [Bool] = []
        var prelude: [Received] = []
        /// Everything the viewer sent in the session. A key or pointer event is listed the same
        /// whether it came plain or sealed; the sealed ones are in `sealedInput` as well.
        var messages: [Received] = []
        var sealedInput: [SealedInput] = []
        /// The tokens of the viewer's drags whose drop the Mac named a folder for.
        var namedDrops: [UInt32] = []
        var isEncrypted = false
        /// The viewer closed the connection after the session began.
        var viewerClosed = false
    }

    let options: Options
    let record = Mutex(Record())
    private let stream: PipeStream
    private let outbox: AsyncStream<Data>
    private let outboxContinuation: AsyncStream<Data>.Continuation
    private let pixels: Mutex<[UInt8]>
    let media = Mutex(MediaState())
    /// The Mac's side of a drag out: whether the viewer's latest pointer event marks it as the
    /// owner of a drag that starts now, and whether a drag it was told of is still under way.
    private let ownDrag = Mutex((viewerHoldsLeftButton: false, isUnderWay: false))
    /// The Mac's High Performance work, done one step at a time in order.
    private let jobs: AsyncStream<@Sendable () async -> Void>
    private let jobsContinuation: AsyncStream<@Sendable () async -> Void>.Continuation

    init(stream: PipeStream, options: Options = Options()) {
        self.stream = stream
        self.options = options
        (outbox, outboxContinuation) = AsyncStream.makeStream(of: Data.self)
        (jobs, jobsContinuation) = AsyncStream.makeStream(of: (@Sendable () async -> Void).self)
        var picture = [UInt8](repeating: 0, count: options.width * options.height * 4)
        for y in 0..<options.height {
            for x in 0..<options.width {
                picture.replaceSubrange(((y * options.width + x) * 4)..<((y * options.width + x) * 4 + 4), with: Self.pixel(x: x, y: y, generation: 0))
            }
        }
        pixels = Mutex(picture)
    }

    /// The pixel the Mac shows at a position: blue, green, red and an unused byte.
    static func pixel(x: Int, y: Int, generation: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: x &* 3 &+ generation &* 40), UInt8(truncatingIfNeeded: y &* 5 &+ 1), UInt8(truncatingIfNeeded: x ^ y), 0xff]
    }

    /// The modulus of the exchange: 512 bits, the least a viewer accepts, to keep the many logins
    /// of a test run quick. (The viewer checks its range, not its primality, and the arithmetic
    /// agrees on both sides either way; a real Mac sends a 4096-bit prime.)
    static let prime = (BigUInt(1) << 512) - 569

    // MARK: Things the test makes the Mac do

    /// Queues a server message for the encrypted stream.
    func send(_ message: Data) {
        outboxContinuation.yield(message)
    }

    func sendBell() {
        send(Data([0x02]))
    }

    /// Repaints a rectangle with a new generation of the pattern and sends it as zlib.
    func repaint(x: Int, y: Int, width: Int, height: Int, generation: Int) {
        pixels.withLock { picture in
            for row in y..<(y + height) {
                for column in x..<(x + width) {
                    let offset = (row * options.width + column) * 4
                    picture.replaceSubrange(offset..<(offset + 4), with: Self.pixel(x: column, y: row, generation: generation))
                }
            }
        }
        outboxContinuation.yield(Self.zlibMarker(x: x, y: y, width: width, height: height))
    }

    /// Says where the Mac's pointer is now (encoding `0x44c`), in framebuffer pixels.
    func sendCursorPosition(x: Int, y: Int) {
        send(Self.update(rectangles: [(x, y, 0, 0, Encoding.appleCursorPosition.rawValue, Data())]))
    }

    static let ownDragToken: UInt32 = 1

    /// A drag of files begins on the Mac under the pointer. A Mac announces it, unasked, to the
    /// viewer it has marked as the drag's owner: the one whose pointer event had exactly the left
    /// button down, and came sealed (a plain pointer event never sets the mark). Anyone else is
    /// told nothing; returns whether this viewer was told.
    ///
    /// The announcement is one item per file, the first with the picture under the pointer beside
    /// its URL. (The capture this follows carried one file.)
    @discardableResult
    func beginDrag(paths: [String], picturePNG: Data) -> Bool {
        let isOwner = ownDrag.withLock { drag in
            if drag.viewerHoldsLeftButton { drag.isUnderWay = true }
            return drag.viewerHoldsLeftButton
        }
        guard isOwner else { return false }
        var archive = WireWriter()
        func counted(_ text: String) {
            archive.u32(UInt32(text.utf8.count))
            archive.bytes(text.utf8)
        }
        for (index, path) in paths.enumerated() {
            archive.u32(index == 0 ? 2 : 1) // flavors
            counted("public.file-url")
            archive.u32(0)
            archive.u32(1) // tags
            counted("com.apple.ostype")
            counted("furl")
            counted(URL(fileURLWithPath: path).absoluteString)
            guard index == 0 else { continue }
            counted("com.apple.remotedesktop.dragimage-png")
            archive.u32(0)
            archive.u32(0)
            archive.u32(UInt32(picturePNG.count))
            archive.bytes(picturePNG)
        }
        let compressed = DeflateStream(level: 9).chunk(archive.data)
        var message = WireWriter()
        message.u8(ServerMessageType.dragPasteboard)
        message.zeros(3)
        message.u32(Self.ownDragToken)
        message.u32(UInt32(archive.count))
        message.u32(UInt32(compressed.count))
        message.bytes(compressed)
        send(message.data)
        return true
    }

    /// Says the Mac's drag is over, as a Mac does once the button has come up: the token and two
    /// zero lengths.
    private func endDrag() {
        var message = WireWriter()
        message.u8(ServerMessageType.dragPasteboard)
        message.zeros(3)
        message.u32(Self.ownDragToken)
        message.zeros(8)
        send(message.data)
    }

    /// Stops taking what the viewer sends, or starts again, as a stalled TCP path would.
    func stallViewer(_ stalled: Bool) async {
        await stream.stallIncoming(stalled)
    }

    func hangUp() async {
        outboxContinuation.finish()
        await stream.close()
    }

    // MARK: Wire helpers

    private static func update(rectangles: [(x: Int, y: Int, width: Int, height: Int, encoding: Int32, body: Data)]) -> Data {
        var writer = WireWriter()
        writer.u8(0)
        writer.u8(0)
        writer.u16(UInt16(rectangles.count))
        for rectangle in rectangles {
            writer.u16(UInt16(rectangle.x))
            writer.u16(UInt16(rectangle.y))
            writer.u16(UInt16(rectangle.width))
            writer.u16(UInt16(rectangle.height))
            writer.i32(rectangle.encoding)
            writer.bytes(rectangle.body)
        }
        return writer.data
    }

    /// A stand-in the writer replaces with the rectangle's pixels, deflated on the session's one
    /// stream at the moment it is sent, so chunks leave in the order they were compressed.
    private static func zlibMarker(x: Int, y: Int, width: Int, height: Int) -> Data {
        var writer = WireWriter()
        writer.bytes(Data("ZLIB".utf8))
        for value in [x, y, width, height] { writer.u16(UInt16(value)) }
        return writer.data
    }

    private func layoutUpdate(flags: DisplayLayout.Flags) -> Data {
        var payload = WireWriter()
        payload.u16(1) // version
        payload.u16(UInt16(options.width / 2))
        payload.u16(UInt16(options.height / 2))
        payload.u16(UInt16(options.width))
        payload.u16(UInt16(options.height))
        payload.u32(.max) // every screen
        payload.u32(flags.rawValue)
        payload.u16(1)
        payload.f64(2) // density
        payload.f64(1) // server scale
        payload.u32(77) // the screen's id
        for edge in [0, 0, options.height / 2, options.width / 2] { payload.i16(Int16(edge)) }
        for edge in [0, 0, options.height, options.width] { payload.i16(Int16(edge)) }
        payload.u32(DisplayLayout.Screen.Flags.main.rawValue)
        payload.zeros(16)
        var body = WireWriter()
        body.u16(UInt16(payload.data.count))
        body.bytes(payload.data)
        return Self.update(rectangles: [(0, 0, 0, 0, Encoding.appleDisplayLayout.rawValue, body.data)])
    }

    /// The quantization tables and one full update that paints every tile white: the least an
    /// Adaptive picture can be.
    private func adaptiveWhiteScreen() -> [Data] {
        let tables = Data([2] + [UInt8](repeating: 16, count: 128))
        var tablesBody = WireWriter()
        tablesBody.u32(UInt32(tables.count))
        tablesBody.bytes(tables)

        let tiles = ((options.width + 7) / 8) * ((options.height + 7) / 8)
        // One skipped bit, command 0 (white), then a repeat: `1`, `1111` and the count less 17 in
        // seven-bit groups, low group first; then the mark.
        var bits: [Bool] = [false, false, false, false, true, true, true, true, true]
        var remaining = UInt32(tiles - 17)
        var groups: [UInt8] = []
        repeat {
            groups.append(UInt8(remaining & 0x7f))
            remaining >>= 7
        } while remaining > 0
        for (index, group) in groups.enumerated() {
            let byte = group | (index < groups.count - 1 ? 0x80 : 0)
            for bit in (0..<8).reversed() { bits.append(byte >> UInt8(bit) & 1 == 1) }
        }
        for bit in (0..<8).reversed() { bits.append(UInt8(0x6d) >> UInt8(bit) & 1 == 1) }
        var commands = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (index, bit) in bits.enumerated() where bit { commands[index / 8] |= 0x80 >> UInt8(index % 8) }
        let offset = 6 + commands.count
        let full = Data([0, 3, 5, UInt8(offset >> 16), UInt8(offset >> 8 & 0xff), UInt8(offset & 0xff)] + commands + [0x6d])
        var fullBody = WireWriter()
        fullBody.u32(UInt32(full.count))
        fullBody.bytes(full)
        return [
            Self.update(rectangles: [(0, 0, 0, 0, Encoding.appleAdaptive.rawValue, tablesBody.data)]),
            Self.update(rectangles: [(0, 0, options.width, options.height, Encoding.appleAdaptive.rawValue, fullBody.data)]),
        ]
    }

    private static func parseClientMessage(_ reader: inout WireReader) throws(WireError) -> Received {
        let type = try reader.u8()
        switch type {
        case ClientMessageType.setPixelFormat:
            try reader.skip(19)
            return .setPixelFormat
        case ClientMessageType.setEncodings:
            try reader.skip(1)
            let count = Int(try reader.u16())
            var list: [Int32] = []
            for _ in 0..<count { list.append(try reader.i32()) }
            return .encodings(list)
        case ClientMessageType.framebufferUpdateRequest:
            let incremental = try reader.u8() != 0
            return .updateRequest(
                incremental: incremental, x: Int(try reader.u16()), y: Int(try reader.u16()),
                width: Int(try reader.u16()), height: Int(try reader.u16())
            )
        case ClientMessageType.keyEvent:
            let isDown = try reader.u8() != 0
            try reader.skip(2)
            return .key(keysym: try reader.u32(), isDown: isDown)
        case ClientMessageType.pointerEvent:
            let mask = try reader.u8()
            return .pointer(mask: mask, x: Int(try reader.u16()), y: Int(try reader.u16()))
        case ClientMessageType.setServerScaling:
            try reader.skip(9)
            return .framed(type: type, length: 8)
        case ClientMessageType.autoFramebufferUpdate:
            try reader.skip(3)
            let interval = try reader.u32()
            try reader.skip(4)
            return .autoUpdate(interval: interval, width: Int(try reader.u16()), height: Int(try reader.u16()))
        case ClientMessageType.setDisplayConfiguration:
            try reader.skip(1)
            var body = try reader.sub(Int(try reader.u16()))
            try body.skip(2) // version
            let count = Int(try body.u16())
            try body.skip(4)
            var modes: [VirtualDisplayMode] = []
            var dynamic = false
            for _ in 0..<count {
                var descriptor = try body.sub(Int(try body.u16()) - 2)
                try descriptor.skip(0x78) // the name
                dynamic = try descriptor.u32() & 1 != 0
                try descriptor.skip(4 + 8 + 8 + 4 + 4 + 2)
                // The requested mode is the first; the presets follow.
                let pixelWidth = try descriptor.u32()
                let pixelHeight = try descriptor.u32()
                let pointWidth = try descriptor.u32()
                let pointHeight = try descriptor.u32()
                modes.append(VirtualDisplayMode(
                    pixelWidth: pixelWidth, pixelHeight: pixelHeight, pointWidth: pointWidth, pointHeight: pointHeight,
                    refreshRate: try descriptor.f64(), isHDR: try descriptor.u32() != 0
                ))
            }
            return .displayConfiguration(modes, dynamic: dynamic)
        case ClientMessageType.mediaOffer:
            try reader.skip(1)
            var body = try reader.sub(Int(try reader.u16()))
            try body.skip(6)
            let audioLength = Int(try body.u16())
            let videoLengths = [Int(try body.u16()), Int(try body.u16())].filter { $0 > 0 }
            try body.skip(4 + 16 + 2 * MediaKey.length + audioLength)
            var keys: [MediaLegKeys] = []
            for length in videoLengths {
                let viewerToServer = MediaKey(bytes: try body.take(MediaKey.length))
                let serverToViewer = MediaKey(bytes: try body.take(MediaKey.length))
                keys.append(MediaLegKeys(viewerToServer: viewerToServer, serverToViewer: serverToViewer))
                try body.skip(length)
            }
            return .mediaOffer(videoKeys: keys)
        case ClientMessageType.setMode:
            try reader.skip(1)
            return .mode(try reader.u16())
        case ClientMessageType.pasteboardFetch:
            try reader.skip(3)
            return .pasteboardFetch(token: try reader.u32())
        case ClientMessageType.setDisplay:
            let all = try reader.u8() != 0
            try reader.skip(2)
            let id = try reader.u32()
            return .setDisplay(all ? nil : id)
        case ClientMessageType.setEncryption:
            try reader.skip(1)
            let command = try reader.u16()
            try reader.skip(command == 1 ? 8 : 4)
            return .encryption(command: command)
        case ClientMessageType.autoPasteboard:
            try reader.skip(7)
            return .autoPasteboard
        case ClientMessageType.event2:
            try reader.skip(1)
            let length = try reader.u16()
            let body = try reader.take(Int(length))
            var header = WireWriter()
            header.u8(type)
            header.u8(0)
            header.u16(length)
            var bodyReader = WireReader(body)
            let kind = (try? bodyReader.skip(2)).flatMap { try? bodyReader.u16() } ?? 0
            return .event(kind: kind, message: header.data + body)
        case ClientMessageType.viewerInfo:
            try reader.skip(1)
            let length = Int(try reader.u16())
            try reader.skip(length)
            return .framed(type: type, length: length)
        case ClientMessageType.setSessionVisibility:
            try reader.skip(1)
            let visible = try reader.u16()
            var note = try reader.sub(Int(try reader.u16()))
            return .curtain(curtained: visible == 0, note: String(decoding: note.rest(), as: UTF8.self))
        case ClientMessageType.dragPasteboard:
            try reader.skip(3)
            let token = try reader.u32()
            let inflatedLength = Int(try reader.u32())
            let sent = try reader.take(Int(try reader.u32()))
            guard inflatedLength > 0 else { return .drag(token: token, names: []) }
            guard let archive = try? InflateStream.inflateWhole(sent, limit: inflatedLength), archive.count == inflatedLength else {
                throw .malformed("a drag archive that does not inflate to its \(inflatedLength) bytes")
            }
            return .drag(token: token, names: try draggedNames(in: archive))
        case ClientMessageType.dragRequest:
            try reader.skip(3)
            return .dragRequest(token: try reader.u32())
        case ClientMessageType.hidReport:
            // Little-endian, unlike everything else.
            try reader.skip(1)
            let header = try reader.take(18)
            func littleEndian(_ offset: Int, _ count: Int) -> Int {
                (0..<count).reduce(0) { $0 | Int(header[header.startIndex + offset + $1]) << (8 * $1) }
            }
            let length = littleEndian(0, 2)
            let reportLength = littleEndian(16, 2)
            guard littleEndian(2, 2) == 1, length == 16 + reportLength else {
                throw .malformed("HID report message of length \(length), version \(littleEndian(2, 2)), report \(reportLength)")
            }
            return .touch(display: UInt32(littleEndian(12, 4)), report: try DigitizerReport.parse(try reader.take(reportLength)))
        default:
            throw .malformed("viewer message type \(type)")
        }
    }

    /// The files a drag's archive lists, by name: the last component of each `public.file-url`.
    private static func draggedNames(in archive: Data) throws(WireError) -> [String] {
        var whole = WireReader(archive)
        var reader = try whole.sub(archive.count)
        var names: [String] = []
        while !reader.isAtEnd {
            for _ in 0..<(try reader.u32()) {
                let flavor = String(decoding: try reader.take(Int(try reader.u32())), as: UTF8.self)
                try reader.skip(4)
                for _ in 0..<(try reader.u32()) {
                    try reader.skip(Int(try reader.u32()))
                    try reader.skip(Int(try reader.u32()))
                }
                let data = try reader.take(Int(try reader.u32()))
                if flavor == "public.file-url", let url = URL(string: String(decoding: data, as: UTF8.self)) {
                    names.append(url.lastPathComponent)
                }
            }
        }
        return names
    }

    /// One message of the session. With the record layer's key, an `EncryptedInputEvent` is opened
    /// and comes out as the key or pointer event inside it, with its sealed form beside it:
    ///
    ///     10 | flags | AES-128-ECB(block)
    ///     key:     ff | down | u32 keysym | u32 microseconds | six bytes for the key's code
    ///     pointer: six zero bytes | u32 microseconds | ff | mask | u16 x | u16 y
    private static func parseSessionMessage(_ reader: inout WireReader, inputKey: Data?) throws(WireError) -> (Received, SealedInput?) {
        var ahead = reader
        guard let inputKey, try ahead.u8() == ClientMessageType.encryptedInputEvent else {
            return (try parseClientMessage(&reader), nil)
        }
        try reader.skip(1)
        let flags = try reader.u8()
        guard let block = try? AES128.decryptECB(try reader.take(16), key: inputKey) else { throw .malformed("an input block that does not decrypt") }
        let bytes = [UInt8](block)
        let event: Received
        if bytes[0] == 0xff {
            event = .key(keysym: bytes[2...5].reduce(0) { $0 << 8 | UInt32($1) }, isDown: bytes[1] != 0)
        } else if bytes[10] == 0xff, bytes[0..<6].allSatisfy({ $0 == 0 }) {
            event = .pointer(mask: bytes[11], x: Int(bytes[12]) << 8 | Int(bytes[13]), y: Int(bytes[14]) << 8 | Int(bytes[15]))
        } else {
            throw .malformed("an input block that is neither a key nor a pointer event: \(bytes)")
        }
        return (event, SealedInput(event: event, flags: flags, block: block))
    }

    // MARK: Serving one viewer

    func run() async throws {
        defer { outboxContinuation.finish() }
        try await stream.write(Data(options.version.utf8))
        let version = try await stream.readExactly(12)
        guard version == Data("RFB 003.889\n".utf8) else { throw Failure.unexpected("viewer version \(String(decoding: version, as: UTF8.self))") }

        if let refusal = options.refusal {
            var writer = WireWriter()
            writer.u8(0)
            writer.u32(UInt32(refusal.utf8.count))
            writer.bytes(Data(refusal.utf8))
            try await stream.write(writer.data)
            await stream.close()
            return
        }
        try await stream.write(Data([UInt8(options.securityTypes.count)] + options.securityTypes))
        let chosen = try await stream.readExactly(1)[0]
        // Like screensharingd, a message read with the type byte is taken to start with its length;
        // one read later starts with the type again. What arrives within 50 ms counts as read with
        // it, as for a daemon slow to read.
        if chosen == 36 { try await Task.sleep(for: .milliseconds(50)) }
        let readWithType = await stream.availableCount() > 0
        let wrapKey: Data?
        switch chosen {
        case 2:
            guard try await serveVNCPassword() else { return }
            wrapKey = nil
        case 36:
            guard let key = try await serveSRP(readWithType: readWithType) else { return }
            wrapKey = key
        case 30:
            guard let key = try await serveDiffieHellman() else { return }
            wrapKey = key
        default:
            throw Failure.unexpected("the viewer picked login type \(chosen)")
        }
        try await serveSession(wrapKey: wrapKey)
    }

    /// Type 2: a challenge, and the result word. No key comes of it, so the session stays in clear.
    private func serveVNCPassword() async throws -> Bool {
        let challenge = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        try await stream.write(challenge)
        let response = try await stream.readExactly(16)
        let accepted = response == (try VNCPasswordLogin.response(to: challenge, password: options.password))
        record.withLock { $0.vncPasswordLogins.append(accepted) }
        try await stream.write(Data([0, 0, 0, accepted ? 0 : 1]))
        if !accepted { await stream.close() }
        return accepted
    }

    /// Type 36 as screensharingd serves it. Returns the rekey's wrapping key, or nil after a refusal.
    private func serveSRP(readWithType: Bool) async throws -> Data? {
        func readMessage(lead: Bool) async throws -> WireReader {
            if lead, !options.isWayshare {
                guard try await stream.readExactly(1) == Data([36]) else { throw Failure.unexpected("SRP message without its type") }
            }
            let outer = try await stream.readExactly(4).reduce(0) { $0 << 8 | Int($1) }
            var reader = WireReader(try await stream.readExactly(outer))
            let inner = Int(try reader.u32())
            guard inner == reader.remaining else { throw Failure.unexpected("SRP buffer of \(inner) in \(reader.remaining)") }
            return reader
        }
        func utf8(_ reader: inout WireReader) throws -> String {
            String(decoding: try reader.take(Int(try reader.u16())), as: UTF8.self)
        }
        func frame(_ fields: Data) -> Data {
            var writer = WireWriter()
            writer.u32(UInt32(fields.count + 4))
            writer.u32(UInt32(fields.count))
            writer.bytes(fields)
            return writer.data
        }
        let group = options.isWayshare ? SRPLogin.rfc5054Group2048 : SRPLogin.rfc5054Group4096
        let N = group.modulus
        let g = group.generator
        func pad(_ value: BigUInt) -> Data { group.pad(value) }

        if readWithType, !options.isWayshare, options.loopsOnAMisreadFirstMessage, await stream.peekFirstByte() == 36 {
            record.withLock { $0.misreadFirstMessage = true }
            await stream.close()
            return nil
        }
        var first = try await readMessage(lead: !readWithType)
        let authenticationID = try utf8(&first)
        _ = try utf8(&first)
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let iterations: UInt64 = 1000
        let x = try SRPLogin.passwordKey(Data(options.password.utf8), salt: salt, iterations: iterations)
        let v = ModularPower.power(g, x, modulus: N)
        let k = BigUInt(Digest.sha512(pad(N) + pad(g)))
        let b = BigUInt(Data((0..<32).map { _ in UInt8.random(in: 1...255) }))
        let B = (k * v + ModularPower.power(g, b, modulus: N)) % N
        var challenge = WireWriter()
        challenge.u8(0)
        challenge.u16(UInt16(group.length)); challenge.bytes(pad(N))
        challenge.u16(1); challenge.u8(UInt8(g))
        challenge.u8(UInt8(salt.count)); challenge.bytes(salt)
        challenge.u16(UInt16(group.length)); challenge.bytes(pad(B))
        challenge.u64(iterations)
        let offered = Data("mda=SHA-512,replay_detection,conf+int=ChaCha20-Poly1305,kdf=SALTED-SHA512-PBKDF2".utf8)
        challenge.u16(UInt16(offered.count)); challenge.bytes(offered)
        try await stream.write(frame(challenge.data))

        var answer = try await readMessage(lead: false)
        let A = BigUInt(try answer.take(Int(try answer.u16())))
        let M1 = try answer.take(Int(try answer.u8()))
        let chosen = Set(try utf8(&answer).split(separator: ",").map(String.init))
        let u = BigUInt(Digest.sha512(pad(A) + pad(B)))
        let S = ModularPower.power(A * ModularPower.power(v, u, modulus: N) % N, b, modulus: N)
        let K = Digest.sha512(pad(S))
        let mixed = Data(zip(Digest.sha512(pad(N)), Digest.sha512(pad(g))).map { $0 ^ $1 })
        let expected = Digest.sha512(mixed + Digest.sha512(Data()) + salt + pad(A) + pad(B) + K)
        let accepted = authenticationID == options.username && M1 == expected
            && options.requiredSRPOptions.allSatisfy(chosen.contains)
        record.withLock { $0.srpLogins.append((authenticationID, accepted)) }
        guard accepted else {
            try await stream.write(Data([0, 0, 0, 1]))
            await stream.close()
            return nil
        }
        var proof = Digest.sha512(pad(A) + M1 + K)
        if options.forgesSRPProof { proof[proof.startIndex] ^= 0xff }
        var reply = WireWriter()
        reply.u8(64); reply.bytes(proof)
        reply.u8(16); reply.bytes(Data(repeating: 7, count: 16))
        reply.u16(0); reply.u32(0)
        try await stream.write(frame(reply.data) + Data([0, 0, 0, 0]))
        return Digest.sha256(K).prefix(16)
    }

    /// Type 30. Returns the rekey's wrapping key, or nil after a refusal.
    private func serveDiffieHellman() async throws -> Data? {
        let length = 64
        let privateKey = BigUInt(Data((0..<16).map { _ in UInt8.random(in: 1...255) }))
        let publicKey = BigUInt(2).power(privateKey, modulus: Self.prime)
        func padded(_ number: BigUInt) -> Data {
            let bytes = number.serialize()
            return Data(count: length - bytes.count) + bytes
        }
        var challenge = WireWriter()
        challenge.u16(2)
        challenge.u16(UInt16(length))
        challenge.bytes(padded(Self.prime))
        challenge.bytes(padded(publicKey))
        try await stream.write(challenge.data)

        let response = try await stream.readExactly(128 + length)
        let shared = BigUInt(response.suffix(length)).power(privateKey, modulus: Self.prime)
        let wrapKey = Digest.md5(padded(shared))
        let credentials = try AES128.decryptECB(response.prefix(128), key: wrapKey)
        func field(_ range: Range<Int>) -> String {
            String(decoding: credentials[range].prefix { $0 != 0 }, as: UTF8.self)
        }
        let (username, password) = (field(0..<64), field(64..<128))
        record.withLock { $0.logins.append((username, password)) }
        guard username == options.username, password == options.password else {
            try await stream.write(Data([0, 0, 0, 1]))
            await stream.close()
            return nil
        }
        try await stream.write(Data([0, 0, 0, 0]))
        return wrapKey
    }

    /// Session select as a Mac with `consoleUser` at its display serves it: an offer, then a verdict
    /// on each answer, until one is accepted.
    private func serveSessionSelect(consoleUser: String, wrapKey: Data?) async throws {
        let offer = SessionSelectOffer(
            commands: SessionSelectOffer.Commands(options.sessionSelectCommands.map(SessionSelectOffer.Commands.init)), consoleUser: consoleUser
        )
        try await stream.write(offer.encoded)
        var answers = options.consoleAnswers
        while true {
            let lengthBytes = try await stream.readExactly(2)
            let body = try await stream.readExactly(Int(lengthBytes[0]) << 8 | Int(lengthBytes[1]))
            var reader = WireReader(lengthBytes + body)
            let answer = try SessionSelectAnswer.parse(&reader)
            record.withLock { $0.sessionSelectAnswers.append(answer) }
            switch answer.command {
            case .logInAsSelf:
                guard let wrapKey else { throw Failure.unexpected("credentials without a login key") }
                let credentials = try AES128.decryptECB(answer.sealedCredentials, key: wrapKey)
                func field(_ range: Range<Int>) -> String {
                    String(decoding: credentials[range].prefix { $0 != 0 }, as: UTF8.self)
                }
                record.withLock { $0.sessionLogins.append((field(0..<64), field(64..<128))) }
                try await stream.write(SessionSelectResult.accepted.encoded)
                return
            case .connectToConsole:
                try await stream.write(SessionSelectResult.accepted.encoded)
                return
            case .askConsoleUser:
                guard !answers.isEmpty else {
                    // Nobody answers: the Mac says nothing until the viewer gives up.
                    _ = try await stream.read(upTo: 1)
                    throw Failure.viewerHungUp
                }
                if answers.removeFirst() {
                    try await stream.write(SessionSelectResult.accepted.encoded)
                    return
                }
                try await stream.write(SessionSelectResult.declined(offer).encoded)
            }
        }
    }

    /// Everything after the login: initialisation, the prelude, the switch to records, the session.
    private func serveSession(wrapKey: Data?) async throws {
        let clientInit = try await stream.readExactly(1)[0]
        let offersSessionSelect = options.consoleUser != nil && clientInit & 0x40 != 0
        var initialisation = WireWriter()
        initialisation.u16(UInt16(options.width))
        initialisation.u16(UInt16(options.height))
        initialisation.bytes(Data([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]))
        var nameField = WireWriter()
        if options.isWayshare {
            // One display, and wayshare's messages.
            nameField.u16(0)
            nameField.u32(1 << 5)
            nameField.bytes(Data(MessageBitmap(types: [0, 2, 3, 4, 5, 6, 9, 33] + (options.wayshareEncrypts ? [18] : []), byteCount: 16).bytes))
        } else if !options.answersInPlainForm {
            nameField.u16(0)
            // May control (or only watch), extended, two virtual displays; and session select
            // follows, if it does.
            nameField.u32((options.isObserveOnly ? 0x01 : 0x02) | 0x10 | 2 << 5 | (offersSessionSelect ? 0x04 : 0))
            // Message 0x10 is the first bit of the third byte.
            // Message 0x12, SetEncryption, is the third bit of the third byte.
            let third: UInt8 = (options.takesEncryptedInput ? 0xe7 : 0x67) & (options.stripsSetEncryption ? ~0x20 : 0xff)
            // Message 0x26, HIDReport, is the seventh bit of the fifth byte.
            let fifth: UInt8 = 0xec | (options.takesTouches ? 0x02 : 0)
            nameField.bytes(Data([0xbf, 0xf6, third, 0x2f, fifth] + [UInt8](repeating: 0, count: 11)))
        }
        nameField.bytes(Data(options.name.utf8))
        initialisation.u32(UInt32(nameField.data.count))
        initialisation.bytes(nameField.data)
        try await stream.write(initialisation.data)
        if offersSessionSelect, let consoleUser = options.consoleUser {
            try await serveSessionSelect(consoleUser: consoleUser, wrapKey: wrapKey)
        }

        // New keys, wrapped under the login's key, in a rectangle of their own; then records.
        // Without a login key (a VNC password) everything stays in clear.
        var keys: RecordKeys?
        func rekey() throws -> Data {
            guard let wrapKey else { return Data() }
            let fresh = RecordKeys(key: Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }), iv: Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
            var rekey = WireWriter()
            rekey.u32(1)
            rekey.bytes(try AES128.encryptECB(fresh.key, key: wrapKey))
            rekey.bytes(try AES128.encryptECB(fresh.iv, key: wrapKey))
            record.withLock { $0.isEncrypted = true }
            keys = fresh
            return Self.update(rectangles: [(0, 0, 0, 0, Encoding.appleRekey.rawValue, rekey.data)])
        }

        // The prelude, in clear, up to the viewer's request for the record layer. A Mac sends its
        // keys once both switches are in; wayshare as soon as the first is.
        var clear = InboundBuffer()
        var requestedRecords = wrapKey == nil || (options.isWayshare && !options.wayshareEncrypts)
        while !requestedRecords {
            guard let chunk = try await stream.read(upTo: 4096) else { throw Failure.viewerHungUp }
            clear.append(chunk)
            while let message = try clear.parse({ (reader: inout WireReader) throws(WireError) in try Self.parseClientMessage(&reader) }) {
                record.withLock { $0.prelude.append(message) }
                if options.isWayshare, message == .encryption(command: 1) {
                    // wayshare's reader runs ahead of the task that makes the keys: a switch that
                    // arrives in the meantime finds none, and the connection ends.
                    try await Task.sleep(for: .milliseconds(100))
                    clear.append(await stream.readAvailable())
                    if try clear.parse({ (reader: inout WireReader) throws(WireError) in try Self.parseClientMessage(&reader) }) == .encryption(command: 2) {
                        throw Failure.unexpected("the viewer switched to records before wayshare sent its keys")
                    }
                    try await stream.write(try rekey())
                }
                if message == .encryption(command: 2) {
                    requestedRecords = true
                    break
                }
            }
        }
        guard clear.isEmpty else { throw Failure.unexpected("the viewer went on in clear after asking for records") }
        if !options.isWayshare, wrapKey != nil { try await stream.write(try rekey()) }

        let writer = Task { [self, keys] in
            let sealer = try keys.map { try RecordSealer(keys: $0) }
            let deflater = DeflateStream()
            for await message in outbox {
                var plain = message
                if message.prefix(4) == Data("ZLIB".utf8) {
                    let values = stride(from: 4, to: 12, by: 2).map { Int(message[message.startIndex + $0]) << 8 | Int(message[message.startIndex + $0 + 1]) }
                    let (x, y, width, height) = (values[0], values[1], values[2], values[3])
                    var raw = Data(capacity: width * height * 4)
                    pixels.withLock { picture in
                        for row in y..<(y + height) {
                            raw.append(contentsOf: picture[((row * options.width + x) * 4)..<((row * options.width + x + width) * 4)])
                        }
                    }
                    let chunk = deflater.chunk(raw)
                    var body = WireWriter()
                    body.u32(UInt32(chunk.count))
                    body.bytes(chunk)
                    plain = Self.update(rectangles: [(x, y, width, height, Encoding.zlib.rawValue, body.data)])
                }
                try await stream.write(try sealer?.seal(plain) ?? plain)
            }
        }
        defer { writer.cancel() }
        let worker = Task { [jobs] in
            for await job in jobs { await job() }
        }
        let pictures = Task { [self] in
            guard let interval = options.highPerformance.pictureInterval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                let legs = media.withLock { $0.showsPictures ? $0.legs.count : 0 }
                for leg in 0..<legs { sendKeyframe(leg: leg) }
            }
        }
        defer { pictures.cancel() }
        let reporter = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                sendReports()
            }
        }
        let heartbeat = Task { [self] in
            guard let interval = options.heartbeatInterval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                sendStatus(4)
            }
        }
        defer {
            jobsContinuation.finish()
            worker.cancel()
            reporter.cancel()
            heartbeat.cancel()
        }

        let opener = try keys.map { try RecordOpener(keys: $0) }
        var ciphertext = InboundBuffer()
        var plaintext = InboundBuffer()
        var codec: Int32?
        // Sealed input is taken only by a Mac that said so, under the record layer's key.
        let inputKey = options.takesEncryptedInput && !options.isWayshare ? keys?.key : nil
        // The viewer's drag over the picture: its token, and whether its button has gone down.
        var viewerDrag: (token: UInt32, isHeld: Bool)?
        while let chunk = try await stream.read(upTo: 65536) {
            if let opener {
                ciphertext.append(chunk)
                try opener.open(from: &ciphertext, into: &plaintext)
            } else {
                plaintext.append(chunk)
            }
            while let (message, sealed) = try plaintext.parse({ (reader: inout WireReader) throws(WireError) in
                try Self.parseSessionMessage(&reader, inputKey: inputKey)
            }) {
                record.withLock {
                    $0.messages.append(message)
                    if let sealed { $0.sealedInput.append(sealed) }
                }
                switch message {
                case .drag(let token, let names):
                    // An empty one calls the drag off: the release that follows drops nothing.
                    viewerDrag = names.isEmpty ? nil : (token, false)
                case .pointer(let mask, _, _):
                    let ownDragEnded = ownDrag.withLock { drag in
                        drag.viewerHoldsLeftButton = sealed != nil && mask == 1
                        defer { if mask == 0 { drag.isUnderWay = false } }
                        return mask == 0 && drag.isUnderWay
                    }
                    // Whether the files were dropped on the Mac or the viewer took the drag over,
                    // the Mac says it is over when the button comes up.
                    if ownDragEnded { endDrag() }
                    guard let drag = viewerDrag else { break }
                    if mask != 0 {
                        viewerDrag?.isHeld = true
                    } else if drag.isHeld {
                        viewerDrag = nil
                        // A Mac goes along with a drag only for a viewer whose pointer events are
                        // sealed, and names a folder only when one is under the drop.
                        guard sealed != nil, let folder = options.dropFolder else { break }
                        var destination = WireWriter()
                        destination.u8(ServerMessageType.dropDestination)
                        destination.zeros(3)
                        destination.u32(drag.token)
                        destination.u32(UInt32(folder.utf8.count))
                        destination.bytes(folder.utf8)
                        send(destination.data)
                        record.withLock { $0.namedDrops.append(drag.token) }
                    }
                case .encodings(let list):
                    // A Mac codes the picture with the first picture codec the list names.
                    let first = list.first { $0 == Encoding.zlib.rawValue || $0 == Encoding.appleAdaptive.rawValue }
                    // In High Performance the layout is of the displays the viewer configures.
                    if codec == nil, options.sendsLayout, !list.contains(Encoding.appleMediaStream.rawValue) {
                        send(layoutUpdate(flags: options.standardLayoutFlags))
                    }
                    codec = first
                case .curtain(let curtained, _) where options.standardLayoutFlags.contains(.curtain):
                    send(layoutUpdate(flags: curtained ? [.onVirtualDisplay, .curtain] : [.onConsole, .lockScreen]))
                case .displayConfiguration(let modes, _):
                    configured(modes)
                case .mediaOffer(let keys):
                    offered(keys)
                case .updateRequest(incremental: false, _, _, _, _):
                    if codec == Encoding.appleAdaptive.rawValue {
                        for update in adaptiveWhiteScreen() { send(update) }
                    } else {
                        outboxContinuation.yield(Self.zlibMarker(x: 0, y: 0, width: options.width, height: options.height))
                    }
                default:
                    break
                }
            }
        }
        record.withLock { $0.viewerClosed = true }
    }
}

// MARK: - High Performance

/// The Mac's view of its High Performance stream.
struct MediaState {
    struct Leg {
        var port: UInt16
        var width: Int
        var height: Int
        var ssrc: UInt32
        var outbound: SRTPSession
        var inbound: SRTPSession
        var lastKeyframe: ContinuousClock.Instant?
    }

    var configurations = 0
    var offers = 0
    /// The displays the latest configuration made.
    var screens: [VirtualDisplayMode] = []
    var nextScreenID: UInt32 = 0x4000
    var channels: [UInt16: ScriptedDatagramChannel] = [:]
    /// The legs of the stream now running; empty when none is.
    var legs: [Leg] = []
    /// RTP numbering carries on across streams, per port.
    var sequences: [UInt16: UInt16] = [:]
    var timestamp: UInt32 = 0
    /// Pictures sent, per leg index.
    var pictures: [Int: Int] = [:]
    /// Datagrams the viewer sent, by the Mac's port.
    var received: [UInt16: Int] = [:]
    /// Every this many picture packets one is lost on the way (0: none).
    var dropEvery = 0
    var packetCount = 0
    /// The stream running is of the session's own displays (not the opening ones), which get pictures.
    var showsPictures = false
}

extension ScriptedMac {
    var videoPorts: [UInt16] { Array(options.highPerformance.ports.dropFirst()) }

    var configurations: [[VirtualDisplayMode]] {
        record.withLock { $0.messages.compactMap { if case .displayConfiguration(let modes, _) = $0 { modes } else { nil } } }
    }

    var offerCount: Int {
        record.withLock { $0.messages.filter { if case .mediaOffer = $0 { true } else { false } }.count }
    }

    /// Sends a status notification (`MiscStatus`).
    func sendStatus(_ status: UInt16) {
        var writer = WireWriter()
        writer.u8(ServerMessageType.status)
        writer.u8(0)
        writer.u16(4)
        writer.u16(1)
        writer.u16(status)
        send(writer.data)
    }

    /// Sends a layout of the displays now made, with these flags.
    func sendLayout(flags: DisplayLayout.Flags) {
        send(Self.layout(media.withLock { $0.screens }, flags: flags, firstID: media.withLock { $0.nextScreenID }))
    }

    /// Names the media ports, as the Mac does once a configuration has taken effect.
    func sendPorts() {
        let legs = max(1, media.withLock { $0.screens.count })
        var body = WireWriter()
        body.u16(1)
        body.zeros(6)
        body.u16(options.highPerformance.ports[0])
        body.u32(1)
        body.u16(videoPorts[0])
        body.u32(1)
        body.u16(videoPorts[1])
        body.u32(legs > 1 && !options.highPerformance.namesOneVideoPort ? 1 : 0)
        body.zeros(10)
        send(Self.mediaReply(body.data))
    }

    /// Stops the stream's pictures and reports, as a path that goes dark would.
    func stopMedia() {
        media.withLock { $0.legs.removeAll() }
    }

    /// Loses every `every`th picture packet from now on (0: none), as a lossy path would.
    func losePackets(every: Int) {
        media.withLock { $0.dropEvery = every }
    }

    private static func mediaReply(_ body: Data) -> Data {
        var rectangle = WireWriter()
        rectangle.u16(UInt16(body.count))
        rectangle.bytes(body)
        return update(rectangles: [(0, 0, 0, 0, Encoding.appleMediaStream.rawValue, rectangle.data)])
    }

    private static func layout(_ modes: [VirtualDisplayMode], flags: DisplayLayout.Flags, firstID: UInt32) -> Data {
        var payload = WireWriter()
        payload.u16(1)
        payload.u16(UInt16(clamping: modes.reduce(0) { $0 + Int($1.pointWidth) }))
        payload.u16(UInt16(clamping: modes.map { Int($0.pointHeight) }.max() ?? 0))
        payload.u16(UInt16(clamping: modes.reduce(0) { $0 + Int($1.pixelWidth) }))
        payload.u16(UInt16(clamping: modes.map { Int($0.pixelHeight) }.max() ?? 0))
        payload.u32(.max)
        payload.u32(flags.rawValue)
        payload.u16(UInt16(modes.count))
        var pointLeft = 0
        var pixelLeft = 0
        for (index, mode) in modes.enumerated() {
            payload.f64(Double(mode.pixelWidth) / Double(mode.pointWidth))
            payload.f64(1)
            payload.u32(firstID + UInt32(index))
            for edge in [0, pointLeft, Int(mode.pointHeight), pointLeft + Int(mode.pointWidth)] { payload.i16(Int16(clamping: edge)) }
            for edge in [0, pixelLeft, Int(mode.pixelHeight), pixelLeft + Int(mode.pixelWidth)] { payload.i16(Int16(clamping: edge)) }
            payload.u32((index == 0 ? DisplayLayout.Screen.Flags.main : []).union(.dynamicVirtual).rawValue)
            payload.zeros(16)
            pointLeft += Int(mode.pointWidth)
            pixelLeft += Int(mode.pixelWidth)
        }
        var body = WireWriter()
        body.u16(UInt16(payload.data.count))
        body.bytes(payload.data)
        return update(rectangles: [(0, 0, 0, 0, Encoding.appleDisplayLayout.rawValue, body.data)])
    }

    private func enqueue(_ job: @escaping @Sendable () async -> Void) {
        jobsContinuation.yield(job)
    }

    /// A display configuration: after a while, the displays' layout and the media ports.
    fileprivate func configured(_ modes: [VirtualDisplayMode]) {
        let script = options.highPerformance
        let index = media.withLock { state in
            defer { state.configurations += 1 }
            return state.configurations
        }
        guard !script.unansweredConfigurations.contains(index) else { return }
        enqueue { [self] in
            try? await Task.sleep(for: script.layoutDelay)
            // Making new displays stops the stream; new ones get new ids.
            media.withLock { state in
                state.legs.removeAll()
                state.screens = modes
                state.nextScreenID += UInt32(modes.count)
            }
            if script.portsBeforeLayout { sendPorts() }
            sendLayout(flags: index >= script.physicalFromConfiguration ? script.layoutFlags.subtracting(.onVirtualDisplay) : script.layoutFlags)
            if !script.portsBeforeLayout { sendPorts() }
            for _ in 0..<script.repeatedPortMessages { sendPorts() }
        }
    }

    /// A media offer: an answer, or the refusal the script names; then the stream.
    fileprivate func offered(_ keys: [MediaLegKeys]) {
        let script = options.highPerformance
        let index = media.withLock { state in
            defer { state.offers += 1 }
            return state.offers
        }
        enqueue { [self] in
            if let refusal = script.refusedOffers[index] {
                var body = WireWriter()
                body.u16(3)
                body.zeros(6)
                body.u32(refusal.kind)
                body.u32(refusal.subCode)
                send(Self.mediaReply(body.data))
                return
            }
            var body = WireWriter()
            body.u16(2)
            body.zeros(6)
            body.u16(4)
            body.u16(4)
            body.u16(keys.count > 1 ? 4 : 0)
            body.zeros(4)
            body.zeros(keys.count > 1 ? 12 : 8)
            body.bytes(script.answerTrailer)
            send(Self.mediaReply(body.data))
            guard script.sendsMedia else { return }
            let legs: [MediaState.Leg] = media.withLock { state in
                zip(state.screens, zip(videoPorts, keys)).enumerated().compactMap { index, pair in
                    let (screen, portAndKeys) = pair
                    guard !script.silentLegs.contains(index) else { return nil }
                    guard let outbound = try? SRTPSession(direction: .outbound, masterKey: portAndKeys.1.serverToViewer.bytes),
                          let inbound = try? SRTPSession(direction: .inbound, masterKey: portAndKeys.1.viewerToServer.bytes)
                    else { return nil }
                    return MediaState.Leg(
                        port: portAndKeys.0, width: Int(screen.pixelWidth), height: Int(screen.pixelHeight),
                        ssrc: .random(in: 1 ... .max), outbound: outbound, inbound: inbound
                    )
                }
            }
            media.withLock {
                $0.legs = legs
                $0.showsPictures = index > 0
            }
            // The opening displays are replaced at once; only the session's own get pictures.
            guard index > 0 else { return }
            for leg in legs.indices { sendKeyframe(leg: leg) }
        }
    }

    /// A keyframe of one leg's display, cut into packets as a Mac cuts its H.264.
    func sendKeyframe(leg index: Int) {
        guard let leg = media.withLock({ $0.legs.indices.contains(index) ? $0.legs[index] : nil }),
              let picture = try? ScriptedH264Encoder.shared.keyframe(width: leg.width, height: leg.height)
        else { return }
        let payloads = Self.h264Payloads(units: picture.units, avcC: picture.avcC, maximum: options.highPerformance.packetPayload)
        let packets: [Data] = media.withLock { state in
            guard state.legs.indices.contains(index), state.legs[index].ssrc == leg.ssrc else { return [] }
            state.timestamp &+= 1500
            state.legs[index].lastKeyframe = .now
            state.pictures[index, default: 0] += 1
            var sequence = state.sequences[leg.port] ?? 1000
            defer { state.sequences[leg.port] = sequence }
            return payloads.enumerated().compactMap { offset, payload -> Data? in
                var packet = WireWriter()
                packet.u8(0x80)
                packet.u8((offset == payloads.count - 1 ? 0x80 : 0) | MediaVideoCodec.h264.payloadType)
                packet.u16(sequence)
                packet.u32(state.timestamp)
                packet.u32(leg.ssrc)
                packet.bytes(payload)
                sequence &+= 1
                return try? leg.outbound.protect(packet.data)
            }
        }
        guard let channel = media.withLock({ $0.channels[leg.port] }) else { return }
        for packet in packets {
            let lost = media.withLock { state in
                state.packetCount += 1
                return state.dropEvery > 0 && state.packetCount % state.dropEvery == 0
            }
            if !lost { channel.arrive(packet) }
        }
    }

    /// A sender report on every leg, as a Mac sends about once a second.
    fileprivate func sendReports() {
        let reports: [(ScriptedDatagramChannel, Data)] = media.withLock { state in
            state.legs.compactMap { leg in
                guard let channel = state.channels[leg.port] else { return nil }
                var report = WireWriter()
                report.u8(0x80)
                report.u8(200)
                report.u16(6)
                for value in [leg.ssrc, 0, 0, state.timestamp, 0, 0] { report.u32(value) }
                return (try? leg.outbound.protectRTCP(report.data)).map { (channel, $0) }
            }
        }
        for (channel, report) in reports { channel.arrive(report) }
    }

    /// What the viewer sends on a media port. A picture-loss indication or refresh request is
    /// answered with a keyframe, at most one every 100 ms.
    fileprivate func viewerSent(_ datagram: Data, toPort port: UInt16) {
        let answer: Int? = media.withLock { state in
            state.received[port, default: 0] += 1
            guard let index = state.legs.firstIndex(where: { $0.port == port }),
                  let clear = try? state.legs[index].inbound.unprotectRTCP(datagram), clear.count >= 2,
                  clear[clear.startIndex + 1] == 206
            else { return nil }
            if let last = state.legs[index].lastKeyframe, ContinuousClock.now - last < .milliseconds(100) { return nil }
            state.legs[index].lastKeyframe = .now
            return index
        }
        if let answer { enqueue { [self] in sendKeyframe(leg: answer) } }
    }

    fileprivate func attach(_ channel: ScriptedDatagramChannel, port: UInt16) {
        media.withLock { $0.channels[port] = channel }
    }

    /// A Mac's H.264 with one tile: a keyframe opens with a packet of NAL type 18 (forbidden bit
    /// set) holding four bytes and an `avc1` sample description with the `avcC` box; each unit
    /// then goes whole if it fits a packet and as FU-A fragments if not.
    private static func h264Payloads(units: [Data], avcC: Data, maximum: Int = 1100) -> [Data] {
        func box(_ type: String, _ body: Data) -> Data {
            var writer = WireWriter()
            writer.u32(UInt32(8 + body.count))
            writer.bytes(Data(type.utf8))
            writer.bytes(body)
            return writer.data
        }
        var payloads = [Data([0x92, 0, 0, 0, 1]) + box("avc1", Data(repeating: 0, count: 78) + box("avcC", avcC))]
        for unit in units {
            if unit.count <= maximum {
                payloads.append(unit)
                continue
            }
            let indicator = unit[unit.startIndex] & 0xe0 | 28
            let type = unit[unit.startIndex] & 0x1f
            let body = unit.dropFirst()
            var offset = body.startIndex
            while offset < body.endIndex {
                let end = min(body.endIndex, offset + maximum)
                var header = type
                if offset == body.startIndex { header |= 0x80 }
                if end == body.endIndex { header |= 0x40 }
                payloads.append(Data([indicator, header]) + body[offset..<end])
                offset = end
            }
        }
        return payloads
    }
}

/// One of the Mac's media ports as the viewer's socket sees it.
final class ScriptedDatagramChannel: DatagramChannel, Sendable {
    let localPort: UInt16
    private weak let mac: ScriptedMac?
    private let receiver = Mutex<(@Sendable (Datagram) -> Void)?>(nil)
    private let closed = Mutex(false)

    init(port: UInt16, mac: ScriptedMac?) {
        localPort = port
        self.mac = mac
    }

    func start(onReceive: @escaping @Sendable (Datagram) -> Void, onClose: @escaping @Sendable (TransportError?) -> Void) {
        receiver.withLock { $0 = onReceive }
    }

    func send(_ payload: Data) {
        guard !closed.withLock({ $0 }) else { return }
        mac?.viewerSent(payload, toPort: localPort)
    }

    func close() {
        closed.withLock { $0 = true }
        receiver.withLock { $0 = nil }
    }

    var isClosed: Bool { closed.withLock { $0 } }

    /// Delivers a datagram from the Mac.
    func arrive(_ payload: Data) {
        receiver.withLock { $0 }?(Datagram(payload: payload, receivedAt: .now))
    }
}

/// Keyframes from the system's H.264 encoder, so the viewer decodes a real bitstream.
final class ScriptedH264Encoder: @unchecked Sendable {
    static let shared = ScriptedH264Encoder()

    struct Picture {
        var units: [Data]
        var avcC: Data
    }

    struct Failure: Error {}

    /// The encoder's output; written once by its callback before the encode call returns.
    private final class SampleBox: @unchecked Sendable {
        var sample: CMSampleBuffer?
    }

    private let lock = NSLock()
    private var sessions: [String: VTCompressionSession] = [:]
    private var shade: UInt8 = 0

    /// A keyframe of a flat picture of this size; each is a little lighter than the one before.
    func keyframe(width: Int, height: Int) throws -> Picture {
        try lock.withLock {
            let session = try self.session(width: width, height: height)
            shade &+= 8
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard let buffer else { throw Failure() }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(shade), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let produced = SampleBox()
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(shade), timescale: 30),
                duration: .invalid, frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary, infoFlagsOut: nil
            ) { status, _, sample in
                if status == noErr, let sample { produced.sample = sample }
            }
            guard status == noErr else { throw Failure() }
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            guard let sample = produced.sample, let format = CMSampleBufferGetFormatDescription(sample),
                  let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
                  let avcC = atoms["avcC"] as? Data, let block = CMSampleBufferGetDataBuffer(sample)
            else { throw Failure() }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { throw Failure() }
            let bytes = Data(bytes: pointer, count: length)
            var units: [Data] = []
            var offset = 0
            while offset + 4 <= bytes.count {
                let size = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
                offset += 4
                guard size > 0, offset + size <= bytes.count else { break }
                units.append(bytes.subdata(in: offset..<(offset + size)))
                offset += size
            }
            return Picture(units: units, avcC: avcC)
        }
    }

    private func session(width: Int, height: Int) throws -> VTCompressionSession {
        if let session = sessions["\(width)x\(height)"] { return session }
        var created: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created
        )
        guard let created else { throw Failure() }
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        sessions["\(width)x\(height)"] = created
        return created
    }
}

/// A transport whose every connection reaches a new scripted Mac.
final class ScriptedMacTransport: TransportProvider {
    let peer = Endpoint(host: "scripted-mac.test", port: 5900)
    let isTunnelled: Bool
    let supportsDatagrams: Bool
    let options: ScriptedMac.Options
    /// Caps what each read on the viewer's side returns. 1 delivers the Mac's bytes one at a time.
    let chunkLimit: Int
    let macs = Mutex<[ScriptedMac]>([])
    let datagramChannels = Mutex<[ScriptedDatagramChannel]>([])

    init(options: ScriptedMac.Options = ScriptedMac.Options(), isTunnelled: Bool = false, supportsDatagrams: Bool = false, chunkLimit: Int = .max) {
        self.options = options
        self.isTunnelled = isTunnelled
        self.supportsDatagrams = supportsDatagrams
        self.chunkLimit = chunkLimit
    }

    var latest: ScriptedMac { macs.withLock { $0.last! } }

    func openStream(port: UInt16) async throws -> any ByteStream {
        let (client, server) = PipeStream.pair(clientChunkLimit: chunkLimit)
        let mac = ScriptedMac(stream: server, options: options)
        macs.withLock { $0.append(mac) }
        Task {
            try? await mac.run()
            await server.close()
        }
        return client
    }

    func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel {
        guard supportsDatagrams else { throw TransportError.unsupported(detail: "the scripted Mac has no media ports") }
        let mac = macs.withLock { $0.last }
        let channel = ScriptedDatagramChannel(port: options.remotePort, mac: mac)
        mac?.attach(channel, port: options.remotePort)
        datagramChannels.withLock { $0.append(channel) }
        return channel
    }
}
