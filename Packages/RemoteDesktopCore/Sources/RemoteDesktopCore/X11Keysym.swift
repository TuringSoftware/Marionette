// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Turns key events into the X11 keysyms that RFB (VNC) carries.
///
/// Servers derive Shift from the keysym — an uppercase letter brings Shift with it and a held Shift
/// is dropped from a lowercase one — so shortcuts must be sent as the letter that matches the
/// modifiers actually held.
public enum X11Keysym {
    public static let backSpace: UInt32 = 0xff08
    public static let tab: UInt32 = 0xff09
    public static let `return`: UInt32 = 0xff0d
    public static let escape: UInt32 = 0xff1b
    public static let delete: UInt32 = 0xffff
    public static let home: UInt32 = 0xff50
    public static let left: UInt32 = 0xff51
    public static let up: UInt32 = 0xff52
    public static let right: UInt32 = 0xff53
    public static let down: UInt32 = 0xff54
    public static let pageUp: UInt32 = 0xff55
    public static let pageDown: UInt32 = 0xff56
    public static let end: UInt32 = 0xff57
    public static let shiftLeft: UInt32 = 0xffe1
    public static let shiftRight: UInt32 = 0xffe2
    public static let controlLeft: UInt32 = 0xffe3
    public static let controlRight: UInt32 = 0xffe4
    public static let capsLock: UInt32 = 0xffe5
    public static let metaLeft: UInt32 = 0xffe7
    public static let metaRight: UInt32 = 0xffe8
    public static let altLeft: UInt32 = 0xffe9
    public static let altRight: UInt32 = 0xffea
    public static let superLeft: UInt32 = 0xffeb
    public static let superRight: UInt32 = 0xffec

    /// Which keysyms the Option and Command keys are sent as.
    public enum ModifierStyle: Sendable {
        /// Option is Alt and Command is Super, as X11 servers expect.
        case standard
        /// For a Mac's own VNC server, which maps keysyms by its own table: Meta lands on Option,
        /// and Alt, Super and Hyper all land on Command. It also reads a Unicode keysym as one
        /// UTF-16 code unit, so characters beyond U+FFFF go as their two surrogates (seen on
        /// macOS 27 on both its protocols: 👍 as U+1F44D never arrives, as D83D and DC4D it does).
        case mac
    }

    /// The keysym for a key that has no character, or whose meaning is its position.
    public static func forKey(_ key: KeyCode, style: ModifierStyle = .standard) -> UInt32? {
        switch key {
        case .returnOrEnter: return `return`
        case .escape: return escape
        case .deleteBackward: return backSpace
        case .deleteForward: return delete
        case .tab: return tab
        case .space: return 0x20
        case .leftArrow: return left
        case .rightArrow: return right
        case .upArrow: return up
        case .downArrow: return down
        case .home: return home
        case .end: return end
        case .pageUp: return pageUp
        case .pageDown: return pageDown
        case .insert: return 0xff63
        case .printScreen: return 0xff61
        case .scrollLock: return 0xff14
        case .pause: return 0xff13
        case .application: return 0xff67
        case .capsLock: return capsLock
        case .leftShift: return shiftLeft
        case .rightShift: return shiftRight
        case .leftControl: return controlLeft
        case .rightControl: return controlRight
        case .leftOption: return style == .mac ? metaLeft : altLeft
        case .rightOption: return style == .mac ? metaRight : altRight
        case .leftCommand: return superLeft
        case .rightCommand: return superRight
        case .keypadEnter: return 0xff8d
        case .keypadSlash: return 0xffaf
        case .keypadAsterisk: return 0xffaa
        case .keypadHyphen: return 0xffad
        case .keypadPlus: return 0xffab
        case .keypadPeriod: return 0xffae
        case .keypadEqual: return 0xffbd
        case .keypadNumLock: return 0xff7f
        default:
            break
        }
        let raw = key.rawValue
        if (KeyCode.f1.rawValue...KeyCode.f12.rawValue).contains(raw) {
            return 0xffbe + UInt32(raw - KeyCode.f1.rawValue)
        }
        // F13 to F24 are consecutive in both numberings; F21–F24 have no names of their own here.
        if (KeyCode.f13.rawValue...KeyCode.f13.rawValue + 11).contains(raw) {
            return 0xffca + UInt32(raw - KeyCode.f13.rawValue)
        }
        if (KeyCode.keypad1.rawValue...KeyCode.keypad9.rawValue).contains(raw) {
            return 0xffb1 + UInt32(raw - KeyCode.keypad1.rawValue)
        }
        if key == .keypad0 { return 0xffb0 }
        return nil
    }

