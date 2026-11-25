// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import RemoteDesktopInteraction
import Testing

/// The mouse, the trackpad and the Pencil as an absolute pointer.
@Suite struct PointerInterpreterTests {
    @Test func hoverMovesThePointerWithoutButtons() {
        var pointer = PointerInterpreter()
        var context = fittedContext()
        let effects = pointer.move(to: ViewPoint(x: 100, y: 50), context: &context)
        #expect(effects.pointers == [RemoteDesktopInteractionTests.pointer(200, 100)])
        #expect(effects.contains(.pointerMoved))
        #expect(context.pointer == PixelPoint(x: 200, y: 100))
        #expect(pointer.isIdle)
        #expect(context.buttons.isEmpty, "the touch interpreters' buttons are not this one's to use")
    }

    @Test func buttonsAreSentAsTheyChangeAndDragsKeepThemHeld() {
        var pointer = PointerInterpreter()
        var context = fittedContext()
        var log: [InteractionEffect] = []
        log += pointer.setButtons(.primary, at: ViewPoint(x: 10, y: 10), context: &context)
        #expect(pointer.heldButtons == .primary)
        #expect(!pointer.isIdle)
        log += pointer.setButtons(.primary, at: ViewPoint(x: 10, y: 10), context: &context)
        log += pointer.move(to: ViewPoint(x: 60, y: 10), context: &context)
        log += pointer.setButtons([], at: ViewPoint(x: 60, y: 10), context: &context)
        let events = log.pointers
        // The pointer is placed first, then pressed.
        #expect(events.first?.position == PixelPoint(x: 20, y: 20))
        #expect(events.first { !$0.buttons.isEmpty }?.buttons == .primary)
        #expect(events.contains(RemoteDesktopInteractionTests.pointer(120, 20, .primary)), "the drag carries the button")
        #expect(events.last == RemoteDesktopInteractionTests.pointer(120, 20))
        #expect(pointer.heldButtons.isEmpty && pointer.isIdle)
        #expect(events.filter { $0.buttons == .primary && $0.position == PixelPoint(x: 20, y: 20) }.count == 1, "an unchanged button state is not repeated")
    }

    @Test func secondaryAndMiddleButtonsPassThrough() {
        var pointer = PointerInterpreter()
        var context = fittedContext()
        let down = pointer.setButtons([.secondary, .middle], at: ViewPoint(x: 0, y: 0), context: &context)
        #expect(down.pointers.last?.buttons == [.secondary, .middle])
        let up = pointer.setButtons([], at: ViewPoint(x: 0, y: 0), context: &context)
        #expect(up.pointers.last?.buttons == [])
    }

    @Test func positionsAreClampedIntoTheDisplay() {
        var pointer = PointerInterpreter()
        var context = fittedContext()
        let effects = pointer.move(to: ViewPoint(x: -50, y: 5000), context: &context)
        let event = effects.pointers.last
        #expect(event?.position.x == 0)
        #expect((event?.position.y ?? -1) <= 599 && (event?.position.y ?? -1) >= 598)
        #expect(event?.display == testDisplay && event?.layoutGeneration == 7)
    }

    @Test func preciseScrollingIsInRemotePixelsAndFollowsTheContent() {
        var pointer = PointerInterpreter()
        var context = fittedContext()
        context.modifiers = .leftShift
        var log: [InteractionEffect] = []
        log += pointer.scroll(by: ViewVector(dx: 0, dy: 10), at: ViewPoint(x: 100, y: 100), phase: .began, isPrecise: true, context: &context)
        log += pointer.scroll(by: ViewVector(dx: 5, dy: 10), at: ViewPoint(x: 100, y: 100), phase: .changed, isPrecise: true, context: &context)
        log += pointer.scroll(by: .zero, at: ViewPoint(x: 100, y: 100), phase: .ended, isPrecise: true, context: &context)
        let scrolls = log.scrolls
        #expect(scrolls.first?.phase == .began && scrolls.last?.phase == .ended)
        // The view shows the display at half size, so 10 view points are 20 remote pixels; with
        // natural scrolling the content follows the fingers (positive = content moves down).
        #expect(scrolls.first?.deltaY == 20)
        #expect(scrolls.contains { $0.deltaX == 10 })
        #expect(scrolls.allSatisfy { $0.isPrecise && $0.modifiers == .leftShift && $0.position == PixelPoint(x: 200, y: 200) })

        pointer.configuration.naturalScrolling = false
        let reversed = pointer.scroll(by: ViewVector(dx: 0, dy: 10), at: ViewPoint(x: 100, y: 100), phase: .none, isPrecise: true, context: &context)
        #expect(reversed.scrolls.first?.deltaY == -20)
    }

