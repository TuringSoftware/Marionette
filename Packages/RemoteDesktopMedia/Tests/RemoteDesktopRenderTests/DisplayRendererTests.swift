// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import RemoteDesktopCore
@testable import RemoteDesktopRender
import RemoteDesktopSimulated
import Testing

/// A 100 x 100 point view at one device pixel per point, so points and offscreen pixels coincide.
private func geometry(
    content: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
    remoteScale: Double = 1,
    desktopOrigin: PixelPoint = .zero
) -> RenderGeometry {
    RenderGeometry(
        viewSize: CGSize(width: 100, height: 100),
        deviceScale: 1,
        contentFrame: content,
        remoteScale: remoteScale,
        desktopOrigin: desktopOrigin
    )
}

private func render(_ renderer: DisplayRenderer, width: Int = 100, height: Int = 100) throws -> Bitmap {
    try Bitmap(try #require(renderer.renderOffscreen(pixelWidth: width, pixelHeight: height)))
}

@Suite(.enabled(if: hasMetalDevice))
struct DisplayCompositionTests {
    @Test func frameLandsAtContentFrameAndLetterboxIsBackground() throws {
        let renderer = DisplayRenderer()
        #expect(renderer.isAvailable)
        renderer.setBackgroundColor(red: 0, green: 1, blue: 0)
        renderer.setGeometry(geometry(content: CGRect(x: 10, y: 20, width: 80, height: 40)))
        renderer.submit(try makeFrame(width: 64, height: 32) { x, _ in x < 32 ? .red : .blue })

        let image = try render(renderer)
        #expect(image[5, 5] == .green)
        #expect(image[50, 10] == .green)
        #expect(image[50, 70] == .green)
        #expect(image[95, 40] == .green)
        #expect(image[9, 30] == .green)
        #expect(image[50, 19] == .green)
        // Inside: left half red, right half blue, edges included.
        #expect(image[10, 20] == .red)
        #expect(image[20, 30] == .red)
        #expect(image[80, 50] == .blue)
        #expect(image[89, 59] == .blue)
        #expect(image[90, 60] == .green)
    }

    @Test func backgroundDefaultsToBlackAndNothingIsDrawnWithoutAFrame() throws {
        let renderer = DisplayRenderer()
        renderer.setGeometry(geometry())
        renderer.setLocalPointer(PixelPoint(x: 50, y: 50))
        let image = try render(renderer)
        #expect(image[50, 50] == .black)
        #expect(image[52, 58] == .black)
        #expect(!renderer.hasFrame)
        #expect(renderer.lastFramePixelSize == nil)
        #expect(renderer.snapshot() == nil)
    }

    @Test func wholeMultiplesArePixelExact() throws {
        let renderer = DisplayRenderer()
        renderer.submit(try makeFrame(width: 8, height: 8) { x, y in (x + y).isMultiple(of: 2) ? .white : .black })

        renderer.setGeometry(RenderGeometry(viewSize: CGSize(width: 8, height: 8), deviceScale: 1, contentFrame: CGRect(x: 0, y: 0, width: 8, height: 8)))
        let actual = try render(renderer, width: 8, height: 8)
        for y in 0..<8 {
            for x in 0..<8 {
                #expect(actual[x, y] == ((x + y).isMultiple(of: 2) ? .white : .black))
            }
        }

        // 2x: every remote pixel becomes a crisp 2 x 2 block.
        renderer.setGeometry(RenderGeometry(viewSize: CGSize(width: 8, height: 8), deviceScale: 2, contentFrame: CGRect(x: 0, y: 0, width: 8, height: 8)))
        let doubled = try render(renderer, width: 16, height: 16)
        for y in 0..<16 {
            for x in 0..<16 {
                #expect(doubled[x, y] == ((x / 2 + y / 2).isMultiple(of: 2) ? .white : .black))
            }
        }
    }

    @Test func minificationAveragesInsteadOfAliasing() throws {
        let renderer = DisplayRenderer()
        renderer.submit(try makeFrame(width: 8, height: 8) { x, y in (x + y).isMultiple(of: 2) ? .white : .black })
        // Half size: each output pixel covers a 2 x 2 block that is half white, half black. Point
        // sampling would give pure black or white; averaging gives mid grey everywhere.
        renderer.setGeometry(RenderGeometry(viewSize: CGSize(width: 4, height: 4), deviceScale: 1, contentFrame: CGRect(x: 0, y: 0, width: 4, height: 4)))
        let half = try render(renderer, width: 4, height: 4)
        for y in 0..<4 {
            for x in 0..<4 {
                #expect(half[x, y].isClose(to: RGB(128, 128, 128), tolerance: 3))
            }
        }
    }

    @Test func frameSizeChangeIsPickedUp() throws {
        let renderer = DisplayRenderer()
        renderer.setGeometry(geometry())
        renderer.submit(try makeFrame(width: 64, height: 32, generation: 1) { _, _ in .red })
        #expect(renderer.lastFramePixelSize == PixelSize(width: 64, height: 32))
        #expect(try render(renderer)[50, 50] == .red)

        renderer.submit(try makeFrame(width: 20, height: 80, generation: 2) { x, _ in x < 10 ? .blue : .white })
        #expect(renderer.lastFramePixelSize == PixelSize(width: 20, height: 80))
        let image = try render(renderer)
        #expect(image[25, 50] == .blue)
        #expect(image[75, 50] == .white)
        #expect(try #require(renderer.snapshot()).width == 20)
    }

    @Test func zeroSizedGeometryIsSafe() throws {
        let renderer = DisplayRenderer()
        renderer.setBackgroundColor(red: 0, green: 0, blue: 1)
        renderer.submit(try makeFrame(width: 16, height: 16) { _, _ in .red })
        renderer.setGeometry(RenderGeometry())
        renderer.waitUntilIdle()
        #expect(try render(renderer, width: 10, height: 10)[5, 5] == .blue)

        renderer.setGeometry(RenderGeometry(viewSize: CGSize(width: 10, height: 10), deviceScale: 1, contentFrame: .zero))
        renderer.waitUntilIdle()
        #expect(try render(renderer, width: 10, height: 10)[5, 5] == .blue)

        renderer.setGeometry(RenderGeometry(viewSize: CGSize(width: 10, height: 10), deviceScale: 1, contentFrame: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10)))
        renderer.waitUntilIdle()
        #expect(try render(renderer, width: 10, height: 10)[5, 5] == .blue)

        #expect(renderer.renderOffscreen(pixelWidth: 0, pixelHeight: 10) == nil)
        #expect(renderer.renderOffscreen(pixelWidth: 10, pixelHeight: -1) == nil)
    }

    @Test func drawsIntoItsLayerWithoutCopyingTheSurface() async throws {
        let renderer = DisplayRenderer()
        renderer.setGeometry(geometry())
        renderer.submit(try makeFrame(width: 64, height: 64) { _, _ in .red })
        renderer.waitUntilIdle()
        let path = try #require(renderer.texturePath)
        print("Marionette-TEXTURE-PATH: \(path)")
        #expect(path == .zeroCopy)
        let size = await MainActor.run { renderer.layer.drawableSize }
        #expect(size == CGSize(width: 100, height: 100))
    }

    @Test func surfacesThatCannotBeWrappedAreUploadedInstead() throws {
        // Plain memory, no IOSurface: there is nothing for the GPU to share.
        let renderer = DisplayRenderer()
        renderer.setBackgroundColor(red: 0, green: 1, blue: 0)
        renderer.setGeometry(geometry(content: CGRect(x: 10, y: 20, width: 80, height: 40)))
        renderer.submit(try makeFrame(width: 64, height: 32, surfaceBacked: false) { x, _ in x < 32 ? .red : .blue })
        var image = try render(renderer)
        #expect(renderer.texturePath == .upload)
        #expect(image[5, 5] == .green)
        #expect(image[20, 30] == .red)
        #expect(image[80, 50] == .blue)

        // Same size again reuses the texture; a new size replaces it.
        renderer.submit(try makeFrame(width: 64, height: 32, surfaceBacked: false) { _, _ in .white })
        #expect(try render(renderer)[50, 40] == .white)
        renderer.submit(try makeFrame(width: 20, height: 20, surfaceBacked: false) { _, y in y < 10 ? .blue : .red })
        image = try render(renderer)
        #expect(image[50, 25] == .blue)
        #expect(image[50, 55] == .red)

        renderer.submit(try makeFrame(width: 64, height: 32) { _, _ in .magenta })
        #expect(try render(renderer)[50, 40] == .magenta)
        #expect(renderer.texturePath == .zeroCopy)
        #expect(try Bitmap(try #require(renderer.snapshot()))[3, 3] == .magenta)
    }

    @Test func repeatedDrawsIntoALayerThatIsNotOnScreenDoNotStall() throws {
        // A renderer outlives its views; while no view hosts the layer, frames keep arriving.
        let renderer = DisplayRenderer()
        renderer.setGeometry(geometry())
        let frames = try (0..<40).map { index in
            try makeFrame(width: 32, height: 32) { _, _ in RGB(UInt8(index * 6), 0, 0) }
        }
        let started = ContinuousClock.now
        for frame in frames {
            renderer.submit(frame)
            renderer.waitUntilIdle()
        }
        let elapsed = ContinuousClock.now - started
        print("Marionette-DETACHED-DRAWS: 40 draws in \(elapsed)")
        #expect(elapsed < .seconds(3))
        #expect(try render(renderer)[50, 50] == RGB(UInt8(39 * 6), 0, 0))
    }

    @Test func nothingIsDrawnWhileDrawingIsSuspended() throws {
        let renderer = DisplayRenderer()
        renderer.suspendDrawing()
        // A frame from the mailbox, a cursor update and a layout pass: each would draw.
        renderer.setGeometry(geometry())
        renderer.submit(try makeFrame(width: 64, height: 64) { _, _ in .red })
        renderer.submit(CursorState(image: makeCursor(), position: PixelPoint(x: 10, y: 10)))
        renderer.waitUntilIdle()
        #expect(renderer.texturePath == nil, "nothing reached the GPU")
        #expect(renderer.hasFrame, "the frame is kept for the resume")

        renderer.resumeDrawing()
        renderer.waitUntilIdle()
        #expect(renderer.texturePath != nil)
        #expect(!renderer.isDrawingSuspended)
    }
}

