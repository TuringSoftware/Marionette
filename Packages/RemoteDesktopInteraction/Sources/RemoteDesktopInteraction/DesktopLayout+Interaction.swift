// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import RemoteDesktopCore

extension RemoteDisplay {
    /// Size in the remote machine's points (pixels divided by the backing scale).
    public var pointSize: ViewSize {
        let divisor = scale.isFinite && scale > 0 ? scale : 1
        return ViewSize(width: Double(pixelSize.width) / divisor, height: Double(pixelSize.height) / divisor)
    }

    /// The nearest position inside the display, in the display's own pixels.
    public func clamping(_ point: PixelPoint) -> PixelPoint {
        PixelPoint(
            x: min(max(point.x, 0), Double(max(pixelSize.width - 1, 0))),
            y: min(max(point.y, 0), Double(max(pixelSize.height - 1, 0)))
        )
    }

    /// Converts a position in the display's own pixels to desktop pixels.
    public func desktopPoint(for displayPoint: PixelPoint) -> PixelPoint {
        PixelPoint(x: displayPoint.x + Double(frameInDesktop.x), y: displayPoint.y + Double(frameInDesktop.y))
    }

    /// Converts a desktop position to the display's own pixels. The result may lie outside the display.
    public func displayPoint(for desktopPoint: PixelPoint) -> PixelPoint {
        PixelPoint(x: desktopPoint.x - Double(frameInDesktop.x), y: desktopPoint.y - Double(frameInDesktop.y))
    }
}

extension DesktopLayout {
    /// One display's rectangle as fractions of the whole desktop's bounding box.
    public struct NormalizedDisplayFrame: Sendable, Hashable, Identifiable {
        public var id: DisplayID
        /// 0...1 on both axes, relative to ``DesktopLayout/bounds``.
        public var frame: ViewRect

        public init(id: DisplayID, frame: ViewRect) {
            self.id = id
            self.frame = frame
        }
    }

    /// The display a session shows first: the first listed, which back ends make the main display
    /// (on a Mac, the one with the menu bar). Not the one at the desktop's origin: a Mac's
    /// framebuffer starts at its leftmost display.
    public var primaryDisplay: RemoteDisplay? {
        displays.first
    }

    /// The display after `id` in layout order, wrapping around. The first display when `id` is `nil`
    /// or unknown; `nil` only when there are no displays.
    public func display(after id: DisplayID?) -> RemoteDisplay? {
        neighbour(of: id, offset: 1)
    }

    /// The display before `id` in layout order, wrapping around.
    public func display(before id: DisplayID?) -> RemoteDisplay? {
        neighbour(of: id, offset: -1)
    }

    private func neighbour(of id: DisplayID?, offset: Int) -> RemoteDisplay? {
        guard !displays.isEmpty else { return nil }
        guard let id, let index = displays.firstIndex(where: { $0.id == id }) else { return displays.first }
        return displays[(index + offset + displays.count) % displays.count]
    }

    /// Converts a position inside a display to desktop pixels; `nil` when the display is unknown.
    public func desktopPoint(for displayPoint: PixelPoint, in display: DisplayID) -> PixelPoint? {
        self[display]?.desktopPoint(for: displayPoint)
    }

    /// Converts a desktop position to a display's own pixels; `nil` when the display is unknown.
    public func displayPoint(for desktopPoint: PixelPoint, in display: DisplayID) -> PixelPoint? {
        self[display]?.displayPoint(for: desktopPoint)
    }

    /// The display under a desktop position, or else the one whose edge is closest to it.
    public func nearestDisplay(to desktopPoint: PixelPoint) -> RemoteDisplay? {
        if let hit = display(at: desktopPoint) { return hit }
        func distanceSquared(_ display: RemoteDisplay) -> Double {
            let frame = display.frameInDesktop
            let dx = max(Double(frame.x) - desktopPoint.x, 0, desktopPoint.x - Double(frame.maxX))
            let dy = max(Double(frame.y) - desktopPoint.y, 0, desktopPoint.y - Double(frame.maxY))
            return dx * dx + dy * dy
        }
        return displays.min { distanceSquared($0) < distanceSquared($1) }
    }

    /// Resolves a desktop position to a display and a valid position inside it, snapping positions in
    /// the gaps between displays to the nearest display.
    public func locate(_ desktopPoint: PixelPoint) -> (display: RemoteDisplay, position: PixelPoint)? {
        guard let display = nearestDisplay(to: desktopPoint) else { return nil }
        return (display, display.clamping(display.displayPoint(for: desktopPoint)))
    }

    /// Width divided by height of the whole desktop; 1 when it is empty.
    public var aspectRatio: Double {
        let box = bounds
        return box.isEmpty ? 1 : Double(box.width) / Double(box.height)
    }

    /// Every display as fractions of the desktop's bounding box, for drawing an arrangement miniature.
    public func normalizedFrames() -> [NormalizedDisplayFrame] {
        let box = bounds
        guard !box.isEmpty else { return [] }
        let width = Double(box.width)
        let height = Double(box.height)
        return displays.map { display in
            let frame = display.frameInDesktop
            return NormalizedDisplayFrame(
                id: display.id,
                frame: ViewRect(
                    x: Double(frame.x - box.x) / width,
                    y: Double(frame.y - box.y) / height,
                    width: Double(frame.width) / width,
                    height: Double(frame.height) / height
                )
            )
        }
    }
}
