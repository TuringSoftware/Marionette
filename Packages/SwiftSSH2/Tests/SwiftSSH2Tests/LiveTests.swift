// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftSSH2
import SwiftSSH2TestSupport
import Synchronization
import Testing

/// Logins that need a real account's password, which the private test server cannot offer. Run
/// only when `MARIONETTE_TEST_HOST` names a machine with Remote Login on (an IPv4 address).
private enum LiveSSH {
    static let environment = ProcessInfo.processInfo.environment
    static let host = environment["MARIONETTE_TEST_HOST"]
    static let user = environment["MARIONETTE_TEST_USER"] ?? ""
    static let password = environment["MARIONETTE_TEST_PASSWORD"] ?? "password"

    static func connect() async throws -> SSHSession {
        try await SSHSession.connect(over: try SocketTransport(host: host ?? "", port: 22))
    }
}

@Suite(.serialized, .enabled(if: LiveSSH.host != nil))
struct LiveSSHTests {
    @Test func passwordLoginRunsCommandsAndSFTP() async throws {
        let session = try await LiveSSH.connect()
        #expect(session.hostKey?.fingerprint.hasPrefix("SHA256:") == true)
        let methods = try await session.authenticationMethods(for: LiveSSH.user)
        #expect(methods.contains("password"))
        try await session.authenticate(username: LiveSSH.user, with: .password(LiveSSH.password))
        let result = try await session.run("sw_vers -productName")
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "macOS\n")
        let sftp = try await session.openSFTP()
        #expect(try await sftp.resolve(".") == "/Users/\(LiveSSH.user)")
        await session.disconnect()
    }

    @Test func wrongPasswordIsRejectedAndTheRightOneThenWorks() async throws {
        let session = try await LiveSSH.connect()
        await #expect(throws: SSHError.authenticationFailed) {
            try await session.authenticate(username: LiveSSH.user, with: .password("definitely-wrong"))
        }
        try await session.authenticate(username: LiveSSH.user, with: .password(LiveSSH.password))
        #expect(await session.isAuthenticated)
        await session.disconnect()
    }

    @Test func keyboardInteractiveLoginAsksAndAccepts() async throws {
        let session = try await LiveSSH.connect()
        guard try await session.authenticationMethods(for: LiveSSH.user).contains("keyboard-interactive") else { return }
        let challenges = Mutex<[SSHKeyboardInteractiveChallenge]>([])
        try await session.authenticate(username: LiveSSH.user, with: .keyboardInteractive { challenge in
            challenges.withLock { $0.append(challenge) }
            // The responder is asynchronous, as a prompt shown to a person would be.
            try? await Task.sleep(for: .milliseconds(50))
            return challenge.prompts.map { _ in LiveSSH.password }
        })
        #expect(await session.isAuthenticated)
        let first = try #require(challenges.withLock { $0 }.first { !$0.prompts.isEmpty })
        #expect(first.prompts.count == 1)
        #expect(first.prompts[0].echoesInput == false)
        await session.disconnect()
    }

    @Test func tunnelReachesTheScreenSharingPort() async throws {
        let session = try await LiveSSH.connect()
        try await session.authenticate(username: LiveSSH.user, with: .password(LiveSSH.password))
        // What a tunnelled Screen Sharing session starts with: the server's version line.
        let tunnel = try await session.openTunnel(toHost: "127.0.0.1", port: 5900)
        var banner = Data()
        while banner.count < 12, let chunk = try await tunnel.read(upTo: 12 - banner.count) { banner.append(chunk) }
        #expect(String(decoding: banner, as: UTF8.self) == "RFB 003.889\n")
        await tunnel.close()
        await session.disconnect()
    }
}
