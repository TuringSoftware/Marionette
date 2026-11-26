// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreVideo
import Foundation
import RemoteDesktopCore

/// CPU-side image helpers: reading surfaces back and drawing the stock pointer.
enum Imaging {
    /// The colour space a surface's pixels are in: its own attachment when it carries one (High
    /// Performance frames are Display P3 primaries with the sRGB transfer function), else sRGB.
    static func colorSpace(of buffer: CVPixelBuffer) -> CGColorSpace? {
        if let attached = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil),
           CFGetTypeID(attached) == CGColorSpace.typeID {
            // The type was just checked; this attachment key always holds a CGColorSpace.
            return (attached as! CGColorSpace)
        }
        if let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate),
           let described = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue() {
            return described
        }
        return CGColorSpace(name: CGColorSpace.sRGB)
    }

    static func colorSpace(of surface: CVReadOnlyPixelBuffer) -> CGColorSpace? {
        surface.withUnsafeBuffer { colorSpace(of: $0) }
    }

    /// Whether a surface's pixels are PQ-encoded: an HDR picture from a Mac.
    static func isPQ(_ buffer: CVPixelBuffer) -> Bool {
        if let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String {
            return transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        }
        guard let space = colorSpace(of: buffer) else { return false }
        return CGColorSpaceIsPQBased(space)
    }

    static func isPQ(_ surface: CVReadOnlyPixelBuffer) -> Bool {
        surface.withUnsafeBuffer { isPQ($0) }
    }

    /// 10-bit code values to 8-bit sRGB-encoded ones: PQ with SDR white at the renderer's reference
    /// white and everything brighter clipped, as the renderer draws HDR pictures into an SDR target.
    private static let pqToSDR: [UInt8] = (0..<1024).map { code in
        let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
        let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
        let power = pow(Double(code) / 1023, 1 / m2)
        let nits = 10_000 * pow(max(power - c1, 0) / (c2 - c3 * power), 1 / m1)
        let linear = min(nits / RenderCore.referenceWhiteNits, 1)
        let encoded = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return UInt8((encoded * 255).rounded())
    }

    /// The sRGB-encoded colour space with a 10-bit surface's primaries.
    private static func sdrSpace(primariesOf buffer: CVPixelBuffer) -> CGColorSpace? {
        let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
        if primaries == kCVImageBufferColorPrimaries_P3_D65 as String {
            return CGColorSpace(name: CGColorSpace.displayP3)
        }
        if primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String {
            return CGColorSpace(name: CGColorSpace.itur_2020_sRGBGamma)
        }
        return CGColorSpace(name: CGColorSpace.sRGB)
    }

    /// An 8-bit copy of a 10-bit RGB surface (``isPQ(_:)`` or not), in the surface's primaries with
    /// the sRGB transfer function: what the renderer would show on an SDR screen.
    private static func sdrCopy(of buffer: CVPixelBuffer) -> (pixels: Data, space: CGColorSpace)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_ARGB2101010LEPacked,
              let space = sdrSpace(primariesOf: buffer),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let table = isPQ(buffer) ? pqToSDR : (0..<1024).map { UInt8($0 >> 2) }
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { destination in
            let out = destination.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<width {
                    let word = UInt32(littleEndian: row[x])
                    let index = (y * width + x) * 4
                    out[index] = table[Int(word & 0x3ff)]
                    out[index + 1] = table[Int(word >> 10 & 0x3ff)]
                    out[index + 2] = table[Int(word >> 20 & 0x3ff)]
                    out[index + 3] = 255
                }
            }
        }
        return (pixels, space)
    }

    private static let opaqueBGRA = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    private static let premultipliedBGRA = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// An opaque sRGB image from tightly or loosely packed BGRA rows. Copies nothing: `data` is retained.
    static func image(bgra data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard width > 0, height > 0, data.count >= bytesPerRow * (height - 1) + width * 4,
              let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: opaqueBGRA),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Reads a surface back into an image the caller owns, optionally scaled down so that neither
    /// side exceeds `maximumPixelDimension`. The image is opaque (a surface's alpha byte is
    /// undefined). A BGRA surface keeps its own colour space; a 10-bit one becomes the SDR picture
    /// the renderer would show of it.
    static func image(from surface: CVReadOnlyPixelBuffer, maximumPixelDimension: Int?) -> CGImage? {
        surface.withUnsafeBuffer { buffer -> CGImage? in
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
                let width = CVPixelBufferGetWidth(buffer)
                let height = CVPixelBufferGetHeight(buffer)
                guard let (pixels, space) = sdrCopy(of: buffer),
                      let provider = CGDataProvider(data: pixels as CFData),
                      let source = CGImage(
                          width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                          space: space, bitmapInfo: CGBitmapInfo(rawValue: opaqueBGRA), provider: provider,
                          decode: nil, shouldInterpolate: true, intent: .defaultIntent
                      )
                else { return nil }
                return scaledCopy(of: source, space: space, maximumPixelDimension: maximumPixelDimension)
            }
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            guard width > 0, height > 0,
                  let base = CVPixelBufferGetBaseAddress(buffer),
                  let space = colorSpace(of: buffer),
                  // Borrowed, not copied: this source image never leaves the locked scope.
                  let provider = CGDataProvider(
                      dataInfo: nil,
                      data: base,
                      size: bytesPerRow * height,
                      releaseData: { _, _, _ in }
                  ),
                  let source = CGImage(
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bitsPerPixel: 32,
                      bytesPerRow: bytesPerRow,
                      space: space,
                      bitmapInfo: CGBitmapInfo(rawValue: opaqueBGRA),
                      provider: provider,
                      decode: nil,
                      shouldInterpolate: true,
                      intent: .defaultIntent
                  )
            else { return nil }
            return scaledCopy(of: source, space: space, maximumPixelDimension: maximumPixelDimension)
        }
    }

    /// An opaque copy of `source` the caller owns, scaled down so that neither side exceeds
    /// `maximumPixelDimension`.
    private static func scaledCopy(of source: CGImage, space: CGColorSpace, maximumPixelDimension: Int?) -> CGImage? {
        let width = source.width
        let height = source.height
        var targetWidth = width
        var targetHeight = height
        if let limit = maximumPixelDimension, limit > 0, max(width, height) > limit {
            let factor = Double(limit) / Double(max(width, height))
            targetWidth = max(1, Int((Double(width) * factor).rounded()))
            targetHeight = max(1, Int((Double(height) * factor).rounded()))
        }
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: space,
            bitmapInfo: opaqueBGRA
        ) else { return nil }
        let isScaled = targetWidth != width || targetHeight != height
        context.interpolationQuality = isScaled ? .high : .none
        context.setBlendMode(.copy)
        context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    /// Identity reserved for the built-in pointer so it shares the cursor texture cache.
    static let stockArrowID = UInt64.max

    /// The arrow drawn when the remote machine has not sent a pointer shape.
    static let stockArrow: CursorImage? = {
        let scale = 2.0
        let side = 48
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: side * 4,
                  space: space,
                  bitmapInfo: premultipliedBGRA
              )
        else { return nil }
        // Top-left origin, in points.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: scale, y: -scale)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2, y: 1.5))
        path.addLine(to: CGPoint(x: 2, y: 18.5))
        path.addLine(to: CGPoint(x: 6.4, y: 14.4))
        path.addLine(to: CGPoint(x: 9.4, y: 21.4))
        path.addLine(to: CGPoint(x: 12.4, y: 20.1))
        path.addLine(to: CGPoint(x: 9.5, y: 13.3))
        path.addLine(to: CGPoint(x: 15.4, y: 13.3))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(1.25)
        context.setLineJoin(.round)
        context.strokePath()
        guard let data = context.data else { return nil }
        return CursorImage(
            id: stockArrowID,
            pixelSize: PixelSize(width: side, height: side),
            bgraPixels: Data(bytes: data, count: side * side * 4),
            hotspot: PixelPoint(x: 2 * scale, y: 1.5 * scale),
            scale: scale
        )
    }()
}
