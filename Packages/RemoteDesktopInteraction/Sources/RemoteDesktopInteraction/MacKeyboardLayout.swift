// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
public import RemoteDesktopCore

/// The keys of an on-screen Mac keyboard and where they sit, for a front end to draw. Pure data:
/// rows of keys with widths in key units. Gaps, corner radii and fonts are the drawer's business.
public struct MacKeyboardLayout: Sendable, Hashable {
    public struct Key: Sendable, Hashable, Identifiable {
        public enum Role: Sendable, Hashable {
            /// Types something: letters, digits, punctuation.
            case character
            /// Shift, Control, Option, Command and fn; meant to be wired to a ``ModifierLatch``.
            case modifier(ModifierLatch.Modifier)
            /// F1 … F12.
            case function
            /// esc, tab, return, delete, space, the arrows and caps lock.
            case editing
        }

        /// Stable and unique within the layout. The built-in layouts use the name of the key's
        /// ``KeyCode`` constant: "a", "digit1", "hyphen", "f5", "leftShift", "escape", "space",
        /// "leftArrow", "function".
        public var id: String
        public var key: KeyCode
        public var role: Role
        /// What to draw: "a", "1", "esc", "⌘", "⇧", "←", "F5"; empty for the space bar.
        public var label: String
        /// What to draw while Shift is in effect ("A", "!"); `nil` when Shift does not change the legend.
        public var shiftedLabel: String?
        /// Localised name for assistive technologies: "A", "Left Shift", "Escape", "F5", "Space".
        public var accessibilityName: String
        /// In key units; a letter key is 1.
        public var width: Double

        /// For a modifier key, which of the modifier's two keys this is; wire it to
        /// ``ModifierLatch/tap(_:side:)`` so a right-hand key is sent as the right-hand key.
        public var modifierSide: ModifierLatch.Side { ModifierLatch.Side(key: key) }

        public init(
            id: String,
            key: KeyCode,
            role: Role,
            label: String,
            shiftedLabel: String? = nil,
            accessibilityName: String,
            width: Double = 1
        ) {
            self.id = id
            self.key = key
            self.role = role
            self.label = label
            self.shiftedLabel = shiftedLabel
            self.accessibilityName = accessibilityName
            self.width = width
        }
    }

    public struct Row: Sendable, Hashable, Identifiable {
        /// Position in ``MacKeyboardLayout/ansi``, top to bottom from 0. ``MacKeyboardLayout/ansiCompact``
        /// keeps these, so a row is the same row in both.
        public var id: Int
        public var keys: [Key]
        /// Height relative to a letter key: 0.6 for the function row, 1 otherwise.
        public var heightFactor: Double

        public init(id: Int, keys: [Key], heightFactor: Double = 1) {
            self.id = id
            self.keys = keys
            self.heightFactor = heightFactor
        }

        /// Sum of the keys' widths, in key units.
        public var unitWidth: Double {
            keys.reduce(0) { $0 + $1.width }
        }
    }

