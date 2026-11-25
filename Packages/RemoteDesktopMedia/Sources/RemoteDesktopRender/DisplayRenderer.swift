// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import CoreGraphics
import Foundation
import Metal
public import QuartzCore
public import RemoteDesktopCore
import Synchronization

/// Draws one remote display, and the remote pointer on top of it, into a `CAMetalLayer` it owns.
///
/// Thread-safe: every method may be called from any thread or actor and none of them waits for the
/// GPU (except ``renderOffscreen(pixelWidth:pixelHeight:)``, which exists for tests). Frames and
/// pointer updates are consumed and drawn away from the main actor; drawing happens on demand — when
/// a frame, the geometry or the pointer changes — and requests that arrive while a draw is pending
/// collapse into it.
///
/// The renderer outlives the views that show it. A view adds ``layer`` to its own layer tree, sets
/// its frame, and reports where the display should land with ``setGeometry(_:)``; a view that is
/// torn down and rebuilt simply attaches the same layer again and loses nothing.
public final class DisplayRenderer: Sendable {
    /// How frames reach the GPU.
    public enum TexturePath: Sendable, Hashable {
        /// The frame's surface is used as the texture directly.
        case zeroCopy
        /// The frame's pixels are copied into a texture (fallback when wrapping is not possible).
        case upload
    }

    private struct State {
        var inputs = RenderInputs()
        var isRenderScheduled = false
        var contentsScale = 0.0
        /// The colour space the layer is tagged with; `nil` until the first frame says.
        var layerColorSpace: CGColorSpace?
        var texturePath: TexturePath?
        var frameTask: Task<Void, Never>?
        var cursorTask: Task<Void, Never>?
        var firstFrameWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var nextWaiterToken: UInt64 = 0
        /// Set by ``suspendDrawing()``: nothing reaches the GPU until ``resumeDrawing()``.
        var isDrawingSuspended = false
    }

    /// `@unchecked Sendable`: the layer is handed out on the main actor only, and besides that the
    /// renderer touches just its drawable (`drawableSize`, `nextDrawable`) from the render queue,
    /// which Core Animation supports from any one thread at a time.
    private final class LayerBox: @unchecked Sendable {
        let layer = CAMetalLayer()
    }

    /// `@unchecked Sendable`: all Metal state lives here and is only ever touched on `queue`.
    private final class CoreBox: @unchecked Sendable {
        let core: RenderCore

        init(_ core: RenderCore) {
            self.core = core
        }
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "llc.turing.Marionette.render", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private let layerBox = LayerBox()
    private let coreBox: CoreBox?

    /// Creates a renderer on the system's default GPU. Without one the renderer is inert: it accepts
    /// everything, keeps the last frame for ``snapshot(maximumPixelDimension:)``, and draws nothing.
    public init() {
        let device = MTLCreateSystemDefaultDevice()
        coreBox = device.flatMap(RenderCore.init(device:)).map(CoreBox.init)

        let layer = layerBox.layer
        layer.device = coreBox?.core.device
        layer.pixelFormat = RenderCore.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = true
        // Pixels pass through untouched; the layer is tagged with the frames' colour space (sRGB
        // until one arrives, see `submit(_:)`) so the system matches it to the panel.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // The host view moves and resizes the layer during layout; none of that should animate.
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "transform": NSNull()]
    }

    deinit {
        let tasks = state.withLock { ($0.frameTask, $0.cursorTask) }
        tasks.0?.cancel()
        tasks.1?.cancel()
    }

    /// False when the device has no usable GPU; nothing will be drawn.
    public var isAvailable: Bool { coreBox != nil }

    /// The layer the display is drawn into. The host adds it as a sublayer and sets its frame; the
    /// renderer sets `drawableSize` and `contentsScale` from the geometry.
    @MainActor public var layer: CAMetalLayer { layerBox.layer }

    // MARK: What to draw

    /// Says where the display lands in the layer, then redraws.
    public func setGeometry(_ geometry: RenderGeometry) {
        let newScale: Double? = state.withLock { state in
            state.inputs.geometry = geometry
            guard geometry.deviceScale > 0, geometry.deviceScale.isFinite, geometry.deviceScale != state.contentsScale else {
                return nil
            }
            state.contentsScale = geometry.deviceScale
            return geometry.deviceScale
        }
        if let newScale {
            let box = layerBox
            if Thread.isMainThread {
                MainActor.assumeIsolated { box.layer.contentsScale = newScale }
            } else {
                Task { @MainActor in box.layer.contentsScale = newScale }
            }
        }
        setNeedsRender()
    }

