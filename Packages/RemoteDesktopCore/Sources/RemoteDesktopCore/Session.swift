// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

/// How pixels travel from the remote machine.
public enum SessionMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Hardware video stream with audio (Apple's High Performance screen sharing).
    case highPerformance
    /// Framebuffer updates over the control connection.
    case standard
}

/// Steps of a connection attempt, in order, for progress display.
public enum ConnectionPhase: Sendable, Hashable {
    case openingTunnel
    case reachingHost
    case negotiating
    case authenticating
    case waitingForRemoteUser
    case preparingDisplays
    case startingMedia
}

public enum SessionState: Sendable, Hashable {
    /// Frames and input are flowing.
    case connected
    /// The app is in the background; media is paused and will resume.
    case suspended
    /// Terminal. A session never leaves this state.
    case disconnected(DisconnectReason)

    public var isDisconnected: Bool {
        if case .disconnected = self { true } else { false }
    }
}

/// Something worth telling the user that is not an error.
public enum SessionNotice: Sendable, Hashable {
    /// The remote machine's screen is locked or at the login window.
    case remoteScreenLocked(Bool)
    /// A secure text field has focus on the remote machine; pasting may be blocked.
    case remoteSecureInput(Bool)
    case bell
    case message(String)
}

public enum SessionEvent: Sendable {
    case stateChanged(SessionState)
    case layoutChanged(DesktopLayout)
    case capabilitiesChanged(SessionCapabilities)
    case notice(SessionNotice)
}

/// Facts fixed when the session was established.
public struct SessionInfo: Sendable, Hashable {
    /// Identifier of the back end that produced the session.
    public var backendID: String
    public var mode: SessionMode
    /// The remote machine's own name for itself.
    public var remoteName: String
    /// Short description of how the control connection is protected, for display ("SRP + AES-128").
    public var securityDescription: String
    public var isTunnelled: Bool
    /// The protocol itself encrypts everything after the login (an SSH tunnel around an
    /// unencrypted protocol does not count here; see ``isTunnelled``).
    public var isEncrypted: Bool
    /// The server proved during the login that it holds the account's password (Apple's SRP), so
    /// it is the computer the password belongs to. Logins that only protect the password in
    /// transit (Diffie-Hellman, VNC's challenge) prove nothing about the server.
    public var isServerAuthenticated: Bool

    public init(
        backendID: String,
        mode: SessionMode,
        remoteName: String,
        securityDescription: String,
        isTunnelled: Bool,
        isEncrypted: Bool = false,
        isServerAuthenticated: Bool = false
    ) {
        self.backendID = backendID
        self.mode = mode
        self.remoteName = remoteName
        self.securityDescription = securityDescription
        self.isTunnelled = isTunnelled
        self.isEncrypted = isEncrypted
        self.isServerAuthenticated = isServerAuthenticated
    }
}

/// A live connection to a remote desktop.
///
/// Thread-safe. Every method may be called from any task. A session is created connected and ends in
/// ``SessionState/disconnected(_:)``; reconnecting means asking the back end for a new session.
public protocol RemoteSession: AnyObject, Sendable {
    var info: SessionInfo { get }

    /// Current values. Each is also announced through ``events()`` when it changes.
    var state: SessionState { get }
    var layout: DesktopLayout { get }
    var capabilities: SessionCapabilities { get }

    /// State, layout, capability and notice changes. Every call returns an independent stream that
    /// ends after the terminal `stateChanged(.disconnected)`.
    func events() -> AsyncStream<SessionEvent>

    /// Frames of one display, latest-wins. The first element is the current surface with full
    /// damage, if one exists. Ends when the display goes away or the session disconnects.
    func frames(for display: DisplayID) -> FrameMailbox

    /// Pointer shape and position, latest-wins; starts with the current state.
    func cursor() -> AsyncStream<CursorState>

    var input: any InputSink { get }

    /// Pauses media while the app cannot show it. Input sent while suspended is discarded.
    func suspend() async
    /// Resumes after ``suspend()``; may renegotiate media. If the connection did not survive, the
    /// session moves to `disconnected(.connectionLost)`.
    func resume() async

    /// Ends the session. Returns once the state is `disconnected`. Idempotent.
    func disconnect() async
}

