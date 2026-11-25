// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import RemoteDesktopCore

/// One finger at one moment, as the platform's touch system reported it.
public struct TouchSample: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case began
        case moved
        case ended
        case cancelled
    }

    /// Identity of the finger, stable from `began` to `ended`/`cancelled`.
    public var id: Int
    public var phase: Phase
    /// Position in the view whose size the viewport describes.
    public var location: ViewPoint
    /// Seconds on a monotonic clock. The same clock must be used for
    /// ``GestureInterpreter/advance(to:context:)``.
    public var timestamp: Double

    public init(id: Int, phase: Phase, location: ViewPoint, timestamp: Double) {
        self.id = id
        self.phase = phase
        self.location = location
        self.timestamp = timestamp
    }
}

/// The remote display that pointer input is aimed at.
public struct PointerTarget: Sendable, Hashable {
    public var display: DisplayID
    public var pixelSize: PixelSize
    public var layoutGeneration: UInt64

    public init(display: DisplayID, pixelSize: PixelSize, layoutGeneration: UInt64) {
        self.display = display
        self.pixelSize = pixelSize
        self.layoutGeneration = layoutGeneration
    }

    /// The target for a display of a layout, or `nil` when there is no display or it is not part of
    /// the layout (any more).
    public init?(display: RemoteDisplay?, layout: DesktopLayout) {
        guard let display, let current = layout[display.id] else { return nil }
        self.init(display: current.id, pixelSize: current.pixelSize, layoutGeneration: layout.generation)
    }

    public init?(display id: DisplayID?, layout: DesktopLayout) {
        guard let id else { return nil }
        self.init(display: layout[id], layout: layout)
    }

    /// The nearest position inside the display. Never returns a coordinate equal to the width or
    /// height, so the result survives a back end rounding it to whole pixels.
    public func clamp(_ point: PixelPoint) -> PixelPoint {
        PixelPoint(
            x: min(max(point.x, 0), Double(max(pixelSize.width - 1, 0))),
            y: min(max(point.y, 0), Double(max(pixelSize.height - 1, 0)))
        )
    }
}

/// Everything an interpreter reads and writes besides its own state. Owned by the caller (the
/// session model's `uiState`), passed `inout` to every call.
public struct InteractionContext: Sendable, Hashable {
    public var viewport: ViewportModel
    /// `nil` while there is nothing to aim at; interpreters then send no input, though viewport
    /// gestures keep working.
    public var target: PointerTarget?
    /// The pointer's position, in the target display's pixels. Interpreters update it whenever they
    /// send a pointer position.
    public var pointer: PixelPoint
    /// Buttons the interpreters are holding down. Empty whenever no finger is touching.
    public var buttons: PointerButtons
    /// Modifiers currently held (latched or hardware); attached to scroll events.
    public var modifiers: KeyModifiers

    public init(
        viewport: ViewportModel = ViewportModel(),
        target: PointerTarget? = nil,
        pointer: PixelPoint = .zero,
        buttons: PointerButtons = [],
        modifiers: KeyModifiers = []
    ) {
        self.viewport = viewport
        self.target = target
        self.pointer = pointer
        self.buttons = buttons
        self.modifiers = modifiers
    }
}

/// What an interpreter wants done, in order.
public enum InteractionEffect: Sendable, Hashable {
    public enum Feedback: Sendable, Hashable {
        /// A long-press was recognised (the finger is still down).
        case longPress
        /// A drag with the primary button started: the button went down.
        case dragBegan
        /// Trackpad: the button of a drag came up.
        case dragEnded
        /// Trackpad: a tap clicked, as a Mac trackpad's click is felt.
        case click
        case secondaryClick
    }

    /// Send this to the session's input sink.
    case input(InputEvent)
    /// `context.viewport` changed; redraw.
    case viewportChanged
    /// `context.pointer` changed; move the locally drawn cursor now, without waiting for the remote.
    case pointerMoved
    /// Play a haptic, if the platform has them.
    case feedback(Feedback)
    /// Trackpad: the finger moved the pointer past an edge of its display, to this position in the
    /// display's pixels (outside it). The pointer itself stopped at the edge; the caller may carry it
    /// on to a display beyond.
    case pointerPushedPastEdge(PixelPoint)
}

/// Tuning for both interpreters. Distances are view points, durations are seconds.
public struct GestureConfiguration: Sendable, Hashable {
    /// How far a finger may travel and still count as a tap or a long-press.
    public var tapSlop = 10.0
    /// Longest a two-finger tap may last, measured from the second finger landing.
    public var maximumTapDuration = 0.30
    public var longPressDuration = 0.45
    /// Longest pause between two taps of a double tap (first lift to second touch).
    public var doubleTapInterval = 0.30
    /// Touch mode: how far apart the two taps of a double tap may land.
    public var doubleTapSlop = 24.0
    /// Centroid travel that latches a two-finger gesture to scrolling.
    public var twoFingerScrollThreshold = 8.0
    /// Change in finger spacing that latches a two-finger gesture to zoom and pan.
    public var twoFingerPinchThreshold = 16.0
    /// Content follows the fingers, as on iOS and on a Mac trackpad's default.
    public var naturalScrolling = true
    public var scrollSpeed = 1.0
    public var pointerSpeed = 1.0
    /// Trackpad mode: fast finger movement moves the pointer further.
    public var pointerAcceleration = true
    /// Keep scrolling after a flick.
    public var momentum = true
    /// Trackpad mode: how far a finger travels before the pointer starts to follow it. Smaller than
    /// ``tapSlop`` so small, slow corrections are possible.
    public var pointerMoveSlop = 4.0
    /// The surface is a trackpad of its own, not the remote picture, and behaves like a Mac's: pinch
    /// and rotate go to the remote app as gestures, a two-finger double tap is smart zoom, a
    /// three-finger tap looks up, and three-finger swipes show Mission Control and Application
    /// Windows or move between spaces. A two-finger tap then clicks a moment later, once it is clear
    /// it was not the first half of a double tap.
    public var forwardsGestures = false
    /// Three-finger travel that makes a swipe.
    public var threeFingerSwipeDistance = 36.0

