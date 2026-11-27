// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
public import RemoteDesktopCore

/// Describes how a simulated remote machine behaves. Deterministic: the same scenario and the same
/// input always produce the same session.
public struct SimulationScenario: Sendable {
    public struct Display: Sendable, Hashable {
        public var name: String
        public var pixelSize: PixelSize
        public var scale: Double
        /// Its pictures are 10-bit HDR (PQ), as a Mac sends for an HDR virtual display.
        public var isHDR: Bool

        public init(name: String, pixelSize: PixelSize, scale: Double = 2, isHDR: Bool = false) {
            self.name = name
            self.pixelSize = pixelSize
            self.scale = scale
            self.isHDR = isHDR
        }
    }

    public struct Account: Sendable, Hashable {
        public var username: String
        public var password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    public struct RemoteFile: Sendable, Hashable {
        public var path: String
        public var contents: [UInt8]

        public init(path: String, contents: [UInt8]) {
            self.path = path
            self.contents = contents
        }
    }

    /// How the simulated machine takes part in drags of files, as a Mac does with its own viewer.
    public struct FileDrags: Sendable {
        /// The folder shown on the desktop. A viewer's drag let go over it lands there; anything
        /// else on the desktop takes no files.
        public var folder = "/Users/demo/Documents"
        /// The file shown on the desktop. Pressing on it and moving, with the button held, starts a
        /// drag of it on the machine, which ends when the button comes up.
        public var file = "/Users/demo/Documents/Readme.txt"
        /// How long the machine leaves a drop it does not take unanswered. A Mac never answers
        /// one; its back end gives up after a few seconds.
        public var refusalDelay: Duration = .seconds(1)
        /// Files the machine starts dragging by itself, this long after connecting, as if someone
        /// at it had picked them up. For screenshots, where nothing can touch the screen.
        public var automaticDrag: (after: Duration, paths: [String])?

        public init() {}
    }

    public var remoteName = "Demo Mac"
    /// Modes the simulated server offers. `automatic` picks the first that the path allows.
    public var offeredModes: [SessionMode] = [.highPerformance, .standard]
    public var displays: [Display] = [Display(name: String(localized: "Built-in Display", bundle: #bundle), pixelSize: PixelSize(width: 2560, height: 1600))]
    /// When set, the back end asks for credentials and accepts only these.
    public var account: Account? = Account(username: "demo", password: "demo")
    /// When set, someone else is at the console and the session-select prompt appears.
    public var consoleUser: String?
    /// How many requests to share the console user turns down before letting the viewer in.
    public var consoleDeclines = 0
    /// How long the console user takes to answer a request to share.
    public var consoleAnswerDelay: Duration = .zero
    /// Questions the SSH layer asks while the tunnel opens (host key, key passphrase,
    /// keyboard-interactive), in order. Only asked when the transport is tunnelled. Declining a host
    /// key fails the attempt with ``ConnectionFailure/hostKeyRejected(host:)``; declining anything else
    /// cancels it.
    public var tunnelPrompts: [SessionPrompt] = []
    /// Time spent in each connection phase.
    public var phaseDelay: Duration = .milliseconds(150)
    /// Fail the attempt with this error when the given phase is reached.
    public var failure: (phase: ConnectionPhase, error: ConnectionFailure)?
    /// End the session with this reason after it has been connected for the given time.
    public var disconnect: (after: Duration, reason: DisconnectReason)?
    /// Frames per second of the animated frame counter.
    public var frameRate = 30
    /// How long a virtual display change takes to apply.
    public var reconfigurationDelay: Duration = .milliseconds(250)
    /// How long the session takes to act on a suspend, as a real one that pauses its media does.
    public var suspendDelay: Duration = .zero
    /// Reject virtual display requests smaller than this, as real servers do.
    public var minimumVirtualPointSize = PixelSize(width: 800, height: 600)
    public var maximumVirtualDisplays = 2
    /// Virtual displays asked for in HDR (``VirtualDisplayRequest/wantsHDR``) get HDR pictures, as
    /// from a Mac and a device that both take them.
    public var makesHDRDisplays = true
    /// Text placed on the remote clipboard shortly after connecting, if any.
    public var initialRemoteClipboard: String?
    public var files: [RemoteFile] = [
        RemoteFile(path: "/Users/demo/Documents/Readme.txt", contents: Array("Hello from the demo Mac.\n".utf8)),
        RemoteFile(path: "/Users/demo/Documents/Notes.txt", contents: Array("Remember to stretch.\n".utf8)),
        RemoteFile(path: "/Users/demo/Pictures/Empty.png", contents: []),
    ]
    /// Whether the file transfer can list folders. `false` plays a drag-and-drop style transfer
    /// (Apple's own Screen Sharing file transfer): sending works, browsing does not.
    public var fileTransferCanBrowse = true
    /// Bytes per second for simulated file transfers.
    public var transferRate = 512 * 1024
    /// Drags of files to and from the machine. `nil` plays a server that knows none (plain VNC).
    public var fileDrags: FileDrags? = FileDrags()
    /// The most fingers the machine takes as a touch screen of its own; 0 for none, as before
    /// macOS 27.3.
    public var touchContacts = 0
    /// Produce a continuous test tone on the audio capability.
    public var playsTone = true
    /// Whether the session reports itself encrypted (``SessionInfo/isEncrypted``), as Apple's
    /// protocol is and plain VNC is not.
    public var encryptsSession = true
    /// Whether the login proves the server's identity (``SessionInfo/isServerAuthenticated``), as
    /// Apple's SRP login does. A server without it refuses a request that requires it.
    public var provesServerIdentity = false

    public init() {}

    // MARK: Presets

    /// Apple silicon Mac reachable directly: High Performance, audio, virtual displays.
    public static var highPerformance: SimulationScenario { SimulationScenario() }

    /// Same Mac through an SSH tunnel: Standard only, no audio.
    public static var standard: SimulationScenario {
        var scenario = SimulationScenario()
        scenario.offeredModes = [.standard]
        return scenario
    }

    /// A generic VNC server: password only, one fixed display, text clipboard.
    public static var genericVNC: SimulationScenario {
        var scenario = SimulationScenario()
        scenario.remoteName = "Demo Linux"
        scenario.offeredModes = [.standard]
        scenario.displays = [Display(name: String(localized: "Screen 0", bundle: #bundle), pixelSize: PixelSize(width: 1920, height: 1080), scale: 1)]
        scenario.maximumVirtualDisplays = 0
        scenario.playsTone = false
        scenario.encryptsSession = false
        scenario.fileDrags = nil
        return scenario
    }

    /// Two physical displays of different density, side by side.
    public static var twoDisplays: SimulationScenario {
        var scenario = SimulationScenario()
        scenario.displays = [
            Display(name: String(localized: "Built-in Display", bundle: #bundle), pixelSize: PixelSize(width: 2560, height: 1600), scale: 2),
            Display(name: String(localized: "External Display", bundle: #bundle), pixelSize: PixelSize(width: 1920, height: 1080), scale: 1),
        ]
        return scenario
    }
}
