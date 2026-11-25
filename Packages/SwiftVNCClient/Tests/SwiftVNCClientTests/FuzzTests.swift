// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftVNCClient
import SwiftVNCClientTestSupport
import Synchronization
import Testing
import zlib

/// Well-formed server messages in every encoding LibVNCClient decodes, for a 64 × 48 desktop in the
/// 32-bit pixel format the client asks for.
private enum Messages {
    static func update(_ rectangles: [Data]) -> Data {
        Data([0, 0, UInt8(rectangles.count >> 8), UInt8(rectangles.count & 0xff)]) + rectangles.reduce(Data(), +)
    }

    static func header(_ x: Int, _ y: Int, _ w: Int, _ h: Int, encoding: Int32) -> Data {
        var data = Data()
        for value in [x, y, w, h] { data.append(contentsOf: [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]) }
        let e = UInt32(bitPattern: encoding)
        data.append(contentsOf: [UInt8(e >> 24), UInt8(e >> 16 & 0xff), UInt8(e >> 8 & 0xff), UInt8(e & 0xff)])
        return data
    }

    static func u32(_ value: Int) -> Data { Data([UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]) }
    static func u16(_ value: Int) -> Data { Data([UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]) }
    static func pixel(_ seed: Int) -> Data { Data([UInt8(truncatingIfNeeded: seed), UInt8(truncatingIfNeeded: seed * 3), UInt8(truncatingIfNeeded: seed * 7), 0]) }

    static func deflate(_ data: Data) -> Data {
        var output = [UInt8](repeating: 0, count: Int(compressBound(uLong(data.count))))
        var length = uLongf(output.count)
        let bytes = [UInt8](data)
        _ = compress2(&output, &length, bytes, uLong(bytes.count), 6)
        return Data(output.prefix(Int(length)))
    }

    /// Concatenates parts without one long `+` chain, which the type checker gives up on.
    static func join(_ parts: [Data]) -> Data {
        var data = Data()
        for part in parts { data.append(part) }
        return data
    }

    static func pixels(_ count: Int) -> Data { join((0..<count).map { pixel($0) }) }

    static func counted(_ body: Data) -> Data { join([u32(body.count), body]) }

    static let all: [Data] = {
        var messages: [Data] = []
        messages.append(update([join([header(0, 0, 8, 4, encoding: 0), pixels(32)])]))
        messages.append(update([join([header(10, 10, 8, 8, encoding: 1), u16(0), u16(0)])]))
        messages.append(update([join([
            header(0, 0, 16, 16, encoding: 2), u32(2), pixel(1),
            pixel(2), u16(1), u16(1), u16(4), u16(4),
            pixel(3), u16(5), u16(5), u16(3), u16(3),
        ])]))
        messages.append(update([join([header(0, 0, 16, 16, encoding: 4), u32(1), pixel(1), pixel(9), Data([2, 2, 5, 5])])]))
        messages.append(update([join([
            header(0, 0, 32, 16, encoding: 5),
            Data([1]), pixels(256),
            Data([2]), pixel(4), Data([8, 2, 0x11, 0x33, 0x22, 0x44]),
        ])]))
        messages.append(update([join([header(0, 0, 16, 8, encoding: 6), counted(deflate(pixels(128)))])]))
        // ZRLE: one solid tile (subencoding 1 and a three-byte pixel), then a raw one.
        var tiles = Data([1, 10, 20, 30, 0])
        tiles.append(Data((0..<(64 * 48 * 3)).map { UInt8(truncatingIfNeeded: $0) }))
        messages.append(update([join([header(0, 0, 64, 48, encoding: 16), counted(deflate(tiles))])]))
        messages.append(update([join([header(0, 0, 8, 8, encoding: 9), counted(Data(repeating: 0x11, count: 12))])]))
        messages.append(update([join([header(2, 3, 8, 8, encoding: -239), pixels(64), Data(repeating: 0xf0, count: 8)])]))
        messages.append(update([join([header(1, 1, 8, 8, encoding: -240), Data([255, 255, 255, 0, 0, 0]), Data(repeating: 0xaa, count: 8), Data(repeating: 0x55, count: 8)])]))
        messages.append(update([header(0, 0, 80, 60, encoding: -223)]))
        messages.append(update([join([header(0, 0, 70, 50, encoding: -308), Data([1, 0, 0, 0]), u32(1), u16(0), u16(0), u16(70), u16(50), u32(0)])]))
        messages.append(update([header(5, 5, 0, 0, encoding: -232), header(0, 0, 0, 0, encoding: -224)]))
        messages.append(join([Data([3, 0, 0, 0]), counted(Data("hello".utf8))]))
        // Extended clipboard: a negative length, then flags and what they carry: Provide (text,
        // deflated), Caps (text, with its size), Notify, Request and Peek.
        func extendedClipboard(_ payload: Data) -> Data {
            join([Data([3, 0, 0, 0]), u32(Int(UInt32(bitPattern: -Int32(payload.count)))), payload])
        }
        messages.append(extendedClipboard(join([Data([0x10, 0, 0, 1]), deflate(join([u32(6), Data("hello\0".utf8)]))])))
        messages.append(extendedClipboard(join([Data([0x1f, 0, 0, 1]), u32(1 << 20)])))
        messages.append(extendedClipboard(Data([0x08, 0, 0, 1])))
        messages.append(extendedClipboard(Data([0x02, 0, 0, 1])))
        messages.append(extendedClipboard(Data([0x04, 0, 0, 0])))
        // Tight: a solid fill, then a JPEG rectangle.
        messages.append(update([join([header(0, 0, 8, 8, encoding: 7), Data([0x80, 10, 20, 30])])]))
        if let jpeg = VNCClientTests.jpeg(width: 16, height: 8, red: 9, green: 99, blue: 199) {
            messages.append(update([join([header(4, 4, 16, 8, encoding: 7), Data([0x90, UInt8(jpeg.count & 0x7f | 0x80), UInt8(jpeg.count >> 7)]), jpeg])]))
        }
        messages.append(Data([2]))
        messages.append(join([Data([1, 0]), u16(0), u16(2), Data(repeating: 0x80, count: 12)]))
        return messages
    }()
}

