// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
public import RemoteDesktopCore
import Synchronization

/// A connected UDP socket as a ``DatagramChannel``.
///
/// Plain BSD sockets rather than Network.framework: the media path needs a fixed local port shared
/// with nothing else, a large receive buffer, and arrival times taken as the datagram is read.
public final class UDPDatagramChannel: DatagramChannel {
    public let localPort: UInt16
    /// The receive buffer the kernel granted, in bytes. It can be less than was asked for.
    public let receiveBufferSize: Int

    private struct State {
        var descriptor: Int32
        var source: (any DispatchSourceRead)?
        var isClosed = false
        var onClose: (@Sendable (TransportError?) -> Void)?
        var survivedErrors = 0
        var errorsByCode: [Int32: Int] = [:]
    }

    private let queue: DispatchQueue
    private let state: Mutex<State>

    private init(descriptor: Int32, localPort: UInt16, receiveBufferSize: Int) {
        self.localPort = localPort
        self.receiveBufferSize = receiveBufferSize
        queue = DispatchQueue(label: "llc.turing.Marionette.udp.\(localPort)", qos: .userInteractive)
        state = Mutex(State(descriptor: descriptor))
    }

    /// Errors from receiving or sending that the channel carried on through.
    public var survivedErrors: Int { state.withLock { $0.survivedErrors } }

    deinit {
        close()
    }

