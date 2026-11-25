// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
public import RemoteDesktopCore

/// A named key combination that can be sent with one tap.
public struct Shortcut: Sendable, Hashable, Identifiable {
    /// Stable identifier ("system.spotlight").
    public var id: String
    public var title: String
    public var category: ShortcutCatalog.Category
    public var modifiers: KeyModifiers
    public var key: KeyCode

    public init(id: String, title: String, category: ShortcutCatalog.Category, modifiers: KeyModifiers, key: KeyCode) {
        self.id = id
        self.title = title
        self.category = category
        self.modifiers = modifiers
        self.key = key
    }

    /// The combination as printed in Mac menus, for example "⌃⌘Q".
    public var symbols: String {
        modifiers.shortcutSymbols + key.shortcutSymbol
    }

    /// How long to hold the chord between ``pressEvents`` and ``releaseEvents``.
    ///
    /// Sent in one burst, a chord is over before some apps look: those that read the live modifier
    /// state rather than the event's flags see the modifiers already up and take the key alone.
    public static let holdDuration: Duration = .milliseconds(75)

    /// The whole chord in one burst: ``pressEvents`` then ``releaseEvents``. Prefer sending the two
    /// halves ``holdDuration`` apart.
    public var events: [InputEvent] {
        pressEvents + releaseEvents
    }

    /// The first half of the chord: modifier keys down in order, then the key down.
    public var pressEvents: [InputEvent] {
        var held: KeyModifiers = []
        var events: [InputEvent] = []
        for modifierKey in KeyTranslator.keys(for: modifiers) {
            events.append(.key(KeyEvent(key: modifierKey, modifiers: held, phase: .down)))
            if let flag = modifierKey.modifier { held.insert(flag) }
        }
        return events + KeyTranslator().stroke(key, modifiers: held).prefix(1)
    }

    /// The second half: the key up, then the modifier keys up in reverse order.
    public var releaseEvents: [InputEvent] {
        let modifierKeys = KeyTranslator.keys(for: modifiers)
        var held: KeyModifiers = modifierKeys.reduce(into: []) { held, key in if let flag = key.modifier { held.insert(flag) } }
        var events = Array(KeyTranslator().stroke(key, modifiers: held).suffix(1))
        for modifierKey in modifierKeys.reversed() {
            if let flag = modifierKey.modifier { held.remove(flag) }
            events.append(.key(KeyEvent(key: modifierKey, modifiers: held, phase: .up)))
        }
        return events
    }
}

/// The macOS shortcuts worth a menu item: things that are awkward or impossible to type on a touch
/// keyboard, or that iOS would otherwise keep for itself.
public enum ShortcutCatalog {
    public enum Category: String, Sendable, Hashable, CaseIterable {
        case system
        case windows
        case editing
        case screenshots