    /// The keysym for one character: Latin-1 maps to itself, everything else to its Unicode keysym.
    /// `nil` when the character takes more than one keysym, even composed (NFC); ``keysyms(for:)``
    /// types those.
    public static func forCharacter(_ character: Character, style: ModifierStyle = .standard) -> UInt32? {
        let keysyms = keysyms(for: character, style: style)
        return keysyms.count == 1 ? keysyms[0] : nil
    }

    /// The keysyms that type one character, in order.
    ///
    /// A keysym carries one Unicode scalar, while a character may be several: an emoji with a
    /// variation selector (❤️) or a skin tone, a flag, a family joined by zero-width joiners, or a
    /// letter and its accent as some input methods and pastes deliver them. The character is
    /// composed (NFC) first, so a letter with an accent that has a composed form is one keysym;
    /// whatever remains is typed one scalar after another, and the remote text system joins them
    /// into one character again. Scalars with no keysym (other control characters) are left out.
    public static func keysyms(for character: Character, style: ModifierStyle = .standard) -> [UInt32] {
        // CR LF is one character in Swift but one line break.
        if character == "\r\n" { return [`return`] }
        return composedScalars(character).flatMap { scalar -> [UInt32] in
            if style == .mac, scalar.value > 0xffff {
                return scalar.utf16.map { 0x0100_0000 | UInt32($0) }
            }
            return forScalar(scalar).map { [$0] } ?? []
        }
    }

    private static func composedScalars(_ character: Character) -> [Unicode.Scalar] {
        let scalars = character.unicodeScalars
        guard scalars.count > 1 else { return Array(scalars) }
        return Array(String(character).precomposedStringWithCanonicalMapping.unicodeScalars)
    }

    private static func forScalar(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x0a, 0x0d: return `return`
        case 0x09: return tab
        case 0x08: return backSpace
        case 0x1b: return escape
        case 0x7f: return delete
        case 0x20...0x7e, 0xa0...0xff: return scalar.value
        case 0x100...0x10ffff: return 0x0100_0000 | scalar.value
        default: return nil
        }
    }

    /// What a US keyboard produces for a key position with and without Shift, for when an event
    /// carries no characters.
    static func usLayout(_ key: KeyCode) -> (plain: Character, shifted: Character)? {
        let raw = key.rawValue
        if (KeyCode.a.rawValue...KeyCode.z.rawValue).contains(raw) {
            let letter = UInt8(ascii: "a") + UInt8(raw - KeyCode.a.rawValue)
            return (Character(UnicodeScalar(letter)), Character(UnicodeScalar(letter - 32)))
        }
        switch key {
        case .digit1: return ("1", "!")
        case .digit2: return ("2", "@")
        case .digit3: return ("3", "#")
        case .digit4: return ("4", "$")
        case .digit5: return ("5", "%")
        case .digit6: return ("6", "^")
        case .digit7: return ("7", "&")
        case .digit8: return ("8", "*")
        case .digit9: return ("9", "(")
        case .digit0: return ("0", ")")
        case .hyphen: return ("-", "_")
        case .equal: return ("=", "+")
        case .openBracket: return ("[", "{")
        case .closeBracket: return ("]", "}")
        case .backslash: return ("\\", "|")
        case .semicolon: return (";", ":")
        case .quote: return ("'", "\"")
        case .graveAccent: return ("`", "~")
        case .comma: return (",", "<")
        case .period: return (".", ">")
        case .slash: return ("/", "?")
        default: return nil
        }
    }

    /// The keysym to send for a key event, or `nil` if the Mac has nothing for it.
    ///
    /// Keys named by position win over characters, so Return is Return whatever the layout types.
    /// With Command or Control held the key is a shortcut: the letter is sent in the case that
    /// matches Shift, because servers derive Shift from the keysym's case.
    public static func forEvent(_ event: KeyEvent, style: ModifierStyle = .standard) -> UInt32? {
        if let key = event.key, let named = forKey(key, style: style) {
            return named
        }
        let isShortcut = event.modifiers.hasCommand || event.modifiers.hasControl
        if isShortcut {
            let base = event.charactersIgnoringModifiers?.first
                ?? event.key.flatMap(usLayout).map { event.modifiers.hasShift ? $0.shifted : $0.plain }
            guard let base else { return nil }
            let cased = event.modifiers.hasShift ? Character(base.uppercased()) : Character(base.lowercased())
            return forCharacter(cased.unicodeScalars.count == 1 ? cased : base)
        }
        if let character = event.characters?.first, event.characters?.count == 1 {
            return forCharacter(character, style: style)
        }
        if let key = event.key, let pair = usLayout(key) {
            // Caps Lock shifts letters only, and Shift undoes it.
            let capsApplies = event.modifiers.contains(.capsLock) && pair.plain.isLetter
            return forCharacter(event.modifiers.hasShift != capsApplies ? pair.shifted : pair.plain)
        }
        return nil
    }
}
