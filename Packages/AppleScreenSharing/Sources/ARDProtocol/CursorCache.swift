// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
public import RemoteDesktopCore

/// A Mac's cursor shapes, which arrive as a cache: each shape is sent once with pixels and then
/// re-selected by id whenever the pointer changes back to it.
public struct CursorCache: Sendable {
    public enum Update: Sendable, Equatable {
        case shape(CursorImage)
        /// A selection of an id that was never stored, or a shape that could not be read. The
        /// pointer keeps the shape it has.
        case unchanged
    }

    /// Largest cursor edge accepted. The Mac sends shapes in points, and its largest accessibility
    /// cursor is well under this.
    static let maximumEdge = 256
    static let maximumShapes = 256
    /// What the stored shapes may take together. A zeroed shape deflates to about a kilobyte, so
    /// without a budget a few hundred kilobytes from the Mac could pin 256 MB here.
    static let byteBudget = 16 << 20

    private var shapes: [UInt32: CursorImage] = [:]
    /// Least recently used first.
    private var order: [UInt32] = []
    private var storedBytes = 0
    /// Counts the shapes decoded. The Mac may send a new shape under a cache id it used before, and
    /// an image's id must name its pixels (renderers keep a texture per id), so each decoded shape
    /// gets an id of its own: this count above the Mac's cache id.
    private var decodedShapes: UInt64 = 0

    public init() {}

    /// Applies a cursor rectangle. The rectangle header's position is the hotspot and its size the
    /// shape's; `deflated` is empty for a selection.
    public mutating func apply(cacheID: UInt32, hotspotX: UInt16, hotspotY: UInt16, width: UInt16, height: UInt16, deflated: Data) -> Update {
        if deflated.isEmpty {
            guard let image = shapes[cacheID] else { return .unchanged }
            touch(cacheID)
            return .shape(image)
        }
        let pixelCount = Int(width) * Int(height)
        guard width > 0, height > 0, Int(width) <= Self.maximumEdge, Int(height) <= Self.maximumEdge else { return .unchanged }
        // Each shape is its own zlib stream: BGRX pixels, then a separate plane of alpha.
        guard let raw = try? InflateStream.inflateWhole(deflated, limit: pixelCount * 5), raw.count == pixelCount * 5 else {
            return .unchanged
        }
        var premultiplied = Data(count: pixelCount * 4)
        premultiplied.withUnsafeMutableBytes { output in
            raw.withUnsafeBytes { input in
                for index in 0..<pixelCount {
                    let alpha = UInt32(input[pixelCount * 4 + index])
                    // The fourth byte of each pixel is not alpha; the plane after the pixels is.
                    for channel in 0..<3 {
                        output[index * 4 + channel] = UInt8((UInt32(input[index * 4 + channel]) * alpha + 127) / 255)
                    }
                    output[index * 4 + 3] = UInt8(alpha)
                }
            }
        }
        decodedShapes += 1
        let image = CursorImage(
            id: decodedShapes << 32 | UInt64(cacheID),
            pixelSize: PixelSize(width: Int(width), height: Int(height)),
            bgraPixels: premultiplied,
            hotspot: PixelPoint(x: Double(hotspotX), y: Double(hotspotY)),
            // The Mac sends the same point-sized pixmap whatever the display's density.
            scale: 1
        )
        if let replaced = shapes.updateValue(image, forKey: cacheID) {
            storedBytes -= replaced.bgraPixels.count
        }
        storedBytes += image.bgraPixels.count
        touch(cacheID)
        // The shape just stored is the newest, so it is never the one evicted.
        while order.count > Self.maximumShapes || storedBytes > Self.byteBudget, order.count > 1 {
            if let evicted = shapes.removeValue(forKey: order.removeFirst()) { storedBytes -= evicted.bgraPixels.count }
        }
        return .shape(image)
    }

    /// Makes `cacheID` the most recently used.
    private mutating func touch(_ cacheID: UInt32) {
        if let index = order.lastIndex(of: cacheID) { order.remove(at: index) }
        order.append(cacheID)
    }
}
