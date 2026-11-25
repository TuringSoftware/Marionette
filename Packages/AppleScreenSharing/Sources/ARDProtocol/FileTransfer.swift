// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation

// Screen Sharing's own file transfer, as recorded between Screen Sharing.app and macOS 27.0.1
// (Docs/protocol/apple-screen-sharing.md, "Native file transfer").
//
// Three message types carry it:
// - `0x20` DragPasteboard, both ways: a drag that crosses the window edge, as a pasteboard archive.
// - `0x1e` DropDestination, from the Mac: the folder a viewer's drag was dropped on.
// - `0x22` FileTransfer, both ways: one command of a transfer.
//
// A transfer is a flat list of items in pre-order (each folder before what it holds); an item's
// depth says which folder it belongs to. Each file's data fork follows its header, then its
// resource fork. Neither side acknowledges anything until the receiver names what it made.

public enum FileTransferCommand: UInt16, Sendable {
    /// Viewer: send me these paths.
    case fetch = 1
    /// Viewer: what follows goes in this folder.
    case destination = 2
    /// Viewer: stop sending this transfer. The Mac stops at once and sends nothing more for it, not
    /// even an end; pieces already on their way still arrive.
    case stop = 5
    /// Sender: totals for the whole transfer.
    case summary = 100
    /// Sender: the next file or folder.
    case item = 101
    /// Sender: a piece of the current file.
    case data = 102
    /// Sender: a piece of the current file, compressed. A sender switches to it when its own queue
    /// backs up behind a slow link (`SSFileCopySender`'s `IsBufferWorthCompressing`).
    case compressedData = 103
    /// Sender: nothing more follows.
    case end = 104
    /// Receiver (seen from the Mac): how the transfer went, and the name the top item was saved
    /// under (renamed if the name was taken).
    case received = 200
    /// Receiver: how far an upload has got, as a fraction.
    case progress = 300
}

/// Totals sent before the items, which the receiver shows as progress.
public struct FileTransferSummary: Sendable, Equatable {
    /// 1 when the transfer is a single file, 0 when it holds a folder.
    public var singleFile: UInt32
    /// Data and resource forks together.
    public var totalBytes: UInt64
    /// The space the items take on the sender's disk.
    public var allocatedBytes: UInt64
    public var fileCount: UInt64
    public var folderCount: UInt64

    public init(singleFile: UInt32, totalBytes: UInt64, allocatedBytes: UInt64, fileCount: UInt64, folderCount: UInt64) {
        self.singleFile = singleFile
        self.totalBytes = totalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.folderCount = folderCount
    }
}

/// A date as Carbon's `UTCDateTime`: seconds since 1904-01-01 UTC in 48 bits and 1/65536ths.
public struct FileTransferDate: Sendable, Equatable {
    public var seconds: UInt64
    public var fraction: UInt16

    public init(seconds: UInt64, fraction: UInt16) {
        self.seconds = seconds
        self.fraction = fraction
    }

    public static let zero = FileTransferDate(seconds: 0, fraction: 0)
    static let epochOffset: Double = 2_082_844_800

    public init(_ date: Date) {
        let since1904 = max(0, date.timeIntervalSince1970 + Self.epochOffset)
        seconds = UInt64(since1904)
        fraction = UInt16(min(65535, (since1904 - Double(UInt64(since1904))) * 65536))
    }

    /// Nil for the zero date, which means "never".
    public var date: Date? {
        guard self != .zero else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) - Self.epochOffset + Double(fraction) / 65536)
    }

    func write(to writer: inout WireWriter) {
        writer.u16(UInt16(truncatingIfNeeded: seconds >> 32))
        writer.u32(UInt32(truncatingIfNeeded: seconds))
        writer.u16(fraction)
    }

    static func read(_ reader: inout WireReader) throws(WireError) -> FileTransferDate {
        let high = UInt64(try reader.u16())
        let low = UInt64(try reader.u32())
        return FileTransferDate(seconds: high << 32 | low, fraction: try reader.u16())
    }
}

