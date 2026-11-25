// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import CoreGraphics
public import RemoteDesktopCore

/// Where and how one remote display is drawn in the renderer's layer.
///
/// Plain values, so a front end can compute it from its own viewport model without the renderer
/// knowing anything about zoom modes or gestures.
public struct RenderGeometry: Sendable, Hashable {
    /// Size of the layer, in points.
    public var viewSize: CGSize
    /// Device pixels per point.
    public var deviceScale: Double
    /// Where the *whole* remote display lands, in layer points with a top-left origin. It may extend
    /// past the layer (zoomed in) or cover only part of it (letterboxed).
    public var contentFrame: CGRect
    /// Backing scale of the remote display (`RemoteDisplay.scale`).
    public var remoteScale: Double
    /// Origin of the display inside the remote desktop (`RemoteDisplay.frameInDesktop`), used to bring
    /// `CursorState.position`, which is in desktop pixels, into this display.
    public var desktopOrigin: PixelPoint

    public init(
        viewSize: CGSize = .zero,
        deviceScale: Double = 2,
        contentFrame: CGRect = .zero,
        remoteScale: Double = 1,
        desktopOrigin: PixelPoint = .zero
    ) {
        self.viewSize = viewSize
        self.deviceScale = deviceScale
        self.contentFrame = contentFrame
        self.remoteScale = remoteScale
        self.desktopOrigin = desktopOrigin
    }

    /// Size of the drawable that covers the layer, in device pixels; `nil` when there is nothing to
    /// draw into (zero-sized or not yet laid out).
    var drawablePixelSize: (width: Int, height: Int)? {
        let width = viewSize.width * deviceScale
        let height = viewSize.height * deviceScale
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else { return nil }
        return (min(Int(width.rounded()), 16_384), min(Int(height.rounded()), 16_384))
    }

    var isDrawable: Bool {
        viewSize.width > 0 && viewSize.height > 0 && viewSize.width.isFinite && viewSize.height.isFinite
    }

    var hasContent: Bool {
        let values = [contentFrame.minX, contentFrame.minY, contentFrame.width, contentFrame.height]
        return values.allSatisfy(\.isFinite) && contentFrame.width > 0 && contentFrame.height > 0
    }
}

/// Everything one draw needs, copied out from under the renderer's lock.
struct RenderInputs: Sendable {
    var geometry = RenderGeometry()
    var frame: DisplayFrame?
    /// Changes whenever `frame` does, so the Metal side knows when to wrap a new surface.
    var frameSerial: UInt64 = 0
    var cursor = CursorState()
    var localPointer: PixelPoint?
    var isCursorHidden = false
    var background = SIMD3<Double>(0, 0, 0)
}

/// Pure placement maths for the client-drawn pointer.
enum CursorLayout {
    /// Where the pointer is, in the display's own pixels, or `nil` when it must not be drawn.
    static func pointerPosition(for inputs: RenderInputs) -> PixelPoint? {
        guard !inputs.isCursorHidden, inputs.cursor.isVisible, !inputs.cursor.isCompositedInFrames else { return nil }
        if let local = inputs.localPointer { return local }
        guard let desktop = inputs.cursor.position else { return nil }
        return PixelPoint(
            x: desktop.x - inputs.geometry.desktopOrigin.x,
            y: desktop.y - inputs.geometry.desktopOrigin.y
        )
    }

    /// The rectangle the cursor image covers, in layer points.
    ///
    /// The image scales with the desktop, so it looks exactly as it would on the remote machine, but
    /// never shrinks below its natural point size: zoomed out on a phone, a pointer drawn to scale
    /// would be a few pixels across and impossible to find.
    static func frame(
        pointer: PixelPoint,
        image: CursorImage,
        geometry: RenderGeometry,
        displayPixelSize: PixelSize
    ) -> CGRect? {
        guard geometry.hasContent, !displayPixelSize.isEmpty, !image.pixelSize.isEmpty else { return nil }
        let pointsPerPixelX = geometry.contentFrame.width / Double(displayPixelSize.width)
        let pointsPerPixelY = geometry.contentFrame.height / Double(displayPixelSize.height)
        let imageScale = image.scale > 0 ? image.scale : 1
        let remoteScale = geometry.remoteScale > 0 ? geometry.remoteScale : 1
        let magnification = max(remoteScale * pointsPerPixelX, 1)
        let pointsPerImagePixel = magnification / imageScale
        let anchor = CGPoint(
            x: geometry.contentFrame.minX + pointer.x * pointsPerPixelX,
            y: geometry.contentFrame.minY + pointer.y * pointsPerPixelY
        )
        return CGRect(
            x: anchor.x - image.hotspot.x * pointsPerImagePixel,
            y: anchor.y - image.hotspot.y * pointsPerImagePixel,
            width: Double(image.pixelSize.width) * pointsPerImagePixel,
            height: Double(image.pixelSize.height) * pointsPerImagePixel
        )
    }
}