    public var rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows
    }

    /// Total width of the widest row, in key units. Every row of the built-in layouts is this wide.
    public var unitWidth: Double {
        rows.reduce(0) { max($0, $1.unitWidth) }
    }

    /// Sum of the rows' height factors: the layout's height in letter-key heights.
    public var unitHeight: Double {
        rows.reduce(0) { $0 + $1.heightFactor }
    }

    public func key(withID id: String) -> Key? {
        for row in rows {
            if let key = row.keys.first(where: { $0.id == id }) { return key }
        }
        return nil
    }

    // MARK: Built-in layouts

    /// US ANSI, arranged like a compact Mac laptop keyboard, 14.5 units wide:
    ///
    /// ```
    /// esc F1 … F12
    /// ` 1 … 0 - = delete
    /// tab q … ] \
    /// caps a … ' return
    /// shift z … / shift
    /// fn control option command space command option ← ↑ ↓ →
    /// ```
    ///
    /// The arrows are four keys of full height in the bottom row.
    public static let ansi = MacKeyboardLayout(rows: [
        Row(
            id: 0,
            keys: [editing("escape", .escape, "esc", String(localized: "Escape", bundle: #bundle), width: 1.75)] + functionKeys(),
            heightFactor: 0.6
        ),
        Row(
            id: 1,
            keys: characters(
                ("graveAccent", .graveAccent, String(localized: "Grave Accent", bundle: #bundle)),
                ("digit1", .digit1, "1"), ("digit2", .digit2, "2"), ("digit3", .digit3, "3"),
                ("digit4", .digit4, "4"), ("digit5", .digit5, "5"), ("digit6", .digit6, "6"),
                ("digit7", .digit7, "7"), ("digit8", .digit8, "8"), ("digit9", .digit9, "9"),
                ("digit0", .digit0, "0"),
                ("hyphen", .hyphen, String(localized: "Hyphen", bundle: #bundle)), ("equal", .equal, String(localized: "Equals", bundle: #bundle))
            ) + [editing("deleteBackward", .deleteBackward, "⌫", String(localized: "Delete", bundle: #bundle), width: 1.5)]
        ),
        Row(
            id: 2,
            keys: [editing("tab", .tab, "⇥", String(localized: "Tab", bundle: #bundle), width: 1.5)]
                + letters(.q, .w, .e, .r, .t, .y, .u, .i, .o, .p)
                + characters(
                    ("openBracket", .openBracket, String(localized: "Left Bracket", bundle: #bundle)),
                    ("closeBracket", .closeBracket, String(localized: "Right Bracket", bundle: #bundle)),
                    ("backslash", .backslash, String(localized: "Backslash", bundle: #bundle))
                )
        ),
        Row(
            id: 3,
            keys: [editing("capsLock", .capsLock, "⇪", String(localized: "Caps Lock", bundle: #bundle), width: 1.75)]
                + letters(.a, .s, .d, .f, .g, .h, .j, .k, .l)
                + characters(("semicolon", .semicolon, String(localized: "Semicolon", bundle: #bundle)), ("quote", .quote, String(localized: "Quote", bundle: #bundle)))
                + [editing("returnOrEnter", .returnOrEnter, String(localized: "↩\u{FE0E}", bundle: #bundle), String(localized: "Return", bundle: #bundle), width: 1.75)]
        ),
        Row(
            id: 4,
            keys: [modifier("leftShift", .leftShift, .shift, String(localized: "Left Shift", bundle: #bundle), width: 2.25)]
                + letters(.z, .x, .c, .v, .b, .n, .m)
                + characters(("comma", .comma, String(localized: "Comma", bundle: #bundle)), ("period", .period, String(localized: "Period", bundle: #bundle)), ("slash", .slash, String(localized: "Slash", bundle: #bundle)))
                + [modifier("rightShift", .rightShift, .shift, String(localized: "Right Shift", bundle: #bundle), width: 2.25)]
        ),
        Row(
            id: 5,
            keys: [
                modifier("function", .function, .function, String(localized: "Function", bundle: #bundle)),
                modifier("leftControl", .leftControl, .control, String(localized: "Control", bundle: #bundle)),
                modifier("leftOption", .leftOption, .option, String(localized: "Left Option", bundle: #bundle)),
                modifier("leftCommand", .leftCommand, .command, String(localized: "Left Command", bundle: #bundle), width: 1.25),
                editing("space", .space, "", String(localized: "Space", bundle: #bundle), width: 4),
                modifier("rightCommand", .rightCommand, .command, String(localized: "Right Command", bundle: #bundle), width: 1.25),
                modifier("rightOption", .rightOption, .option, String(localized: "Right Option", bundle: #bundle)),
                editing("leftArrow", .leftArrow, "←", String(localized: "Left Arrow", bundle: #bundle)),
                editing("upArrow", .upArrow, "↑", String(localized: "Up Arrow", bundle: #bundle)),
                editing("downArrow", .downArrow, "↓", String(localized: "Down Arrow", bundle: #bundle)),
                editing("rightArrow", .rightArrow, "→", String(localized: "Right Arrow", bundle: #bundle)),
            ]
        ),
    ])

    /// ``ansi`` without the function row, for short panes. fn plus the number row still reaches
    /// F1 … F12 through the fn layer.
    public static let ansiCompact = MacKeyboardLayout(rows: Array(ansi.rows.dropFirst()))

    // MARK: Builders

    private static func editing(_ id: String, _ key: KeyCode, _ label: String, _ name: String, width: Double = 1) -> Key {
        Key(id: id, key: key, role: .editing, label: label, accessibilityName: name, width: width)
    }

    private static func modifier(
        _ id: String,
        _ key: KeyCode,
        _ modifier: ModifierLatch.Modifier,
        _ name: String,
        width: Double = 1
    ) -> Key {
        Key(id: id, key: key, role: .modifier(modifier), label: modifier.symbol, accessibilityName: name, width: width)
    }

    /// A key that types: its legends come from the US layout table the translator uses.
    private static func character(_ id: String, _ key: KeyCode, _ name: String) -> Key {
        let plain = KeyTranslator.character(for: key, shift: false).map { String($0) } ?? ""
        let shifted = KeyTranslator.character(for: key, shift: true).map { String($0) }
        return Key(
            id: id,
            key: key,
            role: .character,
            label: plain,
            shiftedLabel: shifted == plain ? nil : shifted,
            accessibilityName: name
        )
    }

    private static func characters(_ entries: (id: String, key: KeyCode, name: String)...) -> [Key] {
        entries.map { character($0.id, $0.key, $0.name) }
    }

    /// Letter keys are named by what they type: id "a", accessibility name "A".
    private static func letters(_ keys: KeyCode...) -> [Key] {
        keys.map { key in
            let letter = KeyTranslator.character(for: key, shift: false).map { String($0) } ?? ""
            return character(letter, key, letter.uppercased())
        }
    }

    /// F1 … F12. Twelve keys of 1.0625 units beside a 1.75-unit esc make the 14.5 of the other rows.
    private static func functionKeys() -> [Key] {
        (0..<12).map { index in
            let name = "F\(index + 1)"
            return Key(
                id: "f\(index + 1)",
                key: KeyCode(rawValue: KeyCode.f1.rawValue + UInt16(index)),
                role: .function,
                label: name,
                accessibilityName: name,
                width: 1.0625
            )
        }
    }
}
