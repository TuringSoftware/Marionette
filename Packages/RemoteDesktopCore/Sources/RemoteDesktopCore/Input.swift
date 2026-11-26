// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

/// A physical key, identified by its USB HID keyboard-page usage (page 0x07).
///
/// Position-based on purpose: back ends translate to whatever their protocol wants (X11 keysyms for
/// RFB, scancodes for RDP) using the accompanying characters where the protocol is symbol-based.
public struct KeyCode: RawRepresentable, Sendable, Hashable, Codable {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    // Letters
    public static let a = KeyCode(rawValue: 0x04), b = KeyCode(rawValue: 0x05), c = KeyCode(rawValue: 0x06)
    public static let d = KeyCode(rawValue: 0x07), e = KeyCode(rawValue: 0x08), f = KeyCode(rawValue: 0x09)
    public static let g = KeyCode(rawValue: 0x0A), h = KeyCode(rawValue: 0x0B), i = KeyCode(rawValue: 0x0C)
    public static let j = KeyCode(rawValue: 0x0D), k = KeyCode(rawValue: 0x0E), l = KeyCode(rawValue: 0x0F)
    public static let m = KeyCode(rawValue: 0x10), n = KeyCode(rawValue: 0x11), o = KeyCode(rawValue: 0x12)
    public static let p = KeyCode(rawValue: 0x13), q = KeyCode(rawValue: 0x14), r = KeyCode(rawValue: 0x15)
    public static let s = KeyCode(rawValue: 0x16), t = KeyCode(rawValue: 0x17), u = KeyCode(rawValue: 0x18)
    public static let v = KeyCode(rawValue: 0x19), w = KeyCode(rawValue: 0x1A), x = KeyCode(rawValue: 0x1B)
    public static let y = KeyCode(rawValue: 0x1C), z = KeyCode(rawValue: 0x1D)

    // Number row
    public static let digit1 = KeyCode(rawValue: 0x1E), digit2 = KeyCode(rawValue: 0x1F)
    public static let digit3 = KeyCode(rawValue: 0x20), digit4 = KeyCode(rawValue: 0x21)
    public static let digit5 = KeyCode(rawValue: 0x22), digit6 = KeyCode(rawValue: 0x23)
    public static let digit7 = KeyCode(rawValue: 0x24), digit8 = KeyCode(rawValue: 0x25)
    public static let digit9 = KeyCode(rawValue: 0x26), digit0 = KeyCode(rawValue: 0x27)

    // Editing and whitespace
    public static let returnOrEnter = KeyCode(rawValue: 0x28)
    public static let escape = KeyCode(rawValue: 0x29)
    public static let deleteBackward = KeyCode(rawValue: 0x2A)
    public static let tab = KeyCode(rawValue: 0x2B)
    public static let space = KeyCode(rawValue: 0x2C)
    public static let hyphen = KeyCode(rawValue: 0x2D)
    public static let equal = KeyCode(rawValue: 0x2E)
    public static let openBracket = KeyCode(rawValue: 0x2F)
    public static let closeBracket = KeyCode(rawValue: 0x30)
    public static let backslash = KeyCode(rawValue: 0x31)
    public static let nonUSPound = KeyCode(rawValue: 0x32)
    public static let semicolon = KeyCode(rawValue: 0x33)
    public static let quote = KeyCode(rawValue: 0x34)
    public static let graveAccent = KeyCode(rawValue: 0x35)
    public static let comma = KeyCode(rawValue: 0x36)
    public static let period = KeyCode(rawValue: 0x37)
    public static let slash = KeyCode(rawValue: 0x38)
    public static let capsLock = KeyCode(rawValue: 0x39)

    // Function keys
    public static let f1 = KeyCode(rawValue: 0x3A), f2 = KeyCode(rawValue: 0x3B), f3 = KeyCode(rawValue: 0x3C)
    public static let f4 = KeyCode(rawValue: 0x3D), f5 = KeyCode(rawValue: 0x3E), f6 = KeyCode(rawValue: 0x3F)
    public static let f7 = KeyCode(rawValue: 0x40), f8 = KeyCode(rawValue: 0x41), f9 = KeyCode(rawValue: 0x42)
    public static let f10 = KeyCode(rawValue: 0x43), f11 = KeyCode(rawValue: 0x44), f12 = KeyCode(rawValue: 0x45)
    public static let f13 = KeyCode(rawValue: 0x68), f14 = KeyCode(rawValue: 0x69), f15 = KeyCode(rawValue: 0x6A)
    public static let f16 = KeyCode(rawValue: 0x6B), f17 = KeyCode(rawValue: 0x6C), f18 = KeyCode(rawValue: 0x6D)
    public static let f19 = KeyCode(rawValue: 0x6E), f20 = KeyCode(rawValue: 0x6F)

