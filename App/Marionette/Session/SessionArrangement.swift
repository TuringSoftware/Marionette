// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MarionetteKit

/// Arranges the remote display and the input deck.
///
/// On iOS 27.1, an `ArrangementView` in the overlay style, vertical axis only: the input deck is the
/// *primary* view, anchored to the bottom edge; the remote display is the *secondary* view. Closed or
/// flat, the deck overlays a full-bleed remote display; divided at the fold, the display takes the
/// pane above and the deck the pane below. Both stay the same views in the same tree, so nothing is
/// swapped on folding; their state lives in the session model.
///
/// Earlier systems, which have no fold, get the same two views in a `ZStack`.
struct SessionArrangement<Stage: View, Deck: View>: View {
    var foldOverride: FoldOverride?
    /// Told the pose whenever it changes, so that bars outside the arrangement can follow it.
    var onPoseChange: (FoldContext.Pose) -> Void = { _ in }
    @ViewBuilder var stage: Stage
    @ViewBuilder var deck: Deck

    var body: some View {
        GeometryReader { proxy in
            let context = foldOverride.map { FoldContext.simulated($0, in: proxy.size) } ?? FoldContext.resolve(proxy)
            Group {
                if foldOverride != nil {
                    SimulatedFoldArrangement(context: context) { stage } deck: { deck }
                } else if context.pose == .docked {
                    // Laid out here from the reported fold rather than by the overlay style's own
                    // transition, which on iPhone Duo leaves the deck filling the screen, its top empty.
                    DockedArrangement(context: context) { stage } deck: { deck }
                        .environment(\.foldContext, context)
                } else {
                    systemArrangement
                        .environment(\.foldContext, context)
                }
            }
            .onChange(of: context.pose, initial: true) { _, pose in onPoseChange(pose) }
        }
    }

    @ViewBuilder
    private var systemArrangement: some View {
        if #available(iOS 27.1, *) {
            ArrangementView {
                deck.overlayArrangementEdge(.bottom)
            } secondary: {
                stage
            }
            .arrangementViewStyle(.overlay.axes(.vertical))
        } else {
            ZStack {
                stage
                deck
            }
        }
    }
}

/// A stand-in for the hinge, selected with `-MarionetteFoldOverride`, since the simulator cannot be
/// folded from the command line. Lays the panes out as the system is *expected* to when the device is
/// partly open, and labels itself on screen. It tests this app's layout, not the system's.
private struct SimulatedFoldArrangement<Stage: View, Deck: View>: View {
    let context: FoldContext
    @ViewBuilder var stage: Stage
    @ViewBuilder var deck: Deck

    var body: some View {
        Group {
            switch context.pose {
            case .docked:
                DockedArrangement(context: context) { stage } deck: { deck }
            case .book, .flat:
                ZStack {
                    stage
                    deck
                    foldLine
                        .frame(width: context.division?.width ?? 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .environment(\.foldContext, context)
        .overlay(alignment: .top) {
            Text("Simulated fold")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.yellow, in: .capsule)
                .foregroundStyle(.black)
                .padding(.top, 4)
                .accessibilityIdentifier("simulated-fold-label")
        }
    }

    private var foldLine: some View {
        Rectangle()
            .fill(.black)
            .overlay { Rectangle().fill(.white.opacity(0.18)).frame(width: context.pose == .docked ? nil : 1, height: context.pose == .docked ? 1 : nil) }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// The laptop pose: the remote display in the pane above the fold, the input deck in the pane below,
/// the fold itself left black. The panes come from the fold's frame, so each view is offered exactly
/// its pane whatever the system's own arrangement would have done.
private struct DockedArrangement<Stage: View, Deck: View>: View {
    let context: FoldContext
    @ViewBuilder var stage: Stage
    @ViewBuilder var deck: Deck

    var body: some View {
        GeometryReader { proxy in
            let fold = context.division ?? CGRect(x: 0, y: proxy.size.height / 2 - 6, width: proxy.size.width, height: 12)
            VStack(spacing: 0) {
                stage
                    .frame(height: max(0, fold.minY))
                    .clipped()
                Color.black
                    .frame(height: max(0, fold.height))
                    .accessibilityHidden(true)
                deck
                    .frame(maxHeight: .infinity)
            }
        }
    }
}
