// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import RemoteDesktopCore

/// Where one remote display sits inside the local view, and how the two coordinate spaces map.
///
/// A pure value: the renderer draws ``contentFrame``, gesture interpreters mutate it, and the session
/// model stores it. Assigning any input (view size, content size, insets) re-applies the zoom mode and
/// re-clamps, so the model is always self-consistent.
///
/// Rules:
/// - *Fit* letterboxes inside the safe area only; the software keyboard never rescales the desktop.
/// - *Fill* covers the whole view, edge to edge.
/// - On each axis the content is clamped against ``availableRect``: content that fits is centred in
///   it (so a letterboxed desktop slides up when the keyboard appears); larger content may be panned
///   until either of its edges reaches the corresponding edge of the available area (so the remote
///   menu bar and Dock can always be brought out from under bars and the keyboard).
public struct ViewportModel: Sendable, Hashable, Codable {
    public enum ZoomMode: String, Sendable, Hashable, Codable, CaseIterable {
        /// Scale to Fit: the whole display, letterboxed inside the safe area, fitted again whenever
        /// the view or the display changes size (a rotation, a fold, a window resize).
        case fit
        /// One remote pixel per device pixel. Chosen once, it is a zoom like any other: it does not
        /// follow the view's size, only stays one-to-one when the display changes size.
        case actualSize
        /// Whatever the user pinched to.
        case free
    }

    // MARK: Inputs

    private struct Inputs: Sendable, Hashable, Codable {
        var viewSize: ViewSize
        var contentSize: PixelSize
        var deviceScale: Double
        var safeAreaInsets = ViewInsets.zero
        var obstructionInsets = ViewInsets.zero

        var bounds: ViewRect { ViewRect(size: viewSize.isEmpty ? .zero : viewSize) }
        var safeRect: ViewRect { bounds.inset(by: safeAreaInsets) }
        var availableRect: ViewRect { bounds.inset(by: safeAreaInsets.union(obstructionInsets)) }

        var contentWidth: Double { Double(max(contentSize.width, 0)) }
        var contentHeight: Double { Double(max(contentSize.height, 0)) }

        var fitScale: Double {
            let safe = safeRect
            guard !contentSize.isEmpty, safe.width > 0, safe.height > 0 else { return 1 }
            return ViewportModel.usable(min(safe.width / contentWidth, safe.height / contentHeight))
        }

        var fillScale: Double {
            guard !contentSize.isEmpty, !viewSize.isEmpty else { return 1 }
            return ViewportModel.usable(max(viewSize.width / contentWidth, viewSize.height / contentHeight))
        }

        var actualSizeScale: Double {
            deviceScale.isFinite && deviceScale > 0 ? 1 / deviceScale : 1
        }
    }

    private var inputs: Inputs

    /// Size of the local view, in points.
    public var viewSize: ViewSize {
        get { inputs.viewSize }
        set { update(recentres: true) { $0.viewSize = newValue } }
    }

    /// Size of the shown remote display, in remote pixels.
    public var contentSize: PixelSize {
        get { inputs.contentSize }
        set { update(recentres: true) { $0.contentSize = newValue } }
    }

    /// Device pixels per view point; decides what ``ZoomMode/actualSize`` means.
    public var deviceScale: Double {
        get { inputs.deviceScale }
        set { update(recentres: false) { $0.deviceScale = newValue } }
    }

    /// Bars and other system chrome. *Fit* letterboxes inside this.
    public var safeAreaInsets: ViewInsets {
        get { inputs.safeAreaInsets }
        set { update(recentres: false) { $0.safeAreaInsets = newValue } }
    }

    /// Things that cover the view temporarily, such as the software keyboard. Never changes the
    /// scale; only where the content may sit.
    public var obstructionInsets: ViewInsets {
        get { inputs.obstructionInsets }
        set { update(recentres: false) { $0.obstructionInsets = newValue } }
    }

    // MARK: State

    public private(set) var mode: ZoomMode
    /// View points per remote pixel. Always finite and greater than zero.
    public private(set) var scale: Double
    /// View position of remote pixel (0, 0).
    public private(set) var origin: ViewPoint

    public init(
        viewSize: ViewSize = .zero,
        contentSize: PixelSize = .zero,
        deviceScale: Double = 2,
        mode: ZoomMode = .fit
    ) {
        inputs = Inputs(viewSize: viewSize, contentSize: contentSize, deviceScale: deviceScale)
        self.mode = mode
        scale = 1
        origin = .zero
        setMode(mode)
    }

