// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import RemoteDesktopInteraction
import Testing

private func keys(_ events: [InputEvent]) -> [KeyEvent] {
    events.compactMap { if case .key(let event) = $0 { event } else { nil } }
}

private func down(_ key: KeyCode, _ characters: String? = nil, _ base: String? = nil, _ modifiers: KeyModifiers = []) -> InputEvent {
    .key(KeyEvent(key: key, characters: characters, charactersIgnoringModifiers: base, modifiers: modifiers, phase: .down))
}

private func up(_ key: KeyCode, _ characters: String? = nil, _ base: String? = nil, _ modifiers: KeyModifiers = []) -> InputEvent {
    .key(KeyEvent(key: key, characters: characters, charactersIgnoringModifiers: base, modifiers: modifiers, phase: .up))
}

@Suite struct KeyboardStateTests {
    @Test func aPressIsOneDownAndOneUp() {
        var state = KeyboardState()
        #expect(state.isEmpty && state.hardwareModifiers.isEmpty && state.modifiers.isEmpty)

        // A hardware keyboard reports its own characters; they are passed on, and repeated on the up.
        #expect(state.keyDown(.a, characters: "å", charactersIgnoringModifiers: "a", source: .hardware) == [down(.a, "å", "a")])
        #expect(!state.isEmpty)
        #expect(state.keyUp(.a, source: .hardware) == [up(.a, "å", "a")])
        #expect(state.isEmpty)

        // Nothing is invented for a hardware key that came without characters.
        #expect(state.keyDown(.a, source: .hardware) == [down(.a)])
        #expect(state.keyUp(.a, source: .hardware) == [up(.a)])
        // Keys that type nothing have no characters from either source.
        #expect(state.keyDown(.escape, source: .onScreen) == [down(.escape)])
        #expect(state.keyUp(.escape, source: .onScreen) == [up(.escape)])
        #expect(state.isEmpty)
    }

    /// With Stage Manager, or when iPadOS takes a ⌘ chord, the ⌘ key-up never arrives.
    @Test func aModifierTheSystemNoLongerHoldsIsReleased() {
        var state = KeyboardState()
        _ = state.keyDown(.leftCommand, source: .hardware)
        _ = state.keyDown(.rightShift, source: .hardware)
        _ = state.keyDown(.leftOption, source: .onScreen)
        _ = state.keyDown(.function, source: .hardware)
        _ = state.keyDown(.a, source: .hardware)
        // The flags still have Shift (either side counts) but no Command.
        #expect(state.synchronize(flags: .leftShift) == [up(.leftCommand, nil, nil, [.rightShift, .leftOption, .function])])
        #expect(state.hardwareModifiers == [.rightShift, .leftOption, .function])
        // Nothing more to release while the flags agree; a flag with no key pressed invents nothing.
        #expect(state.synchronize(flags: [.shift, .command, .control]).isEmpty)
        // An on-screen modifier and fn are not the system's to judge, and ordinary keys stay down.
        #expect(state.synchronize(flags: []) == [up(.rightShift, nil, nil, [.leftOption, .function])])
        #expect(state.hardwareModifiers == [.leftOption, .function])
        #expect(!state.isEmpty)
        // The real key-up, when it comes late after all, adds nothing.
        #expect(state.keyUp(.leftCommand, source: .hardware).isEmpty)
    }

    /// The remote machine does not repeat held keys, so the front end asks for repeats.
    @Test func aHeldKeyRepeatsAsItWasPressed() {
        var state = KeyboardState()
        _ = state.keyDown(.leftShift, source: .hardware)
        _ = state.keyDown(.a, characters: "A", charactersIgnoringModifiers: "a", source: .hardware)
        var repeated = KeyEvent(key: .a, characters: "A", charactersIgnoringModifiers: "a", modifiers: .leftShift, phase: .down, isRepeat: true)
        #expect(state.repeatedKeyDown(.a, source: .hardware) == [.key(repeated)])
        // With the modifiers held now.
        _ = state.keyUp(.leftShift, source: .hardware)
        repeated.modifiers = []
        #expect(state.repeatedKeyDown(.a, source: .hardware) == [.key(repeated)])
        // Not from the other keyboard, not once up, and never modifiers, Caps Lock or fn.
        #expect(state.repeatedKeyDown(.a, source: .onScreen).isEmpty)
        _ = state.keyUp(.a, source: .hardware)
        #expect(state.repeatedKeyDown(.a, source: .hardware).isEmpty)
        for key in [KeyCode.leftCommand, .capsLock, .function] {
            _ = state.keyDown(key, source: .hardware)
            #expect(!KeyboardState.repeats(key))
            #expect(state.repeatedKeyDown(key, source: .hardware).isEmpty)
        }
        #expect(KeyboardState.repeats(.deleteBackward) && KeyboardState.repeats(.leftArrow))
    }

