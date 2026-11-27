// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import RemoteDesktopCore
@testable import RemoteDesktopTransport
import Synchronization
import Testing

/// A loopback TCP server that echoes what it receives and hangs up on "bye".
private final class EchoServer: Sendable {
    let listener: NWListener
    let port: UInt16

    init() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.pump(connection)
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    private static func pump(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                if data == Data("bye".utf8) {
                    connection.cancel()
                    return
                }
                connection.send(content: data, completion: .contentProcessed { _ in pump(connection) })
            } else if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    deinit {
        listener.cancel()
    }
}

private func readExactly(_ count: Int, from stream: any ByteStream) async throws -> Data {
    var collected = Data()
    while collected.count < count {
        guard let chunk = try await stream.read(upTo: count - collected.count) else { break }
        collected.append(chunk)
    }
    return collected
}

@Suite struct TCPByteStreamTests {
    @Test func echoesSmallAndLargePayloads() async throws {
        let server = try await EchoServer()
        let provider = DirectTransportProvider(peer: Endpoint(host: "127.0.0.1", port: server.port))
        let stream = try await provider.openStream(port: server.port)

        try await stream.write(Data("hello".utf8))
        #expect(try await readExactly(5, from: stream) == Data("hello".utf8))

        let large = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        async let echoed = readExactly(large.count, from: stream)
        try await stream.write(large)
        #expect(try await echoed == large)
        await stream.close()
    }

    @Test func readReturnsNilWhenPeerCloses() async throws {
        let server = try await EchoServer()
        let stream = try await TCPByteStream.connect(to: Endpoint(host: "127.0.0.1", port: server.port))
        try await stream.write(Data("bye".utf8))
        #expect(try await stream.read(upTo: 16) == nil)
        await stream.close()
    }

    @Test func refusedConnectionIsUnreachable() async throws {
        // Bind then release a port so nothing is listening on it.
        let server = try await EchoServer()
        let port = server.port
        server.listener.cancel()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: TransportError.self) {
            _ = try await TCPByteStream.connect(to: Endpoint(host: "127.0.0.1", port: port), timeout: .seconds(3))
        }
    }

    @Test func connectHonoursTimeout() async {
        // 203.0.113.0/24 is reserved for documentation and routes nowhere.
        let start = ContinuousClock.now
        await #expect(throws: TransportError.self) {
            _ = try await TCPByteStream.connect(to: Endpoint(host: "203.0.113.1", port: 5900), timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancelledConnectThrowsPromptly() async {
        let attempt = Task {
            try await TCPByteStream.connect(to: Endpoint(host: "203.0.113.1", port: 5900), timeout: .seconds(30))
        }
        try? await Task.sleep(for: .milliseconds(50))
        attempt.cancel()
        let start = ContinuousClock.now
        let result = await attempt.result
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(throws: (any Error).self) { try result.get() }
    }
}

/// Listens on `port` (any free one if 0) and greets each connection with `greeting`, as an RFB or
/// SSH server speaks first.
private final class GreetingServer: Sendable {
    let listener: NWListener
    let port: UInt16

    init(port: UInt16 = 0, greeting: Data = Data("RFB 003.889\n".utf8)) async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.send(content: greeting, completion: .idempotent)
        }
        self.port = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, any Error>? = switch state {
                case .ready: .success(listener.port?.rawValue ?? 0)
                case .failed(let error): .failure(error)
                default: nil
                }
                if let result, resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(with: result) }
            }
            listener.start(queue: .global())
        }
    }

    deinit {
        listener.cancel()
    }
}

/// A SOCKS5 proxy that sends its reply and the server's first bytes in one write, which
/// Network.framework's own SOCKS client mishandles.
private final class CoalescingSOCKSProxy: Sendable {
    let server: GreetingServer
    var port: UInt16 { server.port }

    /// `requiresLogin` makes it refuse every method this client offers.
    init(destinationGreeting: Data, requiresLogin: Bool = false) async throws {
        let reply = Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        // The client's whole request fits in its first two writes; this proxy answers the method
        // selection at once and, after the CONNECT, the reply and the greeting together.
        server = try await GreetingServer(greeting: requiresLogin ? Data([0x05, 0xFF]) : Data([0x05, 0x00]))
        guard !requiresLogin else { return }
        let listener = server.listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 3, maximumLength: 3) { _, _, _, _ in
                connection.send(content: Data([0x05, 0x00]), completion: .idempotent)
                connection.receive(minimumIncompleteLength: 10, maximumLength: 10) { _, _, _, _ in
                    connection.send(content: reply + destinationGreeting, completion: .idempotent)
                }
            }
        }
    }
}

