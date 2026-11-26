// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import RemoteDesktopCore
import UniformTypeIdentifiers

/// What the simulated desktop currently shows. Pure data; the canvas turns it into pixels.
struct SimulatedDesktopContent: Sendable, Equatable {
    var displayName = ""
    var modeLabel = ""
    var typedText = ""
    var lastKey = "—"
    var modifiers = "—"
    var pointer = "—"
    var buttons = "—"
    var scroll = "—"
    var clipboard = "—"
    /// What the machine last saw of a drag of files, in words.
    var files = "—"
    var clicks: [PixelPoint] = []
    var frameCounter: UInt64 = 0
    /// The names under the folder and the file on the desktop; `nil` on a machine that knows no
    /// drags of files, whose desktop is bare.
    var desktopItems: DesktopItems?
    /// A viewer's drag is over the folder, which lights up as a Mac's folders do.
    var isFolderHighlighted = false
    /// The file is being dragged away: what stays behind is faint.
    var isFileLifted = false

    struct DesktopItems: Sendable, Equatable {
        var folder: String
        var file: String
    }
}

/// Where things lie on a simulated display, in its pixels. Shared by the canvas, which draws them,
/// and the machine, which reacts to the pointer over them.
struct SimulatedDesktopLayout {
    let pixelSize: PixelSize
    let unit: CGFloat

    init(pixelSize: PixelSize, scale: Double) {
        self.pixelSize = pixelSize
        unit = CGFloat(scale)
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height) }
    var menuBarHeight: CGFloat { 28 * unit }

    var counterRect: CGRect {
        CGRect(x: bounds.maxX - 220 * unit, y: 0, width: 220 * unit, height: menuBarHeight)
    }

    /// The desktop's folder and file: their pictures with their names under them.
    private var itemSize: CGSize { CGSize(width: 88 * unit, height: 84 * unit) }
    private var itemGap: CGFloat { 12 * unit }
    /// A display wide and tall enough has the two at its right edge, one under the other as on a
    /// Mac's desktop, and the panel keeps clear of them.
    private var hasItemColumn: Bool {
        bounds.width >= 560 * unit && bounds.height >= menuBarHeight + itemSize.height * 2 + itemGap * 3
    }

    var panelRect: CGRect {
        let margin = hasItemColumn ? itemSize.width + itemGap * 2 : 40 * unit
        let width = min(bounds.width - margin * 2, 620 * unit)
        let height = min(bounds.height - menuBarHeight - 160 * unit, 330 * unit)
        return CGRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: (menuBarHeight + (bounds.height - menuBarHeight - 90 * unit - height) / 2).rounded(),
            width: width,
            height: height
        )
    }

    var folderRect: CGRect { itemRects.folder }
    var fileRect: CGRect { itemRects.file }

    /// Top right. On a display too narrow for a column of its own (one shaped like an upright
    /// phone) the two sit side by side above the panel.
    private var itemRects: (folder: CGRect, file: CGRect) {
        let folder = CGRect(origin: CGPoint(x: bounds.maxX - itemGap - itemSize.width, y: menuBarHeight + itemGap), size: itemSize)
        if hasItemColumn { return (folder, folder.offsetBy(dx: 0, dy: itemSize.height + itemGap)) }
        return (folder, folder.offsetBy(dx: -(itemSize.width + itemGap), dy: 0))
    }

    static func pixelRect(_ rect: CGRect, in bounds: CGRect) -> PixelRect {
        let integral = rect.integral.intersection(bounds)
        return PixelRect(x: Int(integral.minX), y: Int(integral.minY), width: Int(integral.width), height: Int(integral.height))
    }
}