    // MARK: Derived

    public var bounds: ViewRect { inputs.bounds }

    /// The part of the view that is neither under bars nor under the keyboard: the bounds inset, per
    /// edge, by the larger of the safe-area and obstruction insets.
    public var availableRect: ViewRect { inputs.availableRect }

    /// Where the whole display lands in the view. The renderer draws exactly this rectangle.
    public var contentFrame: ViewRect {
        ViewRect(x: origin.x, y: origin.y, width: inputs.contentWidth * scale, height: inputs.contentHeight * scale)
    }

    public var fitScale: Double { inputs.fitScale }
    public var fillScale: Double { inputs.fillScale }
    /// One remote pixel per device pixel.
    public var actualSizeScale: Double { inputs.actualSizeScale }
    /// The furthest the user can zoom out: whichever of fit and 1:1 is smaller.
    public var minimumScale: Double { min(fitScale, actualSizeScale) }
    /// The furthest the user can zoom in: four device pixels per remote pixel, and never less than
    /// fill or four times fit.
    public var maximumScale: Double { max(fillScale, fitScale * 4, actualSizeScale * 4) }

    /// Device pixels per remote pixel at the current scale (1 means pixel-exact).
    public var magnification: Double { scale / actualSizeScale }

    /// Whether the content overflows the available area on either axis, so a drag can move it.
    public var isPannable: Bool {
        let available = availableRect
        let frame = contentFrame
        return frame.width > available.width + Self.tolerance || frame.height > available.height + Self.tolerance
    }

    /// The remote pixel under a view position. With `clamped`, positions outside the display map to
    /// its nearest edge pixel, so the result is always a valid pointer position.
    public func remotePoint(for point: ViewPoint, clamped: Bool = true) -> PixelPoint {
        var x = (point.x - origin.x) / scale
        var y = (point.y - origin.y) / scale
        if clamped {
            x = min(max(x, 0), max(0, inputs.contentWidth - 1))
            y = min(max(y, 0), max(0, inputs.contentHeight - 1))
        }
        return PixelPoint(x: x, y: y)
    }

