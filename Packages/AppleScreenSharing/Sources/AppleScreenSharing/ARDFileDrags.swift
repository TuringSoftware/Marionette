// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
import Foundation
import RemoteDesktopCore
import Synchronization

/// Drags of files across the edge of the Mac's picture, as Screen Sharing.app does them
/// (Docs/protocol/apple-screen-sharing.md, "Dragging files").
///
/// A drag from this device: the pointer goes to where the drag enters with no button down, the
/// drag is announced by the names it carries, and the button goes down. The Mac starts a drag of
/// its own under the pointer, which follows the pointer events that come next and is dropped by
/// the release. If a folder, a Finder window or the desktop was under it, the Mac names that
/// folder; anything else takes nothing and the Mac says nothing. A Mac only goes along with this
/// for a viewer whose pointer events are encrypted.
///
/// A drag on the Mac: the Mac announces the files as soon as one starts under this viewer's
/// pointer, and says so again, empty, when its button comes up.
final class ARDFileDrags: FileDragAndDrop {
    private struct Outgoing {
        var token: UInt32
        var display: DisplayID
        var position: PixelPoint
        var waiter: CheckedContinuation<Result<String, FileDragError>, Never>?
        var timeout: Task<Void, Never>?
    }

    private struct State {
        weak var core: ARDSessionCore?
        var outgoing: Outgoing?
        var isClosed = false
    }

    private let state = Mutex(State())
    private let remote = Broadcaster<RemoteFileDrag?>(replaysLatest: true, bufferingPolicy: .bufferingNewest(1))

    /// The session these drags belong to; set once, when the session is built.
    func attach(to core: ARDSessionCore) {
        state.withLock { $0.core = core }
    }

    // MARK: Drags on the Mac

    func remoteDrags() -> AsyncStream<RemoteFileDrag?> {
        remote.subscribe()
    }

    func takeRemoteDrag() {
        guard let core = state.withLock({ $0.core }) else { return }
        // An empty drag from a viewer cancels the Mac's own: the release then drops nothing there.
        core.deliverRawInput([DragPasteboard.end.encoded()])
        remote.send(nil)
    }

    /// The Mac announced a drag of its own, or the end of one.
    func receive(_ drag: DragPasteboard) {
        guard drag.uncompressedLength > 0, let contents = try? drag.contents(), !contents.paths.isEmpty else {
            remote.send(nil)
            return
        }
        remote.send(RemoteFileDrag(paths: contents.paths, previewPNG: contents.imagePNG))
    }

    // MARK: Drags from this device

    func beginDrag(names: [String], at position: PixelPoint, on display: DisplayID) throws(FileDragError) -> any OutgoingFileDrag {
        let token = UInt32.random(in: 2...UInt32.max)
        let core: ARDSessionCore = try state.withLock { state throws(FileDragError) in
            guard !state.isClosed, let core = state.core else { throw .sessionEnded }
            guard state.outgoing == nil else { throw .busy }
            // A viewer that only watches sends no pointer events, so its drag could not move.
            guard core.shared.withLock({ $0.controlMode != .observe }) else { throw .notAccepted }
            state.outgoing = Outgoing(token: token, display: display, position: position)
            return core
        }
        // Only the names matter to the Mac; the files follow once it has said where they go.
        let urls = names.map { URL(fileURLWithPath: "/private/tmp").appendingPathComponent($0.replacingOccurrences(of: "/", with: ":")) }
        point(core, at: position, on: display, pressed: false)
        core.deliverRawInput([DragPasteboard.files(urls, token: token).encoded()])
        // The Mac's drag starts at the pointer and is dropped by the next release, so the button
        // stays down until the drop.
        point(core, at: position, on: display, pressed: true)
        return Drag(owner: self, token: token)
    }

