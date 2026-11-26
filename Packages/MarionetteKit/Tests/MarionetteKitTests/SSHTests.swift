// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopSimulated
import RemoteDesktopTransport
import SwiftSSH2TestSupport
import Synchronization
import Testing
@testable import MarionetteKit

/// Answers prompts from a script and records what was asked. An exhausted script cancels.
final class ScriptedPrompts: PromptHandler {
    private let state: Mutex<(answers: [PromptResponse], seen: [SessionPrompt])>

    init(_ answers: [PromptResponse] = []) {
        state = Mutex((answers, []))
    }

    var seen: [SessionPrompt] { state.withLock { $0.seen } }

    var credentialRequests: [CredentialRequest] {
        seen.compactMap { if case .credentials(let request) = $0 { request } else { nil } }
    }

    var passphraseRequests: [KeyPassphraseRequest] {
        seen.compactMap { if case .keyPassphrase(let request) = $0 { request } else { nil } }
    }

    var hostKeyChallenges: [HostKeyChallenge] {
        seen.compactMap { if case .hostKey(let challenge) = $0 { challenge } else { nil } }
    }

    func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        state.withLock { state in
            state.seen.append(prompt)
            return state.answers.isEmpty ? .cancel : state.answers.removeFirst()
        }
    }
}

/// A scripted SSH server with in-memory stores, behind a live transport factory.
struct TunnelFixture {
    let connector: ScriptedSSHConnector
    let hostKeys: any KnownHostsStore
    let secrets = InMemorySecretStore()
    let keys: SSHKeyStore
    var computer: ComputerConfiguration

    init(_ server: ScriptedSSHConnector.Server = .init(), hostKeys: any KnownHostsStore = InMemoryKnownHostsStore()) {
        connector = ScriptedSSHConnector(server)
        self.hostKeys = hostKeys
        keys = SSHKeyStore(secrets: secrets)
        computer = ComputerConfiguration(name: "Studio", host: "studio-mac.local", username: "alex")
        computer.tunnel.isEnabled = true
    }

    var services: SSHServices { SSHServices(connector: connector, hostKeys: hostKeys, keys: keys) }
    var factory: LiveTransportFactory { LiveTransportFactory(ssh: services) }

    static func accepting(password: String) -> ScriptedSSHConnector.Server {
        var server = ScriptedSSHConnector.Server()
        server.password = password
        return server
    }

    func failure(_ prompts: any PromptHandler) async -> ConnectionFailure? {
        do {
            _ = try await factory.makeTransport(for: computer, prompts: prompts)
            return nil
        } catch {
            return error
        }
    }
}

@Suite struct SSHTunnelFactoryTests {
    @Test func theTunnelGoesToTheComputerItselfUnlessAnotherServerIsNamed() async throws {
        var fixture = TunnelFixture()
        let prompts = ScriptedPrompts([.trustHostKey(remember: false)])
        let own = try await fixture.factory.makeTransport(for: fixture.computer, prompts: prompts)
        #expect(fixture.connector.logins[0].server == Endpoint(host: "studio-mac.local", port: 22))
        #expect(fixture.connector.logins[0].username == "alex")
        #expect(fixture.connector.logins[0].privateKey == nil)
        #expect(own.provider.isTunnelled)
        #expect(own.provider.peer == Endpoint(host: "studio-mac.local", port: 5900))
        #expect(own.ssh?.server == Endpoint(host: "studio-mac.local", port: 22))

        fixture.computer.tunnel.host = "gate.example.com"
        fixture.computer.tunnel.port = 2222
        fixture.computer.tunnel.username = "jump"
        _ = try await fixture.factory.makeTransport(for: fixture.computer, prompts: ScriptedPrompts([.trustHostKey(remember: false)]))
        #expect(fixture.connector.logins[1].server == Endpoint(host: "gate.example.com", port: 2222))
        #expect(fixture.connector.logins[1].username == "jump")
        #expect(fixture.computer.tunnelServerIsComputer == false)
    }

    @Test func aRealTunnelReachesTheComputerAsLocalhostFromItsOwnSSHServer() {
        var computer = ComputerConfiguration(host: "Studio-Mac.local", port: 5901, username: "alex")
        #expect(computer.tunnelServerIsComputer)
        computer.tunnel.host = "studio-mac.LOCAL"
        #expect(computer.tunnelServerIsComputer)
        #expect(computer.fileAccessTarget == SSHTarget(server: Endpoint(host: "Studio-Mac.local", port: 22), username: "alex"))
        computer.tunnel.host = "gate.example.com"
        computer.tunnel.port = 2222
        computer.tunnel.username = "jump"
        computer.tunnel.keyName = "Work"
        #expect(!computer.tunnelServerIsComputer)
        #expect(computer.tunnelTarget == SSHTarget(server: Endpoint(host: "gate.example.com", port: 2222), username: "jump", keyName: "Work"))
        // The gateway's port, account and key say nothing about the computer's own SSH server.
        #expect(computer.fileAccessTarget == SSHTarget(server: Endpoint(host: "Studio-Mac.local", port: 22), username: "alex"))
    }

