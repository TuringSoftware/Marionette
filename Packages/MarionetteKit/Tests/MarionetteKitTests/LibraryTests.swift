// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopSimulated
import Testing
@testable import MarionetteKit

@Suite struct ParsedAddressTests {
    @Test(arguments: [
        ("studio-mac.local", "studio-mac.local", nil, nil),
        ("  192.168.1.20:5901 ", "192.168.1.20", 5901, nil),
        ("alex@mini.example.com", "mini.example.com", nil, "alex"),
        ("vnc://alex@mini.example.com:5902/", "mini.example.com", 5902, "alex"),
        ("[fe80::1]:5900", "fe80::1", 5900, nil),
        ("fe80::1", "fe80::1", nil, nil),
    ] as [(String, String, UInt16?, String?)])
    func parses(text: String, host: String, port: UInt16?, username: String?) throws {
        let parsed = try #require(ParsedAddress(text))
        #expect(parsed.host == host)
        #expect(parsed.port == port)
        #expect(parsed.username == username)
    }

    @Test(arguments: ["", "   ", "host:notaport", "host:0", "two words", "https://example.com", "[fe80::1"])
    func rejects(text: String) {
        #expect(ParsedAddress(text) == nil)
    }
}

@Suite struct ConfigurationTests {
    @Test func tunnelForcesStandardAndSilence() {
        var computer = ComputerConfiguration(host: "a.local", mode: .highPerformance)
        #expect(computer.allowsHighPerformance && computer.allowsAudio)
        computer.tunnel.isEnabled = true
        #expect(!computer.allowsHighPerformance && !computer.allowsAudio)
        #expect(computer.effectiveMode == .standard)
        #expect(computer.mode == .highPerformance, "the user's own choice is kept for when the tunnel is turned off")
    }

    @Test func displayNameFallsBackToTheHost() {
        #expect(ComputerConfiguration(name: "  ", host: "a.local").displayName == "a.local")
        #expect(ComputerConfiguration(name: "Desk", host: "a.local").displayName == "Desk")
    }

    @Test func configurationRoundTripsThroughCoding() throws {
        var computer = ComputerConfiguration(name: "Desk", host: "a.local", port: 5901, username: "u", mode: .standard, display: .fitToDevice)
        computer.tunnel.isEnabled = true
        computer.tunnel.host = "gate.example.com"
        let decoded = try JSONDecoder().decode(ComputerConfiguration.self, from: JSONEncoder().encode(computer))
        #expect(decoded == computer)
    }
}

@MainActor
@Suite struct RepositoryTests {
    @Test func savesUpdatesAndDeletes() throws {
        let repository = ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true))
        var first = ComputerConfiguration(name: "B", host: "b.local")
        let second = ComputerConfiguration(name: "A", host: "a.local")
        repository.save(first, now: Date(timeIntervalSince1970: 10))
        repository.save(second, now: Date(timeIntervalSince1970: 20))
        #expect(repository.records().map(\.configuration.name) == ["B", "A"], "oldest first, not alphabetical")
        first.name = "Renamed"
        repository.save(first, now: Date(timeIntervalSince1970: 99))
        #expect(repository.records().map(\.configuration.name) == ["Renamed", "A"])
        repository.recordConnection(id: first.id, mode: .standard, at: Date(timeIntervalSince1970: 50))
        repository.setThumbnail(Data([1, 2, 3]), id: first.id)
        let record = try #require(repository.record(id: first.id))
        #expect(record.lastMode == .standard)
        #expect(record.lastConnected == Date(timeIntervalSince1970: 50))
        #expect(record.thumbnail == Data([1, 2, 3]))
        repository.delete(id: first.id)
        #expect(repository.records().map(\.id) == [second.id])
    }
}

