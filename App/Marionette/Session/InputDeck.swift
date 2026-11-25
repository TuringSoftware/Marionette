// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import RemoteDesktopInteraction
import SwiftUI
import MarionetteKit

/// The lower pane of a session: a trackpad or a Mac keyboard.
///
/// Folded like a laptop, the deck always fills the pane below the fold: a keyboard in direct-touch
/// mode, a trackpad in trackpad mode. Otherwise it is a panel over the bottom of the remote display,
/// shown when the keyboard control chose the trackpad or the Mac keyboard. The deck stays in the
/// view tree; only what it draws changes.
struct InputDeck: View {
    let session: SessionModel
    @Environment(\.foldContext) private var fold
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A panel that has just appeared takes no touches for a moment. The control strip moves up to
    /// make room for it, so a second quick tap on the keyboard control would otherwise land on the
    /// trackpad or a key that has just arrived under the finger, and reach the Mac.
    @State private var isSettled = true

    private var isDocked: Bool { fold.pose == .docked }

    var body: some View {
        let surface = session.uiState.deckSurface
        GeometryReader { proxy in
            Group {
                if isDocked {
                    DeckPanel(session: session, surface: surface ?? .keyboard)
                } else if let surface {
                    // A keyboard needs five rows of keys; a trackpad is useful at less.
                    let height = surface == .keyboard
                        ? min(380, max(270, proxy.size.height * 0.48))
                        : min(340, max(220, proxy.size.height * 0.42))
                    DeckPanel(session: session, surface: surface)
                        .frame(height: height)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .onChange(of: height + proxy.safeAreaInsets.bottom, initial: true) { _, overlap in
                            session.setDeckOverlap(overlap)
                        }
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: surface)
            .onChange(of: isDocked || surface == nil, initial: true) { _, clear in
                if clear { session.setDeckOverlap(0) }
            }
        }
        // With nothing to draw, the deck must not take touches meant for the remote display.
        .allowsHitTesting(isDocked || (surface != nil && isSettled))
        .task(id: surface) {
            guard !isDocked, surface != nil else {
                isSettled = true
                return
            }
            isSettled = false
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { isSettled = true }
        }
    }
}

private struct DeckPanel: View {
    let session: SessionModel
    let surface: DeckSurface

    var body: some View {
        Group {
            switch surface {
            case .trackpad: TrackpadSurface(session: session)
            case .keyboard: MacKeyboardView(session: session)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Edge to edge, like the system keyboard: the side strips the system keeps for its bars (the
        // closed iPhone Duo's) or its corners hold keys and trackpad too, not just the background.
        .ignoresSafeArea(.container, edges: .horizontal)
        // The deck is content, like a keyboard: an opaque surface, not glass.
        .background {
            Color(uiColor: .secondarySystemBackground)
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityIdentifier("input-deck")
                .accessibilityHidden(false)
        }
    }
}

/// A surface that works like a Mac trackpad, with the same gestures.
private struct TrackpadSurface: View {
    let session: SessionModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(uiColor: .tertiarySystemBackground))
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.separator, lineWidth: 0.5)
            InputCapture(
                session: session,
                surface: .deck,
                accessibilityLabel: String(localized: "Trackpad"),
                accessibilityHint: String(localized: "Works like a Mac trackpad.")
            )
            .clipShape(.rect(cornerRadius: 18))
        }
    }
}
