// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopInteraction
import Testing

private let content = PixelSize(width: 800, height: 600)

private func viewport(_ width: Double, _ height: Double, deviceScale: Double = 2) -> ViewportModel {
    ViewportModel(viewSize: ViewSize(width: width, height: height), contentSize: content, deviceScale: deviceScale)
}

private func isFinite(_ model: ViewportModel) -> Bool {
    let frame = model.contentFrame
    return model.scale.isFinite && model.scale > 0
        && model.origin.x.isFinite && model.origin.y.isFinite
        && frame.width.isFinite && frame.height.isFinite
        && model.fitScale.isFinite && model.fillScale.isFinite
        && model.minimumScale.isFinite && model.maximumScale.isFinite
}

@Suite struct ViewportModeTests {
    @Test func fitFillsTheLimitingAxisAndCentresTheOther() {
        let exact = viewport(400, 300)
        #expect(exact.mode == .fit)
        #expect(exact.scale == 0.5)
        #expect(exact.contentFrame == ViewRect(x: 0, y: 0, width: 400, height: 300))
        #expect(!exact.isPannable)

        let tall = viewport(400, 400)
        #expect(tall.scale == 0.5)
        #expect(tall.contentFrame == ViewRect(x: 0, y: 50, width: 400, height: 300))

        let wide = viewport(1000, 300)
        #expect(wide.scale == 0.5)
        #expect(wide.contentFrame == ViewRect(x: 300, y: 0, width: 400, height: 300))
    }

    @Test func fitLetterboxesInsideTheSafeArea() {
        var model = viewport(400, 800)
        model.safeAreaInsets = ViewInsets(top: 100, bottom: 50)
        #expect(model.scale == 0.5)
        // Safe area is y 100...750; the 300-point-tall desktop sits in its middle.
        #expect(model.contentFrame == ViewRect(x: 0, y: 275, width: 400, height: 300))
        #expect(model.availableRect == ViewRect(x: 0, y: 100, width: 400, height: 650))

        model.safeAreaInsets = ViewInsets(top: 100, left: 100, bottom: 50, right: 100)
        #expect(model.scale == 0.25)
        #expect(model.contentFrame.minX == 100)
        #expect(model.contentFrame.maxX == 300)
    }

    @Test func aZoomThatCoversTheWholeViewPansTheOverflow() {
        var model = viewport(400, 800)
        model.safeAreaInsets = ViewInsets(top: 60, bottom: 30)
        model.setScale(model.fillScale, around: ViewPoint(x: 200, y: 445))
        #expect(model.mode == .free)
        #expect(approximately(model.scale, 800.0 / 600.0))
        let frame = model.contentFrame
        #expect(frame.minX <= 0 && frame.maxX >= 400)
        #expect(approximately(frame.midX, 200))
        #expect(model.isPannable)

        // The left edge of the desktop can be brought into view, and no further.
        model.pan(by: ViewVector(dx: 10_000, dy: 0))
        #expect(approximately(model.contentFrame.minX, 0))
        model.pan(by: ViewVector(dx: -10_000, dy: 0))
        #expect(approximately(model.contentFrame.maxX, 400))
        // Top and bottom can be brought out from under the bars.
        model.pan(by: ViewVector(dx: 0, dy: 10_000))
        #expect(approximately(model.contentFrame.minY, 60))
        model.pan(by: ViewVector(dx: 0, dy: -10_000))
        #expect(approximately(model.contentFrame.maxY, 770))
        #expect(model.mode == .free)
    }

    @Test func actualSizeMapsOneRemotePixelToOneDevicePixel() {
        var model = viewport(400, 300, deviceScale: 3)
        model.setMode(.actualSize)
        #expect(model.mode == .actualSize)
        #expect(approximately(model.scale, 1.0 / 3.0))
        #expect(approximately(model.magnification, 1))
        // 800 px at 1/3 is 266.7 pt: smaller than the view, so centred.
        #expect(approximately(model.contentFrame.midX, 200))
        #expect(approximately(model.contentFrame.midY, 150))

        var dense = viewport(400, 300, deviceScale: 1)
        dense.setMode(.actualSize)
        #expect(dense.scale == 1)
        #expect(dense.isPannable)
        // Switching from fit keeps the middle of the desktop in the middle of the view.
        let centre = dense.remotePoint(for: ViewPoint(x: 200, y: 150))
        #expect(approximately(centre.x, 400) && approximately(centre.y, 300))
    }

