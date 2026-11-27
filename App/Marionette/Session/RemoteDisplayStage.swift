// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import RemoteDesktopInteraction
import SwiftUI
import MarionetteKit

/// The remote display: the Metal surface, the view that captures input over it, and status.
///
/// The display is content, so it runs edge to edge under the bars. The safe area is not used for
/// layout here; it is handed to the viewport model, which letterboxes a fitted desktop inside it so
/// that the remote menu bar and Dock never sit under a bar.
struct RemoteDisplayStage: View {
    let session: SessionModel
    @Environment(\.displayScale) private var displayScale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.launchOptions) private var launchOptions
    @Environment(\.foldContext) private var fold

    private struct Metrics: Equatable {
        var size: CGSize
        var insets: ViewInsets
        var scale: CGFloat
    }

    /// Folded like a laptop the stage has the pane above the fold and nothing under it: below are
    /// the fold and the other pane, where a system keyboard comes up with its edge against this
    /// pane's. Running under that keyboard, or counting it as this view's own margin, would size the
    /// stage, and with it the remote display, for both panes (iOS 27.1, iPhone Duo).
    private var isDocked: Bool { fold.pose == .docked }
    private var ignoredRegions: SafeAreaRegions { isDocked ? .container : .all }
    private var ignoredEdges: Edge.Set { isDocked ? [.top, .horizontal] : .all }

    private func stageInsets(_ proxy: GeometryProxy) -> EdgeInsets {
        var insets = proxy.safeAreaInsets
        if isDocked { insets.bottom = 0 }
        return insets
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = stageInsets(proxy)
            let metrics = Metrics(
                size: CGSize(
                    width: proxy.size.width + insets.leading + insets.trailing,
                    height: proxy.size.height + insets.top + insets.bottom
                ),
                insets: ViewInsets(insets, layoutDirection: layoutDirection),
                scale: displayScale
            )
            ZStack {
                if session.externalDisplayMode == .externalOnly {
                    ExternalOnlyTrackpad(session: session)
                } else {
                    DisplaySurface(renderer: session.renderer)
                }
                InputCapture(
                    session: session,
                    surface: .stage,
                    takesKeyboard: session.phase == .connected && session.prompts.pending == nil && !session.uiState.isPasswordEntryPresented,
                    showsKeyboard: session.uiState.isKeyboardRequested,
                    accessibilityLabel: String(localized: "Remote Display, \(session.selectedDisplay?.name ?? session.title)"),
                    reportsDiagnostics: launchOptions.reportsDiagnostics
                )
                // In the picture's coordinates, like the two above, so the remote pointer can reach it.
                RemoteDragWell(session: session, surface: .device)
            }
            .ignoresSafeArea(ignoredRegions, edges: ignoredEdges)
            // Out of full screen the picture keeps running under the bars, as in full screen; a
            // frosted edge keeps the title and the bar's buttons legible over it.
            .overlay {
                if !session.uiState.showsFullScreen {
                    VerticalBarEdgeReader { edge in
                        BarEdgeEffect(insets: insets, verticalBarEdge: edge)
                    }
                    .ignoresSafeArea(ignoredRegions, edges: ignoredEdges)
                    .transition(.opacity)
                }
            }
            // Laid out against the whole screen, so the strip can sit just above whatever is at the
            // bottom: the keyboard, the deck, or nothing.
            .overlay(alignment: .bottom) {
                VerticalBarEdgeReader { edge in
                    if session.uiState.isPasswordEntryPresented {
                        PasswordEntryBar(
                            session: session,
                            bottomInset: insets.bottom,
                            leadingInset: insets.leading,
                            trailingInset: insets.trailing,
                            barEdge: edge
                        )
                    } else {
                        ControlStrip(
                            session: session,
                            bottomInset: insets.bottom,
                            leadingInset: insets.leading,
                            trailingInset: insets.trailing,
                            barEdge: edge
                        )
                    }
                }
                .ignoresSafeArea(ignoredRegions, edges: ignoredEdges)
            }
            .onChange(of: metrics, initial: true) { _, new in
                session.stageLayoutChanged(size: new.size, safeArea: new.insets, deviceScale: new.scale)
            }
        }
        // The keyboard must not resize the stage; the viewport model slides the desktop instead.
        .ignoresSafeArea(isDocked ? [] : .keyboard)
        .background { Color.black.ignoresSafeArea() }
        .overlay { StageStatus(session: session) }
        .overlay(alignment: .top) {
            // The drop well has the top of the picture while files are dragged there; a notice waits.
            if let banner = session.banner, session.fileDrags.remoteDrag == nil {
                SessionBannerView(banner: banner) { session.dismissBanner() }
                    .padding(.horizontal)
                    // A window smaller than the screen has the system's window controls in its
                    // top corner; the notice sits below them.
                    .padding(.top, session.uiState.isWindowed ? 44 : 8)
                    // Like the bars, this floats over a picture whose surround is black.
                    .environment(\.colorScheme, .dark)
            }
        }
    }
}

/// The edge effect behind the bars where the remote display runs under them.
///
/// The remote display is not a scroll view, so the system's scroll edge effect is drawn here: a
/// material solid along the screen's edge, where the title and clock are, fading toward the picture.
/// Not a bar background (no line or fill of its own); takes no touches.
private struct BarEdgeEffect: View {
    let insets: EdgeInsets
    /// The side the bars stand along as a column (closed iPhone Duo), or nil where they run across the top.
    let verticalBarEdge: HorizontalEdge?

