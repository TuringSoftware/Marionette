// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
import ARDTestSupport
import Foundation
import Testing

@Suite struct WireReaderTests {
    @Test func readsBigEndianFields() throws {
        var reader = WireReader(Data(hex: "01 0203 04050607 08090a0b0c0d0e0f fffe 4000000000000000"))
        #expect(try reader.u8() == 0x01)
        #expect(try reader.u16() == 0x0203)
        #expect(try reader.u32() == 0x0405_0607)
        #expect(try reader.u64() == 0x0809_0a0b_0c0d_0e0f)
        #expect(try reader.i16() == -2)
        #expect(try reader.f64() == 2.0)
        #expect(reader.isAtEnd)
    }

    @Test func truncationReportsTotalNeededFromStart() {
        var reader = WireReader(Data([1, 2, 3]))
        #expect(throws: WireError.truncated(needed: 4)) { try reader.u32() }
        #expect(reader.offset == 0)
        var second = WireReader(Data([1, 2, 3]))
        _ = try? second.u16()
        #expect(throws: WireError.truncated(needed: 2 + 100)) { try second.take(100) }
    }

    @Test func worksOnSlicesWithNonZeroStartIndex() throws {
        let whole = Data([0xAA, 0xBB, 0x00, 0x2A, 0xCC])
        var reader = WireReader(whole[2...])
        #expect(try reader.u16() == 42)
        #expect(try reader.take(1) == Data([0xCC]))
        #expect(reader.isAtEnd)
    }

    @Test func subReaderIsBoundedToItsLength() throws {
        var reader = WireReader(Data([0, 2, 0xAA, 0xBB, 0xCC]))
        var inner = try reader.sub(Int(try reader.u16()))
        #expect(inner.isBounded)
        #expect(try inner.u16() == 0xAABB)
        // The field's end is final: no amount of further input can make this read succeed, so it
        // must not ask for more.
        #expect(throws: WireError.malformed("a field runs 1 bytes past the end of its 2-byte message")) { try inner.u8() }
        #expect(try reader.u8() == 0xCC)
    }

    @Test func shortFieldInAFramedBodyDoesNotStallTheBuffer() throws {
        // A 0x455 keyboard-source rectangle whose name length runs past its own 4-byte body, followed
        // by a bell. An unbounded sub-reader would wait for ever for the name.
        var buffer = InboundBuffer()
        var parser = ServerMessageParser()
        buffer.append(ServerBytes.update([
            ServerBytes.rectangle(encoding: .appleKeyboardSource, body: ServerBytes.counted16(Data(hex: "0001 0000"))),
        ]) + Data([0x02]))
        #expect(try parser.next(from: &buffer) == .updateBegan(rectangleCount: 1))
        guard case .rectangle(let rectangle) = try parser.next(from: &buffer), case .unusable = rectangle.body else {
            Issue.record("expected the keyboard source to be stepped over")
            return
        }
        #expect(try parser.next(from: &buffer) == .updateEnded)
        #expect(try parser.next(from: &buffer) == .bell)
        #expect(buffer.isEmpty)
    }

    @Test func writerMirrorsReader() throws {
        var writer = WireWriter()
        writer.u8(7)
        writer.u16(0xBEEF)
        writer.i32(-5)
        writer.f64(1.5)
        writer.pad(to: 20)
        var reader = WireReader(writer.data)
        #expect(try reader.u8() == 7)
        #expect(try reader.u16() == 0xBEEF)
        #expect(try reader.i32() == -5)
        #expect(try reader.f64() == 1.5)
        #expect(reader.remaining == 5)
    }
}

@Suite struct InboundBufferTests {
    @Test func consumesOnlyOnSuccess() throws {
        var buffer = InboundBuffer()
        buffer.append(Data([0x00]))
        let first = try buffer.parse { (reader: inout WireReader) throws(WireError) in try reader.u16() }
        #expect(first == nil)
        #expect(buffer.count == 1)
        buffer.append(Data([0x05, 0xFF]))
        let second = try buffer.parse { (reader: inout WireReader) throws(WireError) in try reader.u16() }
        #expect(second == 5)
        #expect(buffer.count == 1)
    }

    @Test func doesNotRetryUntilEnoughBytesArrive() throws {
        var buffer = InboundBuffer()
        var attempts = 0
        func attempt() throws -> Data? {
            try buffer.parse { (reader: inout WireReader) throws(WireError) -> Data in
                attempts += 1
                return try reader.take(Int(try reader.u32()))
            }
        }
        buffer.append(Data([0, 0, 0, 100]))
        #expect(try attempt() == nil)
        #expect(attempts == 1)
        for _ in 0..<99 {
            buffer.append(Data([1]))
            #expect(try attempt() == nil)
        }
        #expect(attempts == 1)
        buffer.append(Data([1]))
        #expect(try attempt()?.count == 100)
        #expect(attempts == 2)
        #expect(buffer.isEmpty)
    }

    @Test func malformedPropagatesAndConsumesNothing() {
        var buffer = InboundBuffer()
        buffer.append(Data([9, 9]))
        #expect(throws: WireError.malformed("bad")) {
            _ = try buffer.parse { (_: inout WireReader) throws(WireError) -> Int in throw .malformed("bad") }
        }
        #expect(buffer.count == 2)
    }

    @Test func drainReturnsUnconsumedBytes() throws {
        var buffer = InboundBuffer()
        buffer.append(Data([1, 2, 3, 4]))
        _ = try buffer.parse { (reader: inout WireReader) throws(WireError) in try reader.u8() }
        #expect(buffer.drain() == Data([2, 3, 4]))
        #expect(buffer.isEmpty)
    }

    @Test func survivesManyMessagesInOneLargeAppend() throws {
        var buffer = InboundBuffer()
        var stream = Data()
        for index in 0..<50_000 { stream.append(contentsOf: [0x00, 0x02, UInt8(index & 0xff), UInt8(index >> 8 & 0xff)]) }
        buffer.append(stream)
        var count = 0
        while let payload = try buffer.parse({ (reader: inout WireReader) throws(WireError) in try reader.take(Int(try reader.u16())) }) {
            #expect(payload == Data([UInt8(count & 0xff), UInt8(count >> 8 & 0xff)]))
            count += 1
        }
        #expect(count == 50_000)
    }
}
