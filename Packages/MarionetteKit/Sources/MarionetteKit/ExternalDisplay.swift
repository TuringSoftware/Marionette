// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
public import RemoteDesktopInteraction

/// How an attached monitor is used during a session.
public enum ExternalDisplayMode: String, Sendable, Hashable, CaseIterable {
    /// The system mirrors the device. Marionette draws nothing of its own on the monitor.
    case mirror
    /// The remote display moves to the monitor; the device becomes its trackpad and keyboard.
    case externalOnly
    /// The device shows one remote display and the monitor another.
    case dual

    public var title: String {
        switch self {
        case .mirror: String(localized: "Mirror This Device", bundle: #bundle)
        case .externalOnly: String(localized: "External Display Only", bundle: #bundle)
        case .dual: String(localized: "Both Displays", bundle: #bundle)
        }
    }

    public var symbolName: String {
        switch self {
        case .mirror: "rectangle.on.rectangle"
        case .externalOnly: "display"
        case .dual: "display.2"
        }
    }
}

/// The monitor as the app sees it: the size of the scene it got for it.
public struct ExternalScreen: Sendable, Hashable {
    /// In points.
    public var size: ViewSize
    /// Pixels per point.
    public var scale: Double

    public init(size: ViewSize, scale: Double) {
        self.size = size
        self.scale = scale
    }
}
