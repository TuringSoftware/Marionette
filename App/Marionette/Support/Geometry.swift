// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import RemoteDesktopInteraction
import SwiftUI

extension ViewPoint {
    init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }
}

extension ViewInsets {
    /// Physical insets from SwiftUI's leading/trailing ones.
    init(_ insets: EdgeInsets, layoutDirection: LayoutDirection) {
        let leftToRight = layoutDirection == .leftToRight
        self.init(
            top: insets.top,
            left: leftToRight ? insets.leading : insets.trailing,
            bottom: insets.bottom,
            right: leftToRight ? insets.trailing : insets.leading
        )
    }
}

extension CGRect {
    init(_ rect: ViewRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
