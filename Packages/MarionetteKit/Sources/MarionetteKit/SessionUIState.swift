// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
import Observation
public import RemoteDesktopCore
public import RemoteDesktopInteraction

/// How touches on the remote display are interpreted.
public enum InputMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// The finger is the pointer.
    case touch
    /// The screen is a trackpad that moves a cursor.
    case trackpad
}

/// What the keyboard control has put at the bottom of the screen. One control steps through these.
public enum InputPanel: String, Sendable, Hashable, Codable, CaseIterable {
    /// A trackpad surface that works like a Mac's.
    case trackpad
    /// A Mac-layout keyboard drawn by the app, which sends key codes.
    case deckKeyboard
    /// The system keyboard, with the bar of Mac keys above it.
    case systemKeyboard
    /// Nothing: the whole screen is the remote display.
    case hidden

    /// Whether the panel can be had folded like a laptop, where the lower pane always holds the
    /// trackpad or the Mac keyboard.
    public var isAvailableDocked: Bool { self == .trackpad || self == .deckKeyboard }

    /// What the panel becomes folded like a laptop: nothing becomes the trackpad, the system
    /// keyboard the Mac keyboard.
    public var docked: InputPanel {
        switch self {
        case .trackpad, .hidden: .trackpad
        case .deckKeyboard, .systemKeyboard: .deckKeyboard
        }
    }

    /// The three the keyboard control can show; ``hidden`` is its other state.
    public static let shown: [InputPanel] = [.trackpad, .deckKeyboard, .systemKeyboard]

