// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// Shows its content as is when it fits, in a scroll view otherwise: at the largest text sizes a
/// message and its buttons can be taller than the screen.
struct ScrollIfNeeded<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }
}

extension Color {
    /// The accent colour as a fill under white text: the app icon's crimson, 5.5:1 with white in
    /// either appearance. The accent colour itself is lighter in dark mode, too light under white.
    static let prominentFill = Color(.displayP3, red: 0.752, green: 0.178, blue: 0.228)

    /// Red for text. The system red reaches only about 3.2:1 as small text on a form's background;
    /// this is 4.8:1 or better on every background it is used on.
    static let errorText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.412, blue: 0.380, alpha: 1)
            : UIColor(red: 0.843, green: 0, blue: 0.082, alpha: 1)
    })
}
