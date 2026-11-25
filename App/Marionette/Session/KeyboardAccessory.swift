// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import RemoteDesktopInteraction
import SwiftUI
import UIKit
import MarionetteKit

/// The bar above the system keyboard: the keys a Mac needs that the system keyboard lacks.
///
/// Modifiers latch (tap: next key only; tap again: locked; third tap: off). Escape, tab, forward
/// delete and the arrows are held for as long as they are pressed, so the Mac repeats them. A second
/// page has F1 to F12, and a third every other key the remote keyboard can send. The bar itself is
/// Liquid Glass; the key caps on it are opaque.
struct KeyboardAccessoryBar: View {
    let session: SessionModel

    private static let editingKeys: [(key: KeyCode, title: String, name: String, image: String?)] = [
        (.escape, String(localized: "esc"), String(localized: "Escape"), nil),
        (.tab, String(localized: "tab"), String(localized: "Tab"), "arrow.right.to.line"),
        (.deleteForward, String(localized: "del"), String(localized: "Forward Delete"), "delete.forward"),
    ]

    private static let arrowKeys: [(key: KeyCode, name: String, image: String)] = [
        (.leftArrow, String(localized: "Left Arrow"), "arrow.left"),
        (.downArrow, String(localized: "Down Arrow"), "arrow.down"),
        (.upArrow, String(localized: "Up Arrow"), "arrow.up"),
        (.rightArrow, String(localized: "Right Arrow"), "arrow.right"),
    ]

