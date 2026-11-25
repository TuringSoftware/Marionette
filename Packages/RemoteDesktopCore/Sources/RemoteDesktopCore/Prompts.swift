// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

/// A question a back end needs answered before it can continue connecting.
public enum SessionPrompt: Sendable, Hashable {
    case credentials(CredentialRequest)
    case hostKey(HostKeyChallenge)
    case keyPassphrase(KeyPassphraseRequest)
    case keyboardInteractive(KeyboardInteractiveRequest)
    case sessionSelect(SessionSelectRequest)
}

/// Which service is asking, so the user knows whose password to type.
public enum PromptContext: Sendable, Hashable {
    case remoteDesktop(host: String)
    case sshTunnel(host: String)
    /// An SSH sign-in for moving files, apart from the remote desktop session.
    case fileAccess(host: String)

    public var isSSH: Bool {
        switch self {
        case .remoteDesktop: false
        case .sshTunnel, .fileAccess: true
        }
    }
}

public struct CredentialRequest: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case usernameAndPassword
        /// The server identifies the account some other way (classic VNC password).
        case passwordOnly
    }

    public var context: PromptContext
    public var kind: Kind
    public var suggestedUsername: String?
    /// 1 for the first request. Greater than 1 means the previous answer was rejected.
    public var attempt: Int
    /// Why the previous attempt failed, in the server's words when it gave any.
    public var previousFailure: String?

    public init(
        context: PromptContext,
        kind: Kind = .usernameAndPassword,
        suggestedUsername: String? = nil,
        attempt: Int = 1,
        previousFailure: String? = nil
    ) {
        self.context = context
        self.kind = kind
        self.suggestedUsername = suggestedUsername
        self.attempt = attempt
        self.previousFailure = previousFailure
    }
}

public struct HostKeyChallenge: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case unknown
        /// The host presented a different key than the one remembered. Possible interception.
        case changed(previousFingerprint: String)
    }

    public var host: String
    public var port: UInt16
    /// For example "ssh-ed25519".
    public var algorithm: String
    /// "SHA256:" followed by the unpadded base64 digest, as OpenSSH prints it.
    public var fingerprint: String
    public var status: Status

    public init(host: String, port: UInt16, algorithm: String, fingerprint: String, status: Status) {
        self.host = host
        self.port = port
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.status = status
    }
}

public struct KeyPassphraseRequest: Sendable, Hashable {
    public var keyName: String
    public var attempt: Int

    public init(keyName: String, attempt: Int = 1) {
        self.keyName = keyName
        self.attempt = attempt
    }
}

public struct KeyboardInteractiveRequest: Sendable, Hashable {
    public struct Question: Sendable, Hashable {
        public var text: String
        /// False for secrets, which must not be shown while typed.
        public var echoesInput: Bool

        public init(text: String, echoesInput: Bool) {
            self.text = text
            self.echoesInput = echoesInput
        }
    }

    public var context: PromptContext
    public var title: String
    public var instruction: String
    public var questions: [Question]

    public init(context: PromptContext, title: String, instruction: String, questions: [Question]) {
        self.context = context
        self.title = title
        self.instruction = instruction
        self.questions = questions
    }
}

/// Someone else is logged in at the remote machine's console.
public struct SessionSelectRequest: Sendable, Hashable {
    public var consoleUser: String
    public var choices: [SessionChoice]
    /// The person at the console turned down the last request to share their display. The choice
    /// stands again, on the same connection.
    public var previousRequestDeclined: Bool

    public init(consoleUser: String, choices: [SessionChoice] = SessionChoice.allCases, previousRequestDeclined: Bool = false) {
        self.consoleUser = consoleUser
        self.choices = choices
        self.previousRequestDeclined = previousRequestDeclined
    }
}

public enum SessionChoice: Sendable, Hashable, CaseIterable {
    /// Ask the console user for permission to see their screen.
    case askToShareConsole
    /// Log in as yourself in a separate, private session.
    case logInAsSelf
}

public enum PromptResponse: Sendable, Hashable {
    case credentials(username: String, password: String)
    /// Proceed with the presented host key. `remember` stores it for next time.
    case trustHostKey(remember: Bool)
    case passphrase(String)
    case answers([String])
    case sessionChoice(SessionChoice)
    /// The user declined. The connection attempt ends with ``ConnectionFailure/cancelled`` (or
    /// ``ConnectionFailure/hostKeyRejected(host:)`` for a host key).
    case cancel
}

/// Answers a back end's questions. Implemented above the back ends (MarionetteKit), where saved secrets and
/// the user interface live. Called at most one prompt at a time per connection attempt.
public protocol PromptHandler: Sendable {
    func resolve(_ prompt: SessionPrompt) async -> PromptResponse
}

/// A handler that answers from fixed values; for tools and tests.
public struct StaticPromptHandler: PromptHandler {
    public var username: String
    public var password: String
    public var trustsUnknownHosts: Bool
    public var sessionChoice: SessionChoice

    public init(
        username: String,
        password: String,
        trustsUnknownHosts: Bool = false,
        sessionChoice: SessionChoice = .askToShareConsole
    ) {
        self.username = username
        self.password = password
        self.trustsUnknownHosts = trustsUnknownHosts
        self.sessionChoice = sessionChoice
    }

    public func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        switch prompt {
        case .credentials(let request):
            // A fixed answer that was already rejected will be rejected again.
            request.attempt > 1 ? .cancel : .credentials(username: username, password: password)
        case .hostKey(let challenge):
            if case .unknown = challenge.status, trustsUnknownHosts { .trustHostKey(remember: false) } else { .cancel }
        case .keyPassphrase(let request):
            request.attempt > 1 ? .cancel : .passphrase(password)
        case .keyboardInteractive(let request):
            .answers(request.questions.map { _ in password })
        case .sessionSelect:
            .sessionChoice(sessionChoice)
        }
    }
}