    // Navigation
    public static let printScreen = KeyCode(rawValue: 0x46)
    public static let scrollLock = KeyCode(rawValue: 0x47)
    public static let pause = KeyCode(rawValue: 0x48)
    public static let insert = KeyCode(rawValue: 0x49)
    public static let home = KeyCode(rawValue: 0x4A)
    public static let pageUp = KeyCode(rawValue: 0x4B)
    public static let deleteForward = KeyCode(rawValue: 0x4C)
    public static let end = KeyCode(rawValue: 0x4D)
    public static let pageDown = KeyCode(rawValue: 0x4E)
    public static let rightArrow = KeyCode(rawValue: 0x4F)
    public static let leftArrow = KeyCode(rawValue: 0x50)
    public static let downArrow = KeyCode(rawValue: 0x51)
    public static let upArrow = KeyCode(rawValue: 0x52)

    // Keypad
    public static let keypadNumLock = KeyCode(rawValue: 0x53)
    public static let keypadSlash = KeyCode(rawValue: 0x54), keypadAsterisk = KeyCode(rawValue: 0x55)
    public static let keypadHyphen = KeyCode(rawValue: 0x56), keypadPlus = KeyCode(rawValue: 0x57)
    public static let keypadEnter = KeyCode(rawValue: 0x58)
    public static let keypad1 = KeyCode(rawValue: 0x59), keypad2 = KeyCode(rawValue: 0x5A)
    public static let keypad3 = KeyCode(rawValue: 0x5B), keypad4 = KeyCode(rawValue: 0x5C)
    public static let keypad5 = KeyCode(rawValue: 0x5D), keypad6 = KeyCode(rawValue: 0x5E)
    public static let keypad7 = KeyCode(rawValue: 0x5F), keypad8 = KeyCode(rawValue: 0x60)
    public static let keypad9 = KeyCode(rawValue: 0x61), keypad0 = KeyCode(rawValue: 0x62)
    public static let keypadPeriod = KeyCode(rawValue: 0x63), keypadEqual = KeyCode(rawValue: 0x67)
    public static let nonUSBackslash = KeyCode(rawValue: 0x64)
    public static let application = KeyCode(rawValue: 0x65)

    // Modifiers
    public static let leftControl = KeyCode(rawValue: 0xE0), leftShift = KeyCode(rawValue: 0xE1)
    public static let leftOption = KeyCode(rawValue: 0xE2), leftCommand = KeyCode(rawValue: 0xE3)
    public static let rightControl = KeyCode(rawValue: 0xE4), rightShift = KeyCode(rawValue: 0xE5)
    public static let rightOption = KeyCode(rawValue: 0xE6), rightCommand = KeyCode(rawValue: 0xE7)

    /// The Globe / fn key. Not part of the HID keyboard page; this value is private to Marionette.
    public static let function = KeyCode(rawValue: 0xFF01)

    /// The modifier flag this key toggles while held, if it is a modifier key.
    public var modifier: KeyModifiers? {
        switch self {
        case .leftControl: .leftControl
        case .rightControl: .rightControl
        case .leftShift: .leftShift
        case .rightShift: .rightShift
        case .leftOption: .leftOption
        case .rightOption: .rightOption
        case .leftCommand: .leftCommand
        case .rightCommand: .rightCommand
        case .function: .function
        default: nil
        }
    }
}