    public func viewPoint(for point: PixelPoint) -> ViewPoint {
        ViewPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    // MARK: Intents

    public mutating func setMode(_ mode: ZoomMode) {
        self.mode = mode
        switch mode {
        case .fit:
            scale = fitScale
        case .actualSize:
            rescale(to: actualSizeScale, around: availableRect.center)
        case .free:
            scale = clampedScale(scale)
        }
        origin = clampedOrigin(origin)
    }

    /// Multiplies the scale, keeping the remote pixel under `anchor` where it is as far as clamping
    /// allows. Switches to ``ZoomMode/free``.
    public mutating func zoom(by factor: Double, around anchor: ViewPoint) {
        guard factor.isFinite, factor > 0 else { return }
        setScale(scale * factor, around: anchor)
    }

    /// Sets the scale (limited to ``minimumScale``...``maximumScale``), keeping the remote pixel under
    /// `anchor` where it is as far as clamping allows. Switches to ``ZoomMode/free``.
    public mutating func setScale(_ scale: Double, around anchor: ViewPoint) {
        guard scale.isFinite, scale > 0 else { return }
        mode = .free
        rescale(to: clampedScale(scale), around: anchor)
        origin = clampedOrigin(origin)
    }

    /// Moves the content. Returns the part of `delta` that was applied after clamping.
    @discardableResult
    public mutating func pan(by delta: ViewVector) -> ViewVector {
        guard delta.dx.isFinite, delta.dy.isFinite else { return .zero }
        let target = clampedOrigin(origin + delta)
        let applied = target - origin
        origin = target
        return applied
    }

    /// Pans as little as possible so that `remotePoint` is inside the available area, `margin` points
    /// away from its edges. Returns the pan that was applied.
    @discardableResult
    public mutating func reveal(_ remotePoint: PixelPoint, margin: Double = 24) -> ViewVector {
        let available = availableRect
        let insetX = min(max(margin, 0), available.width / 2)
        let insetY = min(max(margin, 0), available.height / 2)
        let position = viewPoint(for: remotePoint)
        var delta = ViewVector.zero
        if position.x < available.minX + insetX {
            delta.dx = available.minX + insetX - position.x
        } else if position.x > available.maxX - insetX {
            delta.dx = available.maxX - insetX - position.x
        }
        if position.y < available.minY + insetY {
            delta.dy = available.minY + insetY - position.y
        } else if position.y > available.maxY - insetY {
            delta.dy = available.maxY - insetY - position.y
        }
        return pan(by: delta)
    }

    /// How fast the content should move, in points per second, while something is being dragged at
    /// `point`. Non-zero only within `edgeWidth` of an edge of the available area, and only in
    /// directions the content can still move. Feed `velocity × elapsed` to ``pan(by:)``.
    public func edgeAutoPanVelocity(at point: ViewPoint, edgeWidth: Double = 44, maximumSpeed: Double = 900) -> ViewVector {
        guard edgeWidth > 0, maximumSpeed > 0 else { return .zero }
        let available = availableRect
        let frame = contentFrame
        func axis(position: Double, lower: Double, upper: Double, origin: Double, extent: Double) -> Double {
            guard extent > upper - lower + Self.tolerance else { return 0 }
            let nearLower = min(max((lower + edgeWidth - position) / edgeWidth, 0), 1)
            let nearUpper = min(max((position - (upper - edgeWidth)) / edgeWidth, 0), 1)
            if nearLower >= nearUpper {
                // Dragging towards the left/top edge reveals what is beyond it: content moves forward.
                return nearLower > 0 && origin < lower - Self.tolerance ? maximumSpeed * nearLower : 0
            }
            return origin > upper - extent + Self.tolerance ? -maximumSpeed * nearUpper : 0
        }
        return ViewVector(
            dx: axis(position: point.x, lower: available.minX, upper: available.maxX, origin: origin.x, extent: frame.width),
            dy: axis(position: point.y, lower: available.minY, upper: available.maxY, origin: origin.y, extent: frame.height)
        )
    }

    /// Call when a zoom gesture ends: a free scale within a few percent of fit snaps to
    /// ``ZoomMode/fit``.
    public mutating func settle() {
        guard mode == .free else { return }
        let fit = fitScale
        if abs(scale - fit) <= fit * 0.03 {
            setMode(.fit)
        }
    }

    // MARK: Internals

    /// Half a hundredth of a point: below anything visible, above floating-point noise.
    private static let tolerance = 0.005

    fileprivate static func usable(_ scale: Double) -> Double {
        scale.isFinite && scale > 0 ? scale : 1
    }

    private func clampedScale(_ value: Double) -> Double {
        let lower = minimumScale
        let upper = max(maximumScale, lower)
        return Self.usable(min(max(value, lower), upper))
    }

    private mutating func rescale(to newScale: Double, around anchor: ViewPoint) {
        let remote = remotePoint(for: anchor, clamped: false)
        scale = newScale
        origin = ViewPoint(x: anchor.x - remote.x * scale, y: anchor.y - remote.y * scale)
    }

    private func clampedOrigin(_ proposed: ViewPoint) -> ViewPoint {
        let available = availableRect
        let frame = contentFrame
        func axis(_ value: Double, lower: Double, upper: Double, extent: Double) -> Double {
            let room = upper - lower
            if extent <= room + Self.tolerance {
                return lower + (room - extent) / 2
            }
            return min(lower, max(upper - extent, value))
        }
        return ViewPoint(
            x: axis(proposed.x, lower: available.minX, upper: available.maxX, extent: frame.width),
            y: axis(proposed.y, lower: available.minY, upper: available.maxY, extent: frame.height)
        )
    }

    private mutating func update(recentres: Bool, _ change: (inout Inputs) -> Void) {
        let old = inputs
        change(&inputs)
        guard inputs != old else { return }

        // Which part of the content was in the middle of what the user could see.
        let oldWidth = old.contentWidth * scale
        let oldHeight = old.contentHeight * scale
        let oldCentre = old.availableRect.center
        let anchorX = oldWidth > 0 ? (oldCentre.x - origin.x) / oldWidth : 0.5
        let anchorY = oldHeight > 0 ? (oldCentre.y - origin.y) / oldHeight : 0.5

        switch mode {
        case .fit:
            scale = fitScale
        case .actualSize:
            scale = actualSizeScale
        case .free:
            // A resized remote display keeps its zoom relative to fit rather than its raw scale.
            if old.contentSize != inputs.contentSize, !old.contentSize.isEmpty {
                scale = scale / old.fitScale * fitScale
            }
            scale = clampedScale(scale)
        }

        if recentres {
            let centre = availableRect.center
            origin = ViewPoint(
                x: centre.x - anchorX * inputs.contentWidth * scale,
                y: centre.y - anchorY * inputs.contentHeight * scale
            )
        }
        origin = clampedOrigin(origin)
    }
}
