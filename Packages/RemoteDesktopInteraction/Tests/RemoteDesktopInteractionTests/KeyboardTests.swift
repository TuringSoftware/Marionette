// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopInteraction
import Testing

private func keys(_ events: [InputEvent]) -> [KeyEvent] {
    events.compactMap { if case .key(let event) = $0 { event } else { nil } }
}

@Suite struct ModifierLatchTests {
    @Test func tapCyclesOffOneShotLockedOff() {
        var latch = ModifierLatch()
        #expect(latch.isEmpty && latch.activeModifiers.isEmpty)
        #expect(latch.state(of: .command) == .off)

        #expect(latch.tap(.command) == [KeyEvent(key: .leftCommand, phase: .down)])
        #expect(latch.state(of: .command) == .oneShot)
        #expect(latch.activeModifiers == .leftCommand)
        #expect(latch.hasOneShots)

        #expect(latch.tap(.command).isEmpty)                 // already down on the remote
        #expect(latch.state(of: .command) == .locked)
        #expect(!latch.hasOneShots)

        #expect(latch.tap(.command) == [KeyEvent(key: .leftCommand, phase: .up)])
        #expect(latch.state(of: .command) == .off)
        #expect(latch.isEmpty)
    }

    @Test func eventsNameTheOtherHeldModifiers() {
        var latch = ModifierLatch()
        latch.tap(.control)
        latch.tap(.function)
        #expect(latch.tap(.shift) == [KeyEvent(key: .leftShift, modifiers: .leftControl, phase: .down)])
        #expect(latch.activeModifiers == [.leftControl, .leftShift, .function])
        latch.tap(.control)   // lock
        #expect(latch.tap(.control) == [KeyEvent(key: .leftControl, modifiers: .leftShift, phase: .up)])
    }

