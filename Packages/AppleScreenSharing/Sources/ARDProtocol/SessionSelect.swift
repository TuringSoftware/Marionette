// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation

// Session select: what happens when the account that logs in is not the one using the Mac's
// display. Layouts are from captures of Screen Sharing.app on macOS 27.0.1, with the Mac's log
// (`screensharingd`) naming each step; see `Docs/protocol/apple-screen-sharing.md`.
//
// A viewer that sets ClientInit flag 0x40 gets, when someone else is at the console, ServerInit flag
// 0x04 and then an offer. It answers with a command, and the Mac answers with a result. A declined
// request carries a fresh offer, and the viewer may answer again on the same connection. Only then
// does the usual prelude (ViewerInfo, SetMode, …) begin. All of it is in clear, before the record
// layer.

/// Fixed-size, NUL-terminated UTF-8 name fields in session-select messages.
let sessionSelectNameLength = 64

/// The Mac's offer, sent straight after ServerInit when its flags include
/// ``ServerInit/Flags/sessionSelectFollows``.
///
/// `u16 length (74) | u16 version (1) | u32 commands | u32 0 | char[64] console user`
public struct SessionSelectOffer: Sendable, Equatable {
    /// One bit per ``SessionSelectCommand`` the Mac will take.
    public struct Commands: OptionSet, Sendable, Hashable {
        public var rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public init(_ command: SessionSelectCommand) {
            rawValue = 1 << UInt32(command.rawValue)
        }

        public func contains(_ command: SessionSelectCommand) -> Bool {
            contains(Commands(command))
        }
    }

    public var version: UInt16
    public var commands: Commands
    /// The display name of the account at the console, as the Mac shows it.
    public var consoleUser: String

    public init(version: UInt16 = 1, commands: Commands, consoleUser: String) {
        self.version = version
        self.commands = commands
        self.consoleUser = consoleUser
    }

    static let bodyLength = 74
    /// Far more than a Mac sends; a longer claim is refused rather than waited for.
    static let maximumLength = 1024

    public static func parse(_ reader: inout WireReader) throws(WireError) -> SessionSelectOffer {
        let length = Int(try reader.u16())
        guard length >= bodyLength - 64 + 1, length <= maximumLength else {
            throw .malformed("session-select offer of \(length) bytes")
        }
        var body = try reader.sub(length)
        let version = try body.u16()
        let commands = Commands(rawValue: try body.u32())
        try body.skip(4)
        let name = try body.take(min(sessionSelectNameLength, body.remaining))
        return SessionSelectOffer(version: version, commands: commands, consoleUser: decodeName(name))
    }

    public var encoded: Data {
        var writer = WireWriter()
        writer.u16(UInt16(Self.bodyLength))
        writer.u16(version)
        writer.u32(commands.rawValue)
        writer.u32(0)
        writer.bytes(encodeName(consoleUser))
        return writer.data
    }
}

/// What the viewer asks for.
public enum SessionSelectCommand: UInt8, Sendable, CaseIterable {
    /// Ask the person at the console to share their display. Nothing is sent back until they
    /// answer; the Mac sets no time limit.
    case askConsoleUser = 0
    /// Connect to the console's session directly. **Unverified:** macOS 27 offers only 0 and 2.
    /// Rootshell (0ccb286) takes it whenever it is offered, after a login with only a VNC password,
    /// answering like ``askConsoleUser``: 72 bytes, version 1.
    case connectToConsole = 1
    /// Log in to the viewer's own session: a new one, or the one the account already has.
    case logInAsSelf = 2
}

/// The viewer's answer to an offer.
///
/// `u16 length | u16 version | u32 0 | u8 command | u8 0 | char[64] viewer name`, and for
/// ``SessionSelectCommand/logInAsSelf`` (version 2) the 128-byte credential block of a type-30
/// login, encrypted under the login's key. The viewer name is what the console user is told the
/// request comes from ("A guest user connecting from address …").
public struct SessionSelectAnswer: Sendable, Equatable {
    public var command: SessionSelectCommand
    public var viewerName: String
    /// 128 bytes for ``SessionSelectCommand/logInAsSelf``, empty otherwise.
    public var sealedCredentials: Data

