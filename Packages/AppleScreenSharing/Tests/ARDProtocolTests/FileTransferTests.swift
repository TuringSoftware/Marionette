// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDTestSupport
import Foundation
import RemoteDesktopCore
import Testing
@testable import ARDProtocol

/// Native file transfer against what Screen Sharing.app and macOS 27.0.1 actually sent
/// (`Fixtures/file-transfer`, recorded through `marionettectl proxy`).
struct FileTransferTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/file-transfer/\(name)", withExtension: "bin"))
        return try Data(contentsOf: url)
    }

    static func messages(_ data: Data) throws -> [FileTransferMessage] {
        var reader = WireReader(data)
        var messages: [FileTransferMessage] = []
        while !reader.isAtEnd { messages.append(try FileTransferMessage.parse(&reader)) }
        return messages
    }

    static func steps(_ messages: [FileTransferMessage]) throws -> [FileTransferReceiver.Step] {
        var receiver = FileTransferReceiver()
        return try messages.flatMap { try receiver.receive($0.body) }
    }

    @Test func everyRecordedMessageEncodesBackToTheSameBytes() throws {
        for name in ["upload-folder-from-viewer", "download-file-from-mac", "received-from-mac", "download-folder-with-links"] {
            let data = try Self.fixture(name)
            let encoded = try Self.messages(data).map { $0.encoded() }.reduce(Data(), +)
            #expect(encoded == data, "\(name)")
        }
        let drop = try Self.fixture("drop-destination")
        var reader = WireReader(drop)
        #expect(try DropDestination.parse(&reader).encoded() == drop)
        let drag = try Self.fixture("drag-from-mac")
        reader = WireReader(drag)
        #expect(try DragPasteboard.parse(&reader).encoded() == drag)
    }

    @Test func aFolderUploadRebuildsItsTree() throws {
        let messages = try Self.messages(try Self.fixture("upload-folder-from-viewer"))
        #expect(messages.allSatisfy { $0.transferID == 2 })
        guard case .destination(let destination) = messages.first?.body else {
            Issue.record("the upload does not open with its destination")
            return
        }
        #expect(destination == "/Users/dev/Desktop")

        let steps = try Self.steps(Array(messages.dropFirst()))
        var made: [String] = []
        var bytes: [String: (data: Int, resource: Int)] = [:]
        var current = ""
        for step in steps {
            switch step {
            case .summary(let summary):
                #expect(summary == FileTransferSummary(singleFile: 0, totalBytes: 65, allocatedBytes: 16384, fileCount: 5, folderCount: 2))
            case .folder(let path, let item):
                #expect(item.kind == .folder && item.flags == 0x10 && item.mode == 0o40755)
                made.append(path.joined(separator: "/") + "/")
            case .file(let path, _):
                current = path.joined(separator: "/")
                made.append(current)
                bytes[current] = (0, 0)
            case .data(let data, let fork):
                if fork == .data { bytes[current]!.data += data.count } else { bytes[current]!.resource += data.count }
            case .fileComplete, .finished, .symbolicLink, .refusedLink:
                break
            }
        }
        #expect(made == ["/", "forked.txt", "empty.dat", "sub/", "sub/c.txt", "a.txt", "xattr.txt"])
        #expect(bytes["forked.txt"]! == (10, 30))
        #expect(bytes["sub/c.txt"]! == (7, 0))
        #expect(bytes["empty.dat"]! == (0, 0))
        #expect(steps.last == .finished)
        #expect(steps.filter { $0 == .fileComplete }.count == 5)
    }

    @Test func aDownloadCarriesTheFileAndItsDates() throws {
        let steps = try Self.steps(try Self.messages(try Self.fixture("download-file-from-mac")))
        guard case .file(let path, let item) = steps[1] else {
            Issue.record("no file in \(steps)")
            return
        }
        #expect(path.isEmpty)
        #expect(item.name == "wfh-transfer-test.txt" && item.dataSize == 19 && item.mode == 0o100644)
        let modified = try #require(item.contentModified.date)
        #expect(abs(modified.timeIntervalSince1970 - 1_795_427_189) < 2)
        #expect(item.backedUp.date == nil)
        #expect(steps[2] == .data(Data("hello from the Mac\n".utf8), fork: .data))
        #expect(Array(steps.suffix(2)) == [.fileComplete, .finished])
    }

    @Test func theMacsDragNamesTheFileItCarries() throws {
        var reader = WireReader(try Self.fixture("drag-from-mac"))
        let drag = try DragPasteboard.parse(&reader)
        #expect(drag.token == 1)
        #expect(try drag.fileURLs() == [URL(string: "file:///Users/dev/Desktop/wfh-transfer-test.txt")!])
    }

    @Test func theServerParserReadsTheNewMessages() throws {
        var buffer = InboundBuffer()
        for name in ["drop-destination", "received-from-mac", "drag-from-mac", "download-file-from-mac"] {
            buffer.append(try Self.fixture(name))
        }
        var parser = ServerMessageParser()
        var events: [ServerEvent] = []
        while let event = try parser.next(from: &buffer) { events.append(event) }
        #expect(events.count == 3 + 4)
        #expect(events[0] == .dropDestination(DropDestination(token: 0x327b_23c7, path: "/Users/dev/Desktop")))
        #expect(events[1] == .fileTransfer(FileTransferMessage(transferID: 2, body: .received(name: "wfh-batch", status: 0))))
        guard case .drag = events[2], case .fileTransfer(let end) = events[6] else {
            Issue.record("unexpected events \(events)")
            return
        }
        #expect(end.body == .end)
    }

    @Test func aDragOfLocalFilesListsThem() throws {
        let urls = [URL(fileURLWithPath: "/tmp/a b.txt"), URL(fileURLWithPath: "/tmp/folder", isDirectory: true)]
        let drag = DragPasteboard.files(urls, token: 9)
        var reader = WireReader(drag.encoded())
        let parsed = try DragPasteboard.parse(&reader)
        #expect(parsed == drag)
        #expect(try parsed.fileURLs() == urls)
        #expect(DragPasteboard.end.encoded() == Data([0x20] + [UInt8](repeating: 0, count: 15)))
        #expect(DragPasteboard.end.isEnd)
    }

    /// A drag that started on the Mac, as it announced it to Screen Sharing.app: the file as a
    /// POSIX path that a fetch takes, and the picture Finder showed under the pointer.
    @Test func theMacsDragCarriesThePathAndThePictureUnderThePointer() throws {
        var reader = WireReader(try Self.fixture("drag-from-mac"))
        let contents = try DragPasteboard.parse(&reader).contents()
        #expect(contents.paths == ["/Users/dev/Desktop/wfh-transfer-test.txt"])
        let picture = try #require(contents.imagePNG)
        #expect(picture.count == 3342)
        #expect(picture.prefix(8) == Data(hex: "89 50 4e 47 0d 0a 1a 0a"))
        // A 64 × 64 picture, by its header.
        #expect(picture.dropFirst(12).prefix(12) == Data("IHDR".utf8) + Data(hex: "00000040 00000040"))
        #expect(DragPasteboard.dragImageType == "com.apple.remotedesktop.dragimage-png")
    }

    /// When the button comes up on the Mac it says so with its token and two zero lengths; a
    /// viewer ends a drag with the token zero as well. Neither carries anything.
    @Test func anEmptyDragCarriesNothing() throws {
        var reader = WireReader(Data(hex: "20 00 00 00  00 00 00 01  00 00 00 00  00 00 00 00"))
        let ended = try DragPasteboard.parse(&reader)
        #expect(reader.isAtEnd)
        #expect(ended == DragPasteboard(token: 1, uncompressedLength: 0, compressed: Data()))
        // The end is in the lengths, whoever's token it carries.
        #expect(ended.isEnd)
        reader = WireReader(try Self.fixture("drag-from-mac"))
        #expect(try !DragPasteboard.parse(&reader).isEnd)
        #expect(try ended.contents().paths.isEmpty)
        #expect(try ended.contents().imagePNG == nil)
        #expect(try DragPasteboard.end.contents().paths.isEmpty)
        #expect(try DragPasteboard.end.contents().imagePNG == nil)
    }

    /// Only files count as dragged files, each item's own; a drag without a picture has none.
    @Test func aDragsContentsAreItsFilesInOrder() throws {
        let urls = [URL(fileURLWithPath: "/tmp/a b.txt"), URL(fileURLWithPath: "/Users/dev/ünï/c.pdf")]
        let files = try DragPasteboard.files(urls, token: 9).contents()
        #expect(files.paths == ["/tmp/a b.txt", "/Users/dev/ünï/c.pdf"])
        #expect(files.imagePNG == nil)

        let archive = PasteboardArchive.encode([
            ClipboardItem(representations: ["public.file-url": Data("https://example.com/not-a-file".utf8)]),
            ClipboardItem(representations: ["public.file-url": Data("file:///Users/dev/x".utf8), DragPasteboard.dragImageType: Data([1, 2, 3])]),
            ClipboardItem(representations: ["public.utf8-plain-text": Data("text".utf8), DragPasteboard.dragImageType: Data([4])]),
        ])
        let mixed = DragPasteboard(token: 1, uncompressedLength: UInt32(archive.count), compressed: Deflate.compressSyncFlushed(archive))
        #expect(try mixed.contents().paths == ["/Users/dev/x"])
        #expect(try mixed.contents().imagePNG == Data([1, 2, 3]))

        // An archive that does not inflate to what it claims is refused, not read short.
        let short = DragPasteboard(token: 1, uncompressedLength: UInt32(archive.count + 1), compressed: Deflate.compressSyncFlushed(archive))
        #expect(throws: WireError.self) { try short.contents() }
    }

    @Test func datesAreCarbonDates() {
        let date = FileTransferDate(Date(timeIntervalSince1970: 1_795_428_094.29524))
        #expect(date.seconds == 0xe729_bf7e)
        #expect(abs(Int(date.fraction) - 0x4b95) < 8)
        #expect(FileTransferDate(Date(timeIntervalSince1970: -3_000_000_000)).seconds == 0)
    }

    // MARK: Hostile input

    static func item(_ name: String, depth: UInt16, kind: FileTransferItem.Kind = .file, size: UInt64 = 0) -> FileTransferMessage.Body {
        .item(FileTransferItem(kind: kind, name: name, depth: depth, mode: kind == .file ? 0o100644 : 0o40755, dataSize: size))
    }

    @Test(arguments: ["..", ".", "", "a/b", "../../etc", "nul\0byte", String(repeating: "x", count: 256)])
    func unusableNamesAreRefused(_ name: String) {
        var receiver = FileTransferReceiver()
        #expect(throws: FileTransferError.self) { try receiver.receive(Self.item(name, depth: 0)) }
    }

    @Test func itemsCannotEscapeTheTopItem() throws {
        // A second top item, an item below a file, and a depth that skips a level.
        var receiver = FileTransferReceiver()
        _ = try receiver.receive(Self.item("top", depth: 0, kind: .folder))
        #expect(throws: FileTransferError.self) { try receiver.receive(Self.item("other", depth: 0)) }

        receiver = FileTransferReceiver()
        _ = try receiver.receive(Self.item("file", depth: 0))
        #expect(throws: FileTransferError.self) { try receiver.receive(Self.item("inside", depth: 1)) }

        receiver = FileTransferReceiver()
        _ = try receiver.receive(Self.item("top", depth: 0, kind: .folder))
        #expect(throws: FileTransferError.self) { try receiver.receive(Self.item("deep", depth: 2)) }

        receiver = FileTransferReceiver()
        #expect(throws: FileTransferError.self) { try receiver.receive(Self.item("orphan", depth: 1)) }
    }

    @Test func climbingBackOutOfAFolderIsFine() throws {
        let steps = try Self.steps([
            Self.item("top", depth: 0, kind: .folder), Self.item("a", depth: 1, kind: .folder),
            Self.item("b", depth: 2, kind: .folder), Self.item("c.txt", depth: 3), Self.item("d.txt", depth: 1), .end,
        ].map { FileTransferMessage(transferID: 1, body: $0) })
        let paths = steps.compactMap { step -> String? in
            switch step {
            case .folder(let path, _), .file(let path, _): path.joined(separator: "/")
            default: nil
            }
        }
        #expect(paths == ["", "a", "a/b", "a/b/c.txt", "d.txt"])
    }

    @Test func dataMustMatchWhatWasAnnounced() throws {
        var receiver = FileTransferReceiver()
        #expect(throws: FileTransferError.self) { try receiver.receive(.data(Data([1]))) }

        receiver = FileTransferReceiver()
        _ = try receiver.receive(Self.item("f", depth: 0, size: 2))
        #expect(throws: FileTransferError.self) { try receiver.receive(.data(Data([1, 2, 3]))) }

        receiver = FileTransferReceiver()
        _ = try receiver.receive(Self.item("f", depth: 0, size: 2))
        _ = try receiver.receive(.data(Data([1])))
        #expect(throws: FileTransferError.malformed("a file ended 1 bytes short")) { try receiver.receive(.end) }
    }

    @Test func aBareEndMeansNotFound() {
        var receiver = FileTransferReceiver()
        #expect(throws: FileTransferError.notFound) { try receiver.receive(.end) }
        #expect(throws: FileTransferError.self) { try receiver.receive(.end) }
    }

    @Test func framingIsChecked() {
        func parse(_ bytes: [UInt8]) throws {
            var reader = WireReader(Data(bytes))
            _ = try FileTransferMessage.parse(&reader)
        }
        // Too long and too short: with the length unusable there is no stepping over it.
        #expect(throws: WireError.self) { try parse([0x22, 0, 0x7f, 0xff, 0xff, 0xff]) }
        #expect(throws: WireError.self) { try parse([0x22, 0, 0, 0, 0, 4, 0, 1, 0, 104]) }
    }

    @Test func aBodyThatDoesNotParseCostsOnlyItsTransfer() throws {
        func parse(_ bytes: [UInt8]) throws -> FileTransferMessage {
            var reader = WireReader(Data(bytes))
            let message = try FileTransferMessage.parse(&reader)
            #expect(reader.isAtEnd)
            return message
        }
        // A future version, a piece of data over 64 KiB, a summary cut short, an item of an unknown kind.
        let version = try parse([0x22, 0, 0, 0, 0, 12, 0, 2, 0, 104, 0, 0, 0, 1, 0, 0, 0, 0])
        #expect(version == FileTransferMessage(transferID: 1, body: .unusable(command: 104, reason: "file transfer version 2")))
        var big: [UInt8] = [0x22, 0, 0, 1, 0, 12, 0, 1, 0, 102, 0, 0, 0, 1, 0, 1, 0, 1]
        big += [UInt8](repeating: 0, count: 65536)
        #expect(try parse(big) == FileTransferMessage(transferID: 1, body: .unusable(command: 102, reason: "file data piece of 65537 bytes")))
        guard case .unusable(100, _) = try parse([0x22, 0, 0, 0, 0, 12, 0, 1, 0, 100, 0, 0, 0, 3, 0, 0, 0, 1]).body else {
            Issue.record("a short summary should be unusable")
            return
        }
        var item = FileTransferMessage(transferID: 4, body: Self.item("odd", depth: 0)).encoded()
        item[14] = 9
        #expect(try parse(Array(item)) == FileTransferMessage(transferID: 4, body: .unusable(command: 101, reason: "file transfer item of kind 9")))

        var buffer = InboundBuffer()
        buffer.append(item + Data([0x02]))
        var parser = ServerMessageParser()
        guard case .fileTransfer(let message) = try parser.next(from: &buffer) else {
            Issue.record("expected the transfer message")
            return
        }
        #expect(try parser.next(from: &buffer) == .bell)
        var receiver = FileTransferReceiver()
        #expect(throws: FileTransferError.malformed("command 101: file transfer item of kind 9")) { try receiver.receive(message.body) }
    }

    // MARK: Links, names, stopping, compression

    @Test func aDownloadedFolderKeepsItsLinks() throws {
        // `linkdir` on a Mac: target.txt, sub/, and links rel → target.txt, abs → /etc/hosts and
        // esc → ../../../etc. Recorded with this client; each message is re-encoded from what it
        // parsed, which the round-trip test above shows is byte for byte.
        let messages = try Self.messages(try Self.fixture("download-folder-with-links"))
        let steps = try Self.steps(messages)
        guard case .summary(let summary) = steps.first else {
            Issue.record("no summary")
            return
        }
        // The links' targets count as their size: 5 + 10 + 10 + 12.
        #expect(summary.totalBytes == 37 && summary.fileCount == 4)
        var links: [String: String] = [:]
        var refused: [String: String] = [:]
        for step in steps {
            switch step {
            case .symbolicLink(let path, let target, let item):
                #expect(item.mode == 0o120755 && item.dataSize == UInt64(target.utf8.count))
                links[path.joined(separator: "/")] = target
            case .refusedLink(let path, let target, _):
                refused[path.joined(separator: "/")] = target
            default:
                break
            }
        }
        #expect(links == ["rel": "target.txt"])
        #expect(refused == ["abs": "/etc/hosts", "esc": "../../../etc"])
        #expect(steps.last == .finished)
    }

    @Test(arguments: [
        ("a", [String](), true), ("sub/a", [], true), ("./a", [], true), ("..", ["x"], true), ("../b/c", ["x", "y"], true),
        ("", [], false), ("/etc", ["x"], false), ("..", [], false), ("../..", ["x"], false),
        // `..` after another component could pass through a link; it is refused whatever the text says.
        ("a/../b", ["x"], false), ("a/..", ["x"], false),
    ])
    func linkTargetsMustStayInside(_ target: String, _ directory: [String], _ inside: Bool) {
        #expect(FileTransferReceiver.staysInside(target: target, from: directory) == inside)
    }

    @Test func aLinkAtTheTopIsRefused() throws {
        var receiver = FileTransferReceiver()
        let link = FileTransferItem(kind: .symbolicLink, name: "l", depth: 0, mode: 0o120755, dataSize: 1, symbolicLinkTarget: "a")
        #expect(try receiver.receive(.item(link)) == [.refusedLink(path: [], target: "a", item: link)])
    }

    @Test func colonsAndSlashesSwapOnTheWire() throws {
        // macOS 27 sends a file called `a:b` as `a/b`, and saves an upload named `x/y.txt` on the
        // wire as `x:y.txt`, reporting it back as `x/y.txt`.
        let item = FileTransferItem(kind: .file, name: "a:b", depth: 0, mode: 0o100644)
        let encoded = FileTransferMessage(transferID: 1, body: .item(item)).encoded()
        #expect(encoded.range(of: Data("a/b".utf8)) != nil)
        var reader = WireReader(encoded)
        #expect(try FileTransferMessage.parse(&reader).body == .item(item))
        let received = FileTransferMessage(transferID: 1, body: .received(name: "x:y.txt", status: 0)).encoded()
        #expect(received.range(of: Data("x/y.txt".utf8)) != nil)
        reader = WireReader(received)
        #expect(try FileTransferMessage.parse(&reader).body == .received(name: "x:y.txt", status: 0))
    }

    @Test func stopIsTheBareCommand() {
        #expect(FileTransferMessage(transferID: 7, body: .stop).encoded() == Data(hex: "22 00 00000008 0001 0005 00000007"))
    }

    @Test func anEndWithAStatusAbortsTheTransfer() throws {
        // The status is a Carbon error in the sender's byte order, little-endian. macOS 27 ends a
        // fetch of a file it cannot read (/etc/sudoers) with -5000 after the item.
        var reader = WireReader(Data(hex: "22 00 0000000c 0001 0068 00000003 78ecffff"))
        let message = try FileTransferMessage.parse(&reader)
        #expect(message.body == .aborted(status: -5000))
        #expect(message.encoded() == Data(hex: "22 00 0000000c 0001 0068 00000003 78ecffff"))
        var receiver = FileTransferReceiver()
        _ = try receiver.receive(Self.item("sudoers", depth: 0, size: 1709))
        #expect(throws: FileTransferError.aborted(status: -5000)) { try receiver.receive(message.body) }
        #expect(receiver.isFinished)
        // A missing path: -43 and nothing before it.
        reader = WireReader(Data(hex: "22 00 0000000c 0001 0068 00000003 d5ffffff"))
        receiver = FileTransferReceiver()
        #expect(throws: FileTransferError.notFound) { try receiver.receive(try FileTransferMessage.parse(&reader).body) }
    }

    @Test func compressedPiecesShareOneStream() throws {
        let first = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 / 13) })
        let second = first
        let chunks = CompressionTests.deflateStream([first, second])
        let bodies: [FileTransferMessage.Body] = [
            .compressedData(chunks[0], uncompressedLength: first.count),
            .data(Data("plain".utf8)),
            .compressedData(chunks[1], uncompressedLength: second.count),
        ]
        let inflater = FileTransferInflater()
        var expanded: [FileTransferMessage.Body] = []
        for body in bodies {
            let encoded = FileTransferMessage(transferID: 1, body: body).encoded()
            // Compression type 1, zlib, follows the transfer id.
            if case .compressedData = body { #expect(encoded[14 ..< 16] == Data([0, 1])) }
            var reader = WireReader(encoded)
            expanded.append(try inflater.expand(try FileTransferMessage.parse(&reader).body))
        }
        #expect(expanded == [.data(first), .data(Data("plain".utf8)), .data(second)])
        #expect(throws: FileTransferError.self) {
            _ = try FileTransferInflater().expand(.compressedData(chunks[1], uncompressedLength: 10))
        }
    }

    @Test func unknownCompressionIsUnusable() throws {
        var reader = WireReader(Data(hex: "22 00 00000012 0001 0067 00000001 0002 00000001 00000000"))
        #expect(try FileTransferMessage.parse(&reader).body == .unusable(command: 103, reason: "compression type 2"))
    }

    @Test func progressIsADouble() throws {
        let message = FileTransferMessage(transferID: 2, body: .progress(0.25))
        #expect(message.encoded() == Data(hex: "22 00 00000010 0001 012c 00000002 3fd0000000000000"))
        var reader = WireReader(message.encoded())
        #expect(try FileTransferMessage.parse(&reader) == message)
        var receiver = FileTransferReceiver()
        #expect(try receiver.receive(.progress(0.5)).isEmpty)
    }
}
