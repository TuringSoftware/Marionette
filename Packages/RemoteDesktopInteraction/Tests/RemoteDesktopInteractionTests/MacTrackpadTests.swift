// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import RemoteDesktopInteraction
import Testing

/// A trackpad surface of its own behaves like a Mac's: gestures go to the remote app.
private func macTrackpad() -> TrackpadInterpreter {
    var configuration = GestureConfiguration()
    configuration.forwardsGestures = true
    configuration.pointerAcceleration = false
    return TrackpadInterpreter(configuration: configuration, zoomAnchor: .pointer)
}

private extension [InteractionEffect] {
    var gestures: [GestureEvent] {
        inputs.compactMap { if case .gesture(let event) = $0 { event } else { nil } }
    }

    var keys: [KeyEvent] {
        inputs.compactMap { if case .key(let event) = $0 { event } else { nil } }
    }
}

@Suite struct MacTrackpadTests {
    @Test func aPinchIsAMagnifyGestureNotAZoomOfTheView() {
        var rig = Rig(macTrackpad())
        let before = rig.context.viewport
        rig.down(0, 100, 150, at: 0)
        rig.down(1, 200, 150, at: 0.01)
        // Fingers spread from 100 to 140 points apart, then to 154.
        rig.send([sample(0, .moved, 80, 150, 0.05), sample(1, .moved, 220, 150, 0.05)])
        rig.send([sample(0, .moved, 73, 150, 0.08), sample(1, .moved, 227, 150, 0.08)])
        rig.up(0, 73, 150, at: 0.2)
        rig.up(1, 227, 150, at: 0.21)

        let gestures = rig.log.gestures
        #expect(gestures.map(\.phase) == [.began, .changed, .ended])
        guard case .magnify(let first) = gestures[0].kind, case .magnify(let second) = gestures[1].kind else {
            Issue.record("expected magnify, got \(gestures)")
            return
        }
        #expect(approximately(first, 0.4))
        #expect(approximately(second, 0.1))
        #expect(gestures.allSatisfy { $0.position == rig.context.pointer && $0.layoutGeneration == 7 })
        #expect(rig.context.viewport == before)
        #expect(!rig.log.changesViewport)
        #expect(rig.interpreter.isIdle)
    }

    @Test func turningTwoFingersIsARotateGesture() {
        var rig = Rig(macTrackpad())
        rig.down(0, 100, 150, at: 0)
        rig.down(1, 200, 150, at: 0.01)
        // The finger on the right moves up: anticlockwise on screen, so positive degrees on the Mac.
        rig.move(1, 199, 120, at: 0.05)
        rig.move(1, 197, 100, at: 0.08)
        rig.up(0, 100, 150, at: 0.2)
        rig.up(1, 197, 100, at: 0.21)

        let gestures = rig.log.gestures
        #expect(gestures.first?.phase == .began)
        #expect(gestures.last?.phase == .ended)
        let degrees = gestures.compactMap { if case .rotate(let d) = $0.kind { d } else { nil } }.reduce(0, +)
        #expect(degrees > 20 && degrees < 35)
        #expect(rig.log.scrolls.isEmpty)
    }

    @Test func aTwoFingerTapClicksSecondaryOnceItIsNotADoubleTap() {
        var rig = Rig(macTrackpad())
        rig.down(0, 100, 150, at: 0)
        rig.down(1, 140, 150, at: 0.01)
        rig.up(0, 100, 150, at: 0.08)
        // Held back: this could be the first half of a smart zoom.
        #expect(rig.up(1, 140, 150, at: 0.09).isEmpty)
        #expect(!rig.interpreter.isIdle)
        let deadline = try! #require(rig.interpreter.nextDeadline)
        #expect(approximately(deadline, 0.09 + GestureConfiguration().doubleTapInterval))
        let clicked = rig.advance(to: deadline)
        #expect(clicked.pointers.map(\.buttons) == [[], .secondary, []])
        #expect(rig.interpreter.isIdle)
    }