    @Test func oneShotsAreConsumedAndLocksStay() {
        var latch = ModifierLatch()
        latch.tap(.command)
        latch.tap(.shift)
        latch.tap(.option)
        latch.tap(.option)   // locked
        let released = latch.consumeOneShots()
        // Command (pressed first in keyboard order) comes up before Shift, like releasing a chord.
        #expect(released == [
            KeyEvent(key: .leftCommand, modifiers: [.leftOption, .leftShift], phase: .up),
            KeyEvent(key: .leftShift, modifiers: .leftOption, phase: .up),
        ])
        #expect(latch.state(of: .command) == .off && latch.state(of: .shift) == .off)
        #expect(latch.state(of: .option) == .locked)
        #expect(latch.activeModifiers == .leftOption)
        #expect(latch.consumeOneShots().isEmpty)
    }

    @Test func functionStaysOnThisSide() {
        var latch = ModifierLatch()
        #expect(latch.tap(.function).isEmpty)
        #expect(latch.state(of: .function) == .oneShot)
        #expect(latch.activeModifiers == .function)
        #expect(latch.consumeOneShots().isEmpty)
        #expect(latch.isEmpty)
        latch.tap(.function)
        latch.tap(.function)
        #expect(latch.state(of: .function) == .locked)
        #expect(latch.releaseAll().isEmpty)
        #expect(latch.isEmpty)
    }

    @Test func releaseAllLetsGoOfEverything() {
        var latch = ModifierLatch()
        for modifier in ModifierLatch.Modifier.allCases {
            latch.tap(modifier)
        }
        latch.tap(.control)   // locked
        let released = latch.releaseAll()
        #expect(released.map(\.key) == [.leftCommand, .leftShift, .leftOption, .leftControl])
        #expect(released.allSatisfy { $0.phase == .up })
        #expect(released.last?.modifiers == [])
        #expect(latch.isEmpty)
        #expect(latch.releaseAll().isEmpty)
    }

    @Test func everyDownHasExactlyOneUp() {
        var generator = SplitMix64(seed: 3)
        var latch = ModifierLatch()
        var held: [KeyCode: Int] = [:]
        func apply(_ events: [KeyEvent]) {
            for event in events {
                held[event.key!, default: 0] += event.phase == .down ? 1 : -1
                #expect(held[event.key!]! == 0 || held[event.key!]! == 1)
            }
        }
        for _ in 0..<500 {
            switch Int.random(in: 0..<10, using: &generator) {
            case 0..<7: apply(latch.tap(ModifierLatch.Modifier.allCases.randomElement(using: &generator)!))
            case 7..<9: apply(latch.consumeOneShots())
            default: apply(latch.releaseAll())
            }
            let down = Set(held.filter { $0.value == 1 }.keys)
            #expect(down == Set(KeyTranslator.keys(for: latch.activeModifiers)))
        }
        apply(latch.releaseAll())
        #expect(held.values.allSatisfy { $0 == 0 })
    }

    @Test func setStateJumpsDirectly() {
        var latch = ModifierLatch()
        #expect(latch.setState(.locked, for: .shift) == [KeyEvent(key: .leftShift, phase: .down)])
        #expect(latch.setState(.oneShot, for: .shift).isEmpty)
        #expect(latch.setState(.off, for: .shift) == [KeyEvent(key: .leftShift, phase: .up)])
        #expect(latch.setState(.off, for: .shift).isEmpty)
    }

    @Test func rightHandKeysLatchAndSendTheRightHandKey() {
        var latch = ModifierLatch()
        #expect(latch.tap(.command, side: .right) == [KeyEvent(key: .rightCommand, phase: .down)])
        #expect(latch.state(of: .command, side: .right) == .oneShot)
        #expect(latch.state(of: .command) == .off, "the left key is a separate key")
        #expect(latch.isActive(.command))
        #expect(latch.activeModifiers == .rightCommand)

        // The left key latches on its own and names the right one as held.
        #expect(latch.tap(.command) == [KeyEvent(key: .leftCommand, modifiers: .rightCommand, phase: .down)])
        #expect(latch.activeModifiers == [.leftCommand, .rightCommand])

        #expect(latch.tap(.option, side: .right) == [KeyEvent(key: .rightOption, modifiers: [.leftCommand, .rightCommand], phase: .down)])
        #expect(latch.tap(.shift, side: .right) == [KeyEvent(key: .rightShift, modifiers: [.leftCommand, .rightCommand, .rightOption], phase: .down)])
        latch.tap(.shift, side: .right)   // locked
        let released = latch.consumeOneShots()
        #expect(released.map(\.key) == [.rightCommand, .leftCommand, .rightOption])
        #expect(released.allSatisfy { $0.phase == .up })
        #expect(latch.activeModifiers == .rightShift)
        #expect(latch.releaseAll() == [KeyEvent(key: .rightShift, phase: .up)])
        #expect(latch.isEmpty)
    }

    @Test func functionHasOneKeyWhicheverSideIsNamed() {
        var latch = ModifierLatch()
        #expect(latch.tap(.function, side: .right).isEmpty)
        #expect(latch.state(of: .function) == .oneShot)
        #expect(latch.state(of: .function, side: .right) == .oneShot)
        latch.tap(.function)
        #expect(latch.state(of: .function) == .locked)
        #expect(latch.activeModifiers == .function)
    }

    @Test func everyDownHasExactlyOneUpOnBothSides() {
        var generator = SplitMix64(seed: 11)
        var latch = ModifierLatch()
        var held: [KeyCode: Int] = [:]
        func apply(_ events: [KeyEvent]) {
            for event in events {
                held[event.key!, default: 0] += event.phase == .down ? 1 : -1
                #expect(held[event.key!]! == 0 || held[event.key!]! == 1)
            }
        }
        for _ in 0..<800 {
            switch Int.random(in: 0..<10, using: &generator) {
            case 0..<7:
                let modifier = ModifierLatch.Modifier.allCases.randomElement(using: &generator)!
                let side = ModifierLatch.Side.allCases.randomElement(using: &generator)!
                apply(latch.tap(modifier, side: side))
            case 7..<9: apply(latch.consumeOneShots())
            default: apply(latch.releaseAll())
            }
            let down = Set(held.filter { $0.value == 1 }.keys)
            #expect(down == Set(KeyTranslator.keys(for: latch.activeModifiers)))
        }
        apply(latch.releaseAll())
        #expect(held.values.allSatisfy { $0 == 0 })
    }

    @Test func sideOfAKeyCode() {
        #expect(ModifierLatch.Side(key: .rightShift) == .right)
        #expect(ModifierLatch.Side(key: .rightControl) == .right)
        #expect(ModifierLatch.Side(key: .rightOption) == .right)
        #expect(ModifierLatch.Side(key: .rightCommand) == .right)
        #expect(ModifierLatch.Side(key: .leftCommand) == .left)
        #expect(ModifierLatch.Side(key: .function) == .left)
        #expect(ModifierLatch.Side(key: .a) == .left)
    }

    @Test func isAValue() throws {
        var latch = ModifierLatch()
        latch.tap(.command)
        latch.tap(.shift)
        latch.tap(.shift)
        let decoded = try JSONDecoder().decode(ModifierLatch.self, from: JSONEncoder().encode(latch))
        #expect(decoded == latch)
        #expect(decoded.state(of: .shift) == .locked && decoded.state(of: .command) == .oneShot)
        latch.tap(.option, side: .right)
        let decodedRight = try JSONDecoder().decode(ModifierLatch.self, from: JSONEncoder().encode(latch))
        #expect(decodedRight == latch && decodedRight.state(of: .option, side: .right) == .oneShot)
        var cleared = latch
        cleared.releaseAll()
        #expect(cleared == ModifierLatch())
        #expect(ModifierLatch.Modifier.allCases.map(\.symbol) == ["⌃", "⌥", "⇧", "⌘", "fn"])
    }
}

