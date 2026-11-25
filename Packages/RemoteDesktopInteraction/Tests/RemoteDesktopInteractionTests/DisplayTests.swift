// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import RemoteDesktopInteraction
import Testing

/// What the simulated back end reports: one minimum for both scales.
private let simulatedLimits = DisplayConfigurationLimits(
    maximumVirtualDisplays: 2,
    minimumPointSize: PixelSize(width: 800, height: 600),
    maximumPixelSize: PixelSize(width: 3840, height: 2160),
    canSelectPhysicalDisplays: false
)

/// What a real Mac was measured to accept: anything from 200×200 points at scale 1, 800×600 points
/// or more at scale 2, and no more than 3840×2160 pixels on a side at either scale.
private let macLimits = DisplayConfigurationLimits(
    maximumVirtualDisplays: 2,
    minimumPointSize: PixelSize(width: 200, height: 200),
    minimumHiDPIPointSize: PixelSize(width: 800, height: 600),
    maximumPixelSize: PixelSize(width: 3840, height: 2160),
    canSelectPhysicalDisplays: false
)

private let roomyLimits = DisplayConfigurationLimits(
    maximumVirtualDisplays: 2,
    minimumPointSize: PixelSize(width: 800, height: 600),
    maximumPixelSize: PixelSize(width: 8192, height: 8192),
    canSelectPhysicalDisplays: false
)

private func size(_ width: Int, _ height: Int) -> PixelSize {
    PixelSize(width: width, height: height)
}

private func propose(_ width: Double, _ height: Double, at deviceScale: Double, _ limits: DisplayConfigurationLimits = macLimits, retina: Bool = true) throws -> VirtualDisplaySizer.Proposal {
    try #require(VirtualDisplaySizer.proposal(forPane: ViewSize(width: width, height: height), deviceScale: deviceScale, limits: limits, prefersRetina: retina))
}

@Suite struct VirtualDisplaySizerTests {
    @Test func aPhoneHeldUprightGetsAPortraitDisplayOfTwiceItsPoints() throws {
        // Too narrow for a HiDPI display, so: the same pixels at scale 1, shown at half size.
        let proposal = try propose(402, 874, at: 3)
        #expect(proposal.request.pointSize == size(804, 1748))
        #expect(proposal.request.scale == 1)
        #expect(proposal.residualZoom == 0.5)
    }

    @Test func aPhoneOnItsSideGetsALandscapeDisplay() throws {
        // Retina: the phone's own pixels (2622 × 1206) at 2x, as on a Mac's built-in display.
        let retina = try propose(874, 402, at: 3)
        #expect(retina.request.pointSize == size(1312, 604))
        #expect(retina.request.scale == 2)
        #expect(approximately(retina.residualZoom, 2.0 / 3.0, tolerance: 0.01))
        // Without: the device's own pixels at 1x.
        let plain = try propose(874, 402, at: 3, retina: false)
        #expect(plain.request.pointSize == size(1748, 804))
        #expect(plain.request.scale == 1)
        #expect(plain.residualZoom == 0.5)
    }

    /// Upright, a phone's pane would need a Retina display taller than the Mac makes (2160
    /// pixels): there is none of its shape, so it gets the 1x one.
    @Test func noRetinaDisplayFitsAPhoneHeldUpright() throws {
        let proposal = try propose(402, 874, at: 3, retina: true)
        #expect(proposal.request.scale == 1)
        #expect(proposal.request.pointSize == size(804, 1748))
    }

    /// An iPhone Duo open in landscape: its Retina display has the screen's pixels, so Actual Size
    /// and Scale to Fit are the same.
    @Test func aDuoOpenOnItsSideGetsItsOwnPixelsAtRetina() throws {
        let proposal = try propose(951, 669, at: 3)
        #expect(proposal.request.scale == 2)
        #expect(proposal.request.pointSize == size(1426, 1004))
        #expect(approximately(proposal.residualZoom, 2.0 / 3.0, tolerance: 0.01))
    }

    @Test func withoutRetinaABigPaneGetsItsOwnPixelsAt1x() throws {
        let proposal = try propose(1376, 1032, at: 2, retina: false)
        #expect(proposal.request.scale == 1)
        #expect(proposal.request.pointSize.height <= 2160)
    }

