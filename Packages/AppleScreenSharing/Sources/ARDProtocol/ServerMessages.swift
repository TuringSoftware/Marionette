// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation

/// Status notifications a Mac sends once the viewer has identified itself.
public struct MiscStatus: RawRepresentable, Sendable, Hashable {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// The Mac's user ended the session; the connection closes next.
    public static let sessionEndedByUser = MiscStatus(rawValue: 1)
    public static let pasteboardChanged = MiscStatus(rawValue: 2)
    /// The Mac needs the data of a flavor the viewer promised.
    public static let pasteboardDataNeeded = MiscStatus(rawValue: 3)
    /// Sent when nothing else has been for two seconds.
    public static let heartbeat = MiscStatus(rawValue: 4)
    public static let displaysAsleep = MiscStatus(rawValue: 5)
    public static let displaysAwake = MiscStatus(rawValue: 6)
    public static let controlAllowed = MiscStatus(rawValue: 9)
    public static let observeOnly = MiscStatus(rawValue: 10)
    public static let pointerHidden = MiscStatus(rawValue: 11)
    public static let pointerShown = MiscStatus(rawValue: 12)
    /// A login or logout happened at the Mac.
    public static let userSessionChanged = MiscStatus(rawValue: 17)
}

/// The position, size and encoding that head every rectangle. Metadata encodings reuse the
/// geometry fields for their own purposes or leave them zero.
public struct RectangleHeader: Sendable, Hashable {
    public var x: UInt16
    public var y: UInt16
    public var width: UInt16
    public var height: UInt16
    public var encoding: Encoding

    public init(x: UInt16, y: UInt16, width: UInt16, height: UInt16, encoding: Encoding) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.encoding = encoding
    }
}

public enum RectangleBody: Sendable, Equatable {
    /// Uncompressed pixels in the session's pixel format.
    case raw(Data)
    /// The next chunk of the session's shared deflate stream, inflating to raw pixels.
    case zlib(Data)
    /// The next chunk of the session's ZRLE deflate stream.
    case zrle(Data)
    /// Apple's 8×8 tiles, undecoded.
    case adaptive(Data)
    /// A wrapped key and IV for the record layer.
    case rekey(Data)
    /// Stores a cursor shape (non-empty `deflated`) or selects a stored one (empty).
    case cursorImage(cacheID: UInt32, deflated: Data)
    case cursorPosition
    case displayLayout(DisplayLayout)
    case keyboardSource(KeyboardSource)
    case mediaStream(Data)
    case desktopSize
    case lastRectangle
    /// Metadata this client lists but has no use for; already stepped over.
    case ignored
    /// Length-framed metadata whose fields could not be read, stepped over by its length; the
    /// reason is for diagnostics. A layout the Mac could not have meant arrives this way too.
    case unusable(String)
}

public struct Rectangle: Sendable, Equatable {
    public var header: RectangleHeader
    public var body: RectangleBody
}

/// The Mac's current input source and whether a secure text field has focus.
public struct KeyboardSource: Sendable, Equatable {
    public var inputSourceID: String
    public var isSecureInputActive: Bool
}

/// The header of a pasteboard transfer and its compressed archive.
public struct PasteboardData: Sendable, Equatable {
    /// True when the archive lists flavors without their data.
    public var isPromisesOnly: Bool
    /// The value the viewer put in its fetch.
    public var token: UInt32
    public var uncompressedLength: UInt32
    public var compressed: Data

    public init(isPromisesOnly: Bool, token: UInt32, uncompressedLength: UInt32, compressed: Data) {
        self.isPromisesOnly = isPromisesOnly
        self.token = token
        self.uncompressedLength = uncompressedLength
        self.compressed = compressed
    }
}

