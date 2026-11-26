// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
public import RemoteDesktopCore
import RemoteDesktopSimulated
import RemoteDesktopTransport

/// The back ends this build can connect with, by identifier.
public struct BackendRegistry: Sendable {
    private var backends: [String: any RemoteDesktopBackend] = [:]
    private var order: [String] = []
    /// Used for computers whose own back end is not registered. Only the simulated environment
    /// sets it.
    public var fallbackBackendID: String?

    public init() {}

    public mutating func register(_ backend: any RemoteDesktopBackend) {
        let id = backend.descriptor.id
        if backends[id] == nil { order.append(id) }
        backends[id] = backend
    }

    public func backend(id: String) -> (any RemoteDesktopBackend)? {
        backends[id]
    }

    /// The back end to use for a saved identifier, honouring the fallback.
    public func resolve(id: String) -> (any RemoteDesktopBackend)? {
        backends[id] ?? fallbackBackendID.flatMap { backends[$0] }
    }

    public var descriptors: [BackendDescriptor] {
        order.compactMap { backends[$0]?.descriptor }
    }
}

/// A network path to a computer, and the SSH connection it runs through if it has one.
public struct PreparedTransport: Sendable {
    public var provider: any TransportProvider
    /// The tunnel's SSH connection. The session uses it for file transfer and closes it at its end.
    public var ssh: (any SSHSessionHandle)?

    public init(provider: any TransportProvider, ssh: (any SSHSessionHandle)? = nil) {
        self.provider = provider
        self.ssh = ssh
    }
}

/// Builds the network path to a computer: direct, or through the SSH tunnel its settings ask for.
/// Opening a tunnel can ask questions (host key, SSH password), hence the prompt handler.
public protocol TransportFactory: Sendable {
    func makeTransport(
        for computer: ComputerConfiguration,
        prompts: any PromptHandler
    ) async throws(ConnectionFailure) -> PreparedTransport

    /// What SSH connections outside the tunnel (signing in for file access) are made with. `nil`
    /// where there is no SSH.
    var ssh: SSHServices? { get }
}

extension TransportFactory {
    public var ssh: SSHServices? { nil }
}

/// Hands out ``SimulatedTransport``s that only record whether the path is tunnelled. There is no
/// SSH connection behind a simulated tunnel; the simulated back end plays the tunnel's prompts.
public struct SimulatedTransportFactory: TransportFactory {
    /// Set to let a simulated environment exercise "Sign In over SSH" (with a ``ScriptedSSHConnector``).
    public var ssh: SSHServices?

    public init(ssh: SSHServices? = nil) {
        self.ssh = ssh
    }

    public func makeTransport(
        for computer: ComputerConfiguration,
        prompts: any PromptHandler
    ) async throws(ConnectionFailure) -> PreparedTransport {
        PreparedTransport(provider: SimulatedTransport(peer: computer.endpoint, isTunnelled: computer.tunnel.isEnabled))
    }
}

/// The real paths: straight to the computer over TCP and UDP, or through an SSH tunnel when the
/// computer's settings ask for one. The demo computer, which talks to the simulated back end, gets
/// a stand-in.
public struct LiveTransportFactory: TransportFactory {
    private let services: SSHServices

    public var ssh: SSHServices? { services }

    /// `ssh` defaults to real connections with host keys and SSH keys that are not persisted; the
    /// app passes its stores.
    public init(ssh: SSHServices = SSHServices(hostKeys: InMemoryKnownHostsStore(), keys: SSHKeyStore(secrets: InMemorySecretStore()))) {
        services = ssh
    }