    private static let functionKeys: [KeyCode] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]

    /// The "More Keys" page, in groups: every key with a meaning on the wire (an X11 keysym) that
    /// neither the system keyboard nor the other pages have.
    private static let moreKeyGroups: [[(key: KeyCode, title: String, name: String)]] = [
        [
            (.home, String(localized: "home"), String(localized: "Home")), (.end, String(localized: "end"), String(localized: "End")),
            (.pageUp, String(localized: "pg up"), String(localized: "Page Up")), (.pageDown, String(localized: "pg dn"), String(localized: "Page Down")),
            (.insert, String(localized: "ins"), String(localized: "Insert (Help on a Mac)")),
        ],
        [
            (.f13, "F13", "F13"), (.f14, "F14", "F14"), (.f15, "F15", "F15"), (.f16, "F16", "F16"),
            (.f17, "F17", "F17"), (.f18, "F18", "F18"), (.f19, "F19", "F19"), (.f20, "F20", "F20"),
        ],
        [
            (.printScreen, String(localized: "prt sc"), String(localized: "Print Screen")), (.scrollLock, String(localized: "scr lk"), String(localized: "Scroll Lock")),
            (.pause, String(localized: "pause"), String(localized: "Pause")), (.application, String(localized: "menu"), String(localized: "Menu")), (.capsLock, String(localized: "caps"), String(localized: "Caps Lock")),
        ],
        [
            (.keypadNumLock, String(localized: "clear"), String(localized: "Keypad Clear (Num Lock)")), (.keypadEqual, "=", String(localized: "Keypad Equals")),
            (.keypadSlash, "÷", String(localized: "Keypad Divide")), (.keypadAsterisk, "×", String(localized: "Keypad Multiply")),
            (.keypad7, "7", String(localized: "Keypad 7")), (.keypad8, "8", String(localized: "Keypad 8")), (.keypad9, "9", String(localized: "Keypad 9")),
            (.keypadHyphen, "−", String(localized: "Keypad Minus")),
            (.keypad4, "4", String(localized: "Keypad 4")), (.keypad5, "5", String(localized: "Keypad 5")), (.keypad6, "6", String(localized: "Keypad 6")),
            (.keypadPlus, "+", String(localized: "Keypad Plus")),
            (.keypad1, "1", String(localized: "Keypad 1")), (.keypad2, "2", String(localized: "Keypad 2")), (.keypad3, "3", String(localized: "Keypad 3")),
            (.keypad0, "0", String(localized: "Keypad 0")), (.keypadPeriod, ".", String(localized: "Keypad Decimal Point")),
            (.keypadEnter, String(localized: "enter"), String(localized: "Keypad Enter")),
        ],
    ]

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    switch session.uiState.accessoryPage {
                    case .keys: keysPage
                    case .functionKeys: functionPage
                    case .moreKeys: moreKeysPage
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 36)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            // Each page starts scrolled to its beginning.
            .id(session.uiState.accessoryPage)

            Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") {
                session.setInputPanel(.hidden)
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 36)
            .contentShape(.rect)
            .accessibilityShowsLargeContentViewer { Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") }
            .accessibilityIdentifier("accessory-dismiss")
            .padding(.trailing, 4)
        }
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        // Fixed height, like the keyboard under it: keys stop growing at the largest
        // non-accessibility size.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .disabled(!session.acceptsInput)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keyboard-accessory")
    }

    @ViewBuilder
    private var keysPage: some View {
        ForEach(ModifierLatch.Modifier.allCases, id: \.self) { modifier in
            ModifierKeyCap(session: session, modifier: modifier)
                .frame(width: 40)
        }
        separator
        ForEach(Self.editingKeys, id: \.name) { entry in
            SessionKeyCap(session: session, key: entry.key, title: entry.title, name: entry.name, systemImage: entry.image)
                .frame(width: 42)
        }
        separator
        ForEach(Self.arrowKeys, id: \.name) { entry in
            SessionKeyCap(session: session, key: entry.key, title: "", name: entry.name, systemImage: entry.image)
                .frame(width: 40)
        }
        separator
        pageButton(title: String(localized: "F1–F12"), name: String(localized: "Function Keys"), target: .functionKeys)
        pageButton(title: String(localized: "more"), name: String(localized: "More Keys"), target: .moreKeys)
        shortcutsMenu
        pasteButton
    }

    @ViewBuilder
    private var functionPage: some View {
        pageButton(title: "⌘ ⌥ …", name: String(localized: "Modifier Keys"), target: .keys)
        separator
        ForEach(Array(Self.functionKeys.enumerated()), id: \.offset) { index, key in
            SessionKeyCap(session: session, key: key, title: "F\(index + 1)", name: "F\(index + 1)")
                .frame(width: 42)
        }
        separator
        pageButton(title: String(localized: "more"), name: String(localized: "More Keys"), target: .moreKeys)
    }

    @ViewBuilder
    private var moreKeysPage: some View {
        pageButton(title: "⌘ ⌥ …", name: String(localized: "Modifier Keys"), target: .keys)
        ForEach(Array(Self.moreKeyGroups.enumerated()), id: \.offset) { index, group in
            separator
            if index == Self.moreKeyGroups.count - 1 {
                Text("keypad")
                    .font(.caption2.weight(.medium))
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            ForEach(group, id: \.name) { entry in
                SessionKeyCap(session: session, key: entry.key, title: entry.title, name: entry.name)
                    .frame(width: entry.title.count > 3 ? 50 : 40)
            }
        }
    }

    private var separator: some View {
        Divider().frame(height: 22)
    }

    private func pageButton(title: String, name: String, target: AccessoryPage) -> some View {
        KeyCap(accessibilityName: name, onPress: {}, onRelease: { session.setAccessoryPage(target) }) {
            Text(title)
                .font(.system(.footnote, design: .rounded).weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("accessory-page-\(target.rawValue)")
    }

    private var shortcutsMenu: some View {
        Menu {
            ForEach(ShortcutCatalog.Category.allCases, id: \.self) { category in
                Section(category.title) {
                    ForEach(ShortcutCatalog.shortcuts(in: category)) { shortcut in
                        Button("\(shortcut.title)  \(shortcut.symbols)") { session.perform(shortcut) }
                    }
                }
            }
        } label: {
            Image(systemName: "command")
                .font(.system(.callout, design: .rounded).weight(.medium))
                .frame(width: 40, height: 36)
                .foregroundStyle(.primary)
                .background(Color(uiColor: .systemGray3), in: .rect(cornerRadius: 6))
        }
        .accessibilityLabel("Keyboard Shortcuts")
        .accessibilityShowsLargeContentViewer { Label("Keyboard Shortcuts", systemImage: "command") }
        .accessibilityIdentifier("accessory-shortcuts")
    }

    /// The system paste control: hands over the clipboard without the "Allow Paste" prompt. Shown
    /// in every clipboard mode; with sharing off it types the text instead.
    private var pasteButton: some View {
        SessionPasteControl(session: session, isKeyCap: true)
    }
}

/// Hosts the bar as a UIKit input accessory view.
final class KeyboardAccessoryView: UIView {
    private let host: UIHostingController<KeyboardAccessoryBar>

    init(session: SessionModel) {
        host = UIHostingController(rootView: KeyboardAccessoryBar(session: session))
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height))
        autoresizingMask = .flexibleWidth
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    static let height: CGFloat = 58

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }
}