/// A server message this client advertises in its ViewerInfo, as Apple's viewer does, but does not
/// act on: each is stepped over by its own length and kept for diagnostics. Framing from the
/// viewer's `_HandleServerMessage` and screensharingd's encoders; none has been seen on the wire.
public enum ServerNotice: Sendable, Equatable, CustomStringConvertible {
    /// `0x15`: `u32 feature`, `u32 message`, `u32 reply-to id`, `u16 length`, then that many bytes. The
    /// Mac writes these fields in host order, little-endian, unlike every other message.
    case accessibility(feature: UInt32, message: UInt32, replyTo: UInt32, payload: Data)
    /// `0x23`: a request the Mac's user or system makes of the viewer; its meaning is unknown.
    /// `u8 pad`, `u16 length`, `u16 version`, `u32 request`, two `u32`s, then `length − 14` more bytes.
    case userRequest(version: UInt16, request: UInt32, first: UInt32, second: UInt32, extra: Data)
    /// `0x51`: information about the Mac's system. `u8 pad`, `u32 length`, `u16 version`, `u32 sender
    /// token`, `u32 flags` (bit 0: the payload is zlib), `u32 inflated length`, `u32 payload length`,
    /// payload.
    case systemInfo(version: UInt16, senderToken: UInt32, flags: UInt32, inflatedLength: UInt32, payload: Data)
    /// A length-framed message whose fields could not be read.
    case unusable(type: UInt8, reason: String)

    /// Largest inflated system-info payload shown in a description.
    static let maximumDescribedPayload = 64 << 10

    public var description: String {
        func hex(_ data: Data) -> String { data.prefix(32).map { String(format: "%02x", $0) }.joined() }
        switch self {
        case .accessibility(let feature, let message, let replyTo, let payload):
            return "accessibility: feature \(feature), message \(message), reply to \(replyTo), \(payload.count) bytes \(hex(payload))"
        case .userRequest(let version, let request, let first, let second, let extra):
            return "user request \(request) (version \(version)): \(first), \(second), \(extra.count) more bytes \(hex(extra))"
        case .systemInfo(let version, let token, let flags, let inflatedLength, let payload):
            var text = "system info (version \(version), token \(token), flags 0x\(String(flags, radix: 16))): \(payload.count) bytes"
            let limit = min(Int(inflatedLength), Self.maximumDescribedPayload)
            if flags & 1 != 0, let inflated = try? InflateStream.inflateWhole(payload, limit: limit) {
                text += ", \(inflated.count) inflated: " + String(decoding: inflated.prefix(512), as: UTF8.self)
            } else {
                text += " " + hex(payload)
            }
            return text
        case .unusable(let type, let reason):
            return String(format: "message 0x%02x stepped over: ", type) + reason
        }
    }
}

public enum ServerEvent: Sendable, Equatable {
    case updateBegan(rectangleCount: Int)
    case rectangle(Rectangle)
    case updateEnded
    case bell
    case cutText(String)
    case status(MiscStatus)
    case pasteboard(PasteboardData)
    /// A drag on the Mac left its picture (or a drag ended).
    case drag(DragPasteboard)
    /// The viewer's drag was dropped on this folder.
    case dropDestination(DropDestination)
    case fileTransfer(FileTransferMessage)
    /// Something the Mac said that this client does not act on; for diagnostics.
    case notice(ServerNotice)
}

/// Turns the server's byte stream into events, one rectangle or message at a time.
///
/// Sizes taken from the wire are capped before anything is waited for or allocated, so a hostile
/// length ends the session instead of exhausting memory.
public struct ServerMessageParser: Sendable {
    /// The format rectangles arrive in; set to whatever the client last asked for.
    public var pixelFormat: PixelFormat = .bgrx

    private var rectanglesRemaining: Int?

    /// Largest pixel payload accepted for one rectangle: an uncompressed 5K frame with headroom.
    static let maximumPixelPayload = 96 << 20
    static let maximumCursorPayload = 1 << 20
    public static let maximumPasteboardPayload = 100 << 20
    static let maximumCutText = 1 << 20
    static let maximumSystemInfo = 16 << 20

    public init() {}