    public init() {}
}

/// A state machine that turns touches into remote input and viewport changes.
///
/// Feed it every touch sample of one view through ``handle(_:context:)``; pass all samples of one
/// platform event in a single call. Whenever ``nextDeadline`` is not `nil`, call
/// ``advance(to:context:)`` at (or after) that time. Apply the returned effects in order.
public protocol GestureInterpreter: Sendable {
    mutating func handle(_ samples: [TouchSample], context: inout InteractionContext) -> [InteractionEffect]
    /// Runs timers: long-press recognition, edge auto-pan while dragging, scroll momentum.
    mutating func advance(to time: Double, context: inout InteractionContext) -> [InteractionEffect]
    /// When ``advance(to:context:)`` must next be called; `nil` when nothing is pending.
    var nextDeadline: Double? { get }
    /// Abandons whatever is in progress: releases held buttons, ends a scroll with `.cancelled`, stops
    /// momentum, and forgets every finger. Use when the view loses its touches, the app resigns
    /// active, or the input mode changes.
    mutating func cancel(context: inout InteractionContext) -> [InteractionEffect]
    /// No finger is down and no timer is running.
    var isIdle: Bool { get }
}

/// Direct manipulation: the finger is the pointer.
///
/// | Gesture | Result |
/// |---|---|
/// | Tap, double tap | click at the point (a double tap clicks twice on the first tap's exact pixel) |
/// | One-finger drag | pan when the viewport is pannable, otherwise move the pointer |
/// | Long-press, lift | secondary click |
/// | Long-press, move | drag with the primary button; the viewport auto-pans near its edges |
/// | Two-finger tap | secondary click at the midpoint |
/// | Two-finger move / pinch | scroll, or zoom and pan — whichever starts first, until the fingers lift |
public struct TouchInterpreter: GestureInterpreter, Hashable {
    private var engine: GestureEngine

    public var configuration: GestureConfiguration {
        get { engine.configuration }
        set { engine.configuration = newValue }
    }

    public init(configuration: GestureConfiguration = GestureConfiguration()) {
        engine = GestureEngine(style: .touch, configuration: configuration, zoomAnchor: .touchCentroid)
    }

    public mutating func handle(_ samples: [TouchSample], context: inout InteractionContext) -> [InteractionEffect] {
        engine.handle(samples, context: &context)
    }

    public mutating func advance(to time: Double, context: inout InteractionContext) -> [InteractionEffect] {
        engine.advance(to: time, context: &context)
    }

    public var nextDeadline: Double? { engine.nextDeadline }

    public mutating func cancel(context: inout InteractionContext) -> [InteractionEffect] {
        engine.cancel(context: &context)
    }

    public var isIdle: Bool { engine.isIdle }
}

/// Indirect manipulation: the surface is a trackpad and the remote pointer is a cursor.
///
/// | Gesture | Result |
/// |---|---|
/// | Tap, double tap | click at the cursor |
/// | One-finger drag | move the cursor; the viewport follows it |
/// | Long-press, lift | secondary click at the cursor |
/// | Long-press, move — or double-tap-and-hold, move | drag with the primary button |
/// | Two-finger tap | secondary click at the cursor |
/// | Two-finger move / pinch | scroll at the cursor, or zoom — whichever starts first, until the fingers lift |
///
/// With ``GestureConfiguration/forwardsGestures`` (a trackpad surface of its own), as on a Mac:
///
/// | Gesture | Result |
/// |---|---|
/// | Pinch / rotate | magnify / rotate gesture to the remote app |
/// | Two-finger double tap | smart zoom |
/// | Three-finger tap | look up (Quick Look) |
/// | Three-finger swipe up / down | Mission Control / Application Windows |
/// | Three-finger swipe left / right | the space to the right / left |
public struct TrackpadInterpreter: GestureInterpreter, Hashable {
    public enum ZoomAnchor: Sendable, Hashable {
        /// The touches are on the remote display's own view: zoom around the fingers and pan with them.
        case touchCentroid
        /// The touches are on a separate trackpad surface: zoom around the cursor.
        case pointer
    }

    private var engine: GestureEngine

    public var configuration: GestureConfiguration {
        get { engine.configuration }
        set { engine.configuration = newValue }
    }

    public var zoomAnchor: ZoomAnchor {
        get { engine.zoomAnchor }
        set { engine.zoomAnchor = newValue }
    }

    public init(configuration: GestureConfiguration = GestureConfiguration(), zoomAnchor: ZoomAnchor = .touchCentroid) {
        engine = GestureEngine(style: .trackpad, configuration: configuration, zoomAnchor: zoomAnchor)
    }

    public mutating func handle(_ samples: [TouchSample], context: inout InteractionContext) -> [InteractionEffect] {
        engine.handle(samples, context: &context)
    }

    public mutating func advance(to time: Double, context: inout InteractionContext) -> [InteractionEffect] {
        engine.advance(to: time, context: &context)
    }

    public var nextDeadline: Double? { engine.nextDeadline }

    public mutating func cancel(context: inout InteractionContext) -> [InteractionEffect] {
        engine.cancel(context: &context)
    }

    public var isIdle: Bool { engine.isIdle }
}
