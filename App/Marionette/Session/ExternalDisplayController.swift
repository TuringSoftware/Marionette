// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopInteraction
import SwiftUI
import UIKit
import MarionetteKit

/// Connects an attached monitor to the session on screen.
///
/// The monitor gets a scene of its own, which only shows a renderer's layer; the session model owns
/// that renderer and decides what it draws (``SessionModel/externalDisplayMode``):
/// - iOS 27: `.sceneAccessory { ExternalNonInteractiveAccessory(isEnabled:) }` on the library's root
///   view. While no session draws on the monitor the accessory is disabled and the system mirrors.
/// - iOS 26: ``LegacyExternalDisplayHost`` adds a window to the scene SwiftUI connects for the
///   external non-interactive role. Once the app has that scene the system no longer mirrors, so
///   in `.mirror` the session draws its own picture there.
@MainActor
@Observable
final class ExternalDisplayController {
    static let shared = ExternalDisplayController()

    /// A monitor is attached and the app may draw on it.
    private(set) var isAvailable = false
    /// The session shown on this device, which the monitor belongs to.
    private(set) var session: SessionModel?
    /// The size of the monitor's scene, once it has been laid out.
    @ObservationIgnored private var screen: ExternalScreen?
    /// The monitor can show HDR, and the screen the display window is on can: each source keeps its
    /// own, since a monitor can take over from a window that is still open.
    @ObservationIgnored private var monitorShowsHDR = false
    @ObservationIgnored private var windowShowsHDR = false
    private var showsHDR: Bool { isWindow ? windowShowsHDR : monitorShowsHDR }

    /// Whether the system mirrors the device when the app draws nothing (the iOS 27 accessory).
    var systemMirrors: Bool {
        if #available(iOS 27.0, *) { true } else { false }
    }

    /// Whether the accessory should take the monitor over from system mirroring.
    var drawsOnMonitor: Bool { session?.externalDisplay != nil }

    /// Stands in until the accessory's content is first laid out, which happens only once enabled.
    private static let assumedScreen = ExternalScreen(size: ViewSize(width: 1920, height: 1080), scale: 1)

    /// Set from `-MarionetteExternalMode`.
    @ObservationIgnored var preferredModeOverride: ExternalDisplayMode?

    /// A second window of this app stands in for the monitor (iPad). With Stage Manager on an
    /// extended display that is the only way onto it: the monitor hosts windows, not an accessory.
    private(set) var isWindow = false

    /// Whether a display window may be offered: windows are possible and no monitor is in use.
    var offersDisplayWindow: Bool {
        UIApplication.shared.supportsMultipleScenes && UIDevice.current.userInterfaceIdiom == .pad && !isAvailable
    }

    /// External Only suits a phone (the monitor is the bigger screen by far); an iPad mirrors. A
    /// window was opened to show another display, so it shows one.
    private var preferredMode: ExternalDisplayMode {
        if isWindow { return (session?.layout.displays.count ?? 0) > 1 ? .dual : .externalOnly }
        return preferredModeOverride ?? (UIDevice.current.userInterfaceIdiom == .phone ? .externalOnly : .mirror)
    }

    func windowChanged(size: CGSize, scale: CGFloat) {
        guard !isAvailable || isWindow else { return }
        if !isWindow {
            isWindow = true
            isAvailable = true
        }
        screenChanged(size: size, scale: scale)
    }

    func windowClosed() {
        guard isWindow else { return }
        isWindow = false
        availabilityChanged(false)
    }

    func availabilityChanged(_ available: Bool) {
        // A real monitor takes over from a display window.
        if available, isWindow { isWindow = false }
        guard available != isAvailable else { return }
        isAvailable = available
        if !available { screen = nil }
        forward()
    }

    /// The monitor's scene was laid out.
    func screenChanged(size: CGSize, scale: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        let new = ExternalScreen(size: ViewSize(width: size.width, height: size.height), scale: scale, showsHDR: showsHDR)
        guard new != screen else { return }
        screen = new
        forward()
    }

    /// The monitor's scene, or the display window, is on a screen that can show HDR, or not.
    func screenHDRChanged(_ showsHDR: Bool, inWindow: Bool) {
        if inWindow { windowShowsHDR = showsHDR } else { monitorShowsHDR = showsHDR }
        guard var screen, screen.showsHDR != self.showsHDR else { return }
        screen.showsHDR = self.showsHDR
        self.screen = screen
        forward()
    }