@Suite struct TCPRouteTests {
    @Test func aServerThatStartsLateIsReachedByRedialling() async throws {
        // Nothing listens at first, as when a VPN's tunnel is still coming up: the first attempt
        // fails, and a later one gets through.
        let probe = try await GreetingServer()
        let port = probe.port
        probe.listener.cancel()
        try await Task.sleep(for: .milliseconds(100))
        let late = Task {
            try await Task.sleep(for: .milliseconds(600))
            return try await GreetingServer(port: port)
        }
        let start = ContinuousClock.now
        let stream = try await TCPByteStream.connect(to: Endpoint(host: "127.0.0.1", port: port), timeout: .seconds(8))
        #expect(ContinuousClock.now - start >= .milliseconds(600))
        #expect(try await stream.read(upTo: 12) == Data("RFB 003.889\n".utf8))
        await stream.close()
        _ = try await late.value
    }

    @Test func aRefusedConnectionGivesUpAfterTheRedials() async throws {
        let probe = try await GreetingServer()
        let port = probe.port
        probe.listener.cancel()
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        await #expect(throws: TransportError.self) {
            _ = try await TCPByteStream.connect(to: Endpoint(host: "127.0.0.1", port: port), timeout: .seconds(10))
        }
        // Three attempts, a second then two apart: well inside the timeout.
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .seconds(3) && elapsed < .seconds(6))
    }

    @Test func theConnectedPeerIsNumericAndKeepsItsScope() async throws {
        let server = try await GreetingServer()
        let byName = try await TCPByteStream.connect(to: Endpoint(host: "localhost", port: server.port))
        let peer = try #require(byName.connectedPeer)
        #expect(peer.port == server.port)
        #expect(["127.0.0.1", "::1"].contains(peer.host))
        #expect(!byName.usesProxy)
        await byName.close()

        let linkLocal = try await TCPByteStream.connect(to: Endpoint(host: "fe80::1%lo0", port: server.port))
        #expect(linkLocal.connectedPeer == Endpoint(host: "fe80::1%lo0", port: server.port))
        await linkLocal.close()
    }

    @Test func datagramsGoWhereTheStreamWent() async throws {
        let server = try await GreetingServer()
        let provider = DirectTransportProvider(peer: Endpoint(host: "localhost", port: server.port))
        #expect(provider.connectedPeer == nil)
        let stream = try await provider.openStream(port: server.port)
        let reached = try #require((stream as? TCPByteStream)?.connectedPeer)
        #expect(provider.connectedPeer == reached)
        #expect(provider.supportsDatagrams)

        // A datagram channel to the same address and family: what it sends arrives at a socket
        // bound to that address only.
        let family = reached.host.contains(":") ? AF_INET6 : AF_INET
        let receiver = socket(family, SOCK_DGRAM, 0)
        defer { close(receiver) }
        var storage = sockaddr_storage()
        var length: socklen_t
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_loopback
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: withUnsafeBytes(of: address) { Array($0) }) }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: withUnsafeBytes(of: address) { Array($0) }) }
        }
        let bound = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(receiver, $0, length) == 0 && getsockname(receiver, $0, &length) == 0 }
        }
        #expect(bound)
        let port = withUnsafeBytes(of: storage) { bytes in UInt16(bigEndian: bytes.load(fromByteOffset: 2, as: UInt16.self)) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let channel = try await provider.openDatagramChannel(DatagramOptions(remotePort: port))
        channel.send(Data([42]))
        var byte: UInt8 = 0
        #expect(recv(receiver, &byte, 1, 0) == 1 && byte == 42)
        channel.close()
        await stream.close()
    }

    @Test func aSOCKSProxyIsSpokenToDirectlyAndTheGreetingBehindItsReplyKept() async throws {
        let greeting = Data("SSH-2.0-OpenSSH_9.9\r\n".utf8)
        let destination = try await GreetingServer(greeting: greeting)
        let proxy = try await CoalescingSOCKSProxy(destinationGreeting: greeting)
        let stream = try await TCPByteStream.connect(
            to: Endpoint(host: "127.0.0.1", port: destination.port), timeout: .seconds(5),
            socksProxy: Endpoint(host: "127.0.0.1", port: proxy.port)
        )
        #expect(stream.usesProxy)
        #expect(stream.connectedPeer == nil)
        var received = Data()
        while received.count < greeting.count, let chunk = try await stream.read(upTo: 64) { received.append(chunk) }
        #expect(received == greeting)
        await stream.close()
    }

    @Test func aProxyThatWantsALoginIsLeftToTheSystem() async throws {
        let destination = try await GreetingServer()
        let proxy = try await CoalescingSOCKSProxy(destinationGreeting: Data(), requiresLogin: true)
        let stream = try await TCPByteStream.connect(
            to: Endpoint(host: "127.0.0.1", port: destination.port), timeout: .seconds(5),
            socksProxy: Endpoint(host: "127.0.0.1", port: proxy.port)
        )
        // The system went through the proxy, so the peer it reached is the proxy.
        #expect(stream.usesProxy)
        #expect(stream.connectedPeer == nil)
        #expect(try await stream.read(upTo: 12) == Data("RFB 003.889\n".utf8))
        await stream.close()
    }

    @Test func aProxyInTheSystemSettingsIsFoundForEachDestination() {
        let settings = [
            "SOCKSEnable": 1, "SOCKSProxy": "10.0.0.9", "SOCKSPort": 1080,
            "ExceptionsList": ["*.example.org"],
        ] as CFDictionary
        #expect(SystemSOCKSProxy.endpoint(forHost: "mac.example.com", port: 5900, settings: settings) == Endpoint(host: "10.0.0.9", port: 1080))
        #expect(SystemSOCKSProxy.endpoint(forHost: "fe80::1%en0", port: 5900, settings: settings) == Endpoint(host: "10.0.0.9", port: 1080))
        #expect(SystemSOCKSProxy.endpoint(forHost: "mac.example.org", port: 5900, settings: settings) == nil)
        #expect(SystemSOCKSProxy.endpoint(forHost: "mac.example.com", port: 5900, settings: ["SOCKSEnable": 0] as CFDictionary) == nil)
    }

    @Test func theSOCKSRequestNamesTheDestinationAsTheProxyNeedsIt() throws {
        #expect(try SOCKS5.connectRequest(host: "192.0.2.29", port: 5900) == Data([5, 1, 0, 1, 192, 0, 2, 29, 0x17, 0x0c]))
        #expect(try SOCKS5.connectRequest(host: "mac.local", port: 22) == Data([5, 1, 0, 3, 9]) + Data("mac.local".utf8) + Data([0, 22]))
        #expect(try SOCKS5.connectRequest(host: "[::1]", port: 1).count == 4 + 16 + 2)
        #expect(throws: SOCKS5.Failure.authenticationRequired) { try SOCKS5.checkMethodSelection(Data([5, 0xFF])) }
        #expect(throws: SOCKS5.Failure.rejected(5)) { try SOCKS5.boundAddress(afterReplyHeader: Data([5, 5, 0, 1])) }
        #expect(try SOCKS5.boundAddress(afterReplyHeader: Data([5, 0, 0, 3])) == .domain)
    }
}

