// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation

/// A feature a session either offers, with the object that drives it, or does not, with the reason.
public enum Capability<Value: Sendable>: Sendable {
    case available(Value)
    case unavailable(UnavailableReason)

    public var value: Value? {
        if case .available(let value) = self { value } else { nil }
    }

    public var unavailableReason: UnavailableReason? {
        if case .unavailable(let reason) = self { reason } else { nil }
    }

    public var isAvailable: Bool { value != nil }
}

/// Everything optional about a session. Front ends build their controls from this and nothing else.
/// Capabilities can change while connected; watch ``SessionEvent/capabilitiesChanged(_:)``.
public struct SessionCapabilities: Sendable {
    public var clipboard: Capability<any ClipboardSync> = .unavailable(.notSupportedByBackend)
    public var fileTransfer: Capability<any FileTransfer> = .unavailable(.notSupportedByBackend)
    public var fileDrag: Capability<any FileDragAndDrop> = .unavailable(.notSupportedByBackend)
    public var audio: Capability<any AudioOutput> = .unavailable(.notSupportedByBackend)
    public var displayConfiguration: Capability<any DisplayConfiguration> = .unavailable(.notSupportedByBackend)
    public var quality: Capability<any QualityControl> = .unavailable(.notSupportedByBackend)
    public var control: Capability<any SessionControl> = .unavailable(.notSupportedByBackend)
    public var remoteActions: Capability<any RemoteActions> = .unavailable(.notSupportedByBackend)
    public var curtain: Capability<any CurtainControl> = .unavailable(.notSupportedByBackend)
    public var statistics: Capability<any SessionStatisticsSource> = .unavailable(.notSupportedByBackend)
    /// Fingers go to the remote machine as they are (``InputEvent/touch(_:)``), as on a touch screen
    /// of its own, instead of being turned into pointer input here.
    public var touch: Capability<TouchInput> = .unavailable(.notSupportedByBackend)

    public init() {}
}

// MARK: - Touch

/// What a remote machine's touch screen takes.
public struct TouchInput: Sendable, Hashable {
    /// The most fingers it follows at once. Further fingers are not sent.
    public var maximumContacts: Int

    public init(maximumContacts: Int) {
        self.maximumContacts = maximumContacts
    }
}

// MARK: - Clipboard

/// One pasteboard item in every representation its owner offers, keyed by uniform type identifier
/// ("public.utf8-plain-text", "public.png", ...).
public struct ClipboardItem: Sendable, Hashable {
    public var representations: [String: Data]

    public init(representations: [String: Data]) {
        self.representations = representations
    }

    public init(text: String) {
        representations = ["public.utf8-plain-text": Data(text.utf8)]
    }

    public var text: String? {
        representations["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// The remote clipboard changed. Contents are fetched only when wanted: they can be large.
public struct RemoteClipboardOffer: Sendable {
    /// Increases with every remote change.
    public var changeCount: UInt64
    /// Type identifiers on offer, when the protocol reveals them before fetching.
    public var typeIdentifiers: [String]
    private let loader: @Sendable () async throws -> [ClipboardItem]

    public init(
        changeCount: UInt64,
        typeIdentifiers: [String],
        loader: @escaping @Sendable () async throws -> [ClipboardItem]
    ) {
        self.changeCount = changeCount
        self.typeIdentifiers = typeIdentifiers
        self.loader = loader
    }

    public func load() async throws -> [ClipboardItem] {
        try await loader()
    }
}

public protocol ClipboardSync: Sendable {
    /// Remote clipboard changes, newest only.
    func remoteOffers() -> AsyncStream<RemoteClipboardOffer>
    /// Replaces the remote clipboard. An empty array clears it.
    func sendToRemote(_ items: [ClipboardItem]) async throws
}

// MARK: - Files

public struct RemoteFileEntry: Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: UInt64?
    public var modified: Date?

    public init(path: String, name: String, isDirectory: Bool, size: UInt64? = nil, modified: Date? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    public var id: String { path }
}

public struct TransferProgress: Sendable, Hashable {
    public var bytesTransferred: UInt64
    /// `nil` when the size is not known in advance.
    public var totalBytes: UInt64?

    public init(bytesTransferred: UInt64, totalBytes: UInt64?) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesTransferred) / Double(totalBytes))
    }
}

