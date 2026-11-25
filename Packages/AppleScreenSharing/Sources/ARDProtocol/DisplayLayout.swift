// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

/// Which screens a Mac has, which it is sending, and at what size. Sent whenever that changes,
/// including at every login, lock and user switch. It is authoritative: a display selection or
/// resize has happened only when a layout says so.
public struct DisplayLayout: Sendable, Equatable {
    public struct Flags: OptionSet, Sendable, Hashable {
        public var rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// The session is drawn on a virtual display, or off the console (curtained).
        public static let onVirtualDisplay = Flags(rawValue: 0x01)
        /// Curtain mode: may be turned on, or is on (see ``DisplayLayout/curtainState``).
        public static let curtain = Flags(rawValue: 0x02)
        public static let onConsole = Flags(rawValue: 0x04)
        public static let lockScreen = Flags(rawValue: 0x08)
        public static let loginWindow = Flags(rawValue: 0x10)
    }

    public struct Screen: Sendable, Equatable {
        public struct Flags: OptionSet, Sendable, Hashable {
            public var rawValue: UInt32

            public init(rawValue: UInt32) {
                self.rawValue = rawValue
            }

            public static let main = Flags(rawValue: 0x01)
            public static let inMirrorSet = Flags(rawValue: 0x02)
            public static let dynamicVirtual = Flags(rawValue: 0x04)
        }

        public var id: UInt32
        /// Native density, 1 or 2. Derived from the bounds when the Mac states none.
        public var density: Double
        /// Server-side scaling in force, 1 unless the viewer asked for less.
        public var serverScale: Double
        /// Bounds in points within the Mac's arrangement.
        public var pointLeft: Int
        public var pointTop: Int
        public var pointWidth: Int
        public var pointHeight: Int
        /// Bounds in framebuffer pixels: where this screen sits in what is being sent.
        public var pixelLeft: Int
        public var pixelTop: Int
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var flags: Flags
    }

    public var version: UInt16
    /// The whole desktop, in points.
    public var desktopPointWidth: Int
    public var desktopPointHeight: Int
    /// The framebuffer being sent, in pixels. Changes with the selection.
    public var framebufferWidth: Int
    public var framebufferHeight: Int
    /// The screen being sent, or `nil` for all of them combined.
    public var currentScreen: UInt32?
    public var flags: Flags
    public var screens: [Screen]

    static let headerLength = 0x14
    static let recordLength = 0x38
    static let maximumScreens = 25
    /// The most pixels a framebuffer may have: 64 M, 256 MB at four bytes each. Three 6K displays side
    /// by side come to 61 M. The fields allow 65535 × 65535, which a device could not hold.
    static let maximumFramebufferPixels = 1 << 26

    /// The session flags, which every other field's byte order (big-endian) gives. Rootshell found
    /// macOS releases that wrote them little-endian; macOS 27 writes them big-endian (`0x5`). Every
    /// defined flag is in the low byte, so a big-endian reading with bits only above it is taken as
    /// the other order, and a reading that makes sense is never touched.
    static func plausibleFlags(_ raw: UInt32) -> UInt32 {
        let swapped = raw.byteSwapped
        return raw & ~0xff != 0 && swapped & ~0xff == 0 ? swapped : raw
    }

    /// One physical screen filling a framebuffer of this size: what a server that sends no layout
    /// of its own (an older Mac, or one only speaking DesktopSize) amounts to.
    public static func single(width: Int, height: Int) -> DisplayLayout {
        DisplayLayout(
            version: 0, desktopPointWidth: width, desktopPointHeight: height,
            framebufferWidth: width, framebufferHeight: height, currentScreen: nil, flags: [],
            screens: [Screen(
                id: 0, density: 1, serverScale: 1, pointLeft: 0, pointTop: 0, pointWidth: width, pointHeight: height,
                pixelLeft: 0, pixelTop: 0, pixelWidth: width, pixelHeight: height, flags: .main
            )]
        )
    }