    public static let sealedCredentialsLength = 128

    public init(command: SessionSelectCommand, viewerName: String, sealedCredentials: Data = Data()) {
        self.command = command
        self.viewerName = viewerName
        self.sealedCredentials = sealedCredentials
    }

    public var encoded: Data {
        var body = WireWriter()
        body.u16(sealedCredentials.isEmpty ? 1 : 2)
        body.u32(0)
        body.u8(command.rawValue)
        body.u8(0)
        body.bytes(encodeName(viewerName))
        body.bytes(sealedCredentials)
        var writer = WireWriter()
        writer.u16(UInt16(body.data.count))
        writer.bytes(body.data)
        return writer.data
    }

    /// The Mac's side, for tools and tests that stand in for a Mac.
    public static func parse(_ reader: inout WireReader) throws(WireError) -> SessionSelectAnswer {
        let length = Int(try reader.u16())
        guard length >= 8 + sessionSelectNameLength, length <= SessionSelectOffer.maximumLength else {
            throw .malformed("session-select answer of \(length) bytes")
        }
        var body = try reader.sub(length)
        let version = try body.u16()
        try body.skip(4)
        let raw = try body.u8()
        guard let command = SessionSelectCommand(rawValue: raw) else {
            throw .malformed("session-select command \(raw)")
        }
        try body.skip(1)
        let name = decodeName(try body.take(sessionSelectNameLength))
        let credentials = version >= 2 ? try body.take(min(sealedCredentialsLength, body.remaining)) : Data()
        return SessionSelectAnswer(command: command, viewerName: name, sealedCredentials: credentials)
    }
}

/// The Mac's verdict on an answer.
///
/// `u16 length (80) | u16 version (1) | u8 status | u8 0 | 76 bytes`, where the 76 bytes are a new
/// offer (length included) after a declined request and zeros otherwise.
public enum SessionSelectResult: Sendable, Equatable {
    case accepted
    /// The console user declined. The offer stands again, and the viewer may answer it.
    case declined(SessionSelectOffer)

    static let bodyLength = 80

    public static func parse(_ reader: inout WireReader) throws(WireError) -> SessionSelectResult {
        let length = Int(try reader.u16())
        guard length >= 4, length <= SessionSelectOffer.maximumLength else {
            throw .malformed("session-select result of \(length) bytes")
        }
        var body = try reader.sub(length)
        _ = try body.u16()
        let status = try body.u8()
        try body.skip(1)
        guard status != 0 else { return .accepted }
        // A refusal with no usable offer is still a refusal; the console user is unknown.
        guard let offer = try? SessionSelectOffer.parse(&body) else {
            return .declined(SessionSelectOffer(commands: [], consoleUser: ""))
        }
        return .declined(offer)
    }

    public var encoded: Data {
        var body = WireWriter()
        body.u16(1)
        switch self {
        case .accepted:
            body.u16(0)
        case .declined(let offer):
            body.u8(1)
            body.u8(0)
            body.bytes(offer.encoded)
        }
        body.pad(to: Self.bodyLength)
        var writer = WireWriter()
        writer.u16(UInt16(Self.bodyLength))
        writer.bytes(body.data)
        return writer.data
    }
}

/// A name field: UTF-8 cut at a character boundary to leave room for the NUL, then zero-filled.
func encodeName(_ name: String) -> Data {
    var bytes = Data()
    for character in name {
        let encoded = Data(String(character).utf8)
        guard bytes.count + encoded.count < sessionSelectNameLength else { break }
        bytes.append(encoded)
    }
    bytes.append(Data(count: sessionSelectNameLength - bytes.count))
    return bytes
}

func decodeName(_ field: Data) -> String {
    let end = field.firstIndex(of: 0) ?? field.endIndex
    return String(decoding: field[field.startIndex..<end], as: UTF8.self)
}
