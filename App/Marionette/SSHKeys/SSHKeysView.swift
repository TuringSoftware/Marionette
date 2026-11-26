// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import MarionetteKit

/// The SSH keys this device can sign in with: make one, bring one in, hand out its public half. The
/// SSH servers it trusts are one level down.
struct SSHKeysView: View {
    let store: SSHKeyStore
    let hostKeys: any KnownHostsStore
    let owner: OwnerAuthentication

    @State private var keys: [SSHKeyInfo] = []
    @State private var form: SSHKeyFormModel?
    @State private var problem: String?
    @State private var copiedKey: String?
    @State private var ownerCheck = OwnerCheck.unavailable
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let instructions = String(localized: "To sign in with a key, add its public key to ~/.ssh/authorized_keys on the computer.")

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        KnownHostsView(store: hostKeys)
                    } label: {
                        Label("Known Hosts", systemImage: "checkmark.shield")
                    }
                }
                if keys.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No SSH Keys", systemImage: "key")
                        } actions: {
                            Button("New Key") { start(.new) }
                                .buttonStyle(.borderedProminent).tint(.prominentFill)
                        }
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(keys) { key in
                            row(key)
                        }
                        .onDelete { offsets in
                            // By name: deleting one reloads the list, and an index would then point elsewhere.
                            let names = offsets.map { keys[$0].name }
                            for name in names { perform { try store.delete(named: name) } }
                        }
                    } header: {
                        Text("Keys")
                    } footer: {
                        Text(Self.instructions)
                    }
                }
            }
            .navigationTitle("SSH Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Add Key", systemImage: "plus") {
                        Button("New Key", systemImage: "key") { start(.new) }
                        Button("Import Existing Key", systemImage: "square.and.arrow.down") { start(.importing) }
                    }
                    .accessibilityIdentifier("add-ssh-key")
                }
            }
            .sheet(item: $form, onDismiss: reload) { model in
                SSHKeyFormView(model: model)
            }
            .alert("SSH Key", item: $problem) { _ in
                Button("OK", role: .cancel) {}
            } message: { problem in
                Text(problem)
            }
            .onAppear {
                ownerCheck = owner.check()
                reload()
            }
        }
    }

    private func row(_ key: SSHKeyInfo) -> some View {
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
            if let summary = key.storage.summary(ownerCheck: ownerCheck) {
                Label(summary, systemImage: storageSymbol(key.storage))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

    private func storageSymbol(_ storage: SSHKeyStorage) -> String {
        if storage.isInSecureEnclave { return "cpu" }
        if storage.protection.synchronizes { return "icloud" }
        return storage.protection.includedInBackups ? "externaldrive" : "lock"
    }

    private func start(_ kind: SSHKeyFormModel.Kind) {
        form = SSHKeyFormModel(kind: kind, store: store, ownerCheck: owner.check())
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch let error as SSHKeyError {
            problem = error.message
        } catch {
            problem = String(localized: "The key couldn’t be changed.")
        }
        reload()
    }

    private func reload() {
        keys = (try? store.all()) ?? []
    }
}

/// Makes a new key, or brings in one the user pastes, with where it is kept.
struct SSHKeyFormView: View {
    @Bindable var model: SSHKeyFormModel
    @State private var showsStorage = false
    @State private var choosesFile = false
    @ScaledMetric(relativeTo: .caption2) private var keyBoxHeight = 160
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { model.kind == .new }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FieldRow("Name") {
                        TextField("Name", text: $model.name, prompt: Text(model.namePlaceholder))
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("ssh-key-name")
                    }
                }
                if isNew { kind } else { pasted }
                storage
            }
            .navigationTitle(isNew ? "New SSH Key" : "Import SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button(isNew ? "Create" : "Import") {
                            Task { if await model.save() != nil { dismiss() } }
                        }
                        .disabled(!model.canSave)
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.isSaving)
    }

    private var kind: some View {
        Section {
            Picker("Type", selection: typeBinding) {
                ForEach(SSHKeyType.allCases, id: \.self) { type in
                    Text(type.title).tag(type)
                }
            }
            .accessibilityIdentifier("ssh-key-type")
            if model.algorithm.type != .ed25519 {
                Picker("Strength", selection: bitsBinding) {
                    ForEach(model.algorithm.type.sizes, id: \.self) { bits in
                        Text(model.algorithm.sizeTitle(bits)).tag(bits)
                    }
                }
                .accessibilityIdentifier("ssh-key-strength")
            }
        } footer: {
            if let problem = model.problem {
                problemLabel(problem)
            } else if let caution = model.algorithm.caution {
                Label(caution, systemImage: "exclamationmark.triangle")
            }
        }
        .disabled(model.storage.isInSecureEnclave)
    }

    private var pasted: some View {
        Section {
            // A fixed height: a long key scrolls inside the box instead of lengthening the form.
            TextEditor(text: $model.text)
                .font(.caption2.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(height: keyBoxHeight)
                .accessibilityLabel("Private Key")
                .accessibilityIdentifier("ssh-key-text")
            Button("Choose File…", systemImage: "folder") { choosesFile = true }
                .accessibilityIdentifier("choose-ssh-key-file")
                // Key files rarely have an extension (id_ed25519), so any file may be chosen.
                .fileImporter(isPresented: $choosesFile, allowedContentTypes: [.item]) { result in
                    if case .success(let url) = result { model.loadFile(at: url) }
                }
        } header: {
            Text("Private Key")
        } footer: {
            if let problem = model.problem {
                problemLabel(problem)
            }
        }
    }

    private var storage: some View {
        Section {
            DisclosureGroup("Storage", isExpanded: $showsStorage) {
                if model.offersSecureEnclave {
                    Toggle("Store in Secure Enclave", isOn: $model.storage.isInSecureEnclave)
                        .accessibilityIdentifier("secure-enclave")
                }
                SecretProtectionToggles(protection: $model.storage.protection, ownerCheck: model.ownerCheck)
            }
        } footer: {
            if showsStorage, model.storage.isInSecureEnclave {
                Text("The key is stored in the Secure Enclave. It can’t be backed up, moved or restored in any way: if this device is lost, erased or replaced, the key is gone.")
            }
        }
    }

    private func problemLabel(_ problem: String) -> some View {
        Label(problem, systemImage: "exclamationmark.circle")
            .foregroundStyle(Color.errorText)
    }

    /// Shows ECDSA while the Secure Enclave forces it, without losing the user's choice.
    private var typeBinding: Binding<SSHKeyType> {
        Binding(get: { model.algorithm.type }, set: { model.type = $0 })
    }

    private var bitsBinding: Binding<Int> {
        Binding(get: { model.algorithm.bits }, set: { model.bits = $0 })
    }
}

