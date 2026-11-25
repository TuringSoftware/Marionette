// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import MarionetteKit

/// The SSH keys kept in the keychain on this device: make one, bring one in, hand out its public half.
struct SSHKeysView: View {
    let store: SSHKeyStore

    @State private var keys: [SSHKeyInfo] = []
    @State private var problem: String?
    @State private var copiedKey: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let instructions = String(localized: "To sign in with a key, add its public key to ~/.ssh/authorized_keys on the computer.")

    var body: some View {
        List {
            ForEach(keys) { key in
                VStack(alignment: .leading, spacing: 4) {
                    let name = Text(key.name).font(.headline)
                    let type = Text(key.typeName).font(.footnote).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { name; Spacer(); type }
                        VStack(alignment: .leading, spacing: 2) { name; type }
                    }
                    if let fingerprint = key.fingerprint {
                        Text(fingerprint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .truncationMode(.middle)
                    }
                    if key.isEncrypted {
                        Label("Protected by a passphrase", systemImage: "lock")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let line = key.authorizedKeysLine {
                        let copy = Button(copiedKey == key.name ? "Copied" : "Copy Public Key", systemImage: copiedKey == key.name ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = line
                            copiedKey = key.name
                            AccessibilityNotification.Announcement(String(localized: "Copied")).post()
                        }
                        // "Copied" is for the eye; the button keeps its name.
                        .accessibilityLabel("Copy Public Key")
                        let share = ShareLink("Share", item: line)
                        ViewThatFits(in: .horizontal) {
                            HStack { copy; share }
                            VStack(alignment: .leading) { copy; share }
                        }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                        .padding(.top, 2)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ssh-key-\(key.name)")
            }
            .onDelete { offsets in
                // By name: deleting one reloads the list, and an index would then point elsewhere.
                let names = offsets.map { keys[$0].name }
                for name in names { perform { try store.delete(named: name) } }
            }
            if !keys.isEmpty {
                Section {
                } footer: {
                    Text(Self.instructions)
                }
            }
        }
        .overlay {
            if keys.isEmpty {
                ContentUnavailableView {
                    Label("No SSH Keys", systemImage: "key")
                } description: {
                    Text(Self.instructions)
                } actions: {
                    Button("Generate a Key", action: generate)
                        .buttonStyle(.borderedProminent).tint(.prominentFill)
                }
            }
        }
        .navigationTitle("SSH Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add Key", systemImage: "plus") {
                    Button("Generate a Key", systemImage: "key", action: generate)
                    // The system paste control makes importing a private key an explicit act, with no
                    // "Allow Paste" prompt.
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        perform { _ = try store.importKey(named: store.availableName(basedOn: String(localized: "Imported Key")), text: text) }
                    }
                }
                .accessibilityIdentifier("add-ssh-key")
            }
        }
        .alert("SSH Key", item: $problem) { _ in
            Button("OK", role: .cancel) {}
        } message: { problem in
            Text(problem)
        }
        .onAppear(perform: reload)
    }

    private func generate() {
        perform { _ = try store.generateEd25519(named: store.availableName(basedOn: String(localized: "Marionette Key"))) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch let error as SSHKeyError {
            problem = error.message
        } catch {
            problem = String(localized: "The key couldn’t be saved.")
        }
        reload()
    }

    private func reload() {
        keys = (try? store.all()) ?? []
    }
}
