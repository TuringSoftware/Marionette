// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
@testable import AppleScreenSharing
import Foundation
import RemoteDesktopCore
import Synchronization
import Testing

/// The local halves of native file transfer: what an upload sends, and how a download is written.
struct FileTransferLocalTests {
    static func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marionette-tree-\(UUID().uuidString)/Project")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b/c"), withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data(repeating: 7, count: 100_000).write(to: root.appendingPathComponent("b/big.bin"))
        try Data().write(to: root.appendingPathComponent("b/c/empty"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("a.txt").path)
        return root
    }

    @Test func anUploadListsFoldersBeforeTheirContents() throws {
        let root = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let plan = try LocalTransferPlan(scanning: root)
        let listing = plan.entries.map { "\($0.item.depth) \($0.item.kind == .folder ? "d" : "f") \($0.item.name)" }
        #expect(listing == ["0 d Project", "1 f a.txt", "1 d b", "2 f big.bin", "2 d c", "3 f empty"])
        #expect(plan.summary.singleFile == 0)
        #expect(plan.summary.fileCount == 3 && plan.summary.folderCount == 3)
        #expect(plan.summary.totalBytes == 100_005)
        #expect(plan.entries[1].item.mode == 0o100755)
        #expect(plan.entries[0].item.mode & 0o170000 == 0o040000)
        #expect(plan.entries[0].item.flags == 0x10)

        var receiver = FileTransferReceiver()
        var paths: [String] = []
        _ = try receiver.receive(.summary(plan.summary))
        for entry in plan.entries {
            for step in try receiver.receive(.item(entry.item)) {
                if case .folder(let path, _) = step { paths.append(path.joined(separator: "/") + "/") }
                if case .file(let path, _) = step { paths.append(path.joined(separator: "/")) }
            }
            if entry.item.dataSize > 0 {
                _ = try receiver.receive(.data(try Data(contentsOf: entry.url)))
            }
        }
        #expect(try receiver.receive(.end).last == .finished)
        #expect(paths == ["/", "a.txt", "b/", "b/big.bin", "b/c/", "b/c/empty"])

        let single = try LocalTransferPlan(scanning: root.appendingPathComponent("a.txt"))
        #expect(single.summary.singleFile == 1 && single.entries.count == 1)
    }

    @Test func aDownloadAppearsOnlyWhenComplete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marionette-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Fetched")
        let modified = FileTransferDate(Date(timeIntervalSince1970: 1_700_000_000))

        let writer = try DownloadWriter(destination: destination)
        var receiver = FileTransferReceiver()
        let bodies: [FileTransferMessage.Body] = [
            .summary(FileTransferSummary(singleFile: 0, totalBytes: 9, allocatedBytes: 0, fileCount: 1, folderCount: 2)),
            .item(FileTransferItem(kind: .folder, name: "Remote Name", depth: 0, mode: 0o040755, contentModified: modified)),
            .item(FileTransferItem(kind: .folder, name: "inner", depth: 1, mode: 0o040700)),
            .item(FileTransferItem(kind: .file, name: "notes.txt", depth: 2, mode: 0o100600, dataSize: 5, resourceForkSize: 4, contentModified: modified)),
            .data(Data("hello".utf8)), .data(Data("rsrc".utf8)),
        ]
        for body in bodies {
            for step in try receiver.receive(body) { try writer.apply(step) }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        for step in try receiver.receive(.end) { try writer.apply(step) }
        try writer.commit()

        let notes = destination.appendingPathComponent("inner/notes.txt")
        #expect(try String(contentsOf: notes, encoding: .utf8) == "hello")
        let attributes = try FileManager.default.attributesOfItem(atPath: notes.path)
        #expect((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 == 1_700_000_000)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folderDate = try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date
        #expect(folderDate?.timeIntervalSince1970 == 1_700_000_000)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Fetched"])
    }

    @Test func aFailedDownloadLeavesNothing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marionette-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try DownloadWriter(destination: directory.appendingPathComponent("file.bin"))
        try writer.apply(.file(path: [], item: FileTransferItem(kind: .file, name: "file.bin", depth: 0, mode: 0o100644, dataSize: 10)))
        try writer.apply(.data(Data([1, 2, 3]), fork: .data))
        writer.discard()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func linksInsideTheDownloadAreMade() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marionette-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("App")
        let writer = try DownloadWriter(destination: destination)
        var receiver = FileTransferReceiver()
        let bodies: [FileTransferMessage.Body] = [
            .item(FileTransferItem(kind: .folder, name: "App", depth: 0, mode: 0o040755)),
            .item(FileTransferItem(kind: .folder, name: "Versions", depth: 1, mode: 0o040755)),
            .item(FileTransferItem(kind: .file, name: "binary", depth: 2, mode: 0o100755, dataSize: 2)),
            .data(Data("ok".utf8)),
            .item(FileTransferItem(kind: .symbolicLink, name: "Current", depth: 1, mode: 0o120755, dataSize: 15, symbolicLinkTarget: "Versions/binary")),
            .item(FileTransferItem(kind: .symbolicLink, name: "out", depth: 1, mode: 0o120755, dataSize: 4, symbolicLinkTarget: "/etc")),
            .end,
        ]
        for body in bodies {
            for step in try receiver.receive(body) { try writer.apply(step) }
        }
        try writer.commit()
        let link = destination.appendingPathComponent("Current")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "Versions/binary")
        #expect(try String(contentsOf: link, encoding: .utf8) == "ok")
        // The link that pointed outside was left out.
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == ["Current", "Versions"])
    }

    @Test func aFullDownloadHoldsUpItsDelivererUntilWritten() async throws {
        let inbox = DownloadInbox()
        let piece = Data(count: FileTransferMessage.chunkSize)
        let pieces = DownloadInbox.creditLimit / piece.count
        let delivered = Counter()
        let engine = Task {
            for _ in 0..<(pieces + 3) {
                await inbox.deliver(.data(piece))
                delivered.increment()
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        // The delivery that filled the inbox has not returned.
        #expect(delivered.value == pieces - 1)
        var iterator = inbox.bodies.makeAsyncIterator()
        for _ in 0..<4 {
            let body = try #require(await iterator.next())
            inbox.consumed(body)
        }
        await engine.value
        #expect(delivered.value == pieces + 3)
        // Full again with the next piece; closing lets the waiting deliverer go.
        let stuck = Task { await inbox.deliver(.data(piece)) }
        try await Task.sleep(for: .milliseconds(100))
        inbox.close()
        await stuck.value
    }

    @Test func errorsReadAsSentences() {
        let errors: [NativeFileTransferError] = [
            .notFound(path: "/Users/a/Report.pdf"), .refused(directory: "/System", status: 5), .noAnswer, .abortedByMac(status: -1), .sessionEnded,
            .browsingUnsupported, .malformed("x"), .sourceChanged(name: "a"), .nothingToSend(name: "link"),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            #expect(text.count > 10 && text.hasSuffix("."), "\(text)")
        }
        #expect(NativeFileTransferError.notFound(path: "/Users/a/Report.pdf").errorDescription?.contains("Report.pdf") == true)
    }
}

/// The outbound queue's room waits, which an upload makes before each piece.
struct OutboundRoomTests {
    /// Takes no bytes at all, as a peer advertising a zero window does, or fails every write.
    final class StuckStream: ByteStream {
        let fails: Bool
        init(fails: Bool = false) { self.fails = fails }
        func read(upTo maxLength: Int) async throws -> Data? {
            try await Task.sleep(for: .seconds(3600))
            return nil
        }
        func write(_ data: Data) async throws {
            if fails { throw TransportError.closed }
            try await Task.sleep(for: .seconds(3600))
        }
        func close() async {}
    }

    static func waitOutcome(_ outbound: ARDOutbound, below limit: Int = 1) async -> ARDError? {
        do {
            try await outbound.waitForRoom(below: limit)
            return nil
        } catch {
            return error
        }
    }

    @Test func aWaitEndsWhenItsTaskIsCancelled() async throws {
        let outbound = ARDOutbound(stream: StuckStream()) { _ in }
        defer { outbound.cancel() }
        outbound.send(Data(count: 1000))
        let waiter = Task { await Self.waitOutcome(outbound) }
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        #expect(await waiter.value == .cancelled)
    }

    @Test func aWaitGivesUpWhenNothingIsWritten() async throws {
        let outbound = ARDOutbound(stream: StuckStream(), stallTimeout: .milliseconds(300)) { _ in }
        defer { outbound.cancel() }
        outbound.send(Data(count: 1000))
        let started = ContinuousClock.now
        #expect(await Self.waitOutcome(outbound) == .transport(.timedOut))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aWriteFailureEndsEveryWaitNowAndLater() async throws {
        let failures = Counter()
        let outbound = ARDOutbound(stream: StuckStream(fails: true)) { _ in failures.increment() }
        defer { outbound.cancel() }
        let waiter = Task { await Self.waitOutcome(outbound) }
        outbound.send(Data(count: 1000))
        #expect(await waiter.value == .closedByPeer)
        #expect(failures.value == 1)
        outbound.send(Data(count: 1000))
        #expect(await Self.waitOutcome(outbound) == .closedByPeer)
    }

    @Test func finishingEndsWaits() async throws {
        let outbound = ARDOutbound(stream: StuckStream()) { _ in }
        defer { outbound.cancel() }
        outbound.send(Data(count: 1000))
        let waiter = Task { await Self.waitOutcome(outbound) }
        try await Task.sleep(for: .milliseconds(100))
        outbound.finish()
        #expect(await waiter.value == .closedByPeer)
    }
}

final class Counter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
