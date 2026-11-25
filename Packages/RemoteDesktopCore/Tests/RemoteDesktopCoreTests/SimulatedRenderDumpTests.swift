// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import RemoteDesktopCore
import RemoteDesktopSimulated
import Testing
import UniformTypeIdentifiers

/// Writes what the simulated desktop draws to a PNG, for eyeballing. Runs only when
/// `MARIONETTE_DUMP_DIR` names a directory.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MARIONETTE_DUMP_DIR"] != nil))
struct SimulatedRenderDumpTests {
    @Test func dumpDesktop() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MARIONETTE_DUMP_DIR"]))
        var scenario = SimulationScenario.highPerformance
        scenario.phaseDelay = .milliseconds(1)
        scenario.displays = [.init(name: "Built-in Display", pixelSize: PixelSize(width: 1440, height: 900), scale: 2)]
        scenario.initialRemoteClipboard = "copied on the remote"
        let session = try await SimulatedBackend(scenario: scenario).connectSimulated(
            ConnectionRequest(transport: SimulatedTransport(), prompts: StaticPromptHandler(username: "demo", password: "demo"))
        )
        let display = try #require(session.layout.displays.first)
        let generation = session.layout.generation
        session.input.send(.key(KeyEvent(key: .w, characters: "W", charactersIgnoringModifiers: "w", modifiers: .leftShift, phase: .down)))
        session.input.send(.text("FH says hi"))
        session.input.send(.key(KeyEvent(key: .c, characters: "c", charactersIgnoringModifiers: "c", modifiers: .leftCommand, phase: .down)))
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 300, y: 620), buttons: .primary, layoutGeneration: generation)))
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 1100, y: 240), buttons: [], layoutGeneration: generation)))
        session.input.send(.scroll(ScrollEvent(display: display.id, position: PixelPoint(x: 1100, y: 240), deltaX: 0, deltaY: -42, isPrecise: true, layoutGeneration: generation)))
        await session.waitForInputToBeRendered()

        let frames = session.frames(for: display.id)
        let frame = try #require(await frames.next())
        let image: CGImage? = frame.surface.withUnsafeBuffer { buffer in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
            return context?.makeImage()
        }
        let url = directory.appending(path: "simulated-desktop.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image), nil)
        #expect(CGImageDestinationFinalize(destination))
        await session.disconnect()
    }
}
