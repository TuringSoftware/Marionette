// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import RemoteDesktopInteraction
import Testing

/// Throws random, frequently nonsensical touch sequences at an interpreter and checks the promises
/// that keep the remote machine sane: no stuck buttons, balanced scroll phases, valid coordinates.
private struct Fuzzer<Interpreter: GestureInterpreter> {
    var interpreter: Interpreter
    var context: InteractionContext
    var generator: SplitMix64
    var time = 0.0
    /// Fingers the platform believes are down.
    var down: [Int: ViewPoint] = [:]

    var remoteButtons: PointerButtons = []
    var scrolling = false
    var coasting = false
    /// Forwarded magnify or rotate gestures with a `began` and no end yet.
    var gesturing = false
    var keysDown: Set<KeyCode> = []
    var events = 0
    /// The most fingers the interpreter may send as touches; `nil` for one that sends none.
    var maximumContacts: Int?
    /// Contact ids the remote machine has been told are touching.
    var touching: Set<Int> = []

    mutating func check(_ effects: [InteractionEffect], _ step: String) {
        for effect in effects {
            guard case .input(let input) = effect else { continue }
            events += 1
            switch input {
            case .pointer(let event):
                remoteButtons = event.buttons
                #expect(event.position.x.isFinite && event.position.y.isFinite, "\(step)")
                #expect(event.position.x >= 0 && event.position.x <= 799 && event.position.y >= 0 && event.position.y <= 599, "\(step)")
            case .scroll(let event):
                #expect(event.deltaX.isFinite && event.deltaY.isFinite, "\(step)")
                #expect(event.isPrecise)
                switch (event.phase, event.momentumPhase) {
                case (.began, .none):
                    #expect(!scrolling && !coasting, "scroll began twice: \(step)")
                    scrolling = true
                case (.changed, .none):
                    #expect(scrolling, "scroll changed outside a scroll: \(step)")
                case (.ended, .none), (.cancelled, .none):
                    #expect(scrolling, "scroll ended outside a scroll: \(step)")
                    scrolling = false
                case (.none, .began):
                    #expect(!scrolling && !coasting, "momentum began unexpectedly: \(step)")
                    coasting = true
                case (.none, .changed):
                    #expect(coasting, "momentum changed outside momentum: \(step)")
                case (.none, .ended), (.none, .cancelled):
                    #expect(coasting, "momentum ended outside momentum: \(step)")
                    coasting = false
                default:
                    Issue.record("unexpected scroll phases \(event.phase)/\(event.momentumPhase): \(step)")
                }
            case .gesture(let event):
                #expect(event.position.x >= 0 && event.position.x <= 799 && event.position.y >= 0 && event.position.y <= 599, "\(step)")
                switch event.kind {
                case .magnify(let amount): #expect(amount.isFinite, "\(step)")
                case .rotate(let degrees): #expect(degrees.isFinite, "\(step)")
                case .smartMagnify, .quickLook, .swipe: break
                }
                switch event.phase {
                case .began:
                    #expect(!gesturing, "gesture began twice: \(step)")
                    gesturing = true
                case .changed:
                    #expect(gesturing, "gesture changed outside a gesture: \(step)")
                case .ended, .cancelled:
                    #expect(gesturing, "gesture ended outside a gesture: \(step)")
                    gesturing = false
                case .none:
                    #expect(!gesturing, "one-shot gesture inside a gesture: \(step)")
                }
            case .key(let event):
                // Only a three-finger swipe sends keys: a whole shortcut, pressed and released at once.
                if let key = event.key { if event.phase == .down { keysDown.insert(key) } else { keysDown.remove(key) } }
            case .text, .releaseAll:
                Issue.record("interpreters never send text: \(step)")
            case .touch(let event):
                guard let maximumContacts else {
                    Issue.record("only the direct-touch interpreter sends touches: \(step)")
                    continue
                }
                let ids = event.contacts.map(\.id)
                #expect(Set(ids).count == ids.count, "a contact twice in one event: \(step)")
                #expect(ids.allSatisfy { (0..<maximumContacts).contains($0) }, "contact id out of range: \(step)")
                for contact in event.contacts {
                    #expect(contact.position.x >= 0 && contact.position.x <= 799 && contact.position.y >= 0 && contact.position.y <= 599, "\(step)")
                    if contact.phase == .touching {
                        touching.insert(contact.id)
                    } else {
                        #expect(touching.remove(contact.id) != nil, "a contact let go that was not down: \(step)")
                    }
                }
                // Every finger down is in every event.
                #expect(Set(ids).isSuperset(of: touching), "a finger down left out of an event: \(step)")
            }
        }
        #expect(keysDown.isEmpty, "a key was left down: \(step)")
        #expect(remoteButtons == context.buttons, "remote and context disagree on buttons: \(step)")
        if down.isEmpty {
            #expect(context.buttons.isEmpty, "button stuck with no finger down: \(step)")
            #expect(!scrolling, "scroll still open with no finger down: \(step)")
            #expect(!gesturing, "gesture still open with no finger down: \(step)")
        }
        let viewport = context.viewport
        #expect(viewport.scale.isFinite && viewport.scale > 0 && viewport.origin.x.isFinite && viewport.origin.y.isFinite, "\(step)")
        #expect(context.pointer.x.isFinite && context.pointer.y.isFinite, "\(step)")
    }

