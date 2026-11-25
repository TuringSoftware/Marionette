// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore

/// The state machine behind both interpreters. They share everything about finger bookkeeping, the
/// two-finger scroll-or-zoom latch, momentum and button safety, and differ only in what one finger
/// does.
///
/// Invariants, relied on by the hosts and checked by the fuzz tests:
/// - `context.buttons` is empty whenever no finger is down.
/// - Every scroll `began` is followed by exactly one `ended` or `cancelled`; likewise for momentum.
/// - With `context.target == nil` nothing new is sent, but anything already held is still released.
struct GestureEngine: Sendable, Hashable {
    enum Style: Sendable, Hashable {
        case touch
        case trackpad
    }

    // MARK: Tuning that is not worth exposing

    /// How often `advance` wants to run while auto-panning or coasting.
    static let tickInterval = 1.0 / 60.0
    /// Longest step a single `advance` integrates, so a late timer cannot fling the content.
    static let maximumTick = 0.1
    /// Momentum decays as e^(-rate × t).
    static let momentumDecayRate = 3.0
    /// Finger speed (points per second) needed at lift for momentum to start, and below which it ends.
    static let momentumStartSpeed = 120.0
    static let momentumStopSpeed = 12.0
    /// A finger that rested this long before lifting was stopping, not flicking.
    static let momentumMaximumPause = 0.1

    // MARK: State

    private struct Finger: Sendable, Hashable {
        var id: Int
        var start: ViewPoint
        var startTime: Double
        var last: ViewPoint
        var lastTime: Double
        var maxTravel = 0.0
        /// Landed soon enough after a tap to be the second half of a double tap.
        var followsTap = false
    }

    private struct Drag: Sendable, Hashable {
        var id: Int
        var last: ViewPoint
        var lastTime: Double
        var lastTick: Double
        var autoPans = false
    }

    private struct TwoFinger: Sendable, Hashable {
        enum Latch: Sendable, Hashable {
            case undecided
            case scroll
            case zoom
            /// Forwarded gestures: a pinch for the remote app.
            case magnify
            /// Forwarded gestures: a rotation for the remote app.
            case rotate
        }

        var first: Int
        var second: Int
        /// When the second finger landed.
        var startTime: Double
        var startA: ViewPoint
        var startB: ViewPoint
        var startCentroid: ViewPoint
        var startSpacing: Double
        var lastCentroid: ViewPoint
        var lastSpacing: Double
        var latch = Latch.undecided
        /// Furthest either finger has been from where it was when the gesture started.
        var maxTravel = 0.0
        var scrollPosition = PixelPoint.zero
        /// The target `began` was sent to; `nil` until a scroll event has actually gone out.
        var scrollTarget: PointerTarget?
        /// Centroid velocity, view points per second, smoothed.
        var velocity = ViewVector.zero
        var velocityTime: Double
        var velocityCentroid: ViewPoint
        var lastMoveTime: Double
        /// From the first finger to the second, at the last update; for measuring rotation.
        var lastVector: ViewVector
        /// Radians turned since the gesture started; positive is clockwise on screen.
        var rotation = 0.0
        /// Where a forwarded magnify or rotate gesture sent its `began`; its end goes there too, even
        /// if the target has gone away since.
        var gestureTarget: PointerTarget?
        /// Started soon after a two-finger tap: if this is a tap too, the pair is a double tap.
        var followsTwoFingerTap = false

        func contains(_ id: Int) -> Bool { id == first || id == second }
    }

    /// Three fingers down at once (forwarded gestures only): a tap or a swipe.
    private struct ThreeFinger: Sendable, Hashable {
        var ids: [Int]
        var startCentroid: ViewPoint
        var startTime: Double
        var maxTravel = 0.0
    }

    /// A two-finger tap whose secondary click waits to see whether a second tap makes it smart zoom.
    private struct PendingSecondaryClick: Sendable, Hashable {
        var tapTime: Double
        var position: PixelPoint
    }

    /// One finger of an undecided two-finger gesture has lifted; if the other follows quickly it was
    /// a two-finger tap.
    private struct TwoFingerTap: Sendable, Hashable {
        var id: Int
        var start: ViewPoint
        var startTime: Double
        var centroid: ViewPoint
        var followsTwoFingerTap = false
    }

    private struct Tap: Sendable, Hashable {
        var time: Double
        var location: ViewPoint
        var position: PixelPoint
    }

    private struct Momentum: Sendable, Hashable {
        /// View points per second.
        var velocity: ViewVector
        /// Remote pixels per view point, signed for the scroll direction.
        var factor: Double
        var position: PixelPoint
        var target: PointerTarget
        var lastTick: Double
    }

