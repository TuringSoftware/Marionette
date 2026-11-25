// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import RemoteDesktopCore

/// Turns what local keyboards produce into the key events a Mac expects.
///
/// Stateless. Its main job is the *fn layer*: iPhone and iPad keyboards have no Home, End, Page Up,
/// Page Down, forward Delete or function keys, so fn plus another key stands in for them, exactly as
/// on a compact Mac keyboard. fn itself is never sent.
public struct KeyTranslator: Sendable {
    public init() {}

    // MARK: fn layer

    /// The key that fn turns `key` into, if any.
    public static func functionLayerKey(for key: KeyCode) -> KeyCode? {
        switch key {
        case .leftArrow: .home
        case .rightArrow: .end
        case .upArrow: .pageUp
        case .downArrow: .pageDown
        case .deleteBackward: .deleteForward
        case .returnOrEnter: .keypadEnter
        case .digit1: .f1
        case .digit2: .f2
        case .digit3: .f3
        case .digit4: .f4
        case .digit5: .f5
        case .digit6: .f6
        case .digit7: .f7
        case .digit8: .f8
        case .digit9: .f9
        case .digit0: .f10
        case .hyphen: .f11
        case .equal: .f12
        default: nil
        }
    }

    /// Applies the fn layer. When fn is held and the key has an fn meaning, the key is replaced, its
    /// characters are dropped and fn is removed from the modifiers; otherwise the event is returned
    /// unchanged.
    public func translate(_ event: KeyEvent) -> KeyEvent {
        guard event.modifiers.contains(.function),
              let key = event.key,
              let replacement = Self.functionLayerKey(for: key)
        else { return event }
        var translated = event
        translated.key = replacement
        translated.characters = nil
        translated.charactersIgnoringModifiers = nil
        translated.modifiers.remove(.function)
        return translated
    }

    // MARK: Synthesised strokes

    /// A key going down and up, through the fn layer. When `characters` is `nil` they are filled in
    /// from the US layout where the key has a printable meaning.
    public func stroke(_ key: KeyCode, characters: String? = nil, modifiers: KeyModifiers = []) -> [InputEvent] {
        var base = characters
        if base == nil, let character = Self.character(for: key, shift: modifiers.hasShift) {
            base = String(character)
        }
        // What Control or Option turn a key into depends on the remote layout; do not guess.
        let produced = modifiers.hasControl || modifiers.hasOption ? nil : base
        let down = translate(
            KeyEvent(key: key, characters: produced, charactersIgnoringModifiers: base, modifiers: modifiers, phase: .down)
        )
        var up = down
        up.phase = .up
        return [.key(down), .key(up)]
    }

