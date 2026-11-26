// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
import RemoteDesktopConformance
import RemoteDesktopCore
import RemoteDesktopSimulated
import Synchronization
import Testing

/// Records prompts and answers them from a script.
private final class ScriptedPrompts: PromptHandler {
    private let state: Mutex<(answers: [PromptResponse], seen: [SessionPrompt])>

    init(_ answers: [PromptResponse]) {
        state = Mutex((answers, []))
    }

    var seen: [SessionPrompt] { state.withLock { $0.seen } }

    func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        state.withLock { state in
            state.seen.append(prompt)
            return state.answers.isEmpty ? .cancel : state.answers.removeFirst()
        }
    }
}

private func fastScenario(_ base: SimulationScenario = .highPerformance) -> SimulationScenario {
    var scenario = base
    scenario.phaseDelay = .milliseconds(1)
    scenario.reconfigurationDelay = .milliseconds(5)
    scenario.frameRate = 60
    scenario.displays = scenario.displays.map {
        // Small surfaces keep the suite quick; geometry behaviour does not depend on size.
        SimulationScenario.Display(name: $0.name, pixelSize: PixelSize(width: $0.pixelSize.width / 4, height: $0.pixelSize.height / 4), scale: $0.scale)
    }
    return scenario
}

private func request(
    _ options: SessionOptions = SessionOptions(),
    tunnelled: Bool = false,
    prompts: any PromptHandler = StaticPromptHandler(username: "demo", password: "demo"),
    progress: @escaping @Sendable (ConnectionPhase) -> Void = { _ in }
) -> ConnectionRequest {
    ConnectionRequest(options: options, transport: SimulatedTransport(isTunnelled: tunnelled), prompts: prompts, progress: progress)
}

@Suite struct SimulatedBackendConformanceTests {
    @Test(arguments: BackendConformance.allChecks)
    func highPerformance(check: BackendConformance.Check) async throws {
        let suite = BackendConformance(backend: SimulatedBackend(scenario: fastScenario()), timeout: .seconds(5)) { request() }
        try await suite.run(check)
    }

    @Test(arguments: BackendConformance.allChecks)
    func standardThroughTunnel(check: BackendConformance.Check) async throws {
        let suite = BackendConformance(backend: SimulatedBackend(scenario: fastScenario(.standard)), timeout: .seconds(5)) {
            request(tunnelled: true)
        }
        try await suite.run(check)
    }

    @Test(arguments: BackendConformance.allChecks)
    func twoDisplays(check: BackendConformance.Check) async throws {
        let suite = BackendConformance(backend: SimulatedBackend(scenario: fastScenario(.twoDisplays)), timeout: .seconds(5)) { request() }
        try await suite.run(check)
    }
}

@Suite struct SimulatedConnectionTests {
    @Test func reportsPhasesInOrder() async throws {
        let phases = Mutex<[ConnectionPhase]>([])
        let session = try await SimulatedBackend(scenario: fastScenario()).connect(request(progress: { phase in
            phases.withLock { $0.append(phase) }
        }))
        await session.disconnect()
        #expect(phases.withLock { $0 } == [.reachingHost, .negotiating, .authenticating, .preparingDisplays, .startingMedia])
    }

    @Test func automaticModeFallsBackWhenTunnelled() async throws {
        let backend = SimulatedBackend(scenario: fastScenario())
        let direct = try await backend.connect(request())
        #expect(direct.info.mode == .highPerformance)
        #expect(direct.capabilities.audio.isAvailable)
        await direct.disconnect()

        let tunnelled = try await backend.connect(request(tunnelled: true))
        #expect(tunnelled.info.mode == .standard)
        #expect(tunnelled.info.isTunnelled)
        #expect(tunnelled.capabilities.audio.unavailableReason == .tunnelled)
        #expect(tunnelled.capabilities.quality.isAvailable)
        await tunnelled.disconnect()
    }

