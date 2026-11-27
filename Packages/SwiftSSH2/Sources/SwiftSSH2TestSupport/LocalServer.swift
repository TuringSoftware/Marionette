// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Darwin
public import Foundation
public import SwiftSSH2
import Testing

public struct TestFailure: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

@discardableResult
public func runTool(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else { throw TestFailure("\(path) \(arguments.joined(separator: " ")) failed: \(text)") }
    return text
}

/// A port nothing is listening on, for a moment at least.
public func freePort() -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
    return UInt16(bigEndian: address.sin_port)
}

/// A TCP connection as an `SSHTransport`, on plain blocking sockets driven from a dispatch queue.
public final class SocketTransport: SSHTransport, @unchecked Sendable {
    private let descriptor: Int32
    private let readQueue = DispatchQueue(label: "test.socket.read")
    private let writeQueue = DispatchQueue(label: "test.socket.write")
    private let lock = NSLock()
    private var isClosed = false

    public init(host: String = "127.0.0.1", port: UInt16) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(host))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw TestFailure("connect to port \(port) failed: \(String(cString: strerror(errno)))")
        }
    }

    public func read(upTo maxLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async { [descriptor] in
                var buffer = [UInt8](repeating: 0, count: maxLength)
                let count = recv(descriptor, &buffer, maxLength, 0)
                if count > 0 {
                    continuation.resume(returning: Data(buffer[0..<count]))
                } else if count == 0 {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(throwing: TestFailure("recv: \(String(cString: strerror(errno)))"))
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async { [descriptor] in
                var offset = 0
                while offset < data.count {
                    let sent = data.withUnsafeBytes { send(descriptor, $0.baseAddress! + offset, data.count - offset, 0) }
                    if sent <= 0 {
                        continuation.resume(throwing: TestFailure("send: \(String(cString: strerror(errno)))"))
                        return
                    }
                    offset += sent
                }
                continuation.resume()
            }
        }
    }

    public func close() async {
        closeNow()
    }

    /// Drops the connection abruptly, as a lost network would.
    public func closeNow() {
        let shouldClose: Bool = lock.withLock {
            defer { isClosed = true }
            return !isClosed
        }
        if shouldClose {
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }
}

/// A private OpenSSH server on a loopback port, running as the current user with its own host key
/// and authorized keys. Only public-key logins work without root, which is what it is used for.
public final class LocalSSHServer: @unchecked Sendable {
    public let directory: URL
    public let port: UInt16
    public let username = NSUserName()
    private let process = Process()
    /// Held open for as long as this process lives; the server's keeper exits when it closes.
    private let lifeline = Pipe()

    /// Private keys by name: "ed25519", "ecdsa", "rsa", "ed25519-passphrase" (passphrase "open sesame"),
    /// and "stranger", which is not authorized.
    public private(set) var keys: [String: Data] = [:]
    public private(set) var hostFingerprint = ""

    public init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "swiftssh2-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        port = freePort()

        func path(_ name: String) -> String { directory.appending(path: name).path }
        try runTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path("host")])
        // "256 SHA256:… comment (ED25519)"
        hostFingerprint = try runTool("/usr/bin/ssh-keygen", ["-lf", path("host.pub")]).split(separator: " ")[1].description

        var authorized = ""
        for (name, arguments, passphrase) in [
            ("ed25519", ["-t", "ed25519"], ""),
            ("ecdsa", ["-t", "ecdsa", "-b", "256"], ""),
            ("rsa", ["-t", "rsa", "-b", "3072"], ""),
            ("ed25519-passphrase", ["-t", "ed25519"], "open sesame"),
            ("stranger", ["-t", "ed25519"], ""),
        ] {
            try runTool("/usr/bin/ssh-keygen", ["-q"] + arguments + ["-N", passphrase, "-f", path(name)])
            keys[name] = try Data(contentsOf: URL(fileURLWithPath: path(name)))
            if name != "stranger" {
                authorized += try String(contentsOfFile: path(name + ".pub"), encoding: .utf8)
            }
        }
        try authorized.write(toFile: path("authorized_keys"), atomically: true, encoding: .utf8)

        let configuration = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(path("host"))
        PidFile \(path("sshd.pid"))
        AuthorizedKeysFile \(path("authorized_keys"))
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        AllowTcpForwarding yes
        Subsystem sftp /usr/libexec/sftp-server
        LogLevel DEBUG1
        # Tests fail logins on purpose, all from 127.0.0.1. OpenSSH 9.8 and later then refuse the
        # address for a while once its failures add up to 15 s of penalty (four failed logins),
        # closing new connections before the banner, and past ten connections not yet logged in
        # drop some at random; tests on a slow machine get there.
        PerSourcePenalties no
        MaxStartups 100
        """
        try configuration.write(toFile: path("sshd_config"), atomically: true, encoding: .utf8)

        // Tests keep one server for the whole run in a static, which is never deinitialised, so the
        // server must not depend on being stopped: a small shell runs it and waits on a pipe that
        // closes when this process ends, however it ends, then stops the server and clears up.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"/usr/sbin/sshd -D -e -f "$1/sshd_config" & server=$!; cat > /dev/null; kill "$server" 2>/dev/null; wait "$server" 2>/dev/null; rm -rf "$1""#,
            "sshd-keeper", directory.path,
        ]
        process.standardInput = lifeline
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: {
            FileManager.default.createFile(atPath: path("sshd.log"), contents: nil)
            return URL(fileURLWithPath: path("sshd.log"))
        }())
        try process.run()

        for _ in 0..<100 {
            if let probe = try? SocketTransport(port: port) {
                probe.closeNow()
                return
            }
            usleep(50_000)
        }
        let log = (try? String(contentsOfFile: path("sshd.log"), encoding: .utf8)) ?? ""
        throw TestFailure("sshd did not start: \(log)")
    }

    deinit {
        stop()
        try? FileManager.default.removeItem(at: directory)
    }

    public func stop() {
        try? lifeline.fileHandleForWriting.close()
        if process.isRunning { process.waitUntilExit() }
    }

    /// A connected session, not logged in.
    ///
    /// On GitHub's runner a connection now and then gets no banner, until sshd gives up on it
    /// two minutes later. In those caught with sshd's log it was the first connection to a new
    /// server, and sshd had not started the process that answers it.
    /// Such a handshake is abandoned after `handshakeLimit` and tried again, and recorded as a
    /// warning with the end of sshd's log.
    public func connect() async throws -> SSHSession {
        var attempt = 1
        while true {
            do {
                return try await SSHSession.connect(over: try SocketTransport(port: port), timeout: Self.handshakeLimit)
            } catch let error as SSHError where attempt < 3 {
                switch error {
                case .timedOut, .handshakeFailed:
                    let log = (try? String(contentsOf: directory.appending(path: "sshd.log"), encoding: .utf8)) ?? ""
                    let tail = log.split(separator: "\n").suffix(40).joined(separator: " | ")
                    Issue.record("handshake \(attempt) with the local sshd failed (\(error)); sshd's log ends: \(tail)", severity: .warning)
                    attempt += 1
                default:
                    throw error
                }
            }
        }
    }

    /// Far longer than a handshake with the local sshd takes on a loaded machine.
    static let handshakeLimit = Duration.seconds(20)

    private let authorizing = NSLock()

    /// Lets one more key log in, given as a line of `authorized_keys` ("type base64 comment").
    public func authorize(_ line: String) throws {
        try authorizing.withLock {
            let handle = try FileHandle(forWritingTo: directory.appending(path: "authorized_keys"))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    /// A connected session, logged in with the ed25519 key.
    public func login() async throws -> SSHSession {
        let session = try await connect()
        try await session.authenticate(username: username, with: .privateKey(keys["ed25519"]!, passphrase: nil))
        return session
    }
}

/// A loopback TCP server that echoes what it receives.
public final class EchoServer: @unchecked Sendable {
    public let port: UInt16
    private let listener: Int32
    private let queue = DispatchQueue(label: "test.echo", attributes: .concurrent)

    public init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0,
              listen(listener, 8) == 0
        else { throw TestFailure("echo server could not listen") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        queue.async { [queue] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                queue.async {
                    var one: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    while true {
                        let count = recv(client, &buffer, buffer.count, 0)
                        guard count > 0 else { break }
                        var offset = 0
                        while offset < count {
                            let sent = send(client, Array(buffer[offset..<count]), count - offset, 0)
                            guard sent > 0 else { break }
                            offset += sent
                        }
                    }
                    close(client)
                }
            }
        }
    }

    deinit {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }
}
