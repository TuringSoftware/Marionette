// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation

/// A network address: host name or literal address, and port.
public struct Endpoint: Sendable, Hashable, Codable, CustomStringConvertible {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// Failures below the remote-desktop protocols.
public enum TransportError: Error, Sendable, Hashable {
    case unreachable(detail: String)
    case timedOut
    case closed
    case localNetworkDenied
    case addressInUse(port: UInt16)
    case tunnel(detail: String)
    case unsupported(detail: String)
    case other(detail: String)
}

/// A reliable, ordered byte stream (TCP, or an SSH channel).
public protocol ByteStream: Sendable {
    /// Waits for data. Returns between 1 and `maxLength` bytes, or `nil` at end of stream.
    func read(upTo maxLength: Int) async throws -> Data?
    /// Writes all of `data`, suspending while the peer applies back-pressure.
    func write(_ data: Data) async throws
    /// Closes both directions. Pending and later reads end; idempotent.
    func close() async
    /// Whether the network this stream runs over is metered (cellular, a personal hotspot); `nil`
    /// when the stream cannot tell.
    var isMetered: Bool? { get }
}

extension ByteStream {
    public var isMetered: Bool? { nil }
}

/// One received datagram and when it arrived. Rate control needs the arrival time measured as close
/// to the socket as possible, not when a consumer got around to it.
public struct Datagram: Sendable {
    public var payload: Data
    public var receivedAt: ContinuousClock.Instant

    public init(payload: Data, receivedAt: ContinuousClock.Instant) {
        self.payload = payload
        self.receivedAt = receivedAt
    }
}

/// An unreliable datagram flow to one peer (UDP).
///
/// Receiving is callback-based on purpose: media arrives at thousands of packets per second, and the
/// handler runs on the channel's own I/O context without a task or actor hop per packet.
public protocol DatagramChannel: Sendable {
    /// The local port actually bound.
    var localPort: UInt16 { get }
    /// Starts delivery. Call once. `onReceive` runs serially on the channel's I/O context;
    /// `onClose` runs once, after the last `onReceive`.
    func start(
        onReceive: @escaping @Sendable (Datagram) -> Void,
        onClose: @escaping @Sendable (TransportError?) -> Void
    )
    /// Sends without waiting. Datagrams that cannot be queued are dropped, as UDP allows.
    func send(_ payload: Data)
    /// Idempotent.
    func close()
}

public struct DatagramOptions: Sendable, Hashable {
    /// Local port to bind, or `nil` for any.
    public var localPort: UInt16?
    /// Remote port. The remote host is always the provider's peer.
    public var remotePort: UInt16
    /// Requested socket receive buffer, in bytes. A hint.
    public var receiveBufferSize: Int?

    public init(localPort: UInt16? = nil, remotePort: UInt16, receiveBufferSize: Int? = nil) {
        self.localPort = localPort
        self.remotePort = remotePort
        self.receiveBufferSize = receiveBufferSize
    }
}

/// How a back end reaches one remote machine. Created above the back ends, so a back end never knows
/// whether it is talking directly or through a tunnel — except through ``isTunnelled`` and
/// ``supportsDatagrams``, which decide what it may attempt.
public protocol TransportProvider: Sendable {
    /// The machine the session is for, as the user addressed it.
    var peer: Endpoint { get }
    /// True when streams are carried by an intermediary (SSH).
    var isTunnelled: Bool { get }
    /// Whether ``openDatagramChannel(_:)`` can work at all on this path.
    var supportsDatagrams: Bool { get }
    func openStream(port: UInt16) async throws -> any ByteStream
    func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel
}
