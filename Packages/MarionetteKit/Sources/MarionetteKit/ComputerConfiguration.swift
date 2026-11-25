// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
public import RemoteDesktopCore

/// Everything the user chose for one computer, apart from secrets. A plain value: the editor works on
/// a copy, the connection ladder reads it, and SwiftData stores it.
public struct ComputerConfiguration: Sendable, Hashable, Codable, Identifiable {
    public enum Mode: String, Sendable, Hashable, Codable, CaseIterable {
        case automatic
        case highPerformance
        case standard
    }

    public enum Quality: String, Sendable, Hashable, Codable, CaseIterable {
        case adaptive
        case full
    }

    public enum Display: String, Sendable, Hashable, Codable, CaseIterable {
        /// Show the remote machine's own displays.
        case remoteDisplays
        /// Ask for a virtual display shaped like this device (High Performance only; other modes
        /// show the computer's own displays). The default for a new computer.
        case fitToDevice
    }

    public struct Tunnel: Sendable, Hashable, Codable {
        public var isEnabled = false
        /// Empty means "the computer's own address".
        public var host = ""
        public var port: UInt16 = 22
        public var username = ""
        /// The SSH key to log in with, by its name in the ``SSHKeyStore``. `nil` means password only.
        public var keyName: String?

        public init() {}
    }

    public var id: UUID
    /// Display name. Empty means "use the address".
    public var name: String
    public var host: String
    /// `nil` means the back end's default port.
    public var port: UInt16?
    public var backendID: String
    public var username: String
    public var mode: Mode
    public var quality: Quality
    public var display: Display
    public var tunnel: Tunnel
    public var audioEnabled: Bool
    public var clipboardEnabled: Bool
    public var observeOnly: Bool
    /// The built-in demo computer, which talks to the simulated back end and is never saved.
    public var isDemo: Bool

    // Settings added after the first release are stored optionally, so that computers saved
    // before them still decode; each has its default behind it.
    private var retina: Bool?
    private var secondDisplay: Bool?

    /// Fit This Device: ask for a Retina (2x) display wherever the Mac makes one for the pane's
    /// shape, the picture then scaled to fit; off, a 1x display of the device's own pixels.
    public var prefersRetina: Bool {
        get { retina ?? true }
        set { retina = newValue }
    }

    /// Fit This Device: a second virtual display from the start of the session, shown on an
    /// external display when one is connected, and otherwise one display switch away. A Mac keeps
    /// the number of displays a High Performance session started with.
    public var hasSecondaryDisplay: Bool {
        get { secondDisplay ?? false }
        set { secondDisplay = newValue }
    }

    public init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: UInt16? = nil,
        backendID: String = BackendID.appleScreenSharing,
        username: String = "",
        mode: Mode = .automatic,
        quality: Quality = .adaptive,
        display: Display = .fitToDevice,
        tunnel: Tunnel = Tunnel(),
        audioEnabled: Bool = true,
        clipboardEnabled: Bool = true,
        observeOnly: Bool = false,
        isDemo: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.backendID = backendID
        self.username = username
        self.mode = mode
        self.quality = quality
        self.display = display
        self.tunnel = tunnel
        self.audioEnabled = audioEnabled
        self.clipboardEnabled = clipboardEnabled
        self.observeOnly = observeOnly
        self.isDemo = isDemo
    }

    /// What to call the computer in the interface.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? host : trimmed
    }

    /// A computer whose protocol is found out on connecting, Screen Sharing or VNC, rather than
    /// fixed (the demo). ``backendID`` then says what it was last found to speak.
    public var speaksDetectedProtocol: Bool {
        backendID == BackendID.appleScreenSharing || backendID == BackendID.vnc
    }

    /// Last found to be a VNC server that is not a Mac: Screen Sharing's modes mean nothing to it.
    public var isKnownVNCServer: Bool { backendID == BackendID.vnc }

    /// High Performance needs a direct path for its UDP media, which an SSH tunnel cannot carry,
    /// and a Mac.
    public var allowsHighPerformance: Bool { !tunnel.isEnabled && !isKnownVNCServer }
    /// Audio only exists in High Performance.
    public var allowsAudio: Bool { allowsHighPerformance && mode != .standard }
    /// A display made to fit this device only exists in High Performance.
    public var allowsFittedDisplay: Bool { allowsHighPerformance && mode != .standard }

    /// The mode actually requested, after the tunnel restriction.
    public var effectiveMode: Mode {
        allowsHighPerformance ? mode : .standard
    }

    public var endpoint: Endpoint {
        Endpoint(host: host, port: port ?? 5900)
    }

    /// The SSH server the tunnel goes through: its own address, or the computer itself.
    public var tunnelServer: Endpoint {
        let host = tunnel.host.trimmingCharacters(in: .whitespaces)
        return Endpoint(host: host.isEmpty ? self.host : host, port: tunnel.port)
    }

    /// Whether the tunnel's SSH server is the computer itself rather than a machine in front of it.
    public var tunnelServerIsComputer: Bool {
        tunnelServer.host.caseInsensitiveCompare(host) == .orderedSame
    }

    /// The account for the tunnel's SSH server: its own, or the computer's.
    public var tunnelUsername: String {
        let name = tunnel.username.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? username : name
    }

    /// Entered as the address of a computer, "demo" opens the built-in demo computer.
    public var isDemoAddress: Bool {
        !isDemo && host.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("demo") == .orderedSame
    }

    /// The built-in demo computer.
    public static let demo = ComputerConfiguration(
        id: UUID(uuidString: "00000000-0000-4000-8000-00000000D3E0")!,
        name: String(localized: "Demo Mac", bundle: #bundle),
        host: "demo.local",
        backendID: BackendID.simulated,
        username: "demo",
        isDemo: true
    )
}

/// A saved computer together with what the library shows about its history.
public struct ComputerRecord: Sendable, Hashable, Identifiable {
    public var configuration: ComputerConfiguration
    /// Encoded image (JPEG or PNG) of the last frame seen, if any.
    public var thumbnail: Data?
    public var lastConnected: Date?
    /// The mode the last session negotiated.
    public var lastMode: SessionMode?

    public init(configuration: ComputerConfiguration, thumbnail: Data? = nil, lastConnected: Date? = nil, lastMode: SessionMode? = nil) {
        self.configuration = configuration
        self.thumbnail = thumbnail
        self.lastConnected = lastConnected
        self.lastMode = lastMode
    }

    public var id: UUID { configuration.id }
}

/// Splits what people type or paste into an address field: `user@host:port`, `vnc://host:port`,
/// `[v6::addr]:port`, or just a host.
public struct ParsedAddress: Sendable, Hashable {
    public var host: String
    public var port: UInt16?
    public var username: String?
    public var backendID: String?

    public init?(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        if let range = rest.range(of: "://") {
            switch rest[..<range.lowerBound].lowercased() {
            case "vnc", "rfb": backendID = nil
            default: return nil
            }
            rest = String(rest[range.upperBound...])
        }
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        if let at = rest.lastIndex(of: "@") {
            let user = String(rest[..<at])
            username = user.isEmpty ? nil : user
            rest = String(rest[rest.index(after: at)...])
        }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...]
            if tail.hasPrefix(":") {
                guard let value = UInt16(tail.dropFirst()), value > 0 else { return nil }
                port = value
            } else if !tail.isEmpty {
                return nil
            }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            guard let value = UInt16(rest[rest.index(after: colon)...]), value > 0 else { return nil }
            port = value
        } else {
            // No colon, or several: a bare IPv6 literal.
            host = rest
        }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "[" || $0 == "]" }) else { return nil }
    }
}