@Suite(.enabled(if: hasMetalDevice))
struct CursorCompositionTests {
    private func rendererWithGreyDesktop(_ geometry: RenderGeometry = geometry()) throws -> DisplayRenderer {
        let renderer = DisplayRenderer()
        renderer.setGeometry(geometry)
        renderer.submit(try makeFrame(width: 100, height: 100) { _, _ in .grey })
        return renderer
    }

    @Test func cursorIsDrawnAtItsPositionWithTheHotspotHonoured() throws {
        let renderer = try rendererWithGreyDesktop()
        renderer.submit(CursorState(image: makeCursor(hotspot: PixelPoint(x: 2, y: 2)), position: PixelPoint(x: 40, y: 40)))
        let image = try render(renderer)
        // The 8 x 8 image covers 38..<46 in both directions.
        #expect(image[38, 38] == .magenta)
        #expect(image[41, 41] == .magenta)
        #expect(image[45, 45] == .magenta)
        #expect(image[37, 41] == .grey)
        #expect(image[41, 37] == .grey)
        #expect(image[46, 46] == .grey)
    }

    @Test func cursorPositionIsRelativeToTheDisplaysDesktopOrigin() throws {
        let renderer = try rendererWithGreyDesktop(geometry(desktopOrigin: PixelPoint(x: 1000, y: 200)))
        renderer.submit(CursorState(image: makeCursor(), position: PixelPoint(x: 1040, y: 240)))
        let image = try render(renderer)
        #expect(image[41, 41] == .magenta)
        #expect(image[39, 39] == .grey)
        #expect(image[48, 48] == .grey)
    }

