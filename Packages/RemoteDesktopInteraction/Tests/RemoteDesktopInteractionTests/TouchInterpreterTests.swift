// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import RemoteDesktopInteraction
import Testing

@Suite struct TouchTapTests {
    @Test func tapClicksAtThePointImmediately() {
        var rig = Rig(TouchInterpreter())
        #expect(rig.down(100, 50, at: 0).isEmpty)
        let effects = rig.up(100, 50, at: 0.1)
        #expect(effects.pointers == [pointer(200, 100), pointer(200, 100, .primary), pointer(200, 100)])
        #expect(effects.first == .pointerMoved)
        #expect(effects.feedback.isEmpty)
        #expect(rig.context.pointer == PixelPoint(x: 200, y: 100))
        #expect(rig.context.buttons.isEmpty)
        #expect(rig.interpreter.isIdle)
        #expect(rig.interpreter.nextDeadline == nil)
    }

    @Test func tapUsesWhereTheFingerLifted() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        #expect(rig.move(104, 53, at: 0.05).isEmpty)   // within slop: still a tap
        let effects = rig.up(104, 53, at: 0.1)
        #expect(effects.pointers.map(\.position) == Array(repeating: PixelPoint(x: 208, y: 106), count: 3))
    }

    @Test func aSlowPressShortOfLongPressIsStillAClick() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        #expect(rig.advance(to: 0.4).isEmpty)
        #expect(rig.up(100, 50, at: 0.44).pointers.map(\.buttons) == [[], .primary, []])
    }

    @Test func doubleTapLandsOnTheFirstTapsExactPixel() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        rig.up(100, 50, at: 0.08)
        rig.down(106, 53, at: 0.2)
        let second = rig.up(107, 54, at: 0.28)
        #expect(second.pointers == [pointer(200, 100), pointer(200, 100, .primary), pointer(200, 100)])
        // Already there, so the local cursor has nothing to redraw.
        #expect(!second.contains(.pointerMoved))

        // A third tap keeps snapping, so triple-click works too.
        rig.down(110, 56, at: 0.4)
        #expect(rig.up(110, 56, at: 0.45).pointers.allSatisfy { $0.position == PixelPoint(x: 200, y: 100) })
        #expect(rig.log.pointers.count == 9)
    }

    @Test func tapsTooFarApartInTimeOrSpaceAreSeparateClicks() {
        var late = Rig(TouchInterpreter())
        late.down(100, 50, at: 0)
        late.up(100, 50, at: 0.08)
        late.down(106, 53, at: 0.5)
        #expect(late.up(106, 53, at: 0.55).pointers.first == pointer(212, 106))

        var far = Rig(TouchInterpreter())
        far.down(100, 50, at: 0)
        far.up(100, 50, at: 0.08)
        far.down(130, 50, at: 0.2)
        #expect(far.up(130, 50, at: 0.25).pointers.first == pointer(260, 100))
    }

    @Test func eventsCarryTheTargetsDisplayAndGeneration() {
        var rig = Rig(TouchInterpreter())
        rig.context.target = PointerTarget(display: DisplayID(4), pixelSize: PixelSize(width: 800, height: 600), layoutGeneration: 99)
        rig.down(10, 10, at: 0)
        let events = rig.up(10, 10, at: 0.05).pointers
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.display == DisplayID(4) && $0.layoutGeneration == 99 })
    }

    @Test func tapOutsideTheDesktopClampsToItsEdge() {
        var context = fittedContext()
        context.viewport.viewSize = ViewSize(width: 400, height: 400)   // letterboxed: desktop at y 50...350
        var rig = Rig(TouchInterpreter(), context)
        rig.down(390, 380, at: 0)
        #expect(rig.up(390, 380, at: 0.05).pointers.last == pointer(780, 599))
    }
}

