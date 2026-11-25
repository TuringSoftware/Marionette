// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import RemoteDesktopSimulated
import Synchronization
import Testing

private final class RecordingPrompts: PromptHandler {
    private let state: Mutex<[SessionPrompt]> = Mutex([])
    private let trustsHostKey: Bool

    init(trustsHostKey: Bool) {
        self.trustsHostKey = trustsHostKey
    }

    var seen: [SessionPrompt] { state.withLock { $0 } }

    func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        state.withLock { $0.append(prompt) }
        switch prompt {
        case .hostKey: return trustsHostKey ? .trustHostKey(remember: true) : .cancel
        case .credentials: return .credentials(username: "demo", password: "demo")
        default: return .cancel
        }
    }
}

@Suite struct SimulatedTunnelPromptTests {
    private static let challenge = HostKeyChallenge(
        host: "demo.local", port: 22, algorithm: "ssh-ed25519",
        fingerprint: "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s", status: .unknown
    )

    private func scenario() -> SimulationScenario {
        var scenario = SimulationScenario.standard
        scenario.phaseDelay = .milliseconds(1)
        scenario.frameRate = 0
        scenario.displays = [.init(name: "Display", pixelSize: PixelSize(width: 320, height: 200))]
        scenario.tunnelPrompts = [.hostKey(Self.challenge)]
        return scenario
    }

    @Test func tunnelPromptsAreAskedBeforeCredentialsWhenTunnelled() async throws {
        let prompts = RecordingPrompts(trustsHostKey: true)
        let session = try await SimulatedBackend(scenario: scenario()).connect(
            ConnectionRequest(transport: SimulatedTransport(isTunnelled: true), prompts: prompts)
        )
        await session.disconnect()
        #expect(prompts.seen.first == .hostKey(Self.challenge))
        #expect(prompts.seen.count == 2)
    }

    @Test func tunnelPromptsAreSkippedOnADirectConnection() async throws {
        let prompts = RecordingPrompts(trustsHostKey: false)
        let session = try await SimulatedBackend(scenario: scenario()).connect(
            ConnectionRequest(transport: SimulatedTransport(), prompts: prompts)
        )
        await session.disconnect()
        #expect(prompts.seen.count == 1)
    }

    @Test func decliningTheHostKeyRejectsTheHost() async {
        let prompts = RecordingPrompts(trustsHostKey: false)
        await #expect(throws: ConnectionFailure.hostKeyRejected(host: "demo.local")) {
            _ = try await SimulatedBackend(scenario: scenario()).connect(
                ConnectionRequest(transport: SimulatedTransport(isTunnelled: true), prompts: prompts)
            )
        }
    }
}
