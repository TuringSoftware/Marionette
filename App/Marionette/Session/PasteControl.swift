// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
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
struct SessionPasteControl: View {
    let session: SessionModel
    /// The bar above the keyboard draws its controls as key caps.
    var isKeyCap = false

    @State private var hasText = false

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
            Button {
                // Read in the press: this is the moment iOS may ask.
                guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
                session.paste(text)
            } label: {
                ControlStripGlyph(systemImage: "doc.on.clipboard")
                    .overlay(alignment: .topTrailing) {
                        if hasNews { dot.padding(.top, 9).padding(.trailing, 7) }
                    }
            }
            .buttonStyle(StripButtonStyle())
            // Whether there is text at all can be asked without the question.
            .disabled(!hasText)
            .onAppear(perform: refresh)
            .onChange(of: hasNews) { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
            .accessibilityLabel("Paste")
            .accessibilityValue(hasNews ? "New Contents" : "")
            .accessibilityShowsLargeContentViewer { Label("Paste", systemImage: "doc.on.clipboard") }
            .accessibilityIdentifier("toolbar-paste")
            .animation(.snappy, value: hasNews)
        }
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