@MainActor
@Suite struct LibraryModelTests {
    private func makeLibrary(discovery: SimulatedDiscoveryProvider = SimulatedDiscoveryProvider(delay: .milliseconds(5))) throws -> (LibraryModel, InMemorySecretStore) {
        let repository = ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true))
        let secrets = InMemorySecretStore()
        return (LibraryModel(repository: repository, secrets: secrets, discovery: discovery, clock: FixedClock()), secrets)
    }

    /// New computers ask for a display shaped like the device; the seeded test computers keep the
    /// remote machine's own displays so that screenshots stay comparable.
    @Test func newComputersFitTheDeviceAndSeededOnesShowTheirOwnDisplays() async throws {
        let (library, secrets) = try makeLibrary()
        #expect(library.editorForNewComputer().configuration.display == .fitToDevice)
        let found = SimulatedDiscoveryProvider.sampleComputers[0]
        #expect(library.editor(for: found).configuration.display == .fitToDevice)
        #expect(library.save(found).display == .fitToDevice)

        let repository = ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true))
        await SeedData.seed(ScenarioCatalog.setup(named: "hp")!, into: repository, secrets: secrets, clock: FixedClock())
        #expect(repository.record(id: SeedData.studioMacID)?.configuration.display == .remoteDisplays)
        #expect(repository.record(id: SeedData.macMiniID)?.configuration.display == .remoteDisplays)
    }

    @Test func editorValidatesAndSaves() throws {
        let (library, secrets) = try makeLibrary()
        #expect(library.isEmpty)
        let editor = library.editorForNewComputer()
        #expect(!editor.canSave)
        editor.address = "not valid host"
        #expect(editor.addressProblem != nil)
        editor.address = "alex@studio-mac.local:5901"
        #expect(editor.namePlaceholder == "studio-mac.local")
        editor.commitAddress()
        #expect(editor.address == "studio-mac.local")
        #expect(editor.portText == "5901")
        #expect(editor.configuration.username == "alex")
        editor.password = "secret"
        editor.portText = "70000"
        #expect(!editor.canSave)
        editor.portText = "5901"
        let saved = try #require(editor.save())
        #expect(saved.port == 5901)
        #expect(library.items.map(\.configuration.displayName) == ["studio-mac.local"])
        #expect(try secrets.secret(for: .remoteDesktopPassword(for: saved)) == "secret")

        let again = try #require(library.editor(for: saved.id))
        #expect(again.password == "secret")
        #expect(!again.hasChanges)
        again.configuration.name = "Studio"
        again.password = ""
        #expect(again.hasChanges)
        again.save()
        #expect(library.items.first?.configuration.displayName == "Studio")
        #expect(try secrets.secret(for: .remoteDesktopPassword(for: saved)) == nil)

        // A new address is maybe another machine: the password shown for the old one is not
        // carried over unless it is typed again.
        let moving = try #require(library.editor(for: saved.id))
        moving.password = "secret"
        moving.save()
        let renamed = try #require(library.editor(for: saved.id))
        #expect(renamed.password == "secret")
        renamed.address = "studio-mac.example.com"
        let moved = try #require(renamed.save())
        #expect(try secrets.secret(for: .remoteDesktopPassword(for: moved)) == nil)
        #expect(try secrets.secret(for: .remoteDesktopPassword(for: saved)) == nil, "nor left behind for the old one")
        #expect(try #require(library.editor(for: saved.id)).password.isEmpty)

        library.duplicate(saved.id)
        #expect(library.items.map(\.configuration.displayName) == ["Studio", "Studio Copy"])
        library.delete(saved.id)
        #expect(library.items.count == 1)
    }

    @Test func tunnelDisablesHighPerformanceAudioAndAFittedDisplay() throws {
        let (library, _) = try makeLibrary()
        let editor = library.editorForNewComputer()
        editor.configuration.mode = .highPerformance
        #expect(editor.effectiveMode == .highPerformance)
        editor.configuration.tunnel.isEnabled = true
        #expect(editor.effectiveMode == .standard)
        #expect(!editor.configuration.allowsAudio)
        #expect(!editor.configuration.allowsFittedDisplay)
        editor.configuration.tunnel.isEnabled = false
        #expect(editor.effectiveMode == .highPerformance)
        #expect(editor.configuration.allowsAudio && editor.configuration.allowsFittedDisplay)
        // Standard mode has neither; the choices themselves are kept for when it is left again.
        editor.configuration.mode = .standard
        #expect(!editor.configuration.allowsAudio && !editor.configuration.allowsFittedDisplay)
        #expect(editor.configuration.audioEnabled)
    }

    @Test func discoveryStartsOnlyWhenAskedAndMergesWithSavedComputers() async throws {
        let (library, _) = try makeLibrary()
        #expect(library.discoveryState == .idle)
        #expect(library.discovered.isEmpty)
        library.startDiscovery()
        #expect(library.discoveryState == .searching)
        try await waitUntil { library.discovered.count == 4 }
        let saved = library.save(library.discovered[0])
        #expect(library.discovered.count == 3)
        #expect(library.items.first { $0.id == saved.id }?.isOnline == true)
        library.stopDiscovery()
        #expect(library.discoveryState == .idle)
        #expect(library.items.first?.isOnline == false)
    }

    @Test func deniedLocalNetworkIsReported() async throws {
        let (library, _) = try makeLibrary(discovery: SimulatedDiscoveryProvider(delay: .milliseconds(5), deniesPermission: true))
        library.startDiscovery()
        try await waitUntil { library.discoveryState == .denied }
        #expect(library.discovered.isEmpty)
    }
}

