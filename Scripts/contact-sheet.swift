// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tiles screenshots into one captioned image, for reviewing a set at a glance.
//   swift Scripts/contact-sheet.swift <out.png> <cell width> <columns> <image>...
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 5, let cellWidth = Double(arguments[2]), let columns = Int(arguments[3]), columns > 0 else {
    FileHandle.standardError.write(Data("usage: contact-sheet.swift <out.png> <cell width> <columns> <image>...\n".utf8))
    exit(2)
}
let images: [(name: String, image: CGImage)] = arguments.dropFirst(4).compactMap { path in
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return (url.deletingPathExtension().lastPathComponent, image)
}
guard !images.isEmpty, let space = CGColorSpace(name: CGColorSpace.sRGB) else { exit(1) }
let caption = 22.0, gap = 10.0
let cellHeight = images.map { cellWidth * Double($0.image.height) / Double($0.image.width) }.max() ?? 100
let rows = Int((Double(images.count) / Double(columns)).rounded(.up))
let width = Int(Double(columns) * (cellWidth + gap) + gap)
let height = Int(Double(rows) * (cellHeight + caption + gap) + gap)
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
context.setFillColor(CGColor(gray: 0.5, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.interpolationQuality = .high
let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 13, nil)
for (index, entry) in images.enumerated() {
    let x = gap + Double(index % columns) * (cellWidth + gap)
    let top = gap + Double(index / columns) * (cellHeight + caption + gap)
    let drawnHeight = cellWidth * Double(entry.image.height) / Double(entry.image.width)
    context.draw(entry.image, in: CGRect(x: x, y: Double(height) - top - caption - drawnHeight, width: cellWidth, height: drawnHeight))
    let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, entry.name as CFString, attributes))
    context.textPosition = CGPoint(x: x, y: Double(height) - top - 15)
    CTLineDraw(line, context)
}
guard let output = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(destination, output, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
