// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import RemoteDesktopCore
import Synchronization

/// Reaches a machine directly over the network: TCP for streams, UDP for datagrams.
public struct DirectTransportProvider: TransportProvider {
    public let peer: Endpoint
    public var connectTimeout: Duration
    private let route = Route()

    /// Shared by every copy of the provider.
    private final class Route: Sendable {
        struct State {
            var connectedPeer: Endpoint?
            var usesProxy = false
        }

        let state = Mutex(State())
    }

    /// `connectTimeout` covers waking a sleeping Mac: 9–11 s measured (see
    /// ``TCPByteStream/connect(to:timeout:)``); rootshell allows 3 × 10 s attempts.
    public init(peer: Endpoint, connectTimeout: Duration = .seconds(30)) {
        self.peer = peer
        self.connectTimeout = connectTimeout
    }

    public var isTunnelled: Bool { false }

    /// False once a stream went through a proxy: the Mac would send its datagrams to the proxy.
    public var supportsDatagrams: Bool { !usesProxy }

    /// Whether the last stream opened went through a proxy from the system settings.
    public var usesProxy: Bool { route.state.withLock { $0.usesProxy } }

    /// The numeric address the last stream reached, which datagrams go to as well.
    public var connectedPeer: Endpoint? { route.state.withLock { $0.connectedPeer } }

    public func openStream(port: UInt16) async throws -> any ByteStream {
        let stream = try await TCPByteStream.connect(to: Endpoint(host: peer.host, port: port), timeout: connectTimeout)
        route.state.withLock { state in
            state.usesProxy = stream.usesProxy
            if let reached = stream.connectedPeer { state.connectedPeer = reached }
        }
        return stream
    }

    /// Opens UDP to the address and family the streams reached, not to whatever the host name
    /// resolves to first now: for a `.local` name or a dual-stack host the two can differ (TCP over
    /// IPv6 link-local, UDP over IPv4, say), and the Mac sends its media to the address its TCP
    /// peer is at, so nothing would arrive.
    public func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel {
        let host = route.state.withLock { $0.usesProxy ? nil : $0.connectedPeer?.host } ?? peer.host
        return try UDPDatagramChannel.open(host: host, options: options)
    }
}
