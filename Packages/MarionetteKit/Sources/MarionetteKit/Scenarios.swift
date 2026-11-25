// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
public import RemoteDesktopCore
public import RemoteDesktopSimulated
import Synchronization

/// A simulated back end whose behaviour changes from one connection to the next, and which can claim
/// modes its scenario then refuses — which is how the fallback ladder and reconnection are exercised.
public final class ScriptedBackend: RemoteDesktopBackend {
    /// The scenario for the first connection, the second, and so on. The last one repeats.
    public let scenarios: [SimulationScenario]
    public let claimedModes: [SessionMode]
    private let attempts = Mutex(0)

    public init(scenarios: [SimulationScenario], claimedModes: [SessionMode]? = nil) {
        precondition(!scenarios.isEmpty)
        self.scenarios = scenarios
        self.claimedModes = claimedModes ?? scenarios[0].offeredModes
    }

    public var descriptor: BackendDescriptor {
        BackendDescriptor(
            id: SimulatedBackend.backendID,
            displayName: "Demo",
            defaultPort: 5900,
            bonjourServiceType: nil,
            supportedModes: claimedModes
        )
    }

    public func connect(_ request: ConnectionRequest) async throws(ConnectionFailure) -> any RemoteSession {
        let index = attempts.withLock { count in
            defer { count += 1 }
            return min(count, scenarios.count - 1)
        }
        return try await SimulatedBackend(scenario: scenarios[index]).connect(request)
    }
}

/// Everything a named test scenario changes: how the simulated machine behaves and what the seeded
/// library looks like.
public struct ScenarioSetup: Sendable {
    public enum Seed: Sendable, Hashable {
        /// No saved computers: the empty library.
        case empty
        /// A handful of computers with thumbnails.
        case populated
    }

    /// Scenario per connection attempt; the last repeats.
    public var scenarios: [SimulationScenario]
    public var claimedModes: [SessionMode]?
    public var seed: Seed = .populated
    /// Whether seeded computers have their password saved, so connecting needs no prompt.
    public var savesPasswords = true
    /// Saves a wrong password instead, which makes the credential prompt show its retry error.
    public var savesWrongPassword = false
    /// Changes applied to the first seeded computer (the one tests connect to).
    public var primaryComputer: @Sendable (inout ComputerConfiguration) -> Void = { _ in }
    public var discoveryDenied = false
    /// What looking for computers on the network finds.
    public var discovered = SimulatedDiscoveryProvider.sampleComputers
    /// Gives the environment a pretend SSH server, so "Sign In over SSH" is offered for files.
    public var providesSSH = false

    public init(_ scenario: SimulationScenario) {
        scenarios = [scenario]
    }

    /// A new back end that plays this setup from its first connection.
    public func makeBackend() -> ScriptedBackend {
        ScriptedBackend(scenarios: scenarios, claimedModes: claimedModes)
    }
}

/// The scenarios selectable with `-MarionetteScenario <name>`.
public enum ScenarioCatalog {
    public static let defaultName = "hp"

    public static let names = [
        "hp", "standard", "ssh", "vnc", "two-displays", "tone", "empty", "slow", "credentials", "bad-password",
        "host-key", "host-key-changed", "session-select", "keyboard-interactive", "unreachable", "hp-unavailable",
        "fallback", "unreliable-network", "fit-to-device", "busy", "tunnel-failed", "local-network-denied", "drop",
        "remote-closed", "files-send-only", "file-drag", "remote-drag",
    ]

    /// A screen-sized desktop that fills quickly and animates gently.
    private static var base: SimulationScenario {
        var scenario = SimulationScenario.highPerformance
        scenario.remoteName = "Studio Mac"
        scenario.playsTone = false
        scenario.frameRate = 10
        scenario.initialRemoteClipboard = "Copied on the Mac"
        return scenario
    }

    private static let hostKey = HostKeyChallenge(
        host: "studio-mac.local",
        port: 22,
        algorithm: "ssh-ed25519",
        fingerprint: "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s",
        status: .unknown
    )