    @Test func requiringHighPerformanceThroughTunnelFailsWithReason() async {
        let backend = SimulatedBackend(scenario: fastScenario())
        await #expect(throws: ConnectionFailure.modeUnavailable(mode: .highPerformance, reason: .tunnelled)) {
            _ = try await backend.connect(request(SessionOptions(mode: .require(.highPerformance)), tunnelled: true))
        }
    }

    @Test func wrongPasswordIsRetriedWithExplanationThenFails() async {
        let prompts = ScriptedPrompts([
            .credentials(username: "demo", password: "nope"),
            .credentials(username: "demo", password: "still no"),
            .credentials(username: "demo", password: "wrong"),
        ])
        await #expect(throws: ConnectionFailure.authenticationFailed(detail: "The user name or password is incorrect.")) {
            _ = try await SimulatedBackend(scenario: fastScenario()).connect(request(prompts: prompts))
        }
        let attempts = prompts.seen.compactMap { prompt -> CredentialRequest? in
            if case .credentials(let request) = prompt { request } else { nil }
        }
        #expect(attempts.map(\.attempt) == [1, 2, 3])
        #expect(attempts[0].previousFailure == nil)
        #expect(attempts[1].previousFailure != nil)
    }

    @Test func secondPasswordAttemptCanSucceed() async throws {
        let prompts = ScriptedPrompts([
            .credentials(username: "demo", password: "typo"),
            .credentials(username: "demo", password: "demo"),
        ])
        let session = try await SimulatedBackend(scenario: fastScenario()).connect(request(prompts: prompts))
        #expect(session.state == .connected)
        await session.disconnect()
    }

    @Test func decliningCredentialsCancels() async {
        await #expect(throws: ConnectionFailure.cancelled) {
            _ = try await SimulatedBackend(scenario: fastScenario()).connect(request(prompts: ScriptedPrompts([.cancel])))
        }
    }

    @Test func consoleUserTriggersSessionSelect() async throws {
        var scenario = fastScenario()
        scenario.consoleUser = "someone-else"
        let prompts = ScriptedPrompts([.credentials(username: "demo", password: "demo"), .sessionChoice(.askToShareConsole)])
        let phases = Mutex<[ConnectionPhase]>([])
        let session = try await SimulatedBackend(scenario: scenario).connect(request(prompts: prompts, progress: { phase in
            phases.withLock { $0.append(phase) }
        }))
        await session.disconnect()
        #expect(prompts.seen.count == 2)
        guard case .sessionSelect(let select) = prompts.seen[1] else {
            Issue.record("expected a session-select prompt")
            return
        }
        #expect(select.consoleUser == "someone-else")
        #expect(phases.withLock { $0 }.contains(.waitingForRemoteUser))
    }

    @Test func aDeclinedRequestAsksAgainAndSaysSo() async throws {
        var scenario = fastScenario()
        scenario.consoleUser = "someone-else"
        scenario.consoleDeclines = 1
        let prompts = ScriptedPrompts([
            .credentials(username: "demo", password: "demo"), .sessionChoice(.askToShareConsole), .sessionChoice(.logInAsSelf),
        ])
        let session = try await SimulatedBackend(scenario: scenario).connect(request(prompts: prompts))
        await session.disconnect()
        let selects = prompts.seen.compactMap { prompt -> SessionSelectRequest? in
            if case .sessionSelect(let request) = prompt { request } else { nil }
        }
        #expect(selects.map(\.previousRequestDeclined) == [false, true])
    }

    @Test func injectedFailureSurfacesAtItsPhase() async {
        var scenario = fastScenario()
        scenario.failure = (.negotiating, .unsupportedServer(detail: "too old"))
        let phases = Mutex<[ConnectionPhase]>([])
        await #expect(throws: ConnectionFailure.unsupportedServer(detail: "too old")) {
            _ = try await SimulatedBackend(scenario: scenario).connect(request(progress: { phase in
                phases.withLock { $0.append(phase) }
            }))
        }
        #expect(phases.withLock { $0 } == [.reachingHost, .negotiating])
    }

    @Test func scheduledDisconnectIsAnnouncedWithReason() async throws {
        var scenario = fastScenario()
        scenario.disconnect = (.milliseconds(30), .connectionLost(detail: "simulated"))
        let session = try await SimulatedBackend(scenario: scenario).connect(request())
        var last: SessionState?
        for await event in session.events() {
            if case .stateChanged(let state) = event { last = state }
        }
        #expect(last == .disconnected(.connectionLost(detail: "simulated")))
        #expect(session.state.isDisconnected)
    }
}

@Suite struct SimulatedSessionBehaviourTests {
    private func connect(_ scenario: SimulationScenario = fastScenario(), options: SessionOptions = SessionOptions()) async throws -> SimulatedSession {
        try await SimulatedBackend(scenario: scenario).connectSimulated(request(options))
    }

    @Test func inputArrivesInOrderAndIsEchoedIntoAFrame() async throws {
        let session = try await connect()
        let display = try #require(session.layout.displays.first)
        let frames = session.frames(for: display.id)
        _ = await frames.next()

        let events: [InputEvent] = [
            .key(KeyEvent(key: .h, characters: "h", phase: .down)),
            .key(KeyEvent(key: .h, characters: "h", phase: .up)),
            .text("ello"),
            .pointer(PointerEvent(display: display.id, position: PixelPoint(x: 40, y: 30), buttons: .primary, layoutGeneration: session.layout.generation)),
            .pointer(PointerEvent(display: display.id, position: PixelPoint(x: 40, y: 30), layoutGeneration: session.layout.generation)),
        ]
        for event in events { session.input.send(event) }
        await session.waitForInputToBeRendered()

        #expect(session.receivedInput == events)
        let frame = try #require(await frames.next())
        #expect(!frame.damage.isEmpty)
        await session.disconnect()
    }