    @Test func autoRepeatAndStrayUpsAreDropped() {
        var state = KeyboardState()
        #expect(state.keyDown(.j, source: .hardware).count == 1)
        for _ in 0..<5 {
            #expect(state.keyDown(.j, characters: "j", source: .hardware).isEmpty)
        }
        #expect(state.keyUp(.j, source: .hardware).count == 1)
        #expect(state.keyUp(.j, source: .hardware).isEmpty)
        #expect(state.keyUp(.k, source: .hardware).isEmpty)
        #expect(state.keyUp(.leftShift, source: .onScreen).isEmpty)

        // Modifier keys repeat too on some keyboards.
        #expect(state.keyDown(.leftShift, source: .hardware).count == 1)
        #expect(state.keyDown(.leftShift, source: .hardware).isEmpty)
        #expect(state.keyUp(.leftShift, source: .hardware).count == 1)
        #expect(state.isEmpty)
    }

    @Test func theSameKeyOnBothKeyboardsIsTwoPresses() {
        var state = KeyboardState()
        #expect(state.keyDown(.a, source: .onScreen) == [down(.a, "a", "a")])
        #expect(state.keyDown(.a, characters: "a", charactersIgnoringModifiers: "a", source: .hardware) == [down(.a, "a", "a")])
        #expect(state.keyDown(.a, source: .onScreen).isEmpty)      // a repeat of the first
        #expect(state.keyUp(.a, source: .onScreen) == [up(.a, "a", "a")])
        #expect(!state.isEmpty)
        #expect(state.keyUp(.a, source: .onScreen).isEmpty)
        #expect(state.keyUp(.a, source: .hardware) == [up(.a, "a", "a")])
        #expect(state.isEmpty)
    }

    @Test func onScreenKeysTypeTheUSLayout() {
        var state = KeyboardState()
        #expect(state.keyDown(.slash, source: .onScreen) == [down(.slash, "/", "/")])
        #expect(state.keyUp(.slash, source: .onScreen) == [up(.slash, "/", "/")])
        #expect(state.keyDown(.space, source: .onScreen) == [down(.space, " ", " ")])
        _ = state.keyUp(.space, source: .onScreen)

        state.latchedModifiers = .leftShift
        #expect(state.keyDown(.slash, source: .onScreen) == [down(.slash, "?", "?", .leftShift)])
        #expect(state.keyDown(.a, source: .onScreen) == [down(.a, "A", "A", .leftShift)])
        // The up repeats what the down said, even though Shift has been let go since.
        state.latchedModifiers = []
        #expect(state.keyUp(.a, source: .onScreen) == [up(.a, "A", "A")])
        #expect(state.keyUp(.slash, source: .onScreen) == [up(.slash, "?", "?")])

        // What the caller knows wins over the table.
        #expect(state.keyDown(.a, characters: "ä", source: .onScreen) == [down(.a, "ä", "a")])
        #expect(state.keyUp(.a, source: .onScreen) == [up(.a, "ä", "a")])
        #expect(state.keyDown(.a, charactersIgnoringModifiers: "q", source: .onScreen) == [down(.a, "a", "q")])
        #expect(state.keyUp(.a, source: .onScreen) == [up(.a, "a", "q")])
    }