    @Test func duoDisplays() throws {
        let outer = try propose(382, 562, at: 3)
        #expect(outer.request.pointSize == size(764, 1124))
        #expect(outer.request.scale == 1 && outer.residualZoom == 0.5)
        let inner = try propose(669, 951, at: 3)
        #expect(inner.request.pointSize == size(1338, 1902))
        #expect(inner.request.scale == 1 && inner.residualZoom == 0.5)
    }

    @Test func aPaneBigEnoughForHiDPIIsUsedAsItIs() throws {
        let landscape = try propose(1376, 1032, at: 2)
        #expect(landscape.request.pointSize == size(1376, 1032))
        #expect(landscape.request.scale == 2)
        #expect(landscape.residualZoom == 1)
        // The roomy limits have no pixel cap in the way of a tall display.
        let portrait = try propose(1032, 1376, at: 2, roomyLimits)
        #expect(portrait.request.pointSize == size(1032, 1376))
        #expect(portrait.request.scale == 2 && portrait.residualZoom == 1)
    }

    @Test func aTallHiDPIPaneShrinksUniformlyUnderThePixelCap() throws {
        // 1032×1376 at scale 2 would be 2752 pixels tall; the cap is 2160.
        let proposal = try propose(1032, 1376, at: 2)
        #expect(proposal.request.scale == 2)
        #expect(proposal.request.pointSize == size(810, 1080))
        #expect(approximately(proposal.residualZoom, 1376.0 / 1080.0, tolerance: 0.01))
        #expect(approximately(810.0 / 1080.0, 1032.0 / 1376.0, tolerance: 0.01))
    }

    @Test func aPlainMonitorGetsScaleOne() throws {
        let proposal = try propose(1920, 1080, at: 1)
        #expect(proposal.request.pointSize == size(1920, 1080))
        #expect(proposal.request.scale == 1 && proposal.residualZoom == 1)
    }

    @Test func aHugePaneIsHeldToThePixelCap() throws {
        let proposal = try propose(3840, 2160, at: 2)
        #expect(proposal.request.scale == 2)
        #expect(proposal.request.pointSize == size(1920, 1080))
        #expect(proposal.residualZoom == 2)
    }

    @Test func aTinyPaneGrowsToTheMinimumKeepingItsShape() throws {
        let retina = try propose(80, 60, at: 2)
        #expect(retina.request.scale == 2)
        #expect(retina.request.pointSize == size(800, 600))
        let proposal = try propose(80, 60, at: 2, retina: false)
        #expect(proposal.request.scale == 1)
        #expect(proposal.request.pointSize == size(266, 200))
        #expect(approximately(proposal.residualZoom, 0.3, tolerance: 0.01))
    }

    @Test func oneMinimumForBothScalesStillFillsThePane() throws {
        // The simulated back end: 800×600 at either scale.
        let phone = try propose(402, 874, at: 3, simulatedLimits)
        #expect(phone.request.pointSize == size(804, 1748) && phone.request.scale == 1)
        let outer = try propose(382, 562, at: 3, simulatedLimits)
        #expect(outer.request.scale == 1)
        #expect(outer.request.pointSize.width == 800)
        #expect(abs(outer.request.pointSize.height - 1177) <= 1)
        #expect(approximately(outer.residualZoom, 382.0 / 800.0, tolerance: 0.01))
    }

    @Test func oddSizesBecomeEven() throws {
        let proposal = try propose(1033, 1001, at: 2, roomyLimits)
        #expect(proposal.request.pointSize.width.isMultiple(of: 2) && proposal.request.pointSize.height.isMultiple(of: 2))
        #expect(abs(proposal.request.pointSize.width - 1033) <= 1 && abs(proposal.request.pointSize.height - 1001) <= 1)
    }

    @Test func nothingToProposeForEmptyPanesOrFixedDisplays() {
        #expect(VirtualDisplaySizer.proposal(forPane: .zero, deviceScale: 2, limits: simulatedLimits) == nil)
        #expect(VirtualDisplaySizer.proposal(forPane: ViewSize(width: 400, height: 0), deviceScale: 2, limits: simulatedLimits) == nil)
        #expect(VirtualDisplaySizer.proposal(forPane: ViewSize(width: .nan, height: 300), deviceScale: 2, limits: simulatedLimits) == nil)
        var fixed = simulatedLimits
        fixed.maximumVirtualDisplays = 0
        #expect(VirtualDisplaySizer.proposal(forPane: ViewSize(width: 800, height: 600), deviceScale: 2, limits: fixed) == nil)
    }