    @Test func anUnknownHostKeyIsAskedAboutAndRememberedOnDisk() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)/known_hosts.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let fixture = TunnelFixture(hostKeys: FileHostKeyStore(fileURL: file))

        let first = ScriptedPrompts([.trustHostKey(remember: true)])
        _ = try await fixture.factory.makeTransport(for: fixture.computer, prompts: first)
        #expect(first.hostKeyChallenges.map(\.status) == [.unknown])
        #expect(first.hostKeyChallenges.first?.host == "studio-mac.local")
        #expect(first.hostKeyChallenges.first?.fingerprint == fixture.connector.server.hostKey.fingerprint)

        // Remembered: nothing is asked again, not even by a store that reads the file afresh.
        let silent = ScriptedPrompts()
        _ = try await fixture.factory.makeTransport(for: fixture.computer, prompts: silent)
        #expect(silent.seen.isEmpty)
        let reopened = TunnelFixture(hostKeys: FileHostKeyStore(fileURL: file))
        _ = try await reopened.factory.makeTransport(for: reopened.computer, prompts: silent)
        #expect(silent.seen.isEmpty)
    }

    @Test func trustingOnceRemembersNothing() async throws {
        let fixture = TunnelFixture()
        _ = try await fixture.factory.makeTransport(for: fixture.computer, prompts: ScriptedPrompts([.trustHostKey(remember: false)]))
        #expect(await fixture.hostKeys.all().isEmpty)
    }

    @Test func aChangedHostKeyIsFlaggedAndDecliningRejectsTheHost() async throws {
        let fixture = TunnelFixture()
        let previous = KnownHostKey(algorithm: "ssh-ed25519", keyData: Data(repeating: 1, count: 51), fingerprint: "SHA256:previous")
        await fixture.hostKeys.remember(previous, for: Endpoint(host: "studio-mac.local", port: 22))
        let prompts = ScriptedPrompts([.cancel])
        #expect(await fixture.failure(prompts) == .hostKeyRejected(host: "studio-mac.local"))
        #expect(prompts.hostKeyChallenges.map(\.status) == [.changed(previousFingerprint: "SHA256:previous")])
        #expect(await fixture.hostKeys.knownKey(for: Endpoint(host: "studio-mac.local", port: 22)) == previous)
        #expect(fixture.connector.handles.isEmpty)
    }

    @Test func passwordsAreAskedForWithAttemptCountsAndTheReasonForARetry() async throws {
        let fixture = TunnelFixture(TunnelFixture.accepting(password: "right"))
        let prompts = ScriptedPrompts([
            .trustHostKey(remember: false),
            .credentials(username: "alex", password: "wrong"),
            .credentials(username: "alex", password: "right"),
        ])
        let prepared = try await fixture.factory.makeTransport(for: fixture.computer, prompts: prompts)
        #expect(prepared.ssh != nil)
        let requests = prompts.credentialRequests
        #expect(requests.map(\.attempt) == [1, 2])
        #expect(requests.map(\.previousFailure) == [nil, "The password is incorrect."])
        #expect(requests.allSatisfy { $0.context == .sshTunnel(host: "studio-mac.local") && $0.kind == .passwordOnly && $0.suggestedUsername == "alex" })
    }

    @Test func threeWrongPasswordsFailTheSignInAndDismissingThePromptCancels() async throws {
        let fixture = TunnelFixture(TunnelFixture.accepting(password: "right"))
        let wrong = PromptResponse.credentials(username: "alex", password: "wrong")
        let failure = await fixture.failure(ScriptedPrompts([.trustHostKey(remember: false), wrong, wrong, wrong]))
        #expect(failure == .authenticationFailed(detail: "The SSH server at “studio-mac.local” didn’t accept the sign-in."))
        #expect(await fixture.failure(ScriptedPrompts([.trustHostKey(remember: false), wrong])) == .cancelled)
        #expect(fixture.connector.handles.isEmpty)
    }

    @Test func theServersOwnQuestionsReachTheUser() async throws {
        var server = ScriptedSSHConnector.Server()
        let request = KeyboardInteractiveRequest(
            context: .sshTunnel(host: "elsewhere"), title: "Two-Factor Authentication", instruction: "Enter the code.",
            questions: [.init(text: "Verification code", echoesInput: true)]
        )
        server.keyboardInteractive = (request, ["123456"])
        let fixture = TunnelFixture(server)
        let prompts = ScriptedPrompts([.trustHostKey(remember: false), .answers(["123456"])])
        _ = try await fixture.factory.makeTransport(for: fixture.computer, prompts: prompts)
        guard case .keyboardInteractive(let asked) = try #require(prompts.seen.last) else {
            Issue.record("expected the server's questions, saw \(prompts.seen)")
            return
        }
        #expect(asked.title == "Two-Factor Authentication")
        #expect(asked.context == .sshTunnel(host: "studio-mac.local"))
        #expect(await fixture.failure(ScriptedPrompts([.trustHostKey(remember: false), .answers(["000000"])])) == .authenticationFailed(detail: "The SSH server at “studio-mac.local” didn’t accept the sign-in."))
        #expect(await fixture.failure(ScriptedPrompts([.trustHostKey(remember: false), .cancel])) == .cancelled)
    }

    @Test func theComputersKeyIsTriedBeforeAPasswordAndItsPassphraseIsAskedFor() async throws {
        let file = try SSHPrivateKeyFile.generate(.ed25519)
        let key = Data(file.text.utf8)
        var server = ScriptedSSHConnector.Server()
        server.authorizedKeys = [key: "open sesame"]
        server.password = "right"
        var fixture = TunnelFixture(server)
        try fixture.keys.importKey(named: "Work", text: file.text)
        fixture.computer.tunnel.keyName = "Work"

        let prompts = ScriptedPrompts([.trustHostKey(remember: false), .passphrase("wrong"), .passphrase("open sesame")])
        _ = try await fixture.factory.makeTransport(for: fixture.computer, prompts: prompts)
        #expect(fixture.connector.logins[0].privateKey == key)
        #expect(prompts.passphraseRequests == [KeyPassphraseRequest(keyName: "Work", attempt: 1), KeyPassphraseRequest(keyName: "Work", attempt: 2)])
        // The key got in: no password was asked for.
        #expect(prompts.credentialRequests.isEmpty)

        // Declining the passphrase leaves the password.
        let fallback = ScriptedPrompts([.trustHostKey(remember: false), .cancel, .credentials(username: "", password: "right")])
        _ = try await fixture.factory.makeTransport(for: fixture.computer, prompts: fallback)
        #expect(fallback.credentialRequests.map(\.attempt) == [1])
    }

    @Test func aKeyThatIsNoLongerStoredFallsBackToThePassword() async throws {
        var fixture = TunnelFixture(TunnelFixture.accepting(password: "right"))
        fixture.computer.tunnel.keyName = "Gone"
        let prompts = ScriptedPrompts([.trustHostKey(remember: false), .credentials(username: "", password: "right")])
        _ = try await fixture.factory.makeTransport(for: fixture.computer, prompts: prompts)
        #expect(fixture.connector.logins[0].privateKey == nil)
    }

    @Test func aComputerWithoutAnAccountIsAskedForOneAndThePasswordTypedWithItIsUsed() async throws {
        var fixture = TunnelFixture(TunnelFixture.accepting(password: "right"))
        fixture.computer.username = ""
        let prompts = ScriptedPrompts([.credentials(username: " sam ", password: "right"), .trustHostKey(remember: false)])
        _ = try await fixture.factory.makeTransport(for: fixture.computer, prompts: prompts)
        #expect(fixture.connector.logins[0].username == "sam")
        // One question for both; the server's password request was answered from it.
        #expect(prompts.credentialRequests.map(\.kind) == [.usernameAndPassword])

        // A wrong password typed with the name is the user's mistake: the retry says so.
        let retry = ScriptedPrompts([
            .credentials(username: "sam", password: "wrong"), .trustHostKey(remember: false), .credentials(username: "sam", password: "right"),
        ])
        _ = try await fixture.factory.makeTransport(for: fixture.computer, prompts: retry)
        #expect(retry.credentialRequests.map(\.attempt) == [1, 2])
        #expect(retry.credentialRequests.last?.previousFailure == "The password is incorrect.")

        #expect(await fixture.failure(ScriptedPrompts([.cancel])) == .cancelled)
        #expect(await fixture.failure(ScriptedPrompts([.credentials(username: "  ", password: "x")])) == .authenticationFailed(detail: "The SSH server at “studio-mac.local” didn’t accept the sign-in."))
    }

    @Test func aBorrowedPasswordIsTriedSilentlyAndItsRejectionIsNotHeldAgainstTheUser() async throws {
        let fixture = TunnelFixture(TunnelFixture.accepting(password: "right"))
        let target = fixture.computer.tunnelTarget
        let silent = ScriptedPrompts([.trustHostKey(remember: false)])
        _ = try await fixture.services.open(target, prompts: silent, access: .denied, presetPassword: "right")
        #expect(silent.credentialRequests.isEmpty)

        let asked = ScriptedPrompts([.trustHostKey(remember: false), .credentials(username: "", password: "nope"), .credentials(username: "", password: "right")])
        _ = try await fixture.services.open(target, prompts: asked, access: .denied, presetPassword: "stale")
        #expect(asked.credentialRequests.map(\.attempt) == [1, 2])
        #expect(asked.credentialRequests.map(\.previousFailure) == [nil, "The password is incorrect."])
    }

    @Test func failuresToConnectAreTunnelFailuresInWords() async throws {
        func failure(_ error: SSHConnectionError) async -> ConnectionFailure? {
            var server = ScriptedSSHConnector.Server()
            server.failure = error
            return await TunnelFixture(server).failure(ScriptedPrompts())
        }
        #expect(await failure(.unreachable(.timedOut)) == .tunnelFailed(detail: "The SSH server at studio-mac.local:22 didn’t answer."))
        #expect(await failure(.unreachable(.unreachable(detail: "connection refused"))) == .tunnelFailed(detail: "The SSH server at studio-mac.local:22 couldn’t be reached (connection refused)."))
        #expect(await failure(.unreachable(.localNetworkDenied)) == .localNetworkDenied)
        #expect(await failure(.failed("The SSH handshake failed.")) == .tunnelFailed(detail: "The SSH handshake failed."))
        #expect(await failure(.cancelled) == .cancelled)
    }

    @Test func cancellingTheAttemptCancelsTheTunnelAndLeavesNoConnectionOpen() async throws {
        var server = ScriptedSSHConnector.Server()
        server.delay = .seconds(30)
        let slow = TunnelFixture(server)
        let attempt = Task { await slow.failure(ScriptedPrompts()) }
        try await Task.sleep(for: .milliseconds(20))
        attempt.cancel()
        #expect(await attempt.value == .cancelled)

        // Cancelled just as the connection came up: it is closed again, not handed out.
        let fixture = TunnelFixture()
        let cancelling = CancellingPrompts()
        let late = Task { await fixture.failure(cancelling) }
        cancelling.task.withLock { $0 = late }
        #expect(await late.value == .cancelled)
        #expect(fixture.connector.handles.map(\.isClosed) == [true])
    }

    @Test func theDemoComputerAndDirectPathsOpenNoSSHConnection() async throws {
        let fixture = TunnelFixture()
        var direct = fixture.computer
        direct.tunnel.isEnabled = false
        #expect(try await fixture.factory.makeTransport(for: direct, prompts: ScriptedPrompts()).ssh == nil)
        var demo = ComputerConfiguration.demo
        demo.tunnel.isEnabled = true
        let prepared = try await fixture.factory.makeTransport(for: demo, prompts: ScriptedPrompts())
        #expect(prepared.ssh == nil && prepared.provider.isTunnelled)
        #expect(fixture.connector.logins.isEmpty)
    }
}

