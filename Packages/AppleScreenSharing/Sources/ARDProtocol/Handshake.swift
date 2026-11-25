// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation

/// The twelve bytes each side opens with.
public struct ProtocolVersion: Sendable, Hashable, CustomStringConvertible {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Apple's own revision. A Mac only speaks its extensions to a viewer that answers with it.
    public static let apple = ProtocolVersion(major: 3, minor: 889)

    public static let encodedLength = 12

    public var description: String { String(format: "%03d.%03d", major, minor) }

    public var encoded: Data {
        Data("RFB \(description)\n".utf8)
    }

    public static func parse(_ reader: inout WireReader) throws(WireError) -> ProtocolVersion {
        let bytes = try reader.take(encodedLength)
        guard let text = String(data: bytes, encoding: .ascii),
              text.hasPrefix("RFB "), text.hasSuffix("\n"),
              text.utf8.count == encodedLength
        else { throw .malformed("not an RFB version line") }
        let parts = text.dropFirst(4).dropLast(1).split(separator: ".")
        guard parts.count == 2, parts.allSatisfy({ $0.count == 3 }),
              let major = Int(parts[0]), let minor = Int(parts[1])
        else { throw .malformed("unreadable RFB version") }
        return ProtocolVersion(major: major, minor: minor)
    }
}

/// RFB security types a Mac lists.
public struct SecurityType: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let none = SecurityType(rawValue: 1)
    /// Classic VNC password (DES challenge).
    public static let vncPassword = SecurityType(rawValue: 2)
    /// Diffie-Hellman with AES-encrypted name and password.
    public static let diffieHellman = SecurityType(rawValue: 30)
    /// Ask the Mac's user for permission to observe.
    public static let askToObserve = SecurityType(rawValue: 31)
    /// Ask the Mac's user for permission to control.
    public static let askToControl = SecurityType(rawValue: 32)
    /// RSA envelope carrying a plain login or SRP.
    public static let rsa = SecurityType(rawValue: 33)
    public static let preSharedKey = SecurityType(rawValue: 34)
    public static let kerberos = SecurityType(rawValue: 35)
    /// SRP-6a.
    public static let srp = SecurityType(rawValue: 36)

    public var description: String {
        switch self {
        case .none: "none"
        case .vncPassword: "VNC password"
        case .diffieHellman: "Diffie-Hellman (30)"
        case .askToObserve: "ask to observe (31)"
        case .askToControl: "ask to control (32)"
        case .rsa: "RSA (33)"
        case .preSharedKey: "pre-shared key (34)"
        case .kerberos: "Kerberos (35)"
        case .srp: "SRP (36)"
        default: "type \(rawValue)"
        }
    }
}

/// The server's list of acceptable security types, or its refusal.
public enum SecurityOffer: Sendable, Equatable {
    case types([SecurityType])
    case refused(reason: String)

    public static func parse(_ reader: inout WireReader) throws(WireError) -> SecurityOffer {
        let count = Int(try reader.u8())
        if count == 0 {
            let length = Int(try reader.u32())
            guard length <= 4096 else { throw .malformed("refusal reason of \(length) bytes") }
            let reason = String(decoding: try reader.take(length), as: UTF8.self)
            return .refused(reason: reason)
        }
        return .types(try reader.take(count).map(SecurityType.init(rawValue:)))
    }
}

public struct PixelFormat: Sendable, Hashable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var isBigEndian: Bool
    public var isTrueColour: Bool
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    public static let encodedLength = 16

    /// 32 bits per pixel, little-endian, blue in the low byte: bytes arrive as B, G, R, X. This is a
    /// Mac's native format and matches `kCVPixelFormatType_32BGRA`, so pixels are copied, not converted.
    public static let bgrx = PixelFormat(
        bitsPerPixel: 32, depth: 24, isBigEndian: false, isTrueColour: true,
        redMax: 255, greenMax: 255, blueMax: 255, redShift: 16, greenShift: 8, blueShift: 0
    )

    public var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }

    public init(
        bitsPerPixel: UInt8, depth: UInt8, isBigEndian: Bool, isTrueColour: Bool,
        redMax: UInt16, greenMax: UInt16, blueMax: UInt16,
        redShift: UInt8, greenShift: UInt8, blueShift: UInt8
    ) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.isBigEndian = isBigEndian
        self.isTrueColour = isTrueColour
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    public static func parse(_ reader: inout WireReader) throws(WireError) -> PixelFormat {
        let format = PixelFormat(
            bitsPerPixel: try reader.u8(), depth: try reader.u8(),
            isBigEndian: try reader.u8() != 0, isTrueColour: try reader.u8() != 0,
            redMax: try reader.u16(), greenMax: try reader.u16(), blueMax: try reader.u16(),
            redShift: try reader.u8(), greenShift: try reader.u8(), blueShift: try reader.u8()
        )
        try reader.skip(3)
        guard [8, 16, 32].contains(format.bitsPerPixel) else {
            throw .malformed("\(format.bitsPerPixel) bits per pixel")
        }
        return format
    }

    public func write(to writer: inout WireWriter) {
        writer.u8(bitsPerPixel)
        writer.u8(depth)
        writer.u8(isBigEndian ? 1 : 0)
        writer.u8(isTrueColour ? 1 : 0)
        writer.u16(redMax)
        writer.u16(greenMax)
        writer.u16(blueMax)
        writer.u8(redShift)
        writer.u8(greenShift)
        writer.u8(blueShift)
        writer.zeros(3)
    }
}

