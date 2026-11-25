// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import RemoteDesktopInteraction
import Testing

/// Two fingers side by side, 40 points apart, centred on (120, 100) → remote (240, 200).
private func twoDown<I: GestureInterpreter>(_ rig: inout Rig<I>, at time: Double, spacing: Double = 40) {
    rig.send([
        sample(0, .began, 120 - spacing / 2, 100, time),
        sample(1, .began, 120 + spacing / 2, 100, time),
    ])
}

/// Moves both fingers to the same offset from where `twoDown` put them, in one event.
@discardableResult
private func twoMove<I: GestureInterpreter>(
    _ rig: inout Rig<I>,
    dx: Double = 0,
    dy: Double = 0,
    spacing: Double = 40,
    at time: Double
) -> [InteractionEffect] {
    rig.send([
        sample(0, .moved, 120 - spacing / 2 + dx, 100 + dy, time),
        sample(1, .moved, 120 + spacing / 2 + dx, 100 + dy, time),
    ])
}

@discardableResult
private func twoUp<I: GestureInterpreter>(
    _ rig: inout Rig<I>,
    dx: Double = 0,
    dy: Double = 0,
    spacing: Double = 40,
    at time: Double
) -> [InteractionEffect] {
    rig.send([
        sample(0, .ended, 120 - spacing / 2 + dx, 100 + dy, time),
        sample(1, .ended, 120 + spacing / 2 + dx, 100 + dy, time),
    ])
}

@Suite struct TwoFingerTapTests {
    @Test func touchModeClicksSecondaryAtTheMidpoint() {
        var rig = Rig(TouchInterpreter())
        twoDown(&rig, at: 0)
        let effects = twoUp(&rig, at: 0.1)
        #expect(effects.pointers == [pointer(240, 200), pointer(240, 200, .secondary), pointer(240, 200)])
        #expect(effects.feedback == [.secondaryClick])
        #expect(rig.interpreter.isIdle)
        #expect(rig.context.buttons.isEmpty)
    }

    @Test func trackpadModeClicksSecondaryAtTheCursor() {
        var rig = Rig(TrackpadInterpreter())
        twoDown(&rig, at: 0)
        let effects = twoUp(&rig, at: 0.1)
        #expect(effects.pointers == [pointer(400, 300), pointer(400, 300, .secondary), pointer(400, 300)])
        #expect(!effects.contains(.pointerMoved))
    }

    @Test func fingersMayLandAndLiftSlightlyApart() {
        var rig = Rig(TouchInterpreter())
        rig.down(0, 100, 100, at: 0)
        rig.down(1, 140, 100, at: 0.04)
        #expect(rig.interpreter.nextDeadline == nil)   // no long-press with two fingers
        #expect(rig.up(1, 141, 101, at: 0.12).isEmpty)
        #expect(rig.move(0, 101, 101, at: 0.13).isEmpty)
        let effects = rig.up(0, 101, 101, at: 0.15)
        #expect(effects.pointers.map(\.buttons) == [[], .secondary, []])
        #expect(effects.pointers.first?.position == PixelPoint(x: 240, y: 200))
    }

    @Test func restingTwoFingersIsNotATap() {
        var slow = Rig(TouchInterpreter())
        twoDown(&slow, at: 0)
        #expect(twoUp(&slow, at: 0.5).isEmpty)
        #expect(slow.interpreter.isIdle)

        var straggler = Rig(TouchInterpreter())
        twoDown(&straggler, at: 0)
        straggler.up(0, 100, 100, at: 0.1)
        #expect(straggler.up(1, 140, 100, at: 0.6).isEmpty)

        var wanderer = Rig(TouchInterpreter())
        twoDown(&wanderer, at: 0)
        wanderer.up(0, 100, 100, at: 0.1)
        wanderer.move(1, 170, 100, at: 0.15)
        #expect(wanderer.up(1, 170, 100, at: 0.2).isEmpty)
        #expect(wanderer.log.inputs.isEmpty)
    }