@Suite struct TouchOneFingerDragTests {
    @Test func dragMovesThePointerWhenNothingCanPan() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        #expect(rig.move(105, 50, at: 0.02).isEmpty)
        let first = rig.move(130, 50, at: 0.05)
        #expect(first == [.pointerMoved, .input(.pointer(pointer(260, 100)))])
        #expect(rig.interpreter.nextDeadline == nil)   // the long-press timer is gone
        #expect(rig.move(140, 60, at: 0.07).pointers == [pointer(280, 120)])
        #expect(rig.up(140, 60, at: 0.2).isEmpty)
        #expect(rig.log.pointers.allSatisfy { $0.buttons.isEmpty })
        #expect(!rig.log.changesViewport)
        #expect(rig.interpreter.isIdle)
    }

    @Test func dragPansWhenZoomed() {
        var rig = Rig(TouchInterpreter(), zoomedContext())
        rig.down(200, 150, at: 0)
        #expect(rig.move(208, 150, at: 0.02).isEmpty)
        let effects = rig.move(180, 150, at: 0.04)
        #expect(effects == [.viewportChanged])
        #expect(rig.context.viewport.origin == ViewPoint(x: -228, y: -150))
        rig.move(180, 170, at: 0.06)
        #expect(rig.context.viewport.origin == ViewPoint(x: -228, y: -130))
        #expect(rig.up(180, 170, at: 0.1).isEmpty)
        #expect(rig.log.inputs.isEmpty)
        #expect(rig.context.viewport.mode == .free)
    }

    @Test func panStopsAtTheEdgeWithoutEffects() {
        var rig = Rig(TouchInterpreter(), zoomedContext())
        rig.down(100, 100, at: 0)
        rig.move(400, 100, at: 0.02)
        #expect(rig.context.viewport.origin.x == 0)
        #expect(rig.move(500, 100, at: 0.04).isEmpty)
    }

    @Test func aTapAfterADragIsNotADoubleTap() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        rig.up(100, 50, at: 0.05)
        rig.down(100, 50, at: 0.1)
        rig.move(160, 50, at: 0.15)
        rig.up(160, 50, at: 0.2)
        rig.down(104, 50, at: 0.3)
        #expect(rig.up(104, 50, at: 0.35).pointers.first == pointer(208, 100))
    }
}