    /// Parses a layout payload: what follows the `u16` length that leads the rectangle body.
    ///
    /// A layout that cannot be used (no screens, none usable, an empty framebuffer) is an error here;
    /// the server-message parser steps over it, since its length still frames it, and the Mac sends
    /// a fresh layout with every change.
    public static func parse(_ reader: inout WireReader) throws(WireError) -> DisplayLayout {
        guard reader.remaining >= headerLength else {
            throw .malformed("display layout of \(reader.remaining) bytes")
        }
        let version = try reader.u16()
        let desktopWidth = Int(try reader.u16())
        let desktopHeight = Int(try reader.u16())
        let framebufferWidth = Int(try reader.u16())
        let framebufferHeight = Int(try reader.u16())
        let current = try reader.u32()
        let flags = Flags(rawValue: plausibleFlags(try reader.u32()))
        let count = Int(try reader.u16())
        guard (1...maximumScreens).contains(count) else { throw .malformed("display layout lists \(count) screens") }
        guard reader.remaining >= count * recordLength else {
            throw .malformed("display layout lists \(count) screens in \(reader.remaining) bytes")
        }
        guard framebufferWidth > 0, framebufferHeight > 0, framebufferWidth * framebufferHeight <= maximumFramebufferPixels else {
            throw .malformed("display layout gives a \(framebufferWidth)x\(framebufferHeight) framebuffer")
        }

        var screens: [Screen] = []
        var mirrorOrigins: [[Int]] = []
        for _ in 0..<count {
            var record = try reader.sub(recordLength)
            let statedDensity = try record.f64()
            var serverScale = try record.f64()
            let id = try record.u32()
            // Bounds are edges (top, left, bottom, right), signed: a screen left of or above the
            // main one has negative edges.
            let points = (top: Int(try record.i16()), left: Int(try record.i16()), bottom: Int(try record.i16()), right: Int(try record.i16()))
            let pixels = (top: Int(try record.i16()), left: Int(try record.i16()), bottom: Int(try record.i16()), right: Int(try record.i16()))
            let screenFlags = Screen.Flags(rawValue: try record.u32())

            let pointWidth = points.right - points.left
            let pointHeight = points.bottom - points.top
            let pixelWidth = pixels.right - pixels.left
            let pixelHeight = pixels.bottom - pixels.top
            // One unusable record must not cost the whole layout: one arrives at every login.
            guard pointWidth > 0, pointHeight > 0, pixelWidth > 0, pixelHeight > 0 else { continue }
            // Members of a mirror set show the same picture; keep the first.
            if screenFlags.contains(.inMirrorSet) {
                let origin = [points.left, points.top]
                if mirrorOrigins.contains(origin) { continue }
                mirrorOrigins.append(origin)
            }
            if !(serverScale.isFinite && serverScale > 0 && serverScale <= 1) { serverScale = 1 }
            var density = statedDensity
            if !(density.isFinite && density >= 1 && density <= 4) {
                // The Mac writes 0 when it cannot look the mode up; the bounds still say.
                density = (Double(pixelWidth) / Double(pointWidth) / serverScale).rounded()
                guard density >= 1, density <= 4 else { continue }
            }
            screens.append(
                Screen(
                    id: id, density: density, serverScale: serverScale,
                    pointLeft: points.left, pointTop: points.top, pointWidth: pointWidth, pointHeight: pointHeight,
                    pixelLeft: pixels.left, pixelTop: pixels.top, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                    flags: screenFlags
                )
            )
        }
        guard !screens.isEmpty else { throw .malformed("display layout lists no usable screen") }
        return DisplayLayout(
            version: version,
            desktopPointWidth: desktopWidth, desktopPointHeight: desktopHeight,
            framebufferWidth: framebufferWidth, framebufferHeight: framebufferHeight,
            currentScreen: current == .max ? nil : current,
            flags: flags, screens: screens
        )
    }
}