    @Test func aThirdFingerSpoilsTheTap() {
        var rig = Rig(TouchInterpreter())
        twoDown(&rig, at: 0)
        rig.up(0, 100, 100, at: 0.05)
        rig.down(2, 200, 200, at: 0.06)
        rig.up(1, 140, 100, at: 0.08)
        rig.up(2, 200, 200, at: 0.1)
        #expect(rig.log.inputs.isEmpty)
        #expect(rig.interpreter.isIdle)
    }
}

@Suite struct TwoFingerScrollTests {
    @Test func latchesAfterTheCentroidTravelsAndReportsPhases() {
        var rig = Rig(TouchInterpreter())
        twoDown(&rig, at: 0)
        #expect(twoMove(&rig, dy: 5, at: 0.016).isEmpty)          // below the 8-point threshold

        let began = twoMove(&rig, dy: 12, at: 0.032)
        // The pointer goes under the fingers first, so the scroll lands in the right window.
        #expect(began.pointers == [pointer(240, 200)])
        #expect(began.scrolls.count == 1)
        let first = began.scrolls[0]
        #expect(first.phase == .began && first.momentumPhase == .none)
        #expect(first.display == testDisplay && first.layoutGeneration == 7)
        #expect(first.position == PixelPoint(x: 240, y: 200))
        #expect(first.isPrecise)
        // 7 view points since the previous sample, at 2 remote pixels per point.
        #expect(first.deltaX == 0 && first.deltaY == 14)

        let changed = twoMove(&rig, dx: -4, dy: 22, at: 0.048).scrolls
        #expect(changed.count == 1)
        #expect(changed[0].phase == .changed)
        #expect(changed[0].deltaX == -8 && changed[0].deltaY == 20)
        #expect(changed[0].position == PixelPoint(x: 240, y: 200))   // stays where it began

        let ended = twoUp(&rig, dx: -4, dy: 22, at: 0.4).scrolls
        #expect(ended.count == 1)
        #expect(ended[0].phase == .ended && ended[0].deltaX == 0 && ended[0].deltaY == 0)
        #expect(rig.interpreter.isIdle)
        #expect(!rig.log.changesViewport)
        #expect(rig.log.pointers.count == 1)
    }

    @Test func naturalScrollingMovesContentWithTheFingers() {
        var natural = Rig(TouchInterpreter())
        twoDown(&natural, at: 0)
        twoMove(&natural, dx: 10, dy: 20, at: 0.02)
        // Fingers went down and right: content moves down and right, which Core calls positive.
        #expect(natural.log.scrolls[0].deltaY == 40 && natural.log.scrolls[0].deltaX == 20)

        var configuration = GestureConfiguration()
        configuration.naturalScrolling = false
        configuration.scrollSpeed = 0.5
        var classic = Rig(TouchInterpreter(configuration: configuration))
        twoDown(&classic, at: 0)
        twoMove(&classic, dx: 10, dy: 20, at: 0.02)
        #expect(classic.log.scrolls[0].deltaY == -20 && classic.log.scrolls[0].deltaX == -10)
    }

    @Test func deltasAreInRemotePixelsAtTheCurrentZoom() {
        var rig = Rig(TouchInterpreter(), zoomedContext())   // 1 view point per remote pixel
        twoDown(&rig, at: 0)
        twoMove(&rig, dy: 20, at: 0.02)
        #expect(rig.log.scrolls[0].deltaY == 20)
        #expect(rig.log.scrolls[0].position == PixelPoint(x: 320, y: 250))
    }

    @Test func aLatchedScrollNeverZooms() {
        var rig = Rig(TouchInterpreter())
        let viewport = rig.context.viewport
        twoDown(&rig, at: 0)
        twoMove(&rig, dy: 20, at: 0.02)
        // Now spread the fingers wide apart, far past the pinch threshold.
        twoMove(&rig, dy: 20, spacing: 200, at: 0.04)
        twoMove(&rig, dy: 30, spacing: 300, at: 0.06)
        twoUp(&rig, dy: 30, spacing: 300, at: 0.4)
        #expect(rig.context.viewport == viewport)
        #expect(!rig.log.changesViewport)
        #expect(rig.log.scrolls.map(\.phase) == [.began, .changed, .ended])
    }

