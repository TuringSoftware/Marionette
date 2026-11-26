// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import CoreGraphics
public import Foundation
import Observation
public import RemoteDesktopCore
public import RemoteDesktopInteraction
public import RemoteDesktopRender

/// One session with one computer, from the first connection attempt until its screen closes.
///
/// The model keeps a low-frequency, observable picture of the session (phase, layout, features) and
/// turns user intents into calls on it. Frames and the cursor never pass through here: they flow from
/// the session straight into ``renderer`` on background tasks. The model owns the renderer, so a view
/// that is re-created — after a fold, in a new window — only has to attach to it again.
@MainActor
@Observable
public final class SessionModel: Identifiable {
    /// Which surface a touch landed on.
    public enum TouchSurface: Sendable, Hashable {
        /// The remote display itself. Touch or trackpad mode applies.
        case stage
        /// The input deck's trackpad. Always relative.
        case deck
    }

    /// What a session needs from its surroundings.
    public struct Dependencies {
        public var ladder: ConnectionLadder
        public var secrets: any SecretStore
        public var pasteboard: any LocalPasteboard
        public var clock: any AppClock
        public var repository: ComputerRepository?
        public var defaults: UserDefaults
        /// Keeps remote audio silent (tests, screenshots).
        public var mutesAudio = false
        /// How long a banner stays up; `nil` keeps it until dismissed.
        public var bannerDuration: Duration? = .seconds(6)
        /// How automatic reconnection paces its attempts, and how many it makes.
        public var reconnection = ReconnectionPolicy()
        /// Where received files are put. The app points this at its Documents folder, which the
        /// Files app shows.
        public var downloadsDirectory: () -> URL = { FileManager.default.temporaryDirectory }
        /// How often the local clipboard's change count is looked at while connected.
        public var clipboardPollInterval: Duration = .seconds(1)
        /// How long the handle of a collapsed control strip stays before it fades; `nil` keeps it.
        public var controlsHandleTimeout: Duration? = .seconds(4)
        /// Asks the device owner before protected secrets are used.
        public var owner: OwnerAuthentication = .simulated

        public init(
            ladder: ConnectionLadder,
            secrets: any SecretStore,
            pasteboard: any LocalPasteboard,
            clock: any AppClock,
            repository: ComputerRepository?,
            defaults: UserDefaults
        ) {
            self.ladder = ladder
            self.secrets = secrets
            self.pasteboard = pasteboard
            self.clock = clock
            self.repository = repository
            self.defaults = defaults
        }
    }

    // MARK: Observable snapshot

    public nonisolated let id: UUID
    public private(set) var computer: ComputerConfiguration
    public private(set) var phase: SessionPhase = .connecting(nil)
    public private(set) var info: SessionInfo?
    public private(set) var layout: DesktopLayout = .empty
    public private(set) var features = SessionFeatures()
    public private(set) var banner: SessionBanner?
    public private(set) var isRemoteScreenLocked = false
    public private(set) var isAudioMuted: Bool
    /// High Dynamic Range: High Performance displays are HDR where the screen showing them can
    /// show it. On unless the user turned it off; kept across sessions.
    public private(set) var isHDREnabled: Bool
    /// The screen the session's window is on can show HDR.
    public private(set) var windowScreenShowsHDR = false
    public private(set) var quality: QualityPreset
    /// The furthest step (``ConnectionPhase/order``) the current attempt has reached; -1 before any.
    public private(set) var connectionProgress = -1
    /// The attached monitor, while there is one and the app has a scene for it.
    public private(set) var externalScreen: ExternalScreen?
    /// How the attached monitor is used. Always `.mirror` without one.
    public private(set) var externalDisplayMode: ExternalDisplayMode = .mirror
    /// True once the shown display has produced a frame in the current connection.
    public private(set) var hasFirstFrame = false
    /// Set when the user picks "Edit Computer" from a failure; the library opens the editor.
    public private(set) var wantsEditor = false
    /// True once the session has been connected, whatever became of the connection since.
    @ObservationIgnored public private(set) var hasConnected = false

    public let uiState: SessionUIState
    public let prompts: PromptBroker
    public let transfers = TransferQueue()
    public let clipboard: ClipboardBridge
    /// Access to the remote machine's files: built into the session, or over SSH.
    public let files: FileAccessModel
    public let fileDrags: FileDragModel
    /// The remote folder being looked at, while file access is ready. Kept here so that closing and
    /// reopening the Files sheet returns to the same place.
    public private(set) var fileBrowser: RemoteFileBrowserModel?

    // MARK: Not observed

    /// Draws the shown display. Views host its layer; nothing else talks to it.
    @ObservationIgnored public let renderer = DisplayRenderer()
    /// Pastes bringing this device's clipboard over, and the input that arrived meanwhile.
    @ObservationIgnored private var pastesInFlight = 0
    @ObservationIgnored private var heldDuringPaste: [HeldInput] = []
    /// The session runs on a rung that does not speak the computer's own protocol
    /// (``ConnectionLadder/Outcome/usesOwnProtocol``).
    @ObservationIgnored private var isOnFallbackRung = false
    /// Draws the display shown on an attached monitor (External Only, Both Displays). Like
    /// ``renderer`` it belongs to the model, so the monitor's scene only attaches its layer.
    @ObservationIgnored public let externalRenderer = DisplayRenderer()
    /// The display ``externalRenderer`` is consuming frames of.
    @ObservationIgnored private var externalShownDisplay: DisplayID?
    /// The monitor shows the device's picture while mirroring (where the system cannot mirror).
    @ObservationIgnored private var externalMirrorsPicture = false
    /// The user's input mode, kept while External Only forces trackpad mode.
    @ObservationIgnored private var inputModeBeforeExternal: InputMode?
    /// The mode a newly attached monitor should get as soon as the session allows it (Both
    /// Displays needs the layout, which a connecting session does not have yet).
    @ObservationIgnored private var pendingExternalMode: ExternalDisplayMode?
    /// Where ``externalRenderer`` puts the display, in the monitor's points. For tests.
    @ObservationIgnored public private(set) var externalContentFrame: ViewRect?
    @ObservationIgnored private let audio = AudioPlayer()
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private let translator = KeyTranslator()
    @ObservationIgnored private var session: (any RemoteSession)?
    /// The SSH connection carrying a tunnelled session; closed after the session it carries.
    @ObservationIgnored private var tunnel: (any SSHSessionHandle)?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var sizerTask: Task<Void, Never>?
    /// The latest display request on its way; the next waits for it.
    @ObservationIgnored private var displayRequestTask: Task<Void, Never>?
    /// What the connection's options asked of displays the back end makes by itself.
    @ObservationIgnored private var wantsHDRAtConnect = false
    /// Bumped for every connection attempt so late callbacks from an old one are ignored.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var touchInterpreter = TouchInterpreter()
    /// Touch mode, when the remote machine takes fingers as they are: it stands in for
    /// `touchInterpreter`.
    @ObservationIgnored private var directTouch: DirectTouchInterpreter?
    @ObservationIgnored private var stageTrackpad = TrackpadInterpreter(zoomAnchor: .touchCentroid)
    @ObservationIgnored private var deckTrackpad = TrackpadInterpreter(zoomAnchor: .pointer)
    @ObservationIgnored private var heldButtons: PointerButtons = []
    /// The input settings read when the session opened (scroll direction, pointer speed).
    @ObservationIgnored private let inputPreferences: SessionPreferences
    /// Mouse, trackpad and Pencil: an absolute pointer with its own set of held buttons.
    @ObservationIgnored private var pointerInterpreter = PointerInterpreter()
    /// Every key currently held, on screen or on a hardware keyboard.
    @ObservationIgnored private var keyboard = KeyboardState()
    /// Repeats the held key; ends by itself once that key is up.
    @ObservationIgnored private var keyRepeat: Task<Void, Never>?
    @ObservationIgnored private var sizer: VirtualDisplaySizer?
    /// The virtual display asked for when connecting, if any.
    @ObservationIgnored private var requestedDisplay: VirtualDisplaySizer.Proposal?
    /// Which virtual displays were last asked for in HDR, in order.
    @ObservationIgnored private var requestedHDR: [Bool] = []
    /// The mode the user chose for this session from a failure ("Connect in Standard Mode").
    @ObservationIgnored private var modeOverride: ComputerConfiguration.Mode?
    /// The mode the automatic reconnects use after High Performance lost too much data. It lasts
    /// until a connection is up again (or the user retries): the next network may be fine.
    @ObservationIgnored private var demotion: ComputerConfiguration.Mode?
    /// The user agreed, for this session, to connect although the computer cannot prove its
    /// identity as it did before (``RecoveryAction/connectWithoutVerifying``).
    @ObservationIgnored private var allowsUnverifiedIdentity = false
    /// The app is in the background: nothing is drawn, and nothing dials.
    @ObservationIgnored public private(set) var isInBackground = false
    /// The app is active (not behind Control Center, the app switcher or the lock screen).
    @ObservationIgnored private var isActive = true
    /// The pane changed while the app was not active; it is looked at again on return.
    @ObservationIgnored private var paneChangedWhileInactive = false
    /// A reconnect waiting for the app to return to the foreground: the attempts used so far.
    @ObservationIgnored private var heldReconnect: Int?
    /// Until this uptime, just back from the background, a dropped connection is dialled again at
    /// once, without counting the attempt (once).
    @ObservationIgnored private var foregroundRedialUntil: Double?
    /// Shown once the next connection is up: why an automatic reconnect chose a lesser mode.
    @ObservationIgnored private var bannerAfterReconnect: SessionBanner?
    /// A running tally of what has been sent, for accessibility and tests.
    @ObservationIgnored public private(set) var inputTally = InputTally()
    @ObservationIgnored private var stageSafeArea = ViewInsets.zero
    @ObservationIgnored private var controlsCollapsedBeforeDocking: Bool?
    /// The panel shown before folding like a laptop; it comes back on unfolding, whatever the lower
    /// pane held meanwhile.
    @ObservationIgnored private var inputPanelBeforeDocking: InputPanel?
    /// What the keyboard control brings back when pressed with nothing showing: the last panel shown
    /// in this session, or the one chosen in Settings.
    @ObservationIgnored private var lastShownPanel: InputPanel

    /// The panel on screen, or with nothing showing, the one the keyboard control would bring up:
    /// what that control shows as its glyph. (It only changes together with ``SessionUIState/inputPanel``,
    /// which is observed.)
    public var panelForKeyboardControl: InputPanel {
        uiState.inputPanel == .hidden ? lastShownPanel : uiState.inputPanel
    }

    /// The display the person last chose for this computer, kept between sessions. `nil` until they
    /// choose one: the first display (the main one) is shown.
    private var chosenDisplay: DisplayID? {
        get {
            let raw = dependencies.defaults.object(forKey: chosenDisplayKey) as? NSNumber
            return raw.map { DisplayID($0.uint32Value) }
        }
        set {
            if let newValue {
                dependencies.defaults.set(NSNumber(value: newValue.rawValue), forKey: chosenDisplayKey)
            } else {
                dependencies.defaults.removeObject(forKey: chosenDisplayKey)
            }
        }
    }

