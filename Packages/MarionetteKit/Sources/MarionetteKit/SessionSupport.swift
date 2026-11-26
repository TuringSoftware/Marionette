// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
public import Foundation
import ImageIO
public import RemoteDesktopCore
import UniformTypeIdentifiers

/// Where a session is in its life.
public enum SessionPhase: Sendable, Hashable {
    /// A connection attempt is running; the associated value is the step it has reached.
    case connecting(ConnectionPhase?)
    case connected
    /// The connection dropped and is being re-established. The last frame stays on screen.
    case reconnecting(attempt: Int)
    /// A connection attempt failed. The user chooses a recovery action or closes.
    case failed(ConnectionFailure)
    /// An established session ended and will not come back by itself.
    case ended(DisconnectReason)
    /// The session is over and its screen should go away.
    case closed

    public var isConnecting: Bool {
        if case .connecting = self { true } else { false }
    }

    /// Whether there is a remote display worth showing (live, or the last frame of a dropped one).
    public var showsRemoteDisplay: Bool {
        switch self {
        case .connected, .reconnecting, .ended: true
        case .connecting, .failed, .closed: false
        }
    }
}

/// When automatic reconnection tries again: exponential backoff up to a cap, with jitter, so that
/// viewers dropped together (by a router restarting, say) do not all come back at the same instant.
public struct ReconnectionPolicy: Sendable, Hashable {
    /// How many attempts are made before giving up. Zero turns automatic reconnection off.
    public var attempts: Int
    /// The wait before the first attempt. Each later wait is twice the one before, up to
    /// `maximumDelay`.
    public var initialDelay: Duration
    public var maximumDelay: Duration
    /// The share of each wait left to chance: with 0.5, a wait is between half and all of it.
    public var jitter: Double

    public init(attempts: Int = 4, initialDelay: Duration = .seconds(1), maximumDelay: Duration = .seconds(8), jitter: Double = 0.5) {
        self.attempts = attempts
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.jitter = jitter
    }

    /// The wait before attempt `attempt` (counted from 1). `random` is drawn from 0...1.
    public func delay(beforeAttempt attempt: Int, random: Double) -> Duration {
        let doublings = min(max(attempt - 1, 0), 30)
        let full = min(initialDelay * (1 << doublings), maximumDelay)
        return full * (1 - min(max(jitter, 0), 1) * min(max(random, 0), 1))
    }
}

/// A message shown over the session without interrupting it.
public struct SessionBanner: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// The session is running in a lesser mode than hoped.
        case fallback
        case information
    }

    public let id: UUID
    public var kind: Kind
    public var title: String
    public var message: String

    public init(kind: Kind, title: String, message: String) {
        id = UUID()
        self.kind = kind
        self.title = title
        self.message = message
    }

    /// Said wherever a session that is not encrypted is described.
    public static let notEncryptedMessage = String(localized: "This connection isn’t encrypted. What you see and type can be read on the network.", bundle: #bundle)
}

/// A value snapshot of a session's optional features, for building menus.
public struct SessionFeatures: Sendable, Hashable {
    public enum Availability: Sendable, Hashable {
        case available
        case unavailable(UnavailableReason)

        public var isAvailable: Bool { self == .available }

        init<T>(_ capability: Capability<T>) {
            switch capability {
            case .available: self = .available
            case .unavailable(let reason): self = .unavailable(reason)
            }
        }
    }

    public var audio: Availability = .unavailable(.notSupportedByBackend)
    public var clipboard: Availability = .unavailable(.notSupportedByBackend)
    public var fileTransfer: Availability = .unavailable(.notSupportedByBackend)
    /// Dragging files onto the remote picture and off it.
    public var fileDrag: Availability = .unavailable(.notSupportedByBackend)
    public var qualityPresets: [QualityPreset] = []
    public var qualityUnavailableReason: UnavailableReason?
    /// In the order of `RemoteAction.allCases`.
    public var remoteActions: [RemoteAction] = []
    /// Curtain mode, and whether the remote machine says its curtain is up.
    public var curtain: Availability = .unavailable(.notSupportedByBackend)
    public var isCurtained = false
    public var maximumVirtualDisplays = 0
    public var canSelectPhysicalDisplays = false
    /// The remote machine takes fingers as they are, as a touch screen of its own; `nil` when it
    /// does not.
    public var touch: TouchInput?

    public init() {}

    init(_ capabilities: SessionCapabilities) {
        audio = Availability(capabilities.audio)
        clipboard = Availability(capabilities.clipboard)
        fileTransfer = Availability(capabilities.fileTransfer)
        fileDrag = Availability(capabilities.fileDrag)
        qualityPresets = capabilities.quality.value?.supportedPresets ?? []
        qualityUnavailableReason = capabilities.quality.unavailableReason
        let supported = capabilities.remoteActions.value?.supportedActions ?? []
        remoteActions = RemoteAction.allCases.filter(supported.contains)
        curtain = Availability(capabilities.curtain)
        isCurtained = capabilities.curtain.value?.isCurtained ?? false
        if let limits = capabilities.displayConfiguration.value?.limits {
            maximumVirtualDisplays = limits.maximumVirtualDisplays
            canSelectPhysicalDisplays = limits.canSelectPhysicalDisplays
        }
        touch = capabilities.touch.value
    }
}

/// Identifies a window showing one display of one session.
public struct SessionWindowID: Sendable, Hashable, Codable {
    public var sessionID: UUID
    public var displayID: UInt32

    public init(sessionID: UUID, displayID: UInt32) {
        self.sessionID = sessionID
        self.displayID = displayID
    }
}

/// Counts of what a session has sent to the remote machine.
public struct InputTally: Sendable, Hashable {
    /// The most recent characters typed, as text or as character keys.
    public private(set) var typed = ""
    public private(set) var keyPresses = 0
    public private(set) var clicks = 0
    public private(set) var secondaryClicks = 0
    public private(set) var scrolls = 0
    /// Fingers that landed on a remote machine that takes touches.
    public private(set) var touches = 0
    private var buttons: PointerButtons = []
    private var touching: Set<Int> = []

    public init() {}

    mutating func note(_ event: InputEvent) {
        switch event {
        case .text(let text):
            typed = String((typed + text).suffix(64))
        case .key(let key) where key.phase == .down:
            keyPresses += 1
            if key.key?.modifier == nil, !key.modifiers.hasCommand, !key.modifiers.hasControl, let characters = key.characters {
                typed = String((typed + characters).suffix(64))
            }
        case .pointer(let pointer):
            let pressed = pointer.buttons.subtracting(buttons)
            if pressed.contains(.primary) { clicks += 1 }
            if pressed.contains(.secondary) { secondaryClicks += 1 }
            buttons = pointer.buttons
        case .scroll(let scroll) where scroll.phase == .began || scroll.phase == .none:
            scrolls += 1
        case .touch(let touch):
            let down = Set(touch.contacts.filter { $0.phase == .touching }.map(\.id))
            touches += down.subtracting(touching).count
            touching = down
        case .releaseAll:
            buttons = []
            touching = []
        default:
            break
        }
    }

    /// One line, for an accessibility value.
    public var summary: String {
        String(localized: "typed “\(typed)”, \(keyPresses) key presses, \(clicks) clicks, \(secondaryClicks) secondary clicks, \(scrolls) scrolls, \(touches) touches", bundle: #bundle)
    }
}

enum ThumbnailEncoder {
    /// JPEG data for a library thumbnail.
    static func jpegData(from image: CGImage, quality: Double = 0.8) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