/// One file, folder or symbolic link of a transfer.
public struct FileTransferItem: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case file = 1
        case folder = 2
        /// No data follows; the target travels in the item itself.
        case symbolicLink = 3
    }

    public var kind: Kind
    /// The classic Finder information (type, creator, flags, label), 32 bytes.
    public var finderInfo: Data
    public var resourceForkSize: UInt64
    /// For a symbolic link, the length of its target, which the summary's total counts.
    public var dataSize: UInt64
    public var created: FileTransferDate
    public var contentModified: FileTransferDate
    public var attributesModified: FileTransferDate
    public var accessed: FileTransferDate
    public var backedUp: FileTransferDate
    /// 0x10 on folders.
    public var flags: UInt16
    /// 0 for a top item; one more than its folder's for anything inside one.
    public var depth: UInt16
    /// POSIX type and permission bits, as `st_mode`.
    public var mode: UInt16
    /// The POSIX name. On the wire it is spelled as the Finder spells it, with `:` and `/` swapped
    /// (`a:b` in Terminal travels as `a/b`); ``FileTransferMessage`` swaps them both ways.
    public var name: String
    /// What a symbolic link points to, exactly as stored on the sender's disk.
    public var symbolicLinkTarget: String?

    /// Always this value in every recorded header, from either side.
    static let constant: UInt32 = 0x7e
    static let finderInfoLength = 32
    static let maximumNameLength = 1024
    /// The Mac's own limit on a link's target (`SSFileCopyReceiver`: "link path too long").
    static let maximumLinkTargetLength = 0x3ff

    public init(
        kind: Kind, name: String, depth: UInt16, mode: UInt16, dataSize: UInt64 = 0, resourceForkSize: UInt64 = 0,
        created: FileTransferDate = .zero, contentModified: FileTransferDate = .zero,
        attributesModified: FileTransferDate = .zero, accessed: FileTransferDate = .zero,
        backedUp: FileTransferDate = .zero, finderInfo: Data = Data(count: 32), flags: UInt16? = nil,
        symbolicLinkTarget: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.symbolicLinkTarget = symbolicLinkTarget
        self.depth = depth
        self.mode = mode
        self.dataSize = dataSize
        self.resourceForkSize = resourceForkSize
        self.created = created
        self.contentModified = contentModified
        self.attributesModified = attributesModified
        self.accessed = accessed
        self.backedUp = backedUp
        self.finderInfo = finderInfo
        self.flags = flags ?? (kind == .folder ? 0x10 : 0)
    }
}

/// One `FileTransfer` (`0x22`) message.
public struct FileTransferMessage: Sendable, Equatable {
    public enum Body: Sendable, Equatable {
        case fetch(path: String)
        case destination(path: String)
        case stop
        case summary(FileTransferSummary)
        case item(FileTransferItem)
        case data(Data)
        /// The next piece of the transfer's one zlib stream, sync-flushed, which inflates to
        /// `uncompressedLength` bytes of the current file. See ``FileTransferInflater``.
        case compressedData(Data, uncompressedLength: Int)
        /// The sender's end, with status 0: everything was sent.
        case end
        /// The sender's end with a non-zero status, a Carbon `OSErr`: it gave up part way. macOS 27
        /// sent -43 (`fnfErr`) for a missing path, -5000 (`afpAccessDenied`) for a file it could not
        /// read, and -1 for a folder it could not list.
        case aborted(status: Int32)
        /// `status` is 0 when the items were saved; a Mac that could not write them (a folder it may not
        /// write to) sends 5. `name` is the POSIX name, like an item's.
        case received(name: String, status: UInt16)
        /// How much of an upload the receiver has written, from 0 to 1.
        case progress(Double)
        case unknown(command: UInt16, Data)
        /// A message whose own length was intact but whose fields could not be read. Only the
        /// transfer it names is lost; the stream goes on after it. Never sent.
        case unusable(command: UInt16, reason: String)
    }