    @Test func cursorIsSuppressedWhenCompositedInvisibleOrHidden() throws {
        let renderer = try rendererWithGreyDesktop()
        let cursor = makeCursor()

        renderer.submit(CursorState(image: cursor, position: PixelPoint(x: 40, y: 40), isCompositedInFrames: true))
        #expect(try render(renderer)[41, 41] == .grey)
        // Even a locally driven pointer must not be drawn twice.
        renderer.setLocalPointer(PixelPoint(x: 40, y: 40))
        #expect(try render(renderer)[41, 41] == .grey)
        renderer.setLocalPointer(nil)

        renderer.submit(CursorState(image: cursor, position: PixelPoint(x: 40, y: 40), isVisible: false))
        #expect(try render(renderer)[41, 41] == .grey)

        renderer.submit(CursorState(image: cursor, position: PixelPoint(x: 40, y: 40)))
        #expect(try render(renderer)[41, 41] == .magenta)
        renderer.setCursorHidden(true)
        #expect(try render(renderer)[41, 41] == .grey)
        renderer.setCursorHidden(false)
        #expect(try render(renderer)[41, 41] == .magenta)

        // No reported position and no local pointer: nowhere to draw it.
        renderer.submit(CursorState(image: cursor, position: nil))
        #expect(try render(renderer)[41, 41] == .grey)
        #expect(try render(renderer)[1, 1] == .grey)
    }

