// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation

/// A cursor shape sent by the remote machine.
public struct CursorImage: Sendable, Hashable {
    /// Identity assigned by the back end; two images with the same id have identical pixels.
    public var id: UInt64
    public var pixelSize: PixelSize
    /// Tightly packed 32-bit BGRA, premultiplied alpha, `pixelSize.width * 4` bytes per row.
    public var bgraPixels: Data
    /// The pixel within the image that sits on the pointer position.
    public var hotspot: PixelPoint
    /// Backing scale of the image (2 for a HiDPI cursor).
    public var scale: Double

    public init(id: UInt64, pixelSize: PixelSize, bgraPixels: Data, hotspot: PixelPoint, scale: Double = 1) {
        self.id = id
        self.pixelSize = pixelSize
        self.bgraPixels = bgraPixels
        self.hotspot = hotspot
        self.scale = scale
    }

    public static func == (lhs: CursorImage, rhs: CursorImage) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Everything a renderer needs to draw the remote pointer. Delivered latest-wins.
public struct CursorState: Sendable, Hashable {
    /// `nil` when the remote has not sent a shape; draw a default arrow.
    public var image: CursorImage?
    /// Desktop position reported by the remote, if it reports one. Clients that drive the pointer
    /// themselves may draw at their own last position and use this only to correct drift.
    public var position: PixelPoint?
    public var isVisible: Bool
    /// True when the pointer is already painted into the display frames, so it must not be drawn again.
    public var isCompositedInFrames: Bool
    /// Counts the times the pointer was moved at the remote machine (its own mouse, or a program)
    /// rather than by this client. A client that drives the pointer itself takes ``position`` as the
    /// pointer's new place whenever this changes.
    public var remoteMoves: UInt64 = 0

    public init(
        image: CursorImage? = nil,
        position: PixelPoint? = nil,
        isVisible: Bool = true,
        isCompositedInFrames: Bool = false
    ) {
        self.image = image
        self.position = position
        self.isVisible = isVisible
        self.isCompositedInFrames = isCompositedInFrames
    }
}
