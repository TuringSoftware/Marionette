// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
public import RemoteDesktopCore

/// A stand-in for the network. The simulated back end never opens it, but reads its properties to
/// decide which modes are possible, exactly as a real back end would.
public struct SimulatedTransport: TransportProvider {
    public var peer: Endpoint
    public var isTunnelled: Bool
    public var supportsDatagrams: Bool

    public init(peer: Endpoint = Endpoint(host: "demo.local", port: 5900), isTunnelled: Bool = false) {
        self.peer = peer
        self.isTunnelled = isTunnelled
        supportsDatagrams = !isTunnelled
    }

    public func openStream(port: UInt16) async throws -> any ByteStream {
        throw TransportError.unsupported(detail: String(localized: "simulated transport carries no data", bundle: #bundle))
    }

    public func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel {
        throw TransportError.unsupported(detail: String(localized: "simulated transport carries no data", bundle: #bundle))
    }
}

/// A back end that talks to nothing. It walks through the same phases, prompts, failures and
/// capabilities as the real ones, driven by a ``SimulationScenario``.
public struct SimulatedBackend: RemoteDesktopBackend {
    public static let backendID = "simulated"

    public var scenario: SimulationScenario

    public init(scenario: SimulationScenario = .highPerformance) {
        self.scenario = scenario
    }

    public var descriptor: BackendDescriptor {
        BackendDescriptor(
            id: Self.backendID,
            displayName: String(localized: "Demo", bundle: #bundle),
            defaultPort: 5900,
            bonjourServiceType: nil,
            supportedModes: scenario.offeredModes
        )
    }

    public func connect(_ request: ConnectionRequest) async throws(ConnectionFailure) -> any RemoteSession {
        try await connectSimulated(request)
    }

    /// Same as ``connect(_:)`` with the concrete session type, for tests that drive the simulation.
    public func connectSimulated(_ request: ConnectionRequest) async throws(ConnectionFailure) -> SimulatedSession {
        let transport = request.transport

        if transport.isTunnelled {
            try await enter(.openingTunnel, request)
            try await askTunnelPrompts(request)
        }
        try await enter(.reachingHost, request)
        try await enter(.negotiating, request)
        if request.options.requiresServerAuthentication, !scenario.provesServerIdentity {
            throw .unsupportedServer(detail: String(localized: "The server offers no login that proves its identity.", bundle: #bundle))
        }
        if request.options.requiresEncryption, !scenario.encryptsSession {
            throw .notEncrypted(detail: String(localized: "The server would not encrypt the session.", bundle: #bundle))
        }

        let mode = try resolveMode(request.options.mode, transport: transport)

        try await enter(.authenticating, request)
        let username = try await authenticate(request)

        if let consoleUser = scenario.consoleUser, consoleUser != username {
            var declines = scenario.consoleDeclines
            choosing: while true {
                let prompt = SessionSelectRequest(consoleUser: consoleUser, previousRequestDeclined: declines < scenario.consoleDeclines)
                switch await request.prompts.resolve(.sessionSelect(prompt)) {
                case .sessionChoice(.askToShareConsole):
                    try await enter(.waitingForRemoteUser, request)
                    do { try await Task.sleep(for: scenario.consoleAnswerDelay) } catch { throw .cancelled }
                    guard declines > 0 else { break choosing }
                    declines -= 1
                case .sessionChoice(.logInAsSelf):
                    break choosing
                default:
                    throw .cancelled
                }
            }
        }

        try await enter(.preparingDisplays, request)
        if mode == .highPerformance {
            try await enter(.startingMedia, request)
        }

        let session = SimulatedSession(scenario: scenario, mode: mode, options: request.options, isTunnelled: transport.isTunnelled)
        await session.start()
        if Task.isCancelled {
            await session.disconnect()
            throw .cancelled
        }
        return session
    }

    private func askTunnelPrompts(_ request: ConnectionRequest) async throws(ConnectionFailure) {
        for prompt in scenario.tunnelPrompts {
            let response = await request.prompts.resolve(prompt)
            switch (prompt, response) {
            case (.hostKey, .trustHostKey), (.keyPassphrase, .passphrase), (.keyboardInteractive, .answers),
                 (.credentials, .credentials):
                continue
            case (.hostKey(let challenge), _):
                throw .hostKeyRejected(host: challenge.host)
            default:
                throw .cancelled
            }
        }
    }

    private func enter(_ phase: ConnectionPhase, _ request: ConnectionRequest) async throws(ConnectionFailure) {
        request.progress(phase)
        if let failure = scenario.failure, failure.phase == phase {
            throw failure.error
        }
        do {
            try await Task.sleep(for: scenario.phaseDelay)
        } catch {
            throw .cancelled
        }
    }

    private func resolveMode(
        _ preference: SessionOptions.ModePreference,
        transport: any TransportProvider
    ) throws(ConnectionFailure) -> SessionMode {
        func unavailableReason(_ mode: SessionMode) -> UnavailableReason? {
            guard scenario.offeredModes.contains(mode) else { return .notSupportedByServer }
            if mode == .highPerformance, transport.isTunnelled || !transport.supportsDatagrams { return .tunnelled }
            return nil
        }
        switch preference {
        case .automatic:
            guard let mode = scenario.offeredModes.first(where: { unavailableReason($0) == nil }) else {
                throw .unsupportedServer(detail: String(localized: "The server offers no mode usable on this connection.", bundle: #bundle))
            }
            return mode
        case .require(let mode):
            if let reason = unavailableReason(mode) {
                throw .modeUnavailable(mode: mode, reason: reason)
            }
            return mode
        }
    }

    /// Returns the authenticated user name.
    private func authenticate(_ request: ConnectionRequest) async throws(ConnectionFailure) -> String {
        guard let account = scenario.account else { return "guest" }
        let context = PromptContext.remoteDesktop(host: request.transport.peer.host)
        var previousFailure: String?
        for attempt in 1...3 {
            let prompt = SessionPrompt.credentials(
                CredentialRequest(context: context, attempt: attempt, previousFailure: previousFailure)
            )
            guard case .credentials(let username, let password) = await request.prompts.resolve(prompt) else {
                throw .cancelled
            }
            if username == account.username, password == account.password {
                return username
            }
            previousFailure = String(localized: "The user name or password is incorrect.", bundle: #bundle)
        }
        throw .authenticationFailed(detail: previousFailure)
    }
}
