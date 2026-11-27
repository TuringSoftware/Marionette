// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import RemoteDesktopInteraction
import SwiftUI
import UIKit
import MarionetteKit

/// What the library offers the menu bar. Absent while a session covers the library.
struct LibraryActions {
    var newComputer: () -> Void
    var lookAgain: () -> Void
    var showSettings: () -> Void
    var showSSHKeys: () -> Void
    var showHelp: () -> Void
    var showSupport: () -> Void
}

/// What the menu bar acts on. The library says what it offers while it is on screen; the session
/// on screen is the one ``ExternalDisplayController`` already keeps track of.
@MainActor
@Observable
final class CommandTargets {
    static let shared = CommandTargets()
    var library: LibraryActions?
    var session: SessionModel? { ExternalDisplayController.shared.session }
}

/// The app's own keyboard shortcuts while a session is on screen.
///
/// A session sends every key to the remote machine, ⌘ combinations included: ⌘W must close a
/// window on the Mac, not the session. So session commands use ⌃⌥⌘ and a letter, unused on a Mac
/// for these letters, and only those are withheld from the remote machine. The library uses the
/// usual ⌘N and ⌘,.
enum AppShortcut {
    static let modifiers: EventModifiers = [.control, .option, .command]
    static let fullScreen: Character = "f"
    static let controls: Character = "h"
    static let inputMode: Character = "t"
    static let inputPanel: Character = "k"
    static let files: Character = "o"
    static let mute: Character = "m"
    static let disconnect: Character = "w"

    private static let keys: Set<UIKeyboardHIDUsage> = [
        .keyboardF, .keyboardH, .keyboardT, .keyboardK, .keyboardO, .keyboardM, .keyboardW,
    ]

    static func isAppShortcut(_ key: UIKey) -> Bool {
        let held = key.modifierFlags.intersection([.control, .alternate, .command, .shift])
        return held == [.control, .alternate, .command] && keys.contains(key.keyCode)
    }

    /// Performs a shortcut pressed while the remote display has the keyboard. The display takes
    /// every key press before the menu system sees it; the menu bar lists the same shortcuts.
    @MainActor
    static func perform(_ key: UIKey, in session: SessionModel) {
        switch key.keyCode {
        case .keyboardF: session.setFullScreen(!session.uiState.isFullScreen)
        case .keyboardH: session.setControlsCollapsed(!session.uiState.areControlsCollapsed)
        case .keyboardT: session.toggleInputMode()
        case .keyboardK: session.toggleInputPanel()
        case .keyboardO: session.setFilesPresented(true)
        case .keyboardM: session.setAudioMuted(!session.isAudioMuted)
        case .keyboardW: session.disconnect()
        default: break
        }
    }
}

