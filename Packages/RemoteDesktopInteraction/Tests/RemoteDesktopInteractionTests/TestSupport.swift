// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import RemoteDesktopInteraction

let testDisplay = DisplayID(1)
let testTarget = PointerTarget(display: testDisplay, pixelSize: PixelSize(width: 800, height: 600), layoutGeneration: 7)

/// A 400 × 300 view showing an 800 × 600 display fitted: scale 0.5, so remote = view × 2. Not pannable.
func fittedContext() -> InteractionContext {
    InteractionContext(
        viewport: ViewportModel(
            viewSize: ViewSize(width: 400, height: 300),
            contentSize: PixelSize(width: 800, height: 600),
            deviceScale: 2
        ),
        target: testTarget,
        pointer: PixelPoint(x: 400, y: 300)
    )
}

/// The same view zoomed to scale 1 around its centre: origin (−200, −150), pannable both ways.
func zoomedContext() -> InteractionContext {
    var context = fittedContext()
    context.viewport.setScale(1, around: ViewPoint(x: 200, y: 150))
    return context
}

/// Drives an interpreter and keeps everything it emitted.
struct Rig<Interpreter: GestureInterpreter> {
    var interpreter: Interpreter
    var context: InteractionContext
    var log: [InteractionEffect] = []

    init(_ interpreter: Interpreter, _ context: InteractionContext = fittedContext()) {
        self.interpreter = interpreter
        self.context = context
    }

    @discardableResult
    mutating func send(_ samples: [TouchSample]) -> [InteractionEffect] {
        let effects = interpreter.handle(samples, context: &context)
        log += effects
        return effects
    }

    @discardableResult
    mutating func down(_ id: Int, _ x: Double, _ y: Double, at time: Double) -> [InteractionEffect] {
        send([sample(id, .began, x, y, time)])
    }

    @discardableResult
    mutating func move(_ id: Int, _ x: Double, _ y: Double, at time: Double) -> [InteractionEffect] {
        send([sample(id, .moved, x, y, time)])
    }

    @discardableResult
    mutating func up(_ id: Int, _ x: Double, _ y: Double, at time: Double) -> [InteractionEffect] {
        send([sample(id, .ended, x, y, time)])
    }

    @discardableResult
    mutating func down(_ x: Double, _ y: Double, at time: Double) -> [InteractionEffect] {
        down(0, x, y, at: time)
    }

    @discardableResult
    mutating func move(_ x: Double, _ y: Double, at time: Double) -> [InteractionEffect] {
        move(0, x, y, at: time)
    }

    @discardableResult
    mutating func up(_ x: Double, _ y: Double, at time: Double) -> [InteractionEffect] {
        up(0, x, y, at: time)
    }

    @discardableResult
    mutating func advance(to time: Double) -> [InteractionEffect] {
        let effects = interpreter.advance(to: time, context: &context)
        log += effects
        return effects
    }

    @discardableResult
    mutating func cancel() -> [InteractionEffect] {
        let effects = interpreter.cancel(context: &context)
        log += effects
        return effects
    }

    /// Runs timers at their own deadlines until none is left or `limit` is reached.
    @discardableResult
    mutating func runTimers(until limit: Double) -> [InteractionEffect] {
        var effects: [InteractionEffect] = []
        var guardCount = 0
        while let deadline = interpreter.nextDeadline, deadline <= limit, guardCount < 10_000 {
            effects += advance(to: deadline)
            guardCount += 1
        }
        return effects
    }
}

func sample(_ id: Int, _ phase: TouchSample.Phase, _ x: Double, _ y: Double, _ time: Double) -> TouchSample {
    TouchSample(id: id, phase: phase, location: ViewPoint(x: x, y: y), timestamp: time)
}

extension Array where Element == InteractionEffect {
    var inputs: [InputEvent] {
        compactMap { if case .input(let event) = $0 { event } else { nil } }
    }

    var pointers: [PointerEvent] {
        inputs.compactMap { if case .pointer(let event) = $0 { event } else { nil } }
    }

    var scrolls: [ScrollEvent] {
        inputs.compactMap { if case .scroll(let event) = $0 { event } else { nil } }
    }

    var feedback: [InteractionEffect.Feedback] {
        compactMap { if case .feedback(let kind) = $0 { kind } else { nil } }
    }

    var changesViewport: Bool { contains(.viewportChanged) }
}

func pointer(_ x: Double, _ y: Double, _ buttons: PointerButtons = []) -> PointerEvent {
    PointerEvent(display: testDisplay, position: PixelPoint(x: x, y: y), buttons: buttons, layoutGeneration: 7)
}

func approximately(_ a: Double, _ b: Double, tolerance: Double = 1e-6) -> Bool {
    abs(a - b) <= tolerance
}

/// Deterministic generator for the seeded tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