@Suite struct TouchLongPressTests {
    @Test func longPressFiresAtItsDeadline() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 1)
        #expect(rig.interpreter.nextDeadline == 1.45)
        #expect(rig.advance(to: 1.44).isEmpty)
        #expect(rig.interpreter.nextDeadline == 1.45)
        #expect(rig.advance(to: 1.45) == [.feedback(.longPress)])
        #expect(rig.interpreter.nextDeadline == nil)
        #expect(rig.advance(to: 2).isEmpty)
        #expect(!rig.interpreter.isIdle)
    }

    @Test func longPressThenLiftIsASecondaryClick() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        rig.advance(to: 0.45)
        #expect(rig.move(103, 52, at: 0.5).isEmpty)   // still within slop
        let effects = rig.up(103, 52, at: 0.6)
        #expect(effects.pointers == [pointer(200, 100), pointer(200, 100, .secondary), pointer(200, 100)])
        #expect(effects.last == .feedback(.secondaryClick))
        #expect(rig.context.buttons.isEmpty)
        #expect(rig.interpreter.isIdle)
    }

    @Test func aLateTimerDoesNotChangeTheOutcome() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        // `advance` never ran; the lift's own timestamp proves the press was long.
        let effects = rig.up(100, 50, at: 0.7)
        #expect(effects.feedback == [.longPress, .secondaryClick])
        #expect(effects.pointers.map(\.buttons) == [[], .secondary, []])
    }

    @Test func movingBeforeTheDeadlineCancelsTheLongPress() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        rig.move(150, 50, at: 0.2)
        #expect(rig.advance(to: 1).isEmpty)
        rig.move(160, 50, at: 1.1)
        rig.up(160, 50, at: 1.2)
        #expect(rig.log.feedback.isEmpty)
        #expect(rig.log.pointers.allSatisfy { $0.buttons.isEmpty })
    }

    @Test func longPressThenMoveDragsFromThePressPoint() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        rig.advance(to: 0.5)
        #expect(rig.move(104, 50, at: 0.55).isEmpty)
        let start = rig.move(130, 70, at: 0.6)
        #expect(start.pointers == [pointer(200, 100), pointer(200, 100, .primary), pointer(260, 140, .primary)])
        #expect(start.feedback == [.dragBegan])
        #expect(rig.context.buttons == .primary)

        #expect(rig.move(150, 90, at: 0.65).pointers == [pointer(300, 180, .primary)])
        let end = rig.up(150, 90, at: 0.8)
        #expect(end.pointers == [pointer(300, 180)])
        #expect(rig.context.buttons.isEmpty)
        #expect(rig.interpreter.isIdle)
        #expect(!rig.log.changesViewport)
    }

    /// A Mac's Finder picks a file up only if the pointer moves within about half a second of the
    /// button going down. However long the finger rests after the long press, the press goes out
    /// with the first movement, never ahead of it.
    @Test func theButtonOfALongPressDragGoesDownWithTheFirstMovementHoweverLongTheFingerRested() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        rig.advance(to: 0.5)
        #expect(rig.log.pointers.isEmpty)
        // Three seconds of holding still, with the small tremble a resting finger has.
        #expect(rig.move(102, 51, at: 1.5).isEmpty)
        #expect(rig.move(101, 50, at: 3.4).isEmpty)
        let start = rig.move(130, 70, at: 3.5)
        #expect(start.pointers == [pointer(200, 100), pointer(200, 100, .primary), pointer(260, 140, .primary)])
        rig.up(130, 70, at: 3.6)
    }

    @Test func dragDoesNotPanTheViewportAwayFromEdges() {
        var rig = Rig(TouchInterpreter(), zoomedContext())
        let origin = rig.context.viewport.origin
        rig.down(200, 150, at: 0)
        rig.advance(to: 0.5)
        rig.move(230, 180, at: 0.6)
        #expect(rig.context.viewport.origin == origin)
        #expect(rig.interpreter.nextDeadline == nil)
        #expect(rig.log.pointers.last == pointer(430, 330, .primary))
        rig.up(230, 180, at: 0.7)
    }

    @Test func draggingNearAnEdgeAutoPansAndKeepsSendingThePointer() throws {
        var rig = Rig(TouchInterpreter(), zoomedContext())
        rig.down(200, 150, at: 0)
        rig.advance(to: 0.5)
        rig.move(395, 150, at: 0.6)
        #expect(rig.log.pointers.last == pointer(595, 300, .primary))
        let deadline = try #require(rig.interpreter.nextDeadline)
        #expect(approximately(deadline, 0.6 + 1.0 / 60.0))

        let tick = rig.advance(to: 0.7)
        #expect(tick.changesViewport)
        let speed = 900 * (395.0 - 356.0) / 44.0
        #expect(approximately(rig.context.viewport.origin.x, -200 - speed * 0.1))
        // The finger did not move; the desktop moved under it.
        let sent = try #require(tick.pointers.last)
        #expect(sent.buttons == .primary)
        #expect(approximately(sent.position.x, 595 + speed * 0.1))
        #expect(rig.context.pointer == sent.position)

        // Keeps going until the desktop's right edge arrives, then the timer stops.
        rig.runTimers(until: 5)
        #expect(approximately(rig.context.viewport.origin.x, -400))
        #expect(rig.interpreter.nextDeadline == nil)
        #expect(rig.log.pointers.last?.position.x == 795)

        // Moving back to the middle leaves no timer either.
        rig.move(200, 150, at: 5.1)
        #expect(rig.interpreter.nextDeadline == nil)
        let end = rig.up(200, 150, at: 5.2)
        #expect(end.pointers.last?.buttons == [])
        #expect(rig.context.buttons.isEmpty)
    }

    @Test func aLateAutoPanTickIsBounded() {
        var rig = Rig(TouchInterpreter(), zoomedContext())
        rig.context.viewport.pan(by: ViewVector(dx: 200, dy: 0))   // origin.x = 0, 400 points to go
        rig.down(200, 150, at: 0)
        rig.advance(to: 0.5)
        rig.move(400, 150, at: 0.6)
        rig.advance(to: 60)   // the app was stalled for a minute
        #expect(approximately(rig.context.viewport.origin.x, -90))
        rig.up(400, 150, at: 61)
    }

    @Test func extraFingersDoNotDisturbADrag() {
        var rig = Rig(TouchInterpreter())
        rig.down(0, 100, 50, at: 0)
        rig.advance(to: 0.5)
        rig.move(0, 130, 50, at: 0.6)
        #expect(rig.down(1, 300, 200, at: 0.7).isEmpty)
        #expect(rig.move(1, 320, 220, at: 0.75).isEmpty)
        #expect(rig.move(0, 140, 50, at: 0.8).pointers == [pointer(280, 100, .primary)])
        #expect(rig.up(1, 320, 220, at: 0.85).isEmpty)
        #expect(rig.context.buttons == .primary)
        #expect(rig.up(0, 140, 50, at: 0.9).pointers == [pointer(280, 100)])
        #expect(rig.interpreter.isIdle)
    }

    @Test func liftingTheDraggingFingerFirstReleasesAndWaitsForTheOther() {
        var rig = Rig(TouchInterpreter())
        rig.down(0, 100, 50, at: 0)
        rig.advance(to: 0.5)
        rig.move(0, 130, 50, at: 0.6)
        rig.down(1, 300, 200, at: 0.7)
        #expect(rig.up(0, 130, 50, at: 0.8).pointers == [pointer(260, 100)])
        #expect(rig.context.buttons.isEmpty)
        // The leftover finger is inert, and a new finger does not start anything with it.
        #expect(rig.move(1, 200, 100, at: 0.9).isEmpty)
        #expect(rig.down(2, 50, 50, at: 1.0).isEmpty)
        #expect(rig.up(2, 50, 50, at: 1.05).isEmpty)
        #expect(rig.up(1, 200, 100, at: 1.1).isEmpty)
        #expect(rig.interpreter.isIdle)
        rig.down(3, 10, 10, at: 2)
        #expect(rig.up(3, 10, 10, at: 2.05).pointers.count == 3)
    }
}