@Suite struct KeyTranslatorTests {
    let translator = KeyTranslator()

    @Test(arguments: [
        (KeyCode.leftArrow, KeyCode.home), (.rightArrow, .end), (.upArrow, .pageUp), (.downArrow, .pageDown),
        (.deleteBackward, .deleteForward), (.returnOrEnter, .keypadEnter),
        (.digit1, .f1), (.digit2, .f2), (.digit3, .f3), (.digit4, .f4), (.digit5, .f5), (.digit6, .f6),
        (.digit7, .f7), (.digit8, .f8), (.digit9, .f9), (.digit0, .f10), (.hyphen, .f11), (.equal, .f12),
    ])
    func functionLayer(key: KeyCode, expected: KeyCode) {
        let event = KeyEvent(key: key, characters: "x", charactersIgnoringModifiers: "x", modifiers: [.function, .leftCommand], phase: .down)
        let translated = translator.translate(event)
        #expect(translated.key == expected)
        #expect(translated.modifiers == .leftCommand)      // fn itself is consumed
        #expect(translated.characters == nil && translated.charactersIgnoringModifiers == nil)
        #expect(translated.phase == .down)
    }

    @Test func leavesEverythingElseAlone() {
        let plain = KeyEvent(key: .leftArrow, modifiers: .leftShift, phase: .down)
        #expect(translator.translate(plain) == plain)
        let unmapped = KeyEvent(key: .a, characters: "a", charactersIgnoringModifiers: "a", modifiers: .function, phase: .up)
        #expect(translator.translate(unmapped) == unmapped)
        let characterOnly = KeyEvent(key: nil, characters: "é", modifiers: .function, phase: .down)
        #expect(translator.translate(characterOnly) == characterOnly)
    }

