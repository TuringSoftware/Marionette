// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
public import RemoteDesktopCore
public import RemoteDesktopInteraction
import UniformTypeIdentifiers

/// What drags of files need from the session they belong to.
@MainActor
protocol FileDragHost: AnyObject {
    /// Whether a finger over the remote picture steers the remote pointer: the picture is on this
    /// device and the session sends input. Without that, a drag of this device's files has no
    /// place on the remote machine to be let go at.
    var pictureTakesFileDrags: Bool { get }
    /// The place on the remote display under a point of the stage; `nil` beside the picture.
    func remotePlace(under point: ViewPoint) -> (display: DisplayID, position: PixelPoint)?
    /// A drag from this device carried the remote pointer to a place on the shown display.
    func fileDragMovedPointer(to position: PixelPoint)
    /// Whether this session can let go of the remote machine's button, which is how a drag there
    /// is taken.
    var canTakeRemoteDrags: Bool { get }
    /// Where a place on a remote display is on the surface that shows the drop well, in that
    /// surface's points; `nil` when the display is not shown there.
    func dropWellSurfacePoint(for position: PixelPoint, on display: DisplayID) -> ViewPoint?
    /// Where the remote pointer is on that surface.
    var pointerOnDropWellSurface: ViewPoint? { get }
    func showFileDragNotice(_ banner: SessionBanner)
}

/// Drags of files between this device and the remote machine, for one session.
///
/// *From here.* While a drag of files is over the remote picture, the remote machine shows a drag
/// of its own under the finger, and its folders light up. Let go, the machine names the folder the
/// drag landed in and the files are queued for upload there; over something that takes no files,
/// nothing is sent and a banner says why. A session that can move files but knows no drags (plain
/// VNC with SFTP), or whose picture is not under the finger, sends them to its default folder.
///
/// *From there.* While files are dragged on the remote machine, ``remoteDrag`` describes them and
/// the interface shows a drop well. Letting go of the remote pointer over the well takes the drag
/// over and queues the files for download.
@MainActor
@Observable
public final class FileDragModel {
    /// What letting go of a drag of this device's files would do.
    public enum Proposal: Sendable, Hashable {
        case copy
        case forbidden
    }

    /// The drag the remote machine last announced.
    private var announced: RemoteFileDrag?
    /// Where the drop well is, on the surface that shows it.
    private var dropWellFrame: ViewRect?

    @ObservationIgnored weak var host: (any FileDragHost)?
    @ObservationIgnored private let transfers: TransferQueue
    @ObservationIgnored private var drags: (any FileDragAndDrop)?
    /// The remote machine's drag for a drag from this device that is over the picture now.
    @ObservationIgnored private var outgoing: (any OutgoingFileDrag)?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// The buttons the session was last told are down.
    @ObservationIgnored private var sentButtons: PointerButtons = []

    init(transfers: TransferQueue) {
        self.transfers = transfers
    }

    // MARK: Session life cycle

    /// Whether the session has drags of files.
    var isAvailable: Bool { drags != nil }

    /// A session connected, with drags of files or without.
    func connected(_ drags: (any FileDragAndDrop)?) {
        disconnected()
        guard let drags else { return }
        self.drags = drags
        watcher = Task { [weak self] in
            for await drag in drags.remoteDrags() {
                guard let self, !Task.isCancelled else { return }
                self.announced = drag
            }
        }
    }

    func disconnected() {
        watcher?.cancel()
        watcher = nil
        dragExited()
        drags = nil
        announced = nil
        sentButtons = []
    }

    // MARK: From this device

    /// A drag from this device is over the remote picture: the back end steers the remote pointer
    /// and holds its button down for it, so the session's own pointer input has to wait.
    var holdsRemotePointer: Bool { outgoing != nil }

    /// A drag of files called `names` came over the stage, or moved there. Says what letting go
    /// at `point` would do.
    @discardableResult
    public func dragMoved(names: [String], to point: ViewPoint) -> Proposal {
        guard transfers.isAvailable, let host else {
            dragExited()
            return .forbidden
        }
        guard let drags, host.pictureTakesFileDrags else {
            // No place on the remote machine to aim at: the files go to its default folder.
            dragExited()
            return .copy
        }
        guard let place = host.remotePlace(under: point) else {
            // Beside the picture is outside the remote machine: its drag ends, as when a drag
            // leaves a window, and starts again when this one comes back.
            dragExited()
            return .forbidden
        }
        if let outgoing {
            outgoing.move(to: place.position, on: place.display)
        } else {
            do {
                outgoing = try drags.beginDrag(names: names, at: place.position, on: place.display)
            } catch {
                // The drop before this one is still being answered. Tried again as the drag moves.
                return .forbidden
            }
        }
        host.fileDragMovedPointer(to: place.position)
        return .copy
    }

    /// The drag left the stage, or was called off: the remote machine's drag ends without a drop.
    public func dragExited() {
        outgoing?.cancel()
        outgoing = nil
    }

