// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import RemoteDesktopCore
import Testing

struct RGB: Equatable, CustomStringConvertible {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    static let red = RGB(255, 0, 0)
    static let green = RGB(0, 255, 0)
    static let blue = RGB(0, 0, 255)
    static let magenta = RGB(255, 0, 255)
    static let grey = RGB(50, 50, 50)
    static let black = RGB(0, 0, 0)
    static let white = RGB(255, 255, 255)

    var description: String { "(\(red), \(green), \(blue))" }

    func isClose(to other: RGB, tolerance: Int = 2) -> Bool {
        abs(Int(red) - Int(other.red)) <= tolerance
            && abs(Int(green) - Int(other.green)) <= tolerance
            && abs(Int(blue) - Int(other.blue)) <= tolerance
    }
}

/// An image copied into memory so tests can look at single pixels. Row 0 is the top.
struct Bitmap {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try #require(context.data)
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    subscript(x: Int, y: Int) -> RGB {
        let offset = (y * width + x) * 4
        return RGB(bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
}

/// A BGRA frame. IOSurface-backed, like the ones back ends publish, unless asked otherwise.
func makeFrame(
    width: Int,
    height: Int,
    display: DisplayID = DisplayID(1),
    generation: UInt64 = 1,
    surfaceBacked: Bool = true,
    colour: (_ x: Int, _ y: Int) -> RGB
) throws -> DisplayFrame {
    var attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true]
    if surfaceBacked {
        attributes[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary
        attributes[kCVPixelBufferMetalCompatibilityKey] = true
    }
    var created: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created)
    #expect(status == kCVReturnSuccess)
    let buffer = try #require(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = try #require(CVPixelBufferGetBaseAddress(buffer))
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let value = colour(x, y)
            row[x * 4] = value.blue
            row[x * 4 + 1] = value.green
            row[x * 4 + 2] = value.red
            row[x * 4 + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let size = PixelSize(width: width, height: height)
    return DisplayFrame(
        display: display,
        surface: .adopting(buffer),
        pixelSize: size,
        damage: .full(size),
        layoutGeneration: generation
    )
}

/// A square pointer image of one premultiplied colour.
func makeCursor(
    id: UInt64 = 7,
    side: Int = 8,
    colour: RGB = .magenta,
    alpha: UInt8 = 255,
    hotspot: PixelPoint = .zero,
    scale: Double = 1
) -> CursorImage {
    var pixels = Data(capacity: side * side * 4)
    for _ in 0..<(side * side) {
        pixels.append(contentsOf: [
            UInt8(Int(colour.blue) * Int(alpha) / 255),
            UInt8(Int(colour.green) * Int(alpha) / 255),
            UInt8(Int(colour.red) * Int(alpha) / 255),
            alpha,
        ])
    }
    return CursorImage(id: id, pixelSize: PixelSize(width: side, height: side), bgraPixels: pixels, hotspot: hotspot, scale: scale)
}

/// Polls until `condition` holds or the time runs out; returns whether it held.
func eventually(within timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

let hasMetalDevice = MTLCreateSystemDefaultDevice() != nil