    public var transferID: UInt32
    public var body: Body

    public init(transferID: UInt32, body: Body) {
        self.transferID = transferID
        self.body = body
    }

    /// The largest piece of a file one message carries, as Apple's viewer and the Mac both send.
    public static let chunkSize = 65536
    /// A compressed piece may come out a little larger than its input: the Mac gives deflate the
    /// piece's size plus 10,006 bytes of room.
    static let maximumLength = chunkSize + 16384
    static let version: UInt16 = 1
    /// The one compression a sender uses (`SSFileCopyReceiver` refuses any other: "unknown
    /// compression type").
    static let zlibCompression: UInt16 = 1

    public var command: UInt16 {
        switch body {
        case .fetch: FileTransferCommand.fetch.rawValue
        case .destination: FileTransferCommand.destination.rawValue
        case .stop: FileTransferCommand.stop.rawValue
        case .summary: FileTransferCommand.summary.rawValue
        case .item: FileTransferCommand.item.rawValue
        case .data: FileTransferCommand.data.rawValue
        case .compressedData: FileTransferCommand.compressedData.rawValue
        case .end, .aborted: FileTransferCommand.end.rawValue
        case .received: FileTransferCommand.received.rawValue
        case .progress: FileTransferCommand.progress.rawValue
        case .unknown(let command, _), .unusable(let command, _): command
        }
    }

    /// The whole message, type byte included.
    public func encoded() -> Data {
        var fields = WireWriter(capacity: 128)
        fields.u16(Self.version)
        fields.u16(command)
        fields.u32(transferID)
        switch body {
        case .fetch(let path):
            fields.u32(1) // paths
            fields.u32(0)
            Self.writeCString(path, to: &fields)
        case .destination(let path):
            fields.u64(0)
            Self.writeCString(path, to: &fields)
        case .stop, .unusable:
            break
        case .summary(let summary):
            fields.u32(summary.singleFile)
            fields.u32(0)
            fields.u64(summary.totalBytes)
            fields.u64(summary.allocatedBytes)
            fields.u64(summary.fileCount)
            fields.u64(0)
            fields.u64(summary.folderCount)
            fields.u32(0)
        case .item(let item):
            fields.u8(item.kind.rawValue)
            fields.u8(0)
            var info = item.finderInfo.prefix(FileTransferItem.finderInfoLength)
            info.append(Data(count: FileTransferItem.finderInfoLength - info.count))
            fields.bytes(info)
            fields.u64(item.resourceForkSize)
            fields.u64(item.dataSize)
            for date in [item.created, item.contentModified, item.attributesModified, item.accessed, item.backedUp] {
                date.write(to: &fields)
            }
            fields.u16(item.flags)
            fields.u16(item.depth)
            fields.u16(item.mode)
            fields.u32(FileTransferItem.constant)
            let name = Data(Self.swapSeparators(item.name).utf8)
            let target = Data((item.symbolicLinkTarget ?? "").utf8)
            fields.u16(UInt16(name.count))
            // A link's target is `dataSize` bytes after the name's NUL; macOS 27 puts one less than
            // that here, and reads only `dataSize`.
            fields.u16(UInt16(max(target.count - 1, 0)))
            fields.bytes(name)
            fields.u8(0)
            fields.bytes(target)
        case .data(let bytes):
            fields.u32(UInt32(bytes.count))
            fields.bytes(bytes)
        case .compressedData(let bytes, let uncompressedLength):
            fields.u16(Self.zlibCompression)
            fields.u32(UInt32(uncompressedLength))
            fields.u32(UInt32(bytes.count))
            fields.bytes(bytes)
        case .end:
            fields.u32(0)
        case .aborted(let status):
            // The sender writes the status in its own byte order, which is little-endian.
            fields.u32(UInt32(bitPattern: status).byteSwapped)
        case .received(let name, let status):
            fields.u16(status)
            Self.writeCString(Self.swapSeparators(name), to: &fields)
        case .progress(let fraction):
            fields.f64(fraction)
        case .unknown(_, let bytes):
            fields.bytes(bytes)
        }
        var writer = WireWriter(capacity: fields.data.count + 6)
        writer.u8(ClientMessageType.fileTransfer)
        writer.u8(0)
        writer.u32(UInt32(fields.data.count))
        writer.bytes(fields.data)
        return writer.data
    }