    @Test func scaleLimits() {
        var model = viewport(400, 300, deviceScale: 2)
        #expect(model.actualSizeScale == 0.5)
        #expect(model.minimumScale == 0.5)
        #expect(model.maximumScale == 2)
        model.zoom(by: 0.01, around: ViewPoint(x: 200, y: 150))
        #expect(model.scale == 0.5)
        model.zoom(by: 1000, around: ViewPoint(x: 200, y: 150))
        #expect(model.scale == 2)

        // A small remote display on a big screen: fit magnifies it, 1:1 is the way to zoom out.
        let small = ViewportModel(
            viewSize: ViewSize(width: 1600, height: 1200),
            contentSize: PixelSize(width: 800, height: 600),
            deviceScale: 2
        )
        #expect(small.fitScale == 2)
        #expect(small.minimumScale == 0.5)
        #expect(small.maximumScale == 8)
    }

    @Test func changingInputsReappliesTheMode() {
        var model = viewport(400, 300)
        model.viewSize = ViewSize(width: 200, height: 300)
        #expect(model.scale == 0.25)
        #expect(model.contentFrame == ViewRect(x: 0, y: 75, width: 200, height: 150))

        model.contentSize = PixelSize(width: 400, height: 600)
        #expect(model.scale == 0.5)
        #expect(model.contentFrame == ViewRect(x: 0, y: 0, width: 200, height: 300))

        model.setMode(.actualSize)
        model.deviceScale = 4
        #expect(model.scale == 0.25)
    }
}

@Suite struct ViewportMappingTests {
    @Test func mapsBothWays() {
        let model = viewport(400, 400)
        #expect(model.remotePoint(for: ViewPoint(x: 0, y: 50)) == PixelPoint(x: 0, y: 0))
        #expect(model.remotePoint(for: ViewPoint(x: 100, y: 150)) == PixelPoint(x: 200, y: 200))
        #expect(model.viewPoint(for: PixelPoint(x: 800, y: 600)) == ViewPoint(x: 400, y: 350))
    }

    @Test func clampsToValidPixels() {
        let model = viewport(400, 400)
        // In the letterbox above the desktop, and beyond its right edge.
        #expect(model.remotePoint(for: ViewPoint(x: -20, y: 10)) == PixelPoint(x: 0, y: 0))
        #expect(model.remotePoint(for: ViewPoint(x: 900, y: 399)) == PixelPoint(x: 799, y: 599))
        let raw = model.remotePoint(for: ViewPoint(x: -20, y: 10), clamped: false)
        #expect(raw == PixelPoint(x: -40, y: -80))
    }

    @Test func roundTripsInEveryMode() {
        var generator = SplitMix64(seed: 42)
        for mode in ViewportModel.ZoomMode.allCases {
            var model = viewport(393, 852, deviceScale: 3)
            model.safeAreaInsets = ViewInsets(top: 59, bottom: 34)
            model.setMode(mode)
            if mode == .free {
                model.zoom(by: 1.7, around: ViewPoint(x: 120, y: 400))
                model.pan(by: ViewVector(dx: -33, dy: 12))
            }
            for _ in 0..<200 {
                let point = ViewPoint(x: Double.random(in: -100...500, using: &generator), y: Double.random(in: -100...1000, using: &generator))
                let back = model.viewPoint(for: model.remotePoint(for: point, clamped: false))
                #expect(approximately(back.x, point.x, tolerance: 1e-9) && approximately(back.y, point.y, tolerance: 1e-9))

                let pixel = PixelPoint(x: Double.random(in: 0...799, using: &generator), y: Double.random(in: 0...599, using: &generator))
                let again = model.remotePoint(for: model.viewPoint(for: pixel))
                #expect(approximately(again.x, pixel.x, tolerance: 1e-9) && approximately(again.y, pixel.y, tolerance: 1e-9))
            }
        }
    }
}

@Suite struct ViewportZoomAndPanTests {
    @Test func zoomKeepsThePixelUnderTheAnchor() {
        var model = viewport(400, 300)
        let anchor = ViewPoint(x: 100, y: 80)
        let before = model.remotePoint(for: anchor)
        model.zoom(by: 2, around: anchor)
        #expect(model.mode == .free)
        #expect(model.scale == 1)
        let after = model.remotePoint(for: anchor)
        #expect(approximately(after.x, before.x) && approximately(after.y, before.y))
        #expect(model.viewPoint(for: before) == anchor)

        model.zoom(by: 1.3, around: anchor)
        let again = model.remotePoint(for: anchor)
        #expect(approximately(again.x, before.x) && approximately(again.y, before.y))
    }