        public var title: String {
            switch self {
            case .system: String(localized: "System", bundle: #bundle)
            case .windows: String(localized: "Windows and Apps", bundle: #bundle)
            case .editing: String(localized: "Editing", bundle: #bundle)
            case .screenshots: String(localized: "Screenshots", bundle: #bundle)
            }
        }
    }

    public static let all: [Shortcut] = [
        Shortcut(id: "system.spotlight", title: String(localized: "Spotlight", bundle: #bundle), category: .system, modifiers: .leftCommand, key: .space),
        Shortcut(id: "system.appSwitcher", title: String(localized: "App Switcher", bundle: #bundle), category: .system, modifiers: .leftCommand, key: .tab),
        Shortcut(id: "system.missionControl", title: String(localized: "Mission Control", bundle: #bundle), category: .system, modifiers: .leftControl, key: .upArrow),
        Shortcut(id: "system.appWindows", title: String(localized: "App Windows", bundle: #bundle), category: .system, modifiers: .leftControl, key: .downArrow),
        Shortcut(id: "system.spaceLeft", title: String(localized: "Move Left a Space", bundle: #bundle), category: .system, modifiers: .leftControl, key: .leftArrow),
        Shortcut(id: "system.spaceRight", title: String(localized: "Move Right a Space", bundle: #bundle), category: .system, modifiers: .leftControl, key: .rightArrow),
        Shortcut(id: "system.forceQuit", title: String(localized: "Force Quit…", bundle: #bundle), category: .system, modifiers: [.leftOption, .leftCommand], key: .escape),
        Shortcut(id: "system.lockScreen", title: String(localized: "Lock Screen", bundle: #bundle), category: .system, modifiers: [.leftControl, .leftCommand], key: .q),
        Shortcut(id: "system.logOut", title: String(localized: "Log Out…", bundle: #bundle), category: .system, modifiers: [.leftShift, .leftCommand], key: .q),
        Shortcut(id: "system.toggleDock", title: String(localized: "Dock Hiding", bundle: #bundle), category: .system, modifiers: [.leftOption, .leftCommand], key: .d),
        Shortcut(id: "system.characterViewer", title: String(localized: "Emoji & Symbols", bundle: #bundle), category: .system, modifiers: [.leftControl, .leftCommand], key: .space),

        Shortcut(id: "windows.close", title: String(localized: "Close Window", bundle: #bundle), category: .windows, modifiers: .leftCommand, key: .w),
        Shortcut(id: "windows.minimise", title: String(localized: "Minimise", bundle: #bundle), category: .windows, modifiers: .leftCommand, key: .m),
        Shortcut(id: "windows.hide", title: String(localized: "Hide App", bundle: #bundle), category: .windows, modifiers: .leftCommand, key: .h),
        Shortcut(id: "windows.quit", title: String(localized: "Quit App", bundle: #bundle), category: .windows, modifiers: .leftCommand, key: .q),
        Shortcut(id: "windows.new", title: String(localized: "New Window", bundle: #bundle), category: .windows, modifiers: .leftCommand, key: .n),
        Shortcut(id: "windows.newTab", title: String(localized: "New Tab", bundle: #bundle), category: .windows, modifiers: .leftCommand, key: .t),
        Shortcut(id: "windows.cycle", title: String(localized: "Next Window", bundle: #bundle), category: .windows, modifiers: .leftCommand, key: .graveAccent),
        Shortcut(id: "windows.fullScreen", title: String(localized: "Full Screen", bundle: #bundle), category: .windows, modifiers: [.leftControl, .leftCommand], key: .f),
        Shortcut(id: "windows.settings", title: String(localized: "Settings…", bundle: #bundle), category: .windows, modifiers: .leftCommand, key: .comma),

        Shortcut(id: "editing.copy", title: String(localized: "Copy", bundle: #bundle), category: .editing, modifiers: .leftCommand, key: .c),
        Shortcut(id: "editing.cut", title: String(localized: "Cut", bundle: #bundle), category: .editing, modifiers: .leftCommand, key: .x),
        Shortcut(id: "editing.paste", title: String(localized: "Paste", bundle: #bundle), category: .editing, modifiers: .leftCommand, key: .v),
        Shortcut(id: "editing.undo", title: String(localized: "Undo", bundle: #bundle), category: .editing, modifiers: .leftCommand, key: .z),
        Shortcut(id: "editing.redo", title: String(localized: "Redo", bundle: #bundle), category: .editing, modifiers: [.leftShift, .leftCommand], key: .z),
        Shortcut(id: "editing.selectAll", title: String(localized: "Select All", bundle: #bundle), category: .editing, modifiers: .leftCommand, key: .a),
        Shortcut(id: "editing.find", title: String(localized: "Find", bundle: #bundle), category: .editing, modifiers: .leftCommand, key: .f),
        Shortcut(id: "editing.save", title: String(localized: "Save", bundle: #bundle), category: .editing, modifiers: .leftCommand, key: .s),

        Shortcut(id: "screenshots.screen", title: String(localized: "Entire Screen", bundle: #bundle), category: .screenshots, modifiers: [.leftShift, .leftCommand], key: .digit3),
        Shortcut(id: "screenshots.selection", title: String(localized: "Selection", bundle: #bundle), category: .screenshots, modifiers: [.leftShift, .leftCommand], key: .digit4),
        Shortcut(id: "screenshots.toolbar", title: String(localized: "Options", bundle: #bundle), category: .screenshots, modifiers: [.leftShift, .leftCommand], key: .digit5),
    ]

    public static func shortcuts(in category: Category) -> [Shortcut] {
        all.filter { $0.category == category }
    }

    public static func shortcut(withID id: String) -> Shortcut? {
        all.first { $0.id == id }
    }
}

extension KeyModifiers {
    /// The modifiers as Mac menus print them, in Apple's order: fn ⌃ ⌥ ⇧ ⌘.
    public var shortcutSymbols: String {
        var symbols = ""
        if contains(.function) { symbols += "fn" }
        if hasControl { symbols += "⌃" }
        if hasOption { symbols += "⌥" }
        if hasShift { symbols += "⇧" }
        if hasCommand { symbols += "⌘" }
        return symbols
    }
}

extension KeyCode {
    /// The key as Mac menus print it: "Q", "⎋", "F5", "Space".
    public var shortcutSymbol: String {
        switch self {
        case .space: return String(localized: "Space", bundle: #bundle)
        case .returnOrEnter: return String(localized: "↩\u{FE0E}", bundle: #bundle)
        case .keypadEnter: return "⌤"
        case .escape: return "⎋"
        case .tab: return "⇥"
        case .deleteBackward: return "⌫"
        case .deleteForward: return "⌦"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .home: return "↖"
        case .end: return "↘"
        case .pageUp: return "⇞"
        case .pageDown: return "⇟"
        case .capsLock: return "⇪"
        case .leftControl, .rightControl: return "⌃"
        case .leftOption, .rightOption: return "⌥"
        case .leftShift, .rightShift: return "⇧"
        case .leftCommand, .rightCommand: return "⌘"
        case .function: return "fn"
        default: break
        }
        if (KeyCode.f1.rawValue...KeyCode.f12.rawValue).contains(rawValue) {
            return "F\(rawValue - KeyCode.f1.rawValue + 1)"
        }
        if (KeyCode.f13.rawValue...KeyCode.f20.rawValue).contains(rawValue) {
            return "F\(rawValue - KeyCode.f13.rawValue + 13)"
        }
        if let character = KeyTranslator.character(for: self, shift: false) {
            return String(character).uppercased()
        }
        return "?"
    }
}