    public func makeTransport(
        for computer: ComputerConfiguration,
        prompts: any PromptHandler
    ) async throws(ConnectionFailure) -> PreparedTransport {
        if computer.isDemo || computer.backendID == BackendID.simulated {
            return PreparedTransport(provider: SimulatedTransport(peer: computer.endpoint, isTunnelled: computer.tunnel.isEnabled))
        }
        guard computer.tunnel.isEnabled else {
            return PreparedTransport(provider: DirectTransportProvider(peer: computer.endpoint))
        }
        let target = computer.tunnelTarget
        let handle: any SSHSessionHandle
        do {
            let access = (prompts as? any SecretAccessHolder)?.secretAccess ?? .denied
            handle = try await services.open(target, prompts: prompts, access: access)
        } catch {
            throw error.tunnelFailure(server: target.server)
        }
        // From an SSH server that is the computer itself, the computer is "localhost": that works
        // whatever name the user typed, and when Screen Sharing only listens for local connections.
        let hostFromServer = computer.tunnelServerIsComputer ? "localhost" : computer.host
        return PreparedTransport(provider: handle.makeTunnel(to: computer.endpoint, hostFromServer: hostFromServer), ssh: handle)
    }
}

/// Tries the ways of reaching a computer from best to most compatible:
/// Apple High Performance → Apple Standard → plain VNC.
///
/// Which protocol a computer speaks is not asked of the user: it is found out, as Screen Sharing
/// does. The server's first words name it (a Mac says RFB 003.889), so a computer that is not a Mac
/// is told apart on the first rung, before anything is sent or asked, and goes straight to VNC.
///
/// Each rung is a complete, separate connection attempt; a back end never changes mode on its own.
/// The ladder only steps down when the failure says another mode or protocol could work — never after
/// a cancellation, a wrong password or an unreachable host.
public struct ConnectionLadder: Sendable {
    public struct Step: Sendable, Hashable {
        public var backendID: String
        public var mode: SessionMode
        /// Tried only once an earlier rung found the computer speaks another protocol: VNC for a
        /// computer set to High Performance, which a Mac that refuses it must not fall back to.
        public var onlyForOtherProtocol: Bool

        public init(backendID: String, mode: SessionMode, onlyForOtherProtocol: Bool = false) {
            self.backendID = backendID
            self.mode = mode
            self.onlyForOtherProtocol = onlyForOtherProtocol
        }
    }

    /// A rung that was tried and abandoned.
    public struct Fallback: Sendable, Hashable {
        public var step: Step
        public var failure: ConnectionFailure
    }

    public struct Outcome: Sendable {
        public var session: any RemoteSession
        public var step: Step
        public var fallbacks: [Fallback]
        /// The SSH connection of the tunnel the session runs through, if it has one. Whoever holds
        /// the outcome closes it once the session has ended; ``close()`` does both.
        public var ssh: (any SSHSessionHandle)?

        /// Disconnects the session, then closes the tunnel under it.
        public func close() async {
            await session.disconnect()
            await ssh?.close()
        }
    }

    public var registry: BackendRegistry
    public var transports: any TransportFactory

    public init(registry: BackendRegistry, transports: any TransportFactory) {
        self.registry = registry
        self.transports = transports
    }

    /// What signing in for file access uses; `nil` where there is no SSH (simulation).
    public var ssh: SSHServices? { transports.ssh }

    /// The rungs for a computer, in the order they are tried.
    public func steps(for computer: ComputerConfiguration) -> [Step] {
        // A computer last found to be a VNC server is asked again whether it is a Mac now: the
        // first words of a connection say so, at the cost of one connection that sends nothing.
        let primaryID = computer.speaksDetectedProtocol && registry.backend(id: BackendID.appleScreenSharing) != nil
            ? BackendID.appleScreenSharing : computer.backendID
        guard let primary = registry.resolve(id: primaryID) else { return [] }
        let descriptor = primary.descriptor
        var steps: [Step] = []
        let wanted: [SessionMode] = switch computer.effectiveMode {
        case .automatic: [.highPerformance, .standard]
        case .highPerformance: [.highPerformance]
        case .standard: [.standard]
        }
        for mode in wanted where descriptor.supportedModes.contains(mode) {
            steps.append(Step(backendID: descriptor.id, mode: mode))
        }
        if steps.isEmpty, computer.effectiveMode != .automatic, let mode = wanted.first {
            // Asked for a mode the back end does not list: still try, so the user gets its own error.
            steps.append(Step(backendID: descriptor.id, mode: mode))
        }
        if computer.speaksDetectedProtocol, descriptor.id != BackendID.vnc, registry.backend(id: BackendID.vnc) != nil {
            steps.append(Step(backendID: BackendID.vnc, mode: .standard, onlyForOtherProtocol: computer.effectiveMode == .highPerformance))
        }
        return steps
    }

