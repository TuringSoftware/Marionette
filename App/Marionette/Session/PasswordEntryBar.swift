// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MarionetteKit

/// A password field in the control strip's place, for a password to type at the remote computer.
///
/// iOS opens its password picker only from a password field that has the keyboard: the Passwords key
/// above the keyboard, or AutoFill in the field's menu. A password chosen there, or pasted, is sent
/// as it arrives; one typed by hand is sent with Return. The field is emptied before it goes away,
/// so that iOS is not left a filled password field to offer to save.
struct PasswordEntryBar: View {
    let session: SessionModel
    /// The system's own reserve at the bottom of the screen (the home indicator's strip).
    var bottomInset: CGFloat = 0
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    /// The side the system stands its bars up along, if it does.
    var barEdge: HorizontalEdge?

    @State private var password = ""
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.foldContext) private var fold

    /// Clear of the system's bars and of the fold, as ``ControlStrip`` keeps.
    private func sidePadding(_ side: HorizontalEdge) -> CGFloat {
        var inset = side == .leading ? leadingInset : trailingInset
        if side == barEdge, session.uiState.showsFullScreen { inset = 0 }
        guard side == .leading, fold.pose == .book, let division = fold.division else { return 12 + inset }
        return max(12 + inset, division.maxX + 8)
    }

    var body: some View {
        let ui = session.uiState
        let bottom = max(ui.bottomObstruction + 8, ui.showsFullScreen ? 10 : bottomInset + 4)
        HStack(spacing: 4) {
            Button(action: cancel) {
                ControlStripGlyph(systemImage: "xmark")
            }
            .buttonStyle(StripButtonStyle())
            .accessibilityLabel("Cancel")
            .accessibilityShowsLargeContentViewer { Label("Cancel", systemImage: "xmark") }
            .accessibilityIdentifier("password-entry-cancel")
            SecureField("Password", text: entry)
                .textContentType(.password)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .onKeyPress(.escape) {
                    cancel()
                    return .handled
                }
                .padding(.trailing, 16)
                .frame(minHeight: 44)
                .accessibilityIdentifier("password-entry-field")
        }
        .padding(.leading, 6)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 420)
        .padding(.leading, sidePadding(.leading))
        .padding(.trailing, sidePadding(.trailing))
        .padding(.bottom, bottom)
        // The whole stage, so that the caller's `ignoresSafeArea` measures from the screen's edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(reduceMotion ? nil : .snappy, value: bottom)
        .environment(\.colorScheme, .dark)
        .task { isFocused = true }
        // The session can take the field away itself, when the connection goes.
        .onDisappear { password = "" }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("password-entry")
    }

    /// Each edit is judged as the field makes it. Seen once a view update instead, two keys typed
    /// in quick succession would look like a password arriving whole.
    private var entry: Binding<String> {
        Binding {
            password
        } set: { new in
            let old = password
            password = new
            if PasswordEntry.isWholePassword(from: old, to: new) { send() }
        }
    }

    private func send() {
        let entered = password
        password = ""
        if entered.isEmpty {
            session.setPasswordEntryPresented(false)
        } else {
            session.submitPasswordEntry(entered)
        }
    }

    private func cancel() {
        password = ""
        session.setPasswordEntryPresented(false)
    }
}
