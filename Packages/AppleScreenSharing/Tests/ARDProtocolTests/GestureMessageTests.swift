// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
import ARDTestSupport
import Foundation
import Testing

/// Trackpad gestures and scroll phases, byte for byte as Screen Sharing.app builds them
/// (`RFBPostGestureEvent*` and `RFBPostScrollWheelEvent` in ScreenSharing.framework, macOS 27.0.1).
/// Every message is an event message (0x17): type, padding, u16 length of what follows, u16
/// version, u16 kind, then the kind's fields, all big-endian.
@Suite struct GestureMessageTests {
    private let x: UInt16 = 640
    private let y: UInt16 = 480

    private func hex(_ parts: String...) -> String { parts.joined() }

    @Test func gestureSeriesBeginAndEnd() {
        #expect(ClientMessage.gestureBegin(seriesType: 8, x: x, y: y).hex == hex("1700000c", "0001", "0001", "00000008", "028001e0"))
        #expect(ClientMessage.gestureEnd(seriesType: 8, x: x, y: y).hex == hex("1700000c", "0001", "0002", "00000008", "028001e0"))
    }

    @Test func magnifyCarriesADoubleThenThePositionThenPhaseAndMask() {
        let message = ClientMessage.gestureMagnify(0.25, phase: GesturePhase.changed.rawValue, x: x, y: y)
        #expect(message.count == 36)
        #expect(message.hex == hex("17000020", "0002", "0003", "3fd0000000000000", "028001e0", "0000000000000002", "0000000000000004"))
    }

    @Test func rotateIsLaidOutLikeMagnify() {
        let message = ClientMessage.gestureRotate(degrees: -90, phase: GesturePhase.began.rawValue, x: x, y: y)
        #expect(message.hex == hex("17000020", "0002", "0005", "c056800000000000", "028001e0", "0000000000000001", "0000000000000004"))
    }

    @Test func smartMagnifyAndLookUpAreJustAPosition() {
        #expect(ClientMessage.gestureSmartMagnify(x: x, y: y).hex == hex("17000008", "0001", "0004", "028001e0"))
        #expect(ClientMessage.gestureLookUp(x: x, y: y).hex == hex("17000008", "0001", "0007", "028001e0"))
    }

    @Test func gestureScrollHasFloatDeltasThenThreeWords() {
        let message = ClientMessage.gestureScroll(deltaX: 1.5, deltaY: -2, naturalScrolling: true, phase: 2, mask: 0, x: x, y: y)
        #expect(message.count == 36)
        #expect(message.hex == hex("17000020", "0001", "0008", "3fc00000", "c0000000", "00000000", "00000001", "00000002", "00000000", "028001e0"))
    }

    @Test func pageSwipeHasMotionMaskSixFloatsFlagsAndFlavor() {
        let message = ClientMessage.gesturePageSwipe(PageSwipe(motion: 2, swipeMask: 4, progress: 0.5, velocityX: -1), x: x, y: y)
        #expect(message.count == 52)
        #expect(message.hex == hex("17000030", "0001", "0006", "00000002", "00000004", "3f000000", "00000000", "00000000", "bf800000", "00000000", "00000000", "00000000", "00000000", "028001e0"))
    }

    @Test func scrollCarriesItsPhasesAndFlags() {
        let began = ClientMessage.scroll(deltaX: 0, deltaY: -30, x: x, y: y, phase: ScrollPhase.began.rawValue, momentumPhase: 0, flags: .continuous)
        #expect(began.hex == hex("17000036", "0001", "000b", "0000", "fffd", "0000", "00000000", "fffd0000", "00000000", "00000000", "ffffffe2", "00000000", "00000001", "00000000", "00000000", "00000002", "028001e0"))
        // Momentum after the fingers lift has no scroll phase of its own.
        let coasting = ClientMessage.scroll(deltaX: 5, deltaY: 0, x: x, y: y, phase: 0, momentumPhase: MomentumPhase.continue.rawValue)
        #expect(coasting.hex.dropFirst(76).prefix(32) == hex("00000000", "00000002", "00000000", "00000002"))
        // A mouse wheel's notches are not continuous: the Mac then scrolls by lines.
        let wheel = ClientMessage.scroll(deltaX: 0, deltaY: 10, x: x, y: y, flags: [])
        #expect(wheel.hex.dropFirst(100).prefix(8) == hex("00000000"))
    }

    @Test func flagBitsAreTheOnesTheMacReads() {
        #expect(ScrollFlags.instantMouser.rawValue == 1)
        #expect(ScrollFlags.continuous.rawValue == 2)
        #expect(ScrollFlags.directionInvertedFromDevice.rawValue == 4)
        #expect(ScrollPhase.mayBegin.rawValue == 128)
        #expect(MomentumPhase.end.rawValue == 3)
    }

    @Test func nonFiniteValuesNeverReachTheWire() {
        for value in [Double.nan, .infinity, -.infinity] {
            let magnify = ClientMessage.gestureMagnify(value, phase: 2, x: x, y: y)
            #expect(magnify.count == 36)
            #expect(magnify.hex.dropFirst(16).prefix(16) == hex("0000000000000000"))
            #expect(ClientMessage.gestureRotate(degrees: value, phase: 2, x: x, y: y).count == 36)
            let swipe = ClientMessage.gesturePageSwipe(PageSwipe(motion: 2, swipeMask: 4, progress: Float(value)), x: x, y: y)
            #expect(swipe.count == 52)
            #expect(swipe.hex.dropFirst(32).prefix(8) == hex("00000000"))
        }
    }

    @Test func everyKindHasTheNumberTheMacDispatchesOn() {
        #expect(EventMessageKind.allCases.map(\.rawValue) == [1, 2, 3, 4, 5, 6, 7, 8, 11])
    }
}