    /// Whether a failure on one rung justifies trying the next.
    public static func shouldFallBack(after failure: ConnectionFailure, from step: Step, to next: Step) -> Bool {
        switch failure {
        case .modeUnavailable, .busy:
            next.mode != step.mode || next.backendID != step.backendID
        case .unsupportedServer:
            true
        case .otherProtocol:
            // Another mode of the same protocol cannot help.
            next.backendID != step.backendID
        case .protocolViolation:
            next.backendID != step.backendID
        case .unreachable, .timedOut, .authenticationFailed, .permissionDenied, .hostKeyRejected,
             .localNetworkDenied, .tunnelFailed, .cancelled:
            false
        case .serverNotAuthenticated, .identityUnverifiable:
            // Whatever answered could not prove it knows the password. Any other rung would hand
            // that password to it, so the attempt stops here.
            false
        case .notEncrypted:
            // The encryption may have been stripped on the way; a rung without it is exactly what
            // that would be after.
            false
        }
    }

    /// Connects on the first rung that works.
    ///
    /// With `options.requiresServerAuthentication` (a computer that has proved its identity
    /// before), only the computer's own back end is tried, and it must prove the computer's
    /// identity again; a server that cannot ends the attempt with
    /// ``ConnectionFailure/identityUnverifiable(detail:)`` before anything is sent to it.
    /// `isFirstContact`: the computer has never been connected to, so nothing has shown it to be a
    /// Mac. If its first words then say it is not one, it is a VNC server, and the VNC rung is its
    /// own protocol rather than a fallback: it gets the saved credentials.
    public func connect(
        to computer: ComputerConfiguration,
        options: SessionOptions,
        isFirstContact: Bool = false,
        prompts: any PromptHandler,
        progress: @escaping @Sendable (ConnectionPhase) -> Void
    ) async throws(ConnectionFailure) -> Outcome {
        let ownBackendID = registry.resolve(id: computer.backendID)?.descriptor.id
        var steps = steps(for: computer)
        if options.requiresServerAuthentication || options.requiresEncryption {
            // Another back end is plain VNC, which neither proves the server nor encrypts.
            steps.removeAll { $0.backendID != ownBackendID }
        }
        guard !steps.isEmpty else {
            throw .unsupportedServer(detail: String(localized: "This version of Marionette can’t connect to this kind of computer.", bundle: #bundle))
        }
        if computer.tunnel.isEnabled { progress(.openingTunnel) }
        let transport = try await transports.makeTransport(for: computer, prompts: prompts)
        var fallbacks: [Fallback] = []
        // Back ends that found the computer speaks another protocol: their other rungs are skipped.
        var otherProtocolBackends: Set<String> = []
        func remains(_ step: Step) -> Bool {
            !otherProtocolBackends.contains(step.backendID) && (!step.onlyForOtherProtocol || !otherProtocolBackends.isEmpty)
        }
        for (index, step) in steps.enumerated() where remains(step) {
            guard let backend = registry.resolve(id: step.backendID) else { continue }
            var stepOptions = options
            stepOptions.mode = .require(step.mode)
            if step.mode != .highPerformance {
                stepOptions.wantsAudio = false
                if case .virtual = stepOptions.displays { stepOptions.displays = .physical(.all) }
            }
            // Another back end is another protocol, with logins that prove nothing and usually no
            // encryption: the computer's saved password must never be its answer. Unless the
            // computer has just said, on first contact, that it is not a Mac: then VNC is its own.
            let isOwn = step.backendID == ownBackendID
                || (step.backendID == BackendID.vnc && isFirstContact && !otherProtocolBackends.isEmpty)
            let stepPrompts = isOwn ? prompts : FallbackRungPrompts(base: prompts)
            do throws(ConnectionFailure) {
                let session = try await backend.connect(
                    ConnectionRequest(options: stepOptions, transport: transport.provider, prompts: stepPrompts, progress: progress)
                )
                // Whatever a back end let through, a session that must be encrypted and is not
                // ends here, before the user types into it.
                if options.requiresEncryption, !session.info.isEncrypted, !session.info.isTunnelled {
                    await session.disconnect()
                    throw ConnectionFailure.notEncrypted(detail: String(localized: "The session would not be encrypted.", bundle: #bundle))
                }
                return Outcome(session: session, step: step, fallbacks: fallbacks, ssh: transport.ssh)
            } catch {
                if case .otherProtocol = error { otherProtocolBackends.insert(step.backendID) }
                let next = steps[(index + 1)...].first(where: remains)
                guard let next, Self.shouldFallBack(after: error, from: step, to: next) else {
                    await transport.ssh?.close()
                    if options.requiresServerAuthentication {
                        switch error {
                        case .unsupportedServer, .otherProtocol: throw Self.identityUnverifiable(computer)
                        default: break
                        }
                    }
                    throw Self.explanation(for: error, at: step, ownBackendID: ownBackendID, after: fallbacks)
                }
                fallbacks.append(Fallback(step: step, failure: error))
            }
        }
        await transport.ssh?.close()
        throw fallbacks.last?.failure ?? .unsupportedServer(detail: String(localized: "No back end is available.", bundle: #bundle))
    }

    /// The failure to show when the last rung failed. A server that refuses the computer's own
    /// protocol usually refuses the plainer one too, in vaguer words (a server for Apple's viewer
    /// tells a VNC client only that it needs Apple's viewer); the computer's own back end said what
    /// was actually wrong, so its words win.
    static func explanation(for failure: ConnectionFailure, at step: Step, ownBackendID: String?, after fallbacks: [Fallback]) -> ConnectionFailure {
        switch failure {
        case .unsupportedServer, .protocolViolation:
            guard step.backendID != ownBackendID else { return failure }
            let own = fallbacks.last { fallback in
                if fallback.step.backendID == ownBackendID, case .unsupportedServer = fallback.failure { true } else { false }
            }
            return own?.failure ?? failure
        default:
            return failure
        }
    }

    private static func identityUnverifiable(_ computer: ComputerConfiguration) -> ConnectionFailure {
        .identityUnverifiable(detail: String(localized: "“\(computer.displayName)” proved its identity before, but what answered now can’t. It may not be your computer. Your password wasn’t sent.", bundle: #bundle))
    }
}

/// The questions of a rung that uses another back end than the computer's own (plain VNC for a
/// Mac). A ``FallbackPromptHandler`` answers them without the computer's saved or cached
/// credentials; any other handler answers them as usual.
struct FallbackRungPrompts: PromptHandler {
    let base: any PromptHandler

    func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        if let fallbackAware = base as? any FallbackPromptHandler {
            return await fallbackAware.resolveOnFallbackRung(prompt)
        }
        return await base.resolve(prompt)
    }
}

/// A prompt handler that also holds the device owner's agreement for the session's protected
/// secrets, so that unlocking the tunnel's key and the saved password asks the owner once.
protocol SecretAccessHolder: PromptHandler {
    var secretAccess: SecretAccess { get }
}

/// A prompt handler that treats questions from a fallback rung (``FallbackRungPrompts``) apart.
protocol FallbackPromptHandler: PromptHandler {
    func resolveOnFallbackRung(_ prompt: SessionPrompt) async -> PromptResponse
}
