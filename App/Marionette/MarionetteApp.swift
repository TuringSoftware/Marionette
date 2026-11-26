// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import TipKit
import UIKit
import MarionetteKit

@main
struct MarionetteApp: App {
    @State private var bootstrap = Bootstrap()

    var body: some Scene {
        WindowGroup(id: "library") {
            RootView(bootstrap: bootstrap) { environment in
                LibraryView(environment: environment)
            }
            // Main window only: an attached monitor belongs to the app, not to a window.
            .modifier(ExternalDisplayAccessory(controller: .shared))
        }
        .commands { MarionetteCommands() }

        WindowGroup(id: "session", for: SessionWindowID.self) { $window in
            RootView(bootstrap: bootstrap) { environment in
                SessionWindow(environment: environment, window: window)
            }
        }
    }
}

@MainActor
@Observable
final class Bootstrap {
    private(set) var environment: AppEnvironment?
    private var isStarted = false
    private var lifecycle: SessionLifecycle?

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        LegacyExternalDisplayHost.shared.start()
        let environment = await AppEnvironment.make(arguments: ProcessInfo.processInfo.arguments, pasteboard: SystemPasteboard())
        if environment.options.isUITestMode {
            UIView.setAnimationsEnabled(false)
            // Each UI test starts from a first launch, tips included.
            try? Tips.resetDatastore()
        }
        try? Tips.configure([.displayFrequency(.immediate)])
        ExternalDisplayController.shared.preferredModeOverride = environment.options.externalDisplayMode
        lifecycle = SessionLifecycle(sessions: environment.sessions)
        self.environment = environment
        if environment.options.autoConnect {
            environment.sessions.open(environment.autoConnectComputer)
        }
    }
}

/// Forwards app lifecycle notifications to the open sessions and holds a background grace period
/// for them.
///
/// Handled synchronously on the posting thread: drawing has to stop before the system suspends
/// anything (see ``SessionModel/sceneDidResignActive()``), which SwiftUI's scene phase, delivered
/// on a later update, cannot promise.
@MainActor
private final class SessionLifecycle {
    private let sessions: SessionStore
    private var observers: [any NSObjectProtocol] = []
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var graceTimer: Task<Void, Never>?
    /// iOS allows about 30 s of background work; sessions end earlier so their goodbyes reach the Mac.
    private static let gracePeriod = 25.0
    private static let goodbyeTime = 5.0

    init(sessions: SessionStore) {
        self.sessions = sessions
        let center = NotificationCenter.default
        let handlers: [(Notification.Name, @MainActor (SessionLifecycle) -> Void)] = [
            (UIApplication.willResignActiveNotification, { $0.sessions.applicationWillResignActive() }),
            (UIApplication.didEnterBackgroundNotification, { $0.didEnterBackground() }),
            (UIApplication.willEnterForegroundNotification, { $0.willEnterForeground() }),
            (UIApplication.didBecomeActiveNotification, { $0.sessions.applicationDidBecomeActive() }),
        ]
        for (name, handler) in handlers {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                // UIApplication posts these on the main thread.
                MainActor.assumeIsolated {
                    if let self { handler(self) }
                }
            })
        }
    }

    /// Keeps the sessions connected (suspended) for a grace period, then ends them cleanly; they
    /// reconnect when the app returns.
    private func didEnterBackground() {
        sessions.applicationDidEnterBackground()
        guard !sessions.sessions.isEmpty, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Screen sharing session") { [weak self] in
            MainActor.assumeIsolated { self?.graceEnded(waitingForGoodbyes: false) }
        }
        let remaining = UIApplication.shared.backgroundTimeRemaining - Self.goodbyeTime
        graceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, min(Self.gracePeriod, remaining))))
            guard !Task.isCancelled else { return }
            self?.graceEnded(waitingForGoodbyes: true)
        }
    }

    private func willEnterForeground() {
        graceTimer?.cancel()
        graceTimer = nil
        endBackgroundTask()
        sessions.applicationWillEnterForeground()
    }

    /// Ends the sessions. From the system's expiration handler there is no time left to wait for
    /// them: the background task ends at once.
    private func graceEnded(waitingForGoodbyes: Bool) {
        graceTimer?.cancel()
        graceTimer = nil
        guard backgroundTask != .invalid else { return }
        let ending = Task { await sessions.backgroundTimeExpired() }
        guard waitingForGoodbyes else {
            endBackgroundTask()
            return
        }
        let task = backgroundTask
        Task { [weak self] in
            await ending.value
            guard let self, self.backgroundTask == task else { return }
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

private struct RootView<Content: View>: View {
    let bootstrap: Bootstrap
    @ViewBuilder var content: (AppEnvironment) -> Content

    var body: some View {
        Group {
            if let environment = bootstrap.environment {
                content(environment)
                    .environment(\.launchOptions, environment.options)
                    .preferredColorScheme(environment.options.appearance.map { $0 == .dark ? .dark : .light })
                    .transaction { transaction in
                        if environment.options.isUITestMode { transaction.disablesAnimations = true }
                    }
            } else {
                Color(uiColor: .systemBackground).ignoresSafeArea()
            }
        }
        .task { await bootstrap.start() }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-MarionetteMeasurePasteboard") { await PasteboardMeasurement.run() }
        }
        #endif
    }
}

/// The content of a session window: the session it names, or a note that it is gone.
private struct SessionWindow: View {
    let environment: AppEnvironment
    let window: SessionWindowID?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let window, environment.sessions.session(id: window.sessionID) != nil {
            // The session itself stays in the main window; this one shows another of its displays.
            DisplayWindowContent(controller: .shared)
        } else {
            ContentUnavailableView("Session Ended", systemImage: "display", description: Text("This session is no longer open."))
                .task { if environment.options.isUITestMode { giveWayToTheLibrary() } }
        }
    }

    /// Each UI test starts from a first launch, but the system restores a display window an earlier
    /// test opened, in front, with the library's window hidden behind it.
    private func giveWayToTheLibrary() {
        let application = UIApplication.shared
        // Not one on screen: this window's own scene may still be on its way to active.
        let behind = application.openSessions.first { session in
            guard let state = session.scene?.activationState else { return true }
            return state == .background || state == .unattached
        }
        if let library = behind {
            application.activateSceneSession(for: UISceneSessionActivationRequest(session: library))
        } else {
            openWindow(id: "library")
        }
        dismissWindow()
    }
}

extension EnvironmentValues {
    /// What the launch arguments asked for (UI-test mode, fold override).
    @Entry var launchOptions = LaunchOptions()
}