/// Draws one simulated display into a persistent bitmap and snapshots it into immutable pixel buffers.
///
/// Not thread-safe; owned by the session's render actor.
final class SimulatedCanvas {
    let pixelSize: PixelSize
    let scale: CGFloat
    /// Snapshots are 10-bit PQ, with the desktop's white at 100 nits as a Mac puts it.
    let isHDR: Bool
    private let context: CGContext
    /// The bitmap in 10-bit PQ, for an HDR display. Converted only where the bitmap changes:
    /// converting a whole display for every snapshot takes longer than a frame lasts.
    private let encoded: UnsafeMutableBufferPointer<UInt32>?
    private var drawn: SimulatedDesktopContent?

    init?(pixelSize: PixelSize, scale: Double, isHDR: Bool = false) {
        guard !pixelSize.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelSize.width,
                  height: pixelSize.height,
                  bitsPerComponent: 8,
                  bytesPerRow: pixelSize.width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        self.pixelSize = pixelSize
        self.scale = CGFloat(scale)
        self.isHDR = isHDR
        self.context = context
        encoded = isHDR ? .allocate(capacity: pixelSize.width * pixelSize.height) : nil
        context.translateBy(x: 0, y: CGFloat(pixelSize.height))
        context.scaleBy(x: 1, y: -1)
    }

    deinit {
        encoded?.deallocate()
    }

    // MARK: Layout

    private var layout: SimulatedDesktopLayout { SimulatedDesktopLayout(pixelSize: pixelSize, scale: Double(scale)) }
    private var unit: CGFloat { scale }
    private var bounds: CGRect { layout.bounds }
    private var menuBarHeight: CGFloat { layout.menuBarHeight }
    private var counterRect: CGRect { layout.counterRect }
    private var panelRect: CGRect { layout.panelRect }

    // MARK: Drawing

    /// Brings the bitmap up to date with `content` and returns what changed.
    func update(to content: SimulatedDesktopContent) -> DamageRegion {
        let damage = draw(content)
        for rectangle in damage.rectangles { encode(rectangle) }
        return damage
    }

    private func draw(_ content: SimulatedDesktopContent) -> DamageRegion {
        defer { drawn = content }
        guard let previous = drawn else {
            drawEverything(content)
            return .full(pixelSize)
        }
        if previous == content { return DamageRegion() }

        var backgroundChanged = previous
        backgroundChanged.frameCounter = content.frameCounter
        backgroundChanged.typedText = content.typedText
        backgroundChanged.lastKey = content.lastKey
        backgroundChanged.modifiers = content.modifiers
        backgroundChanged.pointer = content.pointer
        backgroundChanged.buttons = content.buttons
        backgroundChanged.scroll = content.scroll
        backgroundChanged.clipboard = content.clipboard
        backgroundChanged.files = content.files
        if backgroundChanged != content {
            // Display name, mode, click markers or the desktop's items changed: those live in the
            // background layer.
            drawEverything(content)
            return .full(pixelSize)
        }

        var damage = DamageRegion()
        var panelOnly = previous
        panelOnly.frameCounter = content.frameCounter
        if panelOnly != content {
            drawPanel(content)
            damage.add(pixelRect(panelRect))
        }
        if previous.frameCounter != content.frameCounter {
            drawCounter(content)
            damage.add(pixelRect(counterRect))
        }
        return damage
    }

    /// sRGB-encoded 8-bit values to 10-bit PQ code values, with white at 100 nits.
    private static let sRGBToPQ: [UInt32] = (0..<256).map { value in
        let encoded = Double(value) / 255
        let linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
        let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
        let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
        let power = pow(linear * 100 / 10_000, m1)
        return UInt32((pow((c1 + c2 * power) / (1 + c3 * power), m2) * 1023).rounded())
    }

    /// Converts one part of the bitmap for an HDR display's snapshots.
    private func encode(_ rectangle: PixelRect) {
        let rectangle = rectangle.intersection(PixelRect(size: pixelSize))
        guard !rectangle.isEmpty, let output = encoded?.baseAddress, let source = context.data else { return }
        let sourceStride = context.bytesPerRow
        Self.sRGBToPQ.withUnsafeBufferPointer { table in
            for row in rectangle.y..<rectangle.maxY {
                let input = (source + row * sourceStride + rectangle.x * 4).assumingMemoryBound(to: UInt8.self)
                let line = output + row * pixelSize.width + rectangle.x
                for column in 0..<rectangle.width {
                    // BGRA in, opaque; alpha is premultiplied but the desktop is opaque throughout.
                    let blue = table[Int(input[column * 4])]
                    let green = table[Int(input[column * 4 + 1])]
                    let red = table[Int(input[column * 4 + 2])]
                    line[column] = (3 << 30 | red << 20 | green << 10 | blue).littleEndian
                }
            }
        }
    }