    @Test func pointerMovesTheCursorInDesktopCoordinates() async throws {
        let session = try await connect(fastScenario(.twoDisplays))
        let second = try #require(session.layout.displays.last)
        var iterator = session.cursor().makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial.image != nil)

        session.input.send(.pointer(PointerEvent(display: second.id, position: PixelPoint(x: 10, y: 20), layoutGeneration: session.layout.generation)))
        let moved = try #require(await iterator.next())
        #expect(moved.position == PixelPoint(x: Double(second.frameInDesktop.x) + 10, y: 20))
        await session.disconnect()
    }

    @Test func pointerForAnOldLayoutDoesNotMoveTheCursor() async throws {
        let session = try await connect()
        let display = try #require(session.layout.displays.first)
        let stale = session.layout.generation - 1
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 5, y: 5), layoutGeneration: stale)))
        var iterator = session.cursor().makeAsyncIterator()
        #expect(await iterator.next()?.position == nil)
        await session.disconnect()
    }

    @Test func observeModeDiscardsInput() async throws {
        let session = try await connect(options: SessionOptions(controlMode: .observe))
        session.input.send(.text("should not arrive"))
        #expect(session.receivedInput.isEmpty)
        try await session.capabilities.control.value?.setControlMode(.control)
        session.input.send(.text("now it does"))
        #expect(session.receivedInput == [.text("now it does")])
        await session.disconnect()
    }

    @Test func virtualDisplayResizeKeepsIdentityAndBumpsGeneration() async throws {
        let session = try await connect()
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        #expect(configuration.limits.maximumVirtualDisplays == 2)
        let before = session.layout
        let id = try #require(before.displays.first?.id)
        let frames = session.frames(for: id)
        _ = await frames.next()

        try await configuration.setVirtualDisplays([VirtualDisplayRequest(pointSize: PixelSize(width: 900, height: 700), scale: 2)])
        let after = session.layout
        #expect(after.generation > before.generation)
        #expect(after.displays.map(\.id) == [id])
        #expect(after.displays.first?.pixelSize == PixelSize(width: 1800, height: 1400))
        #expect(after.displays.first?.kind == .virtual)
        #expect(after.displays.first?.state == .live)

        // The existing subscription keeps working and sees the new size with full damage.
        var resized: DisplayFrame?
        while let frame = await frames.next() {
            if frame.layoutGeneration == after.generation {
                resized = frame
                break
            }
        }
        #expect(resized?.pixelSize == PixelSize(width: 1800, height: 1400))
        #expect(resized?.damage.bounds == PixelRect(x: 0, y: 0, width: 1800, height: 1400))
        await session.disconnect()
    }

    @Test func rapidResizesApplyOnlyTheLast() async throws {
        var scenario = fastScenario()
        // Every request must come while the first is still being applied; 5 ms sleeps can take
        // tens of milliseconds on a loaded machine.
        scenario.reconfigurationDelay = .seconds(1)
        let session = try await connect(scenario)
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        let generationBefore = session.layout.generation
        try await withThrowingTaskGroup(of: Void.self) { group in
            for width in [800, 900, 1000, 1100] {
                group.addTask {
                    try await configuration.setVirtualDisplays([VirtualDisplayRequest(pointSize: PixelSize(width: width, height: 600), scale: 1)])
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            try await group.waitForAll()
        }
        #expect(session.layout.displays.first?.pixelSize == PixelSize(width: 1100, height: 600))
        #expect(session.layout.generation == generationBefore + 1)
        await session.disconnect()
    }

    @Test func undersizedVirtualDisplayIsRefused() async throws {
        let session = try await connect()
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        await #expect(throws: SimulationError.displayTooSmall(minimum: PixelSize(width: 800, height: 600))) {
            try await configuration.setVirtualDisplays([VirtualDisplayRequest(pointSize: PixelSize(width: 400, height: 300))])
        }
        await #expect(throws: SimulationError.tooManyDisplays(maximum: 2)) {
            try await configuration.setVirtualDisplays(Array(repeating: VirtualDisplayRequest(pointSize: PixelSize(width: 800, height: 600)), count: 3))
        }
        await session.disconnect()
    }

    @Test func selectingOnePhysicalDisplayEndsTheOthersFrames() async throws {
        let session = try await connect(fastScenario(.twoDisplays))
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        let ids = session.layout.displays.map(\.id)
        #expect(ids.count == 2)
        let secondFrames = session.frames(for: ids[1])
        _ = await secondFrames.next()

        try await configuration.selectPhysicalDisplays(.single(ids[0]))
        #expect(session.layout.displays.map(\.id) == [ids[0]])
        var ended = false
        while true {
            guard await secondFrames.next() != nil else {
                ended = true
                break
            }
        }
        #expect(ended)
        await session.disconnect()
    }

    @Test func clipboardRoundTripWithoutEcho() async throws {
        var scenario = fastScenario()
        scenario.initialRemoteClipboard = "from remote"
        let session = try await connect(scenario)
        let clipboard = try #require(session.capabilities.clipboard.value)

        var offers = clipboard.remoteOffers().makeAsyncIterator()
        let first = try #require(await offers.next())
        #expect(try await first.load().first?.text == "from remote")

        try await clipboard.sendToRemote([ClipboardItem(text: "from local")])
        #expect(session.remoteClipboard.first?.text == "from local")

        session.simulateRemoteCopy("remote again")
        let next = try #require(await offers.next())
        #expect(next.changeCount > first.changeCount)
        // The offer after our own write is the remote's copy, not an echo of what we sent.
        #expect(try await next.load().first?.text == "remote again")
        await session.disconnect()
    }

    @Test func fileTransferRoundTrip() async throws {
        var scenario = fastScenario()
        scenario.transferRate = 10_000_000
        let session = try await connect(scenario)
        let files = try #require(session.capabilities.fileTransfer.value)
        #expect(try await files.list(directory: "/Users/demo").map(\.name) == ["Documents", "Pictures"])
        #expect(try await files.list(directory: "/Users/demo/Documents").map(\.name) == ["Notes.txt", "Readme.txt"])

        let folder = FileManager.default.temporaryDirectory.appending(path: "marionette-sim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let payload = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let local = folder.appending(path: "payload.bin")
        try payload.write(to: local)

        var lastProgress: TransferProgress?
        let uploads = try await files.defaultUploadDirectory()
        for try await progress in files.upload(from: local, toDirectory: uploads) { lastProgress = progress }
        #expect(lastProgress?.fraction == 1)
        #expect(try await files.list(directory: uploads).map(\.name) == ["payload.bin"])

        let copy = folder.appending(path: "copy.bin")
        for try await _ in files.download(uploads + "/payload.bin", to: copy) {}
        #expect(try Data(contentsOf: copy) == payload)

        await #expect(throws: SimulationError.noSuchFile("/nope")) {
            for try await _ in files.download("/nope", to: copy) {}
        }
        await session.disconnect()
    }

    @Test func audioProducesPacedStereoChunks() async throws {
        let session = try await connect()
        let audio = try #require(session.capabilities.audio.value)
        var received: [AudioChunk] = []
        for await chunk in audio.chunks() {
            received.append(chunk)
            if received.count == 5 { break }
        }
        #expect(received.allSatisfy { $0.channelCount == 2 && $0.frameCount == 480 && $0.sampleRate == 48_000 })
        let nonSilent = received[0].samples.withUnsafeBytes { $0.bindMemory(to: Float32.self).contains { $0 != 0 } }
        #expect(nonSilent)
        await session.disconnect()
    }

    @Test func suspendStopsFramesAndInput() async throws {
        let session = try await connect()
        let display = try #require(session.layout.displays.first)
        let frames = session.frames(for: display.id)
        _ = await frames.next()
        await session.suspend()
        #expect(session.state == .suspended)
        session.input.send(.text("dropped"))
        #expect(session.receivedInput.isEmpty)

        let whileSuspended = Task { await frames.next() }
        try await Task.sleep(for: .milliseconds(80))
        whileSuspended.cancel()
        #expect(await whileSuspended.value == nil)

        await session.resume()
        #expect(session.state == .connected)
        #expect(await frames.next() != nil)
        await session.disconnect()
    }

    @Test func frameCounterAnimatesWithSmallDamage() async throws {
        let session = try await connect()
        let display = try #require(session.layout.displays.first)
        let frames = session.frames(for: display.id)
        let first = try #require(await frames.next())
        #expect(first.damage.bounds == PixelRect(size: display.pixelSize))
        let second = try #require(await frames.next())
        #expect(second.sequence > first.sequence)
        #expect(second.damage.bounds.area < display.pixelSize.width * display.pixelSize.height / 4)
        await session.disconnect()
    }

    @Test func droppingTheSessionEndsIt() async throws {
        var events: AsyncStream<SessionEvent>?
        do {
            let session = try await connect()
            events = session.events()
        }
        var sawDisconnect = false
        for await event in try #require(events) {
            if case .stateChanged(.disconnected) = event { sawDisconnect = true }
        }
        #expect(sawDisconnect)
    }
}