    private enum State: Sendable, Hashable {
        case idle
        /// One finger down, nothing decided yet. The long-press timer is running.
        case pending(Finger)
        /// Touch mode: one finger pans the viewport.
        case panning(id: Int, last: ViewPoint)
        /// One finger moves the pointer with no button (touch: absolutely; trackpad: relatively).
        case moving(Finger)
        /// Long-press recognised; lifting clicks secondary, moving starts a drag.
        case longPressed(Finger)
        /// Primary button held.
        case dragging(Drag)
        case twoFinger(TwoFinger)
        case twoFingerTap(TwoFingerTap)
        case threeFinger(ThreeFinger)
        /// Waiting for every finger to lift before recognising anything new.
        case ignoring
    }

    let style: Style
    var configuration: GestureConfiguration
    var zoomAnchor: TrackpadInterpreter.ZoomAnchor

    /// Every finger currently down, including ones the active gesture ignores.
    private var touches: [Int: ViewPoint] = [:]
    private var state = State.idle
    private var lastTap: Tap?
    private var momentum: Momentum?
    private var pendingSecondaryClick: PendingSecondaryClick?
    /// The target the held buttons were pressed on, so they can be released even if it goes away.
    private var pressTarget: PointerTarget?
    /// Two-finger moves of one platform event are applied together; see `flushTwoFinger`.
    private var twoFingerNeedsUpdate = false
    private var twoFingerUpdateTime = 0.0

    init(style: Style, configuration: GestureConfiguration, zoomAnchor: TrackpadInterpreter.ZoomAnchor) {
        self.style = style
        self.configuration = configuration
        self.zoomAnchor = zoomAnchor
    }

    // MARK: Entry points

    mutating func handle(_ samples: [TouchSample], context: inout InteractionContext) -> [InteractionEffect] {
        var out: [InteractionEffect] = []
        for sample in samples {
            // Both fingers of a two-finger gesture usually move in the same event. Looking at them
            // one at a time would see a pinch in every fast scroll, so their moves are coalesced.
            let coalesces = sample.phase == .moved && isTwoFingerMember(sample.id)
            if !coalesces { flushTwoFinger(&context, &out) }
            // A late timer must not change the outcome: time is taken from the samples themselves.
            recogniseLongPress(at: sample.timestamp, &context, &out)
            switch sample.phase {
            case .began: began(sample, &context, &out)
            case .moved: moved(sample, &context, &out)
            case .ended: ended(sample, &context, &out)
            case .cancelled: cancelled(sample, &context, &out)
            }
        }
        flushTwoFinger(&context, &out)
        if touches.isEmpty {
            if state != .idle {
                abandon(&context, &out)
                state = .idle
            }
            releaseButtons(&context, &out)
        }
        return out
    }

    mutating func advance(to time: Double, context: inout InteractionContext) -> [InteractionEffect] {
        var out: [InteractionEffect] = []
        recogniseLongPress(at: time, &context, &out)
        autoPan(at: time, &context, &out)
        coast(at: time, &context, &out)
        if let pending = pendingSecondaryClick, time >= pending.tapTime + configuration.doubleTapInterval {
            firePendingSecondaryClick(&context, &out)
        }
        return out
    }

    var nextDeadline: Double? {
        var deadline: Double?
        if case .pending(let finger) = state {
            deadline = finger.startTime + configuration.longPressDuration
        }
        if case .dragging(let drag) = state, drag.autoPans {
            deadline = min(deadline ?? .infinity, drag.lastTick + Self.tickInterval)
        }
        if let momentum {
            deadline = min(deadline ?? .infinity, momentum.lastTick + Self.tickInterval)
        }
        if let pending = pendingSecondaryClick {
            deadline = min(deadline ?? .infinity, pending.tapTime + configuration.doubleTapInterval)
        }
        return deadline
    }

    mutating func cancel(context: inout InteractionContext) -> [InteractionEffect] {
        var out: [InteractionEffect] = []
        abandon(&context, &out)
        stopMomentum(&context, &out)
        pendingSecondaryClick = nil
        touches.removeAll()
        state = .idle
        return out
    }

    var isIdle: Bool {
        state == .idle && momentum == nil && touches.isEmpty && pendingSecondaryClick == nil
    }

    // MARK: Touch phases

    private mutating func began(_ sample: TouchSample, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        if touches[sample.id] != nil {
            // The platform repeated a `began`; treat it as movement of the finger we already know.
            moved(sample, &context, &out)
            return
        }
        stopMomentum(&context, &out)
        touches[sample.id] = sample.location

        switch state {
        case .idle:
            guard touches.count == 1 else {
                state = .ignoring
                return
            }
            var finger = Finger(
                id: sample.id,
                start: sample.location,
                startTime: sample.timestamp,
                last: sample.location,
                lastTime: sample.timestamp
            )
            if let tap = lastTap, sample.timestamp - tap.time <= configuration.doubleTapInterval {
                finger.followsTap = style == .trackpad
                    || sample.location.distance(to: tap.location) <= configuration.doubleTapSlop
            }
            state = .pending(finger)
        case .pending(let finger), .moving(let finger):
            beginTwoFinger(first: finger.id, second: sample.id, time: sample.timestamp)
        case .panning(let id, _):
            beginTwoFinger(first: id, second: sample.id, time: sample.timestamp)
        case .twoFinger(let gesture) where configuration.forwardsGestures && gesture.latch == .undecided && touches.count == 3:
            twoFingerNeedsUpdate = false
            state = .threeFinger(ThreeFinger(ids: Array(touches.keys), startCentroid: centroid(of: Array(touches.keys)), startTime: sample.timestamp))
        case .twoFingerTap:
            state = .ignoring
        case .longPressed, .dragging, .twoFinger, .threeFinger, .ignoring:
            // Extra fingers never disturb a drag or a latched two-finger gesture.
            break
        }
    }