public struct ClientInitFlags: OptionSet, Sendable {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Leave other viewers connected.
    public static let shared = ClientInitFlags(rawValue: 0x01)
    /// Ask for the session-select exchange when someone else is at the console.
    public static let sessionSelect = ClientInitFlags(rawValue: 0x40)
    /// Ask for Apple's extended ServerInit.
    public static let extended = ClientInitFlags(rawValue: 0x80)
}

/// What a Mac says about itself and the connection once the login is accepted.
public struct ServerInit: Sendable, Equatable {
    /// The flags word of the extended form.
    public struct Flags: OptionSet, Sendable, Hashable {
        public var rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// Control is refused; the viewer may only watch.
        public static let observeOnly = Flags(rawValue: 0x01)
        /// The account holds the control privilege.
        public static let mayControl = Flags(rawValue: 0x02)
        /// A session-select block follows ServerInit.
        public static let sessionSelectFollows = Flags(rawValue: 0x04)
        /// The Mac is not permitted to capture its screen.
        public static let captureNotPermitted = Flags(rawValue: 0x08)
        /// Marks the extended form.
        public static let extended = Flags(rawValue: 0x10)

        /// How many virtual displays the Mac will create for a session.
        public var maximumVirtualDisplays: Int { Int(rawValue >> 5) }
    }

    public var framebufferWidth: UInt16
    public var framebufferHeight: UInt16
    public var pixelFormat: PixelFormat
    public var name: String
    /// `nil` when the server answered in the plain RFB form.
    public var flags: Flags?
    /// One bit per client message type the Mac accepts; `nil` in the plain form.
    public var acceptedMessages: MessageBitmap?

    /// Upper bound on the name field. A Mac's is under a hundred bytes.
    static let maximumNameLength = 4096
    static let extendedHeaderLength = 22

    public static func parse(_ reader: inout WireReader, extended: Bool) throws(WireError) -> ServerInit {
        let width = try reader.u16()
        let height = try reader.u16()
        let format = try PixelFormat.parse(&reader)
        let length = Int(try reader.u32())
        guard length <= maximumNameLength else { throw .malformed("ServerInit name of \(length) bytes") }
        var field = try reader.sub(length)

        var flags: Flags?
        var bitmap: MessageBitmap?
        // In the extended form the "name" is a zero word, a flags word and a bitmap, then the name.
        // A Mac sets `extended` in the flags; wayshare does not (its word is just the display
        // count), and Screen Sharing.app takes its form as extended all the same.
        if extended, length >= extendedHeaderLength {
            var probe = field
            if try probe.u16() == 0 {
                flags = Flags(rawValue: try probe.u32())
                bitmap = MessageBitmap(bytes: Array(try probe.take(16)))
                field = probe
            }
        }
        let name = String(decoding: try field.take(field.remaining), as: UTF8.self)
        return ServerInit(
            framebufferWidth: width, framebufferHeight: height, pixelFormat: format,
            name: name, flags: flags, acceptedMessages: bitmap
        )
    }

    /// Whether the Mac can hold a High Performance session: it accepts the message that creates
    /// virtual displays and the one that offers the media stream, and will create at least one.
    public var supportsHighPerformance: Bool {
        guard let acceptedMessages, let flags else { return false }
        return acceptedMessages.contains(ClientMessageType.setDisplayConfiguration)
            && acceptedMessages.contains(ClientMessageType.mediaOffer)
            && flags.maximumVirtualDisplays >= 1
    }
}

/// A set of message types, one bit each, most significant bit first within each byte.
public struct MessageBitmap: Sendable, Hashable {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(types: some Sequence<UInt8>, byteCount: Int) {
        bytes = [UInt8](repeating: 0, count: byteCount)
        for type in types { insert(type) }
    }

    public func contains(_ type: UInt8) -> Bool {
        let index = Int(type) / 8
        guard index < bytes.count else { return false }
        return bytes[index] & (0x80 >> (type % 8)) != 0
    }

    public mutating func insert(_ type: UInt8) {
        let index = Int(type) / 8
        guard index < bytes.count else { return }
        bytes[index] |= 0x80 >> (type % 8)
    }

    public var types: [UInt8] {
        (0..<min(bytes.count * 8, 256)).map(UInt8.init(truncatingIfNeeded:)).filter(contains)
    }
}