    /// Reads a message, type byte included.
    ///
    /// Only a bad type or length is an error: with those intact the message can be stepped over, so
    /// fields that do not parse become ``Body/unusable(command:reason:)`` and cost only their transfer.
    public static func parse(_ reader: inout WireReader) throws(WireError) -> FileTransferMessage {
        guard try reader.u8() == ClientMessageType.fileTransfer else { throw .malformed("not a file transfer message") }
        try reader.skip(1)
        let length = Int(try reader.u32())
        guard length >= 8, length <= maximumLength else { throw .malformed("file transfer message of \(length) bytes") }
        var fields = try reader.sub(length)
        let version = try fields.u16()
        let command = try fields.u16()
        let transferID = try fields.u32()
        guard version == Self.version else {
            return FileTransferMessage(transferID: transferID, body: .unusable(command: command, reason: "file transfer version \(version)"))
        }
        do {
            return FileTransferMessage(transferID: transferID, body: try parseBody(command: command, &fields))
        } catch {
            let reason = switch error {
            case .malformed(let detail): detail
            case .truncated: "command \(command) is cut short"
            }
            return FileTransferMessage(transferID: transferID, body: .unusable(command: command, reason: reason))
        }
    }

    private static func parseBody(command: UInt16, _ fields: inout WireReader) throws(WireError) -> Body {
        switch FileTransferCommand(rawValue: command) {
        case .fetch:
            let count = try fields.u32()
            guard count == 1 else { throw .malformed("file fetch of \(count) paths") }
            try fields.skip(4)
            return .fetch(path: try readCString(&fields))
        case .destination:
            try fields.skip(8)
            return .destination(path: try readCString(&fields))
        case .stop:
            return .stop
        case .summary:
            let singleFile = try fields.u32()
            try fields.skip(4)
            let total = try fields.u64()
            let allocated = try fields.u64()
            let files = try fields.u64()
            try fields.skip(8)
            let folders = try fields.u64()
            return .summary(FileTransferSummary(singleFile: singleFile, totalBytes: total, allocatedBytes: allocated, fileCount: files, folderCount: folders))
        case .item:
            return .item(try parseItem(&fields))
        case .data:
            let count = Int(try fields.u32())
            guard count <= chunkSize else { throw .malformed("file data piece of \(count) bytes") }
            return .data(try fields.take(count))
        case .compressedData:
            let compression = try fields.u16()
            guard compression == zlibCompression else { throw .malformed("compression type \(compression)") }
            let uncompressed = Int(try fields.u32())
            let count = Int(try fields.u32())
            guard uncompressed <= chunkSize else { throw .malformed("compressed piece of \(uncompressed) bytes") }
            return .compressedData(try fields.take(count), uncompressedLength: uncompressed)
        case .end:
            // Every recorded end has the status word; one without it still ends the transfer.
            guard fields.remaining >= 4 else { return .end }
            let status = Int32(bitPattern: try fields.u32().byteSwapped)
            return status == 0 ? .end : .aborted(status: status)
        case .received:
            let status = try fields.u16()
            return .received(name: swapSeparators(try readCString(&fields)), status: status)
        case .progress:
            return .progress(try fields.f64())
        case nil:
            return .unknown(command: command, fields.rest())
        }
    }

