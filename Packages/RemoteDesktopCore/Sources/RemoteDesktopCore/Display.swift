// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

/// Stable identity of a remote display for the lifetime of a session.
public struct DisplayID: Sendable, Hashable, Codable, CustomStringConvertible {
    public var rawValue: UInt32

    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public var description: String { "display-\(rawValue)" }
}

/// One display of the remote desktop.
public struct RemoteDisplay: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A monitor attached to the remote machine.
        case physical
        /// A display created for this session (for example a High Performance virtual display).
        case virtual
    }

    public enum State: Sendable, Hashable {
        /// Frames are flowing.
        case live
        /// A resize or mode change is in flight; the last frame stays valid until the next layout.
        case reconfiguring
        /// The display exists but this session is not receiving it.
        case unavailable
    }

    public var id: DisplayID
    public var name: String
    public var kind: Kind
    public var state: State
    /// Position and size inside the remote desktop, in pixels.
    public var frameInDesktop: PixelRect
    /// Backing scale of the remote display (2 for HiDPI). Pixel size divided by scale gives points.
    public var scale: Double
    public var isHDR: Bool

    public init(
        id: DisplayID,
        name: String,
        kind: Kind,
        state: State = .live,
        frameInDesktop: PixelRect,
        scale: Double = 1,
        isHDR: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.state = state
        self.frameInDesktop = frameInDesktop
        self.scale = scale
        self.isHDR = isHDR
    }

    public var pixelSize: PixelSize { frameInDesktop.size }
}

/// An atomic snapshot of every display in the session.
///
/// `generation` increases whenever the set of displays, or any display's geometry, changes. Pointer
/// events carry the generation they were computed against so a back end can discard input aimed at a
/// layout that no longer exists.
public struct DesktopLayout: Sendable, Hashable {
    public var generation: UInt64
    public var displays: [RemoteDisplay]

    public init(generation: UInt64, displays: [RemoteDisplay]) {
        self.generation = generation
        self.displays = displays
    }

    public static let empty = DesktopLayout(generation: 0, displays: [])

    public subscript(id: DisplayID) -> RemoteDisplay? {
        displays.first { $0.id == id }
    }

    /// Bounding box of every display, in desktop pixels.
    public var bounds: PixelRect {
        displays.reduce(PixelRect(x: 0, y: 0, width: 0, height: 0)) { $0.union($1.frameInDesktop) }
    }

    public func display(at desktopPoint: PixelPoint) -> RemoteDisplay? {
        displays.first { $0.frameInDesktop.contains(desktopPoint) }
    }
}