    @Test func everyProposalRespectsTheLimits() {
        var generator = SplitMix64(seed: 11)
        for _ in 0..<2000 {
            let pane = ViewSize(width: Double.random(in: 1...3000, using: &generator), height: Double.random(in: 1...3000, using: &generator))
            let deviceScale = [1.0, 2.0, 3.0].randomElement(using: &generator)!
            for limits in [simulatedLimits, macLimits, roomyLimits] {
                guard let proposal = VirtualDisplaySizer.proposal(forPane: pane, deviceScale: deviceScale, limits: limits) else {
                    Issue.record("no proposal for \(pane)")
                    continue
                }
                let request = proposal.request
                let minimum = request.scale == 2 ? limits.minimumHiDPIPointSize : limits.minimumPointSize
                #expect(request.pointSize.width >= minimum.width && request.pointSize.height >= minimum.height)
                #expect(request.pointSize.width.isMultiple(of: 2) && request.pointSize.height.isMultiple(of: 2))
                #expect(request.scale == 1 || request.scale == 2)
                #expect(request.pointSize.width * request.scale <= limits.maximumPixelSize.width)
                #expect(request.pointSize.height * request.scale <= limits.maximumPixelSize.height)
                #expect(proposal.residualZoom > 0 && proposal.residualZoom.isFinite)
                // Shown at the residual zoom, the display is inside the pane (give or take rounding).
                #expect(Double(request.pointSize.width) * proposal.residualZoom <= pane.width + 2)
                #expect(Double(request.pointSize.height) * proposal.residualZoom <= pane.height + 2)
            }
        }
    }

    @Test func aStormOfResizesYieldsOneProposal() throws {
        var sizer = VirtualDisplaySizer(limits: roomyLimits)
        #expect(sizer.nextDeadline == nil)
        #expect(sizer.poll(at: 100) == nil)

        // The hinge opens: the pane grows over 300 ms.
        for step in 0...30 {
            sizer.paneChanged(to: ViewSize(width: 466 + Double(step) * 6.77, height: 678 + Double(step) * 9.1), deviceScale: 3, at: Double(step) * 0.01)
            #expect(sizer.poll(at: Double(step) * 0.01) == nil)
        }
        let deadline = try #require(sizer.nextDeadline)
        #expect(approximately(deadline, 0.30 + 0.35))
        #expect(sizer.poll(at: 0.6) == nil)

        let polled = sizer.poll(at: deadline)
        let proposal = try #require(polled)
        #expect(proposal == VirtualDisplaySizer.proposal(forPane: ViewSize(width: 669.1, height: 951), deviceScale: 3, limits: roomyLimits))
        #expect(sizer.nextDeadline == nil)
        #expect(sizer.poll(at: 10) == nil)
        #expect(sizer.lastProposal == proposal)
    }

    @Test func unchangedPaneDoesNotRestartTheTimerOrRepeatTheProposal() throws {
        var sizer = VirtualDisplaySizer(limits: roomyLimits, debounceInterval: 0.5)
        let pane = ViewSize(width: 1032, height: 1376)
        sizer.paneChanged(to: pane, deviceScale: 2, at: 0)
        sizer.paneChanged(to: pane, deviceScale: 2, at: 0.4)     // layout passes repeat the same size
        #expect(sizer.nextDeadline == 0.5)
        #expect(sizer.poll(at: 0.5) != nil)

        // Bouncing away and back within the debounce window asks for nothing new.
        sizer.paneChanged(to: ViewSize(width: 800, height: 1376), deviceScale: 2, at: 1)
        sizer.paneChanged(to: pane, deviceScale: 2, at: 1.2)
        #expect(sizer.nextDeadline == 1.7)
        #expect(sizer.poll(at: 1.7) == nil)
        #expect(sizer.nextDeadline == nil)

        // A sub-pixel wobble that rounds to the same request is not news either.
        sizer.paneChanged(to: ViewSize(width: 1032.3, height: 1376), deviceScale: 2, at: 2)
        #expect(sizer.poll(at: 3) == nil)
    }