@Suite struct TouchCancellationTests {
    @Test func cancelledTouchReleasesTheButton() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        rig.advance(to: 0.5)
        rig.move(130, 50, at: 0.6)
        #expect(rig.context.buttons == .primary)
        let effects = rig.send([sample(0, .cancelled, 130, 50, 0.7)])
        #expect(effects.pointers == [pointer(260, 100)])
        #expect(rig.context.buttons.isEmpty)
        #expect(rig.interpreter.isIdle)
    }

    @Test func cancelledTapDoesNotClick() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        #expect(rig.send([sample(0, .cancelled, 100, 50, 0.05)]).isEmpty)
        #expect(rig.interpreter.isIdle)
        #expect(rig.interpreter.nextDeadline == nil)
    }

    @Test func cancelForgetsEveryFinger() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        rig.advance(to: 0.5)
        rig.move(130, 50, at: 0.6)
        #expect(rig.cancel().pointers == [pointer(260, 100)])
        #expect(rig.interpreter.isIdle)
        // The platform may still report the finger; it means nothing now.
        #expect(rig.move(160, 50, at: 0.7).isEmpty)
        #expect(rig.up(160, 50, at: 0.8).isEmpty)
        #expect(rig.cancel().isEmpty)
    }

    @Test func samplesForUnknownFingersAreIgnored() {
        var rig = Rig(TouchInterpreter())
        #expect(rig.up(9, 10, 10, at: 0).isEmpty)
        #expect(rig.move(9, 10, 10, at: 0.1).isEmpty)
        #expect(rig.send([sample(9, .cancelled, 10, 10, 0.2)]).isEmpty)
        #expect(rig.interpreter.isIdle)
        #expect(rig.advance(to: 5).isEmpty)
    }

    @Test func repeatedBeganIsTreatedAsMovement() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        rig.down(100, 50, at: 0.01)
        #expect(rig.up(100, 50, at: 0.1).pointers.count == 3)
        #expect(rig.interpreter.isIdle)
    }
}

@Suite struct TouchWithoutTargetTests {
    @Test func nothingIsSentButViewportGesturesStillWork() {
        var context = zoomedContext()
        context.target = nil
        var rig = Rig(TouchInterpreter(), context)
        rig.down(100, 50, at: 0)
        rig.up(100, 50, at: 0.05)                 // tap
        rig.down(100, 50, at: 1)
        rig.advance(to: 1.5)
        rig.up(100, 50, at: 1.6)                  // long-press
        rig.down(200, 150, at: 2)
        rig.move(170, 150, at: 2.05)              // pan
        rig.up(170, 150, at: 2.1)
        rig.send([sample(0, .began, 150, 150, 3), sample(1, .began, 250, 150, 3)])
        rig.send([sample(0, .moved, 150, 190, 3.02), sample(1, .moved, 250, 190, 3.02)])   // scroll
        rig.send([sample(0, .ended, 150, 190, 3.04), sample(1, .ended, 250, 190, 3.04)])
        rig.send([sample(0, .began, 150, 150, 4), sample(1, .began, 250, 150, 4)])
        rig.send([sample(0, .moved, 130, 150, 4.02), sample(1, .moved, 270, 150, 4.02)])   // pinch
        rig.send([sample(0, .ended, 130, 150, 4.04), sample(1, .ended, 270, 150, 4.04)])
        #expect(rig.log.inputs.isEmpty)
        #expect(rig.log.feedback.isEmpty)
        #expect(rig.log.changesViewport)
        #expect(rig.context.viewport.scale > 1)
        #expect(rig.interpreter.isIdle)
    }

    @Test func losingTheTargetMidDragReleasesTheButton() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        rig.advance(to: 0.5)
        rig.move(130, 50, at: 0.6)
        rig.context.target = nil                   // the display went away
        let effects = rig.move(150, 50, at: 0.7)
        #expect(effects.pointers == [pointer(260, 100)])   // release, addressed to the display it was pressed on
        #expect(rig.context.buttons.isEmpty)
        #expect(rig.move(170, 50, at: 0.8).isEmpty)
        rig.context.target = testTarget
        #expect(rig.move(190, 50, at: 0.9).isEmpty)        // a returning target does not resume the drag
        #expect(rig.up(190, 50, at: 1).isEmpty)
        #expect(rig.interpreter.isIdle)
    }

    @Test func aChangedLayoutMidDragReleasesOnTheNewTarget() {
        var rig = Rig(TouchInterpreter())
        rig.down(100, 50, at: 0)
        rig.advance(to: 0.5)
        rig.move(390, 290, at: 0.6)
        rig.context.target = PointerTarget(display: testDisplay, pixelSize: PixelSize(width: 400, height: 300), layoutGeneration: 8)
        let end = rig.up(390, 290, at: 0.7).pointers
        #expect(end == [PointerEvent(display: testDisplay, position: PixelPoint(x: 399, y: 299), buttons: [], layoutGeneration: 8)])
    }
}