@Suite struct UDPDatagramChannelTests {
    @Test func exchangesDatagramsBetweenFixedPorts() async throws {
        let first = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(remotePort: 9))
        let firstPort = first.localPort
        first.close()
        let a = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(localPort: firstPort, remotePort: firstPort &+ 1, receiveBufferSize: 4 << 20))
        let b = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(localPort: firstPort &+ 1, remotePort: firstPort))
        #expect(a.localPort == firstPort)

        let (stream, continuation) = AsyncStream.makeStream(of: Datagram.self)
        b.start(onReceive: { continuation.yield($0) }, onClose: { _ in continuation.finish() })
        a.start(onReceive: { _ in }, onClose: { _ in })

        let before = ContinuousClock.now
        for index in 0..<20 {
            a.send(Data([UInt8(index), 0xAB]))
        }
        var received: [UInt8] = []
        for await datagram in stream {
            #expect(datagram.payload.count == 2)
            #expect(datagram.receivedAt >= before)
            received.append(datagram.payload[0])
            if received.count == 20 { break }
        }
        #expect(received == Array(0..<20))
        a.close()
        b.close()
    }

    @Test func closeInvokesOnCloseOnce() async throws {
        let channel = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(remotePort: 9))
        let closes = Mutex(0)
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        channel.start(onReceive: { _ in }, onClose: { error in
            #expect(error == nil)
            closes.withLock { $0 += 1 }
            continuation.yield()
        })
        channel.close()
        channel.close()
        for await _ in stream { break }
        try await Task.sleep(for: .milliseconds(50))
        #expect(closes.withLock { $0 } == 1)
        channel.send(Data([1]))
    }

    @Test func sessionsToTwoPeersShareTheFixedLocalPort() async throws {
        // Two Macs each send to the same local port; each socket is connected to its own Mac, and
        // the kernel hands each datagram to the socket whose peer sent it.
        let macA = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(remotePort: 9))
        let macB = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(remotePort: 9))
        let shared = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(remotePort: 9))
        let port = shared.localPort
        shared.close()
        let toA = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(localPort: port, remotePort: macA.localPort))
        let toB = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(localPort: port, remotePort: macB.localPort))
        defer { [macA, macB, toA, toB].forEach { $0.close() } }

        let (stream, continuation) = AsyncStream.makeStream(of: (String, UInt8).self)
        toA.start(onReceive: { continuation.yield(("A", $0.payload[0])) }, onClose: { _ in })
        toB.start(onReceive: { continuation.yield(("B", $0.payload[0])) }, onClose: { _ in })
        let replyA = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(localPort: macA.localPort, remotePort: port))
        let replyB = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(localPort: macB.localPort, remotePort: port))
        defer { replyA.close(); replyB.close() }
        replyA.send(Data([1]))
        replyB.send(Data([2]))
        var seen: [String: UInt8] = [:]
        for await (leg, value) in stream {
            seen[leg] = value
            if seen.count == 2 { break }
        }
        #expect(seen == ["A": 1, "B": 2])
    }

    @Test func pathErrorsAreSurvivedAndCounted() async throws {
        let first = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(remotePort: 9))
        let port = first.localPort
        first.close()
        let a = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(localPort: port, remotePort: port &+ 1))
        let b = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(localPort: port &+ 1, remotePort: port))
        defer { a.close(); b.close() }
        let closed = Mutex(false)
        a.start(onReceive: { _ in }, onClose: { _ in closed.withLock { $0 = true } })
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        b.start(onReceive: { continuation.yield($0.payload) }, onClose: { _ in })

        // Bigger than the system allows for one datagram: EMSGSIZE, a path error.
        a.send(Data(count: 60_000))
        #expect(a.survivedErrors == 1)
        a.send(Data([7]))
        for await payload in stream {
            #expect(payload == Data([7]))
            break
        }
        #expect(!closed.withLock { $0 })
    }

    @Test(arguments: [EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, EMSGSIZE, ECONNREFUSED, ENOBUFS, ENETDOWN, EADDRNOTAVAIL])
    func errorsFromThePathDoNotEndTheChannel(code: Int32) {
        #expect(!UDPDatagramChannel.meansSocketIsGone(code))
    }

    @Test(arguments: [EBADF, ENOTSOCK, ENOTCONN, EPIPE])
    func errorsThatMeanTheSocketIsGoneDo(code: Int32) {
        #expect(UDPDatagramChannel.meansSocketIsGone(code))
    }

    @Test func theGrantedReceiveBufferIsReadBack() throws {
        let wanted = 8 << 20
        let asked = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(remotePort: 9, receiveBufferSize: wanted))
        defer { asked.close() }
        let untouched = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(remotePort: 9))
        defer { untouched.close() }
        #expect(untouched.receiveBufferSize > 0 && untouched.receiveBufferSize < wanted)
        // How much a system grants is bounded by its kern.ipc.maxsockbuf, which differs between
        // machines: GitHub's macOS runners grant less than 8 MB. Past its limit a system either
        // refuses (and the channel steps down) or quietly cuts the size to the limit, as macOS 27
        // does; either way the channel reports what the socket holds.
        let granted = asked.receiveBufferSize
        #expect(granted > untouched.receiveBufferSize && granted <= wanted)
        #expect(Self.receiveBuffer(asking: granted) == granted)
        if Self.receiveBuffer(asking: wanted) == wanted {
            #expect(granted == wanted)
        } else {
            // Within an eighth of a step of the most the system holds.
            let more = granted + granted / 7 + 1
            #expect(Self.receiveBuffer(asking: more).map { $0 < more } ?? true)
        }
    }

    /// What a new socket's receive buffer holds after asking for `size`; `nil` if it was refused.
    private static func receiveBuffer(asking size: Int) -> Int? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var value = Int32(clamping: size)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return nil }
        var held: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &held, &length)
        return Int(held)
    }

    @Test func secondBindToSamePortIsRefused() throws {
        let first = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(remotePort: 9))
        defer { first.close() }
        #expect(throws: TransportError.addressInUse(port: first.localPort)) {
            _ = try UDPDatagramChannel.open(host: "127.0.0.1", options: DatagramOptions(localPort: first.localPort, remotePort: 9))
        }
    }
}
