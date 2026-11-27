// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import CommonCrypto
package import Foundation
package import SwiftVNCClient
package import Synchronization
import zlib

/// One direction of an in-memory byte pipe.
package actor PipeBuffer {
    private var buffer = Data()
    private var isClosed = false
    private var failure: (any Error)?
    private var waiter: CheckedContinuation<Void, Never>?

    package func append(_ data: Data) {
        buffer.append(data)
        waiter?.resume()
        waiter = nil
    }

    package func close() {
        isClosed = true
        waiter?.resume()
        waiter = nil
    }

    /// Ends the pipe with an error, as a network failure does.
    package func fail(_ error: any Error) {
        failure = error
        close()
    }

    package func read(upTo maxLength: Int) async throws -> Data? {
        while buffer.isEmpty {
            if let failure { throw failure }
            if isClosed { return nil }
            await withCheckedContinuation { waiter = $0 }
        }
        let chunk = buffer.prefix(maxLength)
        buffer.removeFirst(chunk.count)
        return Data(chunk)
    }
}

/// One end of an in-memory byte pipe.
package final class PipeEnd: VNCTransport {
    private let incoming: PipeBuffer
    private let outgoing: PipeBuffer

    package init(incoming: PipeBuffer, outgoing: PipeBuffer) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    package static func pair() -> (PipeEnd, PipeEnd) {
        let (a, b) = (PipeBuffer(), PipeBuffer())
        return (PipeEnd(incoming: a, outgoing: b), PipeEnd(incoming: b, outgoing: a))
    }

    package func read(upTo maxLength: Int) async throws -> Data? {
        try await incoming.read(upTo: maxLength)
    }

    package func write(_ data: Data) async throws {
        await outgoing.append(data)
    }

    package func close() async {
        await outgoing.close()
        await incoming.close()
    }

    /// Breaks the pipe: the other end's next read fails with `error`.
    package func fail(_ error: any Error) async {
        await outgoing.fail(error)
        await incoming.close()
    }

    package func readExactly(_ count: Int) async throws -> Data {
        var collected = Data()
        while collected.count < count {
            guard let chunk = try await read(upTo: count - collected.count) else { throw ScriptError.clientHungUp }
            collected.append(chunk)
        }
        return collected
    }
}

package enum ScriptError: Error {
    case clientHungUp
    case unexpected(String)
}

/// The extended clipboard's flags (rfbproto's "Extended Clipboard Pseudo-Encoding").
package enum ExtendedClipboard {
    package static let encoding = Int32(bitPattern: 0xC0A1_E5CE)
    package static let text: UInt32 = 1
    package static let caps: UInt32 = 1 << 24
    package static let request: UInt32 = 1 << 25
    package static let peek: UInt32 = 1 << 26
    package static let notify: UInt32 = 1 << 27
    package static let provide: UInt32 = 1 << 28
}