    private static func parseItem(_ fields: inout WireReader) throws(WireError) -> FileTransferItem {
        let rawKind = try fields.u8()
        guard let kind = FileTransferItem.Kind(rawValue: rawKind) else { throw .malformed("file transfer item of kind \(rawKind)") }
        try fields.skip(1)
        let finderInfo = try fields.take(FileTransferItem.finderInfoLength)
        let resourceForkSize = try fields.u64()
        let dataSize = try fields.u64()
        let created = try FileTransferDate.read(&fields)
        let contentModified = try FileTransferDate.read(&fields)
        let attributesModified = try FileTransferDate.read(&fields)
        let accessed = try FileTransferDate.read(&fields)
        let backedUp = try FileTransferDate.read(&fields)
        let flags = try fields.u16()
        let depth = try fields.u16()
        let mode = try fields.u16()
        try fields.skip(4)
        let nameLength = Int(try fields.u16())
        guard nameLength <= FileTransferItem.maximumNameLength else { throw .malformed("file name of \(nameLength) bytes") }
        try fields.skip(2)
        let name = String(decoding: try fields.take(nameLength), as: UTF8.self)
        var target: String?
        if kind == .symbolicLink {
            guard dataSize <= FileTransferItem.maximumLinkTargetLength else { throw .malformed("link target of \(dataSize) bytes") }
            try fields.skip(1) // the name's NUL
            target = String(decoding: try fields.take(Int(dataSize)), as: UTF8.self)
        }
        return FileTransferItem(
            kind: kind, name: swapSeparators(name), depth: depth, mode: mode, dataSize: dataSize, resourceForkSize: resourceForkSize,
            created: created, contentModified: contentModified, attributesModified: attributesModified,
            accessed: accessed, backedUp: backedUp, finderInfo: finderInfo, flags: flags, symbolicLinkTarget: target
        )
    }

    /// Between a POSIX name and the Finder's spelling of it, which the wire carries: each `:`
    /// becomes `/` and each `/` becomes `:`. Its own inverse.
    static func swapSeparators(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { $0 == ":" ? "/" : $0 == "/" ? ":" : $0 }))
    }

    /// A counted string followed by a NUL the count leaves out.
    static func writeCString(_ text: String, to writer: inout WireWriter) {
        let bytes = Data(text.utf8)
        writer.u16(UInt16(bytes.count))
        writer.bytes(bytes)
        writer.u8(0)
    }

    static func readCString(_ reader: inout WireReader) throws(WireError) -> String {
        let count = Int(try reader.u16())
        guard count <= 4096 else { throw .malformed("file transfer path of \(count) bytes") }
        let text = String(decoding: try reader.take(count), as: UTF8.self)
        if reader.remaining > 0 { try reader.skip(1) }
        return text
    }
}

/// `DragPasteboard` (`0x20`): a drag crossing the window edge, in either direction. A viewer
/// announces its drag when the pointer enters the Mac's picture with it; the Mac announces one of
/// its own when the pointer leaves with it. Sixteen zero bytes after the type say the drag ended.
public struct DragPasteboard: Sendable, Equatable {
    /// Ties the Mac's `DropDestination` to the viewer's drag. The Mac uses 1 for its own drags.
    public var token: UInt32
    public var uncompressedLength: UInt32
    public var compressed: Data

    public init(token: UInt32, uncompressedLength: UInt32, compressed: Data) {
        self.token = token
        self.uncompressedLength = uncompressedLength
        self.compressed = compressed
    }

    /// Whether this says a drag is over. A viewer's has token 0; a Mac's keeps its token, 1.
    public var isEnd: Bool { uncompressedLength == 0 && compressed.isEmpty }

    public static let end = DragPasteboard(token: 0, uncompressedLength: 0, compressed: Data())

