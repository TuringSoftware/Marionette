// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
import RemoteDesktopCore
import AppleScreenSharing
import VNCBackend
import RemoteDesktopSimulated
import SwiftData

/// How the two panes of a session are laid out when a test stands in for the hinge.
public enum FoldOverride: String, Sendable, Hashable {
    /// Laptop pose: remote display above the fold, input deck below.
    case docked
    /// Book pose, partly open: the fold runs vertically and the deck stays overlaid.
    case book
}

/// What the launch arguments ask for.
public struct LaunchOptions: Sendable, Hashable {
    /// `-MarionetteScenario <name>`: run against the simulated back end in the named scenario.
    public var scenarioName: String?
    /// `-MarionetteUITestMode`: no animations, fixed clock, seeded in-memory store, silent audio.
    public var isUITestMode = false
    /// `-MarionetteFoldOverride docked|book`.
    public var foldOverride: FoldOverride?
    /// `-MarionetteAutoConnect`: open a session with the first computer at launch (screenshots).
    public var autoConnect = false
    /// `-MarionetteAppearance light|dark`: force the appearance (screenshots; UI tests do not reliably
    /// inherit the simulator's setting).
    public var appearance: Appearance?
    /// `-MarionetteClipboardMode explicit|automatic|off`: the clipboard setting of the simulated environment.
    public var clipboardMode: ClipboardMode?
    /// `-MarionetteExternalMode mirror|externalOnly|dual`: how a monitor attached during a session is used
    /// at first (screenshots of the monitor).
    public var externalDisplayMode: ExternalDisplayMode?
    /// `-MarionetteWindowed`: behave as in a window smaller than the screen (UI tests; nothing can
    /// resize the simulator's window from the command line).
    public var isWindowedOverride = false
    /// `-MarionetteDiagnostics`: the remote display's accessibility value carries what tests read
    /// (zoom, display size, input received), also against a real computer. Implied by UI-test mode.
    public var reportsDiagnostics: Bool { isUITestMode || wantsDiagnostics }
    private var wantsDiagnostics = false

    public enum Appearance: String, Sendable, Hashable {
        case light
        case dark
    }

    public init() {}

    public init(arguments: [String]) {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "-MarionetteScenario": scenarioName = iterator.next()
            case "-MarionetteUITestMode": isUITestMode = true
            case "-MarionetteFoldOverride": foldOverride = iterator.next().flatMap(FoldOverride.init(rawValue:))
            case "-MarionetteAutoConnect": autoConnect = true
            case "-MarionetteAppearance": appearance = iterator.next().flatMap(Appearance.init(rawValue:))
            case "-MarionetteClipboardMode": clipboardMode = iterator.next().flatMap(ClipboardMode.init(rawValue:))
            case "-MarionetteExternalMode": externalDisplayMode = iterator.next().flatMap(ExternalDisplayMode.init(rawValue:))
            case "-MarionetteWindowed": isWindowedOverride = true
            case "-MarionetteDiagnostics": wantsDiagnostics = true
            default: break
            }
        }
    }
}

/// Everything the app is wired to. Built once at launch.
@MainActor
public final class AppEnvironment {
    public let options: LaunchOptions
    public let registry: BackendRegistry
    public let transports: any TransportFactory
    public let secrets: any SecretStore
    /// The SSH servers whose host keys the user accepted, for a "Known Hosts" screen.
    public let hostKeys: any KnownHostsStore
    /// The user's SSH keys, for an "SSH Keys" screen and the key picker of a computer's tunnel.
    public let sshKeys: SSHKeyStore
    public let discovery: any DiscoveryProvider
    public let pasteboard: any LocalPasteboard
    public let clock: any AppClock
    public let defaults: UserDefaults
    public let repository: ComputerRepository
    public let sessions: SessionStore
    public let library: LibraryModel

    /// `hostKeys` and `sshKeys` default to the ones `transports` connects with, and where it has no
    /// SSH, to stores that last as long as the process.
    public init(
        options: LaunchOptions,
        registry: BackendRegistry,
        transports: any TransportFactory,
        secrets: any SecretStore,
        hostKeys: (any KnownHostsStore)? = nil,
        sshKeys: SSHKeyStore? = nil,
        discovery: any DiscoveryProvider,
        pasteboard: any LocalPasteboard,
        clock: any AppClock,
        defaults: UserDefaults,
        repository: ComputerRepository
    ) {
        self.options = options
        self.registry = registry
        self.transports = transports
        self.secrets = secrets
        self.hostKeys = hostKeys ?? transports.ssh?.hostKeys ?? InMemoryKnownHostsStore()
        self.sshKeys = sshKeys ?? transports.ssh?.keys ?? SSHKeyStore(secrets: secrets)
        self.discovery = discovery
        self.pasteboard = pasteboard
        self.clock = clock
        self.defaults = defaults
        self.repository = repository
        let library = LibraryModel(repository: repository, secrets: secrets, discovery: discovery, clock: clock)
        self.library = library
        let ladder = ConnectionLadder(registry: registry, transports: transports)
        let isUITestMode = options.isUITestMode
        sessions = SessionStore {
            var dependencies = SessionModel.Dependencies(
                ladder: ladder, secrets: secrets, pasteboard: pasteboard, clock: clock, repository: repository, defaults: defaults
            )
            if isUITestMode {
                dependencies.mutesAudio = true
                dependencies.bannerDuration = nil
            } else {
                dependencies.downloadsDirectory = { URL.documentsDirectory }
            }
            return dependencies
        }
        sessions.onSessionClosed = { [weak library, weak sessions] in
            library?.activeComputerIDs = sessions?.activeComputerIDs ?? []
            library?.reload()
        }
    }

