// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import ARDProtocol
public import Foundation
public import RemoteDesktopCore
import Synchronization

/// Why a native transfer failed.
public enum NativeFileTransferError: LocalizedError, Sendable, Equatable {
    /// The Mac sent nothing for this path: it does not exist, or the account cannot read it.
    case notFound(path: String)
    /// The Mac could not save what was sent in this folder (it may not write there).
    case refused(directory: String, status: UInt16)
    case noAnswer
    /// The Mac gave up sending part way, and said so with this Carbon error.
    case abortedByMac(status: Int32)
    case sessionEnded
    /// Screen Sharing cannot list folders; browsing needs Remote Login.
    case browsingUnsupported
    /// What the Mac sent made no sense.
    case malformed(String)
    /// A local file changed size while it was being sent.
    case sourceChanged(name: String)
    /// What was chosen is not a file or folder that can be sent (a link, for one).
    case nothingToSend(name: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): String(localized: "“\((path as NSString).lastPathComponent)” isn't on the Mac, or this account can't read it.", bundle: #bundle)
        case .refused(let directory, _): String(localized: "The Mac couldn't save to “\(directory)”. This account may not be allowed to write there.", bundle: #bundle)
        case .noAnswer: String(localized: "The Mac stopped responding to the transfer.", bundle: #bundle)
        case .abortedByMac(let status): String(localized: "The Mac stopped sending part way (error \(status)).", bundle: #bundle)
        case .sessionEnded: String(localized: "The session ended before the transfer finished.", bundle: #bundle)
        case .browsingUnsupported: String(localized: "Browsing the Mac's files needs Remote Login.", bundle: #bundle)
        case .malformed(let detail): String(localized: "The Mac sent something unexpected (\(detail)).", bundle: #bundle)
        case .sourceChanged(let name): String(localized: "“\(name)” changed while it was being sent.", bundle: #bundle)
        case .nothingToSend(let name): String(localized: "“\(name)” isn't a file or folder that can be sent.", bundle: #bundle)
        }
    }

    init(_ error: FileTransferError, path: String) {
        switch error {
        case .notFound: self = .notFound(path: path)
        // afpAccessDenied and permErr: what the Mac says of a file this account may not read.
        case .aborted(-5000), .aborted(-54): self = .notFound(path: path)
        case .aborted(let status): self = .abortedByMac(status: status)
        case .malformed(let detail): self = .malformed(detail)
        }
    }
}

/// Screen Sharing's own file transfer, the one Screen Sharing.app uses when files are dragged in or
/// out of its window. A Mac accepts a transfer without a drag before it: a destination folder (which
/// it creates if missing, `~` allowed) and the items to put there, or an absolute path to send back.
/// It cannot list folders, so it cannot browse.
///
/// One transfer runs at a time. Uploads keep only half a megabyte queued, so typing and pointing
/// stay responsive while a large file goes out. Downloads hold at most ``DownloadInbox/creditLimit``
/// bytes between the socket and the disk; beyond that the session stops reading until the writer
/// catches up, so a slow destination slows the Mac down rather than filling memory.
final class ARDFileTransfers: FileTransfer {
    private struct State {
        var nextID: UInt32 = 1
        var downloads: [UInt32: DownloadInbox] = [:]
        var uploads: [UInt32: UploadAnswer] = [:]
        /// Downloads this viewer stopped. The Mac still sends what was already on its way.
        var stopped: Set<UInt32> = []
        var isBusy = false
        var turnWaiters: [CheckedContinuation<Void, Never>] = []
        var isClosed = false
    }

    private let connection: ARDConnection
    private let state = Mutex(State())
    private let diagnostics: (@Sendable (String) -> Void)?

    static let queueLimit = 512 * 1024
    /// How long to wait for the Mac to confirm an upload once all of it has left, or for the next
    /// piece of a download.
    static let answerTimeout: Duration = .seconds(30)

    init(connection: ARDConnection, diagnostics: (@Sendable (String) -> Void)? = nil) {
        self.connection = connection
        self.diagnostics = diagnostics
    }

    var canBrowse: Bool { false }

    func defaultUploadDirectory() async throws -> String { "~/Downloads" }

    func list(directory: String) async throws -> [RemoteFileEntry] {
        throw NativeFileTransferError.browsingUnsupported
    }

    func upload(from localFile: URL, toDirectory remoteDirectory: String) -> AsyncThrowingStream<TransferProgress, any Error> {
        run { progress in try await self.performUpload(localFile, to: remoteDirectory, progress: progress) }
    }

    func download(_ remotePath: String, to localFile: URL) -> AsyncThrowingStream<TransferProgress, any Error> {
        run { progress in try await self.performDownload(remotePath, to: localFile, progress: progress) }
    }

    // MARK: Messages from the Mac

    /// Called by the engine for every transfer-related message. Returns once a download has room for
    /// what arrived, which holds up the engine's reading while that download's writer is behind.
    func receive(_ event: ServerEvent) async {
        switch event {
        case .fileTransfer(let message):
            let id = message.transferID
            let (download, upload, stopped) = state.withLock { ($0.downloads[id], $0.uploads[id], $0.stopped.contains(id)) }
            if let upload {
                switch message.body {
                case .received(let name, let status):
                    upload.resolve(.success((name, status)))
                case .progress(let fraction):
                    upload.touch()
                    diagnostics?("file transfer \(id): the Mac has written \(Int(fraction * 100))%")
                case .unusable(let command, let reason):
                    upload.resolve(.failure(.malformed("command \(command): \(reason)")))
                default:
                    diagnostics?("file transfer \(id): command \(message.command) during an upload")
                }
            } else if let download {
                await download.deliver(message.body)
            } else if !stopped {
                diagnostics?("file transfer \(id): command \(message.command) for no one")
            }
        default:
            break
        }
    }

    /// Fails everything in progress: the session has ended.
    func close() {
        let (downloads, uploads, turns) = state.withLock { state in
            state.isClosed = true
            defer {
                state.downloads.removeAll()
                state.uploads.removeAll()
                state.turnWaiters.removeAll()
            }
            return (Array(state.downloads.values), Array(state.uploads.values), state.turnWaiters)
        }
        for download in downloads { download.close() }
        for upload in uploads { upload.resolve(.failure(.sessionEnded)) }
        for turn in turns { turn.resume() }
    }

    // MARK: Running one at a time

    private func run(
        _ body: @escaping @Sendable (_ progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> Void
    ) -> AsyncThrowingStream<TransferProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.takeTurn()
                    defer { self.endTurn() }
                    try Task.checkCancellation()
                    try await body { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func takeTurn() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state in
                if !state.isBusy || state.isClosed {
                    state.isBusy = true
                    return true
                }
                state.turnWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
        if state.withLock({ $0.isClosed }) {
            endTurn()
            throw NativeFileTransferError.sessionEnded
        }
    }

    private func endTurn() {
        let next = state.withLock { state in
            if state.turnWaiters.isEmpty {
                state.isBusy = false
                return nil as CheckedContinuation<Void, Never>?
            }
            return state.turnWaiters.removeFirst()
        }
        next?.resume()
    }

    private func newID() throws -> UInt32 {
        try state.withLock { state in
            guard !state.isClosed else { throw NativeFileTransferError.sessionEnded }
            defer { state.nextID &+= 1 }
            return state.nextID
        }
    }

    private func send(_ id: UInt32, _ body: FileTransferMessage.Body) {
        connection.send(FileTransferMessage(transferID: id, body: body).encoded())
    }

    /// Waits for room in the send queue, as an upload sees it.
    private func waitForSendRoom(below limit: Int) async throws {
        do {
            try await connection.waitForSendRoom(below: limit)
        } catch .cancelled {
            throw CancellationError()
        } catch .transport(.timedOut) {
            throw NativeFileTransferError.noAnswer
        } catch {
            throw NativeFileTransferError.sessionEnded
        }
    }

    // MARK: Upload

    private func performUpload(_ localFile: URL, to directory: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let plan = try LocalTransferPlan(scanning: localFile)
        guard !plan.entries.isEmpty else { throw NativeFileTransferError.nothingToSend(name: localFile.lastPathComponent) }
        let id = try newID()
        let answer = UploadAnswer()
        // Waiting from the start: the Mac may answer (or the session end) at any point.
        let closed = state.withLock { state in
            if state.isClosed { return true }
            state.uploads[id] = answer
            return false
        }
        guard !closed else { throw NativeFileTransferError.sessionEnded }
        defer { state.withLock { _ = $0.uploads.removeValue(forKey: id) } }
        let total = plan.summary.totalBytes
        progress(TransferProgress(bytesTransferred: 0, totalBytes: total))

        send(id, .destination(path: directory))
        send(id, .summary(plan.summary))
        var sent: UInt64 = 0
        var finished = false
        defer {
            // A Mac keeps whatever arrived before the end, so a cancelled upload leaves a short file.
            if !finished { send(id, .end) }
        }
        sending: for entry in plan.entries {
            send(id, .item(entry.item))
            guard entry.item.kind == .file, entry.item.dataSize > 0 else { continue }
            let handle = try FileHandle(forReadingFrom: entry.url)
            defer { try? handle.close() }
            var remaining = entry.item.dataSize
            while remaining > 0 {
                try Task.checkCancellation()
                if answer.isResolved { break sending }
                try await waitForSendRoom(below: Self.queueLimit)
                let piece = try handle.read(upToCount: Int(min(remaining, UInt64(FileTransferMessage.chunkSize)))) ?? Data()
                guard !piece.isEmpty else { throw NativeFileTransferError.sourceChanged(name: entry.item.name) }
                send(id, .data(piece))
                remaining -= UInt64(piece.count)
                sent += UInt64(piece.count)
                progress(TransferProgress(bytesTransferred: sent, totalBytes: total))
            }
        }

        finished = true
        send(id, .end)
        // The Mac answers once it has everything, so its time starts when the last byte has left:
        // half a megabyte can take a minute to drain over a slow tunnel.
        let timer = Task {
            do {
                try await self.waitForSendRoom(below: 1)
                answer.touch()
                while true {
                    let idle = answer.idle
                    if idle >= Self.answerTimeout { break }
                    try await Task.sleep(for: Self.answerTimeout - idle)
                }
                answer.resolve(.failure(.noAnswer))
            } catch let error as NativeFileTransferError {
                answer.resolve(.failure(error))
            } catch {
                // Cancelled: the answer came.
            }
        }
        defer { timer.cancel() }
        let (name, status) = try await answer.value().get()
        guard status == 0 else { throw NativeFileTransferError.refused(directory: directory, status: status) }
        diagnostics?("sent \(localFile.lastPathComponent) to \(directory) as \(name)")
    }

    /// The Mac's answer to one upload, which may arrive before anyone waits for it.
    private final class UploadAnswer: Sendable {
        typealias Outcome = Result<(name: String, status: UInt16), NativeFileTransferError>

        private struct State {
            var outcome: Outcome?
            var waiter: CheckedContinuation<Outcome, Never>?
            var lastHeard = ContinuousClock.now
        }

        private let state = Mutex(State())

        /// Settles the answer; later calls change nothing.
        func resolve(_ outcome: Outcome) {
            let waiter = state.withLock { state -> CheckedContinuation<Outcome, Never>? in
                guard state.outcome == nil else { return nil }
                state.outcome = outcome
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: outcome)
        }

        var isResolved: Bool { state.withLock { $0.outcome != nil } }

        /// The Mac said something about this upload.
        func touch() { state.withLock { $0.lastHeard = .now } }

        var idle: Duration { state.withLock { .now - $0.lastHeard } }

        func value() async -> Outcome {
            await withCheckedContinuation { continuation in
                let outcome = state.withLock { state -> Outcome? in
                    if state.outcome == nil { state.waiter = continuation }
                    return state.outcome
                }
                if let outcome { continuation.resume(returning: outcome) }
            }
        }
    }

    // MARK: Download

    private func performDownload(_ remotePath: String, to localFile: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let id = try newID()
        let inbox = DownloadInbox()
        let closed = state.withLock { state in
            if state.isClosed { return true }
            state.downloads[id] = inbox
            return false
        }
        guard !closed else { throw NativeFileTransferError.sessionEnded }
        var receiver = FileTransferReceiver()
        defer {
            let stop = !receiver.isFinished
            state.withLock { state in
                // Marked before it stops being a download, so nothing that follows is reported as lost.
                if stop { state.stopped.insert(id) }
                state.downloads.removeValue(forKey: id)
            }
            inbox.close()
            // Otherwise the Mac sends the rest anyway, as fast as it can.
            if stop { send(id, .stop) }
        }
        send(id, .fetch(path: remotePath))

        // The Mac sends a whole transfer without pausing; a silence this long means it has stopped.
        let activity = Activity()
        let watchdog = Task {
            while true {
                try await Task.sleep(for: .seconds(1))
                if activity.idle > Self.answerTimeout {
                    activity.timedOut = true
                    inbox.close()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        let writer = try DownloadWriter(destination: localFile)
        let inflater = FileTransferInflater()
        do {
            var total: UInt64?
            var received: UInt64 = 0
            for await body in inbox.bodies {
                defer { inbox.consumed(body) }
                try Task.checkCancellation()
                activity.touch()
                let steps: [FileTransferReceiver.Step]
                do {
                    steps = try receiver.receive(try inflater.expand(body))
                } catch {
                    throw NativeFileTransferError(error, path: remotePath)
                }
                for step in steps {
                    switch step {
                    case .summary(let summary):
                        total = summary.totalBytes
                        progress(TransferProgress(bytesTransferred: 0, totalBytes: total))
                    case .data(let data, _):
                        received += UInt64(data.count)
                        progress(TransferProgress(bytesTransferred: received, totalBytes: total))
                    case .symbolicLink(let path, let target, let item), .refusedLink(let path, let target, let item):
                        // The summary counts a link's target as its size.
                        received += item.dataSize
                        progress(TransferProgress(bytesTransferred: received, totalBytes: total))
                        if case .refusedLink = step {
                            guard !path.isEmpty else { throw NativeFileTransferError.nothingToSend(name: item.name) }
                            diagnostics?("left out \(path.joined(separator: "/")) → \(target): it points outside the download")
                            continue
                        }
                        do {
                            try writer.apply(step)
                        } catch {
                            // A destination that cannot hold links still gets everything else.
                            diagnostics?("could not make the link \(path.joined(separator: "/")) → \(target): \(error)")
                        }
                        continue
                    default:
                        break
                    }
                    try writer.apply(step)
                }
                if receiver.isFinished {
                    try writer.commit()
                    return
                }
            }
            try Task.checkCancellation()
            throw activity.timedOut ? NativeFileTransferError.noAnswer : .sessionEnded
        } catch {
            writer.discard()
            throw error
        }
    }

    /// When a download last heard from the Mac.
    private final class Activity: Sendable {
        private let state = Mutex((last: ContinuousClock.now, timedOut: false))
        func touch() { state.withLock { $0.last = .now } }
        var idle: Duration { state.withLock { .now - $0.last } }
        var timedOut: Bool {
            get { state.withLock { $0.timedOut } }
            set { state.withLock { $0.timedOut = newValue } }
        }
    }
}

/// The messages of one download on their way from the engine to the task that writes them.
///
/// It holds at most ``creditLimit`` bytes of file data. When it is full, ``deliver(_:)`` waits, and
/// with it the engine, which stops reading the socket: TCP then holds the Mac back. (The Mac's file
/// sender does not slow down itself; its daemon buffers whatever the viewer does not take.)
final class DownloadInbox: Sendable {
    static let creditLimit = 8 << 20

    private struct State {
        var continuation: AsyncStream<FileTransferMessage.Body>.Continuation?
        var queuedBytes = 0
        var waiter: CheckedContinuation<Void, Never>?
    }

    let bodies: AsyncStream<FileTransferMessage.Body>
    private let state: Mutex<State>

    init() {
        let (bodies, continuation) = AsyncStream.makeStream(of: FileTransferMessage.Body.self)
        self.bodies = bodies
        state = Mutex(State(continuation: continuation))
    }

    /// The file bytes a body holds in memory.
    static func size(of body: FileTransferMessage.Body) -> Int {
        switch body {
        case .data(let data), .compressedData(let data, _): data.count
        default: 0
        }
    }

    /// Queues `body`, then waits while the queue is over its limit. Returns at once after ``close()``.
    func deliver(_ body: FileTransferMessage.Body) async {
        let size = Self.size(of: body)
        let full = state.withLock { state in
            guard let continuation = state.continuation else { return false }
            state.queuedBytes += size
            continuation.yield(body)
            return state.queuedBytes >= Self.creditLimit
        }
        guard full else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state in
                if state.continuation == nil || state.queuedBytes < Self.creditLimit { return true }
                state.waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// The writer is done with `body`: its bytes no longer count against the limit.
    func consumed(_ body: FileTransferMessage.Body) {
        let size = Self.size(of: body)
        guard size > 0 else { return }
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.queuedBytes -= size
            guard state.queuedBytes < Self.creditLimit else { return nil }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Ends the stream and lets a waiting engine go; later deliveries are dropped.
    func close() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.continuation?.finish()
            state.continuation = nil
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

/// What an upload sends: every item under a local file or folder, in the order the Mac expects.
struct LocalTransferPlan {
    struct Entry {
        var item: FileTransferItem
        var url: URL
    }

    var entries: [Entry] = []
    var summary = FileTransferSummary(singleFile: 0, totalBytes: 0, allocatedBytes: 0, fileCount: 0, folderCount: 0)

    static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey,
        .creationDateKey, .contentModificationDateKey, .attributeModificationDateKey, .contentAccessDateKey,
    ]

    init(scanning root: URL) throws {
        try add(root, depth: 0)
        summary.singleFile = entries.count == 1 && entries[0].item.kind == .file ? 1 : 0
    }

    private mutating func add(_ url: URL, depth: UInt16) throws {
        let values = try url.resourceValues(forKeys: Self.keys)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = UInt16((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644) & 0o7777
        func date(_ value: Date?) -> FileTransferDate { value.map(FileTransferDate.init) ?? .zero }
        let name = url.lastPathComponent
        if values.isDirectory == true {
            entries.append(Entry(item: FileTransferItem(
                kind: .folder, name: name, depth: depth, mode: 0o040000 | permissions,
                created: date(values.creationDate), contentModified: date(values.contentModificationDate),
                attributesModified: date(values.attributeModificationDate), accessed: date(values.contentAccessDate)
            ), url: url))
            summary.folderCount += 1
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(Self.keys))
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try add(child, depth: depth + 1)
            }
        } else if values.isRegularFile == true {
            let size = UInt64(values.fileSize ?? 0)
            entries.append(Entry(item: FileTransferItem(
                kind: .file, name: name, depth: depth, mode: 0o100000 | permissions, dataSize: size,
                created: date(values.creationDate), contentModified: date(values.contentModificationDate),
                attributesModified: date(values.attributeModificationDate), accessed: date(values.contentAccessDate)
            ), url: url))
            summary.fileCount += 1
            summary.totalBytes += size
            summary.allocatedBytes += UInt64(values.totalFileAllocatedSize ?? Int(size))
        }
        // Links and anything else are left out, as they would mean something else on the Mac.
    }
}

/// Writes an incoming transfer into a hidden folder beside the destination, then moves the top item
/// into place, so a failed or cancelled download never leaves a partial file under the real name.
final class DownloadWriter {
    let destination: URL
    let staging: URL
    private var handle: FileHandle?
    private var currentFile: (url: URL, item: FileTransferItem)?
    private var folders: [(url: URL, item: FileTransferItem)] = []
    private var top: URL?

    init(destination: URL) throws {
        self.destination = destination
        staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    private func url(for path: [String]) -> URL {
        path.reduce(staging.appendingPathComponent("item")) { $0.appendingPathComponent($1) }
    }

    func apply(_ step: FileTransferReceiver.Step) throws {
        switch step {
        case .summary, .finished:
            break
        case .folder(let path, let item):
            let url = url(for: path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            folders.append((url, item))
            if path.isEmpty { top = url }
        case .file(let path, let item):
            let url = url(for: path)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            handle = try FileHandle(forWritingTo: url)
            currentFile = (url, item)
            if path.isEmpty { top = url }
        case .symbolicLink(let path, let target, _):
            // The receiver checked that the target stays inside the transfer.
            try FileManager.default.createSymbolicLink(atPath: url(for: path).path, withDestinationPath: target)
        case .refusedLink:
            break
        case .data(let data, let fork):
            // Resource forks have nowhere to go on iOS; their bytes are counted and dropped.
            if fork == .data { try handle?.write(contentsOf: data) }
        case .fileComplete:
            try handle?.close()
            handle = nil
            if let (url, item) = currentFile { Self.applyAttributes(item, to: url) }
            currentFile = nil
        }
    }

    /// Moves the finished top item to the destination.
    func commit() throws {
        // Folders get their dates last, since writing inside them changes their modification date.
        for (url, item) in folders.reversed() { Self.applyAttributes(item, to: url) }
        guard let top else { throw NativeFileTransferError.malformed("a transfer with nothing in it") }
        try FileManager.default.moveItem(at: top, to: destination)
        try? FileManager.default.removeItem(at: staging)
    }

    func discard() {
        try? handle?.close()
        try? FileManager.default.removeItem(at: staging)
    }

    static func applyAttributes(_ item: FileTransferItem, to url: URL) {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: item.mode & 0o777 | (item.kind == .folder ? 0o700 : 0o600))]
        if let modified = item.contentModified.date { attributes[.modificationDate] = modified }
        if let created = item.created.date { attributes[.creationDate] = created }
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
}