    @Test func localPointerOverridesTheReportedPosition() throws {
        let renderer = try rendererWithGreyDesktop()
        renderer.submit(CursorState(image: makeCursor(), position: PixelPoint(x: 40, y: 40)))
        renderer.setLocalPointer(PixelPoint(x: 70, y: 20))
        var image = try render(renderer)
        #expect(image[71, 21] == .magenta)
        #expect(image[41, 41] == .grey)

        renderer.setLocalPointer(nil)
        image = try render(renderer)
        #expect(image[71, 21] == .grey)
        #expect(image[41, 41] == .magenta)
    }

    @Test func cursorNeverShrinksBelowItsNaturalSize() throws {
        // A 200 px display squeezed into 50 points: a quarter point per remote pixel.
        let renderer = DisplayRenderer()
        renderer.setGeometry(geometry(content: CGRect(x: 0, y: 0, width: 50, height: 50), remoteScale: 2))
        renderer.submit(try makeFrame(width: 200, height: 200) { _, _ in .grey })
        renderer.submit(CursorState(image: makeCursor(), position: PixelPoint(x: 100, y: 100)))
        let image = try render(renderer)
        // To scale it would be 4 points wide; it is drawn at its natural 8.
        #expect(image[25, 25] == .magenta)
        #expect(image[32, 32] == .magenta)
        #expect(image[33, 33] == .grey)
        #expect(image[24, 24] == .grey)
    }

    @Test func cursorGrowsWithTheDesktopWhenZoomedIn() throws {
        // A 50 px display over 100 points: two points per remote pixel.
        let renderer = DisplayRenderer()
        renderer.setGeometry(geometry())
        renderer.submit(try makeFrame(width: 50, height: 50) { _, _ in .grey })
        renderer.submit(CursorState(image: makeCursor(), position: PixelPoint(x: 10, y: 10)))
        let image = try render(renderer)
        #expect(image[20, 20] == .magenta)
        #expect(image[35, 35] == .magenta)
        #expect(image[36, 36] == .grey)
        #expect(image[19, 19] == .grey)
    }

    @Test func highDensityCursorIsDrawnAtItsPointSize() throws {
        // A 16 px image at scale 2 on a 2x display shown 1:1 in pixels covers 16 device pixels.
        let renderer = try rendererWithGreyDesktop(geometry(remoteScale: 2))
        renderer.submit(CursorState(image: makeCursor(side: 16, scale: 2), position: PixelPoint(x: 40, y: 40)))
        let image = try render(renderer)
        #expect(image[40, 40] == .magenta)
        #expect(image[55, 55] == .magenta)
        #expect(image[56, 56] == .grey)
    }