    /// The drag was let go at `point`. Returns whether the files are wanted. If they are, the
    /// remote machine's button is let go at once, and `files` is asked for copies of what was
    /// dropped while the machine says where they belong.
    @discardableResult
    public func drop(names: [String], at point: ViewPoint, files: @escaping @Sendable () async -> [StagedUpload]) -> Bool {
        guard dragMoved(names: names, to: point) == .copy else { return false }
        let outgoing = outgoing
        self.outgoing = nil
        Task { [weak self] in
            async let copies = files()
            var directory: String?
            if let outgoing {
                do {
                    directory = try await outgoing.drop()
                } catch {
                    // Only a drop the machine turned down is news; a session that ended says so itself.
                    if error as? FileDragError == .notAccepted { self?.noteRefusal() }
                    for copy in await copies { copy.discard() }
                    return
                }
            }
            let staged = await copies
            guard let self else {
                for copy in staged { copy.discard() }
                return
            }
            for copy in staged { self.transfers.upload(copy, toDirectory: directory) }
            if staged.count < names.count { self.noteUnreadable(names.count - staged.count) }
        }
        return true
    }

    private func noteRefusal() {
        guard let host else { return }
        host.showFileDragNotice(SessionBanner(
            kind: .information,
            title: String(localized: "Not Copied", bundle: #bundle),
            message: String(localized: "Drop files on a folder or the desktop.", bundle: #bundle)
        ))
    }

    private func noteUnreadable(_ count: Int) {
        host?.showFileDragNotice(SessionBanner(
            kind: .information,
            title: count == 1 ? String(localized: "1 Item Couldn’t Be Read", bundle: #bundle) : String(localized: "\(count) Items Couldn’t Be Read", bundle: #bundle),
            message: ""
        ))
    }

    // MARK: From the remote machine

    /// The files being dragged on the remote machine, while this session could take them: it has
    /// a way to fetch them and a button to let go of.
    public var remoteDrag: RemoteFileDrag? {
        guard transfers.isAvailable, host?.canTakeRemoteDrags == true else { return nil }
        return announced
    }

    /// Where the interface put the drop well, in the points of the surface that shows it; `nil`
    /// when it is not showing.
    public func setDropWellFrame(_ frame: ViewRect?) {
        if frame != dropWellFrame { dropWellFrame = frame }
    }

    /// Whether letting go of the remote pointer now would take the remote drag.
    public var isPointerOverDropWell: Bool {
        guard remoteDrag != nil, let dropWellFrame, let pointer = host?.pointerOnDropWellSurface else { return false }
        return dropWellFrame.contains(pointer)
    }

    /// A pointer event is about to go to the session. One that lets go of the primary button over
    /// the drop well takes the remote drag over first: the remote machine has to hear that before
    /// its button comes up, or it drops the files where its pointer is.
    func pointerEventWillBeSent(_ event: PointerEvent) {
        let wasDown = sentButtons.contains(.primary)
        sentButtons = event.buttons
        guard wasDown, !event.buttons.contains(.primary), let drag = remoteDrag, let drags, let dropWellFrame,
              let point = host?.dropWellSurfacePoint(for: event.position, on: event.display), dropWellFrame.contains(point)
        else { return }
        drags.takeRemoteDrag()
        announced = nil
        for path in drag.paths { transfers.download(Self.entry(forDraggedPath: path)) }
    }

    /// The app, not the person, is about to let go of input: it left the foreground, the shown
    /// display changed, the system took the touches away. Nobody chose that moment, so a drag on
    /// the remote machine must neither be fetched nor be dropped wherever the remote pointer
    /// happens to be. It is called off: taken over, and nothing is fetched.
    ///
    /// `everything` says that the remote machine will be told to let go of everything, whatever
    /// this session holds; otherwise only a button of this session's own is about to come up.
    func inputWillBeReleased(everything: Bool) {
        guard everything || sentButtons.contains(.primary), announced != nil, let drags else { return }
        drags.takeRemoteDrag()
        announced = nil
    }

    /// The remote machine was told to let go of everything.
    func allInputReleased() {
        sentButtons = []
    }

    /// What ``TransferQueue/download(_:)`` needs to fetch something a remote drag named.
    nonisolated static func entry(forDraggedPath path: String) -> RemoteFileEntry {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return RemoteFileEntry(path: path, name: name, isDirectory: path.count > 1 && path.hasSuffix("/"))
    }
}

/// Tells the files in a drag from another app from everything else that can be dragged.
public enum DroppedFile {
    /// The type to load a dragged item as, if the item is a file or a folder; `nil` for a
    /// selection of text, a link and the like, which are not files to send.
    ///
    /// - Parameters:
    ///   - registered: The item's type identifiers, best first.
    ///   - openableInPlace: Those the item offers as a file where it lies, as the Files app does.
    ///   - hasName: The item has a name of its own, as a file has and a selection has not.
    public static func typeIdentifier(registered: [String], openableInPlace: [String], hasName: Bool) -> String? {
        // What comes out of a file browser is a file whatever its type, a text file included.
        if let identifier = openableInPlace.first { return identifier }
        for identifier in registered {
            guard let type = UTType(identifier), !type.conforms(to: .url) else { continue }
            guard type.conforms(to: .data) || type.conforms(to: .directory) else { continue }
            // A photo or a PDF is a file. Text is one only when it has a name: an attachment has,
            // words picked out of a page have not.
            return !type.conforms(to: .text) || hasName ? identifier : nil
        }
        return nil
    }

    /// The name a dragged item is announced under: its own, with the extension of its type when
    /// it has none.
    public static func name(suggested: String?, typeIdentifier: String) -> String {
        let name = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Untitled", bundle: #bundle)
        guard (name as NSString).pathExtension.isEmpty, let ending = UTType(typeIdentifier)?.preferredFilenameExtension else { return name }
        return "\(name).\(ending)"
    }
}