/// Trusts the host key, but only after cancelling the task that asked.
private final class CancellingPrompts: PromptHandler {
    let task = Mutex<Task<ConnectionFailure?, Never>?>(nil)

    func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        // Wait until the test has stored the task, then cancel it and answer anyway.
        while task.withLock({ $0 }) == nil { await Task.yield() }
        task.withLock { $0?.cancel() }
        return .trustHostKey(remember: false)
    }
}

@MainActor
@Suite struct SSHTunnelLadderTests {
    /// A ladder over a scripted SSH server and a simulated back end registered as plain VNC.
    private func ladder(_ fixture: TunnelFixture, scenario: SimulationScenario) -> ConnectionLadder {
        struct VNC: RemoteDesktopBackend {
            var scenario: SimulationScenario
            var descriptor: BackendDescriptor {
                BackendDescriptor(id: BackendID.vnc, displayName: "VNC", defaultPort: 5900, bonjourServiceType: nil, supportedModes: [.standard])
            }
            func connect(_ request: ConnectionRequest) async throws(ConnectionFailure) -> any RemoteSession {
                try await SimulatedBackend(scenario: scenario).connect(request)
            }
        }
        var registry = BackendRegistry()
        registry.register(VNC(scenario: scenario))
        return ConnectionLadder(registry: registry, transports: fixture.factory)
    }

