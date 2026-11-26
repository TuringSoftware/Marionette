// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation

/// Client-to-server message type bytes.
public enum ClientMessageType {
    public static let setPixelFormat: UInt8 = 0x00
    public static let setEncodings: UInt8 = 0x02
    public static let framebufferUpdateRequest: UInt8 = 0x03
    public static let keyEvent: UInt8 = 0x04
    public static let pointerEvent: UInt8 = 0x05
    public static let setServerScaling: UInt8 = 0x08
    public static let autoFramebufferUpdate: UInt8 = 0x09
    public static let setMode: UInt8 = 0x0a
    public static let pasteboardFetch: UInt8 = 0x0b
    /// Curtain mode on or off (``Curtain``).
    public static let setSessionVisibility: UInt8 = 0x0c
    public static let setDisplay: UInt8 = 0x0d
    /// Asks what the drag now held on the Mac carries: `0e 00 00 00`, a token. The Mac answers
    /// with its drag and cancels it there, so it is only for taking a drag over. This client
    /// goes by what the Mac announces unasked instead.
    public static let dragRequest: UInt8 = 0x0e
    /// A key or pointer event in one encrypted block (``EncryptedInputEvent``).
    public static let encryptedInputEvent: UInt8 = 0x10
    public static let setEncryption: UInt8 = 0x12
    public static let autoPasteboard: UInt8 = 0x15
    /// The second event message; a scroll is one kind of it.
    public static let event2: UInt8 = 0x17
    public static let mediaOffer: UInt8 = 0x1c
    public static let setDisplayConfiguration: UInt8 = 0x1d
    public static let pasteboardData: UInt8 = 0x1f
    /// A drag entering the Mac's picture, or the end of one. The Mac sends the same type.
    public static let dragPasteboard: UInt8 = 0x20
    public static let viewerInfo: UInt8 = 0x21
    /// Native file transfer; the Mac sends the same type.
    public static let fileTransfer: UInt8 = 0x22
    /// A touch screen report for one of the Mac's displays (``ClientMessage/hidReport(display:report:)``).
    /// A Mac lists it from macOS 27.3.
    public static let hidReport: UInt8 = 0x26
}

/// The kinds of ``ClientMessageType/event2`` (the `u16` after the length and version).
public enum EventMessageKind: UInt16, Sendable, CaseIterable {
    case gestureBegin = 1
    case gestureEnd = 2
    case gestureMagnify = 3
    case gestureSmartMagnify = 4
    case gestureRotate = 5
    case gesturePageSwipe = 6
    case gestureLookUp = 7
    case gestureScroll = 8
    case scrollWheel = 11
}

/// The scroll-wheel message's flags word; the Mac sets one CGEvent field per bit.
public struct ScrollFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    /// Field 14, "instant mouser".
    public static let instantMouser = ScrollFlags(rawValue: 1 << 0)
    /// Field 88: deltas are precise distances (trackpad), not wheel notches.
    public static let continuous = ScrollFlags(rawValue: 1 << 1)
    /// Field 137: the deltas run opposite to the fingers' movement on the device.
    public static let directionInvertedFromDevice = ScrollFlags(rawValue: 1 << 2)
}

/// A scroll's phase, as the Mac's scroll-phase field takes it (CGScrollPhase).
public enum ScrollPhase: UInt32, Sendable {
    case none = 0
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
    case mayBegin = 128
}

/// The inertia after the fingers lift, as the Mac's momentum-phase field takes it (CGMomentumScrollPhase).
public enum MomentumPhase: UInt32, Sendable {
    case none = 0
    case begin = 1
    case `continue` = 2
    case end = 3
}

/// A gesture's phase as the Mac's gesture-phase field (132) takes it: IOHID phase bits.
public enum GesturePhase: UInt64, Sendable {
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
    case mayBegin = 128

    /// What the Mac itself puts in field 133 when a magnify or rotate message has no mask.
    public static let defaultMask: UInt64 = 4
}

/// The fields of a fluid page swipe, named as Screen Sharing.app logs them.
public struct PageSwipe: Sendable, Hashable {
    public var motion: UInt32
    public var swipeMask: UInt32
    public var progress: Float
    public var positionX: Float
    public var positionY: Float
    public var velocityX: Float
    public var velocityY: Float
    public var velocityZ: Float
    public var flags: UInt32
    public var flavor: UInt32

