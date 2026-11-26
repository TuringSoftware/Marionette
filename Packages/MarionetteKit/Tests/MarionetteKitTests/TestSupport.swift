// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopInteraction
import RemoteDesktopSimulated
import Synchronization
import Testing
@testable import MarionetteKit

/// A simulated back end that keeps the sessions it hands out, so tests can see what arrived.
final class RecordingBackend: RemoteDesktopBackend {
    let id: String
    let scenarios: [SimulationScenario]
    let claimedModes: [SessionMode]
    private let state = Mutex<(attempts: Int, sessions: [SimulatedSession])>((0, []))

    /// `id` lets it stand in for another back end, such as the VNC rung under a Mac's.
    init(_ scenarios: [SimulationScenario], claimedModes: [SessionMode]? = nil, id: String = SimulatedBackend.backendID) {
        self.id = id
        self.scenarios = scenarios
        self.claimedModes = claimedModes ?? scenarios[0].offeredModes
    }

    var descriptor: BackendDescriptor {
        BackendDescriptor(id: id, displayName: "Test", defaultPort: 5900, bonjourServiceType: nil, supportedModes: claimedModes)
    }

    var sessions: [SimulatedSession] { state.withLock { $0.sessions } }
    var attempts: Int { state.withLock { $0.attempts } }

    func connect(_ request: ConnectionRequest) async throws(ConnectionFailure) -> any RemoteSession {
        let index = state.withLock { state in
            defer { state.attempts += 1 }
            return min(state.attempts, scenarios.count - 1)
        }
        let session = try await SimulatedBackend(scenario: scenarios[index]).connectSimulated(request)
        state.withLock { $0.sessions.append(session) }
        return session
    }
}

func fastScenario(_ base: SimulationScenario = .highPerformance) -> SimulationScenario {
    var scenario = base
    scenario.phaseDelay = .milliseconds(1)
    scenario.reconfigurationDelay = .milliseconds(5)
    scenario.frameRate = 30
    scenario.playsTone = false
    scenario.fileDrags?.refusalDelay = .milliseconds(20)
    scenario.displays = scenario.displays.map {
        SimulationScenario.Display(name: $0.name, pixelSize: PixelSize(width: $0.pixelSize.width / 4, height: $0.pixelSize.height / 4), scale: $0.scale)
    }
    return scenario
}

/// A session model wired to a recording back end, with everything else in memory.
@MainActor
struct Fixture {
    let backend: RecordingBackend
    let secrets = InMemorySecretStore()
    let pasteboard = InMemoryPasteboard()
    let repository: ComputerRepository
    let defaults: UserDefaults
    var computer: ComputerConfiguration
    /// A plain VNC back end, registered as the last rung under the Mac's.
    var vnc: RecordingBackend?
    var reconnection = ReconnectionPolicy(attempts: 2, initialDelay: .milliseconds(5), maximumDelay: .milliseconds(5), jitter: 0)
    var clipboardPollInterval: Duration = .seconds(1)
    var controlsHandleTimeout: Duration? = .seconds(4)
    /// Where received files go; the temporary directory when `nil`.
    var downloadsDirectory: URL?

    init(_ scenarios: [SimulationScenario] = [fastScenario()], claimedModes: [SessionMode]? = nil, savePassword: Bool = true) throws {
        backend = RecordingBackend(scenarios, claimedModes: claimedModes)
        repository = ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true))
        let suite = "MarionetteKitTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        computer = ComputerConfiguration(name: "Test Mac", host: "test.local", username: "demo", display: .remoteDisplays)
        repository.save(computer, now: Date(timeIntervalSince1970: 0))
        if savePassword {
            try secrets.setSecret("demo", for: .remoteDesktopPassword(for: computer))
        }
    }

    var ladder: ConnectionLadder {
        var registry = BackendRegistry()
        registry.register(backend)
        if let vnc { registry.register(vnc) }
        registry.fallbackBackendID = SimulatedBackend.backendID
        return ConnectionLadder(registry: registry, transports: SimulatedTransportFactory())
    }

    func makeModel() -> SessionModel {
        var dependencies = SessionModel.Dependencies(
            ladder: ladder, secrets: secrets, pasteboard: pasteboard, clock: SystemClock(), repository: repository, defaults: defaults
        )
        dependencies.mutesAudio = true
        dependencies.bannerDuration = nil
        dependencies.reconnection = reconnection
        dependencies.clipboardPollInterval = clipboardPollInterval
        dependencies.controlsHandleTimeout = controlsHandleTimeout
        if let downloadsDirectory { dependencies.downloadsDirectory = { downloadsDirectory } }
        return SessionModel(computer: computer, dependencies: dependencies)
    }

    /// A started model, laid out in a 400×300 pt view once `condition` holds. For sessions that end
    /// by themselves soon after connecting, where waiting for `.connected` can miss it on a loaded machine.
    func startedModel(until condition: @escaping @MainActor (SessionModel) -> Bool) async throws -> SessionModel {
        let model = makeModel()
        model.start()
        try await waitUntil { condition(model) }
        model.stageLayoutChanged(size: CGSize(width: 400, height: 300), safeArea: .zero, deviceScale: 2)
        return model
    }

    /// A model that is connected and laid out in a 400×300 pt view.
    func connectedModel() async throws -> SessionModel {
        let model = makeModel()
        model.start()
        try await waitUntil { model.phase == .connected }
        model.stageLayoutChanged(size: CGSize(width: 400, height: 300), safeArea: .zero, deviceScale: 2)
        return model
    }
}

struct TimedOut: Error {}

/// Polls a main-actor condition until it holds.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
            throw TimedOut()
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Polls an asynchronous main-actor condition until it holds.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        if ContinuousClock.now > deadline {
            Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
            throw TimedOut()
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

extension InputEvent {
    var pointer: PointerEvent? {
        if case .pointer(let event) = self { event } else { nil }
    }

    var key: KeyEvent? {
        if case .key(let event) = self { event } else { nil }
    }

    var touch: TouchEvent? {
        if case .touch(let event) = self { event } else { nil }
    }
}

func tap(at point: ViewPoint, time: Double = 1) -> [[TouchSample]] {
    [
        [TouchSample(id: 1, phase: .began, location: point, timestamp: time)],
        [TouchSample(id: 1, phase: .ended, location: point, timestamp: time + 0.05)],
    ]
}
