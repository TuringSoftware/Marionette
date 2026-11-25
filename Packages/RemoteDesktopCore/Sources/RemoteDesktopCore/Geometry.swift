// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

/// A size in remote framebuffer pixels.
public struct PixelSize: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let zero = PixelSize(width: 0, height: 0)

    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// A position in remote pixels. Fractional so that scaled pointer input keeps sub-pixel precision
/// until the back end rounds it for the wire.
public struct PixelPoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = PixelPoint(x: 0, y: 0)
}

/// An integral rectangle in remote pixels.
public struct PixelRect: Sendable, Hashable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: (x: Int, y: Int) = (0, 0), size: PixelSize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public var size: PixelSize { PixelSize(width: width, height: height) }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var area: Int { isEmpty ? 0 : width * height }

    public func contains(_ point: PixelPoint) -> Bool {
        point.x >= Double(x) && point.x < Double(maxX) && point.y >= Double(y) && point.y < Double(maxY)
    }

    public func contains(_ other: PixelRect) -> Bool {
        other.isEmpty || (other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY)
    }

    public func intersects(_ other: PixelRect) -> Bool {
        !intersection(other).isEmpty
    }

    public func intersection(_ other: PixelRect) -> PixelRect {
        let left = max(x, other.x)
        let top = max(y, other.y)
        let right = min(maxX, other.maxX)
        let bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return PixelRect(x: left, y: top, width: 0, height: 0) }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The smallest rectangle containing both. An empty rectangle contributes nothing.
    public func union(_ other: PixelRect) -> PixelRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let left = min(x, other.x)
        let top = min(y, other.y)
        return PixelRect(x: left, y: top, width: max(maxX, other.maxX) - left, height: max(maxY, other.maxY) - top)
    }
}

/// The set of pixels that changed between two frames of a display surface.
///
/// Kept as a short list of rectangles. When the list grows past ``maximumRectangles`` it collapses to its
/// bounding box, so merging damage from many skipped frames stays cheap and bounded.
public struct DamageRegion: Sendable, Hashable {
    public static let maximumRectangles = 16

    public private(set) var rectangles: [PixelRect]

    public init() {
        rectangles = []
    }

    public init(_ rectangle: PixelRect) {
        rectangles = rectangle.isEmpty ? [] : [rectangle]
    }

    public init(_ rectangles: some Sequence<PixelRect>) {
        self.init()
        for rectangle in rectangles { add(rectangle) }
    }

    public static func full(_ size: PixelSize) -> DamageRegion {
        DamageRegion(PixelRect(size: size))
    }

    public var isEmpty: Bool { rectangles.isEmpty }

    public var bounds: PixelRect {
        rectangles.reduce(PixelRect(x: 0, y: 0, width: 0, height: 0)) { $0.union($1) }
    }

    public mutating func add(_ rectangle: PixelRect) {
        guard !rectangle.isEmpty else { return }
        if rectangles.contains(where: { $0.contains(rectangle) }) { return }
        rectangles.removeAll { rectangle.contains($0) }
        rectangles.append(rectangle)
        if rectangles.count > Self.maximumRectangles {
            rectangles = [bounds]
        }
    }

    public mutating func formUnion(_ other: DamageRegion) {
        for rectangle in other.rectangles { add(rectangle) }
    }

    public func union(_ other: DamageRegion) -> DamageRegion {
        var copy = self
        copy.formUnion(other)
        return copy
    }

    /// Clips every rectangle to `bounds`, dropping the ones that fall outside.
    public func clipped(to bounds: PixelRect) -> DamageRegion {
        DamageRegion(rectangles.map { $0.intersection(bounds) })
    }
}
