// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import RemoteDesktopInteraction
import SwiftUI
import MarionetteKit

/// A Mac-layout keyboard for the input deck. Sends key codes, not text: a key is down while touched
/// and up when released. Modifiers latch as on the bar above the system keyboard; both share the
/// session model's modifier state.
struct MacKeyboardView: View {
    let session: SessionModel

    private let spacing: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            // Drops the function row when there is not the height for six rows of usable keys.
            let layout = proxy.size.height >= 250 ? MacKeyboardLayout.ansi : MacKeyboardLayout.ansiCompact
            let unit = max(1, (proxy.size.width + spacing) / layout.unitWidth)
            let weights = layout.rows.reduce(0) { $0 + $1.heightFactor }
            let rowUnit = max(1, (proxy.size.height - spacing * CGFloat(layout.rows.count - 1)) / weights)
            VStack(spacing: spacing) {
                ForEach(layout.rows) { row in
                    HStack(spacing: spacing) {
                        ForEach(row.keys) { key in
                            keyCap(key)
                                .frame(width: max(1, unit * key.width - spacing))
                        }
                    }
                    .frame(height: min(54, rowUnit * row.heightFactor))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Key width is bounded by the screen, so legends stop growing at the largest
        // non-accessibility size.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .disabled(!session.acceptsInput)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-keyboard")
    }

    @ViewBuilder
    private func keyCap(_ key: MacKeyboardLayout.Key) -> some View {
        if case .modifier(let modifier) = key.role {
            ModifierKeyCap(session: session, modifier: modifier, side: key.modifierSide, label: key.label)
                .accessibilityLabel(key.accessibilityName)
        } else {
            let shifted = session.uiState.modifiers.isActive(.shift)
            let legend = shifted ? (key.shiftedLabel ?? key.label) : key.label
            KeyCap(
                tone: key.role == .character ? .character : .control,
                accessibilityName: key.accessibilityName,
                onPress: { session.keyDown(key.key) },
                onRelease: { session.keyUp(key.key) }
            ) {
                Text(legend)
                    .font(.system(key.role == .character ? .title3 : .footnote, design: .rounded))
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
            .accessibilityIdentifier("mac-key-\(key.id)")
        }
    }
}
