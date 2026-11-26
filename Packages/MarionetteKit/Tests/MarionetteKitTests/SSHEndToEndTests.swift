// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopTransport
import SwiftSSH2TestSupport
import Synchronization
import Testing
@testable import MarionetteKit

/// The live connector against a private OpenSSH server on a loopback port (public-key logins only).
@Suite(.serialized) struct SSHEndToEndTests {
    static let server = Result { try LocalSSHServer() }
    var server: LocalSSHServer { get throws { try Self.server.get() } }

    private struct Rig {
        let hostKeys: FileHostKeyStore
        let keys = SSHKeyStore(secrets: InMemorySecretStore())
        let folder: URL
        var computer: ComputerConfiguration

        init(server: LocalSSHServer, remoteDesktopPort: UInt16) {
            folder = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
            hostKeys = FileHostKeyStore(fileURL: folder.appending(path: "known_hosts.json"))
            computer = ComputerConfiguration(host: "127.0.0.1", port: remoteDesktopPort, username: server.username)
            computer.tunnel.isEnabled = true
            computer.tunnel.port = server.port
        }

        var factory: LiveTransportFactory {
            LiveTransportFactory(ssh: SSHServices(connector: LiveSSHConnector(connectTimeout: .seconds(5)), hostKeys: hostKeys, keys: keys))
        }

        func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    }

    /// A key that signs where it is kept signs in to a real OpenSSH server.
    @Test func aHardwareKeySignsInToOpenSSH() async throws {
        let server = try server
        let keys = SSHKeyStore(secrets: InMemorySecretStore(), hardware: SimulatedHardwareKeys())
        let info = try keys.generate(named: "Enclave", storage: SSHKeyStorage(isInSecureEnclave: true, protection: SecretProtection(requiresUserPresence: true)))
        try server.authorize(try #require(info.authorizedKeysLine))
        let services = SSHServices(connector: LiveSSHConnector(connectTimeout: .seconds(5)), hostKeys: InMemoryKnownHostsStore(), keys: keys)
        let target = SSHTarget(server: Endpoint(host: "127.0.0.1", port: server.port), username: server.username, keyName: "Enclave")

        let asked = Mutex(0)
        let access = SecretAccess { _ in
            asked.withLock { $0 += 1 }
            return true
        }
        let handle = try await services.open(target, prompts: ScriptedPrompts([.trustHostKey(remember: false)]), access: access)
        #expect(asked.withLock { $0 } == 1)
        await handle.close()

        // Without the owner the key is not offered, and the server accepts nothing else.
        await #expect(throws: SSHConnectionError.authenticationFailed) {
            _ = try await services.open(target, prompts: ScriptedPrompts([.trustHostKey(remember: false)]), access: .denied)
        }
    }

    @Test func aGeneratedKeyOpensATunnelThatCarriesStreamsAndFiles() async throws {
        let echo = try EchoServer()
        var rig = Rig(server: try server, remoteDesktopPort: echo.port)
        defer { rig.cleanUp() }
        let info = try rig.keys.generate(named: "iPad")
        try server.authorize(try #require(info.authorizedKeysLine))
        rig.computer.tunnel.keyName = "iPad"

        let prompts = ScriptedPrompts([.trustHostKey(remember: true)])
        let prepared = try await rig.factory.makeTransport(for: rig.computer, prompts: prompts)
        #expect(prompts.seen.count == 1)
        #expect(prompts.hostKeyChallenges.first?.fingerprint == (try server.hostFingerprint))
        #expect(prompts.hostKeyChallenges.first?.status == .unknown)
        #expect(await rig.hostKeys.all().map(\.key.fingerprint) == [try server.hostFingerprint])
        #expect(prepared.provider.isTunnelled && !prepared.provider.supportsDatagrams)

        // The remote-desktop port, reached as the SSH server's own localhost.
        let stream = try await prepared.provider.openStream(port: echo.port)
        let payload = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        async let echoed: Data = {
            var collected = Data()
            while collected.count < payload.count, let chunk = try await stream.read(upTo: 65_536) { collected.append(chunk) }
            return collected
        }()
        try await stream.write(payload)
        #expect(try await echoed == payload)
        await stream.close()

        let ssh = try #require(prepared.ssh)
        let files = ssh.makeFileTransfer()
        let listing = try await files.list(directory: try server.directory.path)
        #expect(listing.contains { $0.name == "authorized_keys" && !$0.isDirectory })
        let browser = await RemoteFileBrowserModel(transfer: files, startDirectory: try server.directory.path)
        await browser.waitUntilLoaded()
        #expect(await browser.entries.contains { $0.name == "sshd_config" })
        #expect(await browser.errorMessage == nil)

        await ssh.close()
        await #expect(throws: (any Error).self) { _ = try await prepared.provider.openStream(port: echo.port) }

        // Remembered on disk: the next connection asks nothing.
        let silent = ScriptedPrompts()
        let again = try await rig.factory.makeTransport(for: rig.computer, prompts: silent)
        #expect(silent.seen.isEmpty)
        await again.ssh?.close()
    }

    @Test func anImportedKeyAsksForItsPassphraseByName() async throws {
        var rig = Rig(server: try server, remoteDesktopPort: 5900)
        defer { rig.cleanUp() }
        let text = String(decoding: try #require(try server.keys["ed25519-passphrase"]), as: UTF8.self)
        let info = try rig.keys.importKey(named: "Locked", text: text)
        #expect(info.isEncrypted && info.type == "ssh-ed25519")
        rig.computer.tunnel.keyName = "Locked"

        let prompts = ScriptedPrompts([.trustHostKey(remember: false), .passphrase("wrong"), .passphrase("open sesame")])
        let prepared = try await rig.factory.makeTransport(for: rig.computer, prompts: prompts)
        #expect(prompts.passphraseRequests == [KeyPassphraseRequest(keyName: "Locked", attempt: 1), KeyPassphraseRequest(keyName: "Locked", attempt: 2)])
        await prepared.ssh?.close()
    }

    @Test func aKeyTheServerDoesNotKnowFailsTheSignIn() async throws {
        var rig = Rig(server: try server, remoteDesktopPort: 5900)
        defer { rig.cleanUp() }
        try rig.keys.importKey(named: "Stranger", text: String(decoding: try #require(try server.keys["stranger"]), as: UTF8.self))
        rig.computer.tunnel.keyName = "Stranger"
        await #expect(throws: ConnectionFailure.authenticationFailed(detail: "The SSH server at “127.0.0.1” didn’t accept the sign-in.")) {
            _ = try await rig.factory.makeTransport(for: rig.computer, prompts: ScriptedPrompts([.trustHostKey(remember: false)]))
        }
        await #expect(throws: ConnectionFailure.hostKeyRejected(host: "127.0.0.1")) {
            _ = try await rig.factory.makeTransport(for: rig.computer, prompts: ScriptedPrompts([.cancel]))
        }
    }

    @Test func aPortNothingListensOnIsATunnelFailure() async throws {
        var rig = Rig(server: try server, remoteDesktopPort: 5900)
        defer { rig.cleanUp() }
        rig.computer.tunnel.port = freePort()
        do {
            _ = try await rig.factory.makeTransport(for: rig.computer, prompts: ScriptedPrompts())
            Issue.record("connected to a closed port")
        } catch {
            guard case .tunnelFailed(let detail) = error else {
                Issue.record("expected a tunnel failure, got \(error)")
                return
            }
            #expect(detail.hasPrefix("The SSH server at 127.0.0.1:\(rig.computer.tunnel.port) couldn’t be reached"))
        }
    }
}
