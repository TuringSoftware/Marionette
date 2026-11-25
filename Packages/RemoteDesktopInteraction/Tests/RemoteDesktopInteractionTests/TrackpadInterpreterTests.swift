// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import RemoteDesktopInteraction
import Testing

private func plain() -> GestureConfiguration {
    var configuration = GestureConfiguration()
    configuration.pointerAcceleration = false
    return configuration
}

@Suite struct TrackpadPointerTests {
    @Test func fingerMovesTheCursorRelatively() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()))
        #expect(rig.down(300, 250, at: 0).isEmpty)       // where the finger lands is irrelevant
        #expect(rig.move(303, 250, at: 0.05).isEmpty)    // inside the move slop
        let first = rig.move(310, 250, at: 0.1)
        // 7 points since the previous sample, shown at 0.5 points per pixel: 14 pixels.
        #expect(first == [.pointerMoved, .input(.pointer(pointer(414, 300)))])
        #expect(rig.move(310, 240, at: 0.2).pointers == [pointer(414, 280)])
        #expect(rig.up(310, 240, at: 0.6).isEmpty)
        #expect(rig.context.pointer == PixelPoint(x: 414, y: 280))
        #expect(rig.log.pointers.allSatisfy { $0.buttons.isEmpty && $0.layoutGeneration == 7 })
        #expect(rig.interpreter.isIdle)
    }

    @Test func cursorTravelMatchesFingerTravelAtAnyZoom() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()), zoomedContext())
        rig.down(100, 100, at: 0)
        rig.move(110, 100, at: 0.1)
        rig.move(130, 100, at: 0.2)
        // At 1 point per pixel, 30 points of finger are 30 pixels (and 30 points on screen).
        #expect(rig.context.pointer == PixelPoint(x: 430, y: 300))
    }

    @Test func cursorStopsAtTheDisplayEdges() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()))
        rig.context.pointer = PixelPoint(x: 790, y: 5)
        rig.down(100, 100, at: 0)
        rig.move(120, 90, at: 0.1)
        #expect(rig.context.pointer == PixelPoint(x: 799, y: 0))
        // Pushing further against the corner sends nothing, but says where the pointer would have
        // gone, so the session can carry it on to another display.
        let pushed = rig.move(140, 80, at: 0.2)
        #expect(pushed.count == 1)
        if case .pointerPushedPastEdge(let beyond) = pushed.first {
            #expect(beyond.x > 799 && beyond.y < 0)
        } else {
            Issue.record("expected a push past the edge, got \(pushed)")
        }
        // Sliding along the edge still works.
        #expect(rig.move(140, 100, at: 0.3).pointers == [pointer(799, 40)])
        rig.up(140, 100, at: 1)
    }

    @Test func fastFingersTravelFurther() {
        var slow = Rig(TrackpadInterpreter())
        slow.down(100, 100, at: 0)
        slow.move(110, 100, at: 0.1)      // 100 pt/s: no acceleration
        slow.move(120, 100, at: 0.2)
        #expect(slow.context.pointer.x == 440)

        var fast = Rig(TrackpadInterpreter())
        fast.down(100, 100, at: 0)
        fast.move(110, 100, at: 0.1)
        fast.move(150, 100, at: 0.116)    // 2500 pt/s: tripled
        #expect(approximately(fast.context.pointer.x, 420 + 40 * 3 * 2))

        var unaccelerated = Rig(TrackpadInterpreter(configuration: plain()))
        unaccelerated.down(100, 100, at: 0)
        unaccelerated.move(110, 100, at: 0.1)
        unaccelerated.move(150, 100, at: 0.116)
        #expect(unaccelerated.context.pointer.x == 500)

        var configuration = plain()
        configuration.pointerSpeed = 0.5
        var halved = Rig(TrackpadInterpreter(configuration: configuration))
        halved.down(100, 100, at: 0)
        halved.move(110, 100, at: 0.1)
        halved.move(150, 100, at: 0.2)
        #expect(halved.context.pointer.x == 450)
    }

    @Test func theViewportFollowsTheCursor() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()), zoomedContext())
        // Cursor starts in the middle of the view: pixel (400, 300) at view (200, 150).
        rig.down(50, 50, at: 0)
        let near = rig.move(150, 50, at: 0.1)
        #expect(!near.changesViewport)                  // view x 300: still comfortably visible
        let far = rig.move(250, 50, at: 0.2)
        #expect(far.changesViewport)
        #expect(rig.context.pointer == PixelPoint(x: 600, y: 300))
        // Kept one margin inside the right edge.
        #expect(rig.context.viewport.viewPoint(for: rig.context.pointer) == ViewPoint(x: 376, y: 150))

        rig.move(650, 50, at: 0.3)
        #expect(rig.context.pointer.x == 799)
        // The display's edge has arrived; the viewport cannot go further.
        #expect(rig.context.viewport.contentFrame.maxX == 400)
        rig.up(650, 50, at: 0.4)
        #expect(rig.log.pointers.allSatisfy { $0.buttons.isEmpty })
    }

    @Test func withoutATargetNothingMoves() {
        var rig = Rig(TrackpadInterpreter())
        rig.context.target = nil
        rig.down(100, 100, at: 0)
        rig.move(150, 100, at: 0.1)
        rig.up(150, 100, at: 0.2)
        #expect(rig.log.isEmpty)
        #expect(rig.context.pointer == PixelPoint(x: 400, y: 300))
    }
}