    @Test func strokeIsADownAndAnUp() {
        #expect(translator.stroke(.escape) == [
            .key(KeyEvent(key: .escape, phase: .down)),
            .key(KeyEvent(key: .escape, phase: .up)),
        ])
        // Characters come from the US layout when the caller has none.
        #expect(keys(translator.stroke(.a)).first == KeyEvent(key: .a, characters: "a", charactersIgnoringModifiers: "a", phase: .down))
        #expect(keys(translator.stroke(.a, modifiers: .leftShift)).first?.characters == "A")
        #expect(keys(translator.stroke(.slash, modifiers: .rightShift)).first?.charactersIgnoringModifiers == "?")
        // With Command the key still produces its letter; with Control or Option nobody knows.
        let copy = keys(translator.stroke(.c, modifiers: .leftCommand))
        #expect(copy.map(\.phase) == [.down, .up])
        #expect(copy.allSatisfy { $0.characters == "c" && $0.charactersIgnoringModifiers == "c" && $0.modifiers == .leftCommand })
        let option = keys(translator.stroke(.a, modifiers: .leftOption))[0]
        #expect(option.characters == nil && option.charactersIgnoringModifiers == "a")
        // Explicit characters win.
        #expect(keys(translator.stroke(.a, characters: "å"))[0].characters == "å")
        // The fn layer applies to strokes.
        let pageUp = keys(translator.stroke(.upArrow, modifiers: [.function, .leftShift]))
        #expect(pageUp.map(\.key) == [.pageUp, .pageUp])
        #expect(pageUp.allSatisfy { $0.modifiers == .leftShift })
    }

    @Test func plainTextGoesOutAsText() {
        #expect(translator.events(forInsertedText: "héllo 👋", modifiers: []) == [.text("héllo 👋")])
        #expect(translator.events(forInsertedText: "A", modifiers: .leftShift) == [.text("A")])
        #expect(translator.events(forInsertedText: "", modifiers: []).isEmpty)
    }

    @Test func newlinesAndTabsAreKeys() {
        let events = translator.events(forInsertedText: "ab\ncd\t", modifiers: [])
        #expect(events == [
            .text("ab"),
            .key(KeyEvent(key: .returnOrEnter, phase: .down)),
            .key(KeyEvent(key: .returnOrEnter, phase: .up)),
            .text("cd"),
            .key(KeyEvent(key: .tab, phase: .down)),
            .key(KeyEvent(key: .tab, phase: .up)),
        ])
        #expect(keys(translator.events(forInsertedText: "\r\n", modifiers: [])).map(\.key) == [.returnOrEnter, .returnOrEnter])
        // Shift-Return keeps its Shift.
        #expect(keys(translator.events(forInsertedText: "\n", modifiers: .leftShift)).allSatisfy { $0.modifiers == .leftShift })
    }

    @Test func latchedModifiersTurnTextIntoShortcuts() {
        let copy = translator.events(forInsertedText: "c", modifiers: .leftCommand)
        #expect(copy == translator.stroke(.c, modifiers: .leftCommand))

        let two = keys(translator.events(forInsertedText: "kv", modifiers: [.leftControl, .leftCommand]))
        #expect(two.map(\.key) == [.k, .k, .v, .v])
        #expect(two.allSatisfy { $0.modifiers == [.leftControl, .leftCommand] })

        // A shifted symbol brings its own Shift, properly bracketed.
        let help = keys(translator.events(forInsertedText: "?", modifiers: .leftCommand))
        #expect(help.map(\.key) == [.leftShift, .slash, .slash, .leftShift])
        #expect(help.map(\.phase) == [.down, .down, .up, .up])
        #expect(help[0].modifiers == .leftCommand)
        #expect(help[1].modifiers == [.leftCommand, .leftShift])
        #expect(help[3].modifiers == .leftCommand)

        // An upper-case letter typed with Shift already latched needs no extra Shift.
        let redo = keys(translator.events(forInsertedText: "Z", modifiers: [.leftCommand, .leftShift]))
        #expect(redo.map(\.key) == [.z, .z])

        // What the US layout cannot type falls back to text.
        #expect(translator.events(forInsertedText: "é", modifiers: .leftCommand) == [.text("é")])
    }

    @Test func functionPlusTypedDigitsAreFunctionKeys() {
        let f5 = keys(translator.events(forInsertedText: "5", modifiers: .function))
        #expect(f5.map(\.key) == [.f5, .f5])
        #expect(f5.allSatisfy { $0.modifiers.isEmpty && $0.characters == nil })
        let f12 = keys(translator.events(forInsertedText: "=", modifiers: [.function, .leftCommand]))
        #expect(f12.map(\.key) == [.f12, .f12])
        #expect(f12.allSatisfy { $0.modifiers == .leftCommand })
        // fn with a letter has no fn meaning: the letter key is pressed, fn noted but unsent.
        #expect(keys(translator.events(forInsertedText: "a", modifiers: .function)).map(\.key) == [.a, .a])
    }

    @Test func deleteBackward() {
        #expect(keys(translator.eventsForDeleteBackward(modifiers: [])).map(\.key) == [.deleteBackward, .deleteBackward])
        #expect(keys(translator.eventsForDeleteBackward(modifiers: .function)).map(\.key) == [.deleteForward, .deleteForward])
        let word = keys(translator.eventsForDeleteBackward(modifiers: .leftOption))
        #expect(word.allSatisfy { $0.key == .deleteBackward && $0.modifiers == .leftOption })
    }

    @Test func usLayoutTableIsConsistent() throws {
        let printable = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789`~!@#$%^&*()-_=+[{]}\\|;:'\",<.>/? "
        for character in printable {
            let entry = try #require(KeyTranslator.key(for: character), "no key for \(character)")
            #expect(KeyTranslator.character(for: entry.key, shift: entry.needsShift) == character)
        }
        #expect(KeyTranslator.key(for: "a")! == (.a, false))
        #expect(KeyTranslator.key(for: "A")! == (.a, true))
        #expect(KeyTranslator.key(for: "%")! == (.digit5, true))
        #expect(KeyTranslator.key(for: "\n")! == (.returnOrEnter, false))
        #expect(KeyTranslator.key(for: "\t")! == (.tab, false))
        #expect(KeyTranslator.key(for: "é") == nil)
        #expect(KeyTranslator.character(for: .escape, shift: false) == nil)
        #expect(KeyTranslator.keys(for: [.rightCommand, .leftShift, .leftControl, .function, .capsLock]) == [.leftControl, .leftShift, .rightCommand])
    }
}

@Suite struct ShortcutCatalogTests {
    @Test func catalogIsWellFormed() {
        let all = ShortcutCatalog.all
        #expect(all.count >= 25)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.symbols)).count == all.count, "two shortcuts share a key combination")
        for shortcut in all {
            #expect(!shortcut.title.isEmpty)
            #expect(shortcut.id.hasPrefix(shortcut.category.rawValue + "."))
            #expect(shortcut.modifiers.hasCommand || shortcut.modifiers.hasControl || shortcut.modifiers.hasOption)
            #expect(shortcut.key.modifier == nil)
            #expect(!shortcut.modifiers.contains(.function))
            #expect(!shortcut.symbols.contains("?"))
            #expect(ShortcutCatalog.shortcut(withID: shortcut.id) == shortcut)
        }
        for category in ShortcutCatalog.Category.allCases {
            #expect(!ShortcutCatalog.shortcuts(in: category).isEmpty)
            #expect(!category.title.isEmpty)
        }
        #expect(ShortcutCatalog.Category.allCases.map { ShortcutCatalog.shortcuts(in: $0).count }.reduce(0, +) == all.count)
        #expect(ShortcutCatalog.shortcut(withID: "nope") == nil)
    }

    @Test func symbolsReadLikeMacMenus() {
        #expect(ShortcutCatalog.shortcut(withID: "system.lockScreen")?.symbols == "⌃⌘Q")
        #expect(ShortcutCatalog.shortcut(withID: "system.spotlight")?.symbols == "⌘Space")
        #expect(ShortcutCatalog.shortcut(withID: "system.forceQuit")?.symbols == "⌥⌘⎋")
        #expect(ShortcutCatalog.shortcut(withID: "system.appSwitcher")?.symbols == "⌘⇥")
        #expect(ShortcutCatalog.shortcut(withID: "system.missionControl")?.symbols == "⌃↑")
        #expect(ShortcutCatalog.shortcut(withID: "screenshots.selection")?.symbols == "⇧⌘4")
        #expect(ShortcutCatalog.shortcut(withID: "editing.redo")?.symbols == "⇧⌘Z")
        #expect(ShortcutCatalog.shortcut(withID: "windows.cycle")?.symbols == "⌘`")
        #expect(KeyModifiers([.function, .rightOption]).shortcutSymbols == "fn⌥")
        #expect(KeyCode.f5.shortcutSymbol == "F5" && KeyCode.f13.shortcutSymbol == "F13" && KeyCode.deleteForward.shortcutSymbol == "⌦")
    }

    @Test func eventsFormABalancedChord() {
        for shortcut in ShortcutCatalog.all {
            let events = keys(shortcut.events)
            #expect(events.count == shortcut.events.count)
            let modifierKeys = KeyTranslator.keys(for: shortcut.modifiers)
            let count = modifierKeys.count
            #expect(events.count == count * 2 + 2)
            #expect(events.prefix(count).map(\.key) == modifierKeys)
            #expect(events.prefix(count).allSatisfy { $0.phase == .down })
            #expect(events[count].key == shortcut.key && events[count].phase == .down && events[count].modifiers == shortcut.modifiers)
            #expect(events[count + 1].key == shortcut.key && events[count + 1].phase == .up)
            #expect(events.suffix(count).map(\.key) == modifierKeys.reversed())
            #expect(events.suffix(count).allSatisfy { $0.phase == .up })
            #expect(events.first?.modifiers == [])
            #expect(events.last?.modifiers == [])
        }
    }

    /// The chord splits after the key's down, so it can be held for a moment.
    @Test func aChordSplitsIntoPressAndRelease() {
        for shortcut in ShortcutCatalog.all {
            let count = KeyTranslator.keys(for: shortcut.modifiers).count
            #expect(shortcut.pressEvents == Array(shortcut.events.prefix(count + 1)))
            #expect(shortcut.releaseEvents == Array(shortcut.events.suffix(count + 1)))
        }
        #expect(Shortcut.holdDuration == .milliseconds(75))
    }

    @Test func lockScreenSpelledOut() {
        let events = ShortcutCatalog.shortcut(withID: "system.lockScreen")!.events
        #expect(events == [
            .key(KeyEvent(key: .leftControl, modifiers: [], phase: .down)),
            .key(KeyEvent(key: .leftCommand, modifiers: .leftControl, phase: .down)),
            .key(KeyEvent(key: .q, characters: nil, charactersIgnoringModifiers: "q", modifiers: [.leftControl, .leftCommand], phase: .down)),
            .key(KeyEvent(key: .q, characters: nil, charactersIgnoringModifiers: "q", modifiers: [.leftControl, .leftCommand], phase: .up)),
            .key(KeyEvent(key: .leftCommand, modifiers: .leftControl, phase: .up)),
            .key(KeyEvent(key: .leftControl, modifiers: [], phase: .up)),
        ])
    }
}