    private var chosenDisplayKey: String { "session.display.\(computer.id.uuidString)" }
    @ObservationIgnored private var handleFadeTask: Task<Void, Never>?
    @ObservationIgnored private var keyboardOverlap = 0.0
    @ObservationIgnored private var deckOverlap = 0.0
    /// Plays haptics for gesture milestones; set by the platform layer.
    @ObservationIgnored public var onFeedback: ((InteractionEffect.Feedback) -> Void)?
    /// Called once, when the session connects for the first time; not when it reconnects.
    @ObservationIgnored var onFirstConnection: (() -> Void)?
    /// Called once when the session reaches ``SessionPhase/closed``.
    @ObservationIgnored var onClose: ((SessionModel) -> Void)?

    public init(computer: ComputerConfiguration, dependencies: Dependencies) {
        id = UUID()
        self.computer = computer
        self.dependencies = dependencies
        quality = computer.quality == .full ? .full : .adaptive
        let preferences = SessionPreferences(defaults: dependencies.defaults)
        isAudioMuted = dependencies.mutesAudio || preferences.isAudioMuted
        isHDREnabled = preferences.isHDREnabled
        uiState = SessionUIState(preferences: preferences)
        lastShownPanel = preferences.inputPanel == .hidden ? preferences.defaultInputPanel : preferences.inputPanel
        inputPreferences = preferences
        let gestures = preferences.gestureConfiguration
        touchInterpreter = TouchInterpreter(configuration: gestures)
        stageTrackpad = TrackpadInterpreter(configuration: gestures, zoomAnchor: .touchCentroid)
        // A trackpad of its own works like a Mac's: pinch, rotate and the other gestures go to the
        // remote app instead of zooming this device's view.
        var padGestures = gestures
        padGestures.forwardsGestures = true
        deckTrackpad = TrackpadInterpreter(configuration: padGestures, zoomAnchor: .pointer)
        pointerInterpreter = PointerInterpreter(configuration: gestures)
        prompts = PromptBroker(computer: computer, secrets: dependencies.secrets, access: dependencies.owner.makeAccess())
        clipboard = ClipboardBridge(
            mode: preferences.clipboardMode,
            pasteboard: dependencies.pasteboard,
            clock: dependencies.clock,
            pollInterval: dependencies.clipboardPollInterval
        )
        files = FileAccessModel(ssh: dependencies.ladder.ssh, broker: prompts)
        fileDrags = FileDragModel(transfers: transfers)
        fileDrags.host = self
        audio.isMuted = isAudioMuted
        files.onTransferChanged = { [weak self] transfer in
            guard let self else { return }
            self.transfers.setTransfer(transfer)
            self.fileBrowser = transfer.flatMap { $0.canBrowse ? RemoteFileBrowserModel(transfer: $0) : nil }
        }
        transfers.destinationDirectory = dependencies.downloadsDirectory
        scheduleHandleFade()
        prompts.isComputerSaved = computer.isDemo || dependencies.repository?.record(id: computer.id) != nil
        prompts.onRememberUsername = { [weak self] username in
            guard let self, !self.computer.isDemo, let repository = self.dependencies.repository else { return }
            if !username.isEmpty { self.computer.username = username }
            if var saved = repository.record(id: self.computer.id)?.configuration {
                guard !username.isEmpty else { return }
                saved.username = username
                repository.save(saved, now: self.dependencies.clock.now)
            } else {
                repository.save(self.computer, now: self.dependencies.clock.now)
                self.prompts.isComputerSaved = true
            }
        }
    }

    // MARK: Derived

    public var title: String { computer.displayName }

    /// The display being shown, if the layout has it.
    public var selectedDisplay: RemoteDisplay? {
        uiState.selectedDisplay.flatMap { layout[$0] } ?? layout.primaryDisplay
    }

    /// The display the pointer is on: the shown one, or the one on the monitor once a trackpad has
    /// taken the pointer across to it.
    public var pointerDisplay: RemoteDisplay? {
        if let id = uiState.pointerDisplay, isOnMonitor(id), let display = layout[id] { return display }
        return selectedDisplay
    }

    /// Whether the display is on the monitor beside the device's own (Both Displays).
    private func isOnMonitor(_ id: DisplayID) -> Bool {
        externalDisplayMode == .dual && externalShownDisplay == id && id != selectedDisplay?.id
    }

