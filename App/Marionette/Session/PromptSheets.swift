// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import SwiftUI
import MarionetteKit

/// The sheet for whatever question the back end is asking.
struct PromptSheet: View {
    let pending: PromptBroker.Pending
    let broker: PromptBroker
    let computerName: String

    var body: some View {
        NavigationStack {
            Group {
                switch pending.prompt {
                case .credentials(let request):
                    CredentialForm(request: request, broker: broker, computerName: computerName, isFromFallbackRung: pending.isFromFallbackRung)
                case .hostKey(let challenge):
                    HostKeyForm(challenge: challenge, broker: broker)
                case .sessionSelect(let request):
                    SessionSelectForm(request: request, broker: broker)
                case .keyPassphrase(let request):
                    AnswersForm(
                        title: String(localized: "Key Passphrase"),
                        instruction: String(localized: "Enter the passphrase for the key “\(request.keyName)”."),
                        failure: request.attempt > 1 ? String(localized: "That passphrase didn’t unlock the key.") : nil,
                        questions: [.init(text: String(localized: "Passphrase"), echoesInput: false)]
                    ) { broker.reply(.passphrase($0[0]), remember: false) }
                case .keyboardInteractive(let request):
                    AnswersForm(title: request.title.isEmpty ? String(localized: "Sign In") : request.title, instruction: request.instruction, failure: nil, questions: request.questions) {
                        broker.reply(.answers($0))
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isChangedHostKey {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { broker.cancelPending() }
                    }
                }
            }
        }
        // Swiping the sheet away would leave the back end waiting; make the choice explicit.
        .interactiveDismissDisabled()
        .presentationDetents(isChangedHostKey ? [.large] : [.medium, .large])
    }

    private var isChangedHostKey: Bool {
        if case .hostKey(let challenge) = pending.prompt, case .changed = challenge.status { true } else { false }
    }
}

private struct CredentialForm: View {
    let request: CredentialRequest
    let broker: PromptBroker
    let computerName: String
    /// Asked for by a weaker fallback connection after the computer's own failed: the password is
    /// used for this connection only and never kept, so nothing is offered to remember.
    var isFromFallbackRung = false
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    private var needsUsername: Bool { request.kind == .usernameAndPassword }
    /// Connected straight from the network: keeping the password means keeping the computer.
    private var offersToSaveComputer: Bool {
        if case .remoteDesktop = request.context { !broker.isComputerSaved } else { false }
    }
    private var canSubmit: Bool { !password.isEmpty && (!needsUsername || !username.isEmpty) }

    /// A whole sentence for each service: a sentence put together from parts cannot be translated.
    private var heading: LocalizedStringKey {
        switch request.context {
        case .remoteDesktop: "Sign in to “\(computerName)”"
        case .sshTunnel(let host): "Sign in to the SSH server “\(host)”"
        case .fileAccess(let host): "Sign in to files on “\(host)” over SSH"
        }
    }

    var body: some View {
        Form {
            Section {
                if needsUsername {
                    TextField("User Name", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("prompt-username")
                }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .accessibilityIdentifier("prompt-password")
            } header: {
                Text(heading)
            } footer: {
                if request.attempt > 1 {
                    Label(request.previousFailure ?? String(localized: "The user name or password is incorrect."), systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.errorText)
                        .accessibilityIdentifier("prompt-error")
                }
            }
            if isFromFallbackRung {
                Section {
                } footer: {
                    Text("Screen Sharing failed. This password is for a VNC connection and isn’t saved.")
                }
            } else {
                Section {
                    if offersToSaveComputer {
                        Toggle("Save This Computer", isOn: $remember)
                            .accessibilityIdentifier("prompt-save-computer")
                    } else {
                        Toggle("Remember Password", isOn: $remember)
                    }
                }
            }
        }
        .navigationTitle("Sign In")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect", action: submit)
                    .disabled(!canSubmit)
            }
        }
        .onChange(of: request.attempt, initial: true) { _, attempt in
            if attempt > 1 {
                AccessibilityNotification.Announcement(request.previousFailure ?? String(localized: "The user name or password is incorrect.")).post()
            }
        }
        .onAppear {
            username = broker.suggestedUsername(for: request)
            focus = needsUsername && username.isEmpty ? .username : .password
        }
    }

    private func submit() {
        guard canSubmit else { return }
        broker.reply(.credentials(username: username, password: password), remember: remember && !isFromFallbackRung)
    }
}

private struct HostKeyForm: View {
    let challenge: HostKeyChallenge
    let broker: PromptBroker
    @State private var remember = true

