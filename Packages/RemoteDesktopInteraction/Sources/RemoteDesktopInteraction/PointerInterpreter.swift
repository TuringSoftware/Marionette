// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import RemoteDesktopCore

/// A mouse, a trackpad's system pointer or an Apple Pencil: an *absolute* pointer on the remote
/// display. Where the local pointer is, the remote pointer goes.
///
/// Complements the touch interpreters and shares their ``InteractionContext``: it updates
/// `context.pointer` and reports `.pointerMoved` so the locally drawn cursor follows. The buttons it
/// holds are its own (``heldButtons``); `context.buttons` belongs to the touch interpreters.
///
/// Invariants, checked by the fuzz tests:
/// - The remote machine's idea of the buttons always equals ``heldButtons``.
/// - ``heldButtons`` is empty after `setButtons([])`, after ``cancel(context:)`` and whenever a call
///   found `context.target == nil`.
/// - Every scroll `began` is followed by exactly one `ended` or `cancelled`.
/// - With `context.target == nil` nothing new is sent, but anything already held is still released.
public struct PointerInterpreter: Sendable, Hashable {
    public var configuration: GestureConfiguration

    /// The buttons held down on the remote machine by this interpreter.
    public private(set) var heldButtons: PointerButtons = []

    /// Buttons that are physically down but were not, or are no longer, pressed on the remote machine
    /// because there was nothing to aim at. They stay out until they are physically released.
    private var suppressed: PointerButtons = []
    /// The target the held buttons were pressed on, so they can be released even if it goes away.
    private var pressTarget: PointerTarget?
    /// The last pointer event this interpreter sent: what the remote machine was told.
    private var lastSent: PointerEvent?

    private struct ActiveScroll: Sendable, Hashable {
        var target: PointerTarget
        var position: PixelPoint
        var isPrecise: Bool
    }

    private var activeScroll: ActiveScroll?

    private struct Pencil: Sendable, Hashable {
        var id: Int
        /// Whether the tip's press reached the remote machine and is still held.
        var isPressing: Bool
    }

    private var pencil: Pencil?

    public init(configuration: GestureConfiguration = GestureConfiguration()) {
        self.configuration = configuration
    }

    /// No button is held, no scroll is in progress and the pencil is not touching.
    public var isIdle: Bool {
        heldButtons.isEmpty && activeScroll == nil && pencil == nil
    }

    // MARK: Entry points

    /// The system pointer moved over the view with no change of buttons: a hover, or a drag while
    /// buttons are held. Sends nothing when the remote pointer is already there.
    public mutating func move(to location: ViewPoint, context: inout InteractionContext) -> [InteractionEffect] {
        var out: [InteractionEffect] = []
        guard let target = context.target else {
            loseTarget(&context, &out)
            return out
        }
        arrive(at: position(for: location, target, context), target, &context, &out)
        return out
    }

    /// The complete set of mouse buttons now physically held, at a location.
    ///
    /// Moves the pointer there first (with the buttons as they were), then sends one pointer event
    /// per button that changed: releases before presses.
    public mutating func setButtons(
        _ buttons: PointerButtons,
        at location: ViewPoint,
        context: inout InteractionContext
    ) -> [InteractionEffect] {
        var out: [InteractionEffect] = []
        suppressed.formIntersection(buttons)
        guard let target = context.target else {
            loseTarget(&context, &out)
            suppressed.formUnion(buttons)
            return out
        }
        let position = position(for: location, target, context)
        arrive(at: position, target, &context, &out)
        change(to: buttons.subtracting(suppressed), at: position, target, &context, &out)
        return out
    }

