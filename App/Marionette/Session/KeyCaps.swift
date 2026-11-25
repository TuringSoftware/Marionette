// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import RemoteDesktopInteraction
import SwiftUI
import MarionetteKit

/// One key of an on-screen keyboard. A key cap is content, so it is an opaque surface, never glass.
///
/// Reports press and release separately: the remote machine sees the key held while the finger is
/// down and does its own key repeat.
struct KeyCap<Label: View>: View {
    enum Tone {
        /// Letters, digits, punctuation.
        case character
        /// Modifiers and the other keys that do not type anything.
        case control
        /// A modifier that is latched or locked.
        case active
    }

    var tone: Tone = .control
    let accessibilityName: String
    var accessibilityValue = ""
    var onPress: () -> Void
    var onRelease: () -> Void
    @ViewBuilder var label: Label

    @State private var isPressed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(tone == .active ? Color.white : Color.primary)
            .background(fill, in: .rect(cornerRadius: 6))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.25), radius: 0, y: 1)
            .contentShape(.rect)
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 44, perform: {}, onPressingChanged: { pressing in
                guard pressing != isPressed else { return }
                isPressed = pressing
                if pressing { onPress() } else { onRelease() }
            })
            .onDisappear {
                // A key that goes away while held (the page was switched) must still come up.
                if isPressed {
                    isPressed = false
                    onRelease()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits([.isButton, .isKeyboardKey])
            .accessibilityAction {
                onPress()
                onRelease()
            }
    }

    private var fill: Color {
        let dark = colorScheme == .dark
        switch (tone, isPressed) {
        case (.active, _): return .prominentFill
        case (.character, false): return dark ? Color(white: 0.42) : .white
        case (.character, true): return dark ? Color(white: 0.30) : Color(white: 0.72)
        case (.control, false): return dark ? Color(white: 0.28) : Color(white: 0.70)
        case (.control, true): return dark ? Color(white: 0.42) : .white
        }
    }
}

/// A modifier key with its three states: off, on for the next key, and locked.
struct ModifierKeyCap: View {
    let session: SessionModel
    let modifier: ModifierLatch.Modifier
    /// Which of the modifier's keys this is; a full keyboard has a right-hand one too.
    var side: ModifierLatch.Side = .left
    var label: String?
    @ScaledMetric(relativeTo: .caption2) private var lockSize: CGFloat = 7

    var body: some View {
        let state = session.uiState.modifiers.state(of: modifier, side: side)
        KeyCap(
            tone: state == .off ? .control : .active,
            accessibilityName: Self.name(of: modifier),
            accessibilityValue: state == .off ? String(localized: "Off") : state == .oneShot ? String(localized: "On for the next key") : String(localized: "Locked"),
            onPress: { session.tapModifier(modifier, side: side) },
            onRelease: {}
        ) {
            VStack(spacing: 0) {
                Text(label ?? modifier.symbol)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                // The lock mark is what tells "locked" from "next key only" without relying on colour.
                Image(systemName: "lock.fill")
                    .font(.system(size: lockSize, weight: .bold))
                    .opacity(state == .locked ? 1 : 0)
                    .frame(height: lockSize + 1)
            }
            .padding(.top, 4)
        }
        .accessibilityHint("Tap for the next key, tap again to lock")
        .accessibilityIdentifier(side == .left || modifier == .function ? "modifier-\(modifier.rawValue)" : "modifier-\(modifier.rawValue)-right")
    }

    static func name(of modifier: ModifierLatch.Modifier) -> String {
        switch modifier {
        case .control: String(localized: "Control")
        case .option: String(localized: "Option")
        case .shift: String(localized: "Shift")
        case .command: String(localized: "Command")
        case .function: String(localized: "Function")
        }
    }
}

/// A key that sends one key code: down while pressed, up when let go.
struct SessionKeyCap: View {
    let session: SessionModel
    let key: KeyCode
    let title: String
    let name: String
    var systemImage: String?
    var tone: KeyCap<AnyView>.Tone = .control

    var body: some View {
        KeyCap(
            tone: tone,
            accessibilityName: name,
            onPress: { session.keyDown(key) },
            onRelease: { session.keyUp(key) }
        ) {
            AnyView(
                Group {
                    if let systemImage {
                        Image(systemName: systemImage)
                    } else {
                        Text(title)
                    }
                }
                .font(.system(.callout, design: .rounded).weight(.medium))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            )
        }
        .accessibilityIdentifier("key-\(name)")
    }
}