    private mutating func moved(_ sample: TouchSample, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        guard let previous = touches[sample.id] else { return }
        touches[sample.id] = sample.location
        let delta = sample.location - previous

        switch state {
        case .twoFinger(let gesture) where gesture.contains(sample.id):
            twoFingerNeedsUpdate = true
            twoFingerUpdateTime = sample.timestamp

        case .twoFingerTap(let tap) where tap.id == sample.id:
            if sample.location.distance(to: tap.start) > configuration.tapSlop {
                state = .ignoring
            }

        case .threeFinger(var gesture) where gesture.ids.contains(sample.id):
            let travel = centroid(of: gesture.ids) - gesture.startCentroid
            gesture.maxTravel = max(gesture.maxTravel, travel.length)
            guard travel.length >= configuration.threeFingerSwipeDistance else {
                state = .threeFinger(gesture)
                return
            }
            state = .ignoring
            threeFingerSwipe(travel, &context, &out)

        case .pending(var finger) where finger.id == sample.id:
            let elapsed = sample.timestamp - finger.lastTime
            finger.maxTravel = max(finger.maxTravel, sample.location.distance(to: finger.start))
            finger.last = sample.location
            finger.lastTime = sample.timestamp
            let slop = style == .touch ? configuration.tapSlop : configuration.pointerMoveSlop
            guard finger.maxTravel > slop else {
                state = .pending(finger)
                return
            }
            lastTap = nil
            switch style {
            case .touch:
                if context.viewport.isPannable {
                    state = .panning(id: finger.id, last: sample.location)
                    pan(by: delta, &context, &out)
                } else {
                    state = .moving(finger)
                    point(context.viewport.remotePoint(for: sample.location), buttons: [], &context, &out)
                }
            case .trackpad:
                if finger.followsTap {
                    beginDrag(finger: finger, time: sample.timestamp, &context, &out)
                } else {
                    state = .moving(finger)
                }
                movePointer(by: delta, elapsed: elapsed, &context, &out)
            }

        case .panning(let id, _) where id == sample.id:
            state = .panning(id: id, last: sample.location)
            pan(by: delta, &context, &out)

        case .moving(var finger) where finger.id == sample.id:
            let elapsed = sample.timestamp - finger.lastTime
            finger.maxTravel = max(finger.maxTravel, sample.location.distance(to: finger.start))
            finger.last = sample.location
            finger.lastTime = sample.timestamp
            state = .moving(finger)
            switch style {
            case .touch:
                point(context.viewport.remotePoint(for: sample.location), buttons: [], &context, &out)
            case .trackpad:
                movePointer(by: delta, elapsed: elapsed, &context, &out)
            }

        case .longPressed(var finger) where finger.id == sample.id:
            let elapsed = sample.timestamp - finger.lastTime
            finger.last = sample.location
            finger.lastTime = sample.timestamp
            let slop = style == .touch ? configuration.tapSlop : configuration.pointerMoveSlop
            guard sample.location.distance(to: finger.start) > slop else {
                state = .longPressed(finger)
                return
            }
            switch style {
            case .touch:
                // The button goes down where the finger pressed, not where it has wandered to.
                point(context.viewport.remotePoint(for: finger.start), buttons: [], &context, &out)
                beginDrag(finger: finger, time: sample.timestamp, &context, &out)
                dragMoved(to: sample.location, time: sample.timestamp, &context, &out)
            case .trackpad:
                beginDrag(finger: finger, time: sample.timestamp, &context, &out)
                movePointer(by: delta, elapsed: elapsed, &context, &out)
            }

        case .dragging(var drag) where drag.id == sample.id:
            let elapsed = sample.timestamp - drag.lastTime
            drag.last = sample.location
            drag.lastTime = sample.timestamp
            state = .dragging(drag)
            switch style {
            case .touch:
                dragMoved(to: sample.location, time: sample.timestamp, &context, &out)
            case .trackpad:
                // Without a held button (no target when the drag started) the finger does nothing.
                if context.buttons.contains(.primary) {
                    movePointer(by: delta, elapsed: elapsed, &context, &out)
                }
            }

        default:
            break
        }
    }