    @Test(arguments: [
        KeyModifiers.leftControl, .rightControl, .leftOption, .rightOption, .leftCommand, .rightCommand,
        [.leftShift, .leftCommand],
    ])
    func shortcutsCarryNoProducedCharacters(modifiers: KeyModifiers) {
        var state = KeyboardState()
        state.latchedModifiers = modifiers
        let base = modifiers.hasShift ? "C" : "c"
        #expect(state.keyDown(.c, source: .onScreen) == [down(.c, nil, base, modifiers)])
        #expect(state.keyUp(.c, source: .onScreen) == [up(.c, nil, base, modifiers)])

        // The same held on a hardware keyboard while an on-screen key is tapped.
        var mixed = KeyboardState()
        for key in KeyTranslator.keys(for: modifiers) {
            _ = mixed.keyDown(key, source: .hardware)
        }
        #expect(mixed.keyDown(.c, source: .onScreen) == [down(.c, nil, base, modifiers)])
        // A hardware key keeps whatever the platform said it produced.
        #expect(mixed.keyDown(.v, characters: "√", charactersIgnoringModifiers: "v", source: .hardware) == [down(.v, "√", "v", modifiers)])
    }

    @Test func modifierKeysAreSentAndTrackedLeftAndRight() {
        var state = KeyboardState()
        #expect(state.keyDown(.rightShift, source: .hardware) == [down(.rightShift)])
        #expect(state.hardwareModifiers == .rightShift)
        #expect(state.keyDown(.leftCommand, source: .hardware) == [down(.leftCommand, nil, nil, .rightShift)])
        #expect(state.hardwareModifiers == [.rightShift, .leftCommand])
        #expect(state.keyDown(.leftShift, source: .hardware) == [down(.leftShift, nil, nil, [.rightShift, .leftCommand])])
        #expect(state.hardwareModifiers == [.leftShift, .rightShift, .leftCommand])

        #expect(state.keyDown(.z, characters: "Z", charactersIgnoringModifiers: "Z", source: .hardware)
            == [down(.z, "Z", "Z", [.leftShift, .rightShift, .leftCommand])])

        // Letting go of one Shift leaves the other.
        #expect(state.keyUp(.rightShift, source: .hardware) == [up(.rightShift, nil, nil, [.leftShift, .leftCommand])])
        #expect(state.hardwareModifiers == [.leftShift, .leftCommand])
        #expect(state.hardwareModifiers.hasShift)
        #expect(state.keyUp(.z, source: .hardware) == [up(.z, "Z", "Z", [.leftShift, .leftCommand])])
        #expect(state.keyUp(.leftShift, source: .hardware) == [up(.leftShift, nil, nil, .leftCommand)])
        #expect(state.keyUp(.leftCommand, source: .hardware) == [up(.leftCommand)])
        #expect(state.hardwareModifiers.isEmpty && state.isEmpty)