    @Test func zoomingOutNeverExposesMoreThanClampingAllows() {
        var model = viewport(400, 300)
        model.zoom(by: 2, around: ViewPoint(x: 400, y: 300))
        // Anchored at the bottom-right corner, which showed remote (800, 600).
        #expect(model.contentFrame.maxX == 400 && model.contentFrame.maxY == 300)
        model.zoom(by: 0.5, around: ViewPoint(x: 0, y: 0))
        #expect(model.contentFrame == ViewRect(x: 0, y: 0, width: 400, height: 300))
    }

    @Test func panReportsWhatWasApplied() {
        var fitted = viewport(400, 300)
        #expect(fitted.pan(by: ViewVector(dx: 50, dy: 50)) == .zero)
        #expect(fitted.contentFrame.origin == .zero)

        var zoomed = viewport(400, 300)
        zoomed.setScale(1, around: ViewPoint(x: 200, y: 150))
        #expect(zoomed.origin == ViewPoint(x: -200, y: -150))
        #expect(zoomed.pan(by: ViewVector(dx: 30, dy: -20)) == ViewVector(dx: 30, dy: -20))
        // Only 170 points are left before the desktop's left edge reaches the view's.
        #expect(zoomed.pan(by: ViewVector(dx: 500, dy: 0)) == ViewVector(dx: 170, dy: 0))
        #expect(zoomed.origin.x == 0)
        #expect(zoomed.pan(by: ViewVector(dx: .nan, dy: 0)) == .zero)
        #expect(zoomed.mode == .free)
    }

    @Test func setScaleIgnoresNonsense() {
        var model = viewport(400, 300)
        let before = model
        model.setScale(.nan, around: .zero)
        model.setScale(0, around: .zero)
        model.setScale(-3, around: .zero)
        model.zoom(by: .infinity, around: .zero)
        model.zoom(by: 0, around: .zero)
        #expect(model == before)
    }

    @Test func settleSnapsNearFitOnly() {
        var near = viewport(400, 300)
        near.setScale(0.512, around: ViewPoint(x: 10, y: 10))
        #expect(near.mode == .free)
        near.settle()
        #expect(near.mode == .fit)
        #expect(near.scale == 0.5)
        #expect(near.contentFrame == ViewRect(x: 0, y: 0, width: 400, height: 300))

        var far = viewport(400, 300)
        far.setScale(0.6, around: ViewPoint(x: 10, y: 10))
        far.settle()
        #expect(far.mode == .free)
        #expect(far.scale == 0.6)

        var actual = viewport(400, 800)
        actual.setMode(.actualSize)
        actual.settle()
        #expect(actual.mode == .actualSize)
    }

    @Test func revealPansAsLittleAsNeeded() {
        var model = viewport(400, 300)
        model.setScale(1, around: .zero)
        #expect(model.origin == .zero)

        // Already comfortably visible: nothing moves.
        #expect(model.reveal(PixelPoint(x: 200, y: 150)) == .zero)

        model.reveal(PixelPoint(x: 700, y: 500))
        #expect(model.viewPoint(for: PixelPoint(x: 700, y: 500)) == ViewPoint(x: 376, y: 276))

        model.reveal(PixelPoint(x: 690, y: 490))
        // Still inside the margin: no further movement.
        #expect(model.origin == ViewPoint(x: -324, y: -224))

        model.reveal(PixelPoint(x: 10, y: 5), margin: 24)
        // Would need to pan past the desktop's corner; clamping wins.
        #expect(model.origin == .zero)

        // A margin larger than the view degrades to "centre it".
        model.reveal(PixelPoint(x: 400, y: 300), margin: 10_000)
        #expect(model.viewPoint(for: PixelPoint(x: 400, y: 300)) == ViewPoint(x: 200, y: 150))
    }