    /// What to send when a software keyboard, input method or dictation inserts `text` while
    /// `modifiers` are latched.
    ///
    /// Without modifiers (or with only Shift) text goes out as text, except that a newline is a
    /// Return key stroke and a tab is a Tab key stroke. With Control, Option, Command or fn latched
    /// the user means a shortcut, so each character becomes a key stroke on the US layout; characters
    /// that layout cannot type are sent as text.
    public func events(forInsertedText text: String, modifiers: KeyModifiers) -> [InputEvent] {
        let chord = modifiers.hasControl || modifiers.hasOption || modifiers.hasCommand || modifiers.contains(.function)
        var events: [InputEvent] = []
        var pending = ""

        func flush() {
            if !pending.isEmpty {
                events.append(.text(pending))
                pending = ""
            }
        }

        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                flush()
                events += stroke(.returnOrEnter, modifiers: modifiers)
            } else if character == "\t" {
                flush()
                events += stroke(.tab, modifiers: modifiers)
            } else if chord, let (key, needsShift) = Self.key(for: character) {
                flush()
                if needsShift, !modifiers.hasShift {
                    // The shortcut needs a shifted key the user did not latch Shift for ("?" on ⌘?).
                    let held = modifiers.subtracting(.function)
                    events.append(.key(KeyEvent(key: .leftShift, modifiers: held, phase: .down)))
                    events += stroke(key, modifiers: modifiers.union(.leftShift))
                    events.append(.key(KeyEvent(key: .leftShift, modifiers: held, phase: .up)))
                } else {
                    events += stroke(key, modifiers: modifiers)
                }
            } else {
                pending.append(character)
            }
        }
        flush()
        return events
    }

    /// What to send when a software keyboard deletes backwards (fn makes it a forward delete).
    public func eventsForDeleteBackward(modifiers: KeyModifiers) -> [InputEvent] {
        stroke(.deleteBackward, modifiers: modifiers)
    }

    // MARK: US layout

    private struct Entry: Sendable {
        var key: KeyCode
        var needsShift: Bool
    }

    private static let rows: [(key: KeyCode, plain: Character, shifted: Character)] = [
        (.a, "a", "A"), (.b, "b", "B"), (.c, "c", "C"), (.d, "d", "D"), (.e, "e", "E"), (.f, "f", "F"),
        (.g, "g", "G"), (.h, "h", "H"), (.i, "i", "I"), (.j, "j", "J"), (.k, "k", "K"), (.l, "l", "L"),
        (.m, "m", "M"), (.n, "n", "N"), (.o, "o", "O"), (.p, "p", "P"), (.q, "q", "Q"), (.r, "r", "R"),
        (.s, "s", "S"), (.t, "t", "T"), (.u, "u", "U"), (.v, "v", "V"), (.w, "w", "W"), (.x, "x", "X"),
        (.y, "y", "Y"), (.z, "z", "Z"),
        (.digit1, "1", "!"), (.digit2, "2", "@"), (.digit3, "3", "#"), (.digit4, "4", "$"),
        (.digit5, "5", "%"), (.digit6, "6", "^"), (.digit7, "7", "&"), (.digit8, "8", "*"),
        (.digit9, "9", "("), (.digit0, "0", ")"),
        (.hyphen, "-", "_"), (.equal, "=", "+"), (.openBracket, "[", "{"), (.closeBracket, "]", "}"),
        (.backslash, "\\", "|"), (.semicolon, ";", ":"), (.quote, "'", "\""), (.graveAccent, "`", "~"),
        (.comma, ",", "<"), (.period, ".", ">"), (.slash, "/", "?"),
    ]

    private static let keysByCharacter: [Character: Entry] = {
        var table: [Character: Entry] = [
            " ": Entry(key: .space, needsShift: false),
            "\n": Entry(key: .returnOrEnter, needsShift: false),
            "\r": Entry(key: .returnOrEnter, needsShift: false),
            "\t": Entry(key: .tab, needsShift: false),
        ]
        for row in rows {
            table[row.plain] = Entry(key: row.key, needsShift: false)
            table[row.shifted] = Entry(key: row.key, needsShift: true)
        }
        return table
    }()

    private static let charactersByKey: [KeyCode: (plain: Character, shifted: Character)] = {
        var table: [KeyCode: (plain: Character, shifted: Character)] = [.space: (" ", " ")]
        for row in rows {
            table[row.key] = (row.plain, row.shifted)
        }
        return table
    }()

    /// The key that types `character` on a US keyboard, and whether Shift must be held.
    public static func key(for character: Character) -> (key: KeyCode, needsShift: Bool)? {
        keysByCharacter[character].map { ($0.key, $0.needsShift) }
    }

    /// What `key` types on a US keyboard, or `nil` for keys that type nothing.
    public static func character(for key: KeyCode, shift: Bool) -> Character? {
        charactersByKey[key].map { shift ? $0.shifted : $0.plain }
    }

    /// The modifier keys to press for a set of flags, in the order a person presses them
    /// (Control, Option, Shift, Command; left before right). fn and Caps Lock are not keys to press.
    public static func keys(for modifiers: KeyModifiers) -> [KeyCode] {
        let order: [(KeyModifiers, KeyCode)] = [
            (.leftControl, .leftControl), (.rightControl, .rightControl),
            (.leftOption, .leftOption), (.rightOption, .rightOption),
            (.leftShift, .leftShift), (.rightShift, .rightShift),
            (.leftCommand, .leftCommand), (.rightCommand, .rightCommand),
        ]
        return order.filter { modifiers.contains($0.0) }.map(\.1)
    }
}