    private mutating func ended(_ sample: TouchSample, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        guard touches.removeValue(forKey: sample.id) != nil else { return }

        switch state {
        case .pending(let finger) where finger.id == sample.id:
            state = .idle
            tap(finger, time: sample.timestamp, &context, &out)

        case .moving(let finger) where finger.id == sample.id:
            // A finger that moved the pointer was pointing, however short and quick its stroke: only
            // a touch that stayed put is a tap. Otherwise every nudge of the pointer would click, and
            // the next stroke would drag.
            state = .idle

        case .panning(let id, _) where id == sample.id:
            state = .idle

        case .longPressed(let finger) where finger.id == sample.id:
            state = .idle
            let position = style == .touch ? context.viewport.remotePoint(for: finger.start) : context.pointer
            secondaryClick(at: position, &context, &out)

        case .dragging(let drag) where drag.id == sample.id:
            state = .idle
            // On a trackpad the button coming up is felt too, more lightly than its going down.
            if style == .trackpad, context.buttons.contains(.primary) { out.append(.feedback(.dragEnded)) }
            releaseButtons(&context, &out)

        case .twoFinger(let gesture) where gesture.contains(sample.id):
            finishTwoFinger(gesture, lifted: sample.id, time: sample.timestamp, &context, &out)

        case .twoFingerTap(let tap) where tap.id == sample.id:
            state = .idle
            if sample.timestamp - tap.startTime <= configuration.maximumTapDuration {
                let position = style == .touch ? context.viewport.remotePoint(for: tap.centroid) : context.pointer
                if configuration.forwardsGestures {
                    if tap.followsTwoFingerTap, pendingSecondaryClick != nil {
                        pendingSecondaryClick = nil
                        sendGesture(.smartMagnify, phase: .none, context, &out)
                    } else {
                        // Wait: a second two-finger tap would make this smart zoom.
                        firePendingSecondaryClick(&context, &out)
                        pendingSecondaryClick = PendingSecondaryClick(tapTime: sample.timestamp, position: position)
                    }
                } else {
                    secondaryClick(at: position, &context, &out)
                }
            }

        case .threeFinger(let gesture) where gesture.ids.contains(sample.id):
            state = .idle
            if gesture.maxTravel <= configuration.tapSlop,
               sample.timestamp - gesture.startTime <= configuration.maximumTapDuration {
                firePendingSecondaryClick(&context, &out)
                lastTap = nil
                sendGesture(.quickLook, phase: .none, context, &out)
            }

        default:
            // A finger the active gesture was ignoring.
            break
        }

        if state == .idle, !touches.isEmpty {
            state = .ignoring
        }
    }

    private mutating func cancelled(_ sample: TouchSample, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        guard touches.removeValue(forKey: sample.id) != nil else { return }
        abandon(&context, &out)
        state = touches.isEmpty ? .idle : .ignoring
    }

    // MARK: One finger

    private mutating func tap(_ finger: Finger, time: Double, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        firePendingSecondaryClick(&context, &out)
        guard context.target != nil else {
            lastTap = nil
            return
        }
        let previous = finger.followsTap ? lastTap : nil
        let position: PixelPoint
        switch style {
        case .touch:
            // The second tap of a double tap lands on the first tap's exact pixel; otherwise the
            // remote machine may see two single clicks a few pixels apart.
            position = previous?.position ?? context.viewport.remotePoint(for: finger.last)
        case .trackpad:
            position = context.pointer
        }
        click(.primary, at: position, &context, &out)
        // A trackpad's click is felt; a touch on the picture itself is not.
        if style == .trackpad { out.append(.feedback(.click)) }
        lastTap = Tap(time: time, location: previous?.location ?? finger.last, position: context.pointer)
    }

    private mutating func secondaryClick(at position: PixelPoint, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        lastTap = nil
        guard context.target != nil else { return }
        click(.secondary, at: position, &context, &out)
        out.append(.feedback(.secondaryClick))
    }

    /// Presses the primary button at the pointer and enters the dragging state.
    private mutating func beginDrag(finger: Finger, time: Double, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        firePendingSecondaryClick(&context, &out)
        lastTap = nil
        state = .dragging(Drag(id: finger.id, last: finger.last, lastTime: time, lastTick: time))
        guard context.target != nil else { return }
        point(context.pointer, buttons: .primary, &context, &out)
        out.append(.feedback(.dragBegan))
    }

    /// Touch mode: the dragging finger is at `location`.
    private mutating func dragMoved(to location: ViewPoint, time: Double, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        guard case .dragging(var drag) = state else { return }
        if context.buttons.contains(.primary) {
            point(context.viewport.remotePoint(for: location), buttons: .primary, &context, &out)
        }
        let wantsAutoPan = context.buttons.contains(.primary)
            && context.viewport.edgeAutoPanVelocity(at: location) != .zero
        if wantsAutoPan, !drag.autoPans {
            drag.lastTick = time
        }
        drag.autoPans = wantsAutoPan
        state = .dragging(drag)
    }

