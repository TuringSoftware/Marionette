// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// Reports whether the screen its window is on can show HDR: when it appears, and again whenever
/// the window may have moved to another screen (Stage Manager on an extended display).
struct ScreenHDRReader: UIViewRepresentable {
    let changed: (Bool) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.changed = changed
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.changed = changed
        // Reporting changes observed state, which must not happen inside SwiftUI's update.
        DispatchQueue.main.async { view.report() }
    }

    final class ReaderView: UIView {
        var changed: ((Bool) -> Void)?
        private var reported: Bool?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            // A window moving to another screen takes that screen's traits.
            registerForTraitChanges([UITraitDisplayScale.self, UITraitDisplayGamut.self]) { (view: ReaderView, _) in
                view.report()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        /// Reports every time, not only on a change: the view can outlive the session it first
        /// reported to (a new session on the same screen), and the receivers ignore repeats.
        func report() {
            guard let screen = window?.windowScene?.screen else { return }
            let showsHDR = screen.potentialEDRHeadroom > 1
            if Self.tracing, showsHDR != reported {
                print("marionette: screen \(Int(screen.bounds.width)) × \(Int(screen.bounds.height)) pt, \(window?.windowScene?.session.role.rawValue ?? "no scene"): EDR headroom \(screen.potentialEDRHeadroom) potential, \(screen.currentEDRHeadroom) now")
            }
            reported = showsHDR
            changed?(showsHDR)
        }

        /// What each screen says about HDR goes to the console with the back end's trace.
        private static let tracing = ProcessInfo.processInfo.arguments.contains("-MarionetteDiagnostics")
    }
}