/// The menu bar (iPad, in a window or with a keyboard attached) and the keyboard shortcuts that
/// come with it on any device with a hardware keyboard.
struct MarionetteCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    private let targets = CommandTargets.shared
    private var library: LibraryActions? { targets.library }
    private var session: SessionModel? { targets.session }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Computer…") { library?.newComputer() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(library == nil)
            Button("Refresh") { library?.lookAgain() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(library == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { library?.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(library == nil)
            Button("SSH Keys…") { library?.showSSHKeys() }
                .disabled(library == nil)
        }
        CommandMenu("Session") {
            Group {
            // Toggles with one fixed title each: a checkmark says the state, and a menu this narrow
            // keeps every title on one line.
            Toggle("Full Screen", isOn: Binding(get: { session?.uiState.isFullScreen == true }, set: { session?.setFullScreen($0) }))
                .keyboardShortcut(KeyEquivalent(AppShortcut.fullScreen), modifiers: AppShortcut.modifiers)
                .disabled(session == nil || session?.uiState.isWindowed == true)
            Toggle("Show Controls", isOn: Binding(get: { session?.uiState.areControlsCollapsed == false }, set: { session?.setControlsCollapsed(!$0) }))
                .keyboardShortcut(KeyEquivalent(AppShortcut.controls), modifiers: AppShortcut.modifiers)
            Divider()
            // A checkmark on the current choice; the switching shortcut sits beside the choice it
            // would make.
            Menu("Touch Mode") {
                ForEach([InputMode.touch, .trackpad], id: \.self) { mode in
                    Toggle(mode == .touch ? "Direct Input" : "Trackpad", isOn: Binding(get: { session?.uiState.inputMode == mode }, set: { if $0 { session?.setInputMode(mode) } }))
                        .keyboardShortcut(session.map { $0.uiState.inputMode != mode } == true ? KeyboardShortcut(KeyEquivalent(AppShortcut.inputMode), modifiers: AppShortcut.modifiers) : nil)
                }
            }
            .disabled(session?.externalDisplayMode == .externalOnly)
            Menu("On-Screen Input") {
                ForEach(InputPanel.allCases, id: \.self) { panel in
                    if panel == .hidden { Divider() }
                    Toggle(panel.title, isOn: Binding(get: { session?.uiState.inputPanel == panel }, set: { if $0 { session?.setInputPanel(panel) } }))
                        .keyboardShortcut(session?.inputPanelAfterToggle == panel ? KeyboardShortcut(KeyEquivalent(AppShortcut.inputPanel), modifiers: AppShortcut.modifiers) : nil)
                        .disabled(session?.uiState.isDeckDocked == true && !panel.isAvailableDocked)
                }
            }
            Menu("Paste") {
                Button("From Clipboard") { session?.pasteDeviceClipboard() }
                Button("Password…") { session?.setPasswordEntryPresented(true) }
                Button("Login Password") { session?.pasteLoginPassword() }
                    .disabled(session?.hasLoginPassword != true)
            }
            .disabled(session?.acceptsInput != true)
            Divider()
            Button("Scale to Fit") { session?.setScaleToFit(true) }
                .disabled(session == nil || session?.uiState.zoomMode == .fit)
            Button("Actual Size") { session?.setZoomMode(.actualSize) }
                .disabled(session == nil)
            Divider()
            if let session, session.layout.displays.count > 1 {
                Menu("Display") {
                    ForEach(session.layout.displays) { display in
                        Button(display.name) { session.selectDisplay(display.id) }
                    }
                    if ExternalDisplayController.shared.offersDisplayWindow {
                        Divider()
                        Button("Show Other Display in New Window") {
                            let other = session.layout.displays.first { $0.id != session.selectedDisplay?.id } ?? session.layout.displays[0]
                            openWindow(id: "session", value: SessionWindowID(sessionID: session.id, displayID: other.id.rawValue))
                        }
                    }
                }
            }
            if let session, !session.availableExternalDisplayModes.isEmpty {
                Menu(ExternalDisplayController.shared.isWindow ? "Other Window" : "External Display") {
                    ForEach(session.availableExternalDisplayModes, id: \.self) { mode in
                        Button(mode.title) { session.setExternalDisplayMode(mode) }
                    }
                }
            }
            if let session, !session.features.qualityPresets.isEmpty {
                Menu("Quality") {
                    ForEach(session.features.qualityPresets, id: \.self) { preset in
                        Button(preset == .adaptive ? "Adaptive Quality" : "Full Quality") { session.setQuality(preset) }
                    }
                }
            }
            Button("Files…") { session?.setFilesPresented(true) }
                .keyboardShortcut(KeyEquivalent(AppShortcut.files), modifiers: AppShortcut.modifiers)
            Toggle("Mute Sound", isOn: Binding(get: { session?.isAudioMuted == true }, set: { session?.setAudioMuted($0) }))
                .keyboardShortcut(KeyEquivalent(AppShortcut.mute), modifiers: AppShortcut.modifiers)
            Divider()
            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut(KeyEquivalent(AppShortcut.disconnect), modifiers: AppShortcut.modifiers)
            }
            .disabled(session == nil)
        }
        // For keys iPadOS keeps for itself (⌘Tab, ⌘Space, ⌘H, Globe) or when no keyboard is
        // attached. No shortcuts here: with a keyboard, the real combination goes to the Mac.
        CommandMenu("Mac") {
            Group {
            if let session {
                ForEach(session.features.remoteActions, id: \.self) { action in
                    Button(action.title) { session.perform(action) }
                }
                if session.features.curtain.isAvailable {
                    Toggle("Curtain Mode", isOn: Binding(get: { session.features.isCurtained }, set: { session.setCurtained($0) }))
                }
                Divider()
            }
            ForEach(ShortcutCatalog.Category.allCases, id: \.self) { category in
                Menu(category.title) {
                    ForEach(ShortcutCatalog.shortcuts(in: category)) { shortcut in
                        Button("\(shortcut.title)  \(shortcut.symbols)") { session?.perform(shortcut) }
                    }
                }
            }
            }
            .disabled(session == nil || session?.acceptsInput != true)
        }
        CommandGroup(replacing: .help) {
            Button("Setting Up a Mac") { library?.showHelp() }
                .disabled(library == nil)
            Divider()
            Button("Support Us") { library?.showSupport() }
                .disabled(library == nil)
        }
    }
}

/// Tells whether the app's window is smaller than its screen (an iPad window, Split View, Stage
/// Manager), and again whenever that changes.
struct WindowModeProbe: UIViewRepresentable {
    /// `-MarionetteWindowed`: report a window whatever the real one is.
    var override = false
    var onChange: (Bool) -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.override = override
        view.onChange = onChange
        view.report()
    }

    final class Probe: UIView {
        var override = false
        var onChange: (Bool) -> Void = { _ in }
        private var last: Bool?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        func report() {
            guard let window, let screen = window.windowScene?.screen else { return }
            let windowed = override
                || abs(window.bounds.width - screen.bounds.width) > 1
                || abs(window.bounds.height - screen.bounds.height) > 1
            guard windowed != last else { return }
            last = windowed
            // Not during layout: this changes observed state.
            DispatchQueue.main.async { [onChange] in onChange(windowed) }
        }
    }
}