    private func vncComputer(_ fixture: TunnelFixture) -> ComputerConfiguration {
        var computer = fixture.computer
        computer.backendID = BackendID.vnc
        return computer
    }

    @Test func theOutcomeCarriesTheTunnelsConnectionAndClosingItEndsBoth() async throws {
        let fixture = TunnelFixture()
        var scenario = fastScenario(.standard)
        scenario.account = nil
        let phases = Mutex<[ConnectionPhase]>([])
        let outcome = try await ladder(fixture, scenario: scenario).connect(
            to: vncComputer(fixture), options: SessionOptions(), prompts: ScriptedPrompts([.trustHostKey(remember: true)])
        ) { phase in phases.withLock { $0.append(phase) } }
        #expect(phases.withLock { $0.first } == .openingTunnel)
        #expect(outcome.session.info.isTunnelled)
        let handle = try #require(fixture.connector.handles.first)
        #expect(outcome.ssh?.server == handle.server)
        #expect(!handle.isClosed)
        await outcome.close()
        #expect(handle.isClosed)
        #expect(outcome.session.state.isDisconnected)
    }

    @Test func aFailedRemoteDesktopConnectionClosesTheTunnel() async throws {
        let fixture = TunnelFixture()
        var scenario = fastScenario(.standard)
        scenario.failure = (.negotiating, .unsupportedServer(detail: "Not a VNC server."))
        await #expect(throws: ConnectionFailure.unsupportedServer(detail: "Not a VNC server.")) {
            _ = try await ladder(fixture, scenario: scenario).connect(
                to: vncComputer(fixture), options: SessionOptions(), prompts: ScriptedPrompts([.trustHostKey(remember: false)]), progress: { _ in }
            )
        }
        #expect(fixture.connector.handles.map(\.isClosed) == [true])
    }

    @Test func cancellingWhileTheBackEndConnectsClosesTheTunnel() async throws {
        let fixture = TunnelFixture()
        var scenario = fastScenario(.standard)
        scenario.phaseDelay = .seconds(30)
        let ladder = ladder(fixture, scenario: scenario)
        let computer = vncComputer(fixture)
        let attempt = Task {
            do {
                _ = try await ladder.connect(to: computer, options: SessionOptions(), prompts: ScriptedPrompts([.trustHostKey(remember: false)]), progress: { _ in })
                return ConnectionFailure?.none
            } catch {
                return error as? ConnectionFailure
            }
        }
        try await waitUntil { !fixture.connector.handles.isEmpty }
        attempt.cancel()
        #expect(await attempt.value == .cancelled)
        #expect(fixture.connector.handles.map(\.isClosed) == [true])
    }

    @Test func theBrokerAnswersTheTunnelPasswordFromTheSavedSecretAndRemembersPassphrases() async throws {
        let file = try SSHPrivateKeyFile.generate(.ed25519)
        var server = ScriptedSSHConnector.Server()
        server.authorizedKeys = [Data(file.text.utf8): "open sesame"]
        let fixture = TunnelFixture(server)
        // The same Keychain for the key store and the broker, as in the app.
        let (secrets, keys, services) = (fixture.secrets, fixture.keys, fixture.services)
        try keys.importKey(named: "Work", text: file.text)
        var computer = fixture.computer
        computer.tunnel.keyName = "Work"

        let broker = PromptBroker(computer: computer, secrets: secrets)
        let first = Task { try await services.open(computer.tunnelTarget, prompts: broker, access: broker.secretAccess) }
        try await waitUntil { broker.pending != nil }
        broker.reply(.trustHostKey(remember: true))
        try await waitUntil { broker.pending != nil }
        #expect(broker.pending?.prompt == .keyPassphrase(KeyPassphraseRequest(keyName: "Work", attempt: 1)))
        #expect(!keys.hasRememberedPassphrase(for: "Work"))
        broker.reply(.passphrase("open sesame"), remember: true)
        _ = try await first.value
        // Kept only once the connection has succeeded.
        #expect(!keys.hasRememberedPassphrase(for: "Work"))
        broker.connectionSucceeded()
        #expect(keys.hasRememberedPassphrase(for: "Work"))

        // A later session, on any computer that uses the key, is not asked.
        var other = computer
        other.id = UUID()
        let later = PromptBroker(computer: other, secrets: secrets)
        _ = try await services.open(computer.tunnelTarget, prompts: later, access: later.secretAccess)
        #expect(later.pending == nil)

        try keys.delete(named: "Work")
        #expect(!keys.hasRememberedPassphrase(for: "Work"))
        #expect(try secrets.secret(for: SecretKey(appWide: .keyPassphrase, name: "Work")) == nil)
    }

    @Test func aSavedTunnelPasswordIsSentWithoutAskingAndARejectedOneIsReplacedOnlyByOneThatWorks() async throws {
        let fixture = TunnelFixture(TunnelFixture.accepting(password: "right"))
        await fixture.hostKeys.remember(fixture.connector.server.hostKey, for: fixture.computer.tunnelServer)
        let key = SecretKey.sshPassword(for: fixture.computer, server: fixture.computer.tunnelServer)
        try fixture.secrets.setSecret("right", for: key)
        let broker = PromptBroker(computer: fixture.computer, secrets: fixture.secrets)
        _ = try await fixture.factory.makeTransport(for: fixture.computer, prompts: broker)
        #expect(broker.pending == nil)
        #expect(broker.knownCredentials(for: .sshTunnel(host: "studio-mac.local"))?.password == "right")
        #expect(broker.knownCredentials(for: .remoteDesktop(host: "studio-mac.local")) == nil)

        // A stale saved password: the user is asked, with the reason; "edit credentials" drops it.
        try fixture.secrets.setSecret("stale", for: key)
        let fresh = PromptBroker(computer: fixture.computer, secrets: fixture.secrets)
        let factory = fixture.factory
        let computer = fixture.computer
        let attempt = Task { try await factory.makeTransport(for: computer, prompts: fresh) }
        try await waitUntil { fresh.pending != nil }
        guard case .credentials(let request) = fresh.pending?.prompt else {
            Issue.record("expected a password prompt")
            return
        }
        #expect(request.attempt == 2 && request.previousFailure == "The password is incorrect.")
        fresh.cancelPending()
        await #expect(throws: ConnectionFailure.cancelled) { _ = try await attempt.value }
        // "Edit credentials", then giving up: nothing saved is lost.
        fresh.forgetCredentials()
        #expect(try fixture.secrets.secret(for: key) == "stale")

        // The right one, typed without "Remember": once it has worked, the stale one goes.
        let retry = Task { try await factory.makeTransport(for: computer, prompts: fresh) }
        try await waitUntil { fresh.pending != nil }
        fresh.reply(.credentials(username: "alex", password: "right"), remember: false)
        _ = try await retry.value
        #expect(try fixture.secrets.secret(for: key) == "stale", "nothing changes before the whole connection has worked")
        fresh.connectionSucceeded()
        #expect(try fixture.secrets.secret(for: key) == nil)
    }
}

