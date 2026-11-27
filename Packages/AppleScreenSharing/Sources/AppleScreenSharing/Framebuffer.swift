// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
public import CoreVideo
public import Foundation
public import RemoteDesktopCore

/// The picture of a Standard-mode session: the Mac's framebuffer, kept up to date from rectangles.
///
/// Pixels are stored as the Mac sends them, four bytes each in B, G, R, X order. Not thread-safe.
public final class Framebuffer {
    public private(set) var size: PixelSize
    private var storage: UnsafeMutableRawBufferPointer
    private let zlibStream = InflateStream()
    /// Adaptive quality's tiles are coded against the picture already here, so their decoder
    /// paints straight onto these pixels and lives as long as they do.
    private var adaptive = AdaptiveTileDecoder()
    /// The tile decoder keeps a record per 8 × 8 tile, about 40 % of the pixels' own size; it is
    /// sized for the picture only once Adaptive quality is used.
    private var isAdaptiveSized = false
    /// Where snapshots are made: reused buffers, no more than ``snapshotsInFlight`` of a size at
    /// once. Told of every change to the pixels, so that a snapshot copies only what its buffer lacks.
    private var snapshotBuffers = SnapshotBuffers()

    /// How many snapshots of one size may exist at once. With that many still in use a snapshot is
    /// refused; the caller tries again with the next update.
    public static let snapshotsInFlight = SnapshotBuffers.defaultLimit

    public enum UpdateError: Error, Sendable, Equatable {
        case outOfBounds(PixelRect)
        case wrongPayloadSize(expected: Int, actual: Int)
        case compression(CompressionError)
        case adaptive(AdaptiveTileDecoder.Failure)
    }

    public init(size: PixelSize) {
        self.size = size
        storage = Self.allocate(size)
    }

    /// The most bytes of picture this device should hold: a sixteenth of its memory (256 MB with
    /// 4 GB), beyond which iOS would end the app before the picture was worth having.
    public static var byteBudget: Int { Int(clamping: ProcessInfo.processInfo.physicalMemory / 16) }

    deinit {
        storage.deallocate()
    }

    private static func allocate(_ size: PixelSize) -> UnsafeMutableRawBufferPointer {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, size.width * size.height * 4), alignment: 64)
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        return buffer
    }

    /// Replaces the framebuffer with a black one of a new size. The session's zlib stream is the
    /// connection's, not the framebuffer's, so its history is kept.
    public func resize(to newSize: PixelSize) {
        guard newSize != size else { return }
        snapshotBuffers.removeAll()
        storage.deallocate()
        size = newSize
        storage = Self.allocate(newSize)
        if isAdaptiveSized { adaptive.resize(width: newSize.width, height: newSize.height) }
    }

    /// Applies uncompressed pixels to `rect`.
    public func write(_ pixels: Data, to rect: PixelRect) throws(UpdateError) {
        guard rect.x >= 0, rect.y >= 0, rect.maxX <= size.width, rect.maxY <= size.height else {
            throw .outOfBounds(rect)
        }
        guard pixels.count == rect.area * 4 else {
            throw .wrongPayloadSize(expected: rect.area * 4, actual: pixels.count)
        }
        guard !rect.isEmpty else { return }
        let rowBytes = rect.width * 4
        let stride = size.width * 4
        pixels.withUnsafeBytes { source in
            for row in 0..<rect.height {
                let destination = storage.baseAddress! + (rect.y + row) * stride + rect.x * 4
                destination.copyMemory(from: source.baseAddress! + row * rowBytes, byteCount: rowBytes)
            }
        }
        snapshotBuffers.noteChange(in: rect)
    }

    /// Applies the next chunk of the session's zlib stream to `rect`.
    ///
    /// A rectangle that does not fit is refused before its chunk is inflated. Later chunks are
    /// compressed against this one, so the stream cannot go on after it, but a misfit ends the
    /// session anyway, and inflating first would let the header's size decide how much to allocate.
    public func writeZlib(_ chunk: Data, to rect: PixelRect) throws(UpdateError) {
        guard rect.x >= 0, rect.y >= 0, rect.maxX <= size.width, rect.maxY <= size.height else {
            throw .outOfBounds(rect)
        }
        let pixels: Data
        do {
            pixels = try zlibStream.inflate(chunk, expecting: max(0, rect.area) * 4)
        } catch {
            throw .compression(error)
        }
        try write(pixels, to: rect)
    }

    /// Applies one rectangle of Adaptive quality's tiles (encoding `0x3f3`). Returns whether it
    /// drew: the quantization tables, which come in an empty rectangle, do not.
    ///
    /// After a failure the picture holds whatever the rectangle drew before it failed and the
    /// Mac's idea of the tiles no longer matches; the session should go back to Full quality.
    public func writeAdaptive(_ body: Data, to rect: PixelRect) throws(UpdateError) -> Bool {
        if !isAdaptiveSized {
            adaptive.resize(width: size.width, height: size.height)
            isAdaptiveSized = true
        }
        let pixels = UnsafeMutableBufferPointer(
            start: storage.baseAddress!.assumingMemoryBound(to: UInt32.self), count: size.width * size.height
        )
        // A rectangle that fails has drawn up to where it failed.
        defer { snapshotBuffers.noteChange(in: rect.intersection(PixelRect(size: size))) }
        do {
            return try adaptive.decode([UInt8](body), x: rect.x, y: rect.y, width: rect.width, height: rect.height, onto: pixels)
        } catch {
            throw .adaptive(error)
        }
    }

    /// An immutable copy of the current picture.
    public func snapshot() -> CVReadOnlyPixelBuffer? {
        snapshot(of: PixelRect(size: size))
    }

    /// An immutable copy of one region, as a buffer of that region's size. `nil` when
    /// ``snapshotsInFlight`` copies of that size are still in use (or memory ran out, or the
    /// buffer could not be written).
    public func snapshot(of region: PixelRect) -> CVReadOnlyPixelBuffer? {
        let region = region.intersection(PixelRect(size: size))
        guard !region.isEmpty, let snapshot = snapshotBuffers.buffer(for: region),
              CVPixelBufferLockBaseAddress(snapshot.buffer, []) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(snapshot.buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(snapshot.buffer) else { return nil }
        let sourceStride = size.width * 4
        let destinationStride = CVPixelBufferGetBytesPerRow(snapshot.buffer)
        for part in snapshot.stale.rectangles {
            for row in part.y..<part.maxY {
                (destination + (row - region.y) * destinationStride + (part.x - region.x) * 4).copyMemory(
                    from: storage.baseAddress! + row * sourceStride + part.x * 4, byteCount: part.width * 4
                )
            }
        }
        return snapshot.finish()
    }

    /// The current pixels, tightly packed B, G, R, X.
    public func copyPixels() -> Data {
        Data(bytes: storage.baseAddress!, count: size.width * size.height * 4)
    }
}