    /// True between the header of a framebuffer update and its last rectangle.
    public var isInsideUpdate: Bool { rectanglesRemaining != nil }

    /// The next event, or `nil` when more bytes are needed.
    public mutating func next(from buffer: inout InboundBuffer) throws(WireError) -> ServerEvent? {
        if let remaining = rectanglesRemaining {
            if remaining == 0 {
                rectanglesRemaining = nil
                return .updateEnded
            }
            let format = pixelFormat
            guard let rectangle = try buffer.parse({ (reader: inout WireReader) throws(WireError) in
                try Self.parseRectangle(&reader, pixelFormat: format)
            }) else { return nil }
            rectanglesRemaining = rectangle.body == .lastRectangle ? 0 : remaining - 1
            return .rectangle(rectangle)
        }

        guard let event = try buffer.parse(Self.parseMessage) else { return nil }
        if case .updateBegan(let count) = event {
            rectanglesRemaining = count
        }
        return event
    }

    private static func parseMessage(_ reader: inout WireReader) throws(WireError) -> ServerEvent {
        let before = reader
        let type = try reader.u8()
        switch type {
        case 0x00:
            try reader.skip(1)
            return .updateBegan(rectangleCount: Int(try reader.u16()))
        case 0x02:
            return .bell
        case 0x03:
            try reader.skip(3)
            let length = Int(try reader.u32())
            guard length <= maximumCutText else { throw .malformed("cut text of \(length) bytes") }
            return .cutText(String(decoding: try reader.take(length), as: UTF8.self))
        case ServerMessageType.status:
            try reader.skip(1)
            var body = try reader.sub(Int(try reader.u16()))
            guard body.remaining >= 4 else { return .notice(.unusable(type: type, reason: "status of \(body.remaining) bytes")) }
            try body.skip(2) // version
            return .status(MiscStatus(rawValue: try body.u16()))
        case ServerMessageType.accessibility:
            let feature = try reader.u32().byteSwapped
            let message = try reader.u32().byteSwapped
            let replyTo = try reader.u32().byteSwapped
            let length = Int(try reader.u16().byteSwapped)
            return .notice(.accessibility(feature: feature, message: message, replyTo: replyTo, payload: try reader.take(length)))
        case ServerMessageType.userRequest:
            try reader.skip(1)
            let length = Int(try reader.u16())
            // The fixed part is read whatever the length says; the length counts what follows it.
            var body = try reader.sub(max(length, 14))
            return .notice(.userRequest(
                version: try body.u16(), request: try body.u32(), first: try body.u32(), second: try body.u32(), extra: body.rest()
            ))
        case ServerMessageType.systemInfo:
            try reader.skip(1)
            let length = Int(try reader.u32())
            guard length <= maximumSystemInfo else { throw .malformed("system info of \(length) bytes") }
            var body = try reader.sub(length)
            do {
                let version = try body.u16()
                let token = try body.u32()
                let flags = try body.u32()
                let inflated = try body.u32()
                let payload = try body.take(Int(try body.u32()))
                return .notice(.systemInfo(version: version, senderToken: token, flags: flags, inflatedLength: inflated, payload: payload))
            } catch {
                return .notice(.unusable(type: type, reason: "\(error)"))
            }
        case 0x1f:
            try reader.skip(1)
            let flags = try reader.u8()
            try reader.skip(1)
            let token = try reader.u32()
            let uncompressed = try reader.u32()
            let compressed = Int(try reader.u32())
            guard compressed <= maximumPasteboardPayload, Int(uncompressed) <= maximumPasteboardPayload else {
                throw .malformed("pasteboard of \(compressed) bytes, \(uncompressed) inflated")
            }
            return .pasteboard(
                PasteboardData(
                    isPromisesOnly: flags & 1 != 0, token: token,
                    uncompressedLength: uncompressed, compressed: try reader.take(compressed)
                )
            )
        case ServerMessageType.dropDestination:
            reader = before
            return .dropDestination(try DropDestination.parse(&reader))
        case ServerMessageType.dragPasteboard:
            reader = before
            return .drag(try DragPasteboard.parse(&reader))
        case ServerMessageType.fileTransfer:
            reader = before
            return .fileTransfer(try FileTransferMessage.parse(&reader))
        default:
            // The stream has no framing above the record layer, so an unknown type cannot be
            // stepped over: there is no telling where the next message starts.
            throw .malformed(String(format: "server message type 0x%02x", type))
        }
    }