    @Test func aTwoFingerDoubleTapIsSmartZoomWithNoClick() {
        var rig = Rig(macTrackpad())
        rig.down(0, 100, 150, at: 0)
        rig.down(1, 140, 150, at: 0.01)
        rig.up(0, 100, 150, at: 0.08)
        rig.up(1, 140, 150, at: 0.09)
        rig.down(0, 101, 151, at: 0.2)
        rig.down(1, 141, 151, at: 0.21)
        rig.up(0, 101, 151, at: 0.28)
        let second = rig.up(1, 141, 151, at: 0.29)
        rig.runTimers(until: 2)

        #expect(second.gestures.map(\.kind) == [.smartMagnify])
        #expect(rig.log.pointers.allSatisfy { $0.buttons.isEmpty })
        #expect(rig.interpreter.isIdle)
    }

    @Test func aClickAfterATwoFingerTapComesAfterItsSecondaryClick() {
        var rig = Rig(macTrackpad())
        rig.down(0, 100, 150, at: 0)
        rig.down(1, 140, 150, at: 0.01)
        rig.up(0, 100, 150, at: 0.08)
        rig.up(1, 140, 150, at: 0.09)
        rig.down(0, 100, 150, at: 0.15)
        rig.up(0, 100, 150, at: 0.2)
        #expect(rig.log.pointers.map(\.buttons) == [[], .secondary, [], [], .primary, []])
    }

    @Test func aThreeFingerTapLooksUp() {
        var rig = Rig(macTrackpad())
        rig.down(0, 100, 150, at: 0)
        rig.down(1, 140, 150, at: 0.01)
        rig.down(2, 180, 150, at: 0.02)
        let lifted = rig.up(0, 100, 150, at: 0.1)
        rig.up(1, 140, 150, at: 0.11)
        rig.up(2, 180, 150, at: 0.12)
        rig.runTimers(until: 2)

        #expect(lifted.gestures.map(\.kind) == [.quickLook])
        #expect(rig.log.pointers.isEmpty)
        #expect(rig.interpreter.isIdle)
    }

    @Test(arguments: [
        (0.0, -60.0, KeyCode.upArrow),      // up: Mission Control
        (0.0, 60.0, KeyCode.downArrow),     // down: Application Windows
        (-60.0, 0.0, KeyCode.rightArrow),   // left: the space on the right
        (60.0, 0.0, KeyCode.leftArrow),     // right: the space on the left
    ])
    func threeFingerSwipesWorkTheSpaces(dx: Double, dy: Double, key: KeyCode) {
        var rig = Rig(macTrackpad())
        rig.down(0, 100, 150, at: 0)
        rig.down(1, 140, 150, at: 0.01)
        rig.down(2, 180, 150, at: 0.02)
        rig.send((0...2).map { sample($0, .moved, 100 + Double($0) * 40 + dx, 150 + dy, 0.1) })
        rig.send((0...2).map { sample($0, .ended, 100 + Double($0) * 40 + dx, 150 + dy, 0.2) })

        let keys = rig.log.keys
        #expect(keys.map(\.key) == [.leftControl, key, key, .leftControl])
        #expect(keys.map(\.phase) == [.down, .down, .up, .up])
        #expect(rig.log.gestures.isEmpty)
        #expect(rig.interpreter.isIdle)
    }

    @Test func twoFingersStillScrollWithPhases() {
        var rig = Rig(macTrackpad())
        rig.down(0, 100, 150, at: 0)
        rig.down(1, 140, 150, at: 0.01)
        rig.send([sample(0, .moved, 100, 170, 0.05), sample(1, .moved, 140, 170, 0.05)])
        rig.send([sample(0, .moved, 100, 190, 0.08), sample(1, .moved, 140, 190, 0.08)])
        rig.send([sample(0, .ended, 100, 190, 0.5), sample(1, .ended, 140, 190, 0.5)])

        #expect(rig.log.scrolls.map(\.phase) == [.began, .changed, .ended])
        #expect(rig.log.gestures.isEmpty)
    }

    @Test func theRemoteDisplaysOwnTrackpadStillZoomsTheView() {
        // Without forwarding (touches on the picture itself), a pinch zooms the local view.
        var rig = Rig(TrackpadInterpreter(zoomAnchor: .touchCentroid))
        rig.down(0, 100, 150, at: 0)
        rig.down(1, 200, 150, at: 0.01)
        rig.send([sample(0, .moved, 80, 150, 0.05), sample(1, .moved, 220, 150, 0.05)])
        #expect(rig.log.changesViewport)
        #expect(rig.log.gestures.isEmpty)
    }
}