    @Test func translucentCursorBlendsOverTheDesktop() throws {
        let renderer = try rendererWithGreyDesktop()
        renderer.submit(CursorState(image: makeCursor(colour: .white, alpha: 128), position: PixelPoint(x: 40, y: 40)))
        // 128 of white plus (1 - 128/255) of grey 50.
        #expect(try render(renderer)[43, 43].isClose(to: RGB(153, 153, 153), tolerance: 2))
    }

    @Test func stockArrowIsDrawnWhenTheRemoteSentNoShape() throws {
        let renderer = try rendererWithGreyDesktop()
        renderer.setLocalPointer(PixelPoint(x: 50, y: 50))
        let image = try render(renderer)
        // Inside the arrow's body, a few points below and right of the tip.
        #expect(image[52, 58].isClose(to: .black, tolerance: 12))
        #expect(image[80, 80] == .grey)
        #expect(image[45, 45] == .grey)
    }

    @Test func newCursorShapeReplacesTheOldOne() throws {
        let renderer = try rendererWithGreyDesktop()
        renderer.submit(CursorState(image: makeCursor(id: 1, colour: .magenta), position: PixelPoint(x: 40, y: 40)))
        #expect(try render(renderer)[43, 43] == .magenta)
        renderer.submit(CursorState(image: makeCursor(id: 2, colour: .green), position: PixelPoint(x: 40, y: 40)))
        #expect(try render(renderer)[43, 43] == .green)
    }
}

@Suite struct CursorLayoutTests {
    private let image = makeCursor(side: 32, hotspot: PixelPoint(x: 4, y: 8), scale: 2)

    @Test func scalesWithTheDesktopAboveNaturalSize() throws {
        // 2x remote display at three points per remote pixel: six times natural size.
        let geometry = RenderGeometry(
            viewSize: CGSize(width: 300, height: 300),
            contentFrame: CGRect(x: 30, y: 60, width: 300, height: 300),
            remoteScale: 2
        )
        let frame = try #require(CursorLayout.frame(
            pointer: PixelPoint(x: 10, y: 20),
            image: image,
            geometry: geometry,
            displayPixelSize: PixelSize(width: 100, height: 100)
        ))
        // 32 px at scale 2 is 16 points natural, times 6.
        #expect(frame.width == 96)
        #expect(frame.height == 96)
        // Anchor (30 + 30, 60 + 60) minus the hotspot (2, 4) points times 6.
        #expect(frame.minX == 48)
        #expect(frame.minY == 96)
    }

    @Test func clampsToNaturalSizeWhenZoomedOut() throws {
        let geometry = RenderGeometry(
            viewSize: CGSize(width: 390, height: 300),
            contentFrame: CGRect(x: 0, y: 28, width: 390, height: 244),
            remoteScale: 2
        )
        let frame = try #require(CursorLayout.frame(
            pointer: PixelPoint(x: 1280, y: 800),
            image: image,
            geometry: geometry,
            displayPixelSize: PixelSize(width: 2560, height: 1600)
        ))
        #expect(frame.width == 16)
        #expect(frame.height == 16)
        #expect(abs(frame.minX - (195 - 2)) < 0.001)
        #expect(abs(frame.minY - (28 + 122 - 4)) < 0.001)
    }

    @Test func nothingToPlaceWithoutContent() {
        #expect(CursorLayout.frame(pointer: .zero, image: image, geometry: RenderGeometry(), displayPixelSize: PixelSize(width: 10, height: 10)) == nil)
        let geometry = RenderGeometry(viewSize: CGSize(width: 10, height: 10), contentFrame: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(CursorLayout.frame(pointer: .zero, image: image, geometry: geometry, displayPixelSize: .zero) == nil)
    }

    @Test func pointerPositionRules() {
        var inputs = RenderInputs()
        inputs.geometry.desktopOrigin = PixelPoint(x: 100, y: 50)
        #expect(CursorLayout.pointerPosition(for: inputs) == nil)

        inputs.cursor.position = PixelPoint(x: 130, y: 70)
        #expect(CursorLayout.pointerPosition(for: inputs) == PixelPoint(x: 30, y: 20))

        inputs.localPointer = PixelPoint(x: 5, y: 6)
        #expect(CursorLayout.pointerPosition(for: inputs) == PixelPoint(x: 5, y: 6))

        inputs.cursor.isCompositedInFrames = true
        #expect(CursorLayout.pointerPosition(for: inputs) == nil)
        inputs.cursor.isCompositedInFrames = false
        inputs.cursor.isVisible = false
        #expect(CursorLayout.pointerPosition(for: inputs) == nil)
        inputs.cursor.isVisible = true
        inputs.isCursorHidden = true
        #expect(CursorLayout.pointerPosition(for: inputs) == nil)
    }
}