    private static func parseRectangle(_ reader: inout WireReader, pixelFormat: PixelFormat) throws(WireError) -> Rectangle {
        let header = RectangleHeader(
            x: try reader.u16(), y: try reader.u16(),
            width: try reader.u16(), height: try reader.u16(),
            encoding: Encoding(rawValue: try reader.i32())
        )
        let body: RectangleBody
        switch header.encoding {
        case .raw:
            let length = Int(header.width) * Int(header.height) * pixelFormat.bytesPerPixel
            guard length <= maximumPixelPayload else { throw .malformed("raw rectangle of \(length) bytes") }
            body = .raw(try reader.take(length))
        case .zlib:
            body = .zlib(try counted32(&reader, limit: maximumPixelPayload, what: "zlib rectangle"))
        case .zrle:
            body = .zrle(try counted32(&reader, limit: maximumPixelPayload, what: "ZRLE rectangle"))
        case .appleAdaptive:
            body = .adaptive(try counted32(&reader, limit: maximumPixelPayload, what: "adaptive rectangle"))
        case .appleRekey:
            body = .rekey(try reader.take(36))
        case .appleCursorImage:
            let cacheID = try reader.u32()
            body = .cursorImage(
                cacheID: cacheID,
                deflated: try counted32(&reader, limit: maximumCursorPayload, what: "cursor image")
            )
        case .appleCursorPosition:
            body = .cursorPosition
        case .appleDisplayLayout:
            var payload = try reader.sub(Int(try reader.u16()))
            body = stepping { () throws(WireError) in .displayLayout(try DisplayLayout.parse(&payload)) }
        case .appleKeyboardSource:
            var payload = try reader.sub(Int(try reader.u16()))
            body = stepping { () throws(WireError) in
                try payload.skip(2) // version
                let flag = try payload.u32()
                let name = try payload.take(Int(try payload.u16()))
                return .keyboardSource(
                    KeyboardSource(inputSourceID: String(decoding: name, as: UTF8.self), isSecureInputActive: flag & 1 != 0)
                )
            }
        case .appleVendorKeysyms, .appleDeviceInfo, .appleUserInfo:
            try reader.skip(Int(try reader.u16()))
            body = .ignored
        case .appleDisplayInfo:
            // The older display list: ten bytes of header ending in a count, then 0x1c per screen.
            try reader.skip(8)
            try reader.skip(Int(try reader.u16()) * 0x1c)
            body = .ignored
        case .appleMediaStream:
            body = .mediaStream(try reader.take(Int(try reader.u16())))
        case .desktopSize:
            body = .desktopSize
        case .lastRect:
            body = .lastRectangle
        default:
            throw .malformed("rectangle encoding \(header.encoding) was never requested")
        }
        return Rectangle(header: header, body: body)
    }

    /// The body `parse` reads from a length-framed field whose frame is already consumed, or
    /// ``RectangleBody/unusable(_:)``: the stream after it is intact either way.
    private static func stepping(_ parse: () throws(WireError) -> RectangleBody) -> RectangleBody {
        do {
            return try parse()
        } catch {
            switch error {
            case .malformed(let reason): return .unusable(reason)
            case .truncated: return .unusable("cut short")
            }
        }
    }

    private static func counted32(_ reader: inout WireReader, limit: Int, what: String) throws(WireError) -> Data {
        let length = Int(try reader.u32())
        guard length <= limit else { throw .malformed("\(what) of \(length) bytes") }
        return try reader.take(length)
    }
}