    /// A scroll step from a wheel or a trackpad, aimed at what is under `location`.
    ///
    /// - Precise sources (`isPrecise` true): `delta` is how far the fingers travelled, in view
    ///   points, as a pan gesture reports it. It is converted to remote pixels exactly as the touch
    ///   interpreters do, honouring ``GestureConfiguration/naturalScrolling`` and
    ///   ``GestureConfiguration/scrollSpeed``: with natural scrolling, fingers moving down give a
    ///   positive `deltaY`.
    /// - Wheels (`isPrecise` false): `delta` counts wheel lines in ``ScrollEvent``'s own convention
    ///   (positive moves content down or right) and is passed through untouched.
    ///
    /// `phase` is `.none` for a wheel notch. For a gesture, pass `.began`, `.changed` and then
    /// `.ended` or `.cancelled`; the position stays where the gesture began. A `.changed` without a
    /// `.began` starts a scroll, a second `.began` cancels the first, and an end without a scroll in
    /// progress is ignored, so the phases that go out are always balanced.
    public mutating func scroll(
        by delta: ViewVector,
        at location: ViewPoint,
        phase: ScrollEvent.Phase,
        isPrecise: Bool,
        context: inout InteractionContext
    ) -> [InteractionEffect] {
        var out: [InteractionEffect] = []
        var deltaX = delta.dx.isFinite ? delta.dx : 0
        var deltaY = delta.dy.isFinite ? delta.dy : 0
        if isPrecise {
            // Remote pixels scrolled per view point of finger travel, signed.
            let factor = (configuration.naturalScrolling ? 1 : -1) * configuration.scrollSpeed / context.viewport.scale
            deltaX *= factor
            deltaY *= factor
        }
        let moves = deltaX != 0 || deltaY != 0

        switch phase {
        case .none:
            guard moves, let target = context.target else { break }
            let position = position(for: location, target, context)
            arrive(at: position, target, &context, &out)
            out.append(scrollEffect(target, position, deltaX, deltaY, isPrecise: isPrecise, phase: .none, context))

        case .began, .changed:
            guard let target = context.target else { break }
            if phase == .began {
                endScroll(.cancelled, &context, &out)
            }
            if var active = activeScroll {
                guard moves else { break }
                active.target = target
                active.position = target.clamp(active.position)
                active.isPrecise = isPrecise
                activeScroll = active
                out.append(scrollEffect(target, active.position, deltaX, deltaY, isPrecise: isPrecise, phase: .changed, context))
            } else {
                // Scrolling goes to whatever is under the pointer, so the pointer goes there first.
                let position = position(for: location, target, context)
                arrive(at: position, target, &context, &out)
                activeScroll = ActiveScroll(target: target, position: position, isPrecise: isPrecise)
                out.append(scrollEffect(target, position, deltaX, deltaY, isPrecise: isPrecise, phase: .began, context))
            }

        case .ended, .cancelled:
            if moves, phase == .ended, let active = activeScroll, let target = context.target {
                // The last step arrived together with the end; ends themselves carry no distance.
                out.append(scrollEffect(target, target.clamp(active.position), deltaX, deltaY, isPrecise: isPrecise, phase: .changed, context))
            }
            endScroll(phase, &context, &out)
        }
        return out
    }

    /// A magnify step (a pinch on a trackpad): zooms the viewport around `location`. Nothing is sent
    /// to the remote machine. Call `context.viewport.settle()` when the pinch ends to snap back to
    /// fit.
    public mutating func magnify(
        by factor: Double,
        at location: ViewPoint,
        context: inout InteractionContext
    ) -> [InteractionEffect] {
        guard location.x.isFinite, location.y.isFinite else { return [] }
        let before = context.viewport
        context.viewport.zoom(by: factor, around: location)
        return context.viewport != before ? [.viewportChanged] : []
    }

    /// The tip of an Apple Pencil. `began` moves the pointer there and presses the primary button,
    /// `moved` drags, `ended` releases at the final location, `cancelled` releases where the pointer
    /// is. Pencil hover uses ``move(to:context:)``.
    ///
    /// One pencil at a time: samples with another `id` are ignored until the first one lifts.
    public mutating func pencil(_ sample: TouchSample, context: inout InteractionContext) -> [InteractionEffect] {
        var out: [InteractionEffect] = []
        if let current = pencil, current.id != sample.id { return out }

        switch sample.phase {
        case .began where pencil == nil:
            pencil = Pencil(id: sample.id, isPressing: false)
            guard let target = context.target else {
                loseTarget(&context, &out)
                break
            }
            let position = position(for: sample.location, target, context)
            arrive(at: position, target, &context, &out)
            change(to: heldButtons.union(.primary), at: position, target, &context, &out)
            pencil?.isPressing = true

        case .began, .moved:
            // Without a press (no target when the tip landed, or it went away) the pencil does nothing.
            guard let current = pencil, current.isPressing else { break }
            guard let target = context.target, heldButtons.contains(.primary) else {
                pencil?.isPressing = false
                if context.target == nil { loseTarget(&context, &out) }
                break
            }
            arrive(at: position(for: sample.location, target, context), target, &context, &out)

        case .ended:
            guard let current = pencil else { break }
            pencil = nil
            guard current.isPressing, heldButtons.contains(.primary) else { break }
            guard let target = context.target else {
                loseTarget(&context, &out)
                break
            }
            let position = position(for: sample.location, target, context)
            arrive(at: position, target, &context, &out)
            change(to: heldButtons.subtracting(.primary), at: position, target, &context, &out)

        case .cancelled:
            guard let current = pencil else { break }
            pencil = nil
            guard current.isPressing, heldButtons.contains(.primary) else { break }
            guard let target = context.target else {
                loseTarget(&context, &out)
                break
            }
            change(to: heldButtons.subtracting(.primary), at: target.clamp(context.pointer), target, &context, &out)
        }
        return out
    }

