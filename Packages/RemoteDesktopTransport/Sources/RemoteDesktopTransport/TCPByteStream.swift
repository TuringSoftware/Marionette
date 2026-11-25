// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
public import RemoteDesktopCore
import Synchronization

/// A TCP connection as a ``ByteStream``.
public final class TCPByteStream: ByteStream {
    private let connection: NWConnection
    private let queue: DispatchQueue

    /// The address the connection reached, as a numeric host (IPv6 with its `%scope`) and port.
    /// Of the addresses a name resolves to, this is the one TCP got through to, so datagrams for
    /// the same machine should go there. `nil` when a proxy carries the connection.
    public let connectedPeer: Endpoint?
    /// Whether a proxy carries the connection. The far end then cannot send datagrams back.
    public let usesProxy: Bool

    /// Waits before each new attempt when the first finds no usable path: the first packet to an
    /// on-demand VPN (Tailscale, say) wakes the tunnel before any route through it exists.
    static let redialDelays: [Duration] = [.seconds(1), .seconds(2)]

    /// Keepalive: first probe after 30 s of silence, then every 10 s, giving up after 6, so a
    /// vanished peer is found within about 90 s rather than the system's ~11 minutes. Not shorter:
    /// rootshell-vnc found 15 s / 5 s / 3 ended healthy idle sessions over power-saving Wi-Fi.
    /// Screen Sharing is never silent that long: the Mac's status heartbeat comes every 2.1 s.
    static let keepalive = (idle: 30, interval: 10, count: 6)

    private init(connection: NWConnection, queue: DispatchQueue, connectedPeer: Endpoint?, usesProxy: Bool) {
        self.connection = connection
        self.queue = queue
        self.connectedPeer = connectedPeer
        self.usesProxy = usesProxy
    }

    /// Connects to `endpoint`, failing after `timeout`, through the system's SOCKS proxy if any
    /// (see ``SystemSOCKSProxy``). The 30 s default covers waking a sleeping Mac with "Wake for
    /// network access": it accepts only once fully awake, 9–11 s after the first attempt (measured,
    /// macOS 15.6); rootshell allows 3 × 10 s.
    public static func connect(to endpoint: Endpoint, timeout: Duration = .seconds(30)) async throws -> TCPByteStream {
        try await connect(to: endpoint, timeout: timeout, socksProxy: SystemSOCKSProxy.endpoint(forHost: endpoint.host, port: endpoint.port))
    }

