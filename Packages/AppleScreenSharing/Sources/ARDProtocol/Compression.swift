// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
import zlib

public enum CompressionError: Error, Sendable, Equatable {
    case corrupt(String)
    /// The data inflates to more than the caller allowed.
    case tooLarge(limit: Int)
    /// The stream ended before producing the bytes the caller required.
    case tooShort(expected: Int, actual: Int)
}

/// A zlib inflater that lives as long as the stream it reads.
///
/// RFB's zlib and ZRLE encodings each use one deflate stream for the whole session: every rectangle
/// is the next chunk, and later chunks refer back to earlier ones. Not thread-safe.
public final class InflateStream {
    private let stream: UnsafeMutablePointer<z_stream>
    private var isOpen = false

    public init() {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        open()
    }

    deinit {
        if isOpen { inflateEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    private func open() {
        stream.pointee = z_stream()
        isOpen = inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    }

    /// Discards all history. The next chunk must start a new zlib stream.
    public func reset() {
        if isOpen { inflateEnd(stream) }
        open()
    }

    /// Inflates the next chunk into exactly `expected` bytes.
    ///
    /// The output grows as data comes out rather than being allocated up front: `expected` comes from
    /// a header the peer wrote, and a small chunk must not make this allocate gigabytes.
    public func inflate(_ chunk: Data, expecting expected: Int) throws(CompressionError) -> Data {
        guard expected >= 0 else { throw .tooShort(expected: expected, actual: 0) }
        var output = Data(count: min(expected, max(4096, chunk.count * 8)))
        let written = try run(chunk, into: &output, growTo: expected)
        output.removeSubrange(written..<output.count)
        guard written == expected else { throw .tooShort(expected: expected, actual: written) }
        return output
    }

    /// Inflates the next chunk, however long it turns out to be, up to `limit` bytes.
    public func inflate(_ chunk: Data, limit: Int) throws(CompressionError) -> Data {
        var output = Data(count: min(limit, max(1024, chunk.count * 4)))
        let written = try run(chunk, into: &output, growTo: limit)
        output.removeSubrange(written..<output.count)
        return output
    }

    private func run(_ chunk: Data, into output: inout Data, growTo limit: Int) throws(CompressionError) -> Int {
        guard isOpen else { throw .corrupt("inflater failed to initialise") }
        var written = 0
        var failure: CompressionError?
        chunk.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.pointee.avail_in = uInt(input.count)
            while failure == nil {
                if written == output.count {
                    if stream.pointee.avail_in == 0 { break }
                    guard output.count < limit else {
                        failure = .tooLarge(limit: limit)
                        break
                    }
                    output.count = min(limit, max(output.count * 2, 4096))
                }
                let capacity = output.count
                let status: Int32 = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                    stream.pointee.next_out = out.bindMemory(to: Bytef.self).baseAddress! + written
                    stream.pointee.avail_out = uInt(capacity - written)
                    return zlib.inflate(stream, Z_SYNC_FLUSH)
                }
                written = capacity - Int(stream.pointee.avail_out)
                switch status {
                case Z_OK:
                    // Out of input with room to spare: this chunk is finished.
                    if stream.pointee.avail_in == 0, stream.pointee.avail_out > 0 { return }
                case Z_STREAM_END:
                    return
                case Z_BUF_ERROR:
                    // No progress possible: input exhausted, or output full (handled at loop top).
                    if stream.pointee.avail_in == 0 { return }
                default:
                    let message = stream.pointee.msg.map { String(cString: $0) } ?? "zlib error \(status)"
                    failure = .corrupt(message)
                }
            }
        }
        stream.pointee.next_in = nil
        stream.pointee.avail_in = 0
        stream.pointee.next_out = nil
        stream.pointee.avail_out = 0
        if let failure {
            // A failed stream has no usable history; do not let later chunks decode against it.
            reset()
            throw failure
        }
        return written
    }

    /// Inflates a complete, self-contained zlib stream.
    public static func inflateWhole(_ data: Data, limit: Int) throws(CompressionError) -> Data {
        try InflateStream().inflate(data, limit: limit)
    }
}

public enum Deflate {
    /// Compresses `data` as a zlib stream that is flushed but not ended: no final block and no
    /// checksum trailer. This is how a Mac frames pasteboard archives, and its inflater rejects a
    /// stream that ends.
    public static func compressSyncFlushed(_ data: Data, level: Int32 = Z_BEST_COMPRESSION) -> Data {
        var stream = z_stream()
        guard deflateInit_(&stream, level, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Data() }
        defer { deflateEnd(&stream) }
        // A sync flush adds a few bytes beyond the ordinary bound.
        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))) + 64)
        let capacity = output.count
        let produced: Int = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                let status = deflate(&stream, Z_SYNC_FLUSH)
                precondition(status == Z_OK && stream.avail_in == 0, "deflate cannot stall with a buffer of deflateBound size")
                return capacity - Int(stream.avail_out)
            }
        }
        output.removeSubrange(produced..<output.count)
        return output
    }

    /// Compresses `data` as one complete zlib stream.
    public static func compress(_ data: Data, level: Int32 = Z_BEST_COMPRESSION) -> Data {
        var length = compressBound(uLong(data.count))
        var output = Data(count: Int(length))
        let status: Int32 = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                compress2(
                    out.bindMemory(to: Bytef.self).baseAddress, &length,
                    input.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), level
                )
            }
        }
        precondition(status == Z_OK, "compress2 cannot fail with a buffer of compressBound size")
        output.removeSubrange(Int(length)..<output.count)
        return output
    }
}
