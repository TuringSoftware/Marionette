// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import RemoteDesktopCore

/// On-screen modifier keys that stay down without a finger on them.
///
/// Each tap advances a modifier: off → one-shot (applies to the next key stroke or click) → locked
/// (stays until tapped again) → off. The latch returns the key events that make the remote machine
/// agree, so a latched ⌘ also modifies pointer clicks. `function` exists only on this side: it selects
/// the ``KeyTranslator`` fn layer and never reaches the remote machine.
///
/// The left-hand and right-hand keys of a modifier latch independently, as they are separate keys on
/// a Mac keyboard: a full on-screen keyboard has both, and the right one must reach the remote
/// machine as the right one. Callers that have only one key per modifier (the bar above the system
/// keyboard) use the left one, the default.
public struct ModifierLatch: Sendable, Hashable, Codable {
    /// Which of a modifier's two keys.
    public enum Side: String, CaseIterable, Sendable, Hashable, Codable {
        case left
        case right

        /// The side of a modifier key code: right for the right-hand keys, left for everything else.
        public init(key: KeyCode) {
            self = [KeyCode.rightShift, .rightControl, .rightOption, .rightCommand].contains(key) ? .right : .left
        }
    }

    public enum Modifier: String, CaseIterable, Sendable, Hashable, Codable {
        case control
        case option
        case shift
        case command
        case function

        /// The flag this modifier contributes (the left-hand key's).
        public var keyModifier: KeyModifiers { keyModifier(on: .left) }

        /// The flag one of this modifier's keys contributes. fn has one key; its side is ignored.
        public func keyModifier(on side: Side) -> KeyModifiers {
            switch (self, side) {
            case (.control, .left): .leftControl
            case (.control, .right): .rightControl
            case (.option, .left): .leftOption
            case (.option, .right): .rightOption
            case (.shift, .left): .leftShift
            case (.shift, .right): .rightShift
            case (.command, .left): .leftCommand
            case (.command, .right): .rightCommand
            case (.function, _): .function
            }
        }

        /// The key pressed on the remote machine (the left-hand one), or `nil` for the client-side fn key.
        public var key: KeyCode? { key(on: .left) }

        /// The key one side presses on the remote machine, or `nil` for the client-side fn key.
        public func key(on side: Side) -> KeyCode? {
            switch (self, side) {
            case (.control, .left): .leftControl
            case (.control, .right): .rightControl
            case (.option, .left): .leftOption
            case (.option, .right): .rightOption
            case (.shift, .left): .leftShift
            case (.shift, .right): .rightShift
            case (.command, .left): .leftCommand
            case (.command, .right): .rightCommand
            case (.function, _): nil
            }
        }

        /// The glyph printed on a Mac keyboard.
        public var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            case .function: "fn"
            }
        }
    }

    public enum State: String, Sendable, Hashable, Codable {
        case off
        /// Applies to the next key stroke or click, then releases.
        case oneShot
        /// Stays until tapped again.
        case locked
    }

    /// One latchable key: a modifier on one side. fn is always `.left`.
    private struct Slot: Sendable, Hashable, Codable {
        var modifier: Modifier
        var side: Side

        init(_ modifier: Modifier, _ side: Side) {
            self.modifier = modifier
            self.side = modifier == .function ? .left : side
        }
    }

    /// Only keys that are not off, so equal latches compare equal.
    private var states: [Slot: State] = [:]

    public init() {}

    /// The state of one of a modifier's keys (the left-hand one unless told otherwise).
    public func state(of modifier: Modifier, side: Side = .left) -> State {
        states[Slot(modifier, side)] ?? .off
    }

    /// Whether either key of a modifier is latched or locked.
    public func isActive(_ modifier: Modifier) -> Bool {
        Side.allCases.contains { state(of: modifier, side: $0) != .off }
    }

    /// Every latched key, as its side's flag, plus `.function`.
    public var activeModifiers: KeyModifiers {
        states.keys.reduce(into: KeyModifiers()) { $0.formUnion($1.modifier.keyModifier(on: $1.side)) }
    }

    public var isEmpty: Bool { states.isEmpty }

    /// Whether any modifier will release after the next key stroke.
    public var hasOneShots: Bool { states.values.contains(.oneShot) }

    /// Advances one of a modifier's keys one step. Returns the key events to send: that key going
    /// down when it leaves `off`, going up when it returns to `off`, nothing in between.
    @discardableResult
    public mutating func tap(_ modifier: Modifier, side: Side = .left) -> [KeyEvent] {
        switch state(of: modifier, side: side) {
        case .off: setState(.oneShot, for: modifier, side: side)
        case .oneShot: setState(.locked, for: modifier, side: side)
        case .locked: setState(.off, for: modifier, side: side)
        }
    }

    /// Puts one of a modifier's keys in a specific state. Returns the key events to send.
    @discardableResult
    public mutating func setState(_ newState: State, for modifier: Modifier, side: Side = .left) -> [KeyEvent] {
        let slot = Slot(modifier, side)
        let wasDown = states[slot] != nil
        states[slot] = newState == .off ? nil : newState
        let isDown = newState != .off
        guard wasDown != isDown, let key = modifier.key(on: slot.side) else { return [] }
        let others = activeModifiers.subtracting([modifier.keyModifier(on: slot.side), .function])
        return [KeyEvent(key: key, modifiers: others, phase: isDown ? .down : .up)]
    }

    /// Call after a non-modifier key stroke or a click went out: releases the one-shot modifiers and
    /// keeps the locked ones. Returns the key-up events to send.
    @discardableResult
    public mutating func consumeOneShots() -> [KeyEvent] {
        release { $0 == .oneShot }
    }

    /// Releases everything. Returns the key-up events to send.
    @discardableResult
    public mutating func releaseAll() -> [KeyEvent] {
        release { _ in true }
    }

    private mutating func release(where shouldRelease: (State) -> Bool) -> [KeyEvent] {
        var events: [KeyEvent] = []
        // Reverse of the order a person would press them, like letting go of a chord.
        for modifier in Modifier.allCases.reversed() {
            for side in Side.allCases.reversed() {
                let current = state(of: modifier, side: side)
                guard current != .off, shouldRelease(current) else { continue }
                events += setState(.off, for: modifier, side: side)
            }
        }
        return events
    }
}