    private mutating func autoPan(at time: Double, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        guard style == .touch, case .dragging(var drag) = state, drag.autoPans else { return }
        let elapsed = min(max(time - drag.lastTick, 0), Self.maximumTick)
        drag.lastTick = max(drag.lastTick, time)
        if elapsed > 0, context.buttons.contains(.primary), context.target != nil {
            let velocity = context.viewport.edgeAutoPanVelocity(at: drag.last)
            let applied = context.viewport.pan(by: velocity * elapsed)
            if applied != .zero {
                out.append(.viewportChanged)
                // The finger has not moved, but what is under it has.
                point(context.viewport.remotePoint(for: drag.last), buttons: .primary, &context, &out)
            }
        }
        drag.autoPans = context.buttons.contains(.primary)
            && context.viewport.edgeAutoPanVelocity(at: drag.last) != .zero
        state = .dragging(drag)
    }

    private mutating func recogniseLongPress(at time: Double, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        // Written exactly as `nextDeadline` computes it, so advancing to the deadline always fires.
        guard case .pending(let finger) = state,
              time >= finger.startTime + configuration.longPressDuration
        else { return }
        lastTap = nil
        state = .longPressed(finger)
        if context.target != nil {
            out.append(.feedback(.longPress))
        }
    }

    private mutating func pan(by delta: ViewVector, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        if context.viewport.pan(by: delta) != .zero {
            out.append(.viewportChanged)
        }
    }

    /// Trackpad mode: moves the pointer by a finger displacement and keeps it in view.
    private mutating func movePointer(by delta: ViewVector, elapsed: Double, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        guard let target = context.target else {
            releaseButtons(&context, &out)
            return
        }
        let distance = delta.length
        guard distance > 0, distance.isFinite else { return }
        var gain = configuration.pointerSpeed
        if configuration.pointerAcceleration, elapsed > 0 {
            gain *= Self.acceleration(forSpeed: distance / elapsed)
        }
        // Finger points become on-screen points, so the cursor tracks the finger at any zoom.
        let perPoint = gain / context.viewport.scale
        let wanted = PixelPoint(x: context.pointer.x + delta.dx * perPoint, y: context.pointer.y + delta.dy * perPoint)
        let moved = target.clamp(wanted)
        if moved != context.pointer {
            point(moved, buttons: context.buttons, &context, &out)
            if context.viewport.reveal(context.pointer) != .zero {
                out.append(.viewportChanged)
            }
        }
        if moved != wanted {
            out.append(.pointerPushedPastEdge(wanted))
        }
    }

    /// 1 up to 150 pt/s, rising linearly to 3 at 1500 pt/s.
    static func acceleration(forSpeed speed: Double) -> Double {
        guard speed.isFinite else { return 1 }
        return 1 + 2 * min(max((speed - 150) / 1350, 0), 1)
    }

    // MARK: Two fingers

    private func isTwoFingerMember(_ id: Int) -> Bool {
        if case .twoFinger(let gesture) = state { gesture.contains(id) } else { false }
    }

    private mutating func beginTwoFinger(first: Int, second: Int, time: Double) {
        lastTap = nil
        guard let a = touches[first], let b = touches[second] else {
            state = .ignoring
            return
        }
        let centroid = a.midpoint(to: b)
        let spacing = a.distance(to: b)
        state = .twoFinger(
            TwoFinger(
                first: first,
                second: second,
                startTime: time,
                startA: a,
                startB: b,
                startCentroid: centroid,
                startSpacing: spacing,
                lastCentroid: centroid,
                lastSpacing: spacing,
                velocityTime: time,
                velocityCentroid: centroid,
                lastMoveTime: time,
                lastVector: b - a,
                followsTwoFingerTap: pendingSecondaryClick.map { time - $0.tapTime <= configuration.doubleTapInterval } ?? false
            )
        )
    }

    private static func progress(_ value: Double, towards threshold: Double) -> Double {
        threshold > 0 ? value / threshold : (value > 0 ? .infinity : 0)
    }

    /// Remote pixels scrolled per view point of finger travel, signed.
    private func scrollFactor(_ context: InteractionContext) -> Double {
        (configuration.naturalScrolling ? 1 : -1) * configuration.scrollSpeed / context.viewport.scale
    }

