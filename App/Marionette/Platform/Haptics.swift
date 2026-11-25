// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopInteraction
import UIKit

/// Haptics for gesture milestones (click, long-press, drag start).
///
/// Trackpad feedback mimics a Mac trackpad: a crisp tick when the button goes down (click,
/// secondary click, drag start) and a lighter one when it comes up at the end of a drag.
@MainActor
final class GestureHaptics {
    private let press = UIImpactFeedbackGenerator(style: .rigid)
    private let impact = UIImpactFeedbackGenerator(style: .medium)

    func play(_ feedback: InteractionEffect.Feedback) {
        switch feedback {
        case .click, .secondaryClick, .dragBegan: press.impactOccurred(intensity: 0.9)
        case .dragEnded: press.impactOccurred(intensity: 0.5)
        case .longPress: impact.impactOccurred()
        }
    }
}
