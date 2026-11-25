// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// The message layout and the note's limit follow rootshell-vnc's AppleCurtainProtocol (MIT, © 2026 Rootshell LLC,
// Kit Knox); both were checked against screensharingd and ScreensharingAgent on macOS 27.0.1.

public import Foundation

/// Curtain mode: the Mac's own screen shows a lock screen, with a note, while the viewer goes on
/// working in the session. It needs Remote Management; plain Screen Sharing ignores the message.
///
/// The Mac never answers the message. What it did shows in the next layout's flags
/// (``DisplayLayout/curtainState``), which come with every change of the session's console.
public enum Curtain {
    /// The longest note a Mac takes, in UTF-8 bytes. Over it the Mac logs "Session message too
    /// large" and closes the connection.
    public static let maximumNoteBytes = 512

    /// Message 12, which Screen Sharing.app names "change session visibility":
    /// `0c 00 | u16 visible (0 hides the session) | u16 note length | note, UTF-8, no NUL`.
    public static func message(curtained: Bool, note: String = "") -> Data {
        let text = curtained ? clampedNote(note) : Data()
        var writer = WireWriter(capacity: 6 + text.count)
        writer.u8(ClientMessageType.setSessionVisibility)
        writer.u8(0)
        writer.u16(curtained ? 0 : 1)
        writer.u16(UInt16(text.count))
        writer.bytes(text)
        return writer.data
    }

    /// The note as UTF-8, cut to the Mac's limit between characters, so that no character is
    /// shown half on the Mac's screen.
    static func clampedNote(_ note: String) -> Data {
        let full = Data(note.utf8)
        guard full.count > maximumNoteBytes else { return full }
        var clamped = Data(capacity: maximumNoteBytes)
        for character in note {
            let bytes = Data(String(character).utf8)
            guard clamped.count + bytes.count <= maximumNoteBytes else { break }
            clamped.append(bytes)
        }
        return clamped
    }
}

extension DisplayLayout {
    /// What a layout says about curtain mode.
    public enum CurtainState: Sendable, Hashable {
        /// The Mac would not curtain this session now: Remote Management is off, the session is not
        /// on the console's own screen (a virtual display), or the console is locked or at the
        /// Login Window. The flags tell which (``CurtainState/unavailable(because:)``).
        case unavailable(because: Flags)
        /// The session is on the console and may be curtained.
        case available
        /// The curtain is up: the session has left the console, which shows the lock screen.
        case curtained
    }

    /// ScreensharingAgent (`EncodeDisplayInfo2ForDaemon`) sets `curtain` in two cases. On the console,
    /// on a physical display, logged in and with Remote Management on, it means the session may be
    /// curtained, unless the Login Window's lock screen is up, which sets `lockScreen` instead. Off the
    /// console or on a virtual display, which sets `onVirtualDisplay`, it means the curtain (the
    /// Remote Management lock screen) is up.
    public var curtainState: CurtainState {
        guard flags.contains(.curtain) else { return .unavailable(because: flags) }
        return flags.contains(.onVirtualDisplay) ? .curtained : .available
    }
}