/// What the user asked for when connecting.
public struct SessionOptions: Sendable, Hashable {
    public enum ModePreference: Sendable, Hashable, Codable {
        /// The best mode the path and server allow.
        case automatic
        case require(SessionMode)
    }

    public enum DisplayPreference: Sendable, Hashable {
        /// Show the remote machine's own displays.
        case physical(PhysicalDisplaySelection)
        /// Create displays for this session where the mode supports it, else fall back to physical.
        case virtual([VirtualDisplayRequest])
    }

    public var mode: ModePreference
    public var displays: DisplayPreference
    public var quality: QualityPreset
    public var controlMode: ControlMode
    public var wantsAudio: Bool
    public var wantsClipboard: Bool
    /// Shown to the remote machine where the protocol has a place for it.
    public var clientName: String
    /// Refuse every login in which the server does not prove it holds the password (see
    /// ``SessionInfo/isServerAuthenticated``), before anything is sent. Set for a computer that
    /// has proved itself before, so that an impostor offering a weaker login gets nothing.
    public var requiresServerAuthentication: Bool
    /// Refuse a session the protocol itself would not encrypt, before anything but the login is
    /// sent, with no unencrypted fallback. Set for a computer whose sessions were encrypted before,
    /// so nothing on the network can downgrade a saved connection.
    public var requiresEncryption: Bool
    /// Whether virtual displays the back end makes by itself (High Performance showing the Mac's
    /// own screens) are asked for in HDR, like ``VirtualDisplayRequest/wantsHDR`` for requested ones.
    public var wantsHDR: Bool

    public init(
        mode: ModePreference = .automatic,
        displays: DisplayPreference = .physical(.all),
        quality: QualityPreset = .adaptive,
        controlMode: ControlMode = .control,
        wantsAudio: Bool = true,
        wantsClipboard: Bool = true,
        clientName: String = "Marionette",
        requiresServerAuthentication: Bool = false,
        requiresEncryption: Bool = false,
        wantsHDR: Bool = false
    ) {
        self.wantsHDR = wantsHDR
        self.mode = mode
        self.displays = displays
        self.quality = quality
        self.controlMode = controlMode
        self.wantsAudio = wantsAudio
        self.wantsClipboard = wantsClipboard
        self.clientName = clientName
        self.requiresServerAuthentication = requiresServerAuthentication
        self.requiresEncryption = requiresEncryption
    }
}

/// Everything a back end needs to produce a session.
public struct ConnectionRequest: Sendable {
    public var options: SessionOptions
    public var transport: any TransportProvider
    public var prompts: any PromptHandler
    /// Called as the attempt advances. May be called from any thread.
    public var progress: @Sendable (ConnectionPhase) -> Void

    public init(
        options: SessionOptions = SessionOptions(),
        transport: any TransportProvider,
        prompts: any PromptHandler,
        progress: @escaping @Sendable (ConnectionPhase) -> Void = { _ in }
    ) {
        self.options = options
        self.transport = transport
        self.prompts = prompts
        self.progress = progress
    }
}

public struct BackendDescriptor: Sendable, Hashable {
    /// Stable identifier, persisted with saved computers ("apple-screen-sharing", "vnc").
    public var id: String
    public var displayName: String
    public var defaultPort: UInt16
    /// Bonjour service type that advertises compatible machines, if any ("_rfb._tcp").
    public var bonjourServiceType: String?
    public var supportedModes: [SessionMode]

    public init(id: String, displayName: String, defaultPort: UInt16, bonjourServiceType: String?, supportedModes: [SessionMode]) {
        self.id = id
        self.displayName = displayName
        self.defaultPort = defaultPort
        self.bonjourServiceType = bonjourServiceType
        self.supportedModes = supportedModes
    }
}

/// A remote-desktop protocol implementation.
public protocol RemoteDesktopBackend: Sendable {
    var descriptor: BackendDescriptor { get }

    /// Connects and returns a session in the ``SessionState/connected`` state.
    ///
    /// Honours task cancellation by throwing ``ConnectionFailure/cancelled`` and leaving nothing open.
    /// A back end connects in exactly the mode the options resolve to; falling back to another mode
    /// or back end is the caller's decision, guided by the thrown failure.
    func connect(_ request: ConnectionRequest) async throws(ConnectionFailure) -> any RemoteSession
}