        for (key, flag) in [
            (KeyCode.leftControl, KeyModifiers.leftControl), (.rightControl, .rightControl),
            (.leftOption, .leftOption), (.rightOption, .rightOption), (.rightCommand, .rightCommand),
        ] {
            #expect(state.keyDown(key, source: .hardware) == [down(key)])
            #expect(state.hardwareModifiers == flag)
            #expect(state.keyUp(key, source: .hardware) == [up(key)])
        }
    }

    @Test func aModifierKeyHeldOnScreenCountsLikeAHardwareOne() {
        var state = KeyboardState()
        #expect(state.keyDown(.leftOption, source: .onScreen) == [down(.leftOption)])
        #expect(state.hardwareModifiers == .leftOption)
        #expect(state.keyDown(.leftArrow, source: .hardware) == [down(.leftArrow, nil, nil, .leftOption)])
        // The same modifier key from the other keyboard is its own press and never names itself.
        #expect(state.keyDown(.leftOption, source: .hardware) == [down(.leftOption)])
        #expect(state.keyUp(.leftOption, source: .onScreen) == [up(.leftOption)])
        #expect(state.hardwareModifiers == .leftOption)
        #expect(state.keyUp(.leftArrow, source: .hardware) == [up(.leftArrow, nil, nil, .leftOption)])
        #expect(state.keyUp(.leftOption, source: .hardware) == [up(.leftOption)])
        #expect(state.isEmpty)
    }

    @Test func latchedAndHardwareModifiersMerge() {
        var state = KeyboardState()
        var latch = ModifierLatch()
        latch.tap(.command)
        state.latchedModifiers = latch.activeModifiers
        #expect(state.hardwareModifiers.isEmpty)
        #expect(state.modifiers == .leftCommand)
        #expect(!state.isEmpty == false)   // a latched modifier is not a key held here

        #expect(state.keyDown(.rightShift, source: .hardware) == [down(.rightShift, nil, nil, .leftCommand)])
        #expect(state.modifiers == [.leftCommand, .rightShift])
        #expect(state.keyDown(.digit4, source: .onScreen) == [down(.digit4, nil, "$", [.leftCommand, .rightShift])])
        #expect(state.keyUp(.digit4, source: .onScreen) == [up(.digit4, nil, "$", [.leftCommand, .rightShift])])

        // The one-shot ⌘ is consumed; the hardware Shift is still down.
        latch.consumeOneShots()
        state.latchedModifiers = latch.activeModifiers
        #expect(state.keyDown(.digit4, source: .onScreen) == [down(.digit4, "$", "$", .rightShift)])
        #expect(state.keyUp(.rightShift, source: .hardware) == [up(.rightShift)])
        #expect(state.keyUp(.digit4, source: .onScreen) == [up(.digit4, "$", "$")])

        // A hardware key that is also latched never lists itself.
        state.latchedModifiers = [.leftShift, .leftControl]
        #expect(state.keyDown(.leftShift, source: .hardware) == [down(.leftShift, nil, nil, .leftControl)])
        #expect(state.keyUp(.leftShift, source: .hardware) == [up(.leftShift, nil, nil, .leftControl)])
    }

    @Test func functionIsTrackedButNeverSent() {
        var state = KeyboardState()
        #expect(state.keyDown(.function, source: .hardware).isEmpty)
        #expect(state.hardwareModifiers == .function)
        #expect(!state.isEmpty)
        #expect(state.keyDown(.function, source: .hardware).isEmpty)
        // A key without an fn meaning is sent as itself, with fn noted.
        #expect(state.keyDown(.a, characters: "a", charactersIgnoringModifiers: "a", source: .hardware) == [down(.a, "a", "a", .function)])
        #expect(state.keyDown(.leftShift, source: .hardware) == [down(.leftShift, nil, nil, .function)])
        #expect(state.keyUp(.function, source: .hardware).isEmpty)
        #expect(state.hardwareModifiers == .leftShift)
        #expect(state.keyUp(.a, source: .hardware) == [up(.a, "a", "a", .leftShift)])
        #expect(state.keyUp(.leftShift, source: .hardware) == [up(.leftShift)])
        #expect(state.keyUp(.function, source: .hardware).isEmpty)
        #expect(state.isEmpty)
    }

    @Test(arguments: [
        (KeyCode.leftArrow, KeyCode.home), (.rightArrow, .end), (.upArrow, .pageUp), (.downArrow, .pageDown),
        (.deleteBackward, .deleteForward), (.returnOrEnter, .keypadEnter),
        (.digit1, .f1), (.digit5, .f5), (.digit0, .f10), (.hyphen, .f11), (.equal, .f12),
    ])
    func functionLayerIsRememberedUntilTheKeyComesUp(key: KeyCode, translated: KeyCode) {
        // Hardware fn, released before the key it modified.
        var state = KeyboardState()
        _ = state.keyDown(.function, source: .hardware)
        _ = state.keyDown(.leftShift, source: .hardware)
        #expect(state.keyDown(key, characters: "x", charactersIgnoringModifiers: "x", source: .hardware) == [down(translated, nil, nil, .leftShift)])
        #expect(state.keyDown(key, source: .hardware).isEmpty)
        #expect(state.keyUp(.function, source: .hardware).isEmpty)
        #expect(state.keyUp(key, source: .hardware) == [up(translated, nil, nil, .leftShift)])
        #expect(state.keyUp(key, source: .hardware).isEmpty)
        _ = state.keyUp(.leftShift, source: .hardware)
        #expect(state.isEmpty)

        // Latched fn and an on-screen key; fn is consumed before the key comes up.
        var latched = KeyboardState()
        latched.latchedModifiers = [.function, .leftCommand]
        #expect(latched.keyDown(key, source: .onScreen) == [down(translated, nil, nil, .leftCommand)])
        latched.latchedModifiers = []
        #expect(latched.keyUp(key, source: .onScreen) == [up(translated)])

        // Pressed without fn, fn arrives later: the key stays what it was.
        var late = KeyboardState()
        let plain = keys(late.keyDown(key, source: .hardware))
        #expect(plain.map(\.key) == [key])
        _ = late.keyDown(.function, source: .hardware)
        let released = keys(late.keyUp(key, source: .hardware))
        #expect(released.map(\.key) == [key])
        #expect(released.first?.modifiers == .function)

        // fn still held when the translated key comes up: fn is not named either way.
        var held = KeyboardState()
        _ = held.keyDown(.function, source: .onScreen)
        #expect(held.keyDown(key, source: .hardware) == [down(translated)])
        #expect(held.keyUp(key, source: .hardware) == [up(translated)])
    }

    @Test func theFunctionLayerAndTheRealKeyAreSeparatePresses() {
        var state = KeyboardState()
        _ = state.keyDown(.function, source: .hardware)
        #expect(keys(state.keyDown(.leftArrow, source: .hardware)).map(\.key) == [.home])
        // An extended keyboard's own Home stays Home while fn is held; once fn is up, the on-screen
        // arrow is an arrow.
        #expect(state.keyDown(.home, source: .hardware) == [down(.home, nil, nil, .function)])
        _ = state.keyUp(.function, source: .hardware)
        #expect(state.keyDown(.leftArrow, source: .onScreen) == [down(.leftArrow)])
        #expect(state.keyUp(.leftArrow, source: .hardware) == [up(.home)])
        #expect(state.keyUp(.leftArrow, source: .onScreen) == [up(.leftArrow)])
        #expect(state.keyUp(.home, source: .hardware) == [up(.home)])
        #expect(state.isEmpty)
    }

    @Test func capsLockIsAModifierFlagAndCapitalisesLetters() {
        var state = KeyboardState()
        state.setCapsLock(true)
        #expect(state.hardwareModifiers == .capsLock)
        #expect(state.isEmpty)
        #expect(state.keyDown(.a, source: .onScreen) == [down(.a, "A", "A", .capsLock)])
        #expect(state.keyDown(.digit1, source: .onScreen) == [down(.digit1, "1", "1", .capsLock)])
        #expect(state.keyDown(.leftShift, source: .hardware) == [down(.leftShift, nil, nil, .capsLock)])
        #expect(state.hardwareModifiers == [.capsLock, .leftShift])
        state.setCapsLock(false)
        #expect(state.keyUp(.a, source: .onScreen) == [up(.a, "A", "A", .leftShift)])
        #expect(state.hardwareModifiers == .leftShift)

        // The Caps Lock key itself is an ordinary key.
        #expect(state.keyDown(.capsLock, source: .hardware) == [down(.capsLock, nil, nil, .leftShift)])
        #expect(state.keyUp(.capsLock, source: .hardware) == [up(.capsLock, nil, nil, .leftShift)])
        #expect(state.hardwareModifiers == .leftShift)
    }

    @Test func releaseAllLetsGoInReverseWithModifiersLast() {
        var state = KeyboardState()
        state.latchedModifiers = .leftOption
        state.setCapsLock(true)
        _ = state.keyDown(.leftControl, source: .hardware)
        _ = state.keyDown(.a, source: .hardware)
        _ = state.keyDown(.function, source: .hardware)
        _ = state.keyDown(.rightShift, source: .onScreen)
        _ = state.keyDown(.upArrow, source: .onScreen)        // fn layer: Page Up
        _ = state.keyDown(.b, characters: "B", charactersIgnoringModifiers: "B", source: .hardware)
        _ = state.keyDown(.a, source: .onScreen)

        let everything: KeyModifiers = [.leftControl, .rightShift, .function, .leftOption, .capsLock]
        let released = state.releaseAll()
        #expect(released == [
            up(.a, nil, "A", everything),
            up(.b, "B", "B", everything),
            up(.pageUp, nil, nil, everything.subtracting(.function)),
            up(.a, nil, nil, everything),
            // fn goes silently, between the two modifier keys.
            up(.rightShift, nil, nil, [.leftControl, .function, .leftOption, .capsLock]),
            up(.leftControl, nil, nil, [.leftOption, .capsLock]),
        ])
        #expect(state.isEmpty)
        #expect(state.hardwareModifiers == .capsLock)
        #expect(state.latchedModifiers == .leftOption)      // the latch releases its own keys
        #expect(state.releaseAll().isEmpty)

        state.latchedModifiers = []
        state.setCapsLock(false)
        #expect(state.keyDown(.a, source: .hardware) == [down(.a)])
        #expect(state.keyUp(.a, source: .hardware) == [up(.a)])
    }

    @Test func isAValue() {
        var first = KeyboardState()
        var second = KeyboardState()
        #expect(first == second)
        _ = first.keyDown(.a, source: .hardware)
        #expect(first != second)
        _ = second.keyDown(.a, source: .hardware)
        #expect(first == second && first.hashValue == second.hashValue)
        _ = first.keyUp(.a, source: .hardware)
        _ = second.releaseAll()
        #expect(first == second && first == KeyboardState())
        first.setCapsLock(true)
        #expect(first != second)
    }
}