    /// A drag of local files, described as Finder describes them: one item per file, each a file URL.
    public static func files(_ urls: [URL], token: UInt32) -> DragPasteboard {
        var writer = WireWriter(capacity: 256)
        for url in urls {
            writer.u32(1) // flavors
            let name = Data("public.file-url".utf8)
            writer.u32(UInt32(name.count))
            writer.bytes(name)
            writer.u32(0)
            writer.u32(1) // tags
            let key = Data("com.apple.ostype".utf8)
            writer.u32(UInt32(key.count))
            writer.bytes(key)
            writer.u32(4)
            writer.bytes(Data("furl".utf8))
            let value = Data(url.absoluteString.utf8)
            writer.u32(UInt32(value.count))
            writer.bytes(value)
        }
        let archive = writer.data
        return DragPasteboard(token: token, uncompressedLength: UInt32(archive.count), compressed: Deflate.compressSyncFlushed(archive))
    }

    /// The file URLs a drag carries, from its archive.
    public func fileURLs() throws(WireError) -> [URL] {
        guard uncompressedLength > 0 else { return [] }
        let items = try PasteboardArchive.items(from: PasteboardData(
            isPromisesOnly: false, token: token, uncompressedLength: uncompressedLength, compressed: compressed
        ))
        return items.compactMap { item in
            item.representations["public.file-url"].flatMap { URL(string: String(decoding: $0, as: UTF8.self)) }
        }
    }

    /// What a drag from the Mac carries: the dragged files as POSIX paths, and the picture under
    /// the pointer.
    public func contents() throws(WireError) -> (paths: [String], imagePNG: Data?) {
        guard uncompressedLength > 0 else { return ([], nil) }
        let items = try PasteboardArchive.items(from: PasteboardData(
            isPromisesOnly: false, token: token, uncompressedLength: uncompressedLength, compressed: compressed
        ))
        var paths: [String] = []
        var image: Data?
        for item in items {
            if let reference = item.representations["public.file-url"],
               let url = URL(string: String(decoding: reference, as: UTF8.self)), url.isFileURL {
                paths.append(url.path)
            }
            if image == nil { image = item.representations[Self.dragImageType] }
        }
        return (paths, image)
    }

    /// The flavor a Mac puts the dragged picture in.
    public static let dragImageType = "com.apple.remotedesktop.dragimage-png"

    public func encoded() -> Data {
        var writer = WireWriter(capacity: 16 + compressed.count)
        writer.u8(ClientMessageType.dragPasteboard)
        writer.zeros(3)
        writer.u32(token)
        writer.u32(uncompressedLength)
        writer.u32(UInt32(compressed.count))
        writer.bytes(compressed)
        return writer.data
    }

    public static func parse(_ reader: inout WireReader) throws(WireError) -> DragPasteboard {
        guard try reader.u8() == ClientMessageType.dragPasteboard else { throw .malformed("not a drag message") }
        try reader.skip(3)
        let token = try reader.u32()
        let uncompressed = try reader.u32()
        let compressed = Int(try reader.u32())
        guard compressed <= ServerMessageParser.maximumPasteboardPayload,
              Int(uncompressed) <= ServerMessageParser.maximumPasteboardPayload
        else { throw .malformed("drag archive of \(compressed) bytes, \(uncompressed) inflated") }
        return DragPasteboard(token: token, uncompressedLength: uncompressed, compressed: try reader.take(compressed))
    }
}

/// `DropDestination` (`0x1e`), from the Mac: where a viewer's drag (matched by token) was dropped.
public struct DropDestination: Sendable, Equatable {
    public var token: UInt32
    public var path: String

    public init(token: UInt32, path: String) {
        self.token = token
        self.path = path
    }

    public func encoded() -> Data {
        var writer = WireWriter(capacity: 12 + path.utf8.count)
        writer.u8(ServerMessageType.dropDestination)
        writer.zeros(3)
        writer.u32(token)
        writer.u32(UInt32(path.utf8.count))
        writer.bytes(path.utf8)
        return writer.data
    }

    public static func parse(_ reader: inout WireReader) throws(WireError) -> DropDestination {
        guard try reader.u8() == ServerMessageType.dropDestination else { throw .malformed("not a drop message") }
        try reader.skip(3)
        let token = try reader.u32()
        let length = Int(try reader.u32())
        guard length <= 4096 else { throw .malformed("drop path of \(length) bytes") }
        return DropDestination(token: token, path: String(decoding: try reader.take(length), as: UTF8.self))
    }
}