@MainActor
@Suite struct LadderAndBrokerTests {
    @Test func stepsFollowTheSettings() throws {
        let fixture = try Fixture([fastScenario()], claimedModes: [.highPerformance, .standard])
        let ladder = fixture.ladder
        var computer = ComputerConfiguration(host: "a.local")
        let id = SimulatedBackend.backendID
        #expect(ladder.steps(for: computer) == [.init(backendID: id, mode: .highPerformance), .init(backendID: id, mode: .standard)])
        computer.tunnel.isEnabled = true
        #expect(ladder.steps(for: computer) == [.init(backendID: id, mode: .standard)])
        computer.tunnel.isEnabled = false
        computer.mode = .highPerformance
        #expect(ladder.steps(for: computer) == [.init(backendID: id, mode: .highPerformance)])
    }

    @Test func aVNCRungFollowsTheAppleOnesWhenRegistered() {
        struct Named: RemoteDesktopBackend {
            var id: String
            var modes: [SessionMode]
            var descriptor: BackendDescriptor { BackendDescriptor(id: id, displayName: id, defaultPort: 5900, bonjourServiceType: nil, supportedModes: modes) }
            func connect(_ request: ConnectionRequest) async throws(ConnectionFailure) -> any RemoteSession { throw .cancelled }
        }
        var registry = BackendRegistry()
        registry.register(Named(id: BackendID.appleScreenSharing, modes: [.highPerformance, .standard]))
        registry.register(Named(id: BackendID.vnc, modes: [.standard]))
        let ladder = ConnectionLadder(registry: registry, transports: SimulatedTransportFactory())
        #expect(ladder.steps(for: ComputerConfiguration(host: "a.local")).map(\.backendID) == [BackendID.appleScreenSharing, BackendID.appleScreenSharing, BackendID.vnc])
        // Last found to be a VNC server: asked once more whether it is a Mac now, then VNC.
        #expect(ladder.steps(for: ComputerConfiguration(host: "a.local", backendID: BackendID.vnc)) == [
            .init(backendID: BackendID.appleScreenSharing, mode: .standard), .init(backendID: BackendID.vnc, mode: .standard),
        ])
        #expect(ladder.steps(for: ComputerConfiguration(host: "a.local", backendID: "rdp")).isEmpty)
    }

    @Test func theLiveRegistryRoutesRealComputersToScreenSharing() async throws {
        let ladder = ConnectionLadder(registry: AppEnvironment.liveRegistry(), transports: LiveTransportFactory())
        let mac = ComputerConfiguration(host: "studio-mac.local")
        #expect(ladder.steps(for: mac) == [
            .init(backendID: BackendID.appleScreenSharing, mode: .highPerformance),
            .init(backendID: BackendID.appleScreenSharing, mode: .standard),
            .init(backendID: BackendID.vnc, mode: .standard),
        ])
        var highPerformanceOnly = mac
        highPerformanceOnly.mode = .highPerformance
        // A Mac set to High Performance does not fall back to VNC; a server that is not a Mac does.
        #expect(ladder.steps(for: highPerformanceOnly) == [
            .init(backendID: BackendID.appleScreenSharing, mode: .highPerformance),
            .init(backendID: BackendID.vnc, mode: .standard, onlyForOtherProtocol: true),
        ])
        #expect(ladder.steps(for: .demo).map(\.backendID) == [BackendID.simulated, BackendID.simulated])
        // A computer found to be a VNC server: the Mac check, then VNC.
        #expect(ladder.steps(for: ComputerConfiguration(host: "linux.local", backendID: BackendID.vnc)).map(\.backendID) == [BackendID.appleScreenSharing, BackendID.vnc])
        #expect(ladder.steps(for: ComputerConfiguration(host: "pc.local", backendID: "rdp")).isEmpty)

        let prompts = StaticPromptHandler(username: "u", password: "p")
        let direct = try await LiveTransportFactory().makeTransport(for: ComputerConfiguration(host: "studio-mac.local", port: 5901), prompts: prompts)
        #expect(direct.provider.peer == Endpoint(host: "studio-mac.local", port: 5901))
        #expect(!direct.provider.isTunnelled && direct.provider.supportsDatagrams)
        #expect(direct.ssh == nil)
        let demo = try await LiveTransportFactory().makeTransport(for: .demo, prompts: prompts)
        #expect(demo.provider is SimulatedTransport)
        #expect(demo.ssh == nil)

        await #expect(throws: ConnectionFailure.unsupportedServer(detail: "This version of Marionette can’t connect to this kind of computer.")) {
            _ = try await ladder.connect(to: ComputerConfiguration(host: "pc.local", backendID: "rdp"), options: SessionOptions(), prompts: prompts, progress: { _ in })
        }
    }

    @Test func onlyModeAndProtocolFailuresFallThrough() {
        let high = ConnectionLadder.Step(backendID: "a", mode: .highPerformance)
        let standard = ConnectionLadder.Step(backendID: "a", mode: .standard)
        #expect(ConnectionLadder.shouldFallBack(after: .modeUnavailable(mode: .highPerformance, reason: .tunnelled), from: high, to: standard))
        #expect(ConnectionLadder.shouldFallBack(after: .busy(detail: ""), from: high, to: standard))
        for failure in [ConnectionFailure.cancelled, .authenticationFailed(detail: nil), .unreachable(host: "h", detail: ""), .hostKeyRejected(host: "h"), .localNetworkDenied] {
            #expect(!ConnectionLadder.shouldFallBack(after: failure, from: high, to: standard))
        }
    }

    @Test func theComputersOwnBackEndExplainsARefusalBetterThanThePlainerRung() {
        let own = ConnectionLadder.Step(backendID: BackendID.appleScreenSharing, mode: .standard)
        let vnc = ConnectionLadder.Step(backendID: BackendID.vnc, mode: .standard)
        let refused = ConnectionLadder.Fallback(step: own, failure: .unsupportedServer(detail: "the server does not encrypt the session"))
        let vague = ConnectionFailure.protocolViolation(detail: "this server requires the macOS Screen Sharing client")
        #expect(ConnectionLadder.explanation(for: vague, at: vnc, ownBackendID: BackendID.appleScreenSharing, after: [refused]) == refused.failure)
        // A plainer rung that got further (a wrong password) says something the first one could not.
        #expect(ConnectionLadder.explanation(for: .authenticationFailed(detail: nil), at: vnc, ownBackendID: BackendID.appleScreenSharing, after: [refused]) == .authenticationFailed(detail: nil))
        // Without an earlier refusal from the computer's own back end, the last failure stands.
        let highPerformance = ConnectionLadder.Fallback(step: own, failure: .modeUnavailable(mode: .highPerformance, reason: .tunnelled))
        #expect(ConnectionLadder.explanation(for: vague, at: vnc, ownBackendID: BackendID.appleScreenSharing, after: [highPerformance]) == vague)
    }

    @Test func aWrongPasswordIsNotRetriedOnTheNextRung() async throws {
        let fixture = try Fixture([fastScenario()], claimedModes: [.highPerformance, .standard])
        await #expect(throws: ConnectionFailure.cancelled) {
            _ = try await fixture.ladder.connect(
                to: fixture.computer, options: SessionOptions(),
                prompts: StaticPromptHandler(username: "demo", password: "wrong"), progress: { _ in }
            )
        }
        #expect(fixture.backend.attempts == 1)
    }

    @Test func savedCredentialsAnswerWithoutAsking() async throws {
        let secrets = InMemorySecretStore()
        let computer = ComputerConfiguration(host: "h", username: "me")
        try secrets.setSecret("pw", for: .remoteDesktopPassword(for: computer))
        let broker = PromptBroker(computer: computer, secrets: secrets)
        let response = await broker.resolve(.credentials(CredentialRequest(context: .remoteDesktop(host: "h"))))
        #expect(response == .credentials(username: "me", password: "pw"))
        #expect(broker.pending == nil)
    }

    @Test func hostKeysAlwaysReachTheUserAndCancellationAnswersCancel() async throws {
        let broker = PromptBroker(computer: ComputerConfiguration(host: "h", username: "me"), secrets: InMemorySecretStore())
        let challenge = HostKeyChallenge(host: "h", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:abc", status: .unknown)
        let asking = Task { await broker.resolve(.hostKey(challenge)) }
        try await waitUntil { broker.pending != nil }
        broker.reply(.trustHostKey(remember: true))
        #expect(await asking.value == .trustHostKey(remember: true))
        #expect(broker.pending == nil)

        let abandoned = Task { await broker.resolve(.hostKey(challenge)) }
        try await waitUntil { broker.pending != nil }
        abandoned.cancel()
        #expect(await abandoned.value == .cancel)
        try await waitUntil { broker.pending == nil }
    }
}