@Suite struct KnownHostsStoreTests {
    private let key = KnownHostKey(algorithm: "ssh-ed25519", keyData: Data([1, 2, 3]), fingerprint: "SHA256:one")
    private let other = KnownHostKey(algorithm: "ssh-rsa", keyData: Data([4, 5]), fingerprint: "SHA256:two")

    private func exercise(_ store: any KnownHostsStore) async {
        #expect(await store.all().isEmpty)
        await store.remember(key, for: Endpoint(host: "Studio-Mac.local", port: 22))
        await store.remember(other, for: Endpoint(host: "gate.example.com", port: 2222))
        await store.remember(other, for: Endpoint(host: "gate.example.com", port: 22))
        // Host names are not case-sensitive; ports are part of the identity.
        #expect(await store.knownKey(for: Endpoint(host: "studio-mac.LOCAL", port: 22)) == key)
        #expect(await store.knownKey(for: Endpoint(host: "studio-mac.local", port: 2222)) == nil)
        #expect(await store.all().map(\.id) == ["gate.example.com|22", "gate.example.com|2222", "studio-mac.local|22"])
        #expect(await store.all().last?.host == "Studio-Mac.local")

        await store.remember(other, for: Endpoint(host: "studio-mac.local", port: 22))
        #expect(await store.knownKey(for: Endpoint(host: "Studio-Mac.local", port: 22)) == other)
        #expect(await store.all().count == 3)

        await store.remove(host: "GATE.example.com", port: 22)
        await store.remove(host: "nobody.example.com", port: 22)
        #expect(await store.all().map(\.id) == ["gate.example.com|2222", "studio-mac.local|22"])
        await store.removeAll()
        #expect(await store.all().isEmpty)
    }

