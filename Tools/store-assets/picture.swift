// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// The two things done to pictures on the way to the App Store, for Scripts/store-assets.sh.
//
//   picture flatten <input> <output.png> [--expect WxH[,WxH…]] [--srgb]
//       Rewrites a picture as an opaque PNG: the App Store refuses an alpha channel. The colour
//       profile is kept unless --srgb asks for sRGB. --expect fails when the picture has none of
//       the sizes named.
//
//   picture cutout <input> <output.png> --crop X,Y,W,H [--tolerance N]
//       Cuts a subject out of a flat background, for a picture of the device in DeviceHub's window:
//       within the cropped region, everything connected to the border and close in colour to the
//       region's top-left pixel becomes transparent, and the result is trimmed to the subject.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

var arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Removes `name` and the value after it from the arguments, and returns the value.
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

func read(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(path)") }
    return image
}

func write(_ image: CGImage, to path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(path)") }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - flatten

func flatten() {
    let expected = option("--expect")?.split(separator: ",").map(String.init)
    let wantsSRGB = flag("--srgb")
    guard arguments.count == 2 else { fail("usage: picture flatten <input> <output.png> [--expect WxH[,WxH…]] [--srgb]") }
    let image = read(arguments[0])
    let size = "\(image.width)x\(image.height)"
    if let expected, !expected.contains(size) { fail("\(arguments[0]) is \(size), expected \(expected.joined(separator: " or "))") }
    let space = wantsSRGB ? sRGB : (image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB)
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fail("cannot make a bitmap") }
    let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(whole)
    context.draw(image, in: whole)
    guard let opaque = context.makeImage() else { fail("cannot make the picture") }
    write(opaque, to: arguments[1])
}

// MARK: - cutout

func cutout() {
    let tolerance = option("--tolerance").flatMap { Int($0) } ?? 10
    let region = option("--crop")?.split(separator: ",").compactMap { Int($0) } ?? []
    guard arguments.count == 2, region.count == 4 else { fail("usage: picture cutout <input> <output.png> --crop X,Y,W,H [--tolerance N]") }
    guard let image = read(arguments[0]).cropping(to: CGRect(x: region[0], y: region[1], width: region[2], height: region[3])) else {
        fail("the region is outside the picture")
    }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot make a bitmap") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let background = (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
    func distance(_ index: Int) -> Int {
        max(abs(Int(pixels[index]) - background.0), abs(Int(pixels[index + 1]) - background.1), abs(Int(pixels[index + 2]) - background.2))
    }

    // Flood inwards from every border pixel through pixels of the background's colour.
    var outside = [Bool](repeating: false, count: width * height)
    var pending: [Int] = []
    func visit(_ x: Int, _ y: Int) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let position = y * width + x
        if !outside[position], distance(position * 4) <= tolerance {
            outside[position] = true
            pending.append(position)
        }
    }
    for x in 0..<width { visit(x, 0); visit(x, height - 1) }
    for y in 0..<height { visit(0, y); visit(width - 1, y) }
    while let position = pending.popLast() {
        let x = position % width, y = position / width
        visit(x + 1, y); visit(x - 1, y); visit(x, y + 1); visit(x, y - 1)
    }

    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let position = y * width + x, index = position * 4
            if outside[position] {
                pixels.replaceSubrange(index..<(index + 4), with: [0, 0, 0, 0])
                continue
            }
            // On the subject's rim, alpha follows how far the pixel is from the background's
            // colour, which keeps the edge's own anti-aliasing instead of a hard step.
            let onRim = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { dx, dy in
                let nx = x + dx, ny = y + dy
                return nx >= 0 && ny >= 0 && nx < width && ny < height && outside[ny * width + nx]
            }
            if onRim {
                let alpha = min(255, max(0, (distance(index) - tolerance) * 255 / 60))
                for channel in 0..<3 { pixels[index + channel] = UInt8(Int(pixels[index + channel]) * alpha / 255) }
                pixels[index + 3] = UInt8(alpha)
            }
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0, let whole = context.makeImage() else { fail("nothing but background in the region") }
    let margin = 8
    let left = max(0, minX - margin), top = max(0, minY - margin)
    let box = CGRect(x: left, y: top, width: min(width, maxX + margin + 1) - left, height: min(height, maxY + margin + 1) - top)
    guard let subject = whole.cropping(to: box) else { fail("cannot trim the picture") }
    write(subject, to: arguments[1])
    print("\(subject.width)x\(subject.height)")
}

switch arguments.isEmpty ? "" : arguments.removeFirst() {
case "flatten": flatten()
case "cutout": cutout()
default: fail("usage: picture flatten|cutout …")
}
