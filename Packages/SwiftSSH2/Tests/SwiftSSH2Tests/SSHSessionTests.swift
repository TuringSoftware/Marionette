// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import SwiftSSH2
import SwiftSSH2TestSupport
import Synchronization
import Testing

/// These tests talk to a real OpenSSH server started for the purpose (see `LocalSSHServer`), so
/// they exercise the same protocol paths as a connection to a Mac with Remote Login on.
@Suite(.serialized) struct SSHSessionTests {
    static let server = Result { try LocalSSHServer() }
    var server: LocalSSHServer { get throws { try Self.server.get() } }

    private func readExactly(_ count: Int, from channel: SSHChannel) async throws -> Data {
        var collected = Data()
        while collected.count < count, let chunk = try await channel.read(upTo: count - collected.count) {
            collected.append(chunk)
        }
        return collected
    }

    @Test func handshakeReportsTheServersHostKey() async throws {
        let session = try await server.connect()
        let key = try #require(session.hostKey)
        #expect(key.algorithm == "ssh-ed25519")
        #expect(key.fingerprint == (try server.hostFingerprint))
        #expect(key.knownHostsLine(host: "example.com") == "example.com ssh-ed25519 \(key.keyData.base64EncodedString())")
        #expect(key.knownHostsLine(host: "example.com", port: 2222).hasPrefix("[example.com]:2222 ssh-ed25519 "))
        #expect(await !session.isAuthenticated)
        #expect(try await session.authenticationMethods(for: try server.username) == ["publickey"])
        await session.disconnect()
    }

    @Test(arguments: ["ed25519", "ecdsa", "rsa"])
    func logsInWithEachKeyType(_ name: String) async throws {
        let session = try await server.connect()
        try await session.authenticate(username: try server.username, with: .privateKey(try #require(try server.keys[name]), passphrase: nil))
        #expect(await session.isAuthenticated)
        let result = try await session.run("echo logged-in")
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "logged-in\n")
        await session.disconnect()
    }

    @Test func passphraseProtectedKey() async throws {
        let key = try #require(try server.keys["ed25519-passphrase"])
        let wrong = try await server.connect()
        await #expect(throws: SSHError.self) {
            try await wrong.authenticate(username: try server.username, with: .privateKey(key, passphrase: "not it"))
        }
        await wrong.disconnect()

        let right = try await server.connect()
        try await right.authenticate(username: try server.username, with: .privateKey(key, passphrase: "open sesame"))
        #expect(await right.isAuthenticated)
        await right.disconnect()
    }