    private mutating func flushTwoFinger(_ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        guard twoFingerNeedsUpdate else { return }
        twoFingerNeedsUpdate = false
        guard case .twoFinger(var gesture) = state,
              let a = touches[gesture.first],
              let b = touches[gesture.second]
        else { return }
        let time = twoFingerUpdateTime
        let centroid = a.midpoint(to: b)
        let spacing = a.distance(to: b)
        gesture.maxTravel = max(gesture.maxTravel, a.distance(to: gesture.startA), b.distance(to: gesture.startB))

        // Turned since the last update: the sine of the small angle between the two finger vectors.
        let vector = b - a
        var turn = 0.0
        if gesture.lastVector.length > 1, vector.length > 1 {
            turn = (gesture.lastVector.dx * vector.dy - gesture.lastVector.dy * vector.dx) / (gesture.lastVector.length * vector.length)
        }
        gesture.rotation += turn
        gesture.lastVector = vector

        if gesture.latch == .undecided {
            let scroll = Self.progress(centroid.distance(to: gesture.startCentroid), towards: configuration.twoFingerScrollThreshold)
            let pinch = Self.progress(abs(spacing - gesture.startSpacing), towards: configuration.twoFingerPinchThreshold)
            // How far the fingers have moved around each other, as distance: rotating one finger
            // about the other moves their midpoint too, so this is weighed against it below.
            let turned = abs(gesture.rotation) * gesture.startSpacing
            let rotate = configuration.forwardsGestures ? Self.progress(turned, towards: configuration.twoFingerPinchThreshold) : 0
            if max(scroll, pinch, rotate) >= 1 {
                if configuration.forwardsGestures {
                    // Not a tap after all: an earlier tap's click is due now.
                    firePendingSecondaryClick(&context, &out)
                    // Both fingers moving together scroll; fingers moving relative to each other
                    // pinch or rotate, whichever they do more.
                    let together = centroid.distance(to: gesture.startCentroid)
                    let apart = abs(spacing - gesture.startSpacing)
                    if together > max(apart, turned) {
                        gesture.latch = .scroll
                    } else {
                        gesture.latch = turned > apart ? .rotate : .magnify
                    }
                } else {
                    // Whichever is further past its threshold wins, and stays until the fingers lift.
                    gesture.latch = pinch > scroll ? .zoom : .scroll
                }
                if gesture.latch == .scroll {
                    gesture.scrollPosition = style == .touch
                        ? context.viewport.remotePoint(for: gesture.startCentroid)
                        : context.pointer
                }
            }
        }

        let delta = centroid - gesture.lastCentroid
        switch gesture.latch {
        case .undecided:
            break
        case .scroll:
            let factor = scrollFactor(context)
            sendScroll(&gesture, deltaX: delta.dx * factor, deltaY: delta.dy * factor, &context, &out)
            let elapsed = time - gesture.velocityTime
            if elapsed >= 0.004 {
                let instant = (centroid - gesture.velocityCentroid) * (1 / elapsed)
                gesture.velocity = gesture.velocity == .zero ? instant : gesture.velocity * 0.3 + instant * 0.7
                gesture.velocityTime = time
                gesture.velocityCentroid = centroid
            }
        case .zoom:
            let before = context.viewport
            let factor = gesture.lastSpacing > 1 && spacing > 1 ? spacing / gesture.lastSpacing : 1
            if style == .trackpad, zoomAnchor == .pointer {
                context.viewport.zoom(by: factor, around: context.viewport.viewPoint(for: context.pointer))
            } else {
                // Zoom about where the fingers were, then carry that spot to where they are now.
                context.viewport.zoom(by: factor, around: gesture.lastCentroid)
                context.viewport.pan(by: delta)
            }
            if context.viewport != before {
                out.append(.viewportChanged)
            }
        case .magnify:
            let factor = gesture.lastSpacing > 1 && spacing > 1 ? spacing / gesture.lastSpacing : 1
            continueGesture(&gesture, .magnify(factor - 1), changed: factor != 1, context, &out)
        case .rotate:
            // The Mac counts counter-clockwise as positive; on screen, y grows downwards.
            continueGesture(&gesture, .rotate(-turn * 180 / Double.pi), changed: turn != 0, context, &out)
        }

        gesture.lastCentroid = centroid
        gesture.lastSpacing = spacing
        gesture.lastMoveTime = time
        state = .twoFinger(gesture)
    }

    private mutating func sendScroll(
        _ gesture: inout TwoFinger,
        deltaX: Double,
        deltaY: Double,
        _ context: inout InteractionContext,
        _ out: inout [InteractionEffect]
    ) {
        guard let target = context.target else { return }
        let phase: ScrollEvent.Phase
        if gesture.scrollTarget == nil {
            if style == .touch {
                // Scrolling goes to whatever is under the pointer, so put the pointer under the fingers.
                point(gesture.scrollPosition, buttons: [], &context, &out)
            }
            gesture.scrollPosition = target.clamp(style == .touch ? gesture.scrollPosition : context.pointer)
            phase = .began
        } else {
            guard deltaX != 0 || deltaY != 0 else { return }
            phase = .changed
        }
        gesture.scrollTarget = target
        out.append(scroll(target, gesture.scrollPosition, deltaX, deltaY, phase: phase, momentum: .none, context))
    }