    var body: some View {
        ZStack {
            band(edge: .top, length: insets.top)
            if let verticalBarEdge {
                band(
                    edge: verticalBarEdge == .leading ? .leading : .trailing,
                    length: verticalBarEdge == .leading ? insets.leading : insets.trailing
                )
            }
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func band(edge: Edge, length: CGFloat) -> some View {
        if length > 0 {
            // A little past the bar, so the fade ends below the bar's own items rather than at them.
            let extent = length + 16
            let alignment: Alignment = switch edge {
            case .top: .top
            case .bottom: .bottom
            case .leading: .leading
            case .trailing: .trailing
            }
            let (start, end): (UnitPoint, UnitPoint) = switch edge {
            case .top: (.top, .bottom)
            case .bottom: (.bottom, .top)
            case .leading: (.leading, .trailing)
            case .trailing: (.trailing, .leading)
            }
            // The material blurs; the black over it keeps the band from showing as grey over the
            // black surround, where the bars would otherwise sit on a slab of their own.
            Rectangle()
                .fill(.regularMaterial)
                .overlay { Color.black.opacity(0.45) }
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.55),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: start,
                        endPoint: end
                    )
                }
                .frame(
                    width: edge == .top || edge == .bottom ? nil : extent,
                    height: edge == .top || edge == .bottom ? extent : nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }
}

/// The device's screen while the picture is on the monitor: a trackpad surface that says so.
private struct ExternalOnlyTrackpad: View {
    let session: SessionModel
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 44

    var body: some View {
        ZStack {
            // Black like the letterbox around a remote display, so the bars look the same over it.
            Color.black
            VStack(spacing: 10) {
                Image(systemName: "display")
                    .font(.system(size: symbolSize, weight: .light))
                    .accessibilityHidden(true)
                Text("Showing on External Display")
                    .font(.headline)
                Text("Use this screen as a trackpad.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding()
            .environment(\.colorScheme, .dark)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("external-only-trackpad")
    }
}

/// Reports the pane a remote display would get here, before there is one. A "fit to this device"
/// session asks for its display while it connects, and needs to know the shape to ask for.
struct StagePaneProbe: ViewModifier {
    let session: SessionModel
    @Environment(\.displayScale) private var displayScale
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                let insets = proxy.safeAreaInsets
                let size = CGSize(
                    width: proxy.size.width + insets.leading + insets.trailing,
                    height: proxy.size.height + insets.top + insets.bottom
                )
                Color.clear
                    .onChange(of: size, initial: true) { _, new in
                        session.stageLayoutChanged(size: new, safeArea: ViewInsets(insets, layoutDirection: layoutDirection), deviceScale: displayScale)
                    }
            }
            .ignoresSafeArea(.keyboard)
        }
    }
}

/// What is said over the remote display when it is not simply live.
private struct StageStatus: View {
    let session: SessionModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch session.phase {
        case .connected where !session.hasFirstFrame:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .accessibilityLabel("Waiting for the first picture")
        case .connected where session.isDisplayReconfiguring:
            // A resize is in flight. The last frame stays up, slightly dimmed, until the new size
            // arrives; blanking would make every rotation flash.
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
                    .padding(14)
                    .background(.black.opacity(0.5), in: .circle)
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Resizing the display")
        case .reconnecting:
            dimmed {
                ProgressView().controlSize(.large)
                Text("Reconnecting…").font(.headline).accessibilityAddTraits(.isHeader)
                Text("The connection to “\(session.title)” was interrupted.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Disconnect") { session.disconnect() }
                    .buttonStyle(.bordered)
            }
        case .ended(let reason):
            dimmed {
                Text(reason.title).font(.headline).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                if !reason.message.isEmpty {
                    Text(reason.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                ActionButtons {
                    Button("Reconnect") { session.reconnect() }
                        .buttonStyle(.borderedProminent).tint(.prominentFill)
                    Button("Close") { session.disconnect() }
                        .buttonStyle(.bordered)
                }
            }
        default:
            EmptyView()
        }
    }

    /// A card over the last frame, which stays visible but dimmed behind it. At the largest text
    /// sizes the card is wider, and scrolls if its buttons would not fit on the screen otherwise.
    private func dimmed(@ViewBuilder content: () -> some View) -> some View {
        let card = VStack(spacing: 12) {
            content()
        }
        .padding(24)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 520 : 340)
        return ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            ScrollIfNeeded { card }
                .background(.regularMaterial, in: .rect(cornerRadius: 24))
                .clipShape(.rect(cornerRadius: 24))
                .padding()
                .accessibilityElement(children: .contain)
        }
    }
}

/// A notice that floats over the session without stopping it.
struct SessionBannerView: View {
    let banner: SessionBanner
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: banner.kind == .fallback ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.kind == .fallback ? .yellow : .blue)
                .font(.title3)
                .accessibilityHidden(true)
            // Over glass and whatever picture is behind it, so nothing here is dimmed.
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.subheadline.weight(.semibold))
                if !banner.message.isEmpty {
                    Text(banner.message).font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .frame(minWidth: 28, minHeight: 28)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 520)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-banner")
        // A notice goes away by itself after a few seconds, so it is said aloud when it comes.
        .onChange(of: banner.id, initial: true) {
            var text = AttributedString([banner.title, banner.message].filter { !$0.isEmpty }.joined(separator: ". "))
            text.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(text).post()
        }
    }
}
