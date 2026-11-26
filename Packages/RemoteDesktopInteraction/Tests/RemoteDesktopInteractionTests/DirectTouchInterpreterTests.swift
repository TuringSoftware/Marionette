// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import RemoteDesktopInteraction
import Testing

private extension Array where Element == InteractionEffect {
    var touches: [TouchEvent] {
        inputs.compactMap { if case .touch(let event) = $0 { event } else { nil } }
    }
}

private func contact(_ id: Int, _ x: Double, _ y: Double, _ phase: TouchEvent.Contact.Phase = .touching) -> TouchEvent.Contact {
    TouchEvent.Contact(id: id, position: PixelPoint(x: x, y: y), phase: phase)
}

private func touch(_ contacts: TouchEvent.Contact...) -> TouchEvent {
    TouchEvent(display: testDisplay, contacts: contacts, layoutGeneration: 7)
}

/// Fingers straight to a remote machine that takes touches: each platform event is one touch event
/// listing every finger, in the display's pixels, and nothing else happens here.
@Suite struct DirectTouchInterpreterTests {
    @Test func aTapIsAFingerLandingAndLiftingWhereItWas() {
        var rig = Rig(DirectTouchInterpreter(maximumContacts: 5))
        #expect(rig.down(100, 50, at: 0) == [.input(.touch(touch(contact(0, 200, 100))))])
        #expect(!rig.interpreter.isIdle)
        #expect(rig.up(101, 51, at: 0.1) == [.input(.touch(touch(contact(0, 202, 102, .lifted))))])
        #expect(rig.interpreter.isIdle)
        #expect(rig.interpreter.nextDeadline == nil)
        // The pointer and the view stay where they were.
        #expect(rig.context == fittedContext())
    }

    @Test func everyFingerIsInEveryEventUntilItLifts() {
        var rig = Rig(DirectTouchInterpreter(maximumContacts: 5))
        rig.send([sample(10, .began, 100, 50, 0), sample(11, .began, 200, 100, 0)])
        rig.send([sample(10, .moved, 110, 50, 0.02), sample(11, .moved, 190, 100, 0.02)])
        rig.up(10, 120, 50, at: 0.04)
        rig.move(11, 180, 100, at: 0.06)
        rig.up(11, 180, 100, at: 0.08)
        #expect(rig.log.touches == [
            touch(contact(0, 200, 100), contact(1, 400, 200)),
            touch(contact(0, 220, 100), contact(1, 380, 200)),
            touch(contact(0, 240, 100, .lifted), contact(1, 380, 200)),
            touch(contact(1, 360, 200)),
            touch(contact(1, 360, 200, .lifted)),
        ])
    }

    @Test func aLiftedFingersIdGoesToTheNextFinger() {
        var rig = Rig(DirectTouchInterpreter(maximumContacts: 5))
        rig.down(1, 10, 10, at: 0)
        rig.down(2, 20, 20, at: 0)
        rig.up(1, 10, 10, at: 0.1)
        #expect(rig.down(3, 30, 30, at: 0.2).touches == [touch(contact(0, 60, 60), contact(1, 40, 40))])
    }

    @Test func fingersBeyondTheMaximumAreLeftOutUntilTheyLift() {
        var rig = Rig(DirectTouchInterpreter(maximumContacts: 2))
        rig.down(1, 10, 10, at: 0)
        rig.down(2, 20, 20, at: 0)
        #expect(rig.down(3, 30, 30, at: 0).isEmpty)
        #expect(rig.move(3, 35, 35, at: 0.1).isEmpty)
        #expect(rig.up(3, 35, 35, at: 0.2).isEmpty)
        rig.up(1, 10, 10, at: 0.3)
        // A finger that landed while every id was taken stays out even once one is free.
        #expect(rig.move(3, 36, 36, at: 0.4).isEmpty)
    }

    @Test func positionsStayInsideTheDisplay() {
        var rig = Rig(DirectTouchInterpreter(maximumContacts: 5))
        #expect(rig.down(-20, 500, at: 0).touches == [touch(contact(0, 0, 599))])
    }

    @Test func zoomedPositionsFollowTheViewport() {
        var rig = Rig(DirectTouchInterpreter(maximumContacts: 5), zoomedContext())
        #expect(rig.down(0, 0, at: 0).touches == [touch(contact(0, 200, 150))])
    }

    @Test func fingersTheSystemTakesAwayAreCancelled() {
        var rig = Rig(DirectTouchInterpreter(maximumContacts: 5))
        rig.down(1, 10, 10, at: 0)
        rig.down(2, 20, 20, at: 0)
        #expect(rig.send([sample(1, .cancelled, 99, 99, 0.1)]).touches == [touch(contact(0, 20, 20, .cancelled), contact(1, 40, 40))])
        #expect(rig.cancel().touches == [touch(contact(1, 40, 40, .cancelled))])
        #expect(rig.interpreter.isIdle)
        #expect(rig.cancel().isEmpty)
    }

    /// The display under the fingers changed while they were down: they are let go there, and the
    /// next fingers start on the new one.
    @Test func aNewTargetCancelsTheFingersOnTheOldOne() {
        var rig = Rig(DirectTouchInterpreter(maximumContacts: 5))
        rig.down(1, 10, 10, at: 0)
        rig.context.target = PointerTarget(display: DisplayID(2), pixelSize: PixelSize(width: 800, height: 600), layoutGeneration: 8)
        let effects = rig.move(1, 12, 12, at: 0.1)
        #expect(effects.touches == [touch(contact(0, 20, 20, .cancelled))])
        let next = rig.down(4, 10, 10, at: 0.2).touches
        #expect(next.map(\.display) == [DisplayID(2)])
        #expect(next.map(\.layoutGeneration) == [8])

        // With nothing to aim at, the fingers down are let go and a new one goes nowhere.
        rig.context.target = nil
        #expect(rig.down(5, 10, 10, at: 0.3).touches.map(\.contacts.first?.phase) == [.cancelled])
        #expect(rig.interpreter.isIdle)
    }
}
