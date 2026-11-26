// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import os

/// What the server is asked for, and the throughput behind it.
let qualityLog = Logger(subsystem: "llc.turing.Marionette", category: "vnc-quality")

/// How faithfully the server is asked to send the desktop.
public enum VNCQuality: Sendable, Hashable {
    /// Follows the link: JPEG quality and colour depth fall as the measured throughput does (see
    /// ``VNCAdaptiveSettings``).
    case automatic
    /// No JPEG and full colour: every pixel exact.
    case lossless
}

/// What the server is asked for: a JPEG quality for Tight, 0 (small) to 9 (faithful), or `nil` for
/// none, and full colour or 256 colours.
package struct VNCAdaptiveSettings: Sendable, Hashable {
    package var jpegQuality: Int?
    package var isFullColour: Bool

    package init(jpegQuality: Int?, isFullColour: Bool) {
        self.jpegQuality = jpegQuality
        self.isFullColour = isFullColour
    }

    package static let lossless = VNCAdaptiveSettings(jpegQuality: nil, isFullColour: true)

    /// Above this a link is a local network's, and gets quality 8, the highest short of 9 and
    /// meant to look lossless; slower links get 6.
    package static let localNetworkBitsPerSecond = 16_000_000
    /// Below this a screenful takes seconds even as JPEG, and the server sends 256 colours, a
    /// quarter of the bytes of full colour before compression.
    package static let fullColourBitsPerSecond = 256_000
    /// Full colour comes back only above this, so that an estimate wandering about the threshold
    /// does not switch the colours every few seconds, as it did on a 200 kbit/s link to Xtigervnc.
    package static let fullColourAgainBitsPerSecond = 320_000

    /// What a link of `bitsPerSecond` calls for, given whether the session is in full colour now.
    package static func automatic(bitsPerSecond: Int, isFullColour: Bool = true) -> VNCAdaptiveSettings {
        VNCAdaptiveSettings(
            jpegQuality: bitsPerSecond > localNetworkBitsPerSecond ? 8 : 6,
            isFullColour: bitsPerSecond > (isFullColour ? fullColourBitsPerSecond : fullColourAgainBitsPerSecond)
        )
    }
}

/// The throughput of the link, measured on framebuffer updates: the bytes of an update over the
/// time from its header to its end. Only time spent receiving counts, so an idle desktop does not
/// look like a slow link.
///
/// Each update moves the estimate in proportion to how long it took, by up to a fifth: a long update
/// says more about the link than a short one, whose time is mostly latency and decoding, and no
/// single update can swing the estimate on its own.
package struct VNCThroughputEstimate: Sendable, Hashable {
    /// Where the estimate starts: a fast local network, so a session starts at full fidelity and
    /// falls only once the link proves slower.
    package static let initialBitsPerSecond = 20_000_000
    /// An update this long moves the estimate all the way, were its weight not capped.
    package static let window = Duration.seconds(1)
    /// The most one update moves the estimate, in parts per million.
    package static let maximumWeight = 200_000

    package private(set) var bitsPerSecond: Int

    package init(bitsPerSecond: Int = initialBitsPerSecond) {
        self.bitsPerSecond = bitsPerSecond
    }

    /// Folds in one update of `bytes` that took `elapsed` from its header to its end.
    package mutating func add(bytes: Int, elapsed: Duration) {
        let microseconds = max(Self.microseconds(elapsed), 1)
        let sample = Int64(max(bytes, 0)) * 8 * 1_000_000 / microseconds
        let weight = min(microseconds * 1_000_000 / Self.microseconds(Self.window), Int64(Self.maximumWeight))
        let blended = (Int64(bitsPerSecond) * (1_000_000 - weight) + sample * weight) / 1_000_000
        bitsPerSecond = Int(clamping: blended)
    }

    private static func microseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }
}