    /// One line for the title menu: "High Performance", "Standard · SSH tunnel".
    public var statusLine: String {
        switch phase {
        case .connecting(let step): return step?.title ?? String(localized: "Connecting…", bundle: #bundle)
        case .reconnecting: return String(localized: "Reconnecting…", bundle: #bundle)
        case .failed: return String(localized: "Not Connected", bundle: #bundle)
        case .ended, .closed: return String(localized: "Disconnected", bundle: #bundle)
        case .connected:
            guard let info else { return String(localized: "Connected", bundle: #bundle) }
            var parts = [info.mode.title]
            // Apple's Standard mode and plain VNC look alike; say which one this is.
            if info.backendID == BackendID.vnc { parts.append("VNC") }
            if info.isTunnelled { parts.append(String(localized: "SSH Tunnel", bundle: #bundle)) }
            if !isSessionEncrypted { parts.append(String(localized: "Not Secure", bundle: #bundle)) }
            return parts.joined(separator: " · ")
        }
    }

    /// True while the shown display is being resized or re-arranged; its last frame stays valid.
    public var isDisplayReconfiguring: Bool {
        phase == .connected && selectedDisplay?.state == .reconfiguring
    }

    /// Whether input can be sent right now.
    public var acceptsInput: Bool { phase == .connected && !computer.observeOnly }

    // MARK: Connection life cycle

    /// Starts connecting. Called once by the session store when the session is opened.
    public func start() {
        guard connectTask == nil, session == nil else { return }
        beginConnecting(reconnectAttempt: nil)
    }

    private func beginConnecting(reconnectAttempt: Int?) {
        attempt += 1
        let token = attempt
        wantsEditor = false
        connectionProgress = -1
        phase = reconnectAttempt.map { .reconnecting(attempt: max(1, $0)) } ?? .connecting(nil)
        var configuration = computer
        if let mode = modeOverride ?? demotion { configuration.mode = mode }
        let (ladder, broker, clock) = (dependencies.ladder, prompts, dependencies.clock)
        // Back ends report progress from any thread. A stream keeps the steps in the order they
        // were reported, which separate hops to the main actor would not guarantee.
        let (steps, progress) = AsyncStream<ConnectionPhase>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let progressTask = Task { [weak self] in
            for await step in steps { self?.noteProgress(step, token: token) }
        }
        connectTask = Task { [weak self] in
            defer {
                progress.finish()
                progressTask.cancel()
            }
            // A fitted display is asked for at connect time, which needs the pane's shape. The session
            // starts before its screen has been laid out, so give layout a moment to report it; a
            // late answer only costs one resize after connecting.
            if configuration.display == .fitToDevice {
                for _ in 0..<12 {
                    guard let self, self.attempt == token, self.stagePane.isEmpty else { break }
                    try? await clock.sleep(for: .milliseconds(50))
                }
            }
            guard let options = self?.sessionOptions(for: configuration) else { return }
            let isFirstContact = self?.isFirstContact ?? false
            do throws(ConnectionFailure) {
                let outcome = try await ladder.connect(to: configuration, options: options, isFirstContact: isFirstContact, prompts: broker) { progress.yield($0) }
                guard let self, self.attempt == token, !Task.isCancelled else {
                    await outcome.close()
                    return
                }
                self.connectTask = nil
                self.attach(outcome)
            } catch {
                guard let self, self.attempt == token else { return }
                self.connectTask = nil
                self.connectionFailed(error, reconnectAttempt: reconnectAttempt)
            }
        }
    }

    private func sessionOptions(for configuration: ComputerConfiguration) -> SessionOptions {
        var displays = SessionOptions.DisplayPreference.physical(.all)
        requestedDisplay = nil
        requestedHDR = []
        wantsHDRAtConnect = wantsHDR(display: 0)
        if configuration.display == .fitToDevice, let proposal = virtualDisplayProposal() {
            // A Mac keeps the number of displays a session starts with, so a second one is asked
            // for now or not at all.
            var requests = [proposal.request]
            if configuration.hasSecondaryDisplay { requests.append(secondaryDisplayRequest(matching: proposal.request)) }
            requests = withHDR(requests)
            displays = .virtual(requests)
            requestedDisplay = proposal
            requestedHDR = requests.map(\.wantsHDR)
        }
        return SessionOptions(
            displays: displays,
            quality: quality,
            controlMode: configuration.observeOnly ? .observe : .control,
            wantsAudio: configuration.audioEnabled && configuration.allowsAudio,
            wantsClipboard: configuration.clipboardEnabled && clipboard.mode != .off,
            requiresServerAuthentication: requiresProvenIdentity,
            requiresEncryption: requiresEncryption,
            wantsHDR: wantsHDRAtConnect
        )
    }

    /// A saved computer whose sessions at this address were encrypted before is never connected to
    /// without encryption again: something on the network could otherwise talk it down to a session
    /// in clear. There is no way around this but adding the computer again, or a new address.
    private var requiresEncryption: Bool {
        ((try? dependencies.secrets.secret(for: .encryptedBefore(for: computer))) ?? nil) != nil
    }

    /// Never connected to before: nothing has shown this computer to be a Mac yet.
    private var isFirstContact: Bool {
        dependencies.repository?.record(id: computer.id)?.lastConnected == nil
    }

    /// Remembers what the computer turned out to speak, so that the editor shows only what applies
    /// and a VNC server's own password is used for it. It becomes a VNC server only when that was
    /// found on first contact (it said it is not a Mac); a computer known as a Mac that stops
    /// answering as one stays a Mac, and its fallback keeps asking for credentials.
    private func noteDetectedProtocol(_ outcome: ConnectionLadder.Outcome) {
        guard computer.speaksDetectedProtocol, outcome.step.backendID != computer.backendID else { return }
        let foundOtherProtocol = outcome.fallbacks.contains { if case .otherProtocol = $0.failure { true } else { false } }
        switch outcome.step.backendID {
        case BackendID.vnc where foundOtherProtocol && isFirstContact,
             BackendID.appleScreenSharing:
            computer.backendID = outcome.step.backendID
            if dependencies.repository?.record(id: computer.id) != nil {
                dependencies.repository?.save(computer, now: dependencies.clock.now)
            }
        default:
            break
        }
    }

    /// A Mac that proved its identity at this address before must prove it again, unless the user
    /// agreed otherwise for this session: anything else answering there is presumed an impostor.
    private var requiresProvenIdentity: Bool {
        guard computer.backendID == BackendID.appleScreenSharing, !allowsUnverifiedIdentity else { return false }
        return ((try? dependencies.secrets.secret(for: .provenIdentity(for: computer))) ?? nil) != nil
    }

    /// Whether nothing on the network can read the session: the protocol encrypts, or a tunnel does.
    private var isSessionEncrypted: Bool {
        info.map { $0.isEncrypted || $0.isTunnelled } ?? false
    }

    private func noteProgress(_ step: ConnectionPhase, token: Int) {
        guard token == attempt, case .connecting = phase else { return }
        phase = .connecting(step)
        // Back ends may revisit a step (a second sign-in attempt reconnects); the bar never retreats.
        connectionProgress = max(connectionProgress, step.order)
    }

    private func connectionFailed(_ failure: ConnectionFailure, reconnectAttempt: Int?) {
        if failure == .cancelled {
            // Only a user's cancel gets here; a superseded attempt is filtered by its token.
            reconnectAttempt == nil ? close() : (phase = .ended(.connectionLost(detail: "")))
            return
        }
        if let reconnectAttempt, failure.isWorthRetrying {
            scheduleReconnect(after: reconnectAttempt, lastFailure: failure)
        } else {
            phase = .failed(failure)
        }
    }

    private func attach(_ outcome: ConnectionLadder.Outcome) {
        let session = outcome.session
        self.session = session
        isOnFallbackRung = !outcome.usesOwnProtocol
        tunnel = outcome.ssh
        // Subscribe before reading the current values so that nothing can slip between the two.
        let events = session.events()
        info = session.info
        setFeatures(SessionFeatures(session.capabilities))
        hasFirstFrame = false
        isRemoteScreenLocked = false
        heldButtons = []
        prompts.connectionSucceeded()
        demotion = nil
        heldReconnect = nil
        noteDetectedProtocol(outcome)
        dependencies.repository?.recordConnection(id: computer.id, mode: session.info.mode, at: dependencies.clock.now)
        if session.info.isServerAuthenticated, computer.backendID == BackendID.appleScreenSharing,
           dependencies.repository?.record(id: computer.id) != nil {
            try? dependencies.secrets.setSecret("1", for: .provenIdentity(for: computer), protection: computer.passwordProtection.withoutUserPresence)
        }
        if session.info.isEncrypted, dependencies.repository?.record(id: computer.id) != nil {
            try? dependencies.secrets.setSecret("1", for: .encryptedBefore(for: computer), protection: computer.passwordProtection.withoutUserPresence)
        }
        if isInBackground {
            // Reconnected while the app is away: nothing may draw or play until it is back.
            Task { await session.suspend() }
        }
        phase = .connected
        if !hasConnected {
            hasConnected = true
            onFirstConnection?()
        }
        apply(layout: session.layout, restartRenderer: true)
        if let banner = bannerAfterReconnect {
            bannerAfterReconnect = nil
            show(banner)
        } else {
            showFallbackBanner(for: outcome)
        }

        let token = attempt
        sessionTasks.append(Task { [weak self] in
            for await event in events {
                guard let self, self.attempt == token else { return }
                self.handle(event)
            }
        })
        let cursor = session.cursor()
        sessionTasks.append(Task { [weak self] in
            var seen: UInt64 = 0
            for await state in cursor {
                guard let self, self.attempt == token else { return }
                guard state.remoteMoves != seen else { continue }
                seen = state.remoteMoves
                if let position = state.position { self.remotePointerMoved(to: position) }
            }
        })
        startCapabilityConsumers(for: session)
        if case .disconnected(let reason) = session.state { sessionEnded(reason) }
    }

    /// The remote machine's pointer moved without this client (someone at its own mouse, or the
    /// position it starts at): this client's pointer, which a trackpad-style touch moves from
    /// where it is, goes on from there. Not while a button is held here.
    private func remotePointerMoved(to desktopPosition: PixelPoint) {
        guard let display = pointerDisplay, heldButtons.isEmpty, pointerInterpreter.heldButtons.isEmpty,
              display.frameInDesktop.contains(desktopPosition)
        else { return }
        uiState.pointer = PixelPoint(x: desktopPosition.x - Double(display.frameInDesktop.x), y: desktopPosition.y - Double(display.frameInDesktop.y))
        showLocalPointer()
    }

    /// Draws the locally tracked pointer on whichever screen shows the display it is on, and on no other.
    private func showLocalPointer() {
        let display = pointerDisplay?.id
        renderer.setLocalPointer(display != nil && display == selectedDisplay?.id ? uiState.pointer : nil)
        if let shown = externalShownDisplay {
            externalRenderer.setLocalPointer(shown == display ? uiState.pointer : nil)
        }
    }

    private func startCapabilityConsumers(for session: any RemoteSession) {
        let capabilities = session.capabilities
        if let output = capabilities.audio.value {
            audio.start(output.chunks())
        }
        files.sessionConnected(computer: computer, tunnel: tunnel, builtIn: capabilities.fileTransfer.value)
        clipboard.connected(capabilities.clipboard.value, isEncrypted: isSessionEncrypted)
        fileDrags.connected(capabilities.fileDrag.value)
        if computer.display == .fitToDevice, let limits = capabilities.displayConfiguration.value?.limits, limits.maximumVirtualDisplays > 0 {
            sizer = VirtualDisplaySizer(limits: limits)
            sizer?.prefersRetina = computer.prefersRetina
            // Only what was really asked for counts as applied; if the pane was not known in time,
            // or has changed since, this asks now.
            sizer?.markApplied(requestedDisplay)
            paneChanged()
        } else {
            sizer = nil
            // The back end made displays like the Mac's own, all as the options asked; a screen
            // reported while connecting may want otherwise.
            let virtualDisplays = layout.displays.filter { $0.kind == .virtual }.count
            requestedHDR = Array(repeating: session.info.mode == .highPerformance && wantsHDRAtConnect, count: virtualDisplays)
            displaysChangedScreens()
        }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .stateChanged(.disconnected(let reason)):
            sessionEnded(reason)
        case .stateChanged:
            break
        case .layoutChanged(let layout):
            apply(layout: layout, restartRenderer: false)
        case .capabilitiesChanged(let capabilities):
            setFeatures(SessionFeatures(capabilities))
            files.setBuiltIn(capabilities.fileTransfer.value)
            if (capabilities.clipboard.value != nil) != clipboard.isAvailable {
                clipboard.connected(capabilities.clipboard.value, isEncrypted: isSessionEncrypted)
            }
            if capabilities.fileDrag.isAvailable != fileDrags.isAvailable {
                fileDrags.connected(capabilities.fileDrag.value)
            }
        case .notice(.remoteScreenLocked(let locked)):
            isRemoteScreenLocked = locked
        case .notice(.message(let text)):
            show(SessionBanner(kind: .information, title: text, message: ""))
        case .notice:
            break
        }
    }

    private func setFeatures(_ newFeatures: SessionFeatures) {
        if newFeatures.touch != features.touch {
            // Fingers down when the remote machine starts or stops taking touches are let go; the
            // next ones go to the interpreter that fits.
            if !(directTouch?.isIdle ?? true) || !touchInterpreter.isIdle { cancelGestures() }
            directTouch = newFeatures.touch.map { DirectTouchInterpreter(maximumContacts: $0.maximumContacts) }
        }
        features = newFeatures
    }

    private func apply(layout newLayout: DesktopLayout, restartRenderer: Bool) {
        let previous = selectedDisplay
        layout = newLayout
        var restart = restartRenderer
        // The display the person chose for this computer comes back whenever the layout has it:
        // after a reconnect (whose first layouts may be empty or partial) and in later sessions.
        if let chosen = chosenDisplay, newLayout[chosen] != nil, uiState.selectedDisplay != chosen {
            uiState.selectedDisplay = chosen
            restart = true
        } else if uiState.selectedDisplay.flatMap({ newLayout[$0] }) == nil {
            uiState.selectedDisplay = newLayout.primaryDisplay?.id
            restart = true
        }
        guard let display = selectedDisplay else { return }
        if previous?.pixelSize != display.pixelSize || restart {
            uiState.viewport.contentSize = display.pixelSize
            uiState.pointer = display.clamping(uiState.pointer)
        }
        if restart, let session {
            if previous?.id != display.id {
                uiState.pointer = PixelPoint(x: Double(display.pixelSize.width) / 2, y: Double(display.pixelSize.height) / 2)
            }
            renderer.start(frames: session.frames(for: display.id), cursor: session.cursor())
            renderer.setLocalPointer(uiState.pointer)
            let token = attempt
            sessionTasks.append(Task { [weak self, renderer] in
                await renderer.firstFrame()
                guard let self, self.attempt == token, !Task.isCancelled else { return }
                self.hasFirstFrame = true
            })
        }
        pushGeometry()
        updateExternalRenderer(restart: restart)
    }

    private func sessionEnded(_ reason: DisconnectReason) {
        guard session != nil else { return }
        releaseAllInput(notifyingRemote: false)
        captureThumbnail()
        tearDownSession()
        if let ssh = takeTunnel() { Task { await ssh.close() } }
        if reason == .mediaStalled(.lossy), info?.mode == .highPerformance, modeOverride == nil {
            // The video path was too lossy to repair. Going straight back into High Performance
            // would usually stall again, so the reconnect takes the next rung, which travels over
            // the control connection. A silent path (a network change) redials in the same mode.
            demotion = .standard
            bannerAfterReconnect = SessionBanner(
                kind: .fallback,
                title: String(localized: "Reconnected in Standard Mode", bundle: #bundle),
                message: String(localized: "The network was losing too much data for High Performance.", bundle: #bundle)
            )
        }
        switch reason {
        case .userInitiated:
            close()
        case _ where reason.isRecoverable && dependencies.reconnection.attempts > 0:
            scheduleReconnect(after: 0, lastFailure: nil, reason: reason)
        default:
            phase = .ended(reason)
        }
    }

    private func tearDownSession() {
        for task in sessionTasks { task.cancel() }
        sessionTasks.removeAll()
        sizerTask?.cancel()
        sizerTask = nil
        // A request still waiting must not hold up the next session's.
        displayRequestTask?.cancel()
        displayRequestTask = nil
        timerTask?.cancel()
        timerTask = nil
        audio.stop()
        files.sessionInterrupted()
        clipboard.disconnected()
        fileDrags.disconnected()
        // The renderer keeps the last frame on screen for the "reconnecting" state.
        renderer.stop()
        externalRenderer.stop()
        externalShownDisplay = nil
        session = nil
        uiState.isPasswordEntryPresented = false
    }

    /// Hands back the tunnel's SSH connection, if any, so it can be closed after the session.
    private func takeTunnel() -> (any SSHSessionHandle)? {
        defer { tunnel = nil }
        return tunnel
    }

    /// Dials again after `attemptsUsed` automatic attempts, after a pause, unless they are used up.
    private func scheduleReconnect(after attemptsUsed: Int, lastFailure: ConnectionFailure?, reason: DisconnectReason? = nil) {
        let policy = dependencies.reconnection
        guard attemptsUsed < policy.attempts else {
            // The real failure, with its own ways forward, rather than a generic "connection lost".
            phase = lastFailure.map { .failed($0) } ?? .ended(reason ?? .connectionLost(detail: ""))
            return
        }
        let next = attemptsUsed + 1
        phase = .reconnecting(attempt: next)
        attempt += 1
        let token = attempt
        if isInBackground {
            // Attempts made while the app is suspended fail for that reason alone, and would use
            // up the attempts before the user is back.
            heldReconnect = attemptsUsed
            return
        }
        if let until = foregroundRedialUntil, dependencies.clock.uptime < until {
            // The connection did not survive the time in the background. That says nothing about
            // the network now, so the first dial after returning is immediate and not counted.
            foregroundRedialUntil = nil
            beginConnecting(reconnectAttempt: attemptsUsed)
            return
        }
        let (clock, delay) = (dependencies.clock, policy.delay(beforeAttempt: next, random: .random(in: 0...1)))
        connectTask = Task { [weak self] in
            try? await clock.sleep(for: delay)
            guard let self, self.attempt == token, !Task.isCancelled else { return }
            self.connectTask = nil
            if self.isInBackground {
                self.heldReconnect = attemptsUsed
            } else {
                self.beginConnecting(reconnectAttempt: next)
            }
        }
    }

    // MARK: User intents — session

    /// Stops a connection attempt, or disconnects, and closes the session.
    public func disconnect() {
        prompts.cancelPending()
        connectTask?.cancel()
        connectTask = nil
        attempt += 1
        guard let session else {
            close()
            return
        }
        releaseAllInput(notifyingRemote: true)
        captureThumbnail()
        tearDownSession()
        let ssh = takeTunnel()
        close()
        Task {
            await session.disconnect()
            await ssh?.close()
        }
    }

    /// Starts over after a failure or an ended session.
    public func reconnect() {
        guard session == nil, connectTask == nil else { return }
        heldReconnect = nil
        beginConnecting(reconnectAttempt: nil)
    }

    /// Carries out a recovery action. Actions that need the interface (help, Settings) are the
    /// caller's to handle; this returns `false` for those.
    @discardableResult
    public func perform(_ action: RecoveryAction) -> Bool {
        switch action {
        case .retry:
            demotion = nil
            reconnect()
        case .editCredentials:
            prompts.forgetCredentials()
            reconnect()
        case .connectWithStandardMode:
            modeOverride = .standard
            reconnect()
        case .connectWithoutTunnel:
            computer.tunnel.isEnabled = false
            prompts.computer = computer
            reconnect()
        case .connectWithoutVerifying:
            allowsUnverifiedIdentity = true
            reconnect()
        case .editConnection:
            wantsEditor = true
            close()
        case .openSystemSettings, .showHelp:
            return false
        }
        return true
    }

    private func close() {
        guard phase != .closed else { return }
        phase = .closed
        bannerTask?.cancel()
        files.sessionEnded()
        savePreferences()
        onClose?(self)
    }

    // MARK: App life cycle

    /// The app is about to stop being active (Control Center, the app switcher, locking, leaving
    /// for another app). Called synchronously from the system's notification: drawing stops before
    /// anything is suspended, because iOS ends an app that draws in the background or while the
    /// device is locked. Nothing may stay pressed on the remote machine either.
    public func sceneDidResignActive() {
        renderer.suspendDrawing()
        externalRenderer.suspendDrawing()
        isActive = false
        if sizerTask != nil {
            // A resize asked for just now waits too; the pane is looked at again on return.
            sizerTask?.cancel()
            sizerTask = nil
            paneChangedWhileInactive = true
        }
        releaseAllInput(notifyingRemote: true)
        captureThumbnail()
    }

    /// The app is active again: drawing resumes, and a pane that changed meanwhile is sized for.
    public func sceneDidBecomeActive() {
        isActive = true
        renderer.resumeDrawing()
        externalRenderer.resumeDrawing()
        if paneChangedWhileInactive {
            paneChangedWhileInactive = false
            paneChanged()
        }
    }

    public func sceneDidEnterBackground() {
        isInBackground = true
        // Whoever has the device next must pass Face ID again before protected secrets are used.
        prompts.lockProtectedSecrets()
        // Already stopped when the app resigned active; this covers a path that skipped that.
        renderer.suspendDrawing()
        externalRenderer.suspendDrawing()
        clipboard.setActive(false)
        guard let session else { return }
        Task { await session.suspend() }
    }

    /// Back from the background. A connection that ended meanwhile is dialled again at once, and
    /// so is one that turns out not to have survived (within ``foregroundRedialWindow``).
    public func sceneWillEnterForeground() {
        let wasInBackground = isInBackground
        isInBackground = false
        clipboard.setActive(true)
        if let session { Task { await session.resume() } }
        guard wasInBackground else { return }
        foregroundRedialUntil = dependencies.clock.uptime + Self.foregroundRedialWindow
        if let attemptsUsed = heldReconnect {
            heldReconnect = nil
            foregroundRedialUntil = nil
            beginConnecting(reconnectAttempt: attemptsUsed)
        }
    }

    /// How long after returning to the foreground a dropped connection is dialled again at once.
    static let foregroundRedialWindow = 3.0

    /// The background grace period the app asked iOS for is over: ends the session cleanly, to be
    /// dialled again when the app returns. A suspended app answers nothing, so the Mac would
    /// otherwise hold the virtual display and the High Performance seat, or wait on a connection
    /// iOS soon reclaims anyway (rootshell: 38 of 40 unexpected disconnects were that).
    public func backgroundTimeExpired() async {
        guard isInBackground else { return }
        if let session {
            releaseAllInput(notifyingRemote: false)
            tearDownSession()
            let ssh = takeTunnel()
            attempt += 1
            heldReconnect = 0
            phase = .reconnecting(attempt: 1)
            await session.disconnect()
            await ssh?.close()
        } else if let connectTask, case .reconnecting(let shown) = phase {
            connectTask.cancel()
            self.connectTask = nil
            attempt += 1
            prompts.cancelPending()
            heldReconnect = max(0, shown - 1)
        }
    }

    public func dismissBanner() {
        bannerTask?.cancel()
        banner = nil
    }

    public func setAudioMuted(_ muted: Bool) {
        isAudioMuted = muted
        audio.isMuted = muted
        savePreferences()
    }

    /// Whether the session offers High Dynamic Range: High Performance, whose displays can be HDR.
    public var offersHDR: Bool {
        phase == .connected && info?.mode == .highPerformance
    }

    /// Whether a screen that shows the session can show HDR: the window's, or an attached
    /// monitor's. Without one, High Dynamic Range does nothing and is shown off and disabled.
    public var canShowHDR: Bool {
        (0..<max(1, layout.displays.count)).contains { screenShowsHDR(display: $0) }
    }

    /// Whether High Dynamic Range can do anything now: a screen can show HDR and the session can
    /// give HDR pictures (not in the constrained media profile, not on a device that cannot decode
    /// them). The menus show it off and disabled otherwise; the choice itself is kept.
    public var isHDRAvailable: Bool {
        canShowHDR && features.highDynamicRange.isAvailable
    }

    /// Turns High Dynamic Range on or off, for this session and the ones after it. The displays
    /// are asked for again at once.
    public func setHDREnabled(_ enabled: Bool) {
        guard enabled != isHDREnabled else { return }
        isHDREnabled = enabled
        savePreferences()
        displaysChangedScreens()
    }

    public func setQuality(_ preset: QualityPreset) {
        guard let control = session?.capabilities.quality.value else { return }
        quality = preset
        Task { try? await control.setPreset(preset) }
    }

    public func perform(_ action: RemoteAction) {
        guard acceptsInput, let actions = session?.capabilities.remoteActions.value else { return }
        Task { try? await actions.perform(action) }
    }

    /// Raises or lowers the curtain on the remote machine's own screen. `features.isCurtained`
    /// changes only when the machine reports that it did.
    public func setCurtained(_ curtained: Bool) {
        guard let curtain = session?.capabilities.curtain.value else { return }
        Task { try? await curtain.setCurtained(curtained, note: Self.curtainNote) }
    }

    /// What the curtain says to anyone at the remote machine.
    static let curtainNote = String(localized: "This computer is being used remotely.", bundle: #bundle)

    /// Sends the device's clipboard to the remote machine. Reading it this way may make iOS ask
    /// first; the paste control and ⌘V do not.
    public func sendLocalClipboard() {
        Task { await clipboard.sendCurrentContents() }
    }

    // MARK: User intents — view

    public func selectDisplay(_ id: DisplayID) {
        guard layout[id] != nil, id != selectedDisplay?.id else { return }
        releaseAllInput(notifyingRemote: true)
        show(display: id, zoom: .fit)
    }

    private func show(display id: DisplayID, zoom: ViewportModel.ZoomMode) {
        chosenDisplay = id
        uiState.selectedDisplay = id
        uiState.pointerDisplay = nil
        uiState.viewport.setMode(zoom)
        apply(layout: layout, restartRenderer: true)
    }

    public func setZoomMode(_ mode: ViewportModel.ZoomMode) {
        uiState.viewport.setMode(mode)
        pushGeometry()
        savePreferences()
    }

    /// Screen Sharing's "Scale to Fit": on, the picture is fitted to the screen and stays fitted
    /// through every change of size; off, it goes to Actual Size.
    public func setScaleToFit(_ isOn: Bool) {
        setZoomMode(isOn ? .fit : .actualSize)
    }

    public func setInputMode(_ mode: InputMode) {
        // With the picture on the monitor, a finger on the device cannot point at anything.
        guard mode != uiState.inputMode, externalDisplayMode != .externalOnly else { return }
        cancelGestures()
        uiState.inputMode = mode
        savePreferences()
    }

    public func toggleInputMode() {
        setInputMode(uiState.inputMode == .touch ? .trackpad : .touch)
    }

    /// What the keyboard control shows at the bottom of the screen. Kept for the next session.
    public func setInputPanel(_ panel: InputPanel) {
        guard panel != uiState.inputPanel else { return }
        // Folded like a laptop the lower pane holds the trackpad or the Mac keyboard, nothing else.
        // Switching between those two is about that pane only: unfolded, what was there before
        // comes back, and what the keyboard control brings up is as it was.
        if uiState.isDeckDocked {
            guard panel.isAvailableDocked else { return }
        }
        cancelGestures()
        uiState.inputPanel = panel
        if panel != .hidden, !uiState.isDeckDocked { lastShownPanel = panel }
        if uiState.deckSurface == nil { setDeckOverlap(0) }
        savePreferences()
    }

    /// The keyboard control was pressed: it shows the last panel shown (or the one chosen in
    /// Settings) and hides it again. Folded like a laptop, where the lower pane is always in use, it
    /// switches between the trackpad and the Mac keyboard. Its menu chooses any of them.
    public func toggleInputPanel() {
        setInputPanel(inputPanelAfterToggle)
    }

    /// What ``toggleInputPanel()`` would show: the menu bar puts the keyboard control's shortcut
    /// beside that choice.
    public var inputPanelAfterToggle: InputPanel {
        if uiState.isDeckDocked {
            uiState.inputPanel.docked == .trackpad ? .deckKeyboard : .trackpad
        } else {
            uiState.inputPanel == .hidden ? lastShownPanel : .hidden
        }
    }

    /// The layout docked the deck beside the remote display (a device folded like a laptop), or
    /// stopped doing so. Docked, the control strip steps aside; it comes back the way it was.
    public func setDeckDocked(_ docked: Bool) {
        guard docked != uiState.isDeckDocked else { return }
        cancelGestures()
        uiState.isDeckDocked = docked
        if docked {
            setDeckOverlap(0)
            controlsCollapsedBeforeDocking = uiState.areControlsCollapsed
            collapseControls(true)
            inputPanelBeforeDocking = uiState.inputPanel
            if !uiState.inputPanel.isAvailableDocked {
                uiState.inputPanel = uiState.inputPanel.docked
            }
        } else {
            if let before = controlsCollapsedBeforeDocking {
                controlsCollapsedBeforeDocking = nil
                collapseControls(before)
            }
            if let before = inputPanelBeforeDocking {
                inputPanelBeforeDocking = nil
                uiState.inputPanel = before
                if uiState.deckSurface == nil { setDeckOverlap(0) }
            }
        }
    }

    /// Full screen: the remote display takes the whole screen, under the camera too, with no bars,
    /// clock or home indicator. Kept for the next session.
    public func setFullScreen(_ fullScreen: Bool) {
        // In a window the session is always full screen; there is nothing to enter or leave, and
        // the choice kept for sessions that have the whole screen stays as it is.
        guard !uiState.isWindowed, fullScreen != uiState.isFullScreen else { return }
        // The picture keeps its size: only the bars and the home indicator come and go over it.
        uiState.isFullScreen = fullScreen
        savePreferences()
    }

    /// The app's window stopped filling the screen, or fills it again (iPad). Reported by the view
    /// layer. Windowed, the session shows full screen at the window's size and follows its resizes.
    public func setWindowed(_ windowed: Bool) {
        guard windowed != uiState.isWindowed else { return }
        uiState.isWindowed = windowed
    }

    /// Folds the control strip into its handle, or opens it again. Kept for the next session.
    public func setControlsCollapsed(_ collapsed: Bool) {
        // A choice made while docked is the user's own: it stays when the device unfolds.
        if uiState.isDeckDocked { controlsCollapsedBeforeDocking = nil }
        collapseControls(collapsed)
        savePreferences()
    }

    private func collapseControls(_ collapsed: Bool) {
        uiState.areControlsCollapsed = collapsed
        uiState.isControlsHandleVisible = true
        scheduleHandleFade()
    }

    /// A finger touched the screen: the handle of a collapsed control strip shows itself again.
    public func screenTouched() {
        guard uiState.areControlsCollapsed else { return }
        if !uiState.isControlsHandleVisible { uiState.isControlsHandleVisible = true }
        scheduleHandleFade()
    }

    /// The handle fades once the strip has been collapsed and the screen untouched for a while.
    private func scheduleHandleFade() {
        handleFadeTask?.cancel()
        handleFadeTask = nil
        guard uiState.areControlsCollapsed, let timeout = dependencies.controlsHandleTimeout else { return }
        let clock = dependencies.clock
        handleFadeTask = Task { [weak self] in
            try? await clock.sleep(for: timeout)
            guard let self, !Task.isCancelled, self.uiState.areControlsCollapsed else { return }
            self.uiState.isControlsHandleVisible = false
        }
    }

    public func setFilesPresented(_ presented: Bool) {
        uiState.isFilesPresented = presented
    }

    /// Shows or hides the field for a password to type at the remote machine. The field takes the
    /// keyboard from the remote display, so whatever is held there is let go of first.
    public func setPasswordEntryPresented(_ presented: Bool) {
        guard presented != uiState.isPasswordEntryPresented, acceptsInput || !presented else { return }
        if presented { releaseAllInput() }
        uiState.isPasswordEntryPresented = presented
        if uiState.deckSurface == nil { setDeckOverlap(0) }
    }

    /// What the password field holds is sent: typed at the remote machine, and the field goes.
    public func submitPasswordEntry(_ password: String) {
        guard uiState.isPasswordEntryPresented else { return }
        typePassword(password)
        uiState.isPasswordEntryPresented = false
    }

    public func setAccessoryPage(_ page: AccessoryPage) {
        uiState.accessoryPage = page
        savePreferences()
    }

    /// The stage view's geometry, in its own coordinate space.
    public func stageLayoutChanged(size: CGSize, safeArea: ViewInsets, deviceScale: Double) {
        var viewport = uiState.viewport
        stageSafeArea = safeArea
        viewport.viewSize = ViewSize(width: size.width, height: size.height)
        // The picture has the whole screen, under the camera and to every edge, in full screen or
        // not: out of full screen the bars and the home indicator are laid over it (glass, as bars
        // over content are), so that entering or leaving full screen changes neither the picture
        // nor the size the remote display is asked to be.
        viewport.safeAreaInsets = .zero
        viewport.deviceScale = deviceScale
        if viewport != uiState.viewport {
            uiState.viewport = viewport
            pushGeometry()
            paneChanged()
        }
    }

    /// How far the software keyboard reaches up into the stage view.
    public func setKeyboardOverlap(_ height: Double) {
        keyboardOverlap = max(0, height)
        updateObstruction()
    }

    /// How far the opened input deck reaches up into the stage view (zero when docked beside it).
    public func setDeckOverlap(_ height: Double) {
        deckOverlap = max(0, height)
        updateObstruction()
    }

    private func updateObstruction() {
        let insets = ViewInsets(bottom: max(keyboardOverlap, deckOverlap))
        if insets.bottom != uiState.bottomObstruction { uiState.bottomObstruction = insets.bottom }
        guard insets != uiState.viewport.obstructionInsets else { return }
        uiState.viewport.obstructionInsets = insets
        if acceptsInput, uiState.inputMode == .trackpad || insets.bottom > 0 {
            uiState.viewport.reveal(uiState.pointer)
        }
        pushGeometry()
    }

    private func pushGeometry() {
        let viewport = uiState.viewport
        let frame = viewport.contentFrame
        let display = selectedDisplay
        renderer.setGeometry(
            RenderGeometry(
                viewSize: CGSize(width: viewport.viewSize.width, height: viewport.viewSize.height),
                deviceScale: viewport.deviceScale,
                contentFrame: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                remoteScale: display?.scale ?? 1,
                desktopOrigin: PixelPoint(x: Double(display?.frameInDesktop.x ?? 0), y: Double(display?.frameInDesktop.y ?? 0))
            )
        )
    }

    // MARK: Virtual display sizing

    /// The pane a fitted virtual display is sized for: the device's, or the monitor's while the
    /// picture is only there.
    private var stagePane: ViewSize {
        if externalDisplayMode == .externalOnly, let externalScreen { return externalScreen.size }
        return uiState.viewport.bounds.inset(by: uiState.viewport.safeAreaInsets).size
    }

    private var stagePaneScale: Double {
        if externalDisplayMode == .externalOnly, let externalScreen { return externalScreen.scale }
        return uiState.viewport.deviceScale
    }

    private func virtualDisplayProposal() -> VirtualDisplaySizer.Proposal? {
        VirtualDisplaySizer.proposal(forPane: stagePane, deviceScale: stagePaneScale, limits: displayLimits, prefersRetina: computer.prefersRetina)
    }

    private var displayLimits: DisplayConfigurationLimits {
        session?.capabilities.displayConfiguration.value?.limits
            ?? DisplayConfigurationLimits(
                maximumVirtualDisplays: 1,
                minimumPointSize: PixelSize(width: 800, height: 600),
                maximumPixelSize: PixelSize(width: 3840, height: 2160),
                canSelectPhysicalDisplays: false
            )
    }

    /// Fit This Device with a secondary display, in a session that has two virtual displays.
    private var hasSecondaryVirtualDisplay: Bool {
        computer.display == .fitToDevice && computer.hasSecondaryDisplay
            && layout.displays.filter { $0.kind == .virtual }.count >= 2
    }

    /// The secondary display: sized for the external display when one is connected, where it is
    /// shown; otherwise like the first, one display switch away on this device.
    private func secondaryDisplayRequest(matching first: VirtualDisplayRequest) -> VirtualDisplayRequest {
        if let screen = externalScreen,
           let proposal = VirtualDisplaySizer.proposal(forPane: screen.size, deviceScale: screen.scale, limits: displayLimits, prefersRetina: computer.prefersRetina) {
            return proposal.request
        }
        return first
    }

    /// Every virtual display the session has, for a first display of `first`.
    private func displayRequests(first: VirtualDisplayRequest) -> [VirtualDisplayRequest] {
        withHDR(hasSecondaryVirtualDisplay ? [first, secondaryDisplayRequest(matching: first)] : [first])
    }

    /// The requests, each asking for HDR when High Dynamic Range is on and the screen that shows its
    /// display can show HDR: the first display is on the session's window, or the monitor in
    /// External Only; the others are on the monitor when there is one, else one display switch away
    /// on the window. (Mirroring shows the first display on the monitor too, which tone-maps it if
    /// it must.) The back end grants HDR only where this device and the Mac take it as well.
    private func withHDR(_ requests: [VirtualDisplayRequest]) -> [VirtualDisplayRequest] {
        requests.enumerated().map { index, request in
            var request = request
            request.wantsHDR = wantsHDR(display: index)
            return request
        }
    }

    /// Whether the display at this position should be HDR; see ``withHDR(_:)``.
    private func wantsHDR(display index: Int) -> Bool {
        isHDREnabled && screenShowsHDR(display: index)
    }

    /// Whether the screen that shows the display at this position can show HDR; see ``withHDR(_:)``.
    private func screenShowsHDR(display index: Int) -> Bool {
        if index == 0 {
            return externalDisplayMode == .externalOnly ? externalScreen?.showsHDR ?? false : windowScreenShowsHDR
        }
        return externalScreen?.showsHDR ?? windowScreenShowsHDR
    }

    /// Asks for these displays, and remembers which of them were asked for in HDR. Requests go out
    /// in the order they are made: two at once (a monitor unplugged and the window's screen
    /// changing) must not reach the back end the other way round.
    private func requestDisplays(_ requests: [VirtualDisplayRequest], from configuration: any DisplayConfiguration) {
        requestedHDR = requests.map(\.wantsHDR)
        let previous = displayRequestTask
        displayRequestTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            try? await configuration.setVirtualDisplays(requests)
        }
    }

    /// The external display came or went: the secondary display takes its size, or the first's again.
    private func resizeSecondaryDisplay() {
        guard hasSecondaryVirtualDisplay, phase == .connected,
              let configuration = session?.capabilities.displayConfiguration.value,
              let first = sizer?.lastProposal?.request ?? requestedDisplay?.request
        else { return }
        requestDisplays(displayRequests(first: first), from: configuration)
    }

    /// A screen that shows a display started or stopped being able to show HDR, or High Dynamic
    /// Range was turned on or off: the displays are asked for again, at the sizes they have. A
    /// resize on its way carries the change instead.
    private func displaysChangedScreens() {
        // Asking again does nothing where the session gives no HDR pictures at all.
        guard phase == .connected, sizer?.nextDeadline == nil, features.highDynamicRange.isAvailable,
              let configuration = session?.capabilities.displayConfiguration.value
        else { return }
        let requests: [VirtualDisplayRequest]
        if computer.display == .fitToDevice {
            guard let first = sizer?.lastProposal?.request ?? requestedDisplay?.request else { return }
            requests = displayRequests(first: first)
        } else {
            // High Performance showing the Mac's own screens: virtual displays like them, made by
            // the back end, which are asked for again as they are.
            let displays = layout.displays
            guard !displays.isEmpty, displays.allSatisfy({ $0.kind == .virtual }) else { return }
            requests = withHDR(displays.map { display in
                let scale = max(1, Int(display.scale.rounded()))
                return VirtualDisplayRequest(pointSize: PixelSize(width: display.pixelSize.width / scale, height: display.pixelSize.height / scale), scale: scale)
            })
        }
        guard requests.map(\.wantsHDR) != requestedHDR else { return }
        requestDisplays(requests, from: configuration)
    }

    /// The session's window is on a screen that can show HDR, or not: reported when the window
    /// appears and whenever it moves to another screen (Stage Manager on an extended display).
    public func windowScreenChanged(showsHDR: Bool) {
        guard showsHDR != windowScreenShowsHDR else { return }
        windowScreenShowsHDR = showsHDR
        displaysChangedScreens()
    }

    /// Whether a display of the session is showing HDR pictures now.
    public var isShowingHDR: Bool {
        layout.displays.contains(where: \.isHDR)
    }

    private func paneChanged() {
        guard sizer != nil, phase == .connected else { return }
        guard isActive else {
            // iPadOS resizes a scene that is not active for its snapshots and the keyboard; the
            // Mac must not follow. The pane is looked at again on return.
            paneChangedWhileInactive = true
            return
        }
        let clock = dependencies.clock
        sizer?.paneChanged(to: stagePane, deviceScale: stagePaneScale, at: clock.uptime)
        sizerTask?.cancel()
        guard let deadline = sizer?.nextDeadline else { return }
        sizerTask = Task { [weak self] in
            try? await clock.sleep(for: .seconds(max(0, deadline - clock.uptime)))
            guard let self, !Task.isCancelled, let configuration = self.session?.capabilities.displayConfiguration.value else { return }
            // A new size, or the one there is: a pane that moved to another screen may need HDR, or
            // no longer have it, at any size.
            let proposal = self.sizer?.poll(at: clock.uptime)
            guard let first = proposal?.request ?? self.sizer?.lastProposal?.request ?? self.requestedDisplay?.request else { return }
            let requests = self.displayRequests(first: first)
            let resizes = proposal.map { !self.isCloseEnough($0.request) } ?? false
            guard resizes || requests.map(\.wantsHDR) != self.requestedHDR else { return }
            self.requestDisplays(requests, from: configuration)
        }
    }

    // MARK: External display

    /// The modes the View menu offers: none without a monitor; Both Displays only when the session
    /// has a second display to put there.
    public var availableExternalDisplayModes: [ExternalDisplayMode] {
        guard externalScreen != nil else { return [] }
        return layout.displays.count > 1 ? [.mirror, .externalOnly, .dual] : [.mirror, .externalOnly]
    }

    /// The remote display on the monitor, if Marionette draws one there.
    public var externalDisplay: RemoteDisplay? {
        guard externalScreen != nil else { return nil }
        switch externalDisplayMode {
        case .mirror: return externalMirrorsPicture ? selectedDisplay : nil
        case .externalOnly: return selectedDisplay
        case .dual: return layout.displays.first { $0.id != selectedDisplay?.id }
        }
    }

    /// A monitor was attached (or its scene resized). `preferredMode` applies when it was not
    /// attached before. `mirrorsPicture`: the system will not mirror this device (no accessory
    /// support), so in `.mirror` Marionette shows the device's remote display there itself.
    public func externalScreenChanged(_ screen: ExternalScreen, preferredMode: ExternalDisplayMode = .mirror, mirrorsPicture: Bool = false) {
        let isNew = externalScreen == nil
        let resized = externalScreen != screen
        externalScreen = screen
        externalMirrorsPicture = mirrorsPicture
        if isNew {
            let preferredMode = hasSecondaryVirtualDisplay ? .dual : preferredMode
            let available = availableExternalDisplayModes.contains(preferredMode)
            pendingExternalMode = available ? nil : preferredMode
            changeExternalDisplayMode(available ? preferredMode : .mirror)
        } else {
            updateExternalRenderer(restart: false)
            if externalDisplayMode == .externalOnly { paneChanged() }
        }
        if resized { resizeSecondaryDisplay() }
        displaysChangedScreens()
    }

    /// The monitor went away: back to the device alone, with the input mode the user had.
    public func externalScreenDisconnected() {
        guard externalScreen != nil else { return }
        pendingExternalMode = nil
        changeExternalDisplayMode(.mirror)
        externalScreen = nil
        updateExternalRenderer(restart: false)
        resizeSecondaryDisplay()
        displaysChangedScreens()
    }

    /// The user's choice; it replaces whatever was waiting to apply.
    public func setExternalDisplayMode(_ mode: ExternalDisplayMode) {
        pendingExternalMode = nil
        changeExternalDisplayMode(mode)
    }

    private func changeExternalDisplayMode(_ mode: ExternalDisplayMode) {
        let mode = externalScreen == nil || !availableExternalDisplayModes.contains(mode) ? .mirror : mode
        guard mode != externalDisplayMode else {
            updateExternalRenderer(restart: false)
            return
        }
        let wasExternalOnly = externalDisplayMode == .externalOnly
        externalDisplayMode = mode
        if mode == .externalOnly, inputModeBeforeExternal == nil {
            inputModeBeforeExternal = uiState.inputMode
            if uiState.inputMode != .trackpad {
                cancelGestures()
                uiState.inputMode = .trackpad
            }
        } else if mode != .externalOnly, let previous = inputModeBeforeExternal {
            inputModeBeforeExternal = nil
            if previous != uiState.inputMode {
                cancelGestures()
                uiState.inputMode = previous
            }
        }
        updateExternalRenderer(restart: false)
        if wasExternalOnly != (mode == .externalOnly) { paneChanged() }
    }

    /// Points ``externalRenderer`` at the display the monitor should show.
    private func updateExternalRenderer(restart: Bool) {
        if let pending = pendingExternalMode, phase == .connected, availableExternalDisplayModes.contains(pending) {
            pendingExternalMode = nil
            changeExternalDisplayMode(pending)
            return
        }
        if externalDisplayMode == .dual, layout.displays.count < 2, phase == .connected {
            changeExternalDisplayMode(.externalOnly)
            return
        }
        let target = phase == .connected ? externalDisplay : nil
        if let session, let target, restart || target.id != externalShownDisplay {
            externalRenderer.start(frames: session.frames(for: target.id), cursor: session.cursor())
            externalShownDisplay = target.id
        } else if target == nil, externalShownDisplay != nil {
            externalRenderer.stop()
            externalShownDisplay = nil
        }
        if let id = uiState.pointerDisplay, !isOnMonitor(id) || layout[id] == nil {
            uiState.pointerDisplay = nil
            if let display = selectedDisplay { uiState.pointer = display.clamping(uiState.pointer) }
            showLocalPointer()
        }
        pushExternalGeometry()
    }

    /// The whole display, fitted to the monitor and centred.
    private func pushExternalGeometry() {
        guard let screen = externalScreen, let display = externalDisplay, !screen.size.isEmpty else {
            externalContentFrame = nil
            return
        }
        let pixels = display.pixelSize
        guard pixels.width > 0, pixels.height > 0 else { return }
        let scale = min(screen.size.width / Double(pixels.width), screen.size.height / Double(pixels.height))
        let width = Double(pixels.width) * scale
        let height = Double(pixels.height) * scale
        let frame = ViewRect(x: (screen.size.width - width) / 2, y: (screen.size.height - height) / 2, width: width, height: height)
        externalContentFrame = frame
        externalRenderer.setGeometry(
            RenderGeometry(
                viewSize: CGSize(width: screen.size.width, height: screen.size.height),
                deviceScale: screen.scale,
                contentFrame: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                remoteScale: display.scale,
                desktopOrigin: PixelPoint(x: Double(display.frameInDesktop.x), y: Double(display.frameInDesktop.y))
            )
        )
        externalRenderer.setLocalPointer(display.id == pointerDisplay?.id ? uiState.pointer : nil)
    }

    /// A resize takes the remote machine a second or two and blanks nothing but is still a
    /// disturbance, so a pane that changed by a bar's height (a toolbar appearing, say) keeps the
    /// display it has and letterboxes by those few points instead.
    private func isCloseEnough(_ request: VirtualDisplayRequest) -> Bool {
        guard let display = selectedDisplay, display.kind == .virtual else { return false }
        let wanted = PixelSize(width: request.pointSize.width * request.scale, height: request.pointSize.height * request.scale)
        let current = display.pixelSize
        func close(_ a: Int, _ b: Int) -> Bool { abs(a - b) * 100 <= max(a, b) * 8 }
        return close(wanted.width, current.width) && close(wanted.height, current.height)
    }

    // MARK: Touch input

    /// Feeds one platform touch event (all of its touches together) to the right interpreter.
    public func handleTouches(_ samples: [TouchSample], on surface: TouchSurface) {
        if samples.contains(where: { $0.phase == .began }) { screenTouched() }
        // Touches the system took away let go of a held button, but not by the person's choice.
        if samples.contains(where: { $0.phase == .cancelled }) { fileDrags.inputWillBeReleased(everything: false) }
        run(on: surface) { interpreter, context in interpreter.handle(samples, context: &context) }
    }

    /// Abandons gestures in progress, releasing any button they hold.
    public func cancelGestures() {
        fileDrags.inputWillBeReleased(everything: false)
        for surface in [TouchSurface.stage, .deck] {
            run(on: surface) { interpreter, context in interpreter.cancel(context: &context) }
        }
    }

    private func run(
        on surface: TouchSurface,
        _ body: (inout any GestureInterpreter, inout InteractionContext) -> [InteractionEffect]
    ) {
        switch (surface, uiState.inputMode) {
        case (.deck, _), (.stage, .trackpad) where externalDisplayMode == .externalOnly:
            // With the picture on the monitor, this screen is a trackpad and nothing else.
            interact(relative: true) { context in
                var interpreter: any GestureInterpreter = deckTrackpad
                defer { deckTrackpad = interpreter as? TrackpadInterpreter ?? deckTrackpad }
                return body(&interpreter, &context)
            }
        case (.stage, .touch):
            if let directTouch {
                interact(relative: false) { context in
                    var interpreter: any GestureInterpreter = directTouch
                    defer { self.directTouch = interpreter as? DirectTouchInterpreter ?? directTouch }
                    return body(&interpreter, &context)
                }
            } else {
                interact(relative: false) { context in
                    var interpreter: any GestureInterpreter = touchInterpreter
                    defer { touchInterpreter = interpreter as? TouchInterpreter ?? touchInterpreter }
                    return body(&interpreter, &context)
                }
            }
        case (.stage, .trackpad):
            interact(relative: true) { context in
                var interpreter: any GestureInterpreter = stageTrackpad
                defer { stageTrackpad = interpreter as? TrackpadInterpreter ?? stageTrackpad }
                return body(&interpreter, &context)
            }
        }
        scheduleTimer()
    }

    /// Runs one interpreter step against the current viewport, pointer and target, then carries out
    /// what it asked for. Shared by touches, the mouse and the Pencil.
    ///
    /// `relative`: the input moves the pointer from where it is (a trackpad), so it goes on with the
    /// display the pointer is on, which may be the one on the monitor. Otherwise the input points at
    /// the device's display, and the pointer comes back to it if the input moved it.
    private func interact(relative: Bool, _ body: (inout InteractionContext) -> [InteractionEffect]) {
        let onMonitor = relative ? monitorPointerDisplay : nil
        var context = InteractionContext(
            viewport: onMonitor.map(monitorViewport(for:)) ?? uiState.viewport,
            target: acceptsInput ? PointerTarget(display: onMonitor ?? selectedDisplay, layout: layout) : nil,
            pointer: uiState.pointer,
            buttons: heldButtons,
            modifiers: uiState.modifiers.activeModifiers.union(keyboard.hardwareModifiers)
        )
        if !relative, uiState.pointerDisplay != nil, let display = selectedDisplay {
            context.pointer = display.clamping(context.pointer)
        }
        let startPointer = context.pointer
        let hadButtons = !heldButtons.isEmpty || !pointerInterpreter.heldButtons.isEmpty
        let effects = body(&context)
        heldButtons = context.buttons
        // The monitor's picture is always fitted: what a gesture did to its stand-in is dropped.
        if onMonitor == nil, context.viewport != uiState.viewport { uiState.viewport = context.viewport }
        let broughtBack = !relative && uiState.pointerDisplay != nil
            && effects.contains { if case .input(.pointer) = $0 { true } else { $0 == .pointerMoved } }
        if broughtBack { uiState.pointerDisplay = nil }
        if broughtBack || context.pointer != startPointer, context.pointer != uiState.pointer {
            uiState.pointer = context.pointer
        }
        var pressed = hadButtons
        for effect in effects {
            switch effect {
            case .input(let event):
                if case .pointer(let pointer) = event, !pointer.buttons.isEmpty { pressed = true }
                deliver(event)
            case .viewportChanged:
                if onMonitor == nil { pushGeometry() }
            case .pointerMoved: showLocalPointer()
            case .feedback(let feedback): onFeedback?(feedback)
            case .pointerPushedPastEdge(let position): pointerPushedPastEdge(to: position)
            }
        }
        if hadButtons || !effects.isEmpty { showLocalPointer() }
        if pressed, heldButtons.isEmpty, pointerInterpreter.heldButtons.isEmpty { consumeOneShotModifiers() }
    }

    /// The display on the monitor, while the pointer is on it.
    private var monitorPointerDisplay: RemoteDisplay? {
        uiState.pointerDisplay.flatMap { isOnMonitor($0) ? layout[$0] : nil }
    }

    /// The monitor's view of a display, fitted, as gestures need one to move the pointer by.
    private func monitorViewport(for display: RemoteDisplay) -> ViewportModel {
        guard let screen = externalScreen else { return uiState.viewport }
        return ViewportModel(viewSize: screen.size, contentSize: display.pixelSize, deviceScale: screen.scale, mode: .fit)
    }

    /// A trackpad pushed the pointer past an edge of its display. Across the edge Settings names
    /// (``SessionPreferences/secondaryDisplayEdge``) it goes on to the next display, across the
    /// opposite edge back to the one before, coming in at the same fraction of the way along the
    /// facing edge, with any held button still held. The next display is shown on this device, or,
    /// with Both Displays, stays on the monitor and the pointer moves there.
    private func pointerPushedPastEdge(to position: PixelPoint) {
        guard acceptsInput, let from = pointerDisplay,
              let index = layout.displays.firstIndex(where: { $0.id == from.id })
        else { return }
        let forward = inputPreferences.secondaryDisplayEdge
        let (exit, next): (DisplayEdge, Int)
        if forward.isPassed(by: position, in: from.pixelSize), index + 1 < layout.displays.count {
            (exit, next) = (forward, index + 1)
        } else if forward.opposite.isPassed(by: position, in: from.pixelSize), index > 0 {
            (exit, next) = (forward.opposite, index - 1)
        } else {
            return
        }
        let destination = layout.displays[next]
        let arrival = exit.opposite.point(at: exit.fraction(of: position, in: from.pixelSize), in: destination.pixelSize)

        if isOnMonitor(destination.id) {
            uiState.pointerDisplay = destination.id
        } else if destination.id == selectedDisplay?.id {
            uiState.pointerDisplay = nil
        } else {
            // A free zoom belongs to the display it was made on.
            show(display: destination.id, zoom: uiState.viewport.mode == .actualSize ? .actualSize : .fit)
        }
        uiState.pointer = arrival
        deliver(.pointer(PointerEvent(display: destination.id, position: arrival, buttons: heldButtons, layoutGeneration: layout.generation)))
        if destination.id == selectedDisplay?.id, uiState.viewport.reveal(arrival) != .zero {
            pushGeometry()
        }
        showLocalPointer()
    }

    // MARK: Mouse, trackpad and Pencil

    /// The system pointer moved over the remote display (hover, or a drag with buttons held).
    public func pointerMoved(to location: ViewPoint) {
        interact(relative: false) { pointerInterpreter.move(to: location, context: &$0) }
    }

    /// The complete set of mouse buttons now held.
    public func pointerButtons(_ buttons: PointerButtons, at location: ViewPoint) {
        interact(relative: false) { pointerInterpreter.setButtons(buttons, at: location, context: &$0) }
    }

    /// A step of a wheel or trackpad scroll. `delta` is in view points.
    public func pointerScrolled(by delta: ViewVector, at location: ViewPoint, phase: ScrollEvent.Phase, isPrecise: Bool = true) {
        interact(relative: false) { pointerInterpreter.scroll(by: delta, at: location, phase: phase, isPrecise: isPrecise, context: &$0) }
    }

    /// A trackpad pinch: zooms the view, sends nothing.
    public func pointerMagnified(by factor: Double, at location: ViewPoint) {
        interact(relative: false) { pointerInterpreter.magnify(by: factor, at: location, context: &$0) }
    }

    /// One Apple Pencil sample: the tip is the pointer, touching is the primary button.
    public func pencil(_ sample: TouchSample) {
        interact(relative: false) { pointerInterpreter.pencil(sample, context: &$0) }
    }

    private var nextGestureDeadline: Double? {
        [touchInterpreter.nextDeadline, stageTrackpad.nextDeadline, deckTrackpad.nextDeadline].compactMap(\.self).min()
    }

    private func scheduleTimer() {
        timerTask?.cancel()
        timerTask = nil
        guard let deadline = nextGestureDeadline else { return }
        let clock = dependencies.clock
        timerTask = Task { [weak self] in
            let wait = deadline - clock.uptime
            if wait > 0 { try? await clock.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            self.timerTask = nil
            let now = clock.uptime
            for surface in [TouchSurface.stage, .deck] {
                self.run(on: surface) { interpreter, context in
                    guard let due = interpreter.nextDeadline, due <= now else { return [] }
                    return interpreter.advance(to: now, context: &context)
                }
            }
        }
    }

    // MARK: Keyboard input

    /// Text from the software keyboard, an input method or dictation.
    public func insertText(_ text: String) {
        guard acceptsInput, !text.isEmpty else { return }
        send(translator.events(forInsertedText: text, modifiers: uiState.modifiers.activeModifiers))
        consumeOneShotModifiers()
    }

    public func deleteBackward() {
        guard acceptsInput else { return }
        send(translator.eventsForDeleteBackward(modifiers: uiState.modifiers.activeModifiers))
        consumeOneShotModifiers()
    }

    /// One press of a non-character key (Escape, Tab, arrows), with the latched modifiers.
    public func pressKey(_ key: KeyCode) {
        guard acceptsInput else { return }
        send(translator.stroke(key, modifiers: uiState.modifiers.activeModifiers))
        consumeOneShotModifiers()
    }

    /// Sends a shortcut, holding its modifiers for ``Shortcut/holdDuration``: apps that read the
    /// live modifier state miss a chord sent in one burst.
    public func perform(_ shortcut: Shortcut) {
        guard acceptsInput else { return }
        send(shortcut.pressEvents)
        let token = attempt
        Task { [weak self] in
            try? await Task.sleep(for: Shortcut.holdDuration)
            guard let self, self.attempt == token else { return }
            self.send(shortcut.releaseEvents)
        }
    }

    /// A key went down, on the on-screen keyboard or a hardware one. Auto-repeats from the system
    /// are swallowed; instead a held key repeats on a timer of its own, the way a Mac's keyboard
    /// does, because the remote machine does not repeat a key a viewer holds. Latched on-screen
    /// modifiers apply to hardware keys too.
    public func keyDown(
        _ key: KeyCode,
        characters: String? = nil,
        charactersIgnoringModifiers: String? = nil,
        source: KeyboardState.Source = .onScreen
    ) {
        guard acceptsInput else { return }
        keyboard.latchedModifiers = uiState.modifiers.activeModifiers
        let events = keyboard.keyDown(key, characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers, source: source)
        send(events)
        if !events.isEmpty, KeyboardState.repeats(key) { startRepeating(key, source: source) }
    }

    /// Repeats the key most recently pressed while it stays down, as macOS does.
    private func startRepeating(_ key: KeyCode, source: KeyboardState.Source) {
        keyRepeat?.cancel()
        keyRepeat = Task { [weak self] in
            try? await Task.sleep(for: KeyboardState.repeatDelay)
            while !Task.isCancelled {
                guard let self, self.acceptsInput else { return }
                let events = self.keyboard.repeatedKeyDown(key, source: source)
                guard !events.isEmpty else { return }
                self.send(events)
                try? await Task.sleep(for: KeyboardState.repeatInterval)
            }
        }
    }

    /// The matching key-up. Releasing a non-modifier key uses up one-shot modifiers.
    public func keyUp(_ key: KeyCode, source: KeyboardState.Source = .onScreen) {
        keyboard.latchedModifiers = uiState.modifiers.activeModifiers
        let events = keyboard.keyUp(key, source: source)
        send(events)
        if !events.isEmpty, key.modifier == nil { consumeOneShotModifiers() }
    }

    /// The hardware keyboard's caps-lock state, as last seen on a key event.
    public func setCapsLock(_ on: Bool) {
        keyboard.setCapsLock(on)
    }

    /// The modifiers the system says are held, as last seen on a key event: a modifier whose key-up
    /// went elsewhere (Stage Manager, a ⌘ chord iPadOS kept) is let go of here and on the remote
    /// machine. See ``KeyboardState/synchronize(flags:)``.
    public func synchronizeHardwareModifiers(_ flags: KeyModifiers) {
        send(keyboard.synchronize(flags: flags))
    }

    /// Whether any key is held right now (on screen or hardware).
    public var hasHeldKeys: Bool { !keyboard.isEmpty }

    /// Pastes text from this device: puts it on the remote clipboard and presses ⌘V there. Without
    /// clipboard sharing the text is typed instead.
    public func paste(_ text: String) {
        guard acceptsInput, !text.isEmpty else { return }
        guard clipboard.isAvailable else {
            insertText(text)
            return
        }
        bringClipboardOver(text)
    }

    /// Types a password at the remote machine as key presses. It goes on neither clipboard and is
    /// left out of ``inputTally``'s text.
    public func typePassword(_ password: String) {
        guard acceptsInput, !password.isEmpty else { return }
        // A modifier still down on the remote machine would make shortcuts of the characters.
        if !uiState.modifiers.isEmpty || hasHeldKeys { releaseAllInput() }
        for event in translator.events(forInsertedText: password, modifiers: []) { deliver(event, isSecret: true) }
        // Counted when it has gone: behind a paste on its way, it waits with its events.
        if pastesInFlight > 0 {
            heldDuringPaste.append(.passwordEnd)
        } else {
            inputTally.notePassword()
        }
    }

    /// Whether there is a password for the computer itself to type. See ``pasteLoginPassword()``.
    /// Never on a rung that speaks another protocol than the computer's own: like the sign-in
    /// there, what is typed over it gets nothing from the computer's saved or cached credentials.
    public var hasLoginPassword: Bool { acceptsInput && !isOnFallbackRung && prompts.hasLoginPassword }

    /// Types the computer's own password at the remote machine: the one sent when signing in, else
    /// the saved one. The device owner is asked first if the password requires them.
    public func pasteLoginPassword() {
        guard hasLoginPassword else { return }
        let token = attempt
        Task { [weak self] in
            guard let password = await self?.prompts.loginPassword() else { return }
            guard let self, self.attempt == token else { return }
            self.typePassword(password)
        }
    }

    /// Whether ⌘V on a hardware keyboard should come to ``pasteFromHardwareKeyboard(_:)`` (through
    /// the responder's `paste(_:)`, which gets the clipboard without a prompt) rather than travel as
    /// plain keys.
    public var routesHardwarePaste: Bool { acceptsInput && clipboard.isAvailable }

    /// ⌘V on a hardware keyboard: this device's clipboard goes to the remote one first, then the
    /// remote machine gets ⌘V. ⌘ is normally still held at that point and is already down there, so
    /// only V is pressed.
    public func pasteFromHardwareKeyboard(_ text: String?) {
        guard acceptsInput else { return }
        guard let text, !text.isEmpty, clipboard.isAvailable else {
            // Nothing to bring over: the remote machine pastes what it has.
            let keys = pasteKeys()
            send(keys.events)
            if keys.usesOneShots { consumeOneShotModifiers() }
            return
        }
        bringClipboardOver(text)
    }

    /// Puts `text` on the remote clipboard, then presses ⌘V there. Input that comes in meanwhile
    /// (typing straight after ⌘V, letting go of ⌘) is held and follows the paste's keys, so the remote
    /// machine sees everything in the order it was done.
    private func bringClipboardOver(_ text: String) {
        // The keys are settled now, while ⌘ is (or is not) held, not when the clipboard has arrived.
        let keys = pasteKeys()
        pastesInFlight += 1
        let token = attempt
        Task { [weak self] in
            guard let self else { return }
            let sent: Bool
            do {
                try await self.clipboard.sendPasted([ClipboardItem(text: text)])
                sent = true
            } catch {
                sent = false
            }
            self.pastesInFlight -= 1
            if sent, self.attempt == token, self.acceptsInput {
                for event in keys.events { self.transmit(event, isSecret: false) }
                if keys.usesOneShots { self.consumeOneShotModifiers() }
            }
            self.releaseHeldInput()
        }
    }

    /// ⌘V for the remote machine. If ⌘ is already down there (held on a hardware keyboard, or
    /// latched on screen) only V is pressed, so ⌘ is not let go of under the user's finger.
    private func pasteKeys() -> (events: [InputEvent], usesOneShots: Bool) {
        keyboard.latchedModifiers = uiState.modifiers.activeModifiers
        let held = keyboard.modifiers
        if held.hasCommand {
            return ([
                .key(KeyEvent(key: .v, charactersIgnoringModifiers: "v", modifiers: held, phase: .down)),
                .key(KeyEvent(key: .v, charactersIgnoringModifiers: "v", modifiers: held, phase: .up)),
            ], true)
        }
        return (Shortcut(id: "paste", title: String(localized: "Paste", bundle: #bundle), category: .editing, modifiers: .leftCommand, key: .v).events, false)
    }

    /// A tap on a modifier key: off → next key only → locked → off. A full keyboard's right-hand
    /// keys pass `.right`, so the remote machine sees the right-hand key.
    public func tapModifier(_ modifier: ModifierLatch.Modifier, side: ModifierLatch.Side = .left) {
        guard acceptsInput else { return }
        var latch = uiState.modifiers
        let events = latch.tap(modifier, side: side)
        uiState.modifiers = latch
        send(events.map(InputEvent.key))
    }

    private func consumeOneShotModifiers() {
        guard uiState.modifiers.hasOneShots else { return }
        var latch = uiState.modifiers
        let events = latch.consumeOneShots()
        uiState.modifiers = latch
        send(events.map(InputEvent.key))
    }

    private func send(_ events: [InputEvent]) {
        for event in events { deliver(event) }
    }

    private func deliver(_ event: InputEvent, isSecret: Bool = false) {
        switch event {
        case .pointer(let pointer):
            // While a drag of this device's files is over the picture, its place is the pointer's
            // and the back end holds the button down for it. A pointer event from here would let
            // go of it on the remote machine.
            if fileDrags.holdsRemotePointer { return }
            fileDrags.pointerEventWillBeSent(pointer)
        case .releaseAll:
            fileDrags.allInputReleased()
        default:
            break
        }
        if pastesInFlight > 0 {
            heldDuringPaste.append(.event(event, isSecret: isSecret))
            return
        }
        transmit(event, isSecret: isSecret)
    }

    /// What waits for a paste on its way.
    private enum HeldInput {
        case event(InputEvent, isSecret: Bool)
        /// The events of one password are all before this.
        case passwordEnd
    }

    /// `isSecret` keeps a password's characters out of ``inputTally``.
    private func transmit(_ event: InputEvent, isSecret: Bool) {
        guard let input = session?.input else { return }
        if !isSecret { inputTally.note(event) }
        input.send(event)
    }

    /// Sends what was held while pastes were on their way, once none is.
    private func releaseHeldInput() {
        guard pastesInFlight == 0, !heldDuringPaste.isEmpty else { return }
        let held = heldDuringPaste
        heldDuringPaste.removeAll()
        guard acceptsInput else { return }
        for item in held {
            switch item {
            case .event(let event, let isSecret): transmit(event, isSecret: isSecret)
            case .passwordEnd: inputTally.notePassword()
            }
        }
    }

    /// Lets go of every button and modifier, locally and on the remote machine.
    public func releaseAllInput() {
        releaseAllInput(notifyingRemote: true)
    }

    private func releaseAllInput(notifyingRemote: Bool) {
        // A drag of this device's files over the picture holds the remote button too.
        fileDrags.dragExited()
        fileDrags.inputWillBeReleased(everything: notifyingRemote)
        cancelGestures()
        interact(relative: false) { pointerInterpreter.cancel(context: &$0) }
        let keyUps = keyboard.releaseAll()
        if notifyingRemote { send(keyUps) }
        if !uiState.modifiers.isEmpty {
            var latch = uiState.modifiers
            let events = latch.releaseAll()
            uiState.modifiers = latch
            if notifyingRemote { send(events.map(InputEvent.key)) }
        }
        if notifyingRemote { deliver(.releaseAll) }
    }

    // MARK: Banners and thumbnails

    private func showFallbackBanner(for outcome: ConnectionLadder.Outcome) {
        guard let fallback = outcome.fallbacks.last else {
            if !isSessionEncrypted {
                show(SessionBanner(
                    kind: .fallback,
                    title: String(localized: "Not Secure", bundle: #bundle),
                    message: SessionBanner.notEncryptedMessage
                ))
            }
            return
        }
        let why: String = switch fallback.failure {
        case .modeUnavailable(_, let reason): reason.explanation
        case .busy(let detail): detail
        default: fallback.failure.message
        }
        let info = outcome.session.info
        if !info.isEncrypted, !info.isTunnelled {
            show(SessionBanner(
                kind: .fallback,
                title: String(localized: "Connected Without Encryption", bundle: #bundle),
                message: String(localized: "\(fallback.step.mode.title) isn’t available. \(why) \(SessionBanner.notEncryptedMessage)", bundle: #bundle)
            ))
            return
        }
        show(SessionBanner(kind: .fallback, title: String(localized: "Connected in \(outcome.step.mode.title) Mode", bundle: #bundle), message: String(localized: "\(fallback.step.mode.title) isn’t available. \(why)", bundle: #bundle)))
    }

    private func show(_ banner: SessionBanner) {
        bannerTask?.cancel()
        self.banner = banner
        guard let duration = dependencies.bannerDuration else { return }
        let clock = dependencies.clock
        bannerTask = Task { [weak self] in
            try? await clock.sleep(for: duration)
            guard let self, !Task.isCancelled, self.banner?.id == banner.id else { return }
            self.banner = nil
        }
    }

    /// Saves the last frame as the computer's library thumbnail.
    public func captureThumbnail() {
        guard !computer.isDemo, renderer.hasFrame, let repository = dependencies.repository else { return }
        let (renderer, id) = (renderer, computer.id)
        Task.detached(priority: .utility) {
            guard let image = renderer.snapshot(maximumPixelDimension: 960), let data = ThumbnailEncoder.jpegData(from: image) else { return }
            await MainActor.run { repository.setThumbnail(data, id: id) }
        }
    }

    private func savePreferences() {
        // Start from what is stored, so settings changed elsewhere while this session was open are kept.
        var preferences = SessionPreferences(defaults: dependencies.defaults)
        preferences.inputMode = inputModeBeforeExternal ?? uiState.inputMode
        preferences.inputPanel = inputPanelBeforeDocking ?? uiState.inputPanel
        preferences.isFullScreen = uiState.isFullScreen
        // Docking folds the strip away by itself; what is kept is what the user chose.
        preferences.areControlsCollapsed = controlsCollapsedBeforeDocking ?? uiState.areControlsCollapsed
        preferences.accessoryPage = uiState.accessoryPage
        if uiState.zoomMode != .free { preferences.zoomMode = uiState.zoomMode }
        preferences.isAudioMuted = isAudioMuted
        preferences.isHDREnabled = isHDREnabled
        preferences.save(to: dependencies.defaults)
    }
}

// MARK: - Drags of files

/// Where a session's remote picture can be: on this device, or on an attached monitor.
public enum PictureSurface: Sendable, Hashable {
    case device
    case externalDisplay
}

extension SessionModel {
    /// The surface the drop well for a drag on the remote machine belongs on: the one where the
    /// remote pointer can be seen reaching it. With the picture only on the monitor, that is the
    /// monitor; the device is a trackpad then.
    public var dropWellSurface: PictureSurface {
        externalDisplayMode == .externalOnly && externalScreen != nil ? .externalDisplay : .device
    }

    /// The part of the shown display's picture that can be seen on a surface, in the surface's
    /// points. The remote pointer cannot leave the picture, so a drop well has to lie in this.
    public func visiblePicture(on surface: PictureSurface) -> ViewRect? {
        switch surface {
        case .externalDisplay:
            return externalDisplay?.id == selectedDisplay?.id ? externalContentFrame : nil
        case .device:
            let (picture, available) = (uiState.viewport.contentFrame, uiState.viewport.availableRect)
            let (minX, minY) = (max(picture.minX, available.minX), max(picture.minY, available.minY))
            let (maxX, maxY) = (min(picture.maxX, available.maxX), min(picture.maxY, available.maxY))
            return maxX > minX && maxY > minY ? ViewRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : nil
        }
    }
}

extension SessionModel: FileDragHost {
    var pictureTakesFileDrags: Bool { acceptsInput && dropWellSurface == .device }

    func remotePlace(under point: ViewPoint) -> (display: DisplayID, position: PixelPoint)? {
        guard let display = selectedDisplay, uiState.viewport.contentFrame.contains(point) else { return nil }
        return (display.id, display.clamping(uiState.viewport.remotePoint(for: point)))
    }

    func fileDragMovedPointer(to position: PixelPoint) {
        uiState.pointerDisplay = nil
        uiState.pointer = position
        showLocalPointer()
    }

    var canTakeRemoteDrags: Bool { acceptsInput }

    func dropWellSurfacePoint(for position: PixelPoint, on display: DisplayID) -> ViewPoint? {
        guard let shown = selectedDisplay, shown.id == display else { return nil }
        switch dropWellSurface {
        case .device:
            return uiState.viewport.viewPoint(for: position)
        case .externalDisplay:
            guard let frame = visiblePicture(on: .externalDisplay), shown.pixelSize.width > 0, shown.pixelSize.height > 0 else { return nil }
            return ViewPoint(
                x: frame.x + position.x * frame.width / Double(shown.pixelSize.width),
                y: frame.y + position.y * frame.height / Double(shown.pixelSize.height)
            )
        }
    }

    var pointerOnDropWellSurface: ViewPoint? {
        pointerDisplay.flatMap { dropWellSurfacePoint(for: uiState.pointer, on: $0.id) }
    }

    func showFileDragNotice(_ banner: SessionBanner) {
        show(banner)
    }
}

extension ConnectionFailure {
    /// Whether an automatic reconnect should try again after this: the network or the computer
    /// may come back, or the viewer holding it may leave. Anything else would fail the same way,
    /// or ask the user the same question again.
    var isWorthRetrying: Bool {
        switch self {
        case .unreachable, .timedOut, .busy: true
        default: false
        }
    }
}