    @Test func theInMemoryStoreRemembersListsAndRemoves() async {
        await exercise(InMemoryKnownHostsStore())
    }

    @Test func theFileStoreRemembersListsRemovesAndSurvivesARelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        // The folder does not exist yet: the store creates it.
        let file = folder.appending(path: "nested/known_hosts.json")
        await exercise(FileHostKeyStore(fileURL: file))

        let store = FileHostKeyStore(fileURL: file)
        #expect(await store.all().isEmpty)
        await store.remember(key, for: Endpoint(host: "studio-mac.local", port: 22))
        #expect(await store.lastWriteError == nil)
        let relaunched = FileHostKeyStore(fileURL: file)
        #expect(await relaunched.knownKey(for: Endpoint(host: "studio-mac.local", port: 22)) == key)
        #expect(await relaunched.all().first?.key == key)
        await relaunched.remove(host: "studio-mac.local", port: 22)
        #expect(await FileHostKeyStore(fileURL: file).all().isEmpty)
        // Nothing but the one file is left behind by the atomic writes.
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["known_hosts.json"])
    }

    @Test func anUnreadableFileCountsAsEmptyAndIsReplacedByTheNextWrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "known_hosts.json")
        try Data("not json".utf8).write(to: file)
        let store = FileHostKeyStore(fileURL: file)
        #expect(await store.all().isEmpty)
        #expect(await store.knownKey(for: Endpoint(host: "a", port: 22)) == nil)
        await store.remember(key, for: Endpoint(host: "a", port: 22))
        #expect(await FileHostKeyStore(fileURL: file).knownKey(for: Endpoint(host: "a", port: 22)) == key)
    }

    @Test func aStoreThatCannotWriteStillRemembersForThisRunAndSaysSo() async throws {
        // A file where the folder should be.
        let blocker = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = FileHostKeyStore(fileURL: blocker.appending(path: "known_hosts.json"))
        await store.remember(key, for: Endpoint(host: "a", port: 22))
        #expect(await store.knownKey(for: Endpoint(host: "a", port: 22)) == key)
        #expect(await store.lastWriteError != nil)
    }
}