    public init(
        motion: UInt32, swipeMask: UInt32, progress: Float, positionX: Float = 0, positionY: Float = 0,
        velocityX: Float = 0, velocityY: Float = 0, velocityZ: Float = 0, flags: UInt32 = 0, flavor: UInt32 = 0
    ) {
        self.motion = motion
        self.swipeMask = swipeMask
        self.progress = progress
        self.positionX = positionX
        self.positionY = positionY
        self.velocityX = velocityX
        self.velocityY = velocityY
        self.velocityZ = velocityZ
        self.flags = flags
        self.flavor = flavor
    }
}

/// Server-to-client message type bytes beyond RFB's own.
public enum ServerMessageType {
    public static let status: UInt8 = 0x14
    public static let accessibility: UInt8 = 0x15
    public static let dropDestination: UInt8 = 0x1e
    public static let pasteboardData: UInt8 = 0x1f
    public static let dragPasteboard: UInt8 = 0x20
    public static let fileTransfer: UInt8 = 0x22
    public static let userRequest: UInt8 = 0x23
    public static let systemInfo: UInt8 = 0x51
}

/// Framebuffer encodings and pseudo-encodings.
public struct Encoding: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let raw = Encoding(rawValue: 0)
    public static let zlib = Encoding(rawValue: 6)
    public static let zrle = Encoding(rawValue: 16)
    public static let desktopSize = Encoding(rawValue: -223)
    public static let lastRect = Encoding(rawValue: -224)

    /// Apple: RGB 5-5-5 through zlib.
    public static let appleHalftone555 = Encoding(rawValue: 0x3ea)
    /// Apple: messages about the media stream travel as rectangles of this encoding.
    public static let appleMediaStream = Encoding(rawValue: 0x3f2)
    /// Apple: 8×8 transform-coded tiles, the picture of Adaptive quality.
    public static let appleAdaptive = Encoding(rawValue: 0x3f3)
    public static let appleCursorPosition = Encoding(rawValue: 0x44c)
    public static let appleDisplayInfo = Encoding(rawValue: 0x44d)
    public static let appleUserInfo = Encoding(rawValue: 0x44e)
    public static let appleRekey = Encoding(rawValue: 0x44f)
    public static let appleCursorImage = Encoding(rawValue: 0x450)
    public static let appleDisplayLayout = Encoding(rawValue: 0x451)
    public static let appleVendorKeysyms = Encoding(rawValue: 0x453)
    public static let appleKeyboardSource = Encoding(rawValue: 0x455)
    public static let appleDeviceInfo = Encoding(rawValue: 0x456)

    public var description: String {
        rawValue >= 0 ? String(format: "0x%x", rawValue) : "\(rawValue)"
    }

    /// What every Apple session lists besides its picture codec. Each one is either decoded or
    /// stepped over by its own framing; a Mac sends whatever it finds listed.
    static let appleMetadata: [Encoding] = [
        .raw, .appleCursorPosition, .appleDisplayInfo, .appleRekey, .appleCursorImage,
        .appleDisplayLayout, .appleVendorKeysyms, .appleKeyboardSource, .desktopSize, .lastRect,
    ]

    /// The list for Standard mode at Full quality: zlib alone, so the Mac sends lossless zlib and
    /// has no codec in reserve that this client cannot decode.
    public static let standardFull: [Encoding] = appleMetadata + [.zlib]
    /// The list for Standard mode at Adaptive quality: the Mac's 8×8 tiles first. A Mac codes every
    /// rectangle with the first picture codec listed and keeps the last lossless one in reserve,
    /// so zlib, which this client decodes, is the only other one named.
    public static let standardAdaptive: [Encoding] = appleMetadata + [.appleAdaptive, .zlib]
    /// The list for High Performance: the media stream first, which also stops pixel repaints.
    public static let highPerformance: [Encoding] = [.appleMediaStream] + appleMetadata + [.zrle]
}

/// How much authority the viewer asks for.
public enum ViewerMode: UInt16, Sendable {
    case observe = 0
    case control = 1
    /// Control with the Mac's own keyboard and mouse inhibited.
    case exclusiveControl = 2
}