    /// The pointer position this client is driving, in the display's own pixels. While non-`nil` it
    /// replaces `CursorState.position`, so the pointer follows the finger without a network round trip.
    public func setLocalPointer(_ position: PixelPoint?) {
        let changed = state.withLock { state in
            guard state.inputs.localPointer != position else { return false }
            state.inputs.localPointer = position
            return true
        }
        if changed { setNeedsRender() }
    }

    /// Hides the client-drawn pointer regardless of what the session reports.
    public func setCursorHidden(_ hidden: Bool) {
        let changed = state.withLock { state in
            guard state.inputs.isCursorHidden != hidden else { return false }
            state.inputs.isCursorHidden = hidden
            return true
        }
        if changed { setNeedsRender() }
    }

    /// Colour of the area the display does not cover (sRGB, 0...1). Black by default.
    public func setBackgroundColor(red: Double, green: Double, blue: Double) {
        let colour = SIMD3(red, green, blue)
        let changed = state.withLock { state in
            guard state.inputs.background != colour else { return false }
            state.inputs.background = colour
            return true
        }
        if changed { setNeedsRender() }
    }

    /// Draws again with the current state. Needed only when something outside the renderer's
    /// knowledge changed, such as the layer returning to the screen.
    public func setNeedsRender() {
        guard let coreBox else { return }
        let shouldSchedule = state.withLock { state in
            if state.isDrawingSuspended || state.isRenderScheduled { return false }
            state.isRenderScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        let layerBox = layerBox
        queue.async { [weak self] in
            guard let self else { return }
            let inputs: RenderInputs? = self.state.withLock { state in
                state.isRenderScheduled = false
                // Suspended after this draw was asked for: the resume draws instead.
                return state.isDrawingSuspended ? nil : state.inputs
            }
            guard let inputs else { return }
            coreBox.core.render(inputs, to: layerBox.layer)
            let path = coreBox.core.texturePath
            self.state.withLock { $0.texturePath = path }
        }
    }

    /// Stops all drawing, at once and until ``resumeDrawing()``. Frames, pointer updates and
    /// geometry are still taken in, so the latest of each is drawn on resuming.
    ///
    /// iOS ends an app that uses the GPU while it is in the background or the device is locked, and
    /// the work that would draw (a frame already in the mailbox, a cursor update) does not stop by
    /// itself. Call this synchronously when the app is about to leave the foreground; it returns
    /// once a draw already under way has been handed over.
    public func suspendDrawing() {
        state.withLock { $0.isDrawingSuspended = true }
        queue.sync {}
    }

    /// Lets drawing continue after ``suspendDrawing()``, and draws the latest state: what changed
    /// meanwhile, and a layer the system may have emptied while the app was away.
    public func resumeDrawing() {
        let wasSuspended = state.withLock { state in
            defer { state.isDrawingSuspended = false }
            return state.isDrawingSuspended
        }
        if wasSuspended { setNeedsRender() }
    }

    public var isDrawingSuspended: Bool {
        state.withLock { $0.isDrawingSuspended }
    }

    // MARK: Sources

    /// Starts drawing a display's frames and, optionally, the session's pointer. Replaces any earlier
    /// sources. The streams are consumed in detached tasks, never on the main actor. Whatever was on
    /// screen stays there until the first new frame arrives.
    public func start(frames: FrameMailbox, cursor: AsyncStream<CursorState>?) {
        stop()
        let frameTask = Task.detached(priority: .userInitiated) { [weak self] in
            while let frame = await frames.next() {
                guard !Task.isCancelled, let self else { return }
                self.submit(frame)
            }
        }
        let cursorTask = cursor.map { stream in
            Task.detached(priority: .userInitiated) { [weak self] in
                for await cursor in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.submit(cursor)
                }
            }
        }
        let replaced = state.withLock { state in
            defer {
                state.frameTask = frameTask
                state.cursorTask = cursorTask
            }
            return (state.frameTask, state.cursorTask)
        }
        replaced.0?.cancel()
        replaced.1?.cancel()
    }