    @Test func aFastScrollWithFingersInLineIsNotMistakenForAPinch() {
        var rig = Rig(TouchInterpreter())
        // One finger above the other, both flicked 30 points down in a single event.
        rig.send([sample(0, .began, 100, 100, 0), sample(1, .began, 100, 180, 0)])
        rig.send([sample(0, .moved, 100, 130, 0.016), sample(1, .moved, 100, 210, 0.016)])
        #expect(rig.log.scrolls.first?.phase == .began)
        #expect(!rig.log.changesViewport)
    }

    @Test func trackpadModeScrollsAtTheCursorWithoutMovingIt() {
        var rig = Rig(TrackpadInterpreter())
        twoDown(&rig, at: 0)
        twoMove(&rig, dy: 20, at: 0.02)
        twoUp(&rig, dy: 20, at: 0.4)
        #expect(rig.log.pointers.isEmpty)
        #expect(rig.log.scrolls.map(\.phase) == [.began, .ended])
        #expect(rig.log.scrolls.allSatisfy { $0.position == PixelPoint(x: 400, y: 300) })
        #expect(rig.context.pointer == PixelPoint(x: 400, y: 300))
    }

    @Test func heldModifiersRideAlong() {
        var rig = Rig(TouchInterpreter())
        rig.context.modifiers = [.leftCommand, .leftShift]
        twoDown(&rig, at: 0)
        twoMove(&rig, dy: 20, at: 0.02)
        twoUp(&rig, dy: 20, at: 0.4)
        #expect(rig.log.scrolls.count == 2)
        #expect(rig.log.scrolls.allSatisfy { $0.modifiers == [.leftCommand, .leftShift] })
    }

    @Test func aThirdFingerIsIgnored() {
        var rig = Rig(TouchInterpreter())
        twoDown(&rig, at: 0)
        twoMove(&rig, dy: 20, at: 0.02)
        #expect(rig.down(2, 300, 250, at: 0.03).isEmpty)
        #expect(rig.move(2, 350, 150, at: 0.04).isEmpty)
        #expect(twoMove(&rig, dy: 30, at: 0.05).scrolls.map(\.deltaY) == [20])
        #expect(rig.up(2, 350, 150, at: 0.06).isEmpty)
        #expect(twoUp(&rig, dy: 30, at: 0.4).scrolls.map(\.phase) == [.ended])
        #expect(rig.interpreter.isIdle)
    }

    @Test func oneFingerLiftingEndsTheScrollAndTheOtherIsInert() {
        var rig = Rig(TouchInterpreter())
        twoDown(&rig, at: 0)
        twoMove(&rig, dy: 20, at: 0.02)
        #expect(rig.up(0, 100, 120, at: 0.4).scrolls.map(\.phase) == [.ended])
        #expect(rig.move(1, 200, 200, at: 0.5).isEmpty)
        #expect(rig.up(1, 200, 200, at: 0.6).isEmpty)
        #expect(rig.interpreter.isIdle)
    }

    @Test func cancellingEndsTheScrollAsCancelled() {
        var viaCancel = Rig(TouchInterpreter())
        twoDown(&viaCancel, at: 0)
        twoMove(&viaCancel, dy: 20, at: 0.02)
        #expect(viaCancel.cancel().scrolls.map(\.phase) == [.cancelled])
        #expect(viaCancel.interpreter.isIdle)

        var viaTouch = Rig(TouchInterpreter())
        twoDown(&viaTouch, at: 0)
        twoMove(&viaTouch, dy: 20, at: 0.02)
        let effects = viaTouch.send([sample(0, .cancelled, 100, 120, 0.03), sample(1, .cancelled, 140, 120, 0.03)])
        #expect(effects.scrolls.map(\.phase) == [.cancelled])
        #expect(viaTouch.interpreter.isIdle)
        #expect(viaTouch.interpreter.nextDeadline == nil)   // no momentum after a cancel
    }

    @Test func scrollStartsLateWhenTheTargetArrivesMidGesture() {
        var rig = Rig(TouchInterpreter())
        rig.context.target = nil
        twoDown(&rig, at: 0)
        #expect(twoMove(&rig, dy: 20, at: 0.02).isEmpty)
        rig.context.target = testTarget
        #expect(twoMove(&rig, dy: 30, at: 0.04).scrolls.map(\.phase) == [.began])
        rig.context.target = nil
        #expect(twoMove(&rig, dy: 40, at: 0.06).isEmpty)
        // The end still goes out, to the display the scroll began on.
        #expect(twoUp(&rig, dy: 40, at: 0.4).scrolls.map(\.phase) == [.ended])
    }
}