@Suite struct SnapshotTests {
    private func pattern(_ x: Int, _ y: Int) -> RGB {
        RGB(UInt8(x * 6), UInt8(y * 12), 77)
    }

    @Test func snapshotCopiesTheLastFrameExactly() throws {
        let renderer = DisplayRenderer()
        #expect(renderer.snapshot() == nil)
        renderer.submit(try makeFrame(width: 40, height: 20, colour: pattern))
        let image = try #require(renderer.snapshot())
        #expect(image.width == 40)
        #expect(image.height == 20)
        let bitmap = try Bitmap(image)
        for (x, y) in [(0, 0), (39, 0), (0, 19), (39, 19), (17, 5), (3, 14)] {
            #expect(bitmap[x, y] == pattern(x, y), "at \(x), \(y)")
        }
    }

    @Test func snapshotIsScaledDownToTheRequestedLimit() throws {
        let renderer = DisplayRenderer()
        renderer.submit(try makeFrame(width: 40, height: 20) { x, _ in x < 20 ? .red : .blue })

        let small = try #require(renderer.snapshot(maximumPixelDimension: 10))
        #expect(small.width == 10)
        #expect(small.height == 5)
        let bitmap = try Bitmap(small)
        #expect(bitmap[1, 2].isClose(to: .red, tolerance: 6))
        #expect(bitmap[8, 2].isClose(to: .blue, tolerance: 6))

        let same = try #require(renderer.snapshot(maximumPixelDimension: 4000))
        #expect(same.width == 40)
        #expect(same.height == 20)

        renderer.submit(try makeFrame(width: 30, height: 90) { _, _ in .green })
        let tall = try #require(renderer.snapshot(maximumPixelDimension: 30))
        #expect(tall.width == 10)
        #expect(tall.height == 30)
    }

    @Test func snapshotLeavesThePointerOut() throws {
        let renderer = DisplayRenderer()
        renderer.setGeometry(geometry())
        renderer.submit(try makeFrame(width: 100, height: 100) { _, _ in .grey })
        renderer.submit(CursorState(image: makeCursor(), position: PixelPoint(x: 40, y: 40)))
        #expect(try Bitmap(try #require(renderer.snapshot()))[43, 43] == .grey)
    }
}

@Suite struct FrameSourceTests {
    @Test func firstFrameReturnsImmediatelyOnceAFrameExists() async throws {
        let renderer = DisplayRenderer()
        renderer.submit(try makeFrame(width: 4, height: 4) { _, _ in .red })
        await renderer.firstFrame()
        #expect(renderer.hasFrame)
    }

    @Test func firstFrameWaitsForAFrame() async throws {
        let renderer = DisplayRenderer()
        let frame = try makeFrame(width: 4, height: 4) { _, _ in .red }
        let waiting = Task {
            await renderer.firstFrame()
            return renderer.hasFrame
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!renderer.hasFrame)
        renderer.submit(frame)
        #expect(await waiting.value)
    }