/// Modifier keys held during an input event, with left and right distinguished.
public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let leftShift = KeyModifiers(rawValue: 1 << 0)
    public static let rightShift = KeyModifiers(rawValue: 1 << 1)
    public static let leftControl = KeyModifiers(rawValue: 1 << 2)
    public static let rightControl = KeyModifiers(rawValue: 1 << 3)
    public static let leftOption = KeyModifiers(rawValue: 1 << 4)
    public static let rightOption = KeyModifiers(rawValue: 1 << 5)
    public static let leftCommand = KeyModifiers(rawValue: 1 << 6)
    public static let rightCommand = KeyModifiers(rawValue: 1 << 7)
    public static let capsLock = KeyModifiers(rawValue: 1 << 8)
    public static let function = KeyModifiers(rawValue: 1 << 9)

    public static let shift: KeyModifiers = [.leftShift, .rightShift]
    public static let control: KeyModifiers = [.leftControl, .rightControl]
    public static let option: KeyModifiers = [.leftOption, .rightOption]
    public static let command: KeyModifiers = [.leftCommand, .rightCommand]

    public var hasShift: Bool { !isDisjoint(with: .shift) }
    public var hasControl: Bool { !isDisjoint(with: .control) }
    public var hasOption: Bool { !isDisjoint(with: .option) }
    public var hasCommand: Bool { !isDisjoint(with: .command) }
}

/// A key going down or up.
///
/// Front ends send one `down` and one `up` per physical press. A held key repeats only through
/// further downs marked ``isRepeat``, which the front end makes on a timer: a Mac or an X server
/// does not repeat a key a remote viewer holds (seen with macOS 27's and TigerVNC's servers).
public struct KeyEvent: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case down
        case up
    }

    /// The physical key, when known. Software keyboards may only know the character.
    public var key: KeyCode?
    /// What the key produces with the current modifiers and layout ("A", "å"), if anything.
    public var characters: String?
    /// What the key produces without modifiers other than Shift.
    public var charactersIgnoringModifiers: String?
    /// Modifiers held *while* this event happened, not counting the key itself.
    public var modifiers: KeyModifiers
    public var phase: Phase
    /// A further down of a key that is already down, for a held key repeating. Back ends send it
    /// as another press; a down of a key already down that is not marked is dropped.
    public var isRepeat: Bool

    public init(
        key: KeyCode?,
        characters: String? = nil,
        charactersIgnoringModifiers: String? = nil,
        modifiers: KeyModifiers = [],
        phase: Phase,
        isRepeat: Bool = false
    ) {
        self.key = key
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
        self.phase = phase
        self.isRepeat = isRepeat
    }
}

public struct PointerButtons: OptionSet, Sendable, Hashable, Codable {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let primary = PointerButtons(rawValue: 1 << 0)
    public static let secondary = PointerButtons(rawValue: 1 << 1)
    public static let middle = PointerButtons(rawValue: 1 << 2)
    public static let back = PointerButtons(rawValue: 1 << 3)
    public static let forward = PointerButtons(rawValue: 1 << 4)
}

/// The pointer's absolute position and complete button state.
///
/// Positions are always absolute, in the pixel space of one display. Relative ("trackpad") motion is
/// turned into absolute positions by the interaction layer before it reaches a back end.
public struct PointerEvent: Sendable, Hashable {
    public var display: DisplayID
    /// Position inside `display`, in that display's pixels, origin top-left.
    public var position: PixelPoint
    /// Every button currently held.
    public var buttons: PointerButtons
    /// The ``DesktopLayout/generation`` the position was computed against.
    public var layoutGeneration: UInt64

    public init(display: DisplayID, position: PixelPoint, buttons: PointerButtons = [], layoutGeneration: UInt64) {
        self.display = display
        self.position = position
        self.buttons = buttons
        self.layoutGeneration = layoutGeneration
    }
}

/// A scroll gesture step.
public struct ScrollEvent: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        /// A discrete wheel notch, or a source that does not report phases.
        case none
        case began
        case changed
        case ended
        case cancelled
    }

    public var display: DisplayID
    public var position: PixelPoint
    /// Horizontal distance. Positive moves content to the right.
    public var deltaX: Double
    /// Vertical distance. Positive moves content down (reveals what is above).
    public var deltaY: Double
    /// True when deltas are in remote pixels (trackpad, touch); false when they count wheel lines.
    public var isPrecise: Bool
    public var phase: Phase
    /// Inertial scrolling after the fingers lift.
    public var momentumPhase: Phase
    public var modifiers: KeyModifiers
    public var layoutGeneration: UInt64

    public init(
        display: DisplayID,
        position: PixelPoint,
        deltaX: Double,
        deltaY: Double,
        isPrecise: Bool,
        phase: Phase = .none,
        momentumPhase: Phase = .none,
        modifiers: KeyModifiers = [],
        layoutGeneration: UInt64
    ) {
        self.display = display
        self.position = position
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.isPrecise = isPrecise
        self.phase = phase
        self.momentumPhase = momentumPhase
        self.modifiers = modifiers
        self.layoutGeneration = layoutGeneration
    }
}