@Suite struct TrackpadClickTests {
    @Test func tapClicksAtTheCursor() {
        var rig = Rig(TrackpadInterpreter())
        rig.down(30, 280, at: 0)
        let effects = rig.up(30, 280, at: 0.1)
        #expect(effects.pointers == [pointer(400, 300), pointer(400, 300, .primary), pointer(400, 300)])
        #expect(!effects.contains(.pointerMoved))
        #expect(rig.context.pointer == PixelPoint(x: 400, y: 300))
        #expect(rig.interpreter.isIdle)
    }

    /// Nudging the pointer with short, quick strokes: each moves it, none clicks, and the second is
    /// not taken for the drag half of a double tap.
    @Test func aQuickShortStrokeMovesThePointerAndNeverClicks() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()))
        rig.down(100, 100, at: 0)
        rig.move(106, 100, at: 0.04)                    // past the move slop, within the tap slop
        #expect(rig.context.pointer == PixelPoint(x: 412, y: 300))
        let first = rig.up(106, 100, at: 0.09)
        #expect(first.pointers.allSatisfy { $0.buttons.isEmpty })
        #expect(rig.context.pointer == PixelPoint(x: 412, y: 300))

        rig.down(100, 100, at: 0.15)
        let second = rig.move(110, 100, at: 0.2)
        let lifted = rig.up(110, 100, at: 0.25)
        #expect((second.pointers + lifted.pointers).allSatisfy { $0.buttons.isEmpty })
        #expect(rig.context.pointer.x > 412)
    }

    @Test func aShortDeliberateMoveIsNotATap() {
        var far = Rig(TrackpadInterpreter(configuration: plain()))
        far.down(100, 100, at: 0)
        far.move(108, 100, at: 0.04)
        far.move(116, 100, at: 0.08)                    // beyond the tap slop
        #expect(far.up(116, 100, at: 0.1).isEmpty)

        var slow = Rig(TrackpadInterpreter(configuration: plain()))
        slow.down(100, 100, at: 0)
        slow.move(106, 100, at: 0.2)
        #expect(slow.up(106, 100, at: 0.4).isEmpty)     // too slow to be a tap
        #expect(slow.context.pointer == PixelPoint(x: 412, y: 300))
    }

    @Test func doubleTapClicksTwiceInPlace() {
        var rig = Rig(TrackpadInterpreter())
        rig.down(100, 100, at: 0)
        rig.up(100, 100, at: 0.08)
        rig.down(180, 40, at: 0.2)                      // anywhere on the surface
        rig.up(180, 40, at: 0.28)
        #expect(rig.log.pointers.map(\.buttons) == [[], .primary, [], [], .primary, []])
        #expect(rig.log.pointers.allSatisfy { $0.position == PixelPoint(x: 400, y: 300) })
        // Each click is felt, as on a Mac trackpad.
        #expect(rig.log.feedback == [.click, .click])
    }

    @Test func doubleTapAndHoldThenMoveDrags() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()))
        rig.down(100, 100, at: 0)
        rig.up(100, 100, at: 0.08)
        rig.down(100, 100, at: 0.2)
        let start = rig.move(110, 100, at: 0.3)
        #expect(start.pointers == [pointer(400, 300, .primary), pointer(420, 300, .primary)])
        #expect(start.feedback == [.dragBegan])
        #expect(rig.context.buttons == .primary)
        #expect(rig.move(110, 120, at: 0.4).pointers == [pointer(420, 340, .primary)])
        #expect(rig.up(110, 120, at: 0.5).pointers == [pointer(420, 340)])
        #expect(rig.context.buttons.isEmpty)
        #expect(rig.interpreter.isIdle)
    }

    /// As in touch mode, and for the same reason (a Mac's Finder wants movement within half a
    /// second of the press): held after a double tap, or pressed long, the button goes down with
    /// the finger's first movement, however long the finger waited.
    @Test func theButtonOfADragGoesDownWithTheFirstMovementHoweverLongTheFingerWaited() {
        var held = Rig(TrackpadInterpreter(configuration: plain()))
        held.down(100, 100, at: 0)
        held.up(100, 100, at: 0.08)
        held.down(100, 100, at: 0.2)
        held.advance(to: 0.7)
        #expect(held.move(101, 100, at: 2.0).isEmpty)
        #expect(held.log.pointers.map(\.buttons) == [[], .primary, []], "only the first tap's click so far")
        let start = held.move(110, 100, at: 3.0)
        #expect(start.pointers.map(\.buttons) == [.primary, .primary])
        #expect(start.pointers.first?.position == PixelPoint(x: 400, y: 300))
        held.up(110, 100, at: 3.1)

        var pressed = Rig(TrackpadInterpreter(configuration: plain()))
        pressed.down(100, 100, at: 0)
        pressed.advance(to: 0.5)
        #expect(pressed.move(101, 100, at: 2.0).isEmpty)
        #expect(pressed.log.pointers.isEmpty)
        #expect(pressed.move(110, 100, at: 3.0).pointers.map(\.buttons) == [.primary, .primary])
        pressed.up(110, 100, at: 3.1)
    }

    @Test func aSecondTouchAfterTheIntervalJustMoves() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()))
        rig.down(100, 100, at: 0)
        rig.up(100, 100, at: 0.08)
        rig.down(100, 100, at: 0.5)
        rig.move(110, 100, at: 0.6)
        rig.up(110, 100, at: 1.2)
        #expect(rig.log.pointers.last == pointer(420, 300))
        // The tap's click is felt; the move after it is not a drag, so nothing more.
        #expect(rig.log.feedback == [.click])
    }

    @Test func aDragIsFeltWhenItsButtonGoesDownAndComesUp() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()))
        rig.down(100, 100, at: 0)
        rig.up(100, 100, at: 0.08)
        rig.down(100, 100, at: 0.2)
        rig.move(110, 100, at: 0.25)
        rig.move(120, 100, at: 0.3)
        rig.up(120, 100, at: 0.4)
        #expect(rig.log.feedback == [.click, .dragBegan, .dragEnded])
    }

    @Test func longPressThenLiftIsASecondaryClickAtTheCursor() {
        var rig = Rig(TrackpadInterpreter())
        rig.down(100, 100, at: 0)
        #expect(rig.interpreter.nextDeadline == 0.45)
        #expect(rig.advance(to: 0.45) == [.feedback(.longPress)])
        let effects = rig.up(101, 100, at: 0.7)
        #expect(effects.pointers == [pointer(400, 300), pointer(400, 300, .secondary), pointer(400, 300)])
        #expect(effects.feedback == [.secondaryClick])
    }

    @Test func longPressThenMoveDrags() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()))
        rig.down(100, 100, at: 0)
        rig.advance(to: 0.5)
        #expect(rig.move(102, 100, at: 0.6).isEmpty)
        let start = rig.move(112, 100, at: 0.7)
        #expect(start.pointers == [pointer(400, 300, .primary), pointer(420, 300, .primary)])
        #expect(start.feedback == [.dragBegan])
        rig.move(112, 110, at: 0.8)
        #expect(rig.up(112, 110, at: 0.9).pointers == [pointer(420, 320)])
        #expect(rig.context.buttons.isEmpty)
    }

    @Test func slowSmallMovementDoesNotBecomeALongPress() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()))
        rig.down(100, 100, at: 0)
        rig.move(105, 100, at: 0.2)                     // a careful nudge, past the move slop
        #expect(rig.interpreter.nextDeadline == nil)
        #expect(rig.advance(to: 2).isEmpty)
        rig.move(107, 100, at: 2.1)
        #expect(rig.up(107, 100, at: 3).isEmpty)
        #expect(rig.context.pointer == PixelPoint(x: 414, y: 300))
        #expect(rig.log.feedback.isEmpty)
    }

    @Test func draggingKeepsTheCursorInView() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()), zoomedContext())
        rig.down(50, 50, at: 0)
        rig.advance(to: 0.5)
        rig.move(300, 50, at: 1)
        #expect(rig.context.buttons == .primary)
        #expect(rig.log.changesViewport)
        #expect(rig.context.viewport.viewPoint(for: rig.context.pointer).x == 376)
        #expect(rig.interpreter.nextDeadline == nil)    // following, not edge auto-pan
        rig.up(300, 50, at: 1.5)
        #expect(rig.context.buttons.isEmpty)
    }

    @Test func cancelReleasesADrag() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()))
        rig.down(100, 100, at: 0)
        rig.advance(to: 0.5)
        rig.move(120, 100, at: 0.6)
        #expect(rig.cancel().pointers == [pointer(440, 300)])
        #expect(rig.context.buttons.isEmpty)
        #expect(rig.up(120, 100, at: 0.7).isEmpty)
    }

    @Test func losingTheTargetMidDragReleases() {
        var rig = Rig(TrackpadInterpreter(configuration: plain()))
        rig.down(100, 100, at: 0)
        rig.advance(to: 0.5)
        rig.move(120, 100, at: 0.6)
        rig.context.target = nil
        #expect(rig.move(140, 100, at: 0.7).pointers == [pointer(440, 300)])
        #expect(rig.context.buttons.isEmpty)
        rig.context.target = testTarget
        #expect(rig.move(160, 100, at: 0.8).isEmpty)
        #expect(rig.up(160, 100, at: 0.9).isEmpty)
    }

    @Test func zoomAnchorAndConfigurationAreAdjustable() {
        var interpreter = TrackpadInterpreter()
        #expect(interpreter.zoomAnchor == .touchCentroid)
        interpreter.zoomAnchor = .pointer
        interpreter.configuration.pointerSpeed = 2
        #expect(interpreter.zoomAnchor == .pointer)
        #expect(interpreter.configuration.pointerSpeed == 2)
        #expect(interpreter.isIdle)
    }
}
