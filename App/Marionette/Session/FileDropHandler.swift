// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopInteraction
import UIKit
import MarionetteKit

/// Takes files and folders dragged from other apps (Files, Photos, a Mail attachment) over the
/// remote display.
///
/// Only the UIKit bridge: drag location and copies of what was dropped. What a drag does on the
/// remote computer, and where the files go, is up to ``FileDragModel``.
@MainActor
final class FileDropHandler: NSObject, UIDropInteractionDelegate {
    private struct Item {
        var provider: NSItemProvider
        var typeIdentifier: String
        /// The item is a file where it lies (the Files app's), not data that becomes one.
        var opensInPlace: Bool
        var name: String
    }

    private weak var view: InputCaptureView?
    /// The names of the files in the drag that is over the view, worked out once when it arrives:
    /// the system asks about a drag many times a second.
    private var current: (session: ObjectIdentifier, names: [String])?

    init(view: InputCaptureView) {
        self.view = view
    }

    /// The files among what a drag carries. Looked at afresh for the drop: only then do the
    /// session's items have providers that deliver.
    private func items(in session: any UIDropSession) -> [Item] {
        session.items.compactMap { item -> Item? in
            let provider = item.itemProvider
            let inPlace = provider.registeredTypeIdentifiers(fileOptions: [.openInPlace])
            guard let type = DroppedFile.typeIdentifier(
                registered: provider.registeredTypeIdentifiers,
                openableInPlace: inPlace,
                hasName: provider.suggestedName?.isEmpty == false
            ) else { return nil }
            return Item(
                provider: provider,
                typeIdentifier: type,
                opensInPlace: inPlace.contains(type),
                name: DroppedFile.name(suggested: provider.suggestedName, typeIdentifier: type)
            )
        }
    }

    private func names(in session: any UIDropSession) -> [String] {
        let identifier = ObjectIdentifier(session)
        if let current, current.session == identifier { return current.names }
        let names = items(in: session).map(\.name)
        current = (identifier, names)
        return names
    }

    private func location(of session: any UIDropSession) -> ViewPoint? {
        view.map { ViewPoint(session.location(in: $0)) }
    }

    // MARK: UIDropInteractionDelegate

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        !names(in: session).isEmpty
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        guard let model = view?.session, let location = location(of: session) else { return UIDropProposal(operation: .forbidden) }
        let proposal = model.fileDrags.dragMoved(names: names(in: session), to: location)
        return UIDropProposal(operation: proposal == .copy ? .copy : .forbidden)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        view?.session?.fileDrags.dragExited()
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        // Also how a drag the system called off ends. After a drop there is nothing left to end.
        view?.session?.fileDrags.dragExited()
        current = nil
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        guard let model = view?.session, let location = location(of: session) else { return }
        let items = items(in: session)
        let (copies, continuation) = AsyncStream<StagedUpload?>.makeStream()
        let count = items.count
        let wanted = model.fileDrags.drop(names: items.map(\.name), at: location) {
            var staged: [StagedUpload] = []
            var answered = 0
            for await copy in copies {
                if let copy { staged.append(copy) }
                answered += 1
                if answered == count { break }
            }
            return staged
        }
        guard wanted else { return }
        // The system hands the items over only if they are asked for before this method returns.
        for item in items {
            if item.opensInPlace {
                _ = item.provider.loadInPlaceFileRepresentation(forTypeIdentifier: item.typeIdentifier) { url, _, _ in
                    continuation.yield(url.flatMap(Self.copy))
                }
            } else {
                // Data that is not a file yet (a picture out of a web page): the system makes a
                // file of it, which lasts as long as the handler.
                _ = item.provider.loadFileRepresentation(forTypeIdentifier: item.typeIdentifier) { url, _ in
                    continuation.yield(url.flatMap(Self.copy))
                }
            }
        }
    }

    /// Copies a dropped item aside. Called inside the provider's handler: the item is readable
    /// only there, and a copy the system made for the drop is gone when the handler returns.
    private nonisolated static func copy(_ url: URL) -> StagedUpload? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var copy: StagedUpload?
        // Handed over in place, the item is another app's, and may still have to come down from
        // iCloud: the read goes through file coordination.
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { readable in
            copy = try? StagedUpload(copying: readable)
        }
        return copy
    }
}