    /// Stops consuming the sources given to ``start(frames:cursor:)``. The last frame stays on screen
    /// and available to ``snapshot(maximumPixelDimension:)``.
    public func stop() {
        let tasks = state.withLock { state in
            defer {
                state.frameTask = nil
                state.cursorTask = nil
            }
            return (state.frameTask, state.cursorTask)
        }
        tasks.0?.cancel()
        tasks.1?.cancel()
    }

    /// Shows a frame directly, bypassing ``start(frames:cursor:)``.
    public func submit(_ frame: DisplayFrame) {
        // Standard-mode frames are sRGB, High Performance frames Display P3; the surface says which.
        let space = Imaging.colorSpace(of: frame.surface)
        let (waiters, newSpace): ([CheckedContinuation<Void, Never>], CGColorSpace?) = state.withLock { state in
            state.inputs.frame = frame
            state.inputs.frameSerial &+= 1
            var changed: CGColorSpace?
            if let space, state.layerColorSpace != space {
                state.layerColorSpace = space
                changed = space
            }
            defer { state.firstFrameWaiters.removeAll() }
            return (Array(state.firstFrameWaiters.values), changed)
        }
        if let newSpace {
            let box = layerBox
            if Thread.isMainThread {
                MainActor.assumeIsolated { box.layer.colorspace = newSpace }
            } else {
                Task { @MainActor in box.layer.colorspace = newSpace }
            }
        }
        for waiter in waiters { waiter.resume() }
        setNeedsRender()
    }

    /// The colour space of the frames being shown, once one has arrived.
    public var frameColorSpace: CGColorSpace? {
        state.withLock { $0.layerColorSpace }
    }

    /// Updates the pointer directly, bypassing ``start(frames:cursor:)``.
    public func submit(_ cursor: CursorState) {
        let changed = state.withLock { state in
            // `CursorImage` compares by identity, so this is cheap.
            guard state.inputs.cursor != cursor else { return false }
            state.inputs.cursor = cursor
            return true
        }
        if changed { setNeedsRender() }
    }

    // MARK: What is shown

    public var hasFrame: Bool {
        state.withLock { $0.inputs.frame != nil }
    }

    public var lastFramePixelSize: PixelSize? {
        state.withLock { $0.inputs.frame?.pixelSize }
    }

    /// How the most recently drawn frame reached the GPU; `nil` before the first draw.
    public var texturePath: TexturePath? {
        state.withLock { $0.texturePath }
    }

    /// Returns once at least one frame has arrived — immediately if one already has — or when the
    /// calling task is cancelled.
    public func firstFrame() async {
        let token: UInt64? = state.withLock { state in
            guard state.inputs.frame == nil else { return nil }
            state.nextWaiterToken += 1
            return state.nextWaiterToken
        }
        guard let token else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state in
                    if state.inputs.frame != nil || Task.isCancelled { return true }
                    state.firstFrameWaiters[token] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.firstFrameWaiters.removeValue(forKey: token) }
            waiter?.resume()
        }
    }

    /// The last frame as an image, without the pointer, optionally scaled down so that neither side
    /// exceeds `maximumPixelDimension`. Read back on the CPU; does not need a GPU.
    public func snapshot(maximumPixelDimension: Int? = nil) -> CGImage? {
        guard let frame = state.withLock({ $0.inputs.frame }) else { return nil }
        return Imaging.image(from: frame.surface, maximumPixelDimension: maximumPixelDimension)
    }

    /// Draws exactly what would be presented — background, display at the current geometry, pointer
    /// — into an image of the given pixel size, with the geometry's `viewSize` stretched over it.
    /// Waits for the GPU; meant for tests.
    public func renderOffscreen(pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard let coreBox else { return nil }
        let inputs = state.withLock { $0.inputs }
        let (image, path) = queue.sync {
            (coreBox.core.renderOffscreen(inputs, pixelWidth: pixelWidth, pixelHeight: pixelHeight), coreBox.core.texturePath)
        }
        state.withLock { $0.texturePath = path }
        return image
    }

    /// Waits until every draw requested so far has been handed to the GPU. For tests.
    func waitUntilIdle() {
        queue.sync {}
    }
}