/// Throws random key traffic from both keyboards at a ``KeyboardState`` and checks, event by event,
/// that the remote machine could never be left with a key down.
private struct KeyboardFuzzer {
    struct Press: Hashable {
        var key: KeyCode
        var source: KeyboardState.Source
    }

    static let pool: [KeyCode] = [
        .a, .z, .digit1, .digit0, .hyphen, .leftArrow, .upArrow, .deleteBackward, .returnOrEnter, .home, .f1, .space,
        .escape, .capsLock, .leftShift, .rightShift, .leftControl, .leftOption, .rightOption, .leftCommand,
        .rightCommand, .function,
    ]
    static let latchable: [KeyModifiers] = [.leftShift, .leftControl, .leftOption, .leftCommand, .function]

    var state = KeyboardState()
    var generator: SplitMix64
    /// What the test believes is down, and what was sent for it.
    var pressed: [Press: KeyCode?] = [:]
    var capsLock = false
    /// How many downs without an up the remote machine has seen, per key.
    var remote: [KeyCode: Int] = [:]
    var downs = 0
    var ups = 0

    var expectedHardware: KeyModifiers {
        var modifiers: KeyModifiers = capsLock ? .capsLock : []
        for press in pressed.keys {
            if let flag = press.key.modifier { modifiers.formUnion(flag) }
        }
        return modifiers
    }