    private func scroll(
        _ target: PointerTarget,
        _ position: PixelPoint,
        _ deltaX: Double,
        _ deltaY: Double,
        phase: ScrollEvent.Phase,
        momentum: ScrollEvent.Phase,
        _ context: InteractionContext
    ) -> InteractionEffect {
        .input(
            .scroll(
                ScrollEvent(
                    display: target.display,
                    position: position,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    isPrecise: true,
                    phase: phase,
                    momentumPhase: momentum,
                    modifiers: context.modifiers,
                    layoutGeneration: target.layoutGeneration
                )
            )
        )
    }

    /// One of the two fingers lifted.
    private mutating func finishTwoFinger(
        _ gesture: TwoFinger,
        lifted: Int,
        time: Double,
        _ context: inout InteractionContext,
        _ out: inout [InteractionEffect]
    ) {
        state = .idle
        switch gesture.latch {
        case .undecided:
            let remaining = lifted == gesture.first ? gesture.second : gesture.first
            if gesture.maxTravel <= configuration.tapSlop,
               time - gesture.startTime <= configuration.maximumTapDuration,
               let location = touches[remaining] {
                state = .twoFingerTap(
                    TwoFingerTap(
                        id: remaining,
                        start: location,
                        startTime: gesture.startTime,
                        centroid: gesture.startCentroid,
                        followsTwoFingerTap: gesture.followsTwoFingerTap
                    )
                )
            }
        case .scroll:
            endScroll(gesture, time: time, phase: .ended, &context, &out)
        case .zoom:
            settleZoom(&context, &out)
        case .magnify:
            endGesture(gesture, .magnify(0), phase: .ended, context, &out)
        case .rotate:
            endGesture(gesture, .rotate(0), phase: .ended, context, &out)
        }
    }

    // MARK: Forwarded gestures

    private func centroid(of ids: [Int]) -> ViewPoint {
        let points = ids.compactMap { touches[$0] }
        guard !points.isEmpty else { return ViewPoint(x: 0, y: 0) }
        let n = Double(points.count)
        return ViewPoint(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n)
    }

    /// The next step of a magnify or rotate: its `began` the first time there is a target to send
    /// it to, `changed` after that whenever there is something to report.
    private func continueGesture(_ gesture: inout TwoFinger, _ kind: GestureEvent.Kind, changed: Bool, _ context: InteractionContext, _ out: inout [InteractionEffect]) {
        guard let target = context.target else { return }
        if gesture.gestureTarget == nil {
            gesture.gestureTarget = target
            sendGesture(kind, phase: .began, to: target, context, &out)
        } else if changed {
            sendGesture(kind, phase: .changed, to: target, context, &out)
        }
    }

    private func endGesture(_ gesture: TwoFinger, _ kind: GestureEvent.Kind, phase: ScrollEvent.Phase, _ context: InteractionContext, _ out: inout [InteractionEffect]) {
        guard let began = gesture.gestureTarget else { return }
        sendGesture(kind, phase: phase, to: context.target ?? began, context, &out)
    }

    private func sendGesture(_ kind: GestureEvent.Kind, phase: ScrollEvent.Phase, _ context: InteractionContext, _ out: inout [InteractionEffect]) {
        guard let target = context.target else { return }
        sendGesture(kind, phase: phase, to: target, context, &out)
    }

    private func sendGesture(_ kind: GestureEvent.Kind, phase: ScrollEvent.Phase, to target: PointerTarget, _ context: InteractionContext, _ out: inout [InteractionEffect]) {
        out.append(.input(.gesture(GestureEvent(
            kind: kind,
            phase: phase,
            display: target.display,
            position: target.clamp(context.pointer),
            layoutGeneration: target.layoutGeneration
        ))))
    }

    /// A two-finger tap's click, held back for a possible double tap, goes out now.
    private mutating func firePendingSecondaryClick(_ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        guard let pending = pendingSecondaryClick else { return }
        pendingSecondaryClick = nil
        secondaryClick(at: pending.position, &context, &out)
    }

    /// Three fingers swiped: what a Mac does with the same swipe (with its default settings).
    private mutating func threeFingerSwipe(_ travel: ViewVector, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        firePendingSecondaryClick(&context, &out)
        lastTap = nil
        guard context.target != nil else { return }
        let id: String
        if abs(travel.dx) > abs(travel.dy) {
            // Fingers going left bring in the space on the right, as on a Mac trackpad.
            id = travel.dx < 0 ? "system.spaceRight" : "system.spaceLeft"
        } else {
            id = travel.dy < 0 ? "system.missionControl" : "system.appWindows"
        }
        guard let shortcut = ShortcutCatalog.all.first(where: { $0.id == id }) else { return }
        out += shortcut.events.map { .input($0) }
    }

    private mutating func settleZoom(_ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        let before = context.viewport
        context.viewport.settle()
        if context.viewport != before {
            out.append(.viewportChanged)
        }
    }