@MainActor
@Suite struct EnvironmentTests {
    @Test func everyCatalogNameResolves() {
        for name in ScenarioCatalog.names {
            #expect(ScenarioCatalog.setup(named: name) != nil, "\(name)")
        }
        #expect(ScenarioCatalog.setup(named: "nonsense") == nil)
    }

    @Test func launchArgumentsAreParsed() {
        let options = LaunchOptions(arguments: ["Marionette", "-MarionetteScenario", "drop", "-MarionetteUITestMode", "-MarionetteFoldOverride", "docked", "-AppleLanguages", "(en)"])
        #expect(options.scenarioName == "drop")
        #expect(options.isUITestMode)
        #expect(options.foldOverride == .docked)
        #expect(LaunchOptions(arguments: ["Marionette", "-MarionetteFoldOverride", "sideways"]).foldOverride == nil)
        #expect(LaunchOptions(arguments: ["Marionette"]) == LaunchOptions())
    }

    @Test func theSimulatedEnvironmentIsSeededAndConnects() async throws {
        let environment = await AppEnvironment.make(arguments: ["Marionette", "-MarionetteUITestMode"], pasteboard: InMemoryPasteboard())
        #expect(environment.library.items.map(\.configuration.displayName) == ["Studio Mac", "Mac mini", "Build Server", "jamies-macbook-air.local"])
        #expect(environment.library.items.prefix(3).allSatisfy { $0.record.thumbnail != nil })
        #expect(environment.library.items[0].record.lastMode == .highPerformance)
        #expect(environment.library.now == FixedClock.referenceDate)
        let session = environment.sessions.open(environment.autoConnectComputer)
        #expect(environment.sessions.presented === session)
        #expect(environment.sessions.open(environment.autoConnectComputer) === session, "a second open reuses the session")
        try await waitUntil { session.phase == .connected }
        session.disconnect()
        #expect(environment.sessions.sessions.isEmpty)
        #expect(environment.sessions.presented == nil)
    }