    @Test func markAppliedSuppressesWhatTheSessionAlreadyHas() throws {
        var sizer = VirtualDisplaySizer(limits: simulatedLimits)
        sizer.prefersRetina = false
        let pane = ViewSize(width: 402, height: 874)
        let initial = try #require(VirtualDisplaySizer.proposal(forPane: pane, deviceScale: 3, limits: simulatedLimits, prefersRetina: false))
        sizer.markApplied(initial)
        sizer.paneChanged(to: pane, deviceScale: 3, at: 0)
        #expect(sizer.poll(at: 1) == nil)

        sizer.paneChanged(to: ViewSize(width: 874, height: 402), deviceScale: 3, at: 2)
        #expect(sizer.poll(at: 2.2) == nil)
        #expect(sizer.poll(at: 2.35)?.request.pointSize == size(1748, 804))

        sizer.reset()
        #expect(sizer.lastProposal == nil && sizer.nextDeadline == nil)
        sizer.paneChanged(to: ViewSize(width: 874, height: 402), deviceScale: 3, at: 3)
        #expect(sizer.poll(at: 4) != nil)
    }
}

@Suite struct DesktopLayoutHelperTests {
    private let builtIn = RemoteDisplay(
        id: DisplayID(1), name: "Built-in Display", kind: .physical,
        frameInDesktop: PixelRect(x: 0, y: 0, width: 2560, height: 1600), scale: 2
    )
    private let external = RemoteDisplay(
        id: DisplayID(2), name: "External Display", kind: .physical,
        frameInDesktop: PixelRect(x: 2560, y: 0, width: 1920, height: 1080), scale: 1
    )
    private var layout: DesktopLayout { DesktopLayout(generation: 3, displays: [builtIn, external]) }

    @Test func pointSizeDividesByTheBackingScale() {
        #expect(builtIn.pointSize == ViewSize(width: 1280, height: 800))
        #expect(external.pointSize == ViewSize(width: 1920, height: 1080))
        var broken = external
        broken.scale = 0
        #expect(broken.pointSize == ViewSize(width: 1920, height: 1080))
    }

    /// With the main display right of the other, a Mac's framebuffer starts at the other one; the
    /// first display listed is the main one, and it is shown first.
    @Test func primaryDisplayIsTheFirstListed() {
        #expect(layout.primaryDisplay?.id == DisplayID(1))
        var left = external
        left.frameInDesktop.x = 0
        var right = builtIn
        right.frameInDesktop.x = 1920
        #expect(DesktopLayout(generation: 1, displays: [right, left]).primaryDisplay?.id == DisplayID(1))
        #expect(DesktopLayout.empty.primaryDisplay == nil)
    }

    @Test func cyclingWrapsAround() {
        #expect(layout.display(after: DisplayID(1))?.id == DisplayID(2))
        #expect(layout.display(after: DisplayID(2))?.id == DisplayID(1))
        #expect(layout.display(before: DisplayID(1))?.id == DisplayID(2))
        #expect(layout.display(before: DisplayID(2))?.id == DisplayID(1))
        #expect(layout.display(after: nil)?.id == DisplayID(1))
        #expect(layout.display(after: DisplayID(77))?.id == DisplayID(1))
        #expect(DesktopLayout.empty.display(after: DisplayID(1)) == nil)
        let single = DesktopLayout(generation: 1, displays: [builtIn])
        #expect(single.display(after: DisplayID(1))?.id == DisplayID(1))
    }

    @Test func convertsBetweenDesktopAndDisplayPixels() {
        #expect(layout.desktopPoint(for: PixelPoint(x: 10, y: 20), in: DisplayID(2)) == PixelPoint(x: 2570, y: 20))
        #expect(layout.displayPoint(for: PixelPoint(x: 2570, y: 20), in: DisplayID(2)) == PixelPoint(x: 10, y: 20))
        #expect(layout.displayPoint(for: PixelPoint(x: 10, y: 20), in: DisplayID(2)) == PixelPoint(x: -2550, y: 20))
        #expect(layout.desktopPoint(for: .zero, in: DisplayID(9)) == nil)
        #expect(layout.displayPoint(for: .zero, in: DisplayID(9)) == nil)
        #expect(external.desktopPoint(for: external.displayPoint(for: PixelPoint(x: 3000.5, y: 7))) == PixelPoint(x: 3000.5, y: 7))
    }

