// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
import Observation
public import RemoteDesktopCore

/// A copy of a local file or folder, set aside to be sent. What a person picks or drops can only be
/// read for a moment, so it is copied first. The copy sits alone in a folder of its own, under the
/// item's own name; the queue it is given to removes both when the upload is over.
public struct StagedUpload: Sendable, Hashable {
    public let file: URL

    /// Copies `source`, which has to be readable now: inside its security scope, or inside the
    /// handler an item provider delivered it to.
    public init(copying source: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Uploads/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        file = copy
    }

    /// Removes the copy: it will not be sent after all.
    public func discard() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

/// File transfers of one session, with progress. Transfers run one at a time, in the order queued.
@MainActor
@Observable
public final class TransferQueue {
    public struct Item: Identifiable, Sendable, Hashable {
        public enum Direction: Sendable, Hashable {
            case upload
            case download
        }

        public enum State: Sendable, Hashable {
            case waiting
            case running
            case finished
            case failed(message: String)
            case cancelled
        }

        public let id: UUID
        public var name: String
        public var direction: Direction
        public var state: State
        public var progress: TransferProgress?
        /// Where a finished download is on this device. `nil` for uploads and until it has finished.
        public var localURL: URL?

        public var isActive: Bool { state == .waiting || state == .running }
    }

    /// What a small indicator says about the transfers: how those under way are doing and, for a
    /// moment afterwards, how they ended. One run of the queue, from its first transfer until
    /// nothing is waiting or running, is told as a whole.
    public struct Activity: Sendable, Hashable {
        public enum Phase: Sendable, Hashable {
            /// This many are waiting or running.
            case active(remaining: Int)
            /// All that were not cancelled arrived.
            case finished(count: Int)
            /// This many did not arrive.
            case failed(count: Int)
        }

        public var phase: Phase
        /// How much of the run is done, 0...1.
        public var fraction: Double
        /// Which way the transfers go; `nil` when some go each way.
        public var direction: Item.Direction?
    }

    /// The transfers queued since the queue was last idle, by how they ended.
    private struct Run {
        var total = 0
        var finished = 0
        var failed = 0
        var cancelled = 0
        var directions: Set<Item.Direction> = []

        var remaining: Int { total - finished - failed - cancelled }
    }

    private enum Work {
        /// `staged`: the copy made for this upload, removed when the upload is over.
        case upload(local: URL, remoteDirectory: String?, staged: StagedUpload?)
        case download(remotePath: String, local: URL)
        /// A download whose place is chosen when it finishes: ``destinationDirectory``, under a name
        /// nothing else there has.
        case downloadToDirectory(remotePath: String, name: String)

        /// The upload is over, however it ended, or never started.
        func discardStaged() {
            if case .upload(_, _, let staged?) = self { staged.discard() }
        }
    }

    public private(set) var items: [Item] = []
    /// What an indicator shows; `nil` when there is nothing to say.
    public private(set) var activity: Activity? {
        didSet { if hasActivity != (activity != nil) { hasActivity = activity != nil } }
    }
    /// Whether there is an ``activity`` at all. Kept apart so that a view which only shows or hides
    /// something for it is not drawn again at every step of progress.
    public private(set) var hasActivity = false
    /// How long ``activity`` goes on saying how the transfers ended.
    @ObservationIgnored public var activityLinger: Duration = .seconds(4)
    @ObservationIgnored private var run = Run()
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    private var work: [UUID: Work] = [:]
    private var runner: Task<Void, Never>?
    private var current: (id: UUID, task: Task<Void, Never>)?
    /// The running transfer lost its connection, as opposed to being cancelled by the user.
    private var interruptedID: UUID?
    private var transfer: (any FileTransfer)?
    /// Whether there is a file transfer to queue for. Without one, whatever is queued fails at once.
    public var isAvailable: Bool { transfer != nil }
    /// The folder downloads go to when no destination is given. The app sets its Documents folder,
    /// so that received files appear in the Files app; the default is the temporary directory.
    /// Asked each time a download finishes, and created if it does not exist.
    @ObservationIgnored public var destinationDirectory: () -> URL = { FileManager.default.temporaryDirectory }

    public init() {}

    public init(destinationDirectory: @escaping () -> URL) {
        self.destinationDirectory = destinationDirectory
    }

