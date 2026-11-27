// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import TipKit
import UIKit
import MarionetteKit

/// Sends this device's clipboard to the remote computer and pastes it there, in one press. A dot
/// shows the clipboard has changed since it was last sent.
///
/// On the control strip it is a plain glyph that reads the clipboard itself, so iOS may ask "Allow
/// Paste?" (Settings › Marionette › Paste from Other Apps allows it permanently). The system
/// `PasteButton` is not used there: inside the strip's glass it stays disabled for text copied
/// before launch and still prompts after a copy in another app. On the bar above the keyboard the
/// system control is used, as a key cap. ⌘V on a hardware keyboard needs neither.
///
/// Held, the strip's glyph offers passwords as well: one from the system's password picker
/// (``PasswordEntryBar``), and the one the computer was signed in to with. Those are typed, and go on
/// no clipboard, so the glyph is there in every clipboard mode; with sharing off the clipboard's
/// text is typed too, as from the key cap.
struct SessionPasteControl: View {
    let session: SessionModel
    /// The bar above the keyboard draws its controls as key caps.
    var isKeyCap = false
    /// The side of the tip its arrow is on: the side the glyph is on, seen from the tip. The tip
    /// stands above a strip that runs across the screen, and beside one that is a column.
    var tipArrowEdge: Edge = .bottom

    @State private var hasText = false
    private let optionsTip = PasteOptionsTip()

    private var hasNews: Bool { session.clipboard.hasUnsentChange }

    private func refresh() {
        hasText = UIPasteboard.general.hasStrings
    }

    var body: some View {
        if isKeyCap {
            HStack(alignment: .top, spacing: 2) {
                PasteButton(payloadType: String.self) { strings in
                    session.paste(strings.joined(separator: "\n"))
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.roundedRectangle(radius: 6))
                .tint(Color(uiColor: .systemGray))
                .frame(height: 36)
                .accessibilityIdentifier("accessory-paste")
                if hasNews { dot.padding(.top, 2) }
            }
            .animation(.snappy, value: hasNews)
        } else {
            // No Large Content Viewer, and never disabled: holding the glyph opens its menu, which
            // has more than the clipboard in it.
            Button {
                if session.pasteDeviceClipboard() { PasteOptionsTip.hasPasted = true }
            } label: {
                ControlStripGlyph(systemImage: "doc.on.clipboard")
                    .overlay(alignment: .topTrailing) {
                        if hasNews { dot.padding(.top, 9).padding(.trailing, 7) }
                    }
            }
            .buttonStyle(StripButtonStyle())
            .onAppear(perform: refresh)
            .onChange(of: hasNews) { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
            .accessibilityLabel("Paste")
            .accessibilityValue(hasNews ? "New Contents" : "")
            .accessibilityHint("Pastes the clipboard. Press and hold to paste a password")
            .accessibilityIdentifier("toolbar-paste")
            .contextMenu {
                Section("Paste") {
                    // Whether there is text at all can be asked without iOS's question.
                    Button("From Clipboard", systemImage: "doc.on.clipboard") { chose { session.pasteDeviceClipboard() } }
                        .disabled(!hasText)
                        .accessibilityIdentifier("paste-clipboard")
                    Button("Password…", systemImage: "key") { chose { session.setPasswordEntryPresented(true) } }
                        .accessibilityIdentifier("paste-password")
                    Button("Login Password", systemImage: "person.badge.key") { chose { session.pasteLoginPassword() } }
                        .disabled(!session.hasLoginPassword)
                        .accessibilityIdentifier("paste-login-password")
                }
            }
            .overlay(alignment: tipAlignment) { tip }
            .animation(.snappy, value: hasNews)
        }
    }

    /// Something was chosen from the menu, so the tip about it has nothing left to say.
    private func chose(_ action: () -> Void) {
        optionsTip.invalidate(reason: .actionPerformed)
        action()
    }

    private var tipAlignment: Alignment {
        switch tipArrowEdge {
        case .leading: .trailing
        case .trailing: .leading
        case .top, .bottom: .top
        }
    }

    /// The tip, laid out beyond the glyph's own bounds with its arrow at the glyph.
    ///
    /// In place rather than as a popover: while a popover is up, the first touch anywhere only
    /// dismisses it, and the press and hold this tip asks for would open nothing.
    private var tip: some View {
        TipView(optionsTip, arrowEdge: tipArrowEdge)
            .frame(width: 230)
            .fixedSize(horizontal: false, vertical: true)
            .alignmentGuide(.top) { $0[.bottom] + 4 }
            .alignmentGuide(HorizontalAlignment.leading) { $0[.trailing] + 4 }
            .alignmentGuide(HorizontalAlignment.trailing) { $0[.leading] - 4 }
    }

    private var dot: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .accessibilityElement()
            .accessibilityLabel("New Clipboard Contents")
            .accessibilityIdentifier("clipboard-changed")
            .transition(.scale.combined(with: .opacity))
    }
}

extension SessionModel {
    /// Pastes this device's clipboard, read here and now: a press is the moment iOS may ask "Allow
    /// Paste?". A clipboard without text is not read, since the question would be for nothing.
    /// Returns whether anything was pasted.
    @discardableResult
    func pasteDeviceClipboard() -> Bool {
        guard UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string, !text.isEmpty else { return false }
        paste(text)
        return true
    }
}

/// Points at the paste glyph's menu once the glyph has been used.
struct PasteOptionsTip: Tip {
    /// Set by the first paste from the glyph.
    @Parameter static var hasPasted: Bool = false

    var title: Text { Text("Paste Passwords") }
    var message: Text? { Text("Press and hold for more ways to paste.") }

    var rules: [Rule] {
        #Rule(Self.$hasPasted) { $0 }
    }
}
