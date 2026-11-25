// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MarionetteKit

/// Add or edit a computer. Address, name and sign-in come first; everything else is tucked into
/// sections that open on demand, because most people never need them.
struct ComputerEditorView: View {
    @Bindable var model: ComputerEditorModel
    /// The SSH keys a tunnel can sign in with.
    let sshKeys: SSHKeyStore
    /// Called with the saved configuration, or `nil` when the user cancelled.
    var onFinish: (ComputerConfiguration?) -> Void
    var onDelete: () -> Void

    @State private var showsConnection = false
    @State private var showsTunnel = false
    @State private var showsDisplay = false
    @State private var showsAudio = false
    @State private var confirmsDiscard = false
    @State private var confirmsDelete = false
    @State private var keyNames: [String] = []
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case address
    }

    var body: some View {
        NavigationStack {
            Form {
                basics
                signIn
                connection
                tunnel
                display
                audio
                if !model.isNew {
                    Section {
                        Button("Delete Computer", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        if model.hasChanges { confirmsDiscard = true } else { onFinish(nil) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isNew ? "Add" : "Save") { onFinish(model.save()) }
                        .disabled(!model.canSave)
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { onFinish(nil) }
                Button("Keep Editing", role: .cancel) {}
            }
            .confirmationDialog("Delete this computer?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Computer", role: .destructive) { onDelete() }
            }
        }
        .interactiveDismissDisabled(model.hasChanges)
        .onAppear {
            reloadKeys()
            showsTunnel = model.isTunnelEnabled
            if model.isNew && model.address.isEmpty { focus = .address }
        }
    }

    // MARK: Sections

    private var basics: some View {
        Section {
            FieldRow("Address") {
                TextField("Address", text: $model.address, prompt: Text("Host name or IP Address"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .address)
                    .onSubmit { model.commitAddress() }
                    .accessibilityIdentifier("address")
            }
            FieldRow("Name") {
                TextField("Name", text: $model.configuration.name, prompt: Text(model.namePlaceholder))
                    .accessibilityIdentifier("name")
            }
        } footer: {
            if let problem = model.addressProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .foregroundStyle(Color.errorText)
            }
        }
    }

    private var signIn: some View {
        Section {
            FieldRow("User Name") {
                TextField("User Name", text: $model.configuration.username, prompt: Text("Ask Every Time"))
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("username")
            }
            FieldRow("Password") {
                SecureField("Password", text: $model.password, prompt: Text("Ask Every Time"))
                    .textContentType(.password)
                    .accessibilityIdentifier("password")
            }
        } header: {
            Text("Sign In")
        }
    }

    private var connection: some View {
        Section {
            DisclosureGroup("Connection", isExpanded: $showsConnection) {
                // The protocol is detected on connecting, as Screen Sharing does. Modes are a Mac's:
                // a computer found to be another VNC server has none.
                if !model.configuration.isKnownVNCServer {
                    Picker("Mode", selection: modeBinding) {
                        ForEach(ComputerConfiguration.Mode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .disabled(model.isTunnelEnabled)
                }
                FieldRow("Port") {
                    TextField("Port", text: $model.portText, prompt: Text("5900"))
                        .keyboardType(.numberPad)
                        .foregroundStyle(model.isPortValid ? .primary : Color.errorText)
                        // Not by colour alone.
                        .accessibilityValue(model.isPortValid ? model.portText : String(localized: "\(model.portText), Invalid"))
                }
                Toggle("View Only", isOn: $model.configuration.observeOnly)
            }
        }
    }

    private var tunnel: some View {
        Section {
            DisclosureGroup("SSH Tunnel", isExpanded: $showsTunnel) {
                Toggle("Use SSH Tunnel", isOn: $model.configuration.tunnel.isEnabled)
                    .accessibilityIdentifier("use-ssh-tunnel")
                if model.isTunnelEnabled {
                    FieldRow("Server") {
                        TextField("SSH Server", text: $model.configuration.tunnel.host, prompt: Text("Same as Address"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    FieldRow("Port") {
                        TextField("SSH Port", text: $model.tunnelPortText, prompt: Text("22"))
                            .keyboardType(.numberPad)
                            .foregroundStyle(model.isTunnelPortValid ? .primary : Color.errorText)
                            .accessibilityValue(model.isTunnelPortValid ? model.tunnelPortText : String(localized: "\(model.tunnelPortText), Invalid"))
                    }
                    FieldRow("User Name") {
                        TextField("SSH User Name", text: $model.configuration.tunnel.username, prompt: Text("Same as Sign In"))
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    FieldRow("Password") {
                        SecureField("SSH Password", text: $model.tunnelPassword, prompt: Text("Ask Every Time"))
                    }
                    Picker("SSH Key", selection: $model.configuration.tunnel.keyName) {
                        Text("None").tag(String?.none)
                        ForEach(keyNames, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    NavigationLink("Manage SSH Keys") {
                        SSHKeysView(store: sshKeys)
                            .onDisappear(perform: reloadKeys)
                    }
                }
            }
        } footer: {
            if showsTunnel, model.isTunnelEnabled {
                Text("Screen sharing travels inside an encrypted SSH connection. High Performance mode and audio are turned off.")
            }
        }
    }

    private var display: some View {
        Section {
            DisclosureGroup("Display", isExpanded: $showsDisplay) {
                Picker("Show", selection: displayBinding) {
                    Text("Computer’s Displays").tag(ComputerConfiguration.Display.remoteDisplays)
                    Text("Fit This Device").tag(ComputerConfiguration.Display.fitToDevice)
                }
                .disabled(!model.configuration.allowsFittedDisplay)
                if displayBinding.wrappedValue == .fitToDevice {
                    Toggle("Retina", isOn: $model.configuration.prefersRetina)
                        .accessibilityIdentifier("retina-display")
                    Toggle("Secondary Display", isOn: $model.configuration.hasSecondaryDisplay)
                        .accessibilityIdentifier("secondary-display")
                }
                Picker("Quality", selection: $model.configuration.quality) {
                    Text("Adaptive").tag(ComputerConfiguration.Quality.adaptive)
                    Text("Full").tag(ComputerConfiguration.Quality.full)
                }
            }
        } footer: {
            if showsDisplay { Text("Fit This Device makes a display the size of this screen in High Performance mode.") }
        }
    }

    private var audio: some View {
        Section {
            DisclosureGroup("Audio and Clipboard", isExpanded: $showsAudio) {
                Toggle("Play Sound", isOn: audioBinding)
                    .disabled(!model.configuration.allowsAudio)
                Toggle("Share Clipboard", isOn: $model.configuration.clipboardEnabled)
            }
        } footer: {
            if showsAudio { Text("Plays the computer’s sound on this device in High Performance mode.") }
        }
    }

    private func reloadKeys() {
        var names = ((try? sshKeys.all()) ?? []).map(\.name)
        // A key that was deleted stays selectable so the setting is not silently changed.
        if let chosen = model.configuration.tunnel.keyName, !names.contains(chosen) { names.append(chosen) }
        keyNames = names
    }

    /// Shows Standard while the tunnel forces it, without overwriting the user's own choice.
    private var modeBinding: Binding<ComputerConfiguration.Mode> {
        Binding(get: { model.effectiveMode }, set: { model.configuration.mode = $0 })
    }

    /// Shows the computer's own displays while there can be no fitted one, keeping the user's choice.
    private var displayBinding: Binding<ComputerConfiguration.Display> {
        Binding(
            get: { model.configuration.allowsFittedDisplay ? model.configuration.display : .remoteDisplays },
            set: { model.configuration.display = $0 }
        )
    }

    /// Off while there can be no sound, and back to the user's choice when there can.
    private var audioBinding: Binding<Bool> {
        Binding(get: { model.configuration.audioEnabled && model.configuration.allowsAudio }, set: { model.configuration.audioEnabled = $0 })
    }
}

/// A form row of a title and a field: side by side, field trailing; at accessibility text sizes the
/// field goes under its title, with the row's full width.
private struct FieldRow<Field: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var field: Field
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: LocalizedStringKey, @ViewBuilder field: () -> Field) {
        self.title = title
        self.field = field()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                field.multilineTextAlignment(.leading)
            }
        } else {
            LabeledContent(title) { field.multilineTextAlignment(.trailing) }
        }
    }
}
