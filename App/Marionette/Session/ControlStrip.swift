// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import RemoteDesktopInteraction
import SwiftUI
import UIKit
import MarionetteKit

/// The session's controls: a Liquid Glass strip floating over the remote display, always above the
/// keyboard or the deck.
///
/// A glass capsule of plain glyphs and a separate glass fold button share one
/// `GlassEffectContainer`, so they morph as one material. Folded, only the button remains; it fades
/// after a few seconds without a touch (so nothing is left over the picture when a mouse is used)
/// and returns on a touch. ``TransferIndicator`` joins them while files move.
///
/// Where the system stands its bars along one side (outer display of a closed iPhone Duo), the strip
/// is a column at the bottom of that side strip; otherwise it is centred at the bottom.
struct ControlStrip: View {
    let session: SessionModel
    /// The system's own reserve at the bottom of the screen (the home indicator's strip).
    var bottomInset: CGFloat = 0
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    /// The side the system stands its bars up along, if it does.
    var barEdge: HorizontalEdge?

    @Namespace private var glass
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.foldContext) private var fold

    /// Held like a book, the fold runs down the screen: the strip keeps to the half after it rather
    /// than sit across it.
    private var foldClearance: CGFloat {
        guard fold.pose == .book, let division = fold.division else { return 0 }
        return division.maxX
    }

    /// A column in the side strip. Not while a keyboard or the deck is up: those take the full
    /// width, side strip included, and leave no height for a column above them.
    private var isVertical: Bool {
        barEdge != nil && session.uiState.bottomObstruction == 0
    }

    var body: some View {
        let ui = session.uiState
        let collapsed = ui.areControlsCollapsed
        let vertical = isVertical
        // In full screen there is no home indicator to keep clear of.
        let rest = ui.showsFullScreen ? 10 : bottomInset + 4
        let bottom = max(ui.bottomObstruction + 8, rest)
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        GlassEffectContainer(spacing: 10) {
            layout {
                // Before the controls, so that the fold button keeps its place at the end.
                if session.transfers.hasActivity {
                    StripTransferIndicator(session: session, vertical: vertical)
                        .glassEffectID("transfers", in: glass)
                }
                if !collapsed {
                    if vertical {
                        // The column shares the side strip with the title bar's own buttons above
                        // it, except in full screen, where there are none.
                        controls(vertical: true, compact: !ui.showsFullScreen)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            controls(vertical: false, compact: false)
                            controls(vertical: false, compact: true)
                        }
                    }
                }
                // Faded means removed: a merely transparent view stops taking taps once shown again.
                // With VoiceOver it stays, since the touch that brings it back cannot be found by ear.
                if !collapsed || ui.isControlsHandleVisible || voiceOverEnabled { foldButton(collapsed: collapsed, vertical: vertical) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: vertical ? .infinity : nil, alignment: alignment(collapsed: collapsed, vertical: vertical))
        .padding(.leading, sidePadding(.leading, vertical: vertical))
        .padding(.trailing, sidePadding(.trailing, vertical: vertical))
        .padding(.bottom, bottom)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: collapsed)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: vertical)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: ui.isControlsHandleVisible)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: session.transfers.hasActivity)
        .animation(reduceMotion ? nil : .snappy, value: bottom)
        // Like the session's title bar, the strip is dark glass with light glyphs in either
        // appearance: it floats over a remote screen and its black surround, and has to read on both.
        .environment(\.colorScheme, .dark)
    }

    private func alignment(collapsed: Bool, vertical: Bool) -> Alignment {
        if vertical { return barEdge == .leading ? .bottomLeading : .bottomTrailing }
        return collapsed ? .trailing : .center
    }

    /// As a column, the strip is centred in the side strip the system reserves for its bar. Across
    /// the screen in full screen, that reserve holds no bar, so the strip centres on the whole width.
    private func sidePadding(_ side: HorizontalEdge, vertical: Bool) -> CGFloat {
        var inset = side == .leading ? leadingInset : trailingInset
        if vertical, side == barEdge { return max((inset - 44) / 2, 10) }
        if side == barEdge, session.uiState.showsFullScreen { inset = 0 }
        if side == .leading { return max(12 + inset, vertical ? 0 : foldClearance + 8) }
        return 12 + inset
    }

    // MARK: Pieces

    private func foldButton(collapsed: Bool, vertical: Bool) -> some View {
        let symbol = vertical
            ? (collapsed ? "chevron.up" : "chevron.down")
            : (collapsed ? "chevron.backward" : "chevron.forward")
        return Button {
            session.setControlsCollapsed(!collapsed)
        } label: {
            glyph(symbol)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("fold", in: glass)
        .accessibilityLabel(collapsed ? "Show Controls" : "Hide Controls")
        .accessibilityShowsLargeContentViewer { Label(collapsed ? "Show Controls" : "Hide Controls", systemImage: symbol) }
        .accessibilityIdentifier(collapsed ? "expand-controls" : "collapse-controls")
    }

    private func controls(vertical: Bool, compact: Bool) -> some View {
        let ui = session.uiState
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        return layout {
            inputModeButton
            inputPanelButton
            if session.clipboard.isAvailable && session.acceptsInput {
                SessionPasteControl(session: session)
            }
            StripDivider(vertical: vertical)
            // Screen Sharing's two zooms: Scale to Fit, which keeps the picture fitted through
            // rotations and folds, and Actual Size, a zoom like any other.
            if !compact {
                item("Actual Size", systemImage: "1.magnifyingglass") { session.setZoomMode(.actualSize) }
                    .accessibilityIdentifier("actual-size")
            }
            item("Scale to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { session.setScaleToFit(true) }
                .disabled(ui.zoomMode == .fit)
                .accessibilityIdentifier("scale-to-fit")
            StripDivider(vertical: vertical)
            moreMenu
            // In a window there is no leaving full screen: the session is the window.
            if ui.isFullScreen && !ui.isWindowed {
                item("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left") { setFullScreen(false) }
                    .accessibilityIdentifier("exit-full-screen")
            }
        }
        .padding(vertical ? .vertical : .horizontal, 6)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("controls", in: glass)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("control-strip")
    }

    private func glyph(_ systemImage: String) -> some View {
        ControlStripGlyph(systemImage: systemImage)
    }

    /// The strip cannot grow with the text size, so each glyph offers the Large Content Viewer.
    private func item(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { glyph(systemImage) }
            .buttonStyle(StripButtonStyle())
            .accessibilityLabel(title)
            .accessibilityShowsLargeContentViewer { Label(title, systemImage: systemImage) }
    }

    private var inputModeButton: some View {
        let mode = session.uiState.inputMode
        return item("Touch Mode", systemImage: mode == .touch ? "hand.tap" : "cursorarrow.motionlines") {
            session.toggleInputMode()
        }
        .accessibilityValue(mode == .touch ? "Direct Input" : "Trackpad")
        .accessibilityHint("Switches between touching the screen directly and using it as a trackpad")
        .accessibilityIdentifier("toggle-input-mode")
        // The picture is on the monitor: this screen can only be a trackpad.
        .disabled(session.externalDisplayMode == .externalOnly)
    }

    /// A press shows or hides the on-screen input (the last shown, or the Settings default); a long
    /// press chooses one. Docked, a press switches between trackpad and Mac keyboard, and the other
    /// options are disabled.
    private var inputPanelButton: some View {
        let ui = session.uiState
        let panel = ui.inputPanel
        // No Large Content Viewer here, unlike the other glyphs: it is shown by holding, and holding
        // this one opens its menu.
        // The glyph is the panel on screen, or the one a press brings up: never a "hide" glyph.
        return Button { session.toggleInputPanel() } label: { glyph(Self.symbol(for: session.panelForKeyboardControl)) }
        .buttonStyle(.plain)
        .accessibilityLabel("On-Screen Input")
        .accessibilityValue(panel.title)
        .accessibilityHint(ui.isDeckDocked
            ? "Switches the lower screen between the trackpad and the Mac keyboard"
            : "Shows or hides the on-screen input. Press and hold to choose input type")
        .accessibilityIdentifier("input-panel")
        .contextMenu {
            ForEach(InputPanel.allCases, id: \.self) { option in
                Toggle(isOn: Binding(get: { session.uiState.inputPanel == option }, set: { if $0 { session.setInputPanel(option) } })) {
                    Label(option.title, systemImage: Self.symbol(for: option))
                }
                .disabled(session.uiState.isDeckDocked && !option.isAvailableDocked)
            }
        }
        .disabled(!session.acceptsInput)
    }

    private static func symbol(for panel: InputPanel) -> String {
        switch panel {
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .deckKeyboard: "command.square"
        case .systemKeyboard: "keyboard"
        case .hidden: "keyboard.chevron.compact.down"
        }
    }

    private func setFullScreen(_ fullScreen: Bool) {
        if reduceMotion {
            session.setFullScreen(fullScreen)
        } else {
            withAnimation(.smooth) { session.setFullScreen(fullScreen) }
        }
    }

    // MARK: More

    private var moreMenu: some View {
        Menu {
            if hasViewMenu {
                Menu("View", systemImage: "display.2") { viewMenuContent }
                    .accessibilityIdentifier("view-menu")
            }
            if !session.features.qualityPresets.isEmpty {
                Picker("Quality", systemImage: "dial.medium", selection: Binding(get: { session.quality }, set: { session.setQuality($0) })) {
                    ForEach(session.features.qualityPresets, id: \.self) { preset in
                        Text(preset == .adaptive ? "Adaptive Quality" : "Full Quality").tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("quality-menu")
            }
            if !session.features.remoteActions.isEmpty || session.features.curtain != .unavailable(.notSupportedByBackend) {
                Section("On the Computer") {
                    ForEach(session.features.remoteActions, id: \.self) { action in
                        Button(action.title, systemImage: action.symbolName) { session.perform(action) }
                    }
                    curtainControl
                }
            }
            Menu("Keyboard Shortcuts", systemImage: "command") {
                ForEach(ShortcutCatalog.Category.allCases, id: \.self) { category in
                    Section(category.title) {
                        ForEach(ShortcutCatalog.shortcuts(in: category)) { shortcut in
                            Button("\(shortcut.title)  \(shortcut.symbols)") { session.perform(shortcut) }
                        }
                    }
                }
            }
            .disabled(!session.acceptsInput)
            Button("Files…", systemImage: "folder") { session.setFilesPresented(true) }
                .accessibilityIdentifier("open-files")
            if session.features.audio.isAvailable {
                Toggle("Mute Sound", systemImage: "speaker.slash", isOn: Binding(get: { session.isAudioMuted }, set: { session.setAudioMuted($0) }))
            }
            Section {
                Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { session.disconnect() }
            }
        } label: {
            glyph("ellipsis")
        }
        // A menu's label takes the accent colour by default; on the strip every glyph is the same.
        .tint(.primary)
        .accessibilityLabel("More")
        .accessibilityShowsLargeContentViewer { Label("More", systemImage: "ellipsis") }
        .accessibilityIdentifier("more-menu")
    }

    /// Curtain mode hides the computer's own screen.
    @ViewBuilder
    private var curtainControl: some View {
        switch session.features.curtain {
        case .available:
            Toggle("Curtain Mode", systemImage: "lock.display", isOn: Binding(get: { session.features.isCurtained }, set: { session.setCurtained($0) }))
                .accessibilityIdentifier("curtain-mode")
        case .unavailable(.notSupportedByBackend):
            EmptyView()
        case .unavailable(let reason):
            // A menu shows the second text as a subtitle, which wraps.
            Button {} label: {
                Label {
                    Text("Curtain Mode")
                    Text(reason.explanation)
                } icon: {
                    Image(systemName: "lock.display")
                }
            }
            .disabled(true)
        }
    }

    private var hasViewMenu: Bool {
        session.layout.displays.count > 1 || !session.availableExternalDisplayModes.isEmpty
    }

    @ViewBuilder
    private var viewMenuContent: some View {
        if session.layout.displays.count > 1 {
            Picker("Display", selection: Binding(get: { session.selectedDisplay?.id }, set: { if let id = $0 { session.selectDisplay(id) } })) {
                ForEach(session.layout.displays) { display in
                    Label(display.name, systemImage: "display").tag(Optional(display.id))
                }
            }
        }
        if session.layout.displays.count > 1, ExternalDisplayController.shared.offersDisplayWindow {
            Button("Show Other Display in New Window", systemImage: "macwindow.badge.plus") {
                let other = session.layout.displays.first { $0.id != session.selectedDisplay?.id } ?? session.layout.displays[0]
                openWindow(id: "session", value: SessionWindowID(sessionID: session.id, displayID: other.id.rawValue))
            }
            .accessibilityIdentifier("open-display-window")
        }
        if !session.availableExternalDisplayModes.isEmpty {
            Section(ExternalDisplayController.shared.isWindow ? "Other Window" : "External Display") {
                Picker("External Display", selection: Binding(get: { session.externalDisplayMode }, set: { session.setExternalDisplayMode($0) })) {
                    ForEach(session.availableExternalDisplayModes, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("external-display-mode")
            }
        }
    }
}

/// A plain glyph button that dims while it cannot be used, as the system's bar buttons do.
struct StripButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

private struct StripDivider: View {
    let vertical: Bool

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.25))
            .frame(width: vertical ? 22 : 1, height: vertical ? 1 : 22)
            .padding(vertical ? .vertical : .horizontal, 4)
            .accessibilityHidden(true)
    }
}

/// A view of its own so that progress, which changes many times a second, redraws only this and not
/// the strip and its menus.
private struct StripTransferIndicator: View {
    let session: SessionModel
    let vertical: Bool

    var body: some View {
        if let activity = session.transfers.activity {
            TransferIndicator(activity: activity, vertical: vertical) { session.setFilesPresented(true) }
        }
    }
}

/// A glyph on the control strip, sized like a bar button's.
struct ControlStripGlyph: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.primary)
            // 44 points where there is room; a little less on the narrowest phones, where the strip
            // would otherwise run past the screen's edges.
            .frame(minWidth: 36, idealWidth: 44, maxWidth: 44, minHeight: 36, idealHeight: 44, maxHeight: 44)
            .contentShape(.rect)
    }
}
