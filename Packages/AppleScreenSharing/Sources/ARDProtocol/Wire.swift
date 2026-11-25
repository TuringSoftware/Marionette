// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation

/// Why bytes from the peer could not be read as a message.
public enum WireError: Error, Sendable, Equatable {
    /// More bytes are required. `needed` is the smallest total length, counted from where parsing
    /// of this message began, at which another attempt can make progress.
    case truncated(needed: Int)
    /// The bytes can never be a valid message, however many more arrive.
    case malformed(String)
}

/// Reads big-endian fields from a byte sequence, refusing to read past its end.
///
/// Every length taken from the wire goes through ``take(_:)`` or ``skip(_:)``, which bound it against
/// what is actually present, so a hostile length cannot cause an out-of-bounds read or a huge
/// allocation: a claim that exceeds the bytes at hand is ``WireError/truncated(needed:)``, and callers
/// cap how much they are willing to wait for.
///
/// A reader made by ``sub(_:)`` is *bounded*: its end is the end of a length-framed field, not the end
/// of what has arrived so far, so reading past it is ``WireError/malformed(_:)``. Were it
/// `.truncated`, the inbound buffer would wait for bytes that can never change the outcome, and the
/// stream would stall behind that one message for good.
public struct WireReader {
    public let data: Data
    /// Offset of the first byte of this reader's view within `data`.
    public let start: Int
    /// Bytes consumed so far, relative to `start`.
    public private(set) var offset = 0
    /// True when the end of `data` is the end of a framed field rather than of the bytes received.
    public let isBounded: Bool

    public init(_ data: Data) {
        self.init(data, bounded: false)
    }

    private init(_ data: Data, bounded: Bool) {
        self.data = data
        start = data.startIndex
        isBounded = bounded
    }

    public var remaining: Int { data.endIndex - start - offset }
    public var isAtEnd: Bool { remaining == 0 }

    private mutating func require(_ count: Int) throws(WireError) {
        guard count >= 0 else { throw .malformed("negative length") }
        guard count <= remaining else {
            if isBounded { throw .malformed("a field runs \(count - remaining) bytes past the end of its \(data.count)-byte message") }
            throw .truncated(needed: offset + count)
        }
    }

    public mutating func u8() throws(WireError) -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return data[start + offset]
    }

    public mutating func u16() throws(WireError) -> UInt16 {
        try require(2)
        defer { offset += 2 }
        let base = start + offset
        return UInt16(data[base]) << 8 | UInt16(data[base + 1])
    }

    public mutating func u32() throws(WireError) -> UInt32 {
        try require(4)
        defer { offset += 4 }
        let base = start + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    public mutating func u64() throws(WireError) -> UInt64 {
        let high = try u32()
        let low = try u32()
        return UInt64(high) << 32 | UInt64(low)
    }

    public mutating func i16() throws(WireError) -> Int16 {
        Int16(bitPattern: try u16())
    }

    public mutating func i32() throws(WireError) -> Int32 {
        Int32(bitPattern: try u32())
    }

    public mutating func f64() throws(WireError) -> Double {
        Double(bitPattern: try u64())
    }

    /// The next `count` bytes, copied out.
    public mutating func take(_ count: Int) throws(WireError) -> Data {
        try require(count)
        defer { offset += count }
        let base = start + offset
        return data.subdata(in: base..<(base + count))
    }

    public mutating func skip(_ count: Int) throws(WireError) {
        try require(count)
        offset += count
    }

    /// A bounded reader over the next `count` bytes, which are consumed from this one.
    public mutating func sub(_ count: Int) throws(WireError) -> WireReader {
        WireReader(try take(count), bounded: true)
    }

    /// Everything left, copied out.
    public mutating func rest() -> Data {
        // `remaining` bytes are always present.
        (try? take(remaining)) ?? Data()
    }
}

/// Builds a message from big-endian fields.
public struct WireWriter {
    public private(set) var data: Data

    public init(capacity: Int = 64) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    public var count: Int { data.count }

    public mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    public mutating func u16(_ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    public mutating func u32(_ value: UInt32) {
        u16(UInt16(value >> 16))
        u16(UInt16(truncatingIfNeeded: value))
    }

    public mutating func u64(_ value: UInt64) {
        u32(UInt32(value >> 32))
        u32(UInt32(truncatingIfNeeded: value))
    }

    public mutating func i16(_ value: Int16) {
        u16(UInt16(bitPattern: value))
    }

    public mutating func i32(_ value: Int32) {
        u32(UInt32(bitPattern: value))
    }

    public mutating func f32(_ value: Float) {
        u32(value.bitPattern)
    }

    public mutating func f64(_ value: Double) {
        u64(value.bitPattern)
    }

    public mutating func bytes(_ bytes: some Sequence<UInt8>) {
        data.append(contentsOf: bytes)
    }

    public mutating func zeros(_ count: Int) {
        data.append(Data(count: count))
    }

    /// Pads with zeros up to `length` total bytes. Does nothing if already that long.
    public mutating func pad(to length: Int) {
        if data.count < length { zeros(length - data.count) }
    }
}

/// Accumulates bytes from the transport and lets a parser consume whole messages from the front.
public struct InboundBuffer: Sendable {
    private var storage = Data()
    private var consumed = 0
    /// Do not retry parsing until at least this many unconsumed bytes are present.
    private var wanted = 0

    public init() {}

    public var count: Int { storage.count - consumed }
    public var isEmpty: Bool { count == 0 }

    public mutating func append(_ data: Data) {
        storage.append(data)
    }

    /// Runs `parse` on the unconsumed bytes. On success the bytes it read are consumed. If it needs
    /// more bytes, nothing is consumed and `nil` is returned; the attempt is not repeated until
    /// enough have arrived, so a message that trickles in is not re-parsed for every chunk.
    public mutating func parse<T>(_ parse: (inout WireReader) throws(WireError) -> T) throws(WireError) -> T? {
        guard count >= wanted else { return nil }
        // A slice shares storage with the buffer, so an attempt costs nothing to set up. It is gone
        // before the buffer is next mutated.
        var reader = WireReader(storage[(storage.startIndex + consumed)..<storage.endIndex])
        do {
            let value = try parse(&reader)
            consumed += reader.offset
            wanted = 0
            compactIfWorthwhile()
            return value
        } catch .truncated(let needed) {
            wanted = max(needed, count + 1)
            return nil
        }
    }

    /// Removes and returns every unconsumed byte.
    public mutating func drain() -> Data {
        defer {
            storage = Data()
            consumed = 0
            wanted = 0
        }
        return storage.subdata(in: (storage.startIndex + consumed)..<storage.endIndex)
    }

    private mutating func compactIfWorthwhile() {
        if consumed == storage.count {
            storage.removeAll(keepingCapacity: true)
            consumed = 0
        } else if consumed > 1 << 16, consumed > storage.count / 2 {
            storage = storage.subdata(in: (storage.startIndex + consumed)..<storage.endIndex)
            consumed = 0
        }
    }
}
