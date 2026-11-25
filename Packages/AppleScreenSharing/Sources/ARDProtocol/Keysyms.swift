// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import RemoteDesktopCore

/// Key mapping for a Mac's Screen Sharing server: the shared X11 table, with the modifier keysyms a
/// Mac maps to its own Option and Command keys.
public enum Keysym {
    public static let backSpace = X11Keysym.backSpace
    public static let tab = X11Keysym.tab
    public static let `return` = X11Keysym.return
    public static let escape = X11Keysym.escape
    public static let delete = X11Keysym.delete
    public static let shiftLeft = X11Keysym.shiftLeft
    public static let shiftRight = X11Keysym.shiftRight
    public static let controlLeft = X11Keysym.controlLeft
    public static let controlRight = X11Keysym.controlRight
    public static let capsLock = X11Keysym.capsLock
    /// Option on a Mac.
    public static let metaLeft = X11Keysym.metaLeft
    public static let metaRight = X11Keysym.metaRight
    /// Command on a Mac.
    public static let superLeft = X11Keysym.superLeft
    public static let superRight = X11Keysym.superRight

    public static func forKey(_ key: KeyCode) -> UInt32? {
        X11Keysym.forKey(key, style: .mac)
    }

    /// A Mac drops keysyms above U+FFFF, so a character outside the Basic Multilingual Plane has
    /// none here; `X11Keysym.keysyms(for:style:)` sends it as its UTF-16 surrogates instead.
    public static func forCharacter(_ character: Character) -> UInt32? {
        X11Keysym.forCharacter(character, style: .mac)
    }

    /// The keysym to send a Mac for a key event, or `nil` if the Mac has nothing for it. Other
    /// servers of Apple's protocol (wayshare) take the `.standard` style.
    public static func forEvent(_ event: KeyEvent, style: X11Keysym.ModifierStyle = .mac) -> UInt32? {
        X11Keysym.forEvent(event, style: style)
    }
}

/// Pointer buttons in the numbering a Mac reads on this protocol revision: bit 0 left, bit 1 right,
/// bit 2 centre — not RFB's left, middle, right.
public enum AppleButtonMask {
    public static func encode(_ buttons: PointerButtons) -> UInt8 {
        var mask: UInt8 = 0
        if buttons.contains(.primary) { mask |= 0x01 }
        if buttons.contains(.secondary) { mask |= 0x02 }
        if buttons.contains(.middle) { mask |= 0x04 }
        return mask
    }
}