    func sessionAppeared(_ session: SessionModel) {
        guard session !== self.session else { return }
        self.session?.externalScreenDisconnected()
        self.session = session
        forward()
    }

    func sessionDisappeared(_ session: SessionModel) {
        guard session === self.session else { return }
        session.externalScreenDisconnected()
        self.session = nil
    }

    private func forward() {
        guard let session else { return }
        if isAvailable {
            // Nothing mirrors into a window: its "mirror" is the same picture, drawn by the app.
            session.externalScreenChanged(screen ?? Self.assumedScreen, preferredMode: preferredMode, mirrorsPicture: isWindow || !systemMirrors)
        } else {
            session.externalScreenDisconnected()
        }
    }
}

/// What the monitor shows: a session's second renderer, letterboxed in black, or black.
struct ExternalDisplayContent: View {
    let controller: ExternalDisplayController
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                ScreenHDRReader { controller.screenHDRChanged($0, inWindow: false) }
                if let session = controller.session, session.externalDisplay != nil {
                    DisplaySurface(renderer: session.externalRenderer)
                    // A monitor is looked at from across a desk or a room.
                    RemoteDragWell(session: session, surface: .externalDisplay, magnification: max(1, proxy.size.height / 540))
                }
            }
            .onChange(of: proxy.size, initial: true) { _, size in
                controller.screenChanged(size: size, scale: displayScale)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A window that shows a session's second display, the way an attached monitor would (iPad).
struct DisplayWindowContent: View {
    let controller: ExternalDisplayController
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                ScreenHDRReader { controller.screenHDRChanged($0, inWindow: true) }
                if let session = controller.session, controller.isWindow, session.externalDisplay != nil {
                    DisplaySurface(renderer: session.externalRenderer)
                        .accessibilityElement()
                        .accessibilityLabel("Remote Display")
                        .accessibilityIdentifier("display-window")
                    RemoteDragWell(session: session, surface: .externalDisplay)
                } else {
                    ContentUnavailableView(
                        "No Display to Show",
                        systemImage: "display.2",
                        description: Text("Choose a display under View in the session.")
                    )
                    .environment(\.colorScheme, .dark)
                }
            }
            .onChange(of: proxy.size, initial: true) { _, size in
                controller.windowChanged(size: size, scale: displayScale)
            }
        }
        .ignoresSafeArea()
        .onDisappear { controller.windowClosed() }
    }
}

/// Puts ``ExternalDisplayContent`` on an attached monitor through the scene accessory (iOS 27).
struct ExternalDisplayAccessory: ViewModifier {
    let controller: ExternalDisplayController

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            // Read here, not only inside the binding, so that SwiftUI re-evaluates it when it changes.
            let enabled = controller.drawsOnMonitor
            content.sceneAccessory {
                ExternalNonInteractiveAccessory(isEnabled: Binding(get: { enabled }, set: { _ in })) {
                    ExternalDisplayContent(controller: controller)
                }
                .onAvailabilityChange { controller.availabilityChanged($0) }
            }
        } else {
            content
        }
    }
}

/// Puts a window on the monitor's scene on iOS 26, where there is no scene accessory. SwiftUI
/// connects a scene for the external non-interactive role by itself (and does not ask the app
/// delegate for its configuration), but leaves it empty; Marionette adds its own window to it.
@MainActor
final class LegacyExternalDisplayHost {
    static let shared = LegacyExternalDisplayHost()
    private var window: UIWindow?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        if #available(iOS 27.0, *) { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated { LegacyExternalDisplayHost.shared.connect(scene) }
        })
        observers.append(center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated { LegacyExternalDisplayHost.shared.disconnect(scene) }
        })
        // A monitor attached before launch has its scene already.
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            connect(scene)
        }
    }

    private func connect(_ scene: UIWindowScene?) {
        guard let scene, scene.session.role == .windowExternalDisplayNonInteractive, window?.windowScene !== scene else { return }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ExternalDisplayContent(controller: .shared))
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        ExternalDisplayController.shared.availabilityChanged(true)
    }

    private func disconnect(_ scene: UIWindowScene?) {
        guard let scene, scene === window?.windowScene else { return }
        window = nil
        ExternalDisplayController.shared.availabilityChanged(false)
    }
}