    mutating func randomPoint() -> ViewPoint {
        ViewPoint(x: Double.random(in: -20...420, using: &generator), y: Double.random(in: -20...320, using: &generator))
    }

    mutating func step(_ index: Int) {
        time += [0, 0.004, 0.016, 0.05, 0.2, 0.6].randomElement(using: &generator)!
        let id = Int.random(in: 0...3, using: &generator)
        switch Int.random(in: 0..<100, using: &generator) {
        case 0..<22:
            let location = randomPoint()
            down[id] = location
            check(interpreter.handle([sample(id, .began, location.x, location.y, time)], context: &context), "began \(index)")
        case 22..<60:
            // Move every finger a little, in one event, as the platform does. Sometimes far.
            var samples: [TouchSample] = []
            let reach = Bool.random(using: &generator) ? 6.0 : 60.0
            for key in down.keys.sorted() {
                let from = down[key]!
                let to = ViewPoint(
                    x: from.x + Double.random(in: -reach...reach, using: &generator),
                    y: from.y + Double.random(in: -reach...reach, using: &generator)
                )
                down[key] = to
                samples.append(sample(key, .moved, to.x, to.y, time))
            }
            if Int.random(in: 0..<10, using: &generator) == 0 {
                samples.append(sample(9, .moved, 1, 1, time))   // a finger nobody announced
            }
            check(interpreter.handle(samples, context: &context), "moved \(index)")
        case 60..<80:
            // Lifting a finger that may not be down is part of the test.
            let location = down.removeValue(forKey: id) ?? randomPoint()
            check(interpreter.handle([sample(id, .ended, location.x, location.y, time)], context: &context), "ended \(index)")
        case 80..<84:
            let location = down.removeValue(forKey: id) ?? randomPoint()
            check(interpreter.handle([sample(id, .cancelled, location.x, location.y, time)], context: &context), "cancelled \(index)")
        case 84..<92:
            check(interpreter.advance(to: time, context: &context), "advance \(index)")
            if let deadline = interpreter.nextDeadline {
                #expect(deadline.isFinite)
            }
        case 92..<95:
            context.target = context.target == nil ? testTarget : nil
            // Nothing to check until the interpreter next runs.
        case 95..<97:
            context.viewport.setMode(ViewportModel.ZoomMode.allCases.randomElement(using: &generator)!)
        case 97..<98:
            context.viewport.viewSize = ViewSize(
                width: Double.random(in: 0...500, using: &generator),
                height: Double.random(in: 0...500, using: &generator)
            )
        default:
            down.removeAll()   // after `cancel` the interpreter has forgotten every finger
            check(interpreter.cancel(context: &context), "cancel \(index)")
        }
    }