public protocol FileTransfer: Sendable {
    /// Whether ``list(directory:)`` works. Drag-and-drop style transports can send and receive but
    /// cannot browse.
    var canBrowse: Bool { get }
    /// Where uploads go when the user does not choose.
    func defaultUploadDirectory() async throws -> String
    func list(directory: String) async throws -> [RemoteFileEntry]
    /// Copies a local file to the remote machine. The stream finishes on success and throws on
    /// failure; cancelling the consuming task cancels the transfer.
    func upload(from localFile: URL, toDirectory remoteDirectory: String) -> AsyncThrowingStream<TransferProgress, any Error>
    func download(_ remotePath: String, to localFile: URL) -> AsyncThrowingStream<TransferProgress, any Error>
}

// MARK: - File drags

/// Files being dragged on the remote machine, which this side may take.
public struct RemoteFileDrag: Sendable, Hashable {
    /// What is dragged, as paths on the remote machine that ``FileTransfer/download(_:to:)`` takes.
    public var paths: [String]
    /// The picture the remote machine shows under its pointer, as PNG, when it sends one.
    public var previewPNG: Data?

    public init(paths: [String], previewPNG: Data? = nil) {
        self.paths = paths
        self.previewPNG = previewPNG
    }
}

public enum FileDragError: Error, Sendable, Hashable {
    /// What was under the drag when it was let go takes no files: on a Mac only folders, Finder
    /// windows and the desktop do.
    case notAccepted
    /// Another drag of this kind is still under way.
    case busy
    /// The session ended first.
    case sessionEnded
}

/// A drag of this device's files over the remote display, from the moment it enters. The remote
/// machine shows it as a drag of its own: folders under it light up as it moves.
public protocol OutgoingFileDrag: Sendable {
    /// The drag moved, in the display's pixels.
    func move(to position: PixelPoint, on display: DisplayID)
    /// Lets go where the drag is. Returns the remote folder the files belong in, for
    /// ``FileTransfer/upload(from:toDirectory:)``; throws ``FileDragError/notAccepted`` when what
    /// is there takes no files.
    func drop() async throws -> String
    /// Ends the drag without dropping: it left the display or was abandoned.
    func cancel()
}

/// Dragging files between this device and the remote machine, as its own viewer does: a drag from
/// here lands in the folder it is dropped on, and a drag of files there can be taken over here.
public protocol FileDragAndDrop: Sendable {
    /// The drag of files under way on the remote machine: a value when one starts, `nil` when it
    /// ends. Replays the current one to a new subscriber.
    func remoteDrags() -> AsyncStream<RemoteFileDrag?>
    /// Takes the remote drag over: the remote machine drops it nowhere when its button comes up.
    /// The files are then fetched with ``FileTransfer/download(_:to:)``.
    func takeRemoteDrag()
    /// Starts a drag of files called `names` at a place on the remote display. One at a time.
    func beginDrag(names: [String], at position: PixelPoint, on display: DisplayID) throws(FileDragError) -> any OutgoingFileDrag
}

// MARK: - Audio

/// Decoded remote audio, ready to play.
public struct AudioChunk: Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    /// Interleaved 32-bit float samples.
    public var samples: Data
    /// When the first sample should be heard, on the same clock as ``DisplayFrame/presentationTime``.
    public var presentationTime: ContinuousClock.Instant

    public init(sampleRate: Double, channelCount: Int, samples: Data, presentationTime: ContinuousClock.Instant) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
        self.presentationTime = presentationTime
    }

    public var frameCount: Int {
        channelCount > 0 ? samples.count / (MemoryLayout<Float32>.size * channelCount) : 0
    }
}

public protocol AudioOutput: Sendable {
    /// Decoded audio. One consumer at a time; a new call ends the previous stream.
    func chunks() -> AsyncStream<AudioChunk>
}

// MARK: - Displays

public struct VirtualDisplayRequest: Sendable, Hashable {
    /// Size in points. Pixel size is this multiplied by `scale`.
    public var pointSize: PixelSize
    /// 1 or 2.
    public var scale: Int
    public var refreshRate: Int
    public var wantsHDR: Bool

    public init(pointSize: PixelSize, scale: Int = 2, refreshRate: Int = 60, wantsHDR: Bool = false) {
        self.pointSize = pointSize
        self.scale = scale
        self.refreshRate = refreshRate
        self.wantsHDR = wantsHDR
    }
}

public enum PhysicalDisplaySelection: Sendable, Hashable {
    /// Every display, combined into one desktop.
    case all
    case single(DisplayID)
}

