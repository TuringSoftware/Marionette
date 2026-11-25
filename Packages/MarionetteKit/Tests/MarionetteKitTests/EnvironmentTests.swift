// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopTransport
import Testing
@testable import MarionetteKit

@MainActor
@Suite struct EnvironmentSSHTests {
    private func environment(scenario: String) async -> AppEnvironment {
        await AppEnvironment.make(arguments: ["Marionette", "-MarionetteUITestMode", "-MarionetteScenario", scenario], pasteboard: InMemoryPasteboard())
    }

    @Test func theSimulatedEnvironmentKeepsKnownHostsAndKeysInMemory() async throws {
        let environment = await environment(scenario: "hp")
        #expect(environment.hostKeys is InMemoryKnownHostsStore)
        #expect(await environment.hostKeys.all().isEmpty)
        #expect(try environment.sshKeys.all().isEmpty)
        // Keys live in the environment's own secret store, where the prompt broker finds passphrases.
        try environment.sshKeys.generateEd25519(named: "Work")
        #expect(try environment.secrets.secret(for: SecretKey(appWide: .sshPrivateKey, name: "Work")) != nil)
        #expect(environment.transports.ssh == nil)
    }

    @Test func anEnvironmentSharesItsTransportsStores() async throws {
        let ssh = SSHServices(connector: ScriptedSSHConnector(), hostKeys: InMemoryKnownHostsStore(), keys: SSHKeyStore(secrets: InMemorySecretStore()))
        let environment = AppEnvironment(
            options: LaunchOptions(), registry: BackendRegistry(), transports: LiveTransportFactory(ssh: ssh), secrets: InMemorySecretStore(),
            discovery: SimulatedDiscoveryProvider(), pasteboard: InMemoryPasteboard(), clock: SystemClock(),
            defaults: UserDefaults(suiteName: "MarionetteKitTests.\(UUID().uuidString)")!,
            repository: ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true))
        )
        #expect(environment.sshKeys === ssh.keys)
        await ssh.hostKeys.remember(KnownHostKey(algorithm: "ssh-ed25519", keyData: Data([1]), fingerprint: "SHA256:x"), for: Endpoint(host: "a", port: 22))
        #expect(await environment.hostKeys.all().map(\.host) == ["a"])
    }

    @Test func knownHostsAreKeptInApplicationSupport() {
        let url = FileHostKeyStore.defaultFileURL
        #expect(url.lastPathComponent == "known_hosts.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Marionette")
        #expect(url.path.hasPrefix(URL.applicationSupportDirectory.path))
    }

    @Test func theHostKeyScenarioAsksAndConnectsOnceTrusted() async throws {
        let environment = await environment(scenario: "host-key")
        let session = environment.sessions.open(environment.autoConnectComputer)
        try await waitUntil { session.prompts.pending != nil }
        guard case .hostKey(let challenge) = session.prompts.pending?.prompt else {
            Issue.record("expected a host-key prompt, got \(String(describing: session.prompts.pending))")
            return
        }
        #expect(challenge.status == .unknown && challenge.host == "studio-mac.local")
        session.prompts.reply(.trustHostKey(remember: true))
        try await waitUntil { session.phase == .connected }
        #expect(session.info?.isTunnelled == true)
        session.disconnect()
    }

    @Test func theChangedHostKeyScenarioWarnsAndDecliningFailsTheConnection() async throws {
        let environment = await environment(scenario: "host-key-changed")
        let session = environment.sessions.open(environment.autoConnectComputer)
        try await waitUntil { session.prompts.pending != nil }
        guard case .hostKey(let challenge) = session.prompts.pending?.prompt, case .changed = challenge.status else {
            Issue.record("expected a changed-host-key prompt")
            return
        }
        session.prompts.reply(.cancel)
        try await waitUntil { session.phase == .failed(.hostKeyRejected(host: "studio-mac.local")) }
        session.disconnect()
    }

    @Test func theKeyboardInteractiveScenarioAsksTheServersQuestion() async throws {
        let environment = await environment(scenario: "keyboard-interactive")
        let session = environment.sessions.open(environment.autoConnectComputer)
        try await waitUntil { session.prompts.pending != nil }
        guard case .keyboardInteractive(let request) = session.prompts.pending?.prompt else {
            Issue.record("expected the server's question")
            return
        }
        #expect(request.questions.map(\.text) == ["Verification code"])
        session.prompts.reply(.answers(["123456"]))
        try await waitUntil { session.phase == .connected }
        session.disconnect()
    }
}