    /// The environment for a launch: simulated when the arguments name a scenario or ask for UI-test
    /// mode, live otherwise.
    public static func make(arguments: [String], pasteboard: any LocalPasteboard) async -> AppEnvironment {
        let options = LaunchOptions(arguments: arguments)
        if options.scenarioName != nil || options.isUITestMode {
            let setup = ScenarioCatalog.setup(named: options.scenarioName ?? ScenarioCatalog.defaultName)
                ?? ScenarioCatalog.setup(named: ScenarioCatalog.defaultName)!
            // The simulated computer shares the real clipboard, so the paste paths can be exercised
            // end to end on a simulator.
            return await simulated(setup, options: options, pasteboard: pasteboard)
        }
        return live(options: options, pasteboard: pasteboard)
    }

    /// The real thing: saved computers on disk, secrets and SSH keys in the Keychain, known hosts in
    /// Application Support, and the real back ends over a direct network path or an SSH tunnel. The
    /// demo computer keeps using the simulated back end. Computers nearby are found with Bonjour.
    public static func live(options: LaunchOptions = LaunchOptions(), pasteboard: any LocalPasteboard) -> AppEnvironment {
        let registry = liveRegistry()
        let container: ModelContainer
        do {
            container = try ComputerRepository.makeContainer(inMemory: false)
        } catch {
            // A store that cannot be opened must not stop the app from launching; saved computers are
            // unavailable for this run.
            container = try! ComputerRepository.makeContainer(inMemory: true)
        }
        let secrets = KeychainSecretStore()
        let ssh = SSHServices(
            connector: LiveSSHConnector(),
            hostKeys: FileHostKeyStore(fileURL: FileHostKeyStore.defaultFileURL),
            keys: SSHKeyStore(secrets: secrets)
        )
        return AppEnvironment(
            options: options,
            registry: registry,
            transports: LiveTransportFactory(ssh: ssh),
            secrets: secrets,
            discovery: BonjourDiscoveryProvider(),
            pasteboard: pasteboard,
            clock: SystemClock(),
            defaults: .standard,
            repository: ComputerRepository(container: container)
        )
    }

    /// The back ends of the live environment: Screen Sharing for Macs, VNC for everything else (and
    /// as a Mac's last resort), and the simulated one for the demo computer. No fallback: a computer
    /// whose back end is missing fails with an explanation rather than connect to something else.
    public static func liveRegistry() -> BackendRegistry {
        var registry = BackendRegistry()
        var demo = SimulationScenario.highPerformance
        demo.playsTone = false
        registry.register(SimulatedBackend(scenario: demo))
        registry.register(AppleScreenSharingBackend())
        registry.register(VNCBackend())
        return registry
    }

    /// A self-contained environment on the simulated back end: nothing is read from or written to
    /// disk, the Keychain or the network.
    /// `pasteboard` defaults to an in-memory one.
    public static func simulated(
        _ setup: ScenarioSetup,
        options: LaunchOptions = LaunchOptions(),
        pasteboard: (any LocalPasteboard)? = nil
    ) async -> AppEnvironment {
        var registry = BackendRegistry()
        registry.register(setup.makeBackend())
        registry.fallbackBackendID = SimulatedBackend.backendID
        let suite = "llc.turing.Marionette.simulated"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        if let mode = options.clipboardMode {
            var preferences = SessionPreferences(defaults: defaults)
            preferences.clipboardMode = mode
            preferences.save(to: defaults)
        }
        let secrets = InMemorySecretStore()
        let clock: any AppClock = options.isUITestMode ? FixedClock() : SystemClock()
        let repository = ComputerRepository(container: try! ComputerRepository.makeContainer(inMemory: true))
        await SeedData.seed(setup, into: repository, secrets: secrets, clock: clock)
        return AppEnvironment(
            options: options,
            registry: registry,
            transports: SimulatedTransportFactory(
                ssh: setup.providesSSH
                    ? SSHServices(connector: ScriptedSSHConnector(), hostKeys: InMemoryKnownHostsStore(), keys: SSHKeyStore(secrets: secrets))
                    : nil
            ),
            secrets: secrets,
            discovery: SimulatedDiscoveryProvider(computers: setup.discovered, delay: .milliseconds(options.isUITestMode ? 50 : 600), deniesPermission: setup.discoveryDenied),
            pasteboard: pasteboard ?? InMemoryPasteboard(),
            clock: clock,
            defaults: defaults,
            repository: repository
        )
    }

    /// The computer `-MarionetteAutoConnect` opens: the first saved one, else the demo.
    public var autoConnectComputer: ComputerConfiguration {
        library.records.first?.configuration ?? .demo
    }
}