public struct DisplayConfigurationLimits: Sendable, Hashable {
    /// 0 when the session cannot create virtual displays.
    public var maximumVirtualDisplays: Int
    /// The least size of a virtual display at scale 1, in points.
    public var minimumPointSize: PixelSize
    /// The least size of a virtual display at scale 2, in points. A Mac wants more room for a
    /// HiDPI display than for a plain one, which matters on a phone: its pane is narrower than
    /// this, so it is served at scale 1 with twice the points.
    public var minimumHiDPIPointSize: PixelSize
    /// The most pixels a virtual display may have on each side, at any scale.
    public var maximumPixelSize: PixelSize
    public var canSelectPhysicalDisplays: Bool

    public init(
        maximumVirtualDisplays: Int,
        minimumPointSize: PixelSize,
        minimumHiDPIPointSize: PixelSize? = nil,
        maximumPixelSize: PixelSize,
        canSelectPhysicalDisplays: Bool
    ) {
        self.maximumVirtualDisplays = maximumVirtualDisplays
        self.minimumPointSize = minimumPointSize
        self.minimumHiDPIPointSize = minimumHiDPIPointSize ?? minimumPointSize
        self.maximumPixelSize = maximumPixelSize
        self.canSelectPhysicalDisplays = canSelectPhysicalDisplays
    }
}

public protocol DisplayConfiguration: Sendable {
    var limits: DisplayConfigurationLimits { get }
    /// Replaces the session's virtual displays. Returns once the new layout is live. Rapid calls are
    /// coalesced: only the most recent request is guaranteed to be applied.
    func setVirtualDisplays(_ requests: [VirtualDisplayRequest]) async throws
    func selectPhysicalDisplays(_ selection: PhysicalDisplaySelection) async throws
}

// MARK: - Quality

public enum QualityPreset: Sendable, Hashable, CaseIterable {
    /// Trade fidelity for responsiveness on slow links.
    case adaptive
    /// Pixel-exact, whatever it costs.
    case full
}

public protocol QualityControl: Sendable {
    var supportedPresets: [QualityPreset] { get }
    func setPreset(_ preset: QualityPreset) async throws
}

// MARK: - Control

public enum ControlMode: Sendable, Hashable, CaseIterable {
    /// Watch only; input is not sent.
    case observe
    /// Share control with whoever is at the remote machine.
    case control
    /// Control with the remote machine's own keyboard and mouse locked out.
    case exclusive
}

public protocol SessionControl: Sendable {
    var supportedModes: [ControlMode] { get }
    func setControlMode(_ mode: ControlMode) async throws
}

// MARK: - Remote actions

/// System functions that have no reliable key combination across setups.
public enum RemoteAction: Sendable, Hashable, CaseIterable {
    case missionControl
    case appExpose
    case launchpad
    case showDesktop
    case lockScreen
}

public protocol RemoteActions: Sendable {
    var supportedActions: Set<RemoteAction> { get }
    func perform(_ action: RemoteAction) async throws
}

// MARK: - Curtain

/// Curtain mode: the remote machine's own screen shows a lock screen, with a note, while this
/// session goes on working, so nobody at the machine sees what is done in it.
///
/// Whether the curtain is up is the remote machine's word, never this side's guess: a request that
/// the machine did not carry out leaves ``isCurtained`` as it was. Every change arrives as a
/// ``SessionEvent/capabilitiesChanged(_:)`` with a new value of this capability.
public protocol CurtainControl: Sendable {
    /// Whether the curtain is up, as the remote machine last reported.
    var isCurtained: Bool { get }
    /// Raises the curtain, showing `note` on it, or lowers it. Returns once the request is sent.
    /// Lowering it, or ending the session, may leave the remote machine at its lock screen.
    func setCurtained(_ curtained: Bool, note: String) async throws
}

// MARK: - Statistics

public struct SessionStatistics: Sendable, Hashable {
    public var framesPerSecond: Double?
    /// Received payload, bits per second.
    public var bitrate: Double?
    /// Fraction of media packets lost, 0...1.
    public var packetLoss: Double?
    public var roundTripTime: Duration?
    /// Time from arrival to ready-to-present.
    public var decodeLatency: Duration?
    public var videoCodec: String?

    public init(
        framesPerSecond: Double? = nil,
        bitrate: Double? = nil,
        packetLoss: Double? = nil,
        roundTripTime: Duration? = nil,
        decodeLatency: Duration? = nil,
        videoCodec: String? = nil
    ) {
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.packetLoss = packetLoss
        self.roundTripTime = roundTripTime
        self.decodeLatency = decodeLatency
        self.videoCodec = videoCodec
    }
}

public protocol SessionStatisticsSource: Sendable {
    /// About one value per second while subscribed.
    func statistics() -> AsyncStream<SessionStatistics>
}
