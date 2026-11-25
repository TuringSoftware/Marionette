// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopRender
import SwiftUI
import UIKit

/// Hosts the renderer's Metal layer. The renderer belongs to the session model, so a new instance
/// (after a fold, in another window) only moves the layer and the picture never goes away.
struct DisplaySurface: UIViewRepresentable {
    let renderer: DisplayRenderer

    func makeUIView(context: Context) -> SurfaceView {
        SurfaceView()
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        view.attach(renderer)
    }

    final class SurfaceView: UIView {
        private var metalLayer: CAMetalLayer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        func attach(_ renderer: DisplayRenderer) {
            let layer = renderer.layer
            guard metalLayer !== layer else { return }
            metalLayer?.removeFromSuperlayer()
            metalLayer = layer
            self.layer.addSublayer(layer)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The layer follows the view exactly; implicit animations would lag behind a resize.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}
