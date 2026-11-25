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

    /// Reads a BGRA surface back into an image the caller owns, optionally scaled down so that
    /// neither side exceeds `maximumPixelDimension`. The image is opaque (a surface's alpha byte is
    /// undefined) and tagged with the surface's own colour space.
    static func image(from surface: CVReadOnlyPixelBuffer, maximumPixelDimension: Int?) -> CGImage? {
        surface.withUnsafeBuffer { buffer -> CGImage? in
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
            else { return nil }
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