    /// The capability to use. `nil` (session gone) fails the running transfer, saying why, and
    /// whatever is still waiting.
    public func setTransfer(_ transfer: (any FileTransfer)?) {
        self.transfer = transfer
        if transfer == nil {
            if let current {
                interruptedID = current.id
                current.task.cancel()
            }
            for item in items where item.state == .waiting {
                work.removeValue(forKey: item.id)?.discardStaged()
                settle(item.id, as: .failed(message: String(localized: "The session ended.", bundle: #bundle)))
            }
        } else {
            pump()
        }
    }

    public var hasActiveTransfers: Bool { items.contains(where: \.isActive) }

    /// Queues a local file for upload. `remoteDirectory` defaults to the back end's upload folder.
    @discardableResult
    public func upload(_ localFile: URL, toDirectory remoteDirectory: String? = nil) -> UUID {
        enqueue(name: localFile.lastPathComponent, direction: .upload, work: .upload(local: localFile, remoteDirectory: remoteDirectory, staged: nil))
    }

    /// Queues a copy made for sending. The copy is removed when its upload is over, however it ends.
    @discardableResult
    public func upload(_ staged: StagedUpload, toDirectory remoteDirectory: String? = nil) -> UUID {
        enqueue(name: staged.file.lastPathComponent, direction: .upload, work: .upload(local: staged.file, remoteDirectory: remoteDirectory, staged: staged))
    }

    @discardableResult
    public func download(_ entry: RemoteFileEntry, to localFile: URL) -> UUID {
        enqueue(name: entry.name, direction: .download, work: .download(remotePath: entry.path, local: localFile))
    }

    /// Queues a remote file for download into ``destinationDirectory``. The file appears there only
    /// once it is complete, as "Name.ext", or "Name 2.ext" and so on if that is taken; the item's
    /// ``Item/localURL`` then says where.
    @discardableResult
    public func download(_ entry: RemoteFileEntry) -> UUID {
        enqueue(name: entry.name, direction: .download, work: .downloadToDirectory(remotePath: entry.path, name: entry.name))
    }

    /// A URL in `directory` for a file called `name` that does not exist yet: `name` itself, or
    /// "Name 2.ext", "Name 3.ext", … Characters that would leave the directory are replaced.
    public nonisolated static func uniqueURL(forFileNamed name: String, in directory: URL) -> URL {
        var safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\0", with: "")
        if safe.isEmpty || safe == "." || safe == ".." { safe = String(localized: "Download", bundle: #bundle) }
        let first = directory.appending(path: safe, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        let stem = (safe as NSString).deletingPathExtension
        let fileExtension = (safe as NSString).pathExtension
        var number = 2
        while true {
            let candidate = directory.appending(
                path: fileExtension.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(fileExtension)", directoryHint: .notDirectory
            )
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    public func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isActive else { return }
        if current?.id == id {
            current?.task.cancel()
        } else {
            work.removeValue(forKey: id)?.discardStaged()
            settle(id, as: .cancelled)
        }
    }

    /// Deletes a finished download's file from this device and takes it off the list. A file that is
    /// already gone (deleted in the Files app, say) only leaves the list.
    public func deleteReceivedFile(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].direction == .download, items[index].state == .finished,
              let url = items[index].localURL
        else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        }
        items.remove(at: index)
    }

    /// Removes finished, failed and cancelled transfers from the list.
    public func clearCompleted() {
        items.removeAll { !$0.isActive }
    }

    /// Suspends until nothing is waiting or running. For tests.
    public func waitUntilIdle() async {
        while let runner {
            await runner.value
            if self.runner == runner { break }
        }
    }

    private func enqueue(name: String, direction: Item.Direction, work: Work) -> UUID {
        let id = UUID()
        items.append(Item(id: id, name: name, direction: direction, state: .waiting))
        run.total += 1
        run.directions.insert(direction)
        if transfer != nil {
            self.work[id] = work
            refreshActivity()
            pump()
        } else {
            work.discardStaged()
            settle(id, as: .failed(message: String(localized: "File transfer is not available.", bundle: #bundle)))
        }
        return id
    }

    /// A transfer ended: it finished, failed or was cancelled.
    private func settle(_ id: UUID, as state: Item.State, localURL: URL? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isActive else { return }
        items[index].state = state
        if let localURL { items[index].localURL = localURL }
        switch state {
        case .finished: run.finished += 1
        case .failed: run.failed += 1
        case .cancelled: run.cancelled += 1
        case .waiting, .running: break
        }
        refreshActivity()
    }

    /// Brings ``activity`` up to date. When the last transfer of a run has ended, the outcome
    /// stays up for a moment and then goes.
    private func refreshActivity() {
        guard run.total > 0 else { return }
        let direction = run.directions.count == 1 ? run.directions.first : nil
        lingerTask?.cancel()
        lingerTask = nil
        guard run.remaining == 0 else {
            let underWay = items.first { $0.state == .running }?.progress?.fraction ?? 0
            let fraction = (Double(run.total - run.remaining) + underWay) / Double(run.total)
            activity = Activity(phase: .active(remaining: run.remaining), fraction: min(1, fraction), direction: direction)
            return
        }
        let ended = run
        run = Run()
        guard ended.failed > 0 || ended.finished > 0 else {
            // Everything was cancelled: the person knows.
            activity = nil
            return
        }
        activity = Activity(phase: ended.failed > 0 ? .failed(count: ended.failed) : .finished(count: ended.finished), fraction: 1, direction: direction)
        let linger = activityLinger
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard let self, !Task.isCancelled else { return }
            self.lingerTask = nil
            self.activity = nil
        }
    }

    private func pump() {
        guard runner == nil, transfer != nil, items.contains(where: { $0.state == .waiting }) else { return }
        runner = Task { [weak self] in
            while let self, let next = self.items.first(where: { $0.state == .waiting }), let transfer = self.transfer {
                await self.run(next.id, using: transfer)
            }
            self?.runner = nil
        }
    }

    private func run(_ id: UUID, using transfer: any FileTransfer) async {
        guard let work = work.removeValue(forKey: id) else {
            settle(id, as: .cancelled)
            return
        }
        defer { work.discardStaged() }
        update(id) { $0.state = .running }
        // A download without a destination is received out of sight and moved into place whole.
        var staging: URL?
        // A download to a file that was not there before is removed again unless it completes:
        // half a file is worse than none.
        var partial: URL?
        switch work {
        case .downloadToDirectory:
            staging = FileManager.default.temporaryDirectory.appending(path: "Marionette-Transfer-\(id.uuidString)", directoryHint: .isDirectory)
        case .download(_, let local) where !FileManager.default.fileExists(atPath: local.path):
            partial = local
        case .download, .upload:
            break
        }
        let task = Task { [weak self, staging, partial] in
            var completed = false
            defer {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                if let partial, !completed { try? FileManager.default.removeItem(at: partial) }
            }
            do {
                let stream: AsyncThrowingStream<TransferProgress, any Error>
                var received: URL?
                switch work {
                case .upload(let local, let directory, _):
                    let target: String
                    if let directory { target = directory } else { target = try await transfer.defaultUploadDirectory() }
                    stream = transfer.upload(from: local, toDirectory: target)
                case .download(let remotePath, let local):
                    received = local
                    stream = transfer.download(remotePath, to: local)
                case .downloadToDirectory(let remotePath, _):
                    guard let staging else { throw CancellationError() }
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    let partial = staging.appending(path: "download", directoryHint: .notDirectory)
                    received = partial
                    stream = transfer.download(remotePath, to: partial)
                }
                for try await progress in stream {
                    self?.update(id) { $0.progress = progress }
                }
                try Task.checkCancellation()
                if case .downloadToDirectory(_, let name) = work, let partial = received {
                    guard let self else { return }
                    let directory = self.destinationDirectory()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let final = Self.uniqueURL(forFileNamed: name, in: directory)
                    try FileManager.default.moveItem(at: partial, to: final)
                    received = final
                }
                completed = true
                self?.settle(id, as: .finished, localURL: received)
            } catch {
                guard let self else { return }
                let state: Item.State
                if self.interruptedID == id {
                    state = .failed(message: Self.interruptedMessage)
                } else if error is CancellationError || Task.isCancelled {
                    state = .cancelled
                } else {
                    state = .failed(message: FileTransferFailure.message(for: error))
                }
                self.settle(id, as: state)
            }
        }
        current = (id, task)
        await task.value
        current = nil
        if interruptedID == id { interruptedID = nil }
    }

    static let interruptedMessage = String(localized: "The connection to the remote computer closed.", bundle: #bundle)

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        refreshActivity()
    }
}
