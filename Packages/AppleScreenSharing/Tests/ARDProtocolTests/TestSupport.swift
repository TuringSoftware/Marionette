// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
import ARDTestSupport
import Foundation

/// Parses every event out of `stream` when it arrives in the given chunk sizes.
func events(in stream: Data, chunkSizes: some Sequence<Int>) throws -> [ServerEvent] {
    var parser = ServerMessageParser()
    var buffer = InboundBuffer()
    var result: [ServerEvent] = []
    var offset = stream.startIndex
    var sizes = chunkSizes.makeIterator()
    while true {
        while let event = try parser.next(from: &buffer) { result.append(event) }
        guard offset < stream.endIndex else { break }
        let size = max(1, sizes.next() ?? stream.count)
        let end = Swift.min(stream.endIndex, offset + size)
        buffer.append(stream.subdata(in: offset..<end))
        offset = end
    }
    return result
}

/// Builders for server-side bytes, used only to exercise the parser.
enum ServerBytes {
    static func update(_ rectangles: [Data]) -> Data {
        var writer = WireWriter()
        writer.u8(0)
        writer.u8(0)
        writer.u16(UInt16(rectangles.count))
        for rectangle in rectangles { writer.bytes(rectangle) }
        return writer.data
    }

    static func rectangle(x: UInt16 = 0, y: UInt16 = 0, width: UInt16 = 0, height: UInt16 = 0, encoding: Encoding, body: Data = Data()) -> Data {
        var writer = WireWriter()
        writer.u16(x)
        writer.u16(y)
        writer.u16(width)
        writer.u16(height)
        writer.i32(encoding.rawValue)
        writer.bytes(body)
        return writer.data
    }

    static func counted32(_ payload: Data) -> Data {
        var writer = WireWriter()
        writer.u32(UInt32(payload.count))
        writer.bytes(payload)
        return writer.data
    }

    static func counted16(_ payload: Data) -> Data {
        var writer = WireWriter()
        writer.u16(UInt16(payload.count))
        writer.bytes(payload)
        return writer.data
    }

    static func status(_ status: MiscStatus) -> Data {
        Data([0x14, 0x00, 0x00, 0x04, 0x00, 0x01, UInt8(status.rawValue >> 8), UInt8(status.rawValue & 0xff)])
    }

    /// `0x15`, whose fields are little-endian: feature 1, message 2, reply to 3, payload "ax".
    static let accessibility = Data(hex: "15 01000000 02000000 03000000 0200 6178")
    /// `0x23` with eight bytes after the fixed part.
    static let userRequest = Data(hex: "23 00 0016 0001 00000007 00000001 00000002 0102030405060708")
    /// `0x23` whose length is under the fixed part, which is read anyway.
    static let shortUserRequest = Data(hex: "23 00 0004 0001 00000009 00000000 00000000")
    static let systemInfoText = "<plist><dict><key>model</key><string>Mac</string></dict></plist>"
    static let systemInfoPayload = Deflate.compress(Data(systemInfoText.utf8))
    /// `0x51` with a compressed payload.
    static let systemInfo: Data = {
        var writer = WireWriter()
        writer.u8(0x51)
        writer.u8(0)
        writer.u32(UInt32(18 + systemInfoPayload.count))
        writer.u16(1)
        writer.u32(9)
        writer.u32(1)
        writer.u32(UInt32(systemInfoText.utf8.count))
        writer.u32(UInt32(systemInfoPayload.count))
        writer.bytes(systemInfoPayload)
        return writer.data
    }()

    struct Screen {
        var id: UInt32
        var density: Double
        var scale: Double = 1
        var points: (top: Int16, left: Int16, bottom: Int16, right: Int16)
        var pixels: (top: Int16, left: Int16, bottom: Int16, right: Int16)
        var flags: UInt32 = 1
    }

    static func layout(framebuffer: (UInt16, UInt16), current: UInt32?, flags: UInt32, screens: [Screen], declaredCount: UInt16? = nil) -> Data {
        var writer = WireWriter()
        writer.u16(5)
        writer.u16(UInt16(screens.reduce(0) { $0 + Int($1.points.right - $1.points.left) }))
        writer.u16(UInt16(screens.map { Int($0.points.bottom - $0.points.top) }.max() ?? 0))
        writer.u16(framebuffer.0)
        writer.u16(framebuffer.1)
        writer.u32(current ?? .max)
        writer.u32(flags)
        writer.u16(declaredCount ?? UInt16(screens.count))
        for screen in screens {
            writer.f64(screen.density)
            writer.f64(screen.scale)
            writer.u32(screen.id)
            for edge in [screen.points.top, screen.points.left, screen.points.bottom, screen.points.right] { writer.i16(edge) }
            for edge in [screen.pixels.top, screen.pixels.left, screen.pixels.bottom, screen.pixels.right] { writer.i16(edge) }
            writer.u32(screen.flags)
            PixelFormat.bgrx.write(to: &writer)
        }
        return writer.data
    }
}