    /// Opens a socket to `host`, bound and connected as `options` ask.
    public static func open(host: String, options: DatagramOptions) throws -> UDPDatagramChannel {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        hints.ai_flags = AI_NUMERICSERV
        var results: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, String(options.remotePort), &hints, &results)
        guard lookup == 0, let first = results else {
            throw TransportError.unreachable(detail: String(localized: "name lookup failed: \(String(cString: gai_strerror(lookup)))", bundle: #bundle))
        }
        defer { freeaddrinfo(results) }

        var lastError = TransportError.unreachable(detail: String(localized: "no usable address for \(host)", bundle: #bundle))
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let info = candidate {
            defer { candidate = info.pointee.ai_next }
            do {
                return try open(info.pointee, options: options)
            } catch let error as TransportError {
                lastError = error
            }
        }
        throw lastError
    }

    private static func open(_ info: addrinfo, options: DatagramOptions) throws -> UDPDatagramChannel {
        let descriptor = socket(info.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw TransportError.other(detail: "socket: \(errnoText())") }
        var succeeded = false
        defer { if !succeeded { Darwin.close(descriptor) } }

        var one: Int32 = 1
        // Sessions to two Macs bind the same fixed ports. For connected unicast UDP on Darwin,
        // SO_REUSEADDR suffices: the kernel delivers by peer, and only a second socket to the same
        // Mac is refused, at connect.
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // "Responsive multimedia" is the service class the system names for screen sharing.
        var serviceType = NET_SERVICE_TYPE_RV
        setsockopt(descriptor, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType, socklen_t(MemoryLayout<Int32>.size))
        if let wanted = options.receiveBufferSize {
            // The kernel refuses more than its maximum: step down in small steps until it agrees.
            var size = Int32(clamping: wanted)
            while size >= 64 * 1024,
                  setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                size -= size / 8
            }
        }
        var granted: Int32 = 0
        var grantedLength = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &granted, &grantedLength)

        if let localPort = options.localPort {
            let bound: Int32
            if info.ai_family == AF_INET6 {
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = localPort.bigEndian
                address.sin6_addr = in6addr_any
                bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                }
            } else {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = localPort.bigEndian
                address.sin_addr = in_addr(s_addr: INADDR_ANY)
                bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            guard bound == 0 else {
                throw errno == EADDRINUSE
                    ? TransportError.addressInUse(port: localPort)
                    : TransportError.other(detail: "bind: \(errnoText())")
            }
        }

        guard Darwin.connect(descriptor, info.ai_addr, info.ai_addrlen) == 0 else {
            // With SO_REUSEADDR the bind succeeds; a duplicate local-and-remote pair fails here.
            if errno == EADDRINUSE, let localPort = options.localPort {
                throw TransportError.addressInUse(port: localPort)
            }
            throw TransportError.unreachable(detail: "connect: \(errnoText())")
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TransportError.other(detail: "fcntl: \(errnoText())")
        }

        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw TransportError.other(detail: "getsockname: \(errnoText())") }
        let family = storage.ss_family
        let port: UInt16 = withUnsafePointer(to: &storage) { pointer in
            if family == sa_family_t(AF_INET6) {
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            } else {
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
        }
        succeeded = true
        let asked = options.receiveBufferSize.map { "\($0)" } ?? String(localized: "the default", bundle: #bundle)
        transportLog.info("UDP \(port) to \(Endpoint(host: host(of: info), port: options.remotePort), privacy: .private): receive buffer \(granted) bytes, asked for \(asked)")
        return UDPDatagramChannel(descriptor: descriptor, localPort: port, receiveBufferSize: Int(granted))
    }

    /// Whether a failed `recv` or `send` means the socket itself is gone, rather than trouble on
    /// the path. On a connected UDP socket, ICMP errors for earlier datagrams come back through
    /// later calls; one of them, spoofed or from a routing blip, must not end the session (the
    /// media watchdog decides when the path is dead). iOS reports `ENOTCONN` for a socket it
    /// reclaimed while the app was suspended; `EPIPE` follows a shutdown.
    static func meansSocketIsGone(_ code: Int32) -> Bool {
        [EBADF, ENOTSOCK, ENOTCONN, EPIPE, EINVAL].contains(code)
    }

    /// Counts an error the channel carries on through, logging the first of each kind and then
    /// each time its count doubles.
    private func survive(_ code: Int32, during operation: String) {
        let count = state.withLock { state in
            state.survivedErrors += 1
            state.errorsByCode[code, default: 0] += 1
            return state.errorsByCode[code, default: 0]
        }
        if count & (count - 1) == 0 {
            transportLog.notice("UDP \(self.localPort): \(operation) failed with \(String(cString: strerror(code))) (\(count) so far); carrying on")
        }
    }

    public func start(
        onReceive: @escaping @Sendable (Datagram) -> Void,
        onClose: @escaping @Sendable (TransportError?) -> Void
    ) {
        let descriptor: Int32? = state.withLock { state in
            guard !state.isClosed, state.source == nil else { return nil }
            state.onClose = onClose
            return state.descriptor
        }
        guard let descriptor else {
            onClose(.closed)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            withUnsafeTemporaryAllocation(byteCount: 65_536, alignment: 16) { buffer in
                // Each error reported is a separate one; still, yield the queue after a run of them.
                var errorsInARow = 0
                while true {
                    let count = recv(descriptor, buffer.baseAddress, buffer.count, 0)
                    if count >= 0 {
                        errorsInARow = 0
                        if count > 0 {
                            onReceive(Datagram(payload: Data(bytes: buffer.baseAddress!, count: count), receivedAt: .now))
                        }
                        continue
                    }
                    let code = errno
                    if code == EAGAIN || code == EWOULDBLOCK {
                        return
                    } else if code == EINTR {
                        continue
                    } else if Self.meansSocketIsGone(code) {
                        self?.shutDown(error: .other(detail: "recv: \(String(cString: strerror(code)))"))
                        return
                    } else {
                        self?.survive(code, during: "recv")
                        errorsInARow += 1
                        if errorsInARow >= 16 { return }
                    }
                }
            }
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        state.withLock { $0.source = source }
        source.resume()
    }

    public func send(_ payload: Data) {
        let descriptor: Int32? = state.withLock { $0.isClosed ? nil : $0.descriptor }
        guard let descriptor else { return }
        let sent = payload.withUnsafeBytes { bytes in
            Darwin.send(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        guard sent < 0 else { return }
        let code = errno
        if Self.meansSocketIsGone(code) {
            shutDown(error: .other(detail: "send: \(String(cString: strerror(code)))"))
        } else if code != EAGAIN, code != EWOULDBLOCK {
            // A full send buffer drops the datagram, as UDP may.
            survive(code, during: "send")
        }
    }

    public func close() {
        shutDown(error: nil)
    }

    private func shutDown(error: TransportError?) {
        let (source, descriptor, onClose): ((any DispatchSourceRead)?, Int32?, (@Sendable (TransportError?) -> Void)?) = state.withLock { state in
            guard !state.isClosed else { return (nil, nil, nil) }
            state.isClosed = true
            defer {
                state.source = nil
                state.onClose = nil
            }
            return (state.source, state.descriptor, state.onClose)
        }
        if let source {
            // The cancel handler closes the descriptor once no event handler is running.
            source.cancel()
        } else if let descriptor {
            Darwin.close(descriptor)
        }
        if let onClose {
            queue.async { onClose(error) }
        }
    }
}

private func errnoText() -> String {
    String(cString: strerror(errno))
}

/// The numeric address an `addrinfo` names, with the scope of a link-local IPv6 address.
private func host(of info: addrinfo) -> String {
    var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(info.ai_addr, info.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else { return "?" }
    return text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