/// Who may read a secret and where copies of it go. Turning one on can turn another off: the model
/// applies the Keychain's rules.
struct SecretProtectionToggles: View {
    @Binding var protection: SecretProtection
    let ownerCheck: OwnerCheck
    /// Whether there is anything to protect; without it, every toggle is disabled and off.
    var applies = true
    /// Passwords stay out of iCloud Keychain: the computers they are for are on this device only.
    var offersICloudKeychain = true

    var body: some View {
        let canRequireOwner = applies && ownerCheck != .unavailable
        Toggle(ownerCheck.requirementTitle, isOn: option(\.requiresUserPresence, applies: canRequireOwner))
            .disabled(!canRequireOwner)
            .accessibilityIdentifier("require-owner")
        Toggle("Include in Encrypted Backups", isOn: option(\.includedInBackups, applies: applies))
            .disabled(!applies)
            .accessibilityIdentifier("include-in-backups")
        if offersICloudKeychain {
            Toggle("Include in iCloud Keychain", isOn: option(\.synchronizes, applies: applies))
                .disabled(!applies)
                .accessibilityIdentifier("include-in-icloud")
        }
    }

    /// An option that reads off while it does not apply, keeping the choice for when it does.
    private func option(_ keyPath: WritableKeyPath<SecretProtection, Bool>, applies: Bool) -> Binding<Bool> {
        Binding(get: { applies && protection[keyPath: keyPath] }, set: { protection[keyPath: keyPath] = $0 })
    }
}