    @Test func theEmptyScenarioHasNoComputers() async {
        let environment = await AppEnvironment.make(arguments: ["Marionette", "-MarionetteScenario", "empty"], pasteboard: InMemoryPasteboard())
        #expect(environment.library.isEmpty)
        #expect(environment.autoConnectComputer == .demo)
    }

    @Test func aFailedSessionCanAskForTheEditor() async throws {
        let environment = await AppEnvironment.make(arguments: ["Marionette", "-MarionetteScenario", "unreachable"], pasteboard: InMemoryPasteboard())
        let session = environment.sessions.open(environment.autoConnectComputer)
        try await waitUntil { if case .failed = session.phase { true } else { false } }
        session.perform(.editConnection)
        #expect(environment.sessions.presented == nil)
        #expect(environment.sessions.editRequest == session.computer.id)
    }
}

@MainActor
@Suite struct TransferQueueTests {
    @Test func uploadsAndDownloadsThroughTheSimulatedFileSystem() async throws {
        var scenario = fastScenario()
        scenario.transferRate = 1 << 30
        let session = try await SimulatedBackend(scenario: scenario).connect(
            ConnectionRequest(transport: SimulatedTransport(), prompts: StaticPromptHandler(username: "demo", password: "demo"))
        )
        let files = try #require(session.capabilities.fileTransfer.value)
        let queue = TransferQueue()
        let folder = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appending(path: "hello.txt")
        try Data("hello".utf8).write(to: local)

        let failed = queue.upload(local)
        #expect(queue.items.first { $0.id == failed }?.state == .failed(message: "File transfer is not available."))
        queue.clearCompleted()

        queue.setTransfer(files)
        queue.upload(local)
        let entry = RemoteFileEntry(path: "/Users/demo/Documents/Readme.txt", name: "Readme.txt", isDirectory: false)
        queue.download(entry, to: folder.appending(path: "Readme.txt"))
        queue.download(RemoteFileEntry(path: "/nope", name: "nope", isDirectory: false), to: folder.appending(path: "nope"))
        #expect(queue.hasActiveTransfers)
        await queue.waitUntilIdle()
        #expect(queue.items.map(\.state).prefix(2) == [.finished, .finished])
        if case .failed = queue.items[2].state {} else { Issue.record("a missing file should fail") }
        #expect(try String(contentsOf: folder.appending(path: "Readme.txt"), encoding: .utf8) == "Hello from the demo Mac.\n")
        #expect(try await files.list(directory: "/Users/demo/Downloads").map(\.name) == ["hello.txt"])
        await session.disconnect()
    }
}