/// Why an incoming transfer was refused.
public enum FileTransferError: Error, Sendable, Equatable {
    /// The Mac ended the transfer without sending anything: the path does not exist or cannot be read.
    case notFound
    /// The sender gave up part way and said so in its end, with a Carbon `OSErr`.
    case aborted(status: Int32)
    /// The sender broke the format: a bad name, an impossible depth, more data than announced.
    case malformed(String)
}

/// Follows one incoming transfer and says what to make where.
///
/// Every name comes off the wire, so it is checked before it becomes part of a path: no separators,
/// no `.` or `..`, nothing empty. Depths must follow the folders actually announced, so an item can
/// never land outside the top item. A symbolic link is made only when its target stays inside the
/// top folder (see ``staysInside(target:from:)``); others are reported and left out.
public struct FileTransferReceiver: Sendable {
    public enum Fork: Sendable, Equatable {
        case data
        case resource
    }

    public enum Step: Sendable, Equatable {
        case summary(FileTransferSummary)
        /// Make this folder. The path is relative to where the top item goes; the top item's is empty.
        case folder(path: [String], item: FileTransferItem)
        /// Start this file, which `data` steps then fill.
        case file(path: [String], item: FileTransferItem)
        /// Make this symbolic link; its target stays inside the transfer.
        case symbolicLink(path: [String], target: String, item: FileTransferItem)
        /// A symbolic link that would point outside the transfer (or is the transfer), left out.
        case refusedLink(path: [String], target: String, item: FileTransferItem)
        case data(Data, fork: Fork)
        /// The current file has all its bytes.
        case fileComplete
        case finished
    }

    struct OpenFile {
        var dataRemaining: UInt64
        var resourceRemaining: UInt64
    }

    /// Names of the folders enclosing the next item, outermost first: the top folder and below.
    private var folders: [String] = []
    private var openFile: OpenFile?
    private var sawSummary = false
    private var sawTopItem = false
    public private(set) var isFinished = false

    public init() {}

    static let maximumDepth = 256

    public mutating func receive(_ body: FileTransferMessage.Body) throws(FileTransferError) -> [Step] {
        guard !isFinished else { throw .malformed("a message after the end") }
        switch body {
        case .summary(let summary):
            guard !sawSummary, !sawTopItem else { throw .malformed("a second summary") }
            sawSummary = true
            return [.summary(summary)]
        case .item(let item):
            var steps = try closeFile()
            try Self.check(item.name)
            let depth = Int(item.depth)
            if depth == 0 {
                guard !sawTopItem else { throw .malformed("a second top item, \(item.name)") }
                sawTopItem = true
            } else {
                // Inside the top folder: its depth must name a folder already opened.
                guard sawTopItem, depth <= folders.count, depth <= Self.maximumDepth else {
                    throw .malformed("\(item.name) at depth \(depth) with \(folders.count) folders open")
                }
            }
            folders.removeSubrange(min(depth, folders.count)...)
            // The top item's own path is empty: it goes where the caller says.
            let path = depth == 0 ? [] : Array(folders.dropFirst()) + [item.name]
            switch item.kind {
            case .folder:
                folders.append(item.name)
                steps.append(.folder(path: path, item: item))
            case .file:
                // A file is not added to `folders`, so an item one level below it is refused.
                openFile = OpenFile(dataRemaining: item.dataSize, resourceRemaining: item.resourceForkSize)
                steps.append(.file(path: path, item: item))
                steps += try closeFileIfDone()
            case .symbolicLink:
                // Neither is a link added to `folders`: nothing can be put inside one.
                let target = item.symbolicLinkTarget ?? ""
                let safe = depth > 0 && Self.staysInside(target: target, from: Array(path.dropLast()))
                steps.append(safe ? .symbolicLink(path: path, target: target, item: item) : .refusedLink(path: path, target: target, item: item))
            }
            return steps
        case .data(var bytes):
            guard var file = openFile else { throw .malformed("data outside a file") }
            var steps: [Step] = []
            if file.dataRemaining > 0 {
                let take = Int(min(UInt64(bytes.count), file.dataRemaining))
                steps.append(.data(bytes.prefix(take), fork: .data))
                file.dataRemaining -= UInt64(take)
                bytes = bytes.dropFirst(take)
            }
            if !bytes.isEmpty {
                guard UInt64(bytes.count) <= file.resourceRemaining else { throw .malformed("more data than the file announced") }
                steps.append(.data(Data(bytes), fork: .resource))
                file.resourceRemaining -= UInt64(bytes.count)
            }
            openFile = file
            return steps + (try closeFileIfDone())
        case .end, .aborted:
            isFinished = true
            // A Mac answers a fetch of a path that is not there with the end alone (status -43).
            guard sawTopItem else { throw .notFound }
            if case .aborted(let status) = body { throw .aborted(status: status) }
            return try closeFile() + [.finished]
        case .progress:
            return []
        case .unusable(let command, let reason):
            throw .malformed("command \(command): \(reason)")
        case .compressedData:
            // ``FileTransferInflater`` turns these into plain data before they get here.
            throw .malformed("compressed data that was not inflated")
        case .fetch, .destination, .stop, .received, .unknown:
            throw .malformed("command \(FileTransferMessage(transferID: 0, body: body).command) inside a transfer")
        }
    }