    mutating func record(_ events: [InputEvent], _ step: String) -> [KeyEvent] {
        var result: [KeyEvent] = []
        for event in events {
            guard case .key(let key) = event, let code = key.key else {
                Issue.record("only key events with a key are expected: \(step)")
                continue
            }
            #expect(code != .function, "fn must never be sent: \(step)")
            switch key.phase {
            case .down:
                downs += 1
                remote[code, default: 0] += 1
            case .up:
                ups += 1
                remote[code, default: 0] -= 1
                #expect(remote[code, default: 0] >= 0, "an up without a down for \(code): \(step)")
            }
            if let flag = code.modifier {
                #expect(key.modifiers.isDisjoint(with: flag), "a modifier key names itself: \(step)")
            }
            result.append(key)
        }
        return result
    }

    mutating func step(_ index: Int) {
        let key = Self.pool.randomElement(using: &generator)!
        let source: KeyboardState.Source = Bool.random(using: &generator) ? .hardware : .onScreen
        let press = Press(key: key, source: source)
        switch Int.random(in: 0..<100, using: &generator) {
        case 0..<45:
            let step = "down \(index)"
            let before = expectedHardware.union(state.latchedModifiers)
            let events = record(state.keyDown(key, source: source), step)
            if pressed[press] != nil || key == .function {
                #expect(events.isEmpty, "a repeat or fn was sent: \(step)")
                if pressed[press] == nil { pressed[press] = .some(nil) }
            } else {
                #expect(events.count == 1 && events.first?.phase == .down, "\(step)")
                let sent = events.first?.key
                pressed[press] = .some(sent)
                let layer = before.contains(.function) ? KeyTranslator.functionLayerKey(for: key) : nil
                #expect(sent == layer ?? key, "\(step)")
                var modifiers = before.subtracting(key.modifier ?? [])
                if layer != nil { modifiers.remove(.function) }
                #expect(events.first?.modifiers == modifiers, "\(step)")
            }
        case 45..<85:
            let step = "up \(index)"
            let events = record(state.keyUp(key, source: source), step)
            if let sent = pressed.removeValue(forKey: press), let sent {
                #expect(events.count == 1 && events.first?.phase == .up, "\(step)")
                #expect(events.first?.key == sent, "the up names another key than the down: \(step)")
            } else {
                #expect(events.isEmpty, "\(step)")
            }
        case 85..<93:
            state.latchedModifiers.formSymmetricDifference(Self.latchable.randomElement(using: &generator)!)
        case 93..<97:
            capsLock.toggle()
            state.setCapsLock(capsLock)
        default:
            let step = "releaseAll \(index)"
            let expected = pressed.values.compactMap { $0 }
            let events = record(state.releaseAll(), step)
            #expect(events.allSatisfy { $0.phase == .up }, "\(step)")
            #expect(events.compactMap(\.key).sorted { $0.rawValue < $1.rawValue } == expected.sorted { $0.rawValue < $1.rawValue }, "\(step)")
            // Modifier keys come last.
            let firstModifier = events.firstIndex { $0.key?.modifier != nil } ?? events.count
            #expect(events[firstModifier...].allSatisfy { $0.key?.modifier != nil }, "\(step)")
            pressed.removeAll()
            #expect(remote.values.allSatisfy { $0 == 0 }, "something is still down after releaseAll: \(step)")
        }
        #expect(state.hardwareModifiers == expectedHardware, "step \(index)")
        #expect(state.modifiers == expectedHardware.union(state.latchedModifiers), "step \(index)")
        #expect(state.isEmpty == pressed.isEmpty, "step \(index)")
        // The remote machine holds exactly what the test believes is pressed.
        var expectedRemote: [KeyCode: Int] = [:]
        for sent in pressed.values {
            if let sent { expectedRemote[sent, default: 0] += 1 }
        }
        #expect(remote.filter { $0.value != 0 } == expectedRemote, "step \(index)")
    }
}