    @Test func wheelNotchesAreLinesNotPixels() {
        var pointer = PointerInterpreter()
        var context = fittedContext()
        let effects = pointer.scroll(by: ViewVector(dx: 0, dy: 3), at: ViewPoint(x: 100, y: 100), phase: .none, isPrecise: false, context: &context)
        let scroll = effects.scrolls.first
        #expect(scroll?.isPrecise == false)
        #expect(scroll?.deltaY == 3)
        #expect(scroll?.phase == ScrollEvent.Phase.none)
    }

    @Test func magnifyZoomsTheViewAndSendsNothing() {
        var pointer = PointerInterpreter()
        var context = fittedContext()
        let before = context.viewport.scale
        let effects = pointer.magnify(by: 2, at: ViewPoint(x: 200, y: 150), context: &context)
        #expect(effects.inputs.isEmpty)
        #expect(effects.changesViewport)
        #expect(approximately(context.viewport.scale, before * 2))
        #expect(context.viewport.mode == .free)
    }

    @Test func thePencilIsAPointerThatPressesWhileItTouches() {
        var pointer = PointerInterpreter()
        var context = fittedContext()
        var log: [InteractionEffect] = []
        log += pointer.pencil(sample(0, .began, 50, 50, 1), context: &context)
        #expect(pointer.heldButtons == .primary)
        log += pointer.pencil(sample(0, .moved, 80, 50, 1.1), context: &context)
        log += pointer.pencil(sample(0, .ended, 80, 50, 1.2), context: &context)
        let events = log.pointers
        #expect(events.first { $0.buttons == .primary }?.position == PixelPoint(x: 100, y: 100))
        #expect(events.contains(RemoteDesktopInteractionTests.pointer(160, 100, .primary)))
        #expect(events.last == RemoteDesktopInteractionTests.pointer(160, 100))
        #expect(pointer.isIdle)
    }

    @Test func cancelReleasesButtonsAndEndsAScroll() {
        var pointer = PointerInterpreter()
        var context = fittedContext()
        _ = pointer.setButtons(.primary, at: ViewPoint(x: 10, y: 10), context: &context)
        _ = pointer.scroll(by: ViewVector(dx: 0, dy: 4), at: ViewPoint(x: 10, y: 10), phase: .began, isPrecise: true, context: &context)
        let effects = pointer.cancel(context: &context)
        #expect(effects.pointers.last?.buttons == [])
        #expect(effects.scrolls.last?.phase == .cancelled)
        #expect(pointer.isIdle)
        #expect(pointer.cancel(context: &context).inputs.isEmpty, "nothing left to release")
    }

    @Test func aLostTargetSendsNothingNewButStillLetsGo() {
        var pointer = PointerInterpreter()
        var context = fittedContext()
        _ = pointer.setButtons(.primary, at: ViewPoint(x: 10, y: 10), context: &context)
        context.target = nil
        #expect(pointer.move(to: ViewPoint(x: 90, y: 90), context: &context).pointers.allSatisfy { $0.buttons.isEmpty || $0.display == testDisplay })
        let released = pointer.cancel(context: &context)
        #expect(pointer.heldButtons.isEmpty)
        #expect(released.pointers.last?.buttons == [] || released.pointers.isEmpty)
        #expect(pointer.setButtons(.primary, at: ViewPoint(x: 10, y: 10), context: &context).pointers.isEmpty, "no target, no new press")
        #expect(pointer.heldButtons.isEmpty || pointer.cancel(context: &context).isEmpty == false)
    }

    @Test func noSequenceLeavesAButtonHeldAfterCancel() {
        var generator = SplitMix64(seed: 7)
        for _ in 0..<60 {
            var pointer = PointerInterpreter()
            var context = fittedContext()
            var downs = 0
            var held: PointerButtons = []
            func note(_ effects: [InteractionEffect]) {
                for event in effects.pointers {
                    if !event.buttons.subtracting(held).isEmpty { downs += 1 }
                    held = event.buttons
                    #expect(event.position.x >= 0 && event.position.x <= 799 && event.position.y >= 0 && event.position.y <= 599)
                }
            }
            for _ in 0..<200 {
                let location = ViewPoint(x: Double.random(in: -50...450, using: &generator), y: Double.random(in: -50...350, using: &generator))
                switch Int.random(in: 0..<7, using: &generator) {
                case 0: note(pointer.move(to: location, context: &context))
                case 1: note(pointer.setButtons(PointerButtons(rawValue: UInt8.random(in: 0..<8, using: &generator)), at: location, context: &context))
                case 2: note(pointer.scroll(by: ViewVector(dx: 3, dy: -4), at: location, phase: [.began, .changed, .ended, .none].randomElement(using: &generator)!, isPrecise: true, context: &context))
                case 3: note(pointer.pencil(TouchSample(id: 0, phase: [.began, .moved, .ended, .cancelled].randomElement(using: &generator)!, location: location, timestamp: 0), context: &context))
                case 4: note(pointer.magnify(by: Double.random(in: 0.5...2, using: &generator), at: location, context: &context))
                case 5: context.target = Bool.random(using: &generator) ? testTarget : nil
                default: note(pointer.cancel(context: &context))
                }
            }
            context.target = testTarget
            note(pointer.cancel(context: &context))
            #expect(pointer.heldButtons.isEmpty)
            #expect(held.isEmpty, "the remote machine was told about the release")
        }
    }
}