    /// Whether a link at `directory` (folder names below the top folder) pointing at `target` resolves
    /// to somewhere inside the top folder.
    ///
    /// `..` is allowed only at the start of the target. Later in the path it would apply to whatever an
    /// earlier link component resolves to, which no reading of the text alone can check (`a/../..`
    /// escapes when `a` is itself a link to `..`). Leading ones climb real folders made by this
    /// transfer, and every link below was checked in the same way, so the result stays inside.
    static func staysInside(target: String, from directory: [String]) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0") else { return false }
        var depth = directory.count
        var climbing = true
        for component in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard climbing, depth > 0 else { return false }
                depth -= 1
            default:
                climbing = false
            }
        }
        return true
    }

    private mutating func closeFileIfDone() throws(FileTransferError) -> [Step] {
        guard let file = openFile, file.dataRemaining == 0, file.resourceRemaining == 0 else { return [] }
        openFile = nil
        return [.fileComplete]
    }

    private mutating func closeFile() throws(FileTransferError) -> [Step] {
        guard let file = openFile else { return [] }
        guard file.dataRemaining == 0, file.resourceRemaining == 0 else {
            throw .malformed("a file ended \(file.dataRemaining + file.resourceRemaining) bytes short")
        }
        openFile = nil
        return [.fileComplete]
    }

    /// A name that is safe as one path component.
    static func check(_ name: String) throws(FileTransferError) {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else {
            throw .malformed("unusable file name \(name.debugDescription)")
        }
    }
}

/// Inflates a transfer's compressed pieces (command 103).
///
/// A sender keeps one zlib stream for the whole transfer and sync-flushes it after each piece, so
/// every piece depends on those before it: one inflater per transfer, fed in order. Plain pieces may
/// come between compressed ones and do not touch the stream. Not thread-safe.
public final class FileTransferInflater {
    private var stream: InflateStream?

    public init() {}

    /// `body` with a compressed piece replaced by the data it stands for; anything else unchanged.
    public func expand(_ body: FileTransferMessage.Body) throws(FileTransferError) -> FileTransferMessage.Body {
        guard case .compressedData(let compressed, let length) = body else { return body }
        let stream = stream ?? InflateStream()
        self.stream = stream
        do {
            return .data(try stream.inflate(compressed, expecting: length))
        } catch {
            throw .malformed("compressed file data: \(error)")
        }
    }
}