/// Builders for everything the viewer sends. Each returns the complete message.
public enum ClientMessage {
    /// An Apple control message: type, a reserved byte, the body's length, the body.
    static func framed(_ type: UInt8, body: Data) -> Data {
        precondition(body.count <= Int(UInt16.max), "control message body exceeds its length field")
        var writer = WireWriter(capacity: 4 + body.count)
        writer.u8(type)
        writer.u8(0)
        writer.u16(UInt16(body.count))
        writer.bytes(body)
        return writer.data
    }

    public static func clientInit(_ flags: ClientInitFlags) -> Data {
        Data([flags.rawValue])
    }

    public static func setPixelFormat(_ format: PixelFormat) -> Data {
        var writer = WireWriter(capacity: 20)
        writer.u8(ClientMessageType.setPixelFormat)
        writer.zeros(3)
        format.write(to: &writer)
        return writer.data
    }

    public static func setEncodings(_ encodings: [Encoding]) -> Data {
        var writer = WireWriter(capacity: 4 + encodings.count * 4)
        writer.u8(ClientMessageType.setEncodings)
        writer.u8(0)
        writer.u16(UInt16(encodings.count))
        for encoding in encodings { writer.i32(encoding.rawValue) }
        return writer.data
    }

    public static func framebufferUpdateRequest(incremental: Bool, x: UInt16, y: UInt16, width: UInt16, height: UInt16) -> Data {
        var writer = WireWriter(capacity: 10)
        writer.u8(ClientMessageType.framebufferUpdateRequest)
        writer.u8(incremental ? 1 : 0)
        writer.u16(x)
        writer.u16(y)
        writer.u16(width)
        writer.u16(height)
        return writer.data
    }

    public static func keyEvent(keysym: UInt32, isDown: Bool) -> Data {
        var writer = WireWriter(capacity: 8)
        writer.u8(ClientMessageType.keyEvent)
        writer.u8(isDown ? 1 : 0)
        writer.u16(0)
        writer.u32(keysym)
        return writer.data
    }