    @Test func edgeAutoPanOnlyWhereThereIsMoreToSee() {
        var model = viewport(400, 300)
        #expect(model.edgeAutoPanVelocity(at: ViewPoint(x: 399, y: 299)) == .zero)

        model.setScale(1, around: .zero)   // showing the top-left quarter
        #expect(model.edgeAutoPanVelocity(at: ViewPoint(x: 200, y: 150)) == .zero)
        // Top-left corner: nothing beyond it.
        #expect(model.edgeAutoPanVelocity(at: ViewPoint(x: 2, y: 2)) == .zero)

        let right = model.edgeAutoPanVelocity(at: ViewPoint(x: 400, y: 150))
        #expect(right == ViewVector(dx: -900, dy: 0))
        let partly = model.edgeAutoPanVelocity(at: ViewPoint(x: 378, y: 150))
        #expect(approximately(partly.dx, -450))
        let corner = model.edgeAutoPanVelocity(at: ViewPoint(x: 400, y: 300), edgeWidth: 20, maximumSpeed: 100)
        #expect(corner == ViewVector(dx: -100, dy: -100))

        model.pan(by: ViewVector(dx: -400, dy: -300))   // now showing the bottom-right quarter
        #expect(model.edgeAutoPanVelocity(at: ViewPoint(x: 400, y: 300)) == .zero)
        #expect(model.edgeAutoPanVelocity(at: ViewPoint(x: 0, y: 0)) == ViewVector(dx: 900, dy: 900))
    }
}

@Suite struct ViewportObstructionTests {
    @Test func keyboardSlidesALetterboxedDesktopUpWithoutRescaling() {
        var model = viewport(400, 800)
        model.safeAreaInsets = ViewInsets(top: 100, bottom: 50)
        #expect(model.contentFrame.minY == 275)

        model.obstructionInsets = ViewInsets(bottom: 300)
        #expect(model.scale == 0.5)
        #expect(model.availableRect == ViewRect(x: 0, y: 100, width: 400, height: 400))
        #expect(model.contentFrame.minY == 150)
        #expect(!model.isPannable)

        // An obstruction smaller than the safe-area inset changes nothing.
        model.obstructionInsets = ViewInsets(bottom: 20)
        #expect(model.contentFrame.minY == 275)

        model.obstructionInsets = .zero
        #expect(model.contentFrame.minY == 275)
    }

    @Test func tallKeyboardMakesFitPannableSoTheDockStaysReachable() {
        var model = viewport(400, 800)
        model.safeAreaInsets = ViewInsets(top: 100, bottom: 50)
        model.obstructionInsets = ViewInsets(bottom: 500)   // 200 points left for a 300-point desktop
        #expect(model.mode == .fit)
        #expect(model.scale == 0.5)
        #expect(model.isPannable)
        #expect(model.contentFrame.minY == 100)   // top of the desktop (menu bar) under the bar's edge

        model.pan(by: ViewVector(dx: 0, dy: -10_000))
        #expect(model.contentFrame.maxY == 300)   // bottom of the desktop (Dock) just above the keyboard
        model.pan(by: ViewVector(dx: 0, dy: 10_000))
        #expect(model.contentFrame.minY == 100)

        // The pointer can be followed under the keyboard.
        model.reveal(PixelPoint(x: 400, y: 560), margin: 10)
        #expect(model.viewPoint(for: PixelPoint(x: 400, y: 560)).y == 290)

        model.obstructionInsets = .zero
        #expect(!model.isPannable)
        #expect(model.contentFrame.minY == 275)
    }

    @Test func zoomedContentEdgesReachTheUnobstructedArea() {
        var model = viewport(400, 800)
        model.safeAreaInsets = ViewInsets(top: 100, left: 10, bottom: 50, right: 20)
        model.obstructionInsets = ViewInsets(bottom: 300)
        model.setScale(2, around: ViewPoint(x: 200, y: 300))
        let available = model.availableRect
        #expect(available == ViewRect(x: 10, y: 100, width: 370, height: 400))

        model.pan(by: ViewVector(dx: 1e6, dy: 1e6))
        #expect(model.contentFrame.minX == available.minX && model.contentFrame.minY == available.minY)
        model.pan(by: ViewVector(dx: -1e6, dy: -1e6))
        #expect(approximately(model.contentFrame.maxX, available.maxX) && approximately(model.contentFrame.maxY, available.maxY))
    }
}

