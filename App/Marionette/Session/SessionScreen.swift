// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import RemoteDesktopInteraction
import SwiftUI
import UIKit
import MarionetteKit

/// A session, from "Connecting…" to the live remote display.
///
/// Two presentations: with system chrome (title bar, clock, home indicator), the default; and full
/// screen, where the remote display has the whole screen and system gestures must be made twice. In
/// both, the session's controls float in a strip at the bottom (``ControlStrip``).
struct SessionScreen: View {
    let session: SessionModel
    @Environment(\.launchOptions) private var launchOptions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var haptics = GestureHaptics()

    private var showsRemoteDisplay: Bool { session.phase.showsRemoteDisplay }

    /// The appearance the person chose, which this presentation's own dark override hides from its
    /// environment: a screen's traits are the system's.
    private var userColorScheme: ColorScheme {
        if let forced = launchOptions.appearance { return forced == .dark ? .dark : .light }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.screen.traitCollection.userInterfaceStyle == .dark ? .dark : .light
    }
    /// No title bar: the user's full screen, or a window smaller than the screen (iPad), where a
    /// session is always shown this way.
    private var hidesTitleBar: Bool { showsRemoteDisplay && session.uiState.showsFullScreen }
    /// The user's full screen with the whole screen to itself: only then are the system's own
    /// overlays and gestures held back. A window has no clock or home indicator to hide, and its
    /// edges are not the screen's.
    private var ownsTheScreen: Bool { showsRemoteDisplay && session.uiState.isFullScreen && !session.uiState.isWindowed }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(session.title)
                .navigationSubtitle(session.statusLine)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .toolbarTitleMenu { titleMenu }
                .toolbarVisibility(hidesTitleBar ? .hidden : .automatic, for: .navigationBar)
                // The remote display's letterbox is black in either appearance; bars must read on it.
                .toolbarColorScheme(showsRemoteDisplay ? .dark : nil, for: .navigationBar)
        }
        // The surround is black in either appearance, so the presentation is dark while the remote
        // display shows: the status bar takes its style from the presentation, not from the bars.
        // Sheets restore the person's own appearance.
        .preferredColorScheme(showsRemoteDisplay ? .dark : nil)
        // Full screen only: no clock or home indicator, and edge swipes go to the remote desktop
        // first (its Dock, menu bar, hot corners), so system gestures need a second swipe.
        .statusBarHidden(ownsTheScreen)
        .persistentSystemOverlays(ownsTheScreen ? .hidden : .automatic)
        .defersSystemGestures(on: ownsTheScreen ? .all : [])
        .background {
            WindowModeProbe(override: launchOptions.isWindowedOverride) { session.setWindowed($0) }
        }

        .sheet(item: pendingPrompt) { pending in
            PromptSheet(pending: pending, broker: session.prompts, computerName: session.title)
                .preferredColorScheme(userColorScheme)
        }
        .sheet(isPresented: Binding(get: { session.uiState.isFilesPresented }, set: { session.setFilesPresented($0) })) {
            FilesSheet(session: session)
                .preferredColorScheme(userColorScheme)
        }
        // Connection status changes on its own, so it is announced.
        .onChange(of: spokenStatus) { _, status in
            AccessibilityNotification.Announcement(status).post()
        }
        .onChange(of: session.phase == .connected, initial: true) { _, connected in
            // Watching a remote screen is not "idle", even with no touches.
            UIApplication.shared.isIdleTimerDisabled = connected
        }
        .onAppear {
            session.onFeedback = { [haptics] in haptics.play($0) }
            ExternalDisplayController.shared.sessionAppeared(session)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // The session stays open behind the library: nothing may stay pressed meanwhile. (App
            // lifecycle events reach every session from `SessionLifecycle`.)
            session.releaseAllInput()
            session.captureThumbnail()
            ExternalDisplayController.shared.sessionDisappeared(session)
        }
    }

    private var spokenStatus: String {
        switch session.phase {
        case .connected: String(localized: "Connected")
        case .ended(let reason): reason.title
        case .failed(let failure): failure.title
        default: session.statusLine
        }
    }

    private var pendingPrompt: Binding<PromptBroker.Pending?> {
        // While the Files sheet is up it shows the questions itself; two sheets cannot share them.
        Binding(
            get: { session.uiState.isFilesPresented ? nil : session.prompts.pending },
            set: { if $0 == nil, !session.uiState.isFilesPresented { session.prompts.cancelPending() } }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .connecting(let step):
            ConnectingView(session: session, step: step)
                .modifier(StagePaneProbe(session: session))
        case .failed(let failure):
            FailureView(session: session, failure: failure)
        case .connected, .reconnecting, .ended:
            SessionArrangement(foldOverride: launchOptions.foldOverride, onPoseChange: { session.setDeckDocked($0 == .docked) }) {
                RemoteDisplayStage(session: session)
            } deck: {
                InputDeck(session: session)
            }
        case .closed:
            Color.black.ignoresSafeArea()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if session.phase.isConnecting {
                Button("Cancel", role: .cancel) { session.disconnect() }
            } else {
                Button("Disconnect", systemImage: "xmark", role: .close) { session.disconnect() }
                    .accessibilityIdentifier("close-session")
            }
        }
        if showsRemoteDisplay {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    if reduceMotion {
                        session.setFullScreen(true)
                    } else {
                        withAnimation(.smooth) { session.setFullScreen(true) }
                    }
                }
                .accessibilityIdentifier("enter-full-screen")
            }
        }
    }

    /// What the title's menu says about the connection.
    @ViewBuilder
    private var titleMenu: some View {
        if let info = session.info {
            Section(info.remoteName) {
                Label(info.mode.title, systemImage: info.mode == .highPerformance ? "bolt.fill" : "display")
                if info.isTunnelled {
                    Label("Through an SSH Tunnel", systemImage: "lock.fill")
                } else if info.isEncrypted {
                    Label("Direct Connection, Encrypted", systemImage: "lock.fill")
                } else {
                    // A menu shows the second text as a subtitle, which wraps; one long label is cut off.
                    Label {
                        Text("Not Secure")
                        Text(SessionBanner.notEncryptedMessage)
                    } icon: {
                        Image(systemName: "lock.open")
                    }
                }
                if case .unavailable(let reason) = session.features.audio {
                    Label {
                        Text("No Sound")
                        Text(reason.explanation)
                    } icon: {
                        Image(systemName: "speaker.slash")
                    }
                }
            }
        }
        Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { session.disconnect() }
    }
}