    /// `buttonMask` is in Apple's numbering on this revision: bit 0 left, bit 1 right, bit 2 centre.
    public static func pointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) -> Data {
        var writer = WireWriter(capacity: 6)
        writer.u8(ClientMessageType.pointerEvent)
        writer.u8(buttonMask)
        writer.u16(x)
        writer.u16(y)
        return writer.data
    }

    /// A scroll by a distance, at the pointer.
    ///
    /// `deltaX`/`deltaY` are in points with the Mac's sign: positive scrolls up and to the left.
    /// `phase` is a ``ScrollPhase`` raw value, `momentumPhase` a ``MomentumPhase`` one. The Mac turns
    /// the message into a scroll-wheel CGEvent field by field (see the protocol notes).
    public static func scroll(
        deltaX: Int32, deltaY: Int32, x: UInt16, y: UInt16,
        phase: UInt32 = 0, momentumPhase: UInt32 = 0, flags: ScrollFlags = .continuous
    ) -> Data {
        let pointsPerLine: Int32 = 10
        let axes = [deltaX, deltaY, 0]
        var writer = WireWriter(capacity: 58)
        writer.u8(ClientMessageType.event2)
        writer.u8(0)
        writer.u16(54)
        writer.u16(1) // version
        writer.u16(EventMessageKind.scrollWheel.rawValue)
        for points in axes { writer.i16(Int16(clamping: points / pointsPerLine)) }
        for points in axes { writer.i32(Int32(clamping: Int64(points) * 65536 / Int64(pointsPerLine))) }
        for points in axes { writer.i32(points) }
        writer.u32(phase)
        writer.u32(momentumPhase)
        writer.u32(0) // scroll count
        writer.u32(flags.rawValue)
        writer.u16(x)
        writer.u16(y)
        return writer.data
    }

    // MARK: Trackpad gestures
    //
    // Each is a kind of ``ClientMessageType/event2`` with Screen Sharing.app's exact layout
    // (`RFBPostGestureEvent*` in ScreenSharing.framework); the Mac posts a gesture CGEvent
    // (type 29) for each. Positions are the pointer's, as in a pointer event.

    /// Opens a gesture series. `seriesType` goes to the Mac's gesture-series field (117).
    public static func gestureBegin(seriesType: UInt32, x: UInt16, y: UInt16) -> Data {
        gestureBracket(.gestureBegin, seriesType: seriesType, x: x, y: y)
    }

    /// Closes a gesture series opened with ``gestureBegin(seriesType:x:y:)``.
    public static func gestureEnd(seriesType: UInt32, x: UInt16, y: UInt16) -> Data {
        gestureBracket(.gestureEnd, seriesType: seriesType, x: x, y: y)
    }

    private static func gestureBracket(_ kind: EventMessageKind, seriesType: UInt32, x: UInt16, y: UInt16) -> Data {
        var writer = eventHeader(kind, bodyLength: 12, version: 1)
        writer.u32(seriesType)
        writer.u16(x)
        writer.u16(y)
        return writer.data
    }

    /// Pinch. `magnification` is the change since the previous event (0.1 = 10 % larger).
    /// `phase` is a ``GesturePhase`` raw value; `mask` goes to the Mac's field 133.
    public static func gestureMagnify(_ magnification: Double, phase: UInt64, mask: UInt64 = GesturePhase.defaultMask, x: UInt16, y: UInt16) -> Data {
        twoFingerGesture(.gestureMagnify, value: magnification, phase: phase, mask: mask, x: x, y: y)
    }

    /// Two-finger rotation by `degrees` since the previous event; positive is counter-clockwise.
    public static func gestureRotate(degrees: Double, phase: UInt64, mask: UInt64 = GesturePhase.defaultMask, x: UInt16, y: UInt16) -> Data {
        twoFingerGesture(.gestureRotate, value: degrees, phase: phase, mask: mask, x: x, y: y)
    }

    private static func twoFingerGesture(_ kind: EventMessageKind, value: Double, phase: UInt64, mask: UInt64, x: UInt16, y: UInt16) -> Data {
        var writer = eventHeader(kind, bodyLength: 32, version: 2)
        writer.f64(value.isFinite ? value : 0)
        writer.u16(x)
        writer.u16(y)
        writer.u64(phase)
        writer.u64(mask)
        return writer.data
    }

    /// Two-finger double tap: smart zoom.
    public static func gestureSmartMagnify(x: UInt16, y: UInt16) -> Data {
        var writer = eventHeader(.gestureSmartMagnify, bodyLength: 8, version: 1)
        writer.u16(x)
        writer.u16(y)
        return writer.data
    }

    /// Force click or three-finger tap: look up what is under the pointer.
    public static func gestureLookUp(x: UInt16, y: UInt16) -> Data {
        var writer = eventHeader(.gestureLookUp, bodyLength: 8, version: 1)
        writer.u16(x)
        writer.u16(y)
        return writer.data
    }

    /// A trackpad scroll as a gesture event (HID scroll), which Screen Sharing.app sends beside
    /// the scroll-wheel message. `phase` is a ``GesturePhase`` raw value.
    public static func gestureScroll(
        deltaX: Float, deltaY: Float, deltaZ: Float = 0, naturalScrolling: Bool, phase: UInt32, mask: UInt32, x: UInt16, y: UInt16
    ) -> Data {
        var writer = eventHeader(.gestureScroll, bodyLength: 32, version: 1)
        writer.f32(deltaX)
        writer.f32(deltaY)
        writer.f32(deltaZ)
        writer.u32(naturalScrolling ? 1 : 0)
        writer.u32(phase)
        writer.u32(mask)
        writer.u16(x)
        writer.u16(y)
        return writer.data
    }

    /// A fluid page swipe (HID navigation swipe), field for field as the Mac's agent copies it.
    public static func gesturePageSwipe(_ swipe: PageSwipe, x: UInt16, y: UInt16) -> Data {
        var writer = eventHeader(.gesturePageSwipe, bodyLength: 48, version: 1)
        writer.u32(swipe.motion)
        writer.u32(swipe.swipeMask)
        for value in [swipe.progress, swipe.positionX, swipe.positionY, swipe.velocityX, swipe.velocityY, swipe.velocityZ] {
            writer.f32(value.isFinite ? value : 0)
        }
        writer.u32(swipe.flags)
        writer.u32(swipe.flavor)
        writer.u16(x)
        writer.u16(y)
        return writer.data
    }

    private static func eventHeader(_ kind: EventMessageKind, bodyLength: UInt16, version: UInt16) -> WireWriter {
        var writer = WireWriter(capacity: 4 + Int(bodyLength))
        writer.u8(ClientMessageType.event2)
        writer.u8(0)
        writer.u16(bodyLength)
        writer.u16(version)
        writer.u16(kind.rawValue)
        return writer
    }

    /// The versions this viewer gives: Screen Sharing 6.1.0 on macOS 26.6.2.
    public static let viewerVersions: (application: [UInt32], system: [UInt32]) = ([6, 1, 0], [26, 6, 2])

    /// Identifies the viewer. Required before the Mac will send status notifications.
    public static func viewerInfo(versions: (application: [UInt32], system: [UInt32]) = viewerVersions) -> Data {
        var writer = WireWriter(capacity: 66)
        writer.u8(ClientMessageType.viewerInfo)
        writer.u8(0)
        writer.u16(62)
        writer.u16(1) // application class: generic viewer
        writer.u32(2) // application id: Screen Sharing
        for part in (versions.application + [0, 0, 0]).prefix(3) { writer.u32(part) }
        for part in (versions.system + [0, 0, 0]).prefix(3) { writer.u32(part) }
        // The server message types this viewer handles, as Apple's viewer states them. The Mac
        // tests bit 20 before each status message and bit 21 before accessibility messages.
        var bitmap = [UInt8](repeating: 0, count: 32)
        bitmap[0] = 0xb0
        bitmap[2] = 0x0c
        bitmap[3] = 0x03
        bitmap[4] = 0x90
        bitmap[10] = 0x40
        writer.bytes(bitmap)
        return writer.data
    }

    public static func setMode(_ mode: ViewerMode) -> Data {
        var writer = WireWriter(capacity: 4)
        writer.u8(ClientMessageType.setMode)
        writer.u8(0)
        writer.u16(mode.rawValue)
        return writer.data
    }

    /// Asks the Mac to draw a fresh key and start the record layer.
    public static func startEncryption() -> Data {
        Data([0x12, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01])
    }

    /// Tells the Mac that everything the viewer sends after the rekey is in records.
    public static func enableInboundDecryption() -> Data {
        Data([0x12, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00])
    }

    public static func autoPasteboard(_ enabled: Bool) -> Data {
        Data([ClientMessageType.autoPasteboard, 0, 0, enabled ? 1 : 2, 0, 0, 0, 0])
    }

    /// Asks for the Mac's pasteboard. `token` comes back in the reply.
    public static func pasteboardFetch(token: UInt32) -> Data {
        var writer = WireWriter(capacity: 8)
        writer.u8(ClientMessageType.pasteboardFetch)
        writer.zeros(3)
        writer.u32(token)
        return writer.data
    }

    /// A HID input report for the virtual touch screen the Mac keeps for one of its displays,
    /// `display` being the Mac's own id for it (a layout's screen id). Unlike every other message
    /// its fields are little-endian, as Screen Sharing.app writes them (`RFBSendHIDReport`): `26 00`,
    /// `u16` the length of what follows it (16 plus the report's), `u16` version 1, eight zero bytes,
    /// `u32` the display, `u16` the report's length, the report.
    public static func hidReport(display: UInt32, report: Data) -> Data {
        precondition(report.count <= Int(UInt16.max) - 16, "HID report exceeds its length field")
        var message = Data([ClientMessageType.hidReport, 0])
        func littleEndian<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { message.append(contentsOf: $0) }
        }
        littleEndian(UInt16(16 + report.count))
        littleEndian(UInt16(1))
        message.append(Data(count: 8))
        littleEndian(display)
        littleEndian(UInt16(report.count))
        message.append(report)
        return message
    }

    /// Arms server-driven updates of a rectangle. `interval` paces them; zero means as fast as the
    /// Mac captures, and `nil` turns them off.
    public static func autoFramebufferUpdate(interval: Duration?, width: UInt16, height: UInt16) -> Data {
        var writer = WireWriter(capacity: 16)
        writer.u8(ClientMessageType.autoFramebufferUpdate)
        writer.u8(0)
        writer.u16(1)
        if let interval {
            let microseconds = interval.components.seconds * 1_000_000 + interval.components.attoseconds / 1_000_000_000_000
            writer.u32(UInt32(clamping: min(microseconds, Int64(UInt32.max) - 1)))
        } else {
            writer.u32(.max)
        }
        writer.u16(0)
        writer.u16(0)
        writer.u16(width)
        writer.u16(height)
        return writer.data
    }

    /// Shares one physical display, or all of them combined when `id` is nil.
    public static func setDisplay(_ id: UInt32?) -> Data {
        var writer = WireWriter(capacity: 8)
        writer.u8(ClientMessageType.setDisplay)
        writer.u8(id == nil ? 1 : 0)
        writer.u16(0)
        writer.u32(id ?? 0)
        return writer.data
    }

    /// Asks the Mac to render at `factor` of native size before encoding. `factor` is in (0, 1].
    public static func setServerScaling(_ factor: Double) -> Data {
        precondition(factor > 0 && factor <= 1, "scaling factor must be in (0, 1]")
        var writer = WireWriter(capacity: 10)
        writer.u8(ClientMessageType.setServerScaling)
        writer.u8(0)
        writer.f64(factor)
        return writer.data
    }

    /// Creates or resizes the session's virtual displays, one per mode.
    public static func setDisplayConfiguration(_ displays: [VirtualDisplayMode], dynamic: Bool) -> Data {
        precondition((1...2).contains(displays.count), "one or two virtual displays")
        var body = WireWriter(capacity: 8 + displays.count * 0x130)
        body.u16(1) // version
        body.u16(UInt16(displays.count))
        body.u32(0) // flags
        for (index, mode) in displays.enumerated() {
            body.bytes(VirtualDisplayMode.descriptor(for: mode, index: index, dynamic: dynamic))
        }
        return framed(ClientMessageType.setDisplayConfiguration, body: body.data)
    }
}

