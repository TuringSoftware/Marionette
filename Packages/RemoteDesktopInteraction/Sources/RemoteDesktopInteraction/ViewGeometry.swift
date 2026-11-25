// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

// Geometry of the local view, in points. Deliberately not CoreGraphics so the package stays pure
// Swift. Edges are physical (left/right), never leading/trailing: a remote desktop does not mirror.

/// A position in the local view, in points, origin top-left.
public struct ViewPoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = ViewPoint(x: 0, y: 0)

    public func distance(to other: ViewPoint) -> Double {
        (self - other).length
    }

    public func midpoint(to other: ViewPoint) -> ViewPoint {
        ViewPoint(x: (x + other.x) / 2, y: (y + other.y) / 2)
    }

    public static func - (lhs: ViewPoint, rhs: ViewPoint) -> ViewVector {
        ViewVector(dx: lhs.x - rhs.x, dy: lhs.y - rhs.y)
    }

    public static func + (lhs: ViewPoint, rhs: ViewVector) -> ViewPoint {
        ViewPoint(x: lhs.x + rhs.dx, y: lhs.y + rhs.dy)
    }
}

/// A displacement or velocity in the local view, in points.
public struct ViewVector: Sendable, Hashable, Codable {
    public var dx: Double
    public var dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    public static let zero = ViewVector(dx: 0, dy: 0)

    public var length: Double { (dx * dx + dy * dy).squareRoot() }

    public static func * (lhs: ViewVector, rhs: Double) -> ViewVector {
        ViewVector(dx: lhs.dx * rhs, dy: lhs.dy * rhs)
    }

    public static func + (lhs: ViewVector, rhs: ViewVector) -> ViewVector {
        ViewVector(dx: lhs.dx + rhs.dx, dy: lhs.dy + rhs.dy)
    }
}

public struct ViewSize: Sendable, Hashable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = ViewSize(width: 0, height: 0)

    /// True when either dimension is zero, negative or not a finite number.
    public var isEmpty: Bool {
        !(width.isFinite && height.isFinite && width > 0 && height > 0)
    }
}

/// Distances from each edge of a view.
public struct ViewInsets: Sendable, Hashable, Codable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = ViewInsets()

    /// The larger inset on every edge.
    public func union(_ other: ViewInsets) -> ViewInsets {
        ViewInsets(
            top: max(top, other.top),
            left: max(left, other.left),
            bottom: max(bottom, other.bottom),
            right: max(right, other.right)
        )
    }
}

public struct ViewRect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: ViewPoint = .zero, size: ViewSize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let zero = ViewRect(x: 0, y: 0, width: 0, height: 0)

    public var origin: ViewPoint { ViewPoint(x: x, y: y) }
    public var size: ViewSize { ViewSize(width: width, height: height) }
    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: ViewPoint { ViewPoint(x: midX, y: midY) }

    /// Edges are inclusive, so a touch exactly on the border counts as inside.
    public func contains(_ point: ViewPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    /// Shrinks the rectangle. Insets larger than the rectangle leave a zero-sized one rather than a
    /// negative size.
    public func inset(by insets: ViewInsets) -> ViewRect {
        let newWidth = max(0, width - insets.left - insets.right)
        let newHeight = max(0, height - insets.top - insets.bottom)
        return ViewRect(
            x: x + min(insets.left, width),
            y: y + min(insets.top, height),
            width: newWidth,
            height: newHeight
        )
    }
}
