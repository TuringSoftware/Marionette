// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import RemoteDesktopCore

/// How the clipboards of this device and the remote computer are kept in step. App-wide, chosen in
/// Settings, read when a session opens.
public enum ClipboardMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// The default. What the remote computer copies arrives here by itself; what this device copies
    /// goes over when the user pastes it (the paste control, or ⌘V on a hardware keyboard). iOS hands
    /// the clipboard over for those without asking.
    case explicit
    /// As `explicit`, and in addition whatever this device copies is sent as soon as Marionette sees it.
    /// Reading the clipboard without a paste gesture makes iOS ask "Allow Paste?" each time the
    /// contents came from another app. Contents marked as concealed (passwords) are never sent this way.
    case automatic
    /// Nothing is shared in either direction.
    case off

    public var title: String {
        switch self {
        case .explicit: String(localized: "When You Paste", bundle: #bundle)
        case .automatic: String(localized: "Automatically", bundle: #bundle)
        case .off: String(localized: "Off", bundle: #bundle)
        }
    }
}

/// Type identifiers Marionette looks for on the local pasteboard.
public enum PasteboardType {
    /// Set by password managers on what they copy: the item must not be synced or shown.
    public static let concealed = "org.nspasteboard.ConcealedType"
}

/// The clipboard side of one session: carries remote copies to this device, notices when this
/// device's clipboard changes, and — in ``ClipboardMode/automatic`` — sends those changes.
///
/// Echoes are suppressed in both directions: what Marionette itself wrote to the local pasteboard never
/// counts as a local change (so it is neither flagged nor sent back), and a remote offer that only
/// repeats what was just sent from here is not written again. A Mac also announces its clipboard
/// again, unchanged, after clicks and copy shortcuts; such a repeat is never written, so it cannot
/// replace something copied here since.
///
/// On a session that is not encrypted, ``ClipboardMode/automatic`` acts as
/// ``ClipboardMode/explicit``: what is copied here (passwords included) crosses the network only
/// when the user pastes it.
@MainActor
@Observable
public final class ClipboardBridge {
    public let mode: ClipboardMode
    /// This device's clipboard has changed since Marionette last sent it or wrote to it. Drives the dot on
    /// the paste control.
    public private(set) var hasUnsentChange = false
    /// The session can take this device's clipboard right now.
    public private(set) var isAvailable = false
    /// What this device copies is sent without a paste: ``ClipboardMode/automatic`` on an
    /// encrypted session.
    public private(set) var sendsAutomatically = false
    /// How many times this device's clipboard has been sent, for accessibility and tests.
    @ObservationIgnored public private(set) var sendCount = 0

    @ObservationIgnored private let pasteboard: any LocalPasteboard
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var sync: (any ClipboardSync)?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The local change count that needs no attention: the one Marionette wrote or sent last. A write
    /// raises the count by one before it returns, and it does not move afterwards (measured on an
    /// iPhone Duo with iOS 27.1 and in the simulator), so the count read right after
    /// Marionette's own write is the whole of it: any later change is the user's.
    @ObservationIgnored private var acknowledgedChangeCount: Int?
    /// True while Marionette is writing remote contents locally; the change that causes is not the user's.
    @ObservationIgnored private var isWriting = false
    @ObservationIgnored private var lastSent: [ClipboardItem]?
    /// The last contents the remote computer delivered, as it delivered them; kept across
    /// reconnects, which deliver the remote clipboard again.
    @ObservationIgnored private var lastRemote: [ClipboardItem]?
    /// What the local clipboard held at a change count, as Marionette last wrote it there.
    @ObservationIgnored private var lastWritten: (items: [ClipboardItem], changeCount: Int)?
    @ObservationIgnored private var isActive = true
    /// Counts connections so that work started for an old one is dropped.
    @ObservationIgnored private var generation = 0

    init(mode: ClipboardMode, pasteboard: any LocalPasteboard, clock: any AppClock, pollInterval: Duration) {
        self.mode = mode
        self.pasteboard = pasteboard
        self.clock = clock
        self.pollInterval = pollInterval
        guard mode != .off else { return }
        // What is on the clipboard when the session opens is not news. Read now, well before the
        // connection is up, so a copy made just after connecting still counts as a change.
        Task { [weak self, pasteboard] in
            let count = await pasteboard.changeCount
            guard let self, self.acknowledgedChangeCount == nil else { return }
            self.acknowledgedChangeCount = count
        }
    }

    /// A session connected, with clipboard sharing or without. `isEncrypted`: nothing on the way
    /// can read what is sent (the protocol encrypts, or a tunnel does).
    func connected(_ sync: (any ClipboardSync)?, isEncrypted: Bool) {
        disconnected()
        guard mode != .off, let sync else { return }
        self.sync = sync
        isAvailable = true
        sendsAutomatically = mode == .automatic && isEncrypted
        let token = generation
        tasks.append(Task { [weak self] in
            for await offer in sync.remoteOffers() {
                guard let self, self.generation == token else { return }
                await self.receive(offer, token: token)
            }
        })
        tasks.append(Task { [weak self, clock, pollInterval] in
            // Other apps change the clipboard without telling anyone; the change count is cheap to
            // read and never makes iOS ask for permission.
            while !Task.isCancelled {
                try? await clock.sleep(for: pollInterval)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                await self.checkLocalPasteboard()
            }
        })
    }

    func disconnected() {
        generation += 1
        for task in tasks { task.cancel() }
        tasks.removeAll()
        sync = nil
        isAvailable = false
        sendsAutomatically = false
        hasUnsentChange = false
        isWriting = false
    }

    /// Whether the app is in the foreground. Nothing is read from the clipboard in the background.
    func setActive(_ active: Bool) {
        isActive = active
        if active { Task { await checkLocalPasteboard() } }
    }

    private func receive(_ offer: RemoteClipboardOffer, token: Int) async {
        guard let items = try? await offer.load(), !items.isEmpty, generation == token else { return }
        // A repeat of the remote clipboard is not news: either this device still holds it, or
        // what was copied here since is newer and must stay.
        let isRepeat = items == lastRemote
        lastRemote = items
        // A server that announces our own write as a change of its clipboard would otherwise bounce
        // it straight back.
        if isRepeat || items == lastSent { return }
        let converted = await Task.detached(priority: .userInitiated) { ClipboardConversion.incoming(items) }.value
        guard generation == token, !converted.isEmpty else { return }
        if let lastWritten, lastWritten.items == converted, await pasteboard.changeCount == lastWritten.changeCount { return }
        isWriting = true
        // Kept off Universal Clipboard: it came from another computer, not from this person's devices.
        await pasteboard.write(converted, localOnly: true)
        let count = await pasteboard.changeCount
        isWriting = false
        guard generation == token else { return }
        acknowledgedChangeCount = count
        lastWritten = (converted, count)
        lastSent = nil
        hasUnsentChange = false
    }

    /// Looks at the local change count; flags a change, and in automatic mode sends it.
    public func checkLocalPasteboard() async {
        guard let sync, isActive, !isWriting else { return }
        let token = generation
        let count = await pasteboard.changeCount
        guard generation == token, !isWriting, let acknowledged = acknowledgedChangeCount, count != acknowledged else { return }
        guard sendsAutomatically else {
            hasUnsentChange = true
            return
        }
        // Whatever happens next, this change has had its turn: a refused paste prompt must not come
        // back every second.
        acknowledgedChangeCount = count
        if await pasteboard.isConcealed {
            // Never sent by itself; the user can still paste it on purpose.
            hasUnsentChange = true
            return
        }
        let items = await pasteboard.read()
        guard generation == token, !items.isEmpty else { return }
        do {
            try await sync.sendToRemote(items)
            sendCount += 1
            guard generation == token else { return }
            noteSent(items)
            hasUnsentChange = false
        } catch {
            hasUnsentChange = true
        }
    }

    /// Puts items on the remote clipboard because the user pasted them. They are what the local
    /// clipboard holds now, so the dot goes out.
    func sendPasted(_ items: [ClipboardItem]) async throws {
        guard let sync else { throw CancellationError() }
        let token = generation
        let count = await pasteboard.changeCount
        try await sync.sendToRemote(items)
        sendCount += 1
        guard generation == token else { return }
        noteSent(items)
        acknowledgedChangeCount = count
        hasUnsentChange = false
    }

    /// The remote clipboard now holds `items`: whatever it delivers next, even what it held
    /// before, is a change there.
    private func noteSent(_ items: [ClipboardItem]) {
        lastSent = items
        lastRemote = nil
    }

    /// Sends whatever the local clipboard holds. Reading it this way may make iOS ask first.
    func sendCurrentContents() async {
        guard sync != nil else { return }
        let items = await pasteboard.read()
        guard !items.isEmpty else { return }
        try? await sendPasted(items)
    }
}
