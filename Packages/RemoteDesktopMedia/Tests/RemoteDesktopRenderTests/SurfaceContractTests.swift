// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import RemoteDesktopCore
import Testing
@testable import RemoteDesktopRender

/// What real back ends publish: surfaces whose alpha byte means nothing, in sRGB (Standard mode) or
/// Display P3 with the sRGB transfer function (High Performance).
@Suite struct SurfaceContractTests {
    private enum Tagging {
        case none
        case colorSpace(CFString)
        case displayP3Attachments
    }

    private func frame(width: Int = 16, height: Int = 8, alpha: UInt8, tagging: Tagging, colour: RGB = RGB(200, 40, 10)) throws -> DisplayFrame {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created) == kCVReturnSuccess)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[x * 4] = colour.blue
                row[x * 4 + 1] = colour.green
                row[x * 4 + 2] = colour.red
                row[x * 4 + 3] = alpha
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        switch tagging {
        case .none:
            break
        case .colorSpace(let name):
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, try #require(CGColorSpace(name: name)), .shouldPropagate)
        case .displayP3Attachments:
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        let size = PixelSize(width: width, height: height)
        return DisplayFrame(display: DisplayID(1), surface: .adopting(buffer), pixelSize: size, damage: .full(size), layoutGeneration: 1)
    }

    @Test func aZeroAlphaByteDoesNotMakeTheDesktopTransparent() throws {
        let renderer = DisplayRenderer()
        renderer.setBackgroundColor(red: 0, green: 0, blue: 1)
        renderer.setGeometry(RenderGeometry(viewSize: CGSize(width: 16, height: 8), deviceScale: 1, contentFrame: CGRect(x: 0, y: 0, width: 16, height: 8)))
        renderer.submit(try frame(alpha: 0, tagging: .none))

        let snapshot = try #require(renderer.snapshot())
        #expect(snapshot.alphaInfo == .noneSkipFirst)
        #expect(try Bitmap(snapshot)[8, 4] == RGB(200, 40, 10))

        try #require(renderer.isAvailable, "no Metal device")
        let composed = try Bitmap(try #require(renderer.renderOffscreen(pixelWidth: 16, pixelHeight: 8)))
        #expect(composed[8, 4].isClose(to: RGB(200, 40, 10)))
    }

    @Test func untaggedSurfacesAreTreatedAsSRGB() throws {
        let renderer = DisplayRenderer()
        #expect(renderer.frameColorSpace == nil)
        renderer.submit(try frame(alpha: 255, tagging: .none))
        #expect(renderer.frameColorSpace?.name == CGColorSpace.sRGB)
        #expect(renderer.snapshot()?.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test func aDisplayP3SurfaceKeepsItsColourSpace() throws {
        let renderer = DisplayRenderer()
        renderer.submit(try frame(alpha: 0, tagging: .colorSpace(CGColorSpace.displayP3)))
        #expect(renderer.frameColorSpace?.name == CGColorSpace.displayP3)
        let snapshot = try #require(renderer.snapshot(maximumPixelDimension: 8))
        #expect(snapshot.colorSpace?.name == CGColorSpace.displayP3)
        #expect(snapshot.width == 8)

        renderer.submit(try frame(alpha: 255, tagging: .none))
        #expect(renderer.frameColorSpace?.name == CGColorSpace.sRGB)
    }

    @Test func colourAttachmentsWithoutAColourSpaceObjectAreHonoured() throws {
        let renderer = DisplayRenderer()
        renderer.submit(try frame(alpha: 0, tagging: .displayP3Attachments))
        let space = try #require(renderer.frameColorSpace)
        #expect(space.name != CGColorSpace.sRGB)
        #expect(space.isWideGamutRGB)
    }

    @MainActor
    @Test func theLayerIsRetaggedWithTheFramesColourSpace() async throws {
        let renderer = DisplayRenderer()
        #expect(renderer.layer.colorspace?.name == CGColorSpace.sRGB)
        renderer.submit(try frame(alpha: 0, tagging: .colorSpace(CGColorSpace.displayP3)))
        #expect(renderer.layer.colorspace?.name == CGColorSpace.displayP3)
    }
}