    private func point(_ core: ARDSessionCore, at position: PixelPoint, on display: DisplayID, pressed: Bool) {
        let generation = core.shared.withLock { $0.layout.generation }
        core.send(.pointer(PointerEvent(display: display, position: position, buttons: pressed ? .primary : [], layoutGeneration: generation)))
    }

    fileprivate func move(_ token: UInt32, to position: PixelPoint, on display: DisplayID) {
        let core: ARDSessionCore? = state.withLock { state in
            guard state.outgoing?.token == token, state.outgoing?.waiter == nil else { return nil }
            state.outgoing?.position = position
            state.outgoing?.display = display
            return state.core
        }
        if let core { point(core, at: position, on: display, pressed: true) }
    }

    fileprivate func drop(_ token: UInt32) async throws -> String {
        let outcome: Result<String, FileDragError> = await withCheckedContinuation { continuation in
            let release: (core: ARDSessionCore, display: DisplayID, position: PixelPoint)? = state.withLock { state in
                guard let outgoing = state.outgoing, outgoing.token == token, outgoing.waiter == nil, let core = state.core else { return nil }
                state.outgoing?.waiter = continuation
                // The Mac's time starts when the release reaches it, which is later while input
                // is being held back (just after the login, or around a display change).
                let limit = core.timing.dropAnswerLimit + max(.zero, core.shared.withLock { $0.inputOpensAt } - .now)
                state.outgoing?.timeout = Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled else { return }
                    self?.settle(token, .failure(.notAccepted))
                }
                return (core, outgoing.display, outgoing.position)
            }
            guard let release else {
                continuation.resume(returning: .failure(state.withLock { $0.isClosed } ? .sessionEnded : .notAccepted))
                return
            }
            point(release.core, at: release.position, on: release.display, pressed: false)
        }
        return try outcome.get()
    }

    fileprivate func cancel(_ token: UInt32) {
        let pending: (core: ARDSessionCore?, outgoing: Outgoing)? = state.withLock { state in
            guard let outgoing = state.outgoing, outgoing.token == token else { return nil }
            // Once let go, the drop is the Mac's to answer: cancelling only stops the wait.
            guard outgoing.waiter == nil else { return (nil, outgoing) }
            state.outgoing = nil
            return (state.core, outgoing)
        }
        guard let pending else { return }
        guard let core = pending.core else {
            settle(token, .failure(.notAccepted))
            return
        }
        // Told that the drag is over, the Mac drops nothing when the button comes up.
        core.deliverRawInput([DragPasteboard.end.encoded()])
        point(core, at: pending.outgoing.position, on: pending.outgoing.display, pressed: false)
    }

    /// The Mac named the folder under a drop.
    func receive(_ destination: DropDestination) {
        settle(destination.token, .success(destination.path))
    }

    private func settle(_ token: UInt32, _ outcome: Result<String, FileDragError>) {
        let outgoing: Outgoing? = state.withLock { state in
            guard let outgoing = state.outgoing, outgoing.token == token, outgoing.waiter != nil else { return nil }
            state.outgoing = nil
            return outgoing
        }
        outgoing?.timeout?.cancel()
        outgoing?.waiter?.resume(returning: outcome)
    }

    /// The session has ended.
    func close() {
        let outgoing: Outgoing? = state.withLock { state in
            state.isClosed = true
            defer { state.outgoing = nil }
            return state.outgoing
        }
        outgoing?.timeout?.cancel()
        outgoing?.waiter?.resume(returning: .failure(.sessionEnded))
        remote.send(nil)
        remote.finish()
    }

    private final class Drag: OutgoingFileDrag {
        private let owner: ARDFileDrags
        private let token: UInt32

        init(owner: ARDFileDrags, token: UInt32) {
            self.owner = owner
            self.token = token
        }

        func move(to position: PixelPoint, on display: DisplayID) { owner.move(token, to: position, on: display) }
        func drop() async throws -> String { try await owner.drop(token) }
        func cancel() { owner.cancel(token) }
    }
}