    /// Copies the bitmap into a new immutable pixel buffer: 32-bit BGRA tagged sRGB, or for an HDR
    /// display 10-bit RGB tagged BT.709 primaries and PQ.
    func snapshot() -> CVReadOnlyPixelBuffer? {
        isHDR ? hdrSnapshot() : sdrSnapshot()
    }

    private func hdrSnapshot() -> CVReadOnlyPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, pixelSize.width, pixelSize.height, kCVPixelFormatType_ARGB2101010LEPacked,
            attributes as CFDictionary, &created
        )
        guard status == kCVReturnSuccess, let buffer = created, let source = UnsafeRawPointer(encoded?.baseAddress) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let destination = CVPixelBufferGetBaseAddress(buffer) {
            let sourceStride = pixelSize.width * 4
            let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
            if sourceStride == destinationStride {
                memcpy(destination, source, sourceStride * pixelSize.height)
            } else {
                for row in 0..<pixelSize.height {
                    memcpy(destination + row * destinationStride, source + row * sourceStride, sourceStride)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return .adopting(buffer)
    }

    private func sdrSnapshot() -> CVReadOnlyPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
        ]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            pixelSize.width,
            pixelSize.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &created
        )
        guard status == kCVReturnSuccess, let buffer = created, let source = context.data else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let destination = CVPixelBufferGetBaseAddress(buffer) {
            let sourceStride = context.bytesPerRow
            let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
            if sourceStride == destinationStride {
                memcpy(destination, source, sourceStride * pixelSize.height)
            } else {
                let rowBytes = min(sourceStride, destinationStride)
                for row in 0..<pixelSize.height {
                    memcpy(destination + row * destinationStride, source + row * sourceStride, rowBytes)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        return .adopting(buffer)
    }

    private func pixelRect(_ rect: CGRect) -> PixelRect {
        SimulatedDesktopLayout.pixelRect(rect, in: bounds)
    }

    private func drawEverything(_ content: SimulatedDesktopContent) {
        drawWallpaper()
        drawRulers()
        drawDesktopItems(content)
        drawClickMarkers(content.clicks)
        drawMenuBar(content)
        drawCounter(content)
        drawDock()
        drawPanel(content)
    }

    private func drawWallpaper() {
        let colors = [color(0.09, 0.16, 0.33), color(0.20, 0.42, 0.56), color(0.93, 0.62, 0.42)] as CFArray
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.6, 1])
        else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: bounds.width * 0.35, y: bounds.height),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    /// Tick marks every 100 pixels along the left and bottom edges, to check scaling and 1:1 zoom.
    private func drawRulers() {
        context.saveGState()
        context.setFillColor(color(1, 1, 1, 0.55))
        let tick = 10 * unit
        var x = 0
        while x <= pixelSize.width {
            let long = x % 500 == 0
            context.fill(CGRect(x: CGFloat(x), y: bounds.maxY - (long ? tick * 2 : tick), width: 1, height: long ? tick * 2 : tick))
            if long, x > 0 {
                drawText("\(x)", at: CGPoint(x: CGFloat(x) + 3 * unit, y: bounds.maxY - tick * 2 - 2 * unit), size: 9, color: color(1, 1, 1, 0.7))
            }
            x += 100
        }
        var y = 0
        while y <= pixelSize.height {
            let long = y % 500 == 0
            context.fill(CGRect(x: 0, y: CGFloat(y), width: long ? tick * 2 : tick, height: 1))
            if long, y > 0 {
                drawText("\(y)", at: CGPoint(x: tick * 2 + 3 * unit, y: CGFloat(y) - 6 * unit), size: 9, color: color(1, 1, 1, 0.7))
            }
            y += 100
        }
        context.restoreGState()
    }

    private func drawDesktopItems(_ content: SimulatedDesktopContent) {
        guard let items = content.desktopItems else { return }
        let iconSide = 48 * unit
        func draw(_ name: String, in cell: CGRect, highlighted: Bool, faint: Bool, picture: (CGContext, CGRect) -> Void) {
            context.saveGState()
            if highlighted {
                context.setFillColor(color(1, 1, 1, 0.3))
                context.addPath(CGPath(roundedRect: cell.insetBy(dx: 2 * unit, dy: 2 * unit), cornerWidth: 10 * unit, cornerHeight: 10 * unit, transform: nil))
                context.fillPath()
            }
            context.setAlpha(faint ? 0.35 : 1)
            picture(context, CGRect(x: cell.midX - iconSide / 2, y: cell.minY + 8 * unit, width: iconSide, height: iconSide))
            let width = textWidth(name, size: 11)
            drawText(name, at: CGPoint(x: cell.midX - min(width, cell.width) / 2, y: cell.minY + iconSide + 14 * unit), size: 11, color: color(1, 1, 1))
            context.restoreGState()
        }
        draw(items.folder, in: layout.folderRect, highlighted: content.isFolderHighlighted, faint: false, picture: SimulatedDesktopArt.drawFolder)
        draw(items.file, in: layout.fileRect, highlighted: false, faint: content.isFileLifted, picture: SimulatedDesktopArt.drawFile)
    }

    private func drawClickMarkers(_ clicks: [PixelPoint]) {
        context.saveGState()
        for (index, click) in clicks.enumerated() {
            let radius = 9 * unit
            let rect = CGRect(x: click.x - radius, y: click.y - radius, width: radius * 2, height: radius * 2)
            context.setStrokeColor(color(1, 1, 1, 0.9))
            context.setFillColor(color(1, 0.35, 0.3, 0.75))
            context.setLineWidth(2 * unit)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
            drawText("\(index + 1)", at: CGPoint(x: click.x + radius + 2 * unit, y: click.y - 7 * unit), size: 11, color: color(1, 1, 1))
        }
        context.restoreGState()
    }

    private func drawMenuBar(_ content: SimulatedDesktopContent) {
        context.saveGState()
        context.setFillColor(color(0.97, 0.97, 0.98))
        context.fill(CGRect(x: 0, y: 0, width: bounds.width, height: menuBarHeight))
        var x = 16 * unit
        for (index, title) in ["Demo", "File", "Edit", "View", "Window", "Help"].enumerated() {
            let width = drawText(title, at: CGPoint(x: x, y: 6 * unit), size: 13, color: color(0.1, 0.1, 0.12), bold: index == 0)
            x += width + 18 * unit
        }
        context.restoreGState()
    }

    private func drawCounter(_ content: SimulatedDesktopContent) {
        context.saveGState()
        context.setFillColor(color(0.97, 0.97, 0.98))
        context.fill(counterRect)
        let label = "frame \(content.frameCounter)"
        drawText(label, at: CGPoint(x: counterRect.minX + 12 * unit, y: 6 * unit), size: 13, color: color(0.1, 0.1, 0.12), monospaced: true)
        context.restoreGState()
    }

    private func drawDock() {
        let tile = 46 * unit
        let gap = 10 * unit
        let count = 6
        let width = CGFloat(count) * tile + CGFloat(count + 1) * gap
        let rect = CGRect(x: (bounds.width - width) / 2, y: bounds.maxY - tile - gap * 2 - 34 * unit, width: width, height: tile + gap * 2)
        guard rect.minX > 0 else { return }
        context.saveGState()
        context.setFillColor(color(1, 1, 1, 0.28))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 16 * unit, cornerHeight: 16 * unit, transform: nil))
        context.fillPath()
        let palette = [color(0.27, 0.6, 0.98), color(0.35, 0.8, 0.5), color(0.98, 0.75, 0.25), color(0.95, 0.4, 0.4), color(0.62, 0.48, 0.92), color(0.4, 0.42, 0.48)]
        for index in 0..<count {
            let tileRect = CGRect(x: rect.minX + gap + CGFloat(index) * (tile + gap), y: rect.minY + gap, width: tile, height: tile)
            context.setFillColor(palette[index])
            context.addPath(CGPath(roundedRect: tileRect, cornerWidth: 11 * unit, cornerHeight: 11 * unit, transform: nil))
            context.fillPath()
        }
        context.restoreGState()
    }

    private func drawPanel(_ content: SimulatedDesktopContent) {
        let rect = panelRect
        guard rect.width > 40, rect.height > 40 else { return }
        context.saveGState()
        // Repaint what is under the panel so translucency does not accumulate between updates.
        context.clip(to: rect)
        drawWallpaper()
        context.setFillColor(color(0.99, 0.99, 1.0, 0.94))
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: 14 * unit, cornerHeight: 14 * unit, transform: nil))
        context.fillPath()

        let titleHeight = 34 * unit
        let lights = [color(0.99, 0.37, 0.35), color(0.99, 0.74, 0.2), color(0.2, 0.78, 0.35)]
        for (index, light) in lights.enumerated() {
            context.setFillColor(light)
            context.fillEllipse(in: CGRect(x: rect.minX + 14 * unit + CGFloat(index) * 20 * unit, y: rect.minY + 11 * unit, width: 12 * unit, height: 12 * unit))
        }
        drawText("Input Echo — \(content.displayName)", at: CGPoint(x: rect.minX + 84 * unit, y: rect.minY + 9 * unit), size: 13, color: color(0.15, 0.15, 0.18), bold: true)
        context.setFillColor(color(0, 0, 0, 0.08))
        context.fill(CGRect(x: rect.minX, y: rect.minY + titleHeight, width: rect.width, height: 1))

        let rows: [(String, String)] = [
            ("Display", "\(pixelSize.width) × \(pixelSize.height) @\(Int(scale))x"),
            ("Mode", content.modeLabel),
            ("Typed", content.typedText.isEmpty ? "—" : String(content.typedText.suffix(48))),
            ("Last key", content.lastKey),
            ("Modifiers", content.modifiers),
            ("Pointer", content.pointer),
            ("Buttons", content.buttons),
            ("Scroll", content.scroll),
            ("Clipboard", content.clipboard),
            ("Files", content.files),
        ]
        var y = rect.minY + titleHeight + 14 * unit
        let lineHeight = max(20 * unit, (rect.height - titleHeight - 28 * unit) / CGFloat(rows.count))
        for (label, value) in rows where y + 16 * unit < rect.maxY {
            drawText(label, at: CGPoint(x: rect.minX + 22 * unit, y: y), size: 13, color: color(0.42, 0.44, 0.5))
            drawText(value, at: CGPoint(x: rect.minX + 130 * unit, y: y), size: 13, color: color(0.1, 0.1, 0.14), monospaced: true)
            y += lineHeight
        }
        context.restoreGState()
    }

    // MARK: Primitives

    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private func line(
        _ string: String,
        size: CGFloat,
        color: CGColor,
        bold: Bool = false,
        monospaced: Bool = false
    ) -> CTLine {
        let pointSize = size * unit
        let uiType: CTFontUIFontType = monospaced ? .userFixedPitch : (bold ? .emphasizedSystem : .system)
        let font = CTFontCreateUIFontForLanguage(uiType, pointSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    private func textWidth(_ string: String, size: CGFloat) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(string, size: size, color: color(0, 0, 0)), nil, nil, nil))
    }

    /// Draws a single line of text with its top-left corner at `origin`. Returns the advance width.
    @discardableResult
    private func drawText(
        _ string: String,
        at origin: CGPoint,
        size: CGFloat,
        color: CGColor,
        bold: Bool = false,
        monospaced: Bool = false
    ) -> CGFloat {
        let line = line(string, size: size, color: color, bold: bold, monospaced: monospaced)
        var ascent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
        context.saveGState()
        // The context is flipped; flip glyphs back so they are upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: origin.x, y: origin.y + ascent)
        CTLineDraw(line, context)
        context.restoreGState()
        return width
    }
}