    @Test func firstFrameHonoursCancellation() async {
        let renderer = DisplayRenderer()
        let waiting = Task {
            await renderer.firstFrame()
            return renderer.hasFrame
        }
        try? await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        #expect(await waiting.value == false)

        // Already cancelled before it starts waiting.
        let cancelled = Task {
            try? await Task.sleep(for: .seconds(60))
            await renderer.firstFrame()
        }
        cancelled.cancel()
        await cancelled.value
    }

    @Test func consumesAMailboxAndKeepsTheLastFrameWhenItEnds() async throws {
        let renderer = DisplayRenderer()
        renderer.setGeometry(geometry())
        let mailbox = FrameMailbox()
        let (cursor, cursorContinuation) = AsyncStream<CursorState>.makeStream()
        renderer.start(frames: mailbox, cursor: cursor)

        mailbox.publish(try makeFrame(width: 10, height: 10) { _, _ in .red })
        await renderer.firstFrame()
        #expect(renderer.lastFramePixelSize == PixelSize(width: 10, height: 10))

        mailbox.publish(try makeFrame(width: 20, height: 20) { _, _ in .blue })
        #expect(await eventually { renderer.lastFramePixelSize == PixelSize(width: 20, height: 20) })

        mailbox.finish()
        cursorContinuation.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(renderer.hasFrame)
        #expect(try Bitmap(try #require(renderer.snapshot()))[5, 5] == .blue)
        if renderer.isAvailable {
            #expect(try render(renderer)[50, 50] == .blue)
        }
    }

