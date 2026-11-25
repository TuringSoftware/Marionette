// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A group of buttons: side by side when all fit on one line at full size, stacked otherwise.
///
/// Give the most important button first: stacked, it is on top; side by side, it is trailing, as in
/// an alert.
struct ActionButtons<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Laid out in the opposite direction so the first button ends up trailing; the buttons
            // themselves keep the real direction.
            HStack(spacing: spacing) {
                content.environment(\.layoutDirection, layoutDirection)
            }
            .environment(\.layoutDirection, layoutDirection == .leftToRight ? .rightToLeft : .leftToRight)
            VStack(spacing: spacing) {
                content
            }
        }
    }
}