/// One mode of a virtual display: the pixels the Mac renders and the points they cover.
public struct VirtualDisplayMode: Sendable, Hashable {
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
    public var pointWidth: UInt32
    public var pointHeight: UInt32
    public var refreshRate: Double
    public var isHDR: Bool

    public init(pixelWidth: UInt32, pixelHeight: UInt32, pointWidth: UInt32, pointHeight: UInt32, refreshRate: Double = 60, isHDR: Bool = false) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.refreshRate = refreshRate
        self.isHDR = isHDR
    }

    /// The largest backing size a dynamic virtual display may be given.
    public static let maximumPixelWidth: UInt32 = 3840
    public static let maximumPixelHeight: UInt32 = 2160
    /// The least size of a 2x display, in points. (At 700 × 1000 a Mac still agreed; at 440 × 956
    /// and at 800 × 500 it substituted a mode of its own.)
    public static let minimumPointWidth: UInt32 = 800
    public static let minimumPointHeight: UInt32 = 600
    /// The least side of a 1x display. A Mac made one of 200 × 200; nothing smaller was tried.
    public static let minimumPointSideAt1x: UInt32 = 200

    /// The mode every virtual display is first created with, before the session's own size is applied.
    public static let opening = VirtualDisplayMode(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 1920, pointHeight: 1080)

    /// A mode covering `pointWidth` × `pointHeight` points at 1x or 2x, held within what a Mac accepts
    /// (measured on macOS 27):
    /// - at 1x anything from 200 × 200 up, portrait included;
    /// - at 2x roughly 800 × 600 points or more, and a smaller request is answered with some
    ///   other mode, so one is served here at 1x with the same pixels instead;
    /// - never more than 3840 × 2160 pixels, because a larger request gets no answer at all;
    /// - an even number of pixels on each side.
    ///
    /// The point size is re-derived after clamping so pixels and points keep one ratio.
    public static func fitting(pointWidth: Int, pointHeight: Int, scale: Int, refreshRate: Double = 60, isHDR: Bool = false) -> VirtualDisplayMode {
        var scale = UInt32(scale >= 2 ? 2 : 1)
        var wantedWidth = max(pointWidth, 1)
        var wantedHeight = max(pointHeight, 1)
        if scale == 2, wantedWidth < Int(minimumPointWidth) || wantedHeight < Int(minimumPointHeight) {
            scale = 1
            wantedWidth *= 2
            wantedHeight *= 2
        }
        func axis(_ points: Int, minimum: UInt32, maximum: UInt32) -> (pixels: UInt32, points: UInt32) {
            let wanted = UInt32(clamping: max(points, Int(minimum)))
            // Even, because a Mac sends no H.264 picture of a display with an odd side.
            let pixels = min(wanted * scale, maximum) & ~1
            return (pixels, pixels / scale)
        }
        let width = axis(wantedWidth, minimum: scale == 2 ? minimumPointWidth : minimumPointSideAt1x, maximum: maximumPixelWidth)
        let height = axis(wantedHeight, minimum: scale == 2 ? minimumPointHeight : minimumPointSideAt1x, maximum: maximumPixelHeight)
        return VirtualDisplayMode(
            pixelWidth: width.pixels, pixelHeight: height.pixels,
            pointWidth: width.points, pointHeight: height.points,
            refreshRate: refreshRate, isHDR: isHDR
        )
    }

    /// The four fixed modes Apple's viewer lists after the requested one.
    private static func presets(refreshRate: Double) -> [VirtualDisplayMode] {
        [
            VirtualDisplayMode(pixelWidth: 2880, pixelHeight: 1800, pointWidth: 1440, pointHeight: 900, refreshRate: refreshRate),
            VirtualDisplayMode(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 1920, pointHeight: 1080, refreshRate: refreshRate),
            VirtualDisplayMode(pixelWidth: 2880, pixelHeight: 1620, pointWidth: 1440, pointHeight: 810, refreshRate: refreshRate),
            VirtualDisplayMode(pixelWidth: 2624, pixelHeight: 1696, pointWidth: 1312, pointHeight: 848, refreshRate: refreshRate),
        ]
    }

    static func name(index: Int) -> String {
        index == 0 ? "Screen Sharing Virtual Display" : "Screen Sharing Virtual Display #\(index + 1)"
    }

    /// One display descriptor: a 0x9c-byte head, then 0x1c bytes per mode. It leads with its own
    /// length, which is how the Mac steps from one descriptor to the next.
    static func descriptor(for mode: VirtualDisplayMode, index: Int, dynamic: Bool) -> Data {
        let modes = [mode] + presets(refreshRate: mode.refreshRate)
        let headLength = 0x9c
        let modeLength = 0x1c
        let total = headLength + modes.count * modeLength
        // Millimetres per backing pixel at 264 dots per inch, as Apple's viewer fills the size.
        let millimetresPerPixel = 25.4 / 264.0
        let maximumWidth = modes.map(\.pixelWidth).max() ?? mode.pixelWidth
        let maximumHeight = modes.map(\.pixelHeight).max() ?? mode.pixelHeight

        var writer = WireWriter(capacity: total)
        writer.u16(UInt16(total))
        writer.bytes(name(index: index).utf8.prefix(119))
        writer.pad(to: 0x7a) // the name's 120 bytes, zero-filled
        writer.u32(dynamic ? 1 : 0) // display flags: bit 0 dynamic resolution
        writer.u32(0) // display type
        // A Mac creates no display when the physical or maximum size is zero.
        writer.f32(Float(Double(maximumWidth) * millimetresPerPixel))
        writer.f32(Float(Double(maximumHeight) * millimetresPerPixel))
        writer.u32(maximumWidth)
        writer.u32(maximumHeight)
        writer.u16(0) // current mode index
        writer.u16(0) // preferred mode index
        writer.u32(7) // rotations, as Apple's viewer sends
        writer.u16(UInt16(modes.count))
        precondition(writer.count == headLength)
        for entry in modes {
            writer.u32(entry.pixelWidth)
            writer.u32(entry.pixelHeight)
            writer.u32(entry.pointWidth)
            writer.u32(entry.pointHeight)
            writer.f64(entry.refreshRate)
            writer.u32(entry.isHDR ? 1 : 0)
        }
        precondition(writer.count == total)
        return writer.data
    }
}