/// A trackpad gesture other than scrolling, at the pointer, as a Mac trackpad reports it to the
/// frontmost app. Back ends without gestures ignore them or approximate them.
public struct GestureEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Pinch. The change in magnification since the previous event of this gesture: 0.1 is 10 %
        /// larger, -0.1 10 % smaller.
        case magnify(Double)
        /// Two-finger rotation since the previous event of this gesture, in degrees; positive is
        /// counter-clockwise, as on the Mac.
        case rotate(Double)
        /// Two-finger double tap: zoom in on what is under the pointer, or back out.
        case smartMagnify
        /// Navigation swipe (back, forward, pages): -1, 0 or 1 on each axis, with the Mac's signs.
        case swipe(dx: Double, dy: Double)
        /// Force click or three-finger tap: look up what is under the pointer.
        case quickLook
    }

    public var kind: Kind
    /// `began`/`changed`/`ended`/`cancelled` for continuous gestures (magnify, rotate); `none` for
    /// one-shot ones.
    public var phase: ScrollEvent.Phase
    public var display: DisplayID
    public var position: PixelPoint
    public var layoutGeneration: UInt64

    public init(kind: Kind, phase: ScrollEvent.Phase = .none, display: DisplayID, position: PixelPoint, layoutGeneration: UInt64) {
        self.kind = kind
        self.phase = phase
        self.display = display
        self.position = position
        self.layoutGeneration = layoutGeneration
    }
}

/// The fingers on one display, for a remote machine that takes them as a touch screen of its own
/// (``SessionCapabilities/touch``). The remote machine decides what they mean.
///
/// Each event lists every finger on the display at that moment. A finger that lifts is in one more
/// event, ``Contact/Phase-swift.enum/lifted`` or ``Contact/Phase-swift.enum/cancelled``, and in
/// none after it.
public struct TouchEvent: Sendable, Hashable {
    public struct Contact: Sendable, Hashable {
        public enum Phase: Sendable, Hashable {
            case touching
            case lifted
            /// Taken away by the system rather than lifted: the remote machine abandons what the
            /// finger started.
            case cancelled
        }

        /// The finger, from landing to lifting: below ``TouchInput/maximumContacts``, and free for
        /// another finger once it has lifted.
        public var id: Int
        /// Inside the display, in its pixels, origin top-left.
        public var position: PixelPoint
        public var phase: Phase

        public init(id: Int, position: PixelPoint, phase: Phase = .touching) {
            self.id = id
            self.position = position
            self.phase = phase
        }
    }

    public var display: DisplayID
    public var contacts: [Contact]
    /// The ``DesktopLayout/generation`` the positions were computed against.
    public var layoutGeneration: UInt64

    public init(display: DisplayID, contacts: [Contact], layoutGeneration: UInt64) {
        self.display = display
        self.contacts = contacts
        self.layoutGeneration = layoutGeneration
    }
}

public enum InputEvent: Sendable, Hashable {
    case key(KeyEvent)
    /// Committed text from a software keyboard, input method, or dictation. The back end types it
    /// however its protocol allows; no modifiers are implied.
    case text(String)
    case pointer(PointerEvent)
    case scroll(ScrollEvent)
    case gesture(GestureEvent)
    /// Fingers on the remote display as on a touch screen; only where ``SessionCapabilities/touch``
    /// is available. Back ends without it ignore them.
    case touch(TouchEvent)
    /// Release every key, button and finger the session believes is held. Sent when the app loses
    /// focus so nothing stays stuck on the remote machine.
    case releaseAll
}

/// Where a front end puts input.
///
/// `send` is synchronous and must not block: implementations enqueue and return. Events are delivered
/// to the remote machine in the order `send` was called. Implementations may coalesce consecutive
/// pointer moves that carry the same button state.
public protocol InputSink: Sendable {
    func send(_ event: InputEvent)
}