@Suite struct TwoFingerZoomTests {
    @Test func latchesAfterTheSpacingChangesAndZoomsAroundTheFingers() {
        var rig = Rig(TouchInterpreter())
        rig.send([sample(0, .began, 150, 150, 0), sample(1, .began, 250, 150, 0)])
        // 10 points of spread: not yet.
        #expect(rig.send([sample(0, .moved, 145, 150, 0.01), sample(1, .moved, 255, 150, 0.01)]).isEmpty)
        let under = rig.context.viewport.remotePoint(for: ViewPoint(x: 200, y: 150))

        let effects = rig.send([sample(0, .moved, 130, 150, 0.02), sample(1, .moved, 270, 150, 0.02)])
        #expect(effects == [.viewportChanged])
        #expect(rig.context.viewport.mode == .free)
        #expect(approximately(rig.context.viewport.scale, 0.5 * 140 / 110))
        let after = rig.context.viewport.remotePoint(for: ViewPoint(x: 200, y: 150))
        #expect(approximately(after.x, under.x) && approximately(after.y, under.y))

        rig.send([sample(0, .moved, 100, 150, 0.03), sample(1, .moved, 300, 150, 0.03)])
        #expect(approximately(rig.context.viewport.scale, 0.5 * 200 / 110))
        rig.send([sample(0, .ended, 100, 150, 0.1), sample(1, .ended, 300, 150, 0.1)])
        #expect(rig.log.inputs.isEmpty)
        #expect(rig.context.viewport.mode == .free)
        #expect(rig.interpreter.isIdle)
    }

    @Test func aLatchedZoomPansButNeverScrolls() {
        var rig = Rig(TouchInterpreter())
        rig.send([sample(0, .began, 150, 150, 0), sample(1, .began, 250, 150, 0)])
        rig.send([sample(0, .moved, 100, 150, 0.02), sample(1, .moved, 300, 150, 0.02)])   // scale 1.0
        #expect(approximately(rig.context.viewport.scale, 1))
        let origin = rig.context.viewport.origin
        // Both fingers now travel together, far past the scroll threshold.
        let effects = rig.send([sample(0, .moved, 60, 120, 0.04), sample(1, .moved, 260, 120, 0.04)])
        #expect(effects == [.viewportChanged])
        #expect(approximately(rig.context.viewport.origin.x, origin.x - 40))
        #expect(approximately(rig.context.viewport.origin.y, origin.y - 30))
        #expect(approximately(rig.context.viewport.scale, 1))
        rig.send([sample(0, .ended, 60, 120, 0.1), sample(1, .ended, 260, 120, 0.1)])
        #expect(rig.log.scrolls.isEmpty)
        #expect(rig.log.inputs.isEmpty)
    }

    @Test func aScrollThatDriftsApartAFewPointsStaysAScroll() {
        var rig = Rig(TouchInterpreter())
        rig.send([sample(0, .began, 150, 150, 0), sample(1, .began, 200, 150, 0)])
        for step in 1...5 {
            let y = 150 - Double(step) * 8
            rig.send([sample(0, .moved, 150 - Double(step), y, Double(step) * 0.02), sample(1, .moved, 200 + Double(step), y, Double(step) * 0.02)])
        }
        rig.send([sample(0, .ended, 145, 110, 0.2), sample(1, .ended, 205, 110, 0.2)])
        #expect(!rig.log.scrolls.isEmpty)
        #expect(approximately(rig.context.viewport.scale, 0.5))
    }