    mutating func finish() {
        let samples = down.keys.sorted().map { sample($0, .ended, down[$0]!.x, down[$0]!.y, time) }
        down.removeAll()
        check(interpreter.handle(samples, context: &context), "final lift")
        var ticks = 0
        while let deadline = interpreter.nextDeadline, ticks < 5_000 {
            time = max(time, deadline)
            check(interpreter.advance(to: time, context: &context), "final tick \(ticks)")
            ticks += 1
        }
        #expect(interpreter.nextDeadline == nil)
        #expect(interpreter.isIdle)
        #expect(context.buttons.isEmpty)
        #expect(remoteButtons.isEmpty)
        #expect(!scrolling)
        #expect(!coasting)
        #expect(!gesturing)
        #expect(touching.isEmpty, "a finger left down on the remote machine")
    }
}

@Suite struct GestureFuzzTests {
    @Test(arguments: 1...40)
    func touchInterpreterNeverLeavesAnythingStuck(seed: Int) {
        var fuzzer = Fuzzer(interpreter: TouchInterpreter(), context: seed.isMultiple(of: 2) ? fittedContext() : zoomedContext(), generator: SplitMix64(seed: UInt64(seed)))
        for index in 0..<400 { fuzzer.step(index) }
        fuzzer.finish()
        #expect(fuzzer.events > 0)
    }

    @Test(arguments: 1...40)
    func trackpadInterpreterNeverLeavesAnythingStuck(seed: Int) {
        let anchor: TrackpadInterpreter.ZoomAnchor = seed.isMultiple(of: 3) ? .pointer : .touchCentroid
        var fuzzer = Fuzzer(
            interpreter: TrackpadInterpreter(zoomAnchor: anchor),
            context: seed.isMultiple(of: 2) ? fittedContext() : zoomedContext(),
            generator: SplitMix64(seed: UInt64(seed) &+ 1000)
        )
        for index in 0..<400 { fuzzer.step(index) }
        fuzzer.finish()
        #expect(fuzzer.events > 0)
    }

    @Test(arguments: 1...40)
    func aForwardingTrackpadNeverLeavesAnythingStuck(seed: Int) {
        var configuration = GestureConfiguration()
        configuration.forwardsGestures = true
        var fuzzer = Fuzzer(
            interpreter: TrackpadInterpreter(configuration: configuration, zoomAnchor: .pointer),
            context: seed.isMultiple(of: 2) ? fittedContext() : zoomedContext(),
            generator: SplitMix64(seed: UInt64(seed) &+ 5000)
        )
        for index in 0..<400 { fuzzer.step(index) }
        fuzzer.finish()
        #expect(fuzzer.events > 0)
    }

    @Test(arguments: 1...40)
    func directTouchNeverLeavesAFingerDown(seed: Int) {
        let maximum = seed % 4 + 1
        var fuzzer = Fuzzer(
            interpreter: DirectTouchInterpreter(maximumContacts: maximum),
            context: seed.isMultiple(of: 2) ? fittedContext() : zoomedContext(),
            generator: SplitMix64(seed: UInt64(seed) &+ 9000)
        )
        fuzzer.maximumContacts = maximum
        for index in 0..<400 { fuzzer.step(index) }
        fuzzer.finish()
        #expect(fuzzer.events > 0)
    }

    @Test func theSameInputAlwaysProducesTheSameOutput() {
        func run() -> ([InteractionEffect], InteractionContext) {
            var rig = Rig(TouchInterpreter(), zoomedContext())
            var generator = SplitMix64(seed: 7)
            var time = 0.0
            for _ in 0..<300 {
                time += Double.random(in: 0...0.1, using: &generator)
                let phase: TouchSample.Phase = [.began, .moved, .moved, .ended].randomElement(using: &generator)!
                rig.send([sample(Int.random(in: 0...1, using: &generator), phase, Double.random(in: 0...400, using: &generator), Double.random(in: 0...300, using: &generator), time)])
                rig.advance(to: time)
            }
            return (rig.log, rig.context)
        }
        let first = run()
        let second = run()
        #expect(first.0 == second.0)
        #expect(first.1 == second.1)
    }
}
