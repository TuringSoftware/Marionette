// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
import Observation

/// The sessions that are open, and which one is on screen.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var sessions: [SessionModel] = []
    /// The session shown full screen over the library.
    public var presented: SessionModel?
    /// A computer whose editor should open, set when a failed session asks to edit its connection.
    public var editRequest: UUID?

    @ObservationIgnored private let makeDependencies: () -> SessionModel.Dependencies
    /// Called when a session closes, so the library can refresh thumbnails and dates.
    @ObservationIgnored public var onSessionClosed: (() -> Void)?

    /// Told of every session that connects, and of its end.
    @ObservationIgnored private let support: SupportPrompts?

    public init(support: SupportPrompts? = nil, dependencies: @escaping () -> SessionModel.Dependencies) {
        self.support = support
        makeDependencies = dependencies
    }

    public var activeComputerIDs: Set<UUID> { Set(sessions.map(\.computer.id)) }

    public func session(id: UUID) -> SessionModel? {
        sessions.first { $0.id == id }
    }

    /// Opens a session with a computer and presents it; an already open one is brought back instead.
    @discardableResult
    public func open(_ computer: ComputerConfiguration) -> SessionModel {
        // The demo has no button of its own: a computer whose address is "demo" is the demo
        // (App Store review uses it).
        let computer = computer.isDemoAddress ? .demo : computer
        if let existing = sessions.first(where: { $0.computer.id == computer.id }) {
            presented = existing
            return existing
        }
        let session = SessionModel(computer: computer, dependencies: makeDependencies())
        session.onFirstConnection = { [weak self] in self?.support?.sessionConnected() }
        session.onClose = { [weak self] closed in self?.didClose(closed) }
        sessions.append(session)
        presented = session
        session.start()
        return session
    }

    // MARK: App life cycle, for every open session

    /// Call synchronously from the system's notification: drawing stops before anything is suspended.
    public func applicationWillResignActive() {
        for session in sessions { session.sceneDidResignActive() }
    }

    public func applicationDidEnterBackground() {
        for session in sessions { session.sceneDidEnterBackground() }
    }

    public func applicationWillEnterForeground() {
        for session in sessions { session.sceneWillEnterForeground() }
    }

    public func applicationDidBecomeActive() {
        for session in sessions { session.sceneDidBecomeActive() }
    }

    /// The background grace period is over: see ``SessionModel/backgroundTimeExpired()``. Returns
    /// once every session has ended cleanly.
    public func backgroundTimeExpired() async {
        for session in sessions { await session.backgroundTimeExpired() }
    }

    private func didClose(_ session: SessionModel) {
        sessions.removeAll { $0.id == session.id }
        if presented?.id == session.id { presented = nil }
        if session.wantsEditor, !session.computer.isDemo { editRequest = session.computer.id }
        if session.hasConnected { support?.sessionEnded() }
        onSessionClosed?()
    }
}