    public static func setup(named name: String) -> ScenarioSetup? {
        var scenario = base
        switch name {
        case "hp":
            return ScenarioSetup(scenario)
        case "standard":
            scenario.offeredModes = [.standard]
            return ScenarioSetup(scenario)
        case "ssh":
            var setup = ScenarioSetup(scenario)
            setup.primaryComputer = { $0.tunnel.isEnabled = true }
            return setup
        case "vnc":
            var vnc = SimulationScenario.genericVNC
            vnc.frameRate = 10
            return ScenarioSetup(vnc)
        case "two-displays":
            scenario.displays = SimulationScenario.twoDisplays.displays
            return ScenarioSetup(scenario)
        case "tone":
            scenario.playsTone = true
            return ScenarioSetup(scenario)
        case "empty":
            var setup = ScenarioSetup(scenario)
            setup.seed = .empty
            setup.discovered = []
            return setup
        case "first-launch":
            var setup = ScenarioSetup(scenario)
            setup.seed = .empty
            return setup
        case "slow":
            scenario.phaseDelay = .seconds(600)
            return ScenarioSetup(scenario)
        case "credentials":
            var setup = ScenarioSetup(scenario)
            setup.savesPasswords = false
            return setup
        case "bad-password":
            var setup = ScenarioSetup(scenario)
            setup.savesWrongPassword = true
            return setup
        case "host-key", "host-key-changed":
            var challenge = hostKey
            if name == "host-key-changed" {
                challenge.status = .changed(previousFingerprint: "SHA256:Zk3mY9pQ0aV7dL1xT5uHc2rNw8eBf4GjS6oKiPqRs0A")
            }
            scenario.tunnelPrompts = [.hostKey(challenge)]
            var setup = ScenarioSetup(scenario)
            setup.primaryComputer = { $0.tunnel.isEnabled = true }
            return setup
        case "keyboard-interactive":
            scenario.tunnelPrompts = [
                .keyboardInteractive(
                    KeyboardInteractiveRequest(
                        context: .sshTunnel(host: "studio-mac.local"),
                        title: "Two-Factor Authentication",
                        instruction: "Enter the code from your authenticator app.",
                        questions: [.init(text: "Verification code", echoesInput: true)]
                    )
                ),
            ]
            var setup = ScenarioSetup(scenario)
            setup.primaryComputer = { $0.tunnel.isEnabled = true }
            return setup
        case "session-select":
            scenario.consoleUser = "Alex"
            return ScenarioSetup(scenario)
        case "session-select-declined":
            scenario.consoleUser = "Alex"
            scenario.consoleDeclines = 1
            return ScenarioSetup(scenario)
        case "session-select-waiting":
            scenario.consoleUser = "Alex"
            scenario.consoleAnswerDelay = .seconds(600)
            return ScenarioSetup(scenario)
        case "unreachable":
            scenario.failure = (.reachingHost, .unreachable(host: "studio-mac.local", detail: ""))
            return ScenarioSetup(scenario)
        case "hp-unavailable":
            scenario.offeredModes = [.standard]
            var setup = ScenarioSetup(scenario)
            setup.claimedModes = [.highPerformance, .standard]
            setup.primaryComputer = { $0.mode = .highPerformance }
            return setup
        case "fallback":
            scenario.offeredModes = [.standard]
            var setup = ScenarioSetup(scenario)
            setup.claimedModes = [.highPerformance, .standard]
            return setup
        case "unreliable-network":
            scenario.failure = (.startingMedia, .modeUnavailable(mode: .highPerformance, reason: .unreliableNetwork))
            var setup = ScenarioSetup(scenario)
            setup.claimedModes = [.highPerformance, .standard]
            return setup
        case "fit-to-device":
            var setup = ScenarioSetup(scenario)
            setup.primaryComputer = { $0.display = .fitToDevice }
            return setup
        case "busy":
            scenario.failure = (.startingMedia, .busy(detail: "Someone else is already viewing this Mac in High Performance mode."))
            var setup = ScenarioSetup(scenario)
            setup.primaryComputer = { $0.mode = .highPerformance }
            return setup
        case "tunnel-failed":
            scenario.failure = (.openingTunnel, .tunnelFailed(detail: "The SSH server refused the connection."))
            var setup = ScenarioSetup(scenario)
            setup.primaryComputer = { $0.tunnel.isEnabled = true }
            return setup
        case "local-network-denied":
            scenario.failure = (.reachingHost, .localNetworkDenied)
            var setup = ScenarioSetup(scenario)
            setup.discoveryDenied = true
            return setup
        case "drop":
            // The first session drops after a moment; reconnecting then takes long enough to look at.
            var first = scenario
            first.disconnect = (.seconds(3), .connectionLost(detail: ""))
            var later = scenario
            later.phaseDelay = .seconds(600)
            var setup = ScenarioSetup(first)
            setup.scenarios = [first, later]
            return setup
        case "files-send-only":
            // File transfer that sends but cannot browse, as Screen Sharing's own does.
            scenario.fileTransferCanBrowse = false
            var setup = ScenarioSetup(scenario)
            setup.providesSSH = true
            return setup
        case "file-drag", "remote-drag":
            // A file on the Mac's desktop that takes a few seconds to move, so that transfers can
            // be watched. In "remote-drag" the Mac picks it up by itself a moment after
            // connecting, with another, for looking at the drop well without touching the screen.
            let movie = "/Users/demo/Documents/Holiday.mov"
            scenario.files.append(SimulationScenario.RemoteFile(path: movie, contents: [UInt8](repeating: 0x4D, count: 384 * 1024)))
            scenario.transferRate = 96 * 1024
            scenario.fileDrags?.file = movie
            if name == "remote-drag" {
                scenario.fileDrags?.automaticDrag = (.seconds(1), [movie, "/Users/demo/Documents/Readme.txt"])
            }
            return ScenarioSetup(scenario)
        case "remote-closed":
            scenario.disconnect = (.seconds(3), .remoteClosed(detail: nil))
            return ScenarioSetup(scenario)
        default:
            return nil
        }
    }
}