@Suite struct ViewportResizeTests {
    @Test func resizingTheViewKeepsWhatWasInTheMiddle() {
        var model = viewport(400, 300)
        model.setScale(1, around: ViewPoint(x: 200, y: 150))
        model.pan(by: ViewVector(dx: -50, dy: 30))
        let centre = model.remotePoint(for: ViewPoint(x: 200, y: 150))

        model.viewSize = ViewSize(width: 300, height: 400)
        #expect(model.mode == .free)
        #expect(model.scale == 1)
        let after = model.remotePoint(for: ViewPoint(x: 150, y: 200))
        #expect(approximately(after.x, centre.x) && approximately(after.y, centre.y))
    }

    @Test func resizedRemoteDisplayKeepsZoomRelativeToFit() {
        var model = viewport(400, 300)
        model.setScale(1, around: ViewPoint(x: 200, y: 150))   // twice fit
        model.contentSize = PixelSize(width: 1600, height: 1200)
        #expect(model.mode == .free)
        #expect(model.scale == 0.5)                              // still twice fit
        let centre = model.remotePoint(for: ViewPoint(x: 200, y: 150))
        #expect(approximately(centre.x, 800) && approximately(centre.y, 600))
    }

    @Test func insetChangesDoNotMoveZoomedContentUnlessTheyMust() {
        var model = viewport(400, 300)
        model.setScale(1, around: ViewPoint(x: 200, y: 150))
        let origin = model.origin
        model.obstructionInsets = ViewInsets(bottom: 100)
        #expect(model.origin == origin)
        model.pan(by: ViewVector(dx: 0, dy: -1e6))
        #expect(model.contentFrame.maxY == 200)
        model.obstructionInsets = .zero
        // The desktop's bottom edge may not float above the view's bottom edge once the keyboard is gone.
        #expect(model.contentFrame.maxY == 300)
    }
}

@Suite struct ViewportDegenerateTests {
    @Test func emptyAndAbsurdInputsStayFinite() {
        var models: [ViewportModel] = [
            ViewportModel(),
            ViewportModel(viewSize: ViewSize(width: 400, height: 300)),
            ViewportModel(contentSize: content),
            ViewportModel(viewSize: ViewSize(width: -5, height: .nan), contentSize: content),
            ViewportModel(viewSize: ViewSize(width: 400, height: 300), contentSize: PixelSize(width: -1, height: 600)),
            ViewportModel(viewSize: ViewSize(width: 400, height: 300), contentSize: content, deviceScale: 0),
            ViewportModel(viewSize: ViewSize(width: 400, height: 300), contentSize: content, deviceScale: .infinity),
        ]
        var squeezed = viewport(400, 300)
        squeezed.safeAreaInsets = ViewInsets(top: 500, left: 500, bottom: 500, right: 500)
        models.append(squeezed)
        var covered = viewport(400, 300)
        covered.obstructionInsets = ViewInsets(bottom: 5000)
        models.append(covered)

        for var model in models {
            #expect(isFinite(model))
            for mode in ViewportModel.ZoomMode.allCases {
                model.setMode(mode)
                #expect(isFinite(model))
                model.zoom(by: 3, around: ViewPoint(x: 10, y: 10))
                model.pan(by: ViewVector(dx: 1e9, dy: -1e9))
                model.reveal(PixelPoint(x: 5, y: 5))
                model.settle()
                #expect(isFinite(model))
                let remote = model.remotePoint(for: ViewPoint(x: 7, y: 9))
                #expect(remote.x.isFinite && remote.y.isFinite && remote.x >= 0 && remote.y >= 0)
                let velocity = model.edgeAutoPanVelocity(at: ViewPoint(x: 0, y: 0))
                #expect(velocity.dx.isFinite && velocity.dy.isFinite)
            }
        }
    }

    @Test func recoversWhenSizesArrive() {
        var model = ViewportModel()
        model.contentSize = content
        model.viewSize = ViewSize(width: 400, height: 300)
        #expect(model.scale == 0.5)
        #expect(model.contentFrame == ViewRect(x: 0, y: 0, width: 400, height: 300))
    }

    @Test func isAValue() throws {
        var model = viewport(393, 852, deviceScale: 3)
        model.safeAreaInsets = ViewInsets(top: 59, bottom: 34)
        model.zoom(by: 1.5, around: ViewPoint(x: 100, y: 300))
        let copy = model
        #expect(copy == model && copy.hashValue == model.hashValue)
        let decoded = try JSONDecoder().decode(ViewportModel.self, from: JSONEncoder().encode(model))
        #expect(decoded == model)
        model.pan(by: ViewVector(dx: -5, dy: 0))
        #expect(copy != model)
    }
}