    @Test func clampingStaysOnValidPixels() {
        #expect(external.clamping(PixelPoint(x: -5, y: 2000)) == PixelPoint(x: 0, y: 1079))
        #expect(external.clamping(PixelPoint(x: 1920, y: 540.5)) == PixelPoint(x: 1919, y: 540.5))
        #expect(external.clamping(PixelPoint(x: 100, y: 100)) == PixelPoint(x: 100, y: 100))
    }

    @Test func nearestDisplayCoversTheGaps() throws {
        #expect(layout.nearestDisplay(to: PixelPoint(x: 100, y: 100))?.id == DisplayID(1))
        #expect(layout.nearestDisplay(to: PixelPoint(x: 3000, y: 500))?.id == DisplayID(2))
        // Below the shorter external display there is no screen; the external one is still closest.
        #expect(layout.nearestDisplay(to: PixelPoint(x: 4000, y: 1500))?.id == DisplayID(2))
        #expect(layout.nearestDisplay(to: PixelPoint(x: 2600, y: 1590))?.id == DisplayID(1))
        #expect(layout.nearestDisplay(to: PixelPoint(x: -50, y: -50))?.id == DisplayID(1))
        #expect(DesktopLayout.empty.nearestDisplay(to: .zero) == nil)

        let located = try #require(layout.locate(PixelPoint(x: 4000, y: 1500)))
        #expect(located.display.id == DisplayID(2))
        #expect(located.position == PixelPoint(x: 1440, y: 1079))
        let inside = try #require(layout.locate(PixelPoint(x: 2570, y: 20)))
        #expect(inside.display.id == DisplayID(2) && inside.position == PixelPoint(x: 10, y: 20))
        #expect(DesktopLayout.empty.locate(.zero) == nil)
    }

    @Test func normalizedFramesTileTheBoundingBox() {
        let frames = layout.normalizedFrames()
        #expect(frames.map(\.id) == [DisplayID(1), DisplayID(2)])
        #expect(approximately(frames[0].frame.x, 0) && approximately(frames[0].frame.width, 2560.0 / 4480.0))
        #expect(frames[0].frame.height == 1)
        #expect(approximately(frames[1].frame.x, 2560.0 / 4480.0) && approximately(frames[1].frame.maxX, 1))
        #expect(approximately(frames[1].frame.height, 1080.0 / 1600.0))
        #expect(approximately(layout.aspectRatio, 4480.0 / 1600.0))

        // Negative origins are normalised away.
        var left = external
        left.frameInDesktop.x = -1920
        let shifted = DesktopLayout(generation: 1, displays: [left, builtIn]).normalizedFrames()
        #expect(shifted[0].frame.x == 0)
        #expect(approximately(shifted[1].frame.x, 1920.0 / 4480.0))

        #expect(DesktopLayout.empty.normalizedFrames().isEmpty)
        #expect(DesktopLayout.empty.aspectRatio == 1)
    }

    @Test func pointerTargetComesFromTheCurrentLayout() {
        let target = PointerTarget(display: external, layout: layout)
        #expect(target == PointerTarget(display: DisplayID(2), pixelSize: PixelSize(width: 1920, height: 1080), layoutGeneration: 3))
        #expect(PointerTarget(display: DisplayID(2), layout: layout) == target)
        // A stale copy of the display is refreshed from the layout.
        var stale = external
        stale.frameInDesktop.width = 100
        #expect(PointerTarget(display: stale, layout: layout)?.pixelSize.width == 1920)
        #expect(PointerTarget(display: nil as RemoteDisplay?, layout: layout) == nil)
        #expect(PointerTarget(display: nil as DisplayID?, layout: layout) == nil)
        #expect(PointerTarget(display: DisplayID(9), layout: layout) == nil)
        #expect(PointerTarget(display: external, layout: .empty) == nil)
        #expect(target?.clamp(PixelPoint(x: 5000, y: -1)) == PixelPoint(x: 1919, y: 0))
    }
}