/// A minimal RFB 3.8 server, enough to exercise a viewer: one desktop sent as Raw rectangles,
/// optional VNC password authentication, resizes, the extended clipboard, and a record of the
/// input it receives.
package final class ScriptedServer: Sendable {
    package struct Recorded: Sendable {
        package var keys: [(keysym: UInt32, isDown: Bool)] = []
        package var pointers: [(x: Int, y: Int, mask: Int)] = []
        /// Classic cut text, and the text of extended Provides (as sent: CR LF and the NUL included).
        package var clipboard: [String] = []
        /// Every SetEncodings, in order.
        package var encodingLists: [[Int32]] = []
        package var updateRequests = 0
        /// Whether each update request was incremental, in order.
        package var incrementalRequests: [Bool] = []
        /// The bits per pixel of every SetPixelFormat, in order.
        package var pixelFormats: [Int] = []
        /// SetPixelFormats that came while an update request was still unanswered: the server could
        /// not know which format the client expects for its answer.
        package var pixelFormatsWithRequestOutstanding = 0
        /// Update requests that came while another was still unanswered.
        package var requestsWhileOneWasOutstanding = 0
        package var shared: Bool?
        /// The flags of the client's extended-clipboard Caps, once it sent them.
        package var clientClipboardCaps: UInt32?
        package var clientClipboardNotifies = 0
        /// For ``sendTwoRectanglesWaitingForInput(generation:)``: whether the key came before the
        /// second rectangle was sent.
        package var inputArrivedBetweenRectangles: Bool?

        package var encodings: [Int32] { encodingLists.last ?? [] }
    }

    /// How the server turns a client away, if it does.
    package enum Refusal: Sendable {
        /// No security types, then this reason (RFB 3.8).
        case beforeAuthentication(String)
    }

    private enum Step: Sendable {
        case bytes(Data)
        /// Raw pixels, in the format the client asked for when they are sent.
        case update(x: Int, y: Int, width: Int, height: Int, generation: Int)
        case pause(Duration)
        /// Keep reading client messages until a key event arrives, or the time is up.
        case awaitKey(Duration, then: Data)
        case resize(width: Int, height: Int, generation: Int)
    }

    private struct Desktop {
        var width: Int
        var height: Int
    }

    /// What a real server tracks between requests and updates.
    private struct Wire {
        /// 32 (B, G, R, X) or 8 (three bits red, three green, two blue).
        var bitsPerPixel = 32
        /// An update request has come that no update has answered yet. Like real servers, one
        /// update answers every request outstanding.
        var requestOutstanding = false
        /// Changes made while no request was outstanding, for the next one.
        var painted: [Step] = []
    }

    package let password: String?
    package let recorded = Mutex(Recorded())
    private let version: String
    private let refusal: Refusal?
    private let failureReason: String
    private let extendedDesktopSizeScreenID: UInt32?
    private let offersExtendedClipboard: Bool
    private let firstFrameInZRLE: Bool
    private let end: PipeEnd
    private let steps: Mutex<[Step]>
    private let desktop: Mutex<Desktop>
    private let wire = Mutex(Wire())
    private let serverClipboard = Mutex<String?>(nil)

    /// - Parameters:
    ///   - version: what the server announces; a Mac's says 3.889.
    ///   - failureReason: what it says when the password is wrong.
    ///   - extendedDesktopSizeScreenID: when set, the server answers ExtendedDesktopSize with one
    ///     screen of this id, as QEMU does with 0, and resizes with it while the client asks for it.
    ///   - extendedClipboard: whether the server speaks the extended clipboard.
    ///   - firstFrameInZRLE: whether the first picture comes as ZRLE rather than Raw.
    package init(
        end: PipeEnd, width: Int = 64, height: Int = 48, password: String? = nil, version: String = "RFB 003.008\n",
        refusal: Refusal? = nil, failureReason: String = "Authentication failed", extendedDesktopSizeScreenID: UInt32? = nil,
        extendedClipboard: Bool = false, firstFrameInZRLE: Bool = false
    ) {
        self.end = end
        self.password = password
        self.version = version
        self.refusal = refusal
        self.failureReason = failureReason
        self.extendedDesktopSizeScreenID = extendedDesktopSizeScreenID
        offersExtendedClipboard = extendedClipboard
        self.firstFrameInZRLE = firstFrameInZRLE
        steps = Mutex([])
        desktop = Mutex(Desktop(width: width, height: height))
    }

    /// The client has asked for an update that the server has not answered yet. A client asks for
    /// the next update once it has handled one, so this says that it has, as far as the server can tell.
    package var isRequestOutstanding: Bool { wire.withLock { $0.requestOutstanding } }

    package var width: Int { desktop.withLock { $0.width } }
    package var height: Int { desktop.withLock { $0.height } }

    /// The pixel the server paints at a position: B, G, R, X.
    package static func pixel(x: Int, y: Int, generation: Int = 0) -> [UInt8] {
        [UInt8(truncatingIfNeeded: x &* 3 &+ generation), UInt8(truncatingIfNeeded: y &* 5), UInt8(truncatingIfNeeded: x ^ y), 0]
    }

    private static func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }
    private static func u32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }

    private static func rectangleHeader(x: Int, y: Int, width: Int, height: Int, encoding: Int32) -> Data {
        Data(u16(x) + u16(y) + u16(width) + u16(height) + u32(UInt32(bitPattern: encoding)))
    }

    /// A pixel of ``pixel(x:y:generation:)`` in 256 colours: three bits of red and green, two of blue.
    package static func lowColourValue(x: Int, y: Int, generation: Int = 0) -> UInt8 {
        reduce(pixel(x: x, y: y, generation: generation))
    }

    private static func reduce(_ pixel: [UInt8]) -> UInt8 {
        (pixel[2] & 0xe0) | ((pixel[1] >> 5) << 2) | (pixel[0] >> 6)
    }

    /// What a client shows for a pixel sent in 256 colours: B, G, R, each stretched back to 0–255.
    package static func lowColourPixel(x: Int, y: Int, generation: Int = 0) -> [UInt8] {
        let value = Int(lowColourValue(x: x, y: y, generation: generation))
        return [UInt8((value & 3) * 255 / 3), UInt8(((value >> 2) & 7) * 255 / 7), UInt8(((value >> 5) & 7) * 255 / 7)]
    }

    private static func encode(_ pixel: [UInt8], bitsPerPixel: Int) -> [UInt8] {
        bitsPerPixel == 8 ? [reduce(pixel)] : pixel
    }

    private static func rawRectangle(x: Int, y: Int, width: Int, height: Int, generation: Int, bitsPerPixel: Int = 32) -> Data {
        var data = rectangleHeader(x: x, y: y, width: width, height: height, encoding: 0)
        for row in y..<(y + height) {
            for column in x..<(x + width) {
                data.append(contentsOf: encode(pixel(x: column, y: row, generation: generation), bitsPerPixel: bitsPerPixel))
            }
        }
        return data
    }

    private static func update(_ rectangles: [Data]) -> Data {
        Data([0, 0] + u16(rectangles.count)) + rectangles.reduce(Data(), +)
    }

    private func raw(x: Int, y: Int, width: Int, height: Int, generation: Int) -> Data {
        let bitsPerPixel = wire.withLock { $0.bitsPerPixel }
        return Self.update([Self.rawRectangle(x: x, y: y, width: width, height: height, generation: generation, bitsPerPixel: bitsPerPixel)])
    }

    /// The whole desktop as one ZRLE rectangle of raw 64 × 64 tiles, in 32-bit pixels sent as three
    /// bytes, B, G, R. ZRLE's zlib stream lasts the whole connection, and this one starts it, so it
    /// is for the first update only.
    private func zrle(width: Int, height: Int) -> Data {
        var tiles = Data()
        for top in stride(from: 0, to: height, by: 64) {
            for left in stride(from: 0, to: width, by: 64) {
                tiles.append(0)
                for row in top..<min(top + 64, height) {
                    for column in left..<min(left + 64, width) { tiles.append(contentsOf: Self.pixel(x: column, y: row).prefix(3)) }
                }
            }
        }
        let compressed = Self.deflateFlushed(tiles)
        var rectangle = Self.rectangleHeader(x: 0, y: 0, width: width, height: height, encoding: 16)
        rectangle.append(contentsOf: Self.u32(UInt32(compressed.count)) + compressed)
        return Self.update([rectangle])
    }

    /// Writes a server message, noting whether it answers the outstanding requests.
    private func write(_ bytes: Data) async throws {
        if bytes.first == 0 { wire.withLock { $0.requestOutstanding = false } }
        try await end.write(bytes)
    }

    /// Queues something for the server to send at its next opportunity (the next update request).
    package func send(_ bytes: Data) {
        steps.withLock { $0.append(.bytes(bytes)) }
    }

    /// Sends what is queued at once rather than with the next request, as a server with something
    /// to say does.
    package func sendQueued() async throws {
        try await playSteps()
    }

    package func sendUpdate(x: Int, y: Int, width: Int, height: Int, generation: Int) {
        steps.withLock { $0.append(.update(x: x, y: y, width: width, height: height, generation: generation)) }
    }

    /// Changes part of the desktop as a real server sees it change: sent at once if the client has
    /// a request outstanding, otherwise in answer to its next one.
    package func paint(x: Int, y: Int, width: Int, height: Int, generation: Int) async throws {
        try await deliver(.update(x: x, y: y, width: width, height: height, generation: generation))
    }

    /// A new cursor shape as a RichCursor rectangle, in the client's pixel format, delivered as
    /// ``paint(x:y:width:height:generation:)`` is: `width` × `height` of the pixel at (1, 1), with
    /// its hotspot at (1, 2).
    package func changeCursor(width: Int, height: Int) async throws {
        let bitsPerPixel = wire.withLock { $0.bitsPerPixel }
        var rectangle = Self.rectangleHeader(x: 1, y: 2, width: width, height: height, encoding: -239)
        for _ in 0..<(width * height) { rectangle.append(contentsOf: Self.encode(Self.pixel(x: 1, y: 1), bitsPerPixel: bitsPerPixel)) }
        rectangle.append(Data(repeating: 0xff, count: (width + 7) / 8 * height))
        try await deliver(.bytes(Self.update([rectangle])))
    }

    private func deliver(_ step: Step) async throws {
        let now: Bool = wire.withLock { wire in
            guard wire.requestOutstanding else {
                wire.painted.append(step)
                return false
            }
            wire.requestOutstanding = false
            return true
        }
        if now { try await play([step]) }
    }

    package func sendBell() {
        send(Data([2]))
    }

    /// Classic cut text, the bytes as given.
    package func sendCutText(bytes: [UInt8]) {
        send(Data([3, 0, 0, 0] + Self.u32(UInt32(bytes.count)) + bytes))
    }

    package func sendCutText(_ text: String) {
        sendCutText(bytes: Array(text.utf8))
    }

    /// Tells the client the server's clipboard has text, as an extended-clipboard Notify; the text
    /// goes out when the client asks for it.
    package func announceClipboard(_ text: String) {
        serverClipboard.withLock { $0 = text }
        send(Self.extendedClipboardMessage(Self.u32(ExtendedClipboard.notify | ExtendedClipboard.text)))
    }

    /// Changes the desktop's size: a resize rectangle (ExtendedDesktopSize while the client asks for
    /// it and the server has it, DesktopSize otherwise), then the whole desktop at the new size.
    package func resize(width: Int, height: Int, generation: Int) {
        steps.withLock { $0.append(.resize(width: width, height: height, generation: generation)) }
    }

    /// An update of two rectangles, the first sent in two halves 200 ms apart, the second only once
    /// a key event arrives (or after two seconds). Records whether the key came in between.
    package func sendTwoRectanglesWaitingForInput(generation: Int) {
        let (width, height) = (self.width, self.height)
        let first = Self.rawRectangle(x: 0, y: 0, width: width, height: height / 2, generation: generation)
        let second = Self.rawRectangle(x: 0, y: height / 2, width: width, height: height - height / 2, generation: generation)
        let start = Data([0, 0] + Self.u16(2)) + first
        let half = start.count / 2
        steps.withLock {
            $0 += [.bytes(start.prefix(half)), .pause(.milliseconds(200)), .bytes(start.dropFirst(half)), .awaitKey(.seconds(2), then: second)]
        }
    }

    package func hangUp() async {
        await end.close()
    }

    /// Breaks the connection, as a network failure does.
    package func fail() async {
        await end.fail(URLError(.networkConnectionLost))
    }

    /// VNC authentication's response: the challenge DES-encrypted with the password, each key byte bit-reversed.
    package static func desResponse(challenge: Data, password: String) -> Data {
        var key = [UInt8](repeating: 0, count: 8)
        for (index, byte) in password.utf8.prefix(8).enumerated() {
            var reversed: UInt8 = 0
            for bit in 0..<8 where byte & (1 << bit) != 0 { reversed |= 0x80 >> bit }
            key[index] = reversed
        }
        var output = [UInt8](repeating: 0, count: 16)
        var moved = 0
        challenge.withUnsafeBytes { input in
            _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode), key, 8, nil, input.baseAddress, 16, &output, 16, &moved)
        }
        return Data(output)
    }

    private static func reason(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        return Data(u32(UInt32(bytes.count)) + bytes)
    }

    package func run() async throws {
        try await end.write(Data(version.utf8))
        let clientVersion = try await end.readExactly(12)
        guard clientVersion == Data("RFB 003.008\n".utf8) else { throw ScriptError.unexpected("client version \(String(decoding: clientVersion, as: UTF8.self))") }

        if case .beforeAuthentication(let text) = refusal {
            try await end.write(Data([0]) + Self.reason(text))
            await end.close()
            return
        }
        if let password {
            try await end.write(Data([1, 2]))
            guard try await end.readExactly(1) == Data([2]) else { throw ScriptError.unexpected("client did not pick VNC authentication") }
            let challenge = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })
            try await end.write(challenge)
            let response = try await end.readExactly(16)
            guard response == Self.desResponse(challenge: challenge, password: password) else {
                try await end.write(Data([0, 0, 0, 1]) + Self.reason(failureReason))
                await end.close()
                return
            }
        } else {
            try await end.write(Data([1, 1]))
            guard try await end.readExactly(1) == Data([1]) else { throw ScriptError.unexpected("client did not pick None") }
        }
        try await end.write(Data([0, 0, 0, 0]))

        let shared = try await end.readExactly(1)
        recorded.withLock { $0.shared = shared[0] != 0 }
        var initMessage = Data(Self.u16(width) + Self.u16(height))
        initMessage.append(contentsOf: [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        let name = Array("Scripted Desktop".utf8)
        initMessage.append(contentsOf: Self.u32(UInt32(name.count)) + name)
        try await end.write(initMessage)

        var sentFirstFrame = false
        while true {
            guard let type = try await end.read(upTo: 1)?.first else { return }
            if try await handle(type) {
                if !sentFirstFrame, width > 0, height > 0 {
                    sentFirstFrame = true
                    try await write(firstFrameInZRLE ? zrle(width: width, height: height) : raw(x: 0, y: 0, width: width, height: height, generation: 0))
                }
                try await playSteps()
            }
        }
    }

    /// Handles one client message. Returns true for an update request.
    private func handle(_ type: UInt8) async throws -> Bool {
        switch type {
        case 0:
            let body = try await end.readExactly(19)
            let bitsPerPixel = Int(body[3])
            guard bitsPerPixel == 32 || bitsPerPixel == 8 else { throw ScriptError.unexpected("\(bitsPerPixel) bits per pixel") }
            let outstanding = wire.withLock { wire in
                wire.bitsPerPixel = bitsPerPixel
                return wire.requestOutstanding
            }
            recorded.withLock { recorded in
                recorded.pixelFormats.append(bitsPerPixel)
                if outstanding { recorded.pixelFormatsWithRequestOutstanding += 1 }
            }
        case 2:
            let header = try await end.readExactly(3)
            let count = Int(header[1]) << 8 | Int(header[2])
            let body = try await end.readExactly(count * 4)
            let list = (0..<count).map { index -> Int32 in
                Int32(bitPattern: body[(index * 4)..<(index * 4 + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            }
            recorded.withLock { $0.encodingLists.append(list) }
            // As QEMU does: the current size, at once, whenever the client asks for ExtendedDesktopSize.
            if let id = extendedDesktopSizeScreenID, list.contains(-308) {
                try await end.write(extendedDesktopSize(width: width, height: height, screenID: id))
            }
            if offersExtendedClipboard, list.contains(ExtendedClipboard.encoding) {
                let flags = ExtendedClipboard.caps | ExtendedClipboard.text | ExtendedClipboard.request
                    | ExtendedClipboard.peek | ExtendedClipboard.notify | ExtendedClipboard.provide
                try await end.write(Self.extendedClipboardMessage(Self.u32(flags) + Self.u32(1 << 20)))
            }
        case 3:
            let body = try await end.readExactly(9)
            let wasOutstanding = wire.withLock { wire in
                defer { wire.requestOutstanding = true }
                return wire.requestOutstanding
            }
            recorded.withLock {
                $0.updateRequests += 1
                $0.incrementalRequests.append(body[0] != 0)
                if wasOutstanding { $0.requestsWhileOneWasOutstanding += 1 }
            }
            return true
        case 4:
            let body = try await end.readExactly(7)
            let keysym = body[3...6].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            recorded.withLock { $0.keys.append((keysym, body[0] != 0)) }
        case 5:
            let body = try await end.readExactly(5)
            recorded.withLock { $0.pointers.append((Int(body[1]) << 8 | Int(body[2]), Int(body[3]) << 8 | Int(body[4]), Int(body[0]))) }
        case 6:
            let header = try await end.readExactly(7)
            let length = Int32(bitPattern: header[3...6].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let payload = try await end.readExactly(Int(length.magnitude))
            if length < 0 {
                try await handleExtendedClipboard(payload)
            } else {
                recorded.withLock { $0.clipboard.append(String(decoding: payload, as: UTF8.self)) }
            }
        default:
            throw ScriptError.unexpected("client message type \(type)")
        }
        return false
    }

    private func handleExtendedClipboard(_ payload: Data) async throws {
        guard payload.count >= 4 else { throw ScriptError.unexpected("extended clipboard message of \(payload.count) bytes") }
        let flags = payload.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        if flags & ExtendedClipboard.caps != 0 {
            recorded.withLock { $0.clientClipboardCaps = flags }
        } else if flags & ExtendedClipboard.notify != 0 {
            recorded.withLock { $0.clientClipboardNotifies += 1 }
            if flags & ExtendedClipboard.text != 0 {
                try await end.write(Self.extendedClipboardMessage(Self.u32(ExtendedClipboard.request | ExtendedClipboard.text)))
            }
        } else if flags & ExtendedClipboard.request != 0 {
            guard let text = serverClipboard.withLock({ $0 }) else { return }
            // As the extended clipboard carries text: CR LF line ends and a terminating NUL.
            let bytes = Array(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) + [0]
            let compressed = Self.deflate(Data(Self.u32(UInt32(bytes.count)) + bytes))
            try await end.write(Self.extendedClipboardMessage(Self.u32(ExtendedClipboard.provide | ExtendedClipboard.text) + compressed))
        } else if flags & ExtendedClipboard.provide != 0 {
            let plain = Self.inflate(payload.dropFirst(4))
            guard plain.count >= 4 else { throw ScriptError.unexpected("provide without a length") }
            let length = Int(plain.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            recorded.withLock { $0.clipboard.append(String(decoding: plain.dropFirst(4).prefix(length), as: UTF8.self)) }
        }
    }

    private func extendedDesktopSize(width: Int, height: Int, screenID: UInt32) -> Data {
        var rectangle = Self.rectangleHeader(x: 0, y: 0, width: width, height: height, encoding: -308)
        rectangle.append(contentsOf: [1, 0, 0, 0])
        rectangle.append(contentsOf: Self.u32(screenID) + Self.u16(0) + Self.u16(0) + Self.u16(width) + Self.u16(height) + Self.u32(0))
        return Self.update([rectangle])
    }

    private func playSteps() async throws {
        let queued: [Step] = steps.withLock {
            defer { $0.removeAll() }
            return $0
        }
        let painted: [Step] = wire.withLock {
            defer { $0.painted.removeAll() }
            return $0.painted
        }
        try await play(queued + painted)
    }

    private func play(_ queued: [Step]) async throws {
        for step in queued {
            switch step {
            case .bytes(let bytes):
                try await write(bytes)
            case .update(let x, let y, let width, let height, let generation):
                try await write(raw(x: x, y: y, width: width, height: height, generation: generation))
            case .pause(let duration):
                try await Task.sleep(for: duration)
            case .awaitKey(let timeout, let then):
                let keysBefore = recorded.withLock { $0.keys.count }
                func keyArrived() -> Bool { recorded.withLock { $0.keys.count } > keysBefore }
                // Reads until the key comes, which is after the rest of the update if the client
                // holds input back until then.
                let reader = Task { [self] in
                    while !keyArrived() {
                        guard let type = try await end.read(upTo: 1)?.first else { return }
                        _ = try await handle(type)
                    }
                }
                let deadline = ContinuousClock.now + timeout
                while !keyArrived(), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let arrived = keyArrived()
                recorded.withLock { $0.inputArrivedBetweenRectangles = arrived }
                try await write(then)
                try await reader.value
            case .resize(let width, let height, let generation):
                desktop.withLock { $0 = Desktop(width: width, height: height) }
                let encodings = recorded.withLock { $0.encodings }
                if let id = extendedDesktopSizeScreenID, encodings.contains(-308) {
                    try await write(extendedDesktopSize(width: width, height: height, screenID: id))
                } else {
                    guard encodings.contains(-223) else { throw ScriptError.unexpected("the client cannot be resized") }
                    try await write(Self.update([Self.rectangleHeader(x: 0, y: 0, width: width, height: height, encoding: -223)]))
                }
                try await write(raw(x: 0, y: 0, width: width, height: height, generation: generation))
            }
        }
    }

    private static func extendedClipboardMessage(_ payload: [UInt8]) -> Data {
        extendedClipboardMessage(Data(payload))
    }

    private static func extendedClipboardMessage(_ payload: Data) -> Data {
        Data([3, 0, 0, 0] + u32(UInt32(bitPattern: -Int32(payload.count)))) + payload
    }

    private static func deflate(_ data: Data) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: Int(compressBound(uLong(data.count))))
        var length = uLongf(output.count)
        let bytes = [UInt8](data)
        _ = compress2(&output, &length, bytes, uLong(bytes.count), 6)
        return Array(output.prefix(Int(length)))
    }

    /// The start of a zlib stream holding `data`, ended with a sync flush rather than the stream's
    /// end, as ZRLE's stream, which lasts the whole connection, is sent.
    private static func deflateFlushed(_ data: Data) -> [UInt8] {
        var stream = z_stream()
        guard deflateInit_(&stream, 6, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return [] }
        defer { deflateEnd(&stream) }
        var input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: Int(compressBound(uLong(data.count))) + 64)
        let produced: Int = input.withUnsafeMutableBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                stream.next_in = input.baseAddress
                stream.avail_in = uInt(input.count)
                stream.next_out = output.baseAddress
                stream.avail_out = uInt(output.count)
                _ = zlib.deflate(&stream, Z_SYNC_FLUSH)
                return output.count - Int(stream.avail_out)
            }
        }
        return Array(output.prefix(produced))
    }

    /// Inflates a zlib stream that may end in a sync flush rather than the stream's end.
    private static func inflate(_ data: Data) -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Data() }
        defer { inflateEnd(&stream) }
        var input = [UInt8](data)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        input.withUnsafeMutableBufferPointer { input in
            stream.next_in = input.baseAddress
            stream.avail_in = uInt(input.count)
            repeat {
                let produced: Int = chunk.withUnsafeMutableBufferPointer { chunk in
                    stream.next_out = chunk.baseAddress
                    stream.avail_out = uInt(chunk.count)
                    let result = zlib.inflate(&stream, Z_SYNC_FLUSH)
                    guard result == Z_OK || result == Z_STREAM_END else { return -1 }
                    return chunk.count - Int(stream.avail_out)
                }
                guard produced > 0 else { break }
                output.append(contentsOf: chunk.prefix(produced))
            } while stream.avail_in > 0 || stream.avail_out == 0
        }
        return output
    }
}