    @Test func endingNearFitSettlesToFit() {
        var rig = Rig(TouchInterpreter())
        rig.send([sample(0, .began, 150, 150, 0), sample(1, .began, 250, 150, 0)])
        rig.send([sample(0, .moved, 140, 150, 0.02), sample(1, .moved, 260, 150, 0.02)])
        #expect(rig.context.viewport.mode == .free)
        rig.send([sample(0, .moved, 149, 150, 0.04), sample(1, .moved, 250, 150, 0.04)])
        #expect(rig.context.viewport.mode == .free)
        let end = rig.send([sample(0, .ended, 149, 150, 0.1), sample(1, .ended, 250, 150, 0.1)])
        #expect(end == [.viewportChanged])
        #expect(rig.context.viewport.mode == .fit)
        #expect(rig.context.viewport.scale == 0.5)
    }

    @Test func pinchingInStopsAtTheMinimum() {
        var rig = Rig(TouchInterpreter())
        rig.send([sample(0, .began, 100, 150, 0), sample(1, .began, 300, 150, 0)])
        rig.send([sample(0, .moved, 180, 150, 0.02), sample(1, .moved, 220, 150, 0.02)])
        #expect(rig.context.viewport.scale == 0.5)
        rig.send([sample(0, .ended, 180, 150, 0.1), sample(1, .ended, 220, 150, 0.1)])
        #expect(rig.context.viewport.mode == .fit)
    }

    @Test func aPanStartedWithOneFingerBecomesAPinchWhenASecondLands() {
        var rig = Rig(TouchInterpreter(), zoomedContext())
        rig.down(0, 100, 150, at: 0)
        rig.move(0, 130, 150, at: 0.02)          // panning
        rig.down(1, 230, 150, at: 0.04)
        rig.send([sample(0, .moved, 110, 150, 0.06), sample(1, .moved, 250, 150, 0.06)])
        #expect(approximately(rig.context.viewport.scale, 1.4))
        rig.send([sample(0, .ended, 110, 150, 0.1), sample(1, .ended, 250, 150, 0.1)])
        #expect(rig.log.inputs.isEmpty)
    }

    @Test func trackpadSurfaceZoomsAroundTheCursor() {
        var rig = Rig(TrackpadInterpreter(zoomAnchor: .pointer))
        rig.context.pointer = PixelPoint(x: 600, y: 200)
        let cursor = rig.context.viewport.viewPoint(for: rig.context.pointer)
        rig.send([sample(0, .began, 50, 50, 0), sample(1, .began, 150, 50, 0)])
        rig.send([sample(0, .moved, 0, 50, 0.02), sample(1, .moved, 200, 50, 0.02)])
        #expect(approximately(rig.context.viewport.scale, 1))
        let after = rig.context.viewport.viewPoint(for: rig.context.pointer)
        #expect(approximately(after.x, cursor.x) && approximately(after.y, cursor.y))
        // Sliding both fingers does not pan: the surface is not the display.
        let origin = rig.context.viewport.origin
        rig.send([sample(0, .moved, 0, 90, 0.04), sample(1, .moved, 200, 90, 0.04)])
        #expect(rig.context.viewport.origin == origin)
        rig.send([sample(0, .ended, 0, 90, 0.1), sample(1, .ended, 200, 90, 0.1)])
        #expect(rig.log.inputs.isEmpty)
    }

    @Test func trackpadOnTheDisplayZoomsAroundTheFingers() {
        var rig = Rig(TrackpadInterpreter(zoomAnchor: .touchCentroid))
        let under = rig.context.viewport.remotePoint(for: ViewPoint(x: 100, y: 50))
        rig.send([sample(0, .began, 50, 50, 0), sample(1, .began, 150, 50, 0)])
        rig.send([sample(0, .moved, 0, 50, 0.02), sample(1, .moved, 200, 50, 0.02)])
        let after = rig.context.viewport.remotePoint(for: ViewPoint(x: 100, y: 50))
        #expect(approximately(after.x, under.x) && approximately(after.y, under.y))
        rig.cancel()
    }
}

@Suite struct ScrollMomentumTests {
    /// Scrolls down at 1250 points per second for five frames and lifts.
    private func flick<I: GestureInterpreter>(_ rig: inout Rig<I>, liftDelay: Double = 0.016) -> Double {
        twoDown(&rig, at: 0)
        var time = 0.0
        for step in 1...5 {
            time = Double(step) * 0.016
            twoMove(&rig, dy: Double(step) * 20, at: time)
        }
        twoUp(&rig, dy: 100, at: time + liftDelay)
        return time + liftDelay
    }