    static func connect(to endpoint: Endpoint, timeout: Duration, socksProxy: Endpoint?) async throws -> TCPByteStream {
        guard NWEndpoint.Port(rawValue: endpoint.port) != nil else {
            throw TransportError.unreachable(detail: String(localized: "invalid port \(endpoint.port)", bundle: #bundle))
        }
        let deadline = ContinuousClock.now + timeout
        if let socksProxy {
            let (connection, queue) = try await dial(socksProxy, bypassingProxies: true, deadline: deadline)
            do {
                try await negotiateSOCKS5(on: connection, queue: queue, to: endpoint, deadline: deadline)
                transportLog.info("TCP to \(endpoint, privacy: .private) through the SOCKS proxy \(socksProxy, privacy: .private)")
                return TCPByteStream(connection: connection, queue: queue, connectedPeer: nil, usesProxy: true)
            } catch SOCKS5.Failure.authenticationRequired {
                connection.cancel()
                transportLog.info("the SOCKS proxy \(socksProxy, privacy: .private) wants a login; the system connects instead")
            } catch {
                connection.cancel()
                throw error
            }
        }
        let (connection, queue) = try await dial(endpoint, bypassingProxies: false, deadline: deadline)
        let peer = numericPeer(of: connection)
        // A direct connection reaches the port it asked for. Any other port is a proxy the system
        // chose: one from a PAC file, or the SOCKS proxy that needed the system's saved login.
        let proxied = socksProxy != nil || peer.map { $0.port != endpoint.port } ?? false
        transportLog.info("TCP to \(endpoint, privacy: .private) reached \(peer?.description ?? "an unknown address", privacy: .private)\(proxied ? ", a proxy" : "")")
        return TCPByteStream(connection: connection, queue: queue, connectedPeer: proxied ? nil : peer, usesProxy: proxied)
    }

    /// Opens a connection and waits for it to be ready, trying again while the path is unusable.
    private static func dial(_ endpoint: Endpoint, bypassingProxies: Bool, deadline: ContinuousClock.Instant) async throws -> (NWConnection, DispatchQueue) {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw TransportError.unreachable(detail: String(localized: "invalid port \(endpoint.port)", bundle: #bundle))
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = keepalive.idle
        tcp.keepaliveInterval = keepalive.interval
        tcp.keepaliveCount = keepalive.count
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .responsiveData
        parameters.preferNoProxies = bypassingProxies
        let queue = DispatchQueue(label: "llc.turing.Marionette.tcp")
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
        let attempt = ConnectAttempt()

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    attempt.arm(continuation)
                    connection.stateUpdateHandler = { state in
                        attempt.noteState(isWaiting: { if case .waiting = state { true } else { false } }())
                        switch state {
                        case .ready:
                            attempt.finish(.success(()))
                        case .failed(let error):
                            attempt.finish(.failure(map(error)))
                        case .waiting(let error):
                            if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                                // iOS shows its Local Network alert meanwhile, and the connection
                                // proceeds once the user allows it; if not, the timeout reports it.
                                attempt.noteWaiting(.localNetworkDenied)
                                return
                            }
                            let reason = map(error)
                            guard let delay = attempt.nextRedial(reason, delays: redialDelays) else {
                                attempt.finish(.failure(reason))
                                return
                            }
                            queue.asyncAfter(deadline: .now() + dispatchInterval(delay)) {
                                if attempt.isStillWaiting { connection.restart() }
                            }
                        case .cancelled:
                            attempt.finish(.failure(TransportError.closed))
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + dispatchInterval(deadline - .now)) {
                        attempt.finish(.failure(attempt.waitingReason ?? TransportError.timedOut))
                    }
                }
            } onCancel: {
                attempt.finish(.failure(CancellationError()))
            }
        } catch {
            connection.stateUpdateHandler = nil
            connection.cancel()
            throw error
        }
        connection.stateUpdateHandler = nil
        return (connection, queue)
    }

    /// Asks the proxy to connect to `endpoint`, reading exactly its reply so that whatever the
    /// server sent behind it stays in the connection for the caller.
    private static func negotiateSOCKS5(on connection: NWConnection, queue: DispatchQueue, to endpoint: Endpoint, deadline: ContinuousClock.Instant) async throws {
        let expired = Mutex(false)
        let finished = Mutex(false)
        queue.asyncAfter(deadline: .now() + dispatchInterval(deadline - .now)) {
            guard !finished.withLock({ $0 }) else { return }
            expired.withLock { $0 = true }
            connection.cancel()
        }
        defer { finished.withLock { $0 = true } }
        do {
            try await withTaskCancellationHandler {
                try await send(SOCKS5.methodRequest, on: connection)
                try SOCKS5.checkMethodSelection(try await receive(exactly: 2, on: connection))
                try await send(try SOCKS5.connectRequest(host: endpoint.host, port: endpoint.port), on: connection)
                switch try SOCKS5.boundAddress(afterReplyHeader: try await receive(exactly: 4, on: connection)) {
                case .fixed(let count):
                    _ = try await receive(exactly: count, on: connection)
                case .domain:
                    let length = try await receive(exactly: 1, on: connection)
                    _ = try await receive(exactly: Int(length[length.startIndex]) + 2, on: connection)
                }
            } onCancel: {
                connection.cancel()
            }
        } catch let failure as SOCKS5.Failure {
            if failure == .authenticationRequired { throw failure }
            throw failure.transportError
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if expired.withLock({ $0 }) { throw TransportError.timedOut }
            throw error
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: map(error)) } else { continuation.resume() }
            })
        }
    }

    private static func receive(exactly count: Int, on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error.map(map) ?? TransportError.closed)
                }
            }
        }
    }

    /// The connection's remote address in numbers, with the interface of a scoped IPv6 address.
    private static func numericPeer(of connection: NWConnection) -> Endpoint? {
        guard let path = connection.currentPath, case .hostPort(let host, let port) = path.remoteEndpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return Endpoint(host: numeric(address.rawValue, family: AF_INET), port: port.rawValue)
        case .ipv6(let address):
            var text = numeric(address.rawValue, family: AF_INET6)
            // A link-local address means nothing without the interface it was reached on.
            let localInterface: NWInterface? = if case .hostPort(.ipv6(let local), _) = path.localEndpoint { local.interface } else { nil }
            if let interface = address.interface ?? (address.isLinkLocal ? localInterface ?? path.availableInterfaces.first : nil) {
                text += "%" + interface.name
            }
            return Endpoint(host: text, port: port.rawValue)
        default:
            return nil
        }
    }

    private static func numeric(_ bytes: Data, family: Int32) -> String {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &text, socklen_t(text.count)) }
        return text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    public func read(upTo maxLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maxLength)) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: Self.map(error))
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(throwing: TransportError.closed)
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: Self.map(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func close() async {
        connection.cancel()
    }

    private static func map(_ error: NWError) -> TransportError {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN:
                .unreachable(detail: String(describing: code))
            case .ETIMEDOUT:
                .timedOut
            case .ECONNRESET, .EPIPE, .ENOTCONN, .ECANCELED:
                .closed
            default:
                .other(detail: String(describing: code))
            }
        case .dns(let code):
            .unreachable(detail: String(localized: "name lookup failed (\(code))", bundle: #bundle))
        default:
            .other(detail: error.localizedDescription)
        }
    }
}