    @Test func unauthorizedKeyAndGarbageKeyAreToldApart() async throws {
        let session = try await server.connect()
        do {
            try await session.authenticate(username: try server.username, with: .privateKey(try #require(try server.keys["stranger"]), passphrase: nil))
            Issue.record("an unauthorized key was accepted")
        } catch SSHError.authenticationFailed {
            #expect(try await session.authenticationMethods(for: try server.username) == ["publickey"])
        }
        await #expect(throws: SSHError.self) {
            try await session.authenticate(username: try server.username, with: .privateKey(Data("not a key".utf8), passphrase: nil))
        }
        // The session survives failed attempts.
        try await session.authenticate(username: try server.username, with: .privateKey(try #require(try server.keys["ed25519"]), passphrase: nil))
        #expect(await session.isAuthenticated)
        await session.disconnect()
    }

    @Test func commandOutputErrorsAndExitStatus() async throws {
        let session = try await server.login()
        let result = try await session.run("printf out; printf err >&2; exit 3")
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "out")
        #expect(String(decoding: result.standardError, as: UTF8.self) == "err")
        #expect(result.exitStatus == 3)

        // Enough output to need many window adjustments.
        let large = try await session.run("head -c 3000000 /dev/zero | tr '\\0' 'x'")
        #expect(large.standardOutput.count == 3_000_000)
        #expect(large.standardOutput.allSatisfy { $0 == UInt8(ascii: "x") })
        #expect(large.exitStatus == 0)
        await session.disconnect()
    }

    /// A short command's output, error output and exit can all arrive in one go, between this
    /// client looking at one stream and at the other. Run often enough to meet every interleaving.
    @Test(.timeLimit(.minutes(2))) func manyShortCommandsAllComeBack() async throws {
        let session = try await server.login()
        for round in 0..<300 {
            let result = try await session.run("printf out\(round); printf err\(round) >&2; exit \(round % 7)")
            #expect(String(decoding: result.standardOutput, as: UTF8.self) == "out\(round)")
            #expect(String(decoding: result.standardError, as: UTF8.self) == "err\(round)")
            #expect(result.exitStatus == Int32(round % 7))
        }
        await session.disconnect()
    }

    @Test func tunnelCarriesBytesBothWays() async throws {
        let echo = try EchoServer()
        let session = try await server.login()
        let tunnel = try await session.openTunnel(toHost: "127.0.0.1", port: echo.port)

        try await tunnel.write(Data("hello through the tunnel".utf8))
        #expect(try await readExactly(24, from: tunnel) == Data("hello through the tunnel".utf8))

        // Larger than the channel window, so writing and reading must interleave.
        let payload = Data((0..<4_000_000).map { UInt8(truncatingIfNeeded: $0 &* 131) })
        async let echoed = readExactly(payload.count, from: tunnel)
        try await tunnel.write(payload)
        #expect(try await echoed == payload)
        await tunnel.close()
        await session.disconnect()
    }

    @Test func aTunnelIsOpenedWithASmallReceiveWindow() async throws {
        // libssh2's own direct-tcpip asks for 2 MiB; a tunnel holding that much keeps seconds of
        // stale picture on a slow link before the remote encoder feels any back-pressure.
        let echo = try EchoServer()
        let session = try await server.login()
        let tunnel = try await session.openTunnel(toHost: "127.0.0.1", port: echo.port)
        #expect(try await tunnel.initialReceiveWindow() == SSHSession.tunnelWindow)
        #expect(SSHSession.tunnelWindow == 512 * 1024)
        await tunnel.close()
        await session.disconnect()
    }

    @Test func severalTunnelsShareOneSession() async throws {
        let echo = try EchoServer()
        let session = try await server.login()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    let tunnel = try await session.openTunnel(toHost: "127.0.0.1", port: echo.port)
                    let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &+ index) })
                    async let echoed = readExactly(payload.count, from: tunnel)
                    try await tunnel.write(payload)
                    let received = try await echoed
                    #expect(received == payload, "tunnel \(index)")
                    await tunnel.close()
                }
            }
            try await group.waitForAll()
        }
        await session.disconnect()
    }

    @Test func tunnelToAClosedPortIsRefused() async throws {
        let session = try await server.login()
        let port = freePort()
        do {
            _ = try await session.openTunnel(toHost: "127.0.0.1", port: port)
            Issue.record("a tunnel to a closed port opened")
        } catch SSHError.channelRefused {
            // Expected: the server could not connect.
        }
        #expect(try await session.run("echo ok").exitStatus == 0)
        await session.disconnect()
    }

    @Test func sessionRunsOverATunnelOfAnotherSession() async throws {
        // A jump host: the second SSH session's transport is a channel of the first.
        let jump = try await server.login()
        let hop = try await jump.openTunnel(toHost: "127.0.0.1", port: try server.port)
        let inner = try await SSHSession.connect(over: hop)
        #expect(inner.hostKey?.fingerprint == (try server.hostFingerprint))
        try await inner.authenticate(username: try server.username, with: .privateKey(try #require(try server.keys["ecdsa"]), passphrase: nil))
        let result = try await inner.run("echo via-jump-host")
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "via-jump-host\n")
        await inner.disconnect()
        await jump.disconnect()
    }

    @Test func cancellingABlockedReadReturnsPromptly() async throws {
        let echo = try EchoServer()
        let session = try await server.login()
        let tunnel = try await session.openTunnel(toHost: "127.0.0.1", port: echo.port)
        let reader = Task { try await tunnel.read(upTo: 100) }
        try await Task.sleep(for: .milliseconds(100))
        reader.cancel()
        let start = ContinuousClock.now
        await #expect(throws: CancellationError.self) { _ = try await reader.value }
        #expect(ContinuousClock.now - start < .seconds(2))
        try await tunnel.write(Data("still here".utf8))
        #expect(try await readExactly(10, from: tunnel) == Data("still here".utf8))
        await tunnel.close()
        await session.disconnect()
    }

    @Test func droppedConnectionFailsPendingWorkInsteadOfHanging() async throws {
        let echo = try EchoServer()
        let transport = try SocketTransport(port: try server.port)
        let session = try await SSHSession.connect(over: transport)
        try await session.authenticate(username: try server.username, with: .privateKey(try #require(try server.keys["ed25519"]), passphrase: nil))
        let tunnel = try await session.openTunnel(toHost: "127.0.0.1", port: echo.port)
        let reader = Task { try await tunnel.read(upTo: 100) }
        try await Task.sleep(for: .milliseconds(100))
        transport.closeNow()
        let start = ContinuousClock.now
        // Either an error or end-of-stream is acceptable; waiting forever is not.
        _ = try? await reader.value
        #expect(ContinuousClock.now - start < .seconds(3))
        await #expect(throws: (any Error).self) { _ = try await session.run("echo unreachable") }
        await session.disconnect()
    }
}

@Suite(.serialized) struct SFTPClientTests {
    var server: LocalSSHServer { get throws { try SSHSessionTests.server.get() } }

    @Test func fileRoundTripAndDirectoryOperations() async throws {
        let session = try await server.login()
        let sftp = try await session.openSFTP()
        let home = try await sftp.resolve(".")
        #expect(home == NSHomeDirectory())

        let root = try server.directory.appending(path: "sftp-\(UUID().uuidString.prefix(6))").path
        try await sftp.makeDirectory(root)
        #expect(try await sftp.attributes(of: root).isDirectory)

        let local = try server.directory.appending(path: "upload.bin")
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 73 &+ ($0 >> 9)) })
        try payload.write(to: local)

        let uploaded = Mutex<[UInt64]>([])
        try await sftp.upload(local, to: root + "/data.bin") { bytes in uploaded.withLock { $0.append(bytes) } }
        let steps = uploaded.withLock { $0 }
        #expect(steps.first == 0)
        #expect(steps.last == 3_000_000)
        #expect(steps == steps.sorted())

        let listing = try await sftp.list(root)
        #expect(listing.map(\.name) == ["data.bin"])
        #expect(listing[0].attributes.size == 3_000_000)
        #expect(!listing[0].attributes.isDirectory)
        #expect(listing[0].attributes.permissions == 0o644)
        #expect(abs((listing[0].attributes.modified ?? .distantPast).timeIntervalSinceNow) < 120)

        try await sftp.rename(root + "/data.bin", to: root + "/renamed.bin")
        let copy = try server.directory.appending(path: "download.bin")
        let downloaded = Mutex<UInt64>(0)
        try await sftp.download(root + "/renamed.bin", to: copy) { bytes in downloaded.withLock { $0 = bytes } }
        #expect(try Data(contentsOf: copy) == payload)
        #expect(downloaded.withLock { $0 } == 3_000_000)

        try await sftp.removeFile(root + "/renamed.bin")
        #expect(try await sftp.list(root).isEmpty)
        try await sftp.removeDirectory(root)
        await #expect(throws: SSHError.sftp(.noSuchFile)) { _ = try await sftp.attributes(of: root) }
        await sftp.close()
        await session.disconnect()
    }

    @Test func errorsNameWhatWentWrong() async throws {
        let session = try await server.login()
        let sftp = try await session.openSFTP()
        let missing = try server.directory.appending(path: "nope").path
        await #expect(throws: SSHError.sftp(.noSuchFile)) { _ = try await sftp.list(missing) }
        await #expect(throws: SSHError.sftp(.noSuchFile)) {
            try await sftp.download(missing, to: try server.directory.appending(path: "never"))
        }
        #expect(!FileManager.default.fileExists(atPath: try server.directory.appending(path: "never").path))
        await #expect(throws: SSHError.self) { try await sftp.makeDirectory("/System/marionette-not-allowed") }
        await session.disconnect()
    }

    @Test func cancelledDownloadStopsAndCleansUp() async throws {
        let session = try await server.login()
        let sftp = try await session.openSFTP()
        let big = try server.directory.appending(path: "big.bin")
        try Data(count: 40_000_000).write(to: big)
        let target = try server.directory.appending(path: "big-copy.bin")
        let transfer = Task { try await sftp.download(big.path, to: target) }
        try await Task.sleep(for: .milliseconds(30))
        transfer.cancel()
        await #expect(throws: (any Error).self) { try await transfer.value }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try await sftp.attributes(of: big.path).size == 40_000_000)
        await session.disconnect()
    }
}