    @Test func aFlickCoastsAndDecays() throws {
        var rig = Rig(TouchInterpreter())
        let lift = flick(&rig)
        let tail = rig.log.scrolls.suffix(2)
        #expect(tail.map(\.phase) == [.ended, .none])
        #expect(tail.last?.momentumPhase == .began)
        #expect(!rig.interpreter.isIdle)
        let deadline = try #require(rig.interpreter.nextDeadline)
        #expect(approximately(deadline, lift + 1.0 / 60.0))

        let before = rig.log.scrolls.count
        rig.runTimers(until: 30)
        let coast = Array(rig.log.scrolls[before...])
        #expect(coast.count > 10)
        #expect(coast.allSatisfy { $0.phase == .none && $0.position == PixelPoint(x: 240, y: 200) })
        #expect(coast.dropLast().allSatisfy { $0.momentumPhase == .changed })
        #expect(coast.last?.momentumPhase == .ended)
        // Same direction as the fingers were going, shrinking every tick.
        let steps = coast.dropLast().map(\.deltaY)
        #expect(steps.allSatisfy { $0 > 0 })
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 > $1 })
        #expect(steps.allSatisfy { $0 < 50 })
        // 1250 pt/s decaying at 3/s coasts roughly 400 points: 800 remote pixels at this zoom.
        let total = steps.reduce(0, +)
        #expect(total > 600 && total < 900)
        #expect(rig.interpreter.isIdle)
        #expect(rig.interpreter.nextDeadline == nil)
    }

    @Test func aNewTouchStopsTheCoast() {
        var rig = Rig(TouchInterpreter())
        let lift = flick(&rig)
        rig.advance(to: lift + 0.05)
        let effects = rig.down(0, 200, 200, at: lift + 0.1)
        #expect(effects.scrolls.map(\.momentumPhase) == [.cancelled])
        #expect(rig.interpreter.nextDeadline == lift + 0.1 + 0.45)   // only the new finger's long-press
        #expect(rig.advance(to: lift + 0.2).isEmpty)
        rig.up(0, 200, 200, at: lift + 0.25)
        let momentum = rig.log.scrolls.map(\.momentumPhase).filter { $0 != .none }
        #expect(momentum.first == .began && momentum.last == .cancelled)
        #expect(momentum.filter { $0 == .began }.count == 1)
    }

    @Test func cancelStopsTheCoast() {
        var rig = Rig(TouchInterpreter())
        _ = flick(&rig)
        #expect(rig.cancel().scrolls.map(\.momentumPhase) == [.cancelled])
        #expect(rig.interpreter.isIdle)
    }

    @Test func noCoastWhenDisabledSlowOrPaused() {
        var configuration = GestureConfiguration()
        configuration.momentum = false
        var disabled = Rig(TouchInterpreter(configuration: configuration))
        _ = flick(&disabled)
        #expect(disabled.interpreter.isIdle)
        #expect(disabled.log.scrolls.last?.phase == .ended)

        var paused = Rig(TouchInterpreter())
        _ = flick(&paused, liftDelay: 0.4)   // the fingers rested before lifting
        #expect(paused.interpreter.isIdle)

        var slow = Rig(TouchInterpreter())
        twoDown(&slow, at: 0)
        for step in 1...5 {
            twoMove(&slow, dy: Double(step) * 3, at: Double(step) * 0.05)   // 60 pt/s
        }
        twoUp(&slow, dy: 15, at: 0.26)
        #expect(slow.interpreter.isIdle)
        #expect(slow.log.scrolls.allSatisfy { $0.momentumPhase == .none })
    }

    @Test func coastingWorksInTrackpadModeToo() {
        var rig = Rig(TrackpadInterpreter(zoomAnchor: .pointer))
        _ = flick(&rig)
        rig.runTimers(until: 30)
        #expect(rig.log.scrolls.last?.momentumPhase == .ended)
        #expect(rig.log.scrolls.allSatisfy { $0.position == PixelPoint(x: 400, y: 300) })
        #expect(rig.log.pointers.isEmpty)
    }
}