/// The pictures of the desktop's folder and file. Drawn into a context whose origin is top left.
enum SimulatedDesktopArt {
    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    static func drawFolder(in context: CGContext, rect: CGRect) {
        let side = rect.width
        let body = CGRect(x: rect.minX, y: rect.minY + side * 0.22, width: side, height: side * 0.66)
        let tab = CGRect(x: rect.minX, y: rect.minY + side * 0.1, width: side * 0.42, height: side * 0.3)
        context.setFillColor(color(0.2, 0.52, 0.9))
        context.addPath(CGPath(roundedRect: tab, cornerWidth: side * 0.07, cornerHeight: side * 0.07, transform: nil))
        context.fillPath()
        context.setFillColor(color(0.36, 0.68, 0.98))
        context.addPath(CGPath(roundedRect: body, cornerWidth: side * 0.09, cornerHeight: side * 0.09, transform: nil))
        context.fillPath()
    }

    static func drawFile(in context: CGContext, rect: CGRect) {
        let side = rect.width
        let page = CGRect(x: rect.minX + side * 0.16, y: rect.minY + side * 0.04, width: side * 0.68, height: side * 0.92)
        let fold = side * 0.22
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: page.minX, y: page.minY))
        outline.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY))
        outline.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
        outline.addLine(to: CGPoint(x: page.maxX, y: page.maxY))
        outline.addLine(to: CGPoint(x: page.minX, y: page.maxY))
        outline.closeSubpath()
        context.setFillColor(color(0.98, 0.98, 1))
        context.addPath(outline)
        context.fillPath()
        context.setFillColor(color(0.78, 0.8, 0.86))
        context.move(to: CGPoint(x: page.maxX - fold, y: page.minY))
        context.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
        context.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY + fold))
        context.closePath()
        context.fillPath()
        context.setFillColor(color(0.62, 0.65, 0.72))
        for row in 0..<4 {
            let y = page.minY + fold + side * 0.12 + CGFloat(row) * side * 0.13
            context.fill(CGRect(x: page.minX + side * 0.1, y: y, width: page.width - side * (row == 3 ? 0.36 : 0.2), height: side * 0.045))
        }
    }

    /// The file's picture as PNG: what the machine shows under its pointer while the file is dragged.
    static func filePNG(scale: Double) -> Data? {
        let side = Int(64 * scale)
        guard side > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: side * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        drawFile(in: context, rect: CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// A plain arrow, used as the simulated remote pointer.
enum SimulatedCursor {
    static func arrow(scale: Double) -> CursorImage? {
        let side = Int(24 * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: side * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        let unit = CGFloat(scale)
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: unit, y: -unit)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2, y: 1))
        path.addLine(to: CGPoint(x: 2, y: 18))
        path.addLine(to: CGPoint(x: 6.5, y: 14))
        path.addLine(to: CGPoint(x: 9.5, y: 21))
        path.addLine(to: CGPoint(x: 12.5, y: 19.7))
        path.addLine(to: CGPoint(x: 9.6, y: 13))
        path.addLine(to: CGPoint(x: 15.5, y: 13))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1))
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(1.2)
        context.setLineJoin(.round)
        context.strokePath()
        guard let data = context.data else { return nil }
        return CursorImage(
            id: UInt64(side),
            pixelSize: PixelSize(width: side, height: side),
            bgraPixels: Data(bytes: data, count: side * side * 4),
            hotspot: PixelPoint(x: 2 * scale, y: 1 * scale),
            scale: scale
        )
    }
}