/// The on-screen Mac keyboard's geometry and legends.
@Suite struct MacKeyboardLayoutTests {
    @Test func everyRowHasTheSameWidth() {
        for layout in [MacKeyboardLayout.ansi, .ansiCompact] {
            for row in layout.rows {
                #expect(approximately(row.keys.reduce(0) { $0 + $1.width }, layout.unitWidth), "row \(row.id)")
            }
        }
    }

    @Test func identifiersAreUniqueAndResolvable() {
        let keys = MacKeyboardLayout.ansi.rows.flatMap(\.keys)
        #expect(Set(keys.map(\.id)).count == keys.count)
        for key in keys {
            #expect(MacKeyboardLayout.ansi.key(withID: key.id) == key)
            #expect(!key.accessibilityName.isEmpty)
            #expect(key.width > 0)
        }
        #expect(MacKeyboardLayout.ansi.key(withID: "no-such-key") == nil)
    }

    @Test func theFunctionRowIsOnlyInTheFullLayout() {
        let functionKeys: [KeyCode] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
        let full = Set(MacKeyboardLayout.ansi.rows.flatMap(\.keys).map(\.key))
        let compact = Set(MacKeyboardLayout.ansiCompact.rows.flatMap(\.keys).map(\.key))
        #expect(functionKeys.allSatisfy(full.contains))
        #expect(full.contains(.escape))
        #expect(functionKeys.allSatisfy { !compact.contains($0) })
        #expect(MacKeyboardLayout.ansiCompact.rows.count == MacKeyboardLayout.ansi.rows.count - 1)
        #expect(MacKeyboardLayout.ansi.rows.first?.heightFactor ?? 1 < 1)
    }

    @Test func everyPrintableCharacterOfTheUSLayoutIsOnExactlyOneKey() {
        let keys = MacKeyboardLayout.ansi.rows.flatMap(\.keys).filter { $0.role == .character }
        for character in "abcdefghijklmnopqrstuvwxyz1234567890`-=[];',./" + "\\" {
            let mapped = KeyTranslator.key(for: character)
            #expect(mapped != nil && mapped?.needsShift == false, "\(character)")
            let matches = keys.filter { $0.key == mapped?.key }
            #expect(matches.count == 1, "\(character)")
            #expect(matches.first?.label.lowercased() == String(character), "\(character)")
            // The legend with Shift is what the layout table says Shift types.
            if let key = matches.first, let shifted = KeyTranslator.character(for: key.key, shift: true), let legend = key.shiftedLabel {
                #expect(legend == String(shifted), "\(character)")
            }
        }
    }

    @Test func modifiersAreOnBothSidesWithTheRightKeyCodes() {
        let keys = MacKeyboardLayout.ansi.rows.flatMap(\.keys)
        func codes(_ modifier: ModifierLatch.Modifier) -> Set<KeyCode> {
            Set(keys.filter { $0.role == .modifier(modifier) }.map(\.key))
        }
        #expect(codes(.shift) == [.leftShift, .rightShift])
        #expect(codes(.command) == [.leftCommand, .rightCommand])
        #expect(codes(.option) == [.leftOption, .rightOption])
        #expect(codes(.control).contains(.leftControl))
        #expect(codes(.function) == [.function])
        for code in [KeyCode.space, .returnOrEnter, .deleteBackward, .tab, .capsLock, .leftArrow, .rightArrow, .upArrow, .downArrow] {
            #expect(keys.contains { $0.key == code }, "\(code.rawValue)")
        }
    }

    /// Wiring each modifier key to the latch with its own side must press exactly that key.
    @Test func eachModifierKeyLatchesItsOwnKeyCode() {
        for key in MacKeyboardLayout.ansi.rows.flatMap(\.keys) {
            guard case .modifier(let modifier) = key.role else { continue }
            var latch = ModifierLatch()
            let events = latch.tap(modifier, side: key.modifierSide)
            if modifier == .function {
                #expect(events.isEmpty)
            } else {
                #expect(events.map(\.key) == [key.key], "\(key.id)")
            }
        }
    }
}