@Suite struct KeyboardStateFuzzTests {
    @Test(arguments: 1...40)
    func everyDownHasExactlyOneUp(seed: Int) {
        var fuzzer = KeyboardFuzzer(generator: SplitMix64(seed: UInt64(seed) &+ 5000))
        for index in 0..<600 { fuzzer.step(index) }

        // Let go of whatever is left: one key at a time on even seeds, all at once on odd ones.
        if seed.isMultiple(of: 2) {
            for press in fuzzer.pressed.keys.sorted(by: { ($0.key.rawValue, $0.source == .hardware ? 0 : 1) < ($1.key.rawValue, $1.source == .hardware ? 0 : 1) }) {
                _ = fuzzer.record(fuzzer.state.keyUp(press.key, source: press.source), "final up")
            }
        } else {
            _ = fuzzer.record(fuzzer.state.releaseAll(), "final releaseAll")
        }
        #expect(fuzzer.state.isEmpty)
        #expect(fuzzer.remote.values.allSatisfy { $0 == 0 })
        #expect(fuzzer.downs == fuzzer.ups)
        #expect(fuzzer.downs > 50)
        #expect(fuzzer.state.releaseAll().isEmpty)
    }

    @Test func theSameTrafficAlwaysProducesTheSameEvents() {
        func run() -> ([InputEvent], KeyboardState) {
            var generator = SplitMix64(seed: 99)
            var state = KeyboardState()
            var log: [InputEvent] = []
            for _ in 0..<400 {
                let key = KeyboardFuzzer.pool.randomElement(using: &generator)!
                let source: KeyboardState.Source = Bool.random(using: &generator) ? .hardware : .onScreen
                log += Bool.random(using: &generator) ? state.keyDown(key, source: source) : state.keyUp(key, source: source)
            }
            log += state.releaseAll()
            return (log, state)
        }
        let first = run()
        let second = run()
        #expect(first.0 == second.0)
        #expect(first.1 == second.1)
    }
}