    private mutating func endScroll(
        _ gesture: TwoFinger,
        time: Double,
        phase: ScrollEvent.Phase,
        _ context: inout InteractionContext,
        _ out: inout [InteractionEffect]
    ) {
        // Nothing was sent (no target), so there is nothing to end.
        guard let began = gesture.scrollTarget else { return }
        let target = context.target ?? began
        out.append(scroll(target, gesture.scrollPosition, 0, 0, phase: phase, momentum: .none, context))

        guard phase == .ended,
              configuration.momentum,
              time - gesture.lastMoveTime <= Self.momentumMaximumPause,
              gesture.velocity.length >= Self.momentumStartSpeed
        else { return }
        momentum = Momentum(
            velocity: gesture.velocity,
            factor: scrollFactor(context),
            position: gesture.scrollPosition,
            target: target,
            lastTick: time
        )
        out.append(scroll(target, gesture.scrollPosition, 0, 0, phase: .none, momentum: .began, context))
    }

    // MARK: Momentum

    private mutating func coast(at time: Double, _ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        guard var coasting = momentum else { return }
        let elapsed = min(max(time - coasting.lastTick, 0), Self.maximumTick)
        guard elapsed > 0 else { return }
        // e^(-x) for the small x of one tick, without needing libm.
        let x = Self.momentumDecayRate * elapsed
        let decay = 1 / (1 + x + x * x / 2)
        let travel = elapsed * (1 + decay) / 2
        let target = context.target ?? coasting.target
        let deltaX = coasting.velocity.dx * travel * coasting.factor
        let deltaY = coasting.velocity.dy * travel * coasting.factor
        coasting.velocity = coasting.velocity * decay
        coasting.lastTick = time
        coasting.target = target
        out.append(scroll(target, coasting.position, deltaX, deltaY, phase: .none, momentum: .changed, context))
        if coasting.velocity.length < Self.momentumStopSpeed {
            out.append(scroll(target, coasting.position, 0, 0, phase: .none, momentum: .ended, context))
            momentum = nil
        } else {
            momentum = coasting
        }
    }

    private mutating func stopMomentum(_ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        guard let coasting = momentum else { return }
        momentum = nil
        let target = context.target ?? coasting.target
        out.append(scroll(target, coasting.position, 0, 0, phase: .none, momentum: .cancelled, context))
    }

    // MARK: Pointer output

    /// Moves the pointer to `position` (clamped to the target) and reports it with `buttons`.
    private mutating func point(
        _ position: PixelPoint,
        buttons: PointerButtons,
        _ context: inout InteractionContext,
        _ out: inout [InteractionEffect]
    ) {
        guard let target = context.target else {
            // Nothing to aim at: nothing new may be pressed, and nothing may stay pressed.
            releaseButtons(&context, &out)
            return
        }
        let clamped = target.clamp(position)
        if clamped != context.pointer {
            context.pointer = clamped
            out.append(.pointerMoved)
        }
        context.buttons = buttons
        pressTarget = buttons.isEmpty ? nil : target
        out.append(
            .input(
                .pointer(
                    PointerEvent(
                        display: target.display,
                        position: clamped,
                        buttons: buttons,
                        layoutGeneration: target.layoutGeneration
                    )
                )
            )
        )
    }

    private mutating func click(
        _ button: PointerButtons,
        at position: PixelPoint,
        _ context: inout InteractionContext,
        _ out: inout [InteractionEffect]
    ) {
        guard context.target != nil else { return }
        point(position, buttons: [], &context, &out)
        point(position, buttons: button, &context, &out)
        point(position, buttons: [], &context, &out)
    }

    private mutating func releaseButtons(_ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        defer { pressTarget = nil }
        guard !context.buttons.isEmpty else { return }
        context.buttons = []
        // Prefer the live target; fall back to the one the press went to, which the back end may
        // discard as stale — the caller's `releaseAll` covers that case.
        guard let target = context.target ?? pressTarget else { return }
        out.append(
            .input(
                .pointer(
                    PointerEvent(
                        display: target.display,
                        position: target.clamp(context.pointer),
                        buttons: [],
                        layoutGeneration: target.layoutGeneration
                    )
                )
            )
        )
    }

    /// Ends whatever gesture is in progress without completing it.
    private mutating func abandon(_ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        twoFingerNeedsUpdate = false
        if case .twoFinger(let gesture) = state {
            switch gesture.latch {
            case .undecided:
                break
            case .scroll:
                endScroll(gesture, time: gesture.lastMoveTime, phase: .cancelled, &context, &out)
            case .zoom:
                settleZoom(&context, &out)
            case .magnify:
                endGesture(gesture, .magnify(0), phase: .cancelled, context, &out)
            case .rotate:
                endGesture(gesture, .rotate(0), phase: .cancelled, context, &out)
            }
        }
        releaseButtons(&context, &out)
        lastTap = nil
    }
}