    private var previousFingerprint: String? {
        if case .changed(let previous) = challenge.status { previous } else { nil }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(previousFingerprint == nil ? "First Connection to This Server" : "This Server’s Identity Has Changed")
                            .font(.headline)
                    } icon: {
                        Image(systemName: previousFingerprint == nil ? "key.viewfinder" : "exclamationmark.shield.fill")
                            .foregroundStyle(previousFingerprint == nil ? Color.accentColor : .red)
                    }
                    .accessibilityAddTraits(.isHeader)
                    Text(explanation)
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }
            if previousFingerprint != nil {
                // The choice comes straight after the warning so that stopping never needs a scroll.
                Section {
                    // Stopping is the safe choice, so it is the prominent one.
                    Button { broker.cancelPending() } label: {
                        Text("Cancel Connection").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.prominentFill)
                    .controlSize(.large)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .keyboardShortcut(.defaultAction)
                }
                Section {
                    Button("Connect Anyway", role: .destructive) { broker.reply(.trustHostKey(remember: true)) }
                        .frame(maxWidth: .infinity)
                }
            }
            Section("Server") {
                LabeledContent("Address", value: challenge.port == 22 ? challenge.host : "\(challenge.host):\(challenge.port)")
                LabeledContent("Key Type", value: challenge.algorithm)
            }
            Section(previousFingerprint == nil ? "Fingerprint" : "New Fingerprint") {
                fingerprint(challenge.fingerprint)
            }
            if let previousFingerprint {
                Section("Fingerprint You Trusted Before") {
                    fingerprint(previousFingerprint)
                }
            } else {
                Section {
                    Toggle("Remember This Server", isOn: $remember)
                }
            }
        }
        .navigationTitle(previousFingerprint == nil ? "Verify Server" : "Warning")
        .toolbar {
            if previousFingerprint == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust") { broker.reply(.trustHostKey(remember: remember)) }
                }
            }
        }
    }

    private var explanation: String {
        previousFingerprint == nil
            ? String(localized: "Check that the fingerprint matches the one shown on the computer.")
            : String(localized: "Someone could be intercepting the connection. Don’t continue unless you know why the key changed.")
    }

    private func fingerprint(_ text: String) -> some View {
        Text(text)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .accessibilityLabel("Fingerprint")
            // Checked character by character, so it is spoken that way.
            .accessibilityValue(Text(text).speechSpellsOutCharacters())
    }
}

private struct SessionSelectForm: View {
    let request: SessionSelectRequest
    let broker: PromptBroker

    var body: some View {
        Form {
            Section {
                ForEach(request.choices, id: \.self) { choice in
                    Button { broker.reply(.sessionChoice(choice)) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.title).font(.body.weight(.medium))
                            // A concrete colour: inside a button, hierarchical styles follow the tint.
                            Text(choice.explanation(consoleUser: request.consoleUser))
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } header: {
                Text("\(request.consoleUser) is using this computer")
            } footer: {
                if request.previousRequestDeclined {
                    Label("\(request.consoleUser) declined your request to share the display.", systemImage: "hand.raised.fill")
                        .foregroundStyle(Color.errorText)
                }
            }
        }
        .navigationTitle("Choose How to Connect")
    }
}

/// One or more free-form questions (keyboard-interactive sign-in, key passphrase).
private struct AnswersForm: View {
    let title: String
    let instruction: String
    let failure: String?
    let questions: [KeyboardInteractiveRequest.Question]
    var onSubmit: ([String]) -> Void
    @State private var answers: [String] = []

    var body: some View {
        Form {
            Section {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    let binding = Binding(get: { answers.indices.contains(index) ? answers[index] : "" }, set: { if answers.indices.contains(index) { answers[index] = $0 } })
                    if question.echoesInput {
                        TextField(question.text, text: binding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField(question.text, text: binding)
                    }
                }
            } header: {
                // The server's name for the exchange can be any length, so it goes here rather than
                // in the bar, which truncates.
                VStack(alignment: .leading, spacing: 4) {
                    if !title.isEmpty {
                        Text(title).font(.headline).foregroundStyle(.primary).textCase(nil)
                    }
                    if !instruction.isEmpty { Text(instruction).textCase(nil) }
                }
            } footer: {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.circle.fill").foregroundStyle(Color.errorText)
                }
            }
        }
        .onChange(of: failure, initial: true) { _, failure in
            if let failure { AccessibilityNotification.Announcement(failure).post() }
        }
        .navigationTitle("Sign In")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue") { onSubmit(answers) }
                    .disabled(answers.contains(where: \.isEmpty))
            }
        }
        .onAppear { answers = Array(repeating: "", count: questions.count) }
    }
}