/// A duration as dispatch understands it; negative ones are now.
func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
    let (seconds, attoseconds) = duration.components
    guard seconds >= 0, duration > .zero else { return .nanoseconds(0) }
    return .nanoseconds(Int(clamping: seconds.multipliedReportingOverflow(by: 1_000_000_000).partialValue + attoseconds / 1_000_000_000))
}

/// Resumes a connect continuation exactly once, whichever of ready, failure, timeout or cancellation
/// comes first, and keeps what the connection last waited for.
private final class ConnectAttempt: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var early: Result<Void, any Error>?
        var isWaiting = false
        var waitingReason: TransportError?
        var redials = 0
    }

    private let state = Mutex(State())

    /// Why the connection is waiting, if it is: what to report if time runs out.
    var waitingReason: TransportError? { state.withLock { $0.isWaiting ? $0.waitingReason : nil } }
    var isStillWaiting: Bool { state.withLock { $0.early == nil && $0.isWaiting } }

    func arm(_ continuation: CheckedContinuation<Void, any Error>) {
        let early: Result<Void, any Error>? = state.withLock { state in
            if let early = state.early { return early }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func noteState(isWaiting: Bool) {
        state.withLock { $0.isWaiting = isWaiting }
    }

    func noteWaiting(_ reason: TransportError) {
        state.withLock { $0.waitingReason = reason }
    }

    /// Notes `reason`, and says how long to wait before the next attempt, or `nil` once there have
    /// been as many as `delays` allows.
    func nextRedial(_ reason: TransportError, delays: [Duration]) -> Duration? {
        state.withLock { state in
            state.waitingReason = reason
            guard state.redials < delays.count else { return nil }
            defer { state.redials += 1 }
            return delays[state.redials]
        }
    }

    func finish(_ result: Result<Void, any Error>) {
        let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
            guard state.early == nil else { return nil }
            state.early = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}