@Suite struct SSHKeyStoreTests {
    /// Keys made by OpenSSH's own tool, for the store to read.
    private struct Tool {
        let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: folder) }

        /// A new private key file's text and its public key line.
        func make(_ name: String, _ arguments: [String], passphrase: String = "", comment: String = "me@example") throws -> (text: String, publicLine: String) {
            let path = folder.appending(path: name).path
            try runTool("/usr/bin/ssh-keygen", ["-q"] + arguments + ["-N", passphrase, "-C", comment, "-f", path])
            return (try String(contentsOfFile: path, encoding: .utf8), try String(contentsOfFile: path + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// "SHA256:…" as `ssh-keygen -l` prints it for a public key line.
        func fingerprint(ofPublicLine line: String) throws -> String {
            let path = folder.appending(path: "check-\(UUID().uuidString).pub").path
            try line.write(toFile: path, atomically: true, encoding: .utf8)
            return String(try runTool("/usr/bin/ssh-keygen", ["-lf", path]).split(separator: " ")[1])
        }

        func publicLine(ofPrivateKey text: String) throws -> String {
            let path = folder.appending(path: "check-\(UUID().uuidString)").path
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return try runTool("/usr/bin/ssh-keygen", ["-y", "-f", path]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @Test func aGeneratedKeyIsOneOpenSSHAcceptsAndListsItsPublicHalf() throws {
        let tool = try Tool()
        defer { tool.cleanUp() }
        let store = SSHKeyStore(secrets: InMemorySecretStore())
        let info = try store.generate(named: "  iPad  ", now: Date(timeIntervalSince1970: 10))
        #expect(info.name == "iPad")
        #expect(info.type == "ssh-ed25519" && info.typeName == "Ed25519")
        #expect(!info.isEncrypted)
        #expect(info.comment == "iPad")
        #expect(info.created == Date(timeIntervalSince1970: 10))

        let text = String(decoding: try #require(try store.privateKey(named: "iPad")), as: UTF8.self)
        let line = try #require(info.authorizedKeysLine)
        // OpenSSH reads the private key and derives the same public key from it.
        #expect(try tool.publicLine(ofPrivateKey: text) == line)
        #expect(try tool.fingerprint(ofPublicLine: line) == info.fingerprint)
        #expect(try store.all() == [info])
        #expect(store.key(named: "iPad") == info)

        let second = try store.generate(named: "Second")
        #expect(second.publicKey != info.publicKey)
    }

    @Test func importedKeysAreIdentifiedWithoutTheirPassphrase() throws {
        let tool = try Tool()
        defer { tool.cleanUp() }
        let store = SSHKeyStore(secrets: InMemorySecretStore())
        for (name, arguments, passphrase, type, typeName) in [
            ("ed", ["-t", "ed25519"], "", "ssh-ed25519", "Ed25519"),
            ("ec", ["-t", "ecdsa", "-b", "256"], "", "ecdsa-sha2-nistp256", "ECDSA P-256"),
            ("rsa", ["-t", "rsa", "-b", "2048"], "", "ssh-rsa", "RSA 2048"),
            ("locked", ["-t", "ed25519"], "open sesame", "ssh-ed25519", "Ed25519"),
        ] {
            let made = try tool.make(name, arguments, passphrase: passphrase)
            let info = try store.importKey(named: name, text: made.text)
            #expect(info.type == type && info.typeName == typeName)
            #expect(info.isEncrypted == !passphrase.isEmpty)
            // The comment is inside the encrypted part of a protected key.
            #expect(info.comment == (passphrase.isEmpty ? "me@example" : ""))
            #expect(info.fingerprint == (try tool.fingerprint(ofPublicLine: made.publicLine)))
            #expect(info.authorizedKeysLine?.split(separator: " ").prefix(2).joined(separator: " ") == made.publicLine.split(separator: " ").prefix(2).joined(separator: " "))
            // What is stored is the same key, byte for byte once decoded.
            let stored = String(decoding: try #require(try store.privateKey(named: name)), as: UTF8.self)
            #expect(try SSHPrivateKeyFile(text: stored) == SSHPrivateKeyFile(text: made.text))
        }
        #expect(try store.all().map(\.name) == ["ec", "ed", "locked", "rsa"])
    }

    @Test func aKeyPastedWithoutItsLineBreaksIsStillRead() throws {
        let tool = try Tool()
        defer { tool.cleanUp() }
        let made = try tool.make("ed", ["-t", "ed25519"])
        let flattened = "Here is my key:  " + made.text.replacingOccurrences(of: "\n", with: " ") + "  thanks"
        let file = try SSHPrivateKeyFile(text: flattened)
        #expect(file == (try SSHPrivateKeyFile(text: made.text)))
        #expect(try tool.publicLine(ofPrivateKey: file.text).hasPrefix(made.publicLine.split(separator: " ").prefix(2).joined(separator: " ")))
        #expect(try SSHPrivateKeyFile(text: made.text.replacingOccurrences(of: "\n", with: "\r\n")) == file)
    }

    @Test func olderPEMKeysAreAcceptedByKind() throws {
        let tool = try Tool()
        defer { tool.cleanUp() }
        let plain = try tool.make("rsa", ["-t", "rsa", "-b", "2048", "-m", "PEM"])
        let file = try SSHPrivateKeyFile(text: plain.text)
        #expect(file.type == "ssh-rsa" && !file.isEncrypted && file.publicKey == nil && file.fingerprint == nil)
        #expect(file.text == plain.text)
        let locked = try tool.make("rsa-locked", ["-t", "rsa", "-b", "2048", "-m", "PEM"], passphrase: "open sesame")
        let lockedFile = try SSHPrivateKeyFile(text: locked.text)
        #expect(lockedFile.isEncrypted)
        #expect(lockedFile.text == locked.text)
        let store = SSHKeyStore(secrets: InMemorySecretStore())
        let info = try store.importKey(named: "Old", text: plain.text)
        #expect(info.typeName == "RSA" && info.authorizedKeysLine == nil)
    }

    @Test func whatIsNotAPrivateKeyIsRefusedWithAReason() throws {
        let tool = try Tool()
        defer { tool.cleanUp() }
        let store = SSHKeyStore(secrets: InMemorySecretStore())
        let made = try tool.make("ed", ["-t", "ed25519"])
        func error(_ name: String, _ text: String) -> SSHKeyError? {
            do {
                try store.importKey(named: name, text: text)
                return nil
            } catch {
                return error
            }
        }
        #expect(error("a", made.publicLine) == .notAPrivateKey)
        #expect(error("a", "") == .notAPrivateKey)
        #expect(error("a", "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----") == .notAPrivateKey)
        #expect(error("a", String(made.text.dropLast(40))) == .notAPrivateKey)
        #expect(error("a", "-----BEGIN DSA PRIVATE KEY-----\nAAAA\n-----END DSA PRIVATE KEY-----") == .unsupportedKeyType("DSA"))
        #expect(error("a", made.text) == nil)
        #expect(error("a", made.text) == .nameInUse("a"))
        // Without a name, an unused one.
        #expect(error("  ", made.text) == nil)
        #expect(try store.all().map(\.name) == ["a", "Imported Key"])
        #expect(SSHKeyError.nameInUse("a").message == "There is already a key named “a”.")
    }

    @Test func keysAreListedDeletedAndNamedApart() throws {
        let secrets = InMemorySecretStore()
        let store = SSHKeyStore(secrets: secrets)
        #expect(try store.all().isEmpty)
        #expect(store.availableName(basedOn: " Work ") == "Work")
        try store.generate(named: "Work")
        try store.generate(named: "Work 2")
        try store.generate(named: "home")
        #expect(store.availableName(basedOn: "Work") == "Work 3")
        #expect(store.availableName(basedOn: "") == "SSH Key")
        #expect(try store.all().map(\.name) == ["home", "Work", "Work 2"])
        // Another store over the same Keychain sees the same keys.
        #expect(try SSHKeyStore(secrets: secrets).all().map(\.name) == ["home", "Work", "Work 2"])

        try secrets.setSecret("open sesame", for: SecretKey(appWide: .keyPassphrase, name: "Work"))
        #expect(store.hasRememberedPassphrase(for: "Work"))
        store.forgetPassphrase(for: "Work")
        #expect(!store.hasRememberedPassphrase(for: "Work"))

        try store.delete(named: "Work")
        #expect(try store.privateKey(named: "Work") == nil)
        #expect(store.key(named: "Work") == nil)
        #expect(try store.all().map(\.name) == ["home", "Work 2"])
        try store.delete(named: "never existed")
        // Private keys are filed apart from every computer's secrets.
        #expect(SecretKey(appWide: .sshPrivateKey, name: "Work").account == "pk:@Work")
        #expect(SecretKey(computerID: SecretKey.appWideID, kind: .sshPrivateKey) != SecretKey(appWide: .sshPrivateKey, name: "Work"))
    }

    @Test func aFailingKeychainIsReportedAsSuch() {
        struct Broken: SecretStore {
            func secret(for key: SecretKey, access: SecretAccess?) throws -> String? { throw SecretStoreError.storeFailure(code: -25308) }
            func setSecret(_ secret: String, for key: SecretKey, protection: SecretProtection) throws { throw SecretStoreError.storeFailure(code: -25308) }
            func removeSecret(for key: SecretKey) throws {}
            func names(of kind: SecretKey.Kind) throws -> [String] { throw SecretStoreError.storeFailure(code: -25308) }
        }
        let store = SSHKeyStore(secrets: Broken())
        #expect(throws: SSHKeyError.storage(code: -25308)) { try store.all() }
        #expect(throws: SSHKeyError.storage(code: -25308)) { try store.generate(named: "a") }
        #expect(store.key(named: "a") == nil)
        #expect(throws: SSHKeyError.storage(code: -25308)) { try store.privateKey(named: "a") }
    }

    @Test func aTunnelsKeyNameIsOptionalInStoredComputers() throws {
        // What versions before SSH keys stored.
        let old = #"{"isEnabled":true,"host":"gate.example.com","port":2222,"username":"jump"}"#
        let decoded = try JSONDecoder().decode(ComputerConfiguration.Tunnel.self, from: Data(old.utf8))
        #expect(decoded.keyName == nil)
        #expect(decoded.isEnabled && decoded.host == "gate.example.com" && decoded.port == 2222 && decoded.username == "jump")

        var computer = ComputerConfiguration(host: "studio-mac.local")
        let withoutKey = try JSONEncoder().encode(computer)
        #expect(try JSONDecoder().decode(ComputerConfiguration.self, from: withoutKey) == computer)
        computer.tunnel.keyName = "Work"
        let withKey = try JSONEncoder().encode(computer)
        #expect(try JSONDecoder().decode(ComputerConfiguration.self, from: withKey).tunnel.keyName == "Work")
        // A whole stored computer from before still loads.
        var legacy = try #require(JSONSerialization.jsonObject(with: withKey) as? [String: Any])
        var tunnel = try #require(legacy["tunnel"] as? [String: Any])
        tunnel["keyName"] = nil
        legacy["tunnel"] = tunnel
        let restored = try JSONDecoder().decode(ComputerConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.tunnel.keyName == nil && restored.id == computer.id)
    }
}