private func damage(_ data: Data, _ generator: inout some RandomNumberGenerator) -> Data {
    var bytes = [UInt8](data)
    for _ in 0..<Int.random(in: 1...8, using: &generator) {
        guard !bytes.isEmpty else { break }
        let index = Int.random(in: 0..<bytes.count, using: &generator)
        switch Int.random(in: 0..<5, using: &generator) {
        case 0: bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        case 1: bytes.remove(at: index)
        case 2: bytes.insert(UInt8.random(in: .min ... .max, using: &generator), at: index)
        case 3: bytes.removeSubrange(index...)
        default: for offset in index..<min(bytes.count, index + Int.random(in: 1...4, using: &generator)) { bytes[offset] = 0xff }
        }
    }
    return Data(bytes)
}

/// SplitMix64, so a failing case can be found again.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// LibVNCClient is C, parsing whatever a server sends. Run under AddressSanitizer
/// (`swift test --sanitize=address --filter VNCFuzzTests`) to turn a quiet overrun into a failure.
@Suite(.serialized) struct VNCFuzzTests {
    /// One connection: the handshake, the first picture, then `payload` as the server's next
    /// messages, then a hang-up. The client must end, and end without crashing.
    private func run(_ payload: Data) async throws {
        let (clientEnd, serverEnd) = PipeEnd.pair()
        let server = ScriptedServer(end: serverEnd)
        let serving = Task { try? await server.run() }
        let ended = Mutex(false)
        let updated = Mutex(false)
        var handlers = VNCHandlers()
        handlers.updated = { _, _ in updated.withLock { $0 = true } }
        handlers.disconnected = { _ in ended.withLock { $0 = true } }
        let client = VNCClient(transport: clientEnd, configuration: VNCConfiguration(), handlers: handlers)
        _ = try await client.connect()
        let start = ContinuousClock.now
        while !updated.withLock({ $0 }), ContinuousClock.now - start < .seconds(3) { try await Task.sleep(for: .milliseconds(2)) }
        server.send(payload)
        client.requestFullUpdate()
        try await Task.sleep(for: .milliseconds(30))
        await server.hangUp()
        let deadline = ContinuousClock.now + .seconds(5)
        while !ended.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ended.withLock { $0 }, "the client did not end after the server hung up")
        client.disconnect()
        serving.cancel()
    }

    @Test func wellFormedMessagesAreAllHandled() async throws {
        for message in Messages.all { try await run(message) }
        try await run(Messages.all.reduce(Data(), +))
    }

    @Test(arguments: 0..<6)
    func damagedMessagesNeverCrashTheClient(batch: Int) async throws {
        var generator = Seeded(state: UInt64(1000 + batch))
        for _ in 0..<60 {
            var payload = Data()
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                payload.append(damage(Messages.all.randomElement(using: &generator)!, &generator))
            }
            try await run(payload)
        }
    }

    @Test func randomBytesNeverCrashTheClient() async throws {
        var generator = Seeded(state: 77)
        for _ in 0..<100 {
            try await run(Data((0..<Int.random(in: 1...300, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }))
        }
    }
}
