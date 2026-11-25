// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import RemoteDesktopCore

/// Every key that is down right now, on the on-screen keyboard and on a hardware keyboard alike.
///
/// The one place that turns "a key went down / came up" into key events, so that the promises of
/// ``KeyEvent`` hold whatever the platform delivers:
/// - exactly one down and one up per press — auto-repeat downs and stray ups are dropped;
/// - the up names the key the down named, even when the fn layer translated it and fn has been let
///   go in between;
/// - ``releaseAll()`` lets go of everything, so nothing stays stuck when the app loses focus.
///
/// The two sources are tracked separately: the same key held on screen and on the hardware keyboard
/// is two presses, each with its own down and up.
public struct KeyboardState: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        case onScreen
        case hardware
    }

    private struct Press: Sendable, Hashable {
        /// The key that was physically pressed.
        var key: KeyCode
        var source: Source
        /// The key that was sent for it; `nil` for fn, which never leaves this side.
        var sent: KeyCode?
        var characters: String?
        var charactersIgnoringModifiers: String?

        var usedFunctionLayer: Bool { sent != nil && sent != key }
    }

    /// In the order the keys went down.
    private var presses: [Press] = []
    private var capsLock = false

    /// Modifiers latched on screen (``ModifierLatch/activeModifiers``). Merged into the modifiers of
    /// every key event; the latch sends the key events of its own modifier keys.
    public var latchedModifiers: KeyModifiers = []

    public init() {}

    /// Modifiers held right now, left and right told apart by the modifier keys themselves, plus
    /// `.capsLock` while caps lock is on. Counts modifier keys passed to ``keyDown(_:characters:charactersIgnoringModifiers:source:)``
    /// from either source; latched modifiers are not included.
    public var hardwareModifiers: KeyModifiers {
        var modifiers: KeyModifiers = capsLock ? .capsLock : []
        for press in presses {
            if let flag = press.key.modifier { modifiers.formUnion(flag) }
        }
        return modifiers
    }

    /// ``hardwareModifiers`` and ``latchedModifiers`` together: what a key pressed now would carry,
    /// and what belongs in ``InteractionContext/modifiers``.
    public var modifiers: KeyModifiers {
        hardwareModifiers.union(latchedModifiers)
    }

    /// No key is held. Caps lock and latched modifiers are not keys held here.
    public var isEmpty: Bool { presses.isEmpty }

    /// A key went down.
    ///
    /// Returns the events to send: nothing for an auto-repeat (the key is already down from that
    /// source) and for fn, otherwise one key-down.
    ///
    /// - The fn layer (``KeyTranslator/translate(_:)``) is applied here and remembered, so the
    ///   matching ``keyUp(_:source:)`` names the translated key even if fn was released first.
    /// - Modifier keys update ``hardwareModifiers`` and are sent as their own key events.
    /// - The event's modifiers are ``modifiers`` without the key itself, and without `.function`
    ///   when the fn layer translated the key.
    /// - For an on-screen key, characters the caller leaves `nil` are filled in from the US layout.
    ///   `characters` stays `nil` while Control, Option or Command is in effect: what they turn a
    ///   key into depends on the remote layout.
    public mutating func keyDown(
        _ key: KeyCode,
        characters: String? = nil,
        charactersIgnoringModifiers: String? = nil,
        source: Source
    ) -> [InputEvent] {
        guard index(of: key, source: source) == nil else { return [] }
        if key == .function {
            presses.append(Press(key: key, source: source, sent: nil))
            return []
        }
        if let flag = key.modifier {
            let event = KeyEvent(key: key, modifiers: modifiers.subtracting(flag), phase: .down)
            presses.append(Press(key: key, source: source, sent: key))
            return [.key(event)]
        }

        let held = modifiers
        var produced = characters
        var base = charactersIgnoringModifiers
        if source == .onScreen {
            // Caps lock capitalises letters only.
            let shifted = held.hasShift || (held.contains(.capsLock) && Self.isLetter(key))
            if let character = KeyTranslator.character(for: key, shift: shifted) {
                if base == nil { base = String(character) }
                if produced == nil, !(held.hasControl || held.hasOption || held.hasCommand) {
                    produced = String(character)
                }
            }
        }
        let event = KeyTranslator().translate(
            KeyEvent(key: key, characters: produced, charactersIgnoringModifiers: base, modifiers: held, phase: .down)
        )
        presses.append(
            Press(
                key: key,
                source: source,
                sent: event.key,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
        )
        return [.key(event)]
    }

    /// A key came up. Returns one key-up naming what the key-down named, or nothing when that key is
    /// not down from that source (and for fn).
    public mutating func keyUp(_ key: KeyCode, source: Source) -> [InputEvent] {
        guard let index = index(of: key, source: source) else { return [] }
        return release(at: index)
    }

    /// How long a key is held before it repeats, and how often it repeats after that: a Mac's own
    /// defaults (InitialKeyRepeat 15 and KeyRepeat 2, in ticks of 15 ms). The remote machine does
    /// not repeat a key a viewer holds, so the front end does, with ``repeatedKeyDown(_:source:)``.
    public static let repeatDelay: Duration = .milliseconds(225)
    public static let repeatInterval: Duration = .milliseconds(30)

    /// Whether holding the key repeats it: every key but the modifiers, Caps Lock and fn.
    public static func repeats(_ key: KeyCode) -> Bool {
        key.modifier == nil && key != .capsLock
    }

    /// One repeat of a held key: the down it was pressed with again, marked ``KeyEvent/isRepeat``,
    /// with the modifiers held now. Nothing when the key is no longer down from that source, or does
    /// not repeat.
    public func repeatedKeyDown(_ key: KeyCode, source: Source) -> [InputEvent] {
        guard Self.repeats(key), let index = index(of: key, source: source), let sent = presses[index].sent else { return [] }
        let press = presses[index]
        var held = modifiers
        if press.usedFunctionLayer { held.remove(.function) }
        return [
            .key(
                KeyEvent(
                    key: sent,
                    characters: press.characters,
                    charactersIgnoringModifiers: press.charactersIgnoringModifiers,
                    modifiers: held,
                    phase: .down,
                    isRepeat: true
                )
            ),
        ]
    }

    /// Lets go of every hardware modifier key that the system says is no longer held.
    ///
    /// A modifier's key-up can go elsewhere: with Stage Manager, or when iPadOS takes a ⌘ chord for
    /// itself, the up never reaches the app, and the remote machine would go on seeing ⌘ held (and
    /// turn every click into a multi-select). The modifier flags on each later event are the
    /// system's word on what is down; pass them here first. Only ever releases: a modifier held
    /// according to the flags but never pressed here is not invented. On-screen presses are not the
    /// system's to judge; caps lock is a state rather than a key held, and fn has no flag there.
    ///
    /// `flags` need only tell modifiers apart by kind (`.shift`, `.command`, …); either side's flag
    /// counts for both keys of that kind.
    public mutating func synchronize(flags: KeyModifiers) -> [InputEvent] {
        var events: [InputEvent] = []
        var index = presses.count - 1
        while index >= 0 {
            let press = presses[index]
            if press.source == .hardware, let flag = press.key.modifier,
               let kind = ([.shift, .control, .option, .command] as [KeyModifiers]).first(where: { !$0.isDisjoint(with: flag) }),
               flags.isDisjoint(with: kind) {
                events += release(at: index)
            }
            index -= 1
        }
        return events
    }

    /// Records whether caps lock is on; reflected as `.capsLock` in ``hardwareModifiers``. The Caps
    /// Lock key itself goes through `keyDown`/`keyUp` like any other key.
    public mutating func setCapsLock(_ on: Bool) {
        capsLock = on
    }

    /// Releases everything held: key-ups for the ordinary keys in reverse order of pressing, then
    /// for the modifier keys, likewise in reverse. Use on resign-active and on disconnect.
    ///
    /// ``latchedModifiers`` and caps lock are left alone; ``ModifierLatch/releaseAll()`` releases
    /// the latch's own keys.
    public mutating func releaseAll() -> [InputEvent] {
        var events: [InputEvent] = []
        for modifierPass in [false, true] {
            var index = presses.count - 1
            while index >= 0 {
                if (presses[index].key.modifier != nil) == modifierPass {
                    events += release(at: index)
                }
                index -= 1
            }
        }
        return events
    }

    // MARK: Internals

    private func index(of key: KeyCode, source: Source) -> Int? {
        presses.firstIndex { $0.key == key && $0.source == source }
    }

    private mutating func release(at index: Int) -> [InputEvent] {
        let press = presses.remove(at: index)
        guard let sent = press.sent else { return [] }
        var held = modifiers
        if let flag = press.key.modifier { held.subtract(flag) }
        if press.usedFunctionLayer { held.remove(.function) }
        return [
            .key(
                KeyEvent(
                    key: sent,
                    characters: press.characters,
                    charactersIgnoringModifiers: press.charactersIgnoringModifiers,
                    modifiers: held,
                    phase: .up
                )
            ),
        ]
    }

    private static func isLetter(_ key: KeyCode) -> Bool {
        (KeyCode.a.rawValue...KeyCode.z.rawValue).contains(key.rawValue)
    }
}
