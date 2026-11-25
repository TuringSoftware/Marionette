// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MarionetteKit

/// How the device is folded, as far as layout is concerned.
///
/// This file and `SessionArrangement.swift` are the only places that use iPhone Duo API; everything
/// in them is behind `#available(iOS 27.1, *)`. The pose comes from the system's *division* reserved
/// region — where it says content should split — never from the hinge angle.
struct FoldContext: Hashable {
    enum Pose: Hashable {
        /// No active fold: closed, opened flat, or a device that does not fold.
        case flat
        /// An active fold running across the screen (laptop pose): the input deck gets the lower pane.
        case docked
        /// An active fold running down the screen (book pose, partly open): panes stay overlaid.
        case book
    }

    var pose: Pose = .flat
    /// The fold's frame in the arrangement's coordinate space, when there is one.
    var division: CGRect?
    /// True when a test argument, not the system, produced this context.
    var isSimulated = false

    /// Reads the fold from the system for a view's geometry.
    @MainActor
    static func resolve(_ proxy: GeometryProxy) -> FoldContext {
        if #available(iOS 27.1, *) {
            guard let fold = proxy.reservedRegions(kind: .division).first(where: \.isActive) else { return FoldContext() }
            return FoldContext(pose: fold.frame.width >= fold.frame.height ? .docked : .book, division: fold.frame)
        }
        return FoldContext()
    }

    /// The context a `-MarionetteFoldOverride` argument stands for, in a container of the given size.
    static func simulated(_ override: FoldOverride, in size: CGSize) -> FoldContext {
        let thickness = 12.0
        switch override {
        case .docked:
            return FoldContext(pose: .docked, division: CGRect(x: 0, y: (size.height - thickness) / 2, width: size.width, height: thickness), isSimulated: true)
        case .book:
            return FoldContext(pose: .book, division: CGRect(x: (size.width - thickness) / 2, y: 0, width: thickness, height: size.height), isSimulated: true)
        }
    }
}

extension EnvironmentValues {
    @Entry var foldContext = FoldContext()
}

/// Tells its content which side the system stands its bars up along, when it does: on the outer
/// display of a closed iPhone Duo the title bar becomes a column on the trailing side. `nil`
/// everywhere bars are horizontal, and on systems without the notion.
struct VerticalBarEdgeReader<Content: View>: View {
    @ViewBuilder var content: (HorizontalEdge?) -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            Reader(content: content)
        } else {
            content(nil)
        }
    }

    @available(iOS 27.1, *)
    private struct Reader<Inner: View>: View {
        @Environment(\.toolbarVerticalEdge) private var edge
        @ViewBuilder var content: (HorizontalEdge?) -> Inner

        var body: some View { content(edge) }
    }
}