    /// Abandons whatever is in progress: ends a scroll with `.cancelled`, releases every held button
    /// with one pointer event at the pointer's position, and forgets the pencil. Afterwards the
    /// interpreter is as new; a button that is still physically down is pressed again by the next
    /// ``setButtons(_:at:context:)`` that names it.
    public mutating func cancel(context: inout InteractionContext) -> [InteractionEffect] {
        var out: [InteractionEffect] = []
        endScroll(.cancelled, &context, &out)
        releaseButtons(&context, &out)
        suppressed = []
        pencil = nil
        return out
    }

    // MARK: Pointer output

    /// The remote position under a view location, always a valid pixel of the target.
    private func position(for location: ViewPoint, _ target: PointerTarget, _ context: InteractionContext) -> PixelPoint {
        guard location.x.isFinite, location.y.isFinite else { return target.clamp(context.pointer) }
        return target.clamp(context.viewport.remotePoint(for: location))
    }

    /// Puts the pointer at `position` with the buttons as they are, unless the remote machine has
    /// already been told exactly that.
    private mutating func arrive(
        at position: PixelPoint,
        _ target: PointerTarget,
        _ context: inout InteractionContext,
        _ out: inout [InteractionEffect]
    ) {
        let event = PointerEvent(
            display: target.display,
            position: position,
            buttons: heldButtons,
            layoutGeneration: target.layoutGeneration
        )
        if event == lastSent, context.pointer == position { return }
        send(event, target, &context, &out)
    }

    /// Changes the held buttons one at a time, releases first, without moving.
    private mutating func change(
        to wanted: PointerButtons,
        at position: PixelPoint,
        _ target: PointerTarget,
        _ context: inout InteractionContext,
        _ out: inout [InteractionEffect]
    ) {
        guard wanted != heldButtons else { return }
        var buttons = heldButtons
        for pressing in [false, true] {
            for bit in 0..<PointerButtons.RawValue.bitWidth {
                let button = PointerButtons(rawValue: 1 << PointerButtons.RawValue(bit))
                guard buttons.contains(button) != wanted.contains(button), wanted.contains(button) == pressing else { continue }
                if pressing { buttons.insert(button) } else { buttons.remove(button) }
                send(
                    PointerEvent(display: target.display, position: position, buttons: buttons, layoutGeneration: target.layoutGeneration),
                    target,
                    &context,
                    &out
                )
            }
        }
    }

    private mutating func send(
        _ event: PointerEvent,
        _ target: PointerTarget,
        _ context: inout InteractionContext,
        _ out: inout [InteractionEffect]
    ) {
        if event.position != context.pointer {
            context.pointer = event.position
            out.append(.pointerMoved)
        }
        heldButtons = event.buttons
        pressTarget = event.buttons.isEmpty ? nil : target
        lastSent = event
        out.append(.input(.pointer(event)))
    }

    /// There is nothing to aim at: nothing new may be pressed, and nothing may stay pressed.
    private mutating func loseTarget(_ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        suppressed.formUnion(heldButtons)
        if pencil != nil { pencil?.isPressing = false }
        releaseButtons(&context, &out)
    }

    private mutating func releaseButtons(_ context: inout InteractionContext, _ out: inout [InteractionEffect]) {
        defer { pressTarget = nil }
        guard !heldButtons.isEmpty else { return }
        heldButtons = []
        // Prefer the live target; fall back to the one the press went to, which the back end may
        // discard as stale — the caller's `releaseAll` covers that case.
        guard let target = context.target ?? pressTarget else {
            lastSent = nil
            return
        }
        let event = PointerEvent(
            display: target.display,
            position: target.clamp(context.pointer),
            buttons: [],
            layoutGeneration: target.layoutGeneration
        )
        lastSent = event
        out.append(.input(.pointer(event)))
    }

    // MARK: Scroll output

    private mutating func endScroll(
        _ phase: ScrollEvent.Phase,
        _ context: inout InteractionContext,
        _ out: inout [InteractionEffect]
    ) {
        guard let active = activeScroll else { return }
        activeScroll = nil
        // Goes to the display the scroll began on when there is no target any more.
        let target = context.target ?? active.target
        out.append(scrollEffect(target, target.clamp(active.position), 0, 0, isPrecise: active.isPrecise, phase: phase, context))
    }

    private func scrollEffect(
        _ target: PointerTarget,
        _ position: PixelPoint,
        _ deltaX: Double,
        _ deltaY: Double,
        isPrecise: Bool,
        phase: ScrollEvent.Phase,
        _ context: InteractionContext
    ) -> InteractionEffect {
        .input(
            .scroll(
                ScrollEvent(
                    display: target.display,
                    position: position,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    isPrecise: isPrecise,
                    phase: phase,
                    modifiers: context.modifiers,
                    layoutGeneration: target.layoutGeneration
                )
            )
        )
    }
}