    public var title: String {
        switch self {
        case .trackpad: String(localized: "Trackpad", bundle: #bundle)
        case .deckKeyboard: String(localized: "Mac Keyboard", bundle: #bundle)
        case .systemKeyboard: String(localized: "System Keyboard", bundle: #bundle)
        case .hidden: String(localized: "Hidden", bundle: #bundle)
        }
    }
}

/// What the input deck draws.
public enum DeckSurface: Sendable, Hashable {
    case trackpad
    case keyboard
}

/// Which keys the bar above the system keyboard is showing.
public enum AccessoryPage: String, Sendable, Hashable, Codable {
    /// Modifiers, escape, tab, forward delete and the arrows.
    case keys
    /// F1 to F12.
    case functionKeys
    /// Every other key a remote keyboard has that the system keyboard lacks: navigation, F13 to F20,
    /// the PC system keys and the numeric keypad.
    case moreKeys
}

/// A side of a display, as in a Mac's display arrangement.
public enum DisplayEdge: String, Sendable, Hashable, Codable, CaseIterable {
    case left
    case right
    case top
    case bottom

    /// The side across from this one: where the pointer comes into the next display.
    public var opposite: DisplayEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }

    public var title: String {
        switch self {
        case .left: String(localized: "Left", bundle: #bundle)
        case .right: String(localized: "Right", bundle: #bundle)
        case .top: String(localized: "Above", bundle: #bundle)
        case .bottom: String(localized: "Below", bundle: #bundle)
        }
    }

    /// Whether `point` lies past this side of a display of `size` pixels.
    func isPassed(by point: PixelPoint, in size: PixelSize) -> Bool {
        switch self {
        case .left: point.x < 0
        case .right: point.x > Double(size.width - 1)
        case .top: point.y < 0
        case .bottom: point.y > Double(size.height - 1)
        }
    }

    /// How far along this side `point` is, from 0 (its top or left end) to 1.
    func fraction(of point: PixelPoint, in size: PixelSize) -> Double {
        let (position, length) = switch self {
        case .left, .right: (point.y, size.height)
        case .top, .bottom: (point.x, size.width)
        }
        guard length > 1 else { return 0.5 }
        return min(max(position / Double(length - 1), 0), 1)
    }

    /// The pixel on this side of a display of `size` pixels that is `fraction` of the way along it.
    func point(at fraction: Double, in size: PixelSize) -> PixelPoint {
        let (width, height) = (Double(max(size.width - 1, 0)), Double(max(size.height - 1, 0)))
        return switch self {
        case .left: PixelPoint(x: 0, y: fraction * height)
        case .right: PixelPoint(x: width, y: fraction * height)
        case .top: PixelPoint(x: fraction * width, y: 0)
        case .bottom: PixelPoint(x: fraction * width, y: height)
        }
    }
}

/// The parts of the session interface that survive between sessions: each is left the way the user
/// last had it, in whichever session that was.
public struct SessionPreferences: Sendable, Hashable {
    public var inputMode: InputMode = .touch
    public var inputPanel: InputPanel = .hidden
    /// What the keyboard control shows when pressed with nothing showing, until another is chosen
    /// from its menu (Settings). Never ``InputPanel/hidden``.
    public var defaultInputPanel: InputPanel = .systemKeyboard
    /// The remote display fills the screen: no bars, no clock, no home indicator.
    public var isFullScreen = false
    /// The control strip is folded away into its handle.
    public var areControlsCollapsed = false
    public var accessoryPage: AccessoryPage = .keys
    /// Scale to Fit or Actual Size; a free zoom is not kept (it belongs to one desktop's size).
    public var zoomMode: ViewportModel.ZoomMode = .fit
    public var isAudioMuted = false
    /// High Performance displays are HDR where the screen showing them can show it.
    public var isHDREnabled = true
    /// Content follows the fingers (the default on Apple devices) rather than the scroll bar.
    public var naturalScrolling = true
    /// Multiplier for relative pointer movement in trackpad mode, 0.5 (slow) to 2 (fast).
    public var pointerSpeed = 1.0
    public var clipboardMode: ClipboardMode = .explicit
    /// The side of Display 1 where a trackpad's pointer goes on to Display 2 (and of Display 2 to
    /// Display 3); it comes back across the opposite side.
    public var secondaryDisplayEdge: DisplayEdge = .right

    public static let pointerSpeedRange: ClosedRange<Double> = 0.5...2.0

    public init() {}

    private static let inputModeKey = "session.inputMode"
    private static let inputPanelKey = "session.inputPanel"
    private static let defaultInputPanelKey = "input.defaultPanel"
    private static let fullScreenKey = "session.fullScreen"
    private static let controlsCollapsedKey = "session.controlsCollapsed"
    private static let naturalScrollingKey = "input.naturalScrolling"
    private static let pointerSpeedKey = "input.pointerSpeed"
    private static let clipboardModeKey = "clipboard.mode"
    private static let accessoryPageKey = "session.accessoryPage"
    private static let zoomModeKey = "session.zoomMode"
    private static let audioMutedKey = "session.audioMuted"
    private static let hdrKey = "session.hdr"
    private static let secondaryDisplayEdgeKey = "input.secondaryDisplayEdge"

    public init(defaults: UserDefaults) {
        if let raw = defaults.string(forKey: Self.inputModeKey), let mode = InputMode(rawValue: raw) { inputMode = mode }
        if let raw = defaults.string(forKey: Self.inputPanelKey), let panel = InputPanel(rawValue: raw) { inputPanel = panel }
        if let raw = defaults.string(forKey: Self.defaultInputPanelKey), let panel = InputPanel(rawValue: raw), panel != .hidden {
            defaultInputPanel = panel
        }
        isFullScreen = defaults.bool(forKey: Self.fullScreenKey)
        areControlsCollapsed = defaults.bool(forKey: Self.controlsCollapsedKey)
        if defaults.object(forKey: Self.naturalScrollingKey) != nil { naturalScrolling = defaults.bool(forKey: Self.naturalScrollingKey) }
        if defaults.object(forKey: Self.pointerSpeedKey) != nil {
            let stored = defaults.double(forKey: Self.pointerSpeedKey)
            if stored.isFinite { pointerSpeed = min(max(stored, Self.pointerSpeedRange.lowerBound), Self.pointerSpeedRange.upperBound) }
        }
        if let raw = defaults.string(forKey: Self.clipboardModeKey), let mode = ClipboardMode(rawValue: raw) { clipboardMode = mode }
        if let raw = defaults.string(forKey: Self.accessoryPageKey), let page = AccessoryPage(rawValue: raw) { accessoryPage = page }
        switch defaults.string(forKey: Self.zoomModeKey) {
        case "actualSize": zoomMode = .actualSize
        default: zoomMode = .fit
        }
        isAudioMuted = defaults.bool(forKey: Self.audioMutedKey)
        if defaults.object(forKey: Self.hdrKey) != nil { isHDREnabled = defaults.bool(forKey: Self.hdrKey) }
        if let raw = defaults.string(forKey: Self.secondaryDisplayEdgeKey), let edge = DisplayEdge(rawValue: raw) { secondaryDisplayEdge = edge }
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(inputMode.rawValue, forKey: Self.inputModeKey)
        defaults.set(inputPanel.rawValue, forKey: Self.inputPanelKey)
        defaults.set(defaultInputPanel.rawValue, forKey: Self.defaultInputPanelKey)
        defaults.set(isFullScreen, forKey: Self.fullScreenKey)
        defaults.set(areControlsCollapsed, forKey: Self.controlsCollapsedKey)
        defaults.set(naturalScrolling, forKey: Self.naturalScrollingKey)
        defaults.set(pointerSpeed, forKey: Self.pointerSpeedKey)
        defaults.set(clipboardMode.rawValue, forKey: Self.clipboardModeKey)
        defaults.set(accessoryPage.rawValue, forKey: Self.accessoryPageKey)
        let zoom: String = switch zoomMode {
        case .actualSize: "actualSize"
        default: "fit"
        }
        defaults.set(zoom, forKey: Self.zoomModeKey)
        defaults.set(isAudioMuted, forKey: Self.audioMutedKey)
        defaults.set(isHDREnabled, forKey: Self.hdrKey)
        defaults.set(secondaryDisplayEdge.rawValue, forKey: Self.secondaryDisplayEdgeKey)
    }

    public var gestureConfiguration: GestureConfiguration {
        var configuration = GestureConfiguration()
        configuration.naturalScrolling = naturalScrolling
        configuration.pointerSpeed = pointerSpeed
        return configuration
    }
}

/// Everything about how a session is being looked at and controlled, as opposed to what the session
/// is. It lives in the model, not in view state, so folding the device, moving to another window or
/// re-creating a view loses nothing. Each property is observed on its own: a pinch updates
/// ``viewport`` many times a second without invalidating views that only read, say, ``inputMode``.
@MainActor
@Observable
public final class SessionUIState {
    /// Zoom and pan of the shown display.
    public internal(set) var viewport = ViewportModel() {
        didSet { if zoomMode != viewport.mode { zoomMode = viewport.mode } }
    }
    /// The viewport's zoom mode, kept apart so that the menus showing it are not drawn again at
    /// every step of a pan or a pinch.
    public private(set) var zoomMode: ViewportModel.ZoomMode = .fit
    /// The locally tracked pointer, in the shown display's pixels.
    public internal(set) var pointer: PixelPoint = .zero
    public internal(set) var selectedDisplay: DisplayID?
    /// The display on the monitor, while a trackpad has taken the pointer across to it (Both
    /// Displays); ``pointer`` is then in its pixels. `nil` while the pointer is on the shown display.
    public internal(set) var pointerDisplay: DisplayID?
    public internal(set) var inputMode: InputMode
    /// What the keyboard control last chose for the bottom of the screen.
    public internal(set) var inputPanel: InputPanel
    /// True while the layout has given the deck a pane of its own (a device folded like a laptop).
    /// Reported by the view layer; it is a fact about the device's pose, not a user choice.
    public internal(set) var isDeckDocked = false
    /// The user chose full screen: no bars and no system overlays. Kept across sessions.
    public internal(set) var isFullScreen: Bool
    /// The app's window is smaller than the screen (iPad). A session in a window is always shown
    /// full screen, at the window's size; that is not the user's choice and is not kept.
    public internal(set) var isWindowed = false
    /// Whether the remote display fills its window now, with no title bar.
    public var showsFullScreen: Bool { isWindowed || isFullScreen }
    /// The control strip is folded into its handle.
    public internal(set) var areControlsCollapsed: Bool
    /// The handle of a collapsed control strip is showing. It goes away by itself after a while and
    /// comes back when the screen is touched.
    public internal(set) var isControlsHandleVisible = true
    /// How far the keyboard or the deck reaches up from the bottom of the stage; the control strip
    /// stays above it.
    public internal(set) var bottomObstruction = 0.0
    public internal(set) var modifiers = ModifierLatch()
    public internal(set) var accessoryPage: AccessoryPage = .keys
    public internal(set) var isFilesPresented = false
    /// The field for a password to type at the remote machine is showing. It has the keyboard while
    /// it does.
    public internal(set) var isPasswordEntryPresented = false

    init(preferences: SessionPreferences) {
        inputMode = preferences.inputMode
        inputPanel = preferences.inputPanel
        isFullScreen = preferences.isFullScreen
        areControlsCollapsed = preferences.areControlsCollapsed
        accessoryPage = preferences.accessoryPage
        viewport.setMode(preferences.zoomMode)
        zoomMode = viewport.mode
    }

    /// What the deck draws, if anything. Folded like a laptop the lower pane is always in use: a
    /// keyboard while the picture is touched directly, a trackpad in trackpad mode.
    public var deckSurface: DeckSurface? {
        if isDeckDocked { return inputPanel.docked == .trackpad ? .trackpad : .keyboard }
        // The password field brings the system keyboard up; the deck makes way and comes back.
        if isPasswordEntryPresented { return nil }
        switch inputPanel {
        case .trackpad: return .trackpad
        case .deckKeyboard: return .keyboard
        case .systemKeyboard, .hidden: return nil
        }
    }

    /// Whether the system keyboard should be up. Never while the deck has a pane of its own.
    public var isKeyboardRequested: Bool { !isDeckDocked && inputPanel == .systemKeyboard }
}