    @Test func cursorStreamReachesTheComposition() async throws {
        guard hasMetalDevice else { return }
        let renderer = DisplayRenderer()
        renderer.setGeometry(geometry())
        let mailbox = FrameMailbox()
        let (cursor, cursorContinuation) = AsyncStream<CursorState>.makeStream()
        renderer.start(frames: mailbox, cursor: cursor)
        mailbox.publish(try makeFrame(width: 100, height: 100) { _, _ in .grey })
        await renderer.firstFrame()

        cursorContinuation.yield(CursorState(image: makeCursor(), position: PixelPoint(x: 40, y: 40)))
        var drawn = false
        for _ in 0..<200 where !drawn {
            drawn = try render(renderer)[43, 43] == .magenta
            if !drawn { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(drawn)
        renderer.stop()
    }

    @Test func stopKeepsTheLastFrameAndStartReplacesTheSource() async throws {
        let renderer = DisplayRenderer()
        let first = FrameMailbox()
        renderer.start(frames: first, cursor: nil)
        first.publish(try makeFrame(width: 10, height: 10) { _, _ in .red })
        await renderer.firstFrame()

        renderer.stop()
        try await Task.sleep(for: .milliseconds(20))
        first.publish(try makeFrame(width: 30, height: 30) { _, _ in .green })
        try await Task.sleep(for: .milliseconds(30))
        #expect(renderer.lastFramePixelSize == PixelSize(width: 10, height: 10))
        #expect(try Bitmap(try #require(renderer.snapshot()))[5, 5] == .red)

        let second = FrameMailbox()
        renderer.start(frames: second, cursor: nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(renderer.lastFramePixelSize == PixelSize(width: 10, height: 10))
        second.publish(try makeFrame(width: 20, height: 20) { _, _ in .blue })
        #expect(await eventually { renderer.lastFramePixelSize == PixelSize(width: 20, height: 20) })

        // Restarting on the same mailbox is allowed: the previous consumer has let go of it.
        renderer.start(frames: second, cursor: nil)
        second.publish(try makeFrame(width: 40, height: 40) { _, _ in .white })
        #expect(await eventually { renderer.lastFramePixelSize == PixelSize(width: 40, height: 40) })
        renderer.stop()
    }
}

@Suite struct SimulatedSessionRenderingTests {
    @Test func rendersALiveSimulatedSession() async throws {
        var scenario = SimulationScenario.highPerformance
        scenario.phaseDelay = .milliseconds(1)
        scenario.frameRate = 60
        scenario.displays = [.init(name: "Built-in Display", pixelSize: PixelSize(width: 640, height: 400), scale: 2)]
        let session = try await SimulatedBackend(scenario: scenario).connectSimulated(
            ConnectionRequest(transport: SimulatedTransport(), prompts: StaticPromptHandler(username: "demo", password: "demo"))
        )
        let display = try #require(session.layout.displays.first)

        let renderer = DisplayRenderer()
        renderer.setGeometry(RenderGeometry(
            viewSize: CGSize(width: 320, height: 200),
            deviceScale: 2,
            contentFrame: CGRect(x: 0, y: 0, width: 320, height: 200),
            remoteScale: display.scale,
            desktopOrigin: PixelPoint(x: Double(display.frameInDesktop.x), y: Double(display.frameInDesktop.y))
        ))
        renderer.start(frames: session.frames(for: display.id), cursor: session.cursor())
        await renderer.firstFrame()
        #expect(renderer.hasFrame)
        #expect(renderer.lastFramePixelSize == display.pixelSize)

        let first = try #require(renderer.snapshot())
        #expect(first.width == 640)
        #expect(first.height == 400)

        // Freeze on one frame, then check the GPU shows exactly what the surface holds.
        renderer.stop()
        try await Task.sleep(for: .milliseconds(50))
        renderer.setCursorHidden(true)
        let expected = try Bitmap(try #require(renderer.snapshot()))
        if renderer.isAvailable {
            let actual = try Bitmap(try #require(renderer.renderOffscreen(pixelWidth: 640, pixelHeight: 400)))
            var mismatches = 0
            for y in stride(from: 0, to: 400, by: 7) {
                for x in stride(from: 0, to: 640, by: 5) where actual[x, y] != expected[x, y] {
                    mismatches += 1
                }
            }
            #expect(mismatches == 0)
            // And that the desktop is not one flat colour, so the comparison means something.
            #expect(expected[10, 5] != expected[320, 200] || expected[320, 200] != expected[600, 390])

            // The session's pointer is drawn by the client: moving it changes the composition.
            renderer.setCursorHidden(false)
            renderer.setLocalPointer(PixelPoint(x: 320, y: 300))
            let withPointer = try Bitmap(try #require(renderer.renderOffscreen(pixelWidth: 640, pixelHeight: 400)))
            var changed = 0
            for y in 300..<340 {
                for x in 320..<350 where withPointer[x, y] != expected[x, y] {
                    changed += 1
                }
            }
            #expect(changed > 50)
        }

        await session.disconnect()
        try await Task.sleep(for: .milliseconds(30))
        #expect(renderer.hasFrame)
        #expect(renderer.snapshot(maximumPixelDimension: 128)?.width == 128)
    }

    @Test func followsTheSessionThroughAResize() async throws {
        var scenario = SimulationScenario.highPerformance
        scenario.phaseDelay = .milliseconds(1)
        scenario.reconfigurationDelay = .milliseconds(5)
        scenario.frameRate = 60
        let session = try await SimulatedBackend(scenario: scenario).connectSimulated(
            ConnectionRequest(
                options: SessionOptions(displays: .virtual([VirtualDisplayRequest(pointSize: PixelSize(width: 800, height: 600), scale: 1)])),
                transport: SimulatedTransport(),
                prompts: StaticPromptHandler(username: "demo", password: "demo")
            )
        )
        let display = try #require(session.layout.displays.first)
        let renderer = DisplayRenderer()
        renderer.start(frames: session.frames(for: display.id), cursor: session.cursor())
        await renderer.firstFrame()
        #expect(renderer.lastFramePixelSize == PixelSize(width: 800, height: 600))

        let configuration = try #require(session.capabilities.displayConfiguration.value)
        try await configuration.setVirtualDisplays([VirtualDisplayRequest(pointSize: PixelSize(width: 1024, height: 768), scale: 1)])
        // Display identity is stable across the resize, so the same mailbox carries the new size.
        #expect(await eventually { renderer.lastFramePixelSize == PixelSize(width: 1024, height: 768) })
        #expect(renderer.snapshot()?.width == 1024)
        await session.disconnect()
    }
}
