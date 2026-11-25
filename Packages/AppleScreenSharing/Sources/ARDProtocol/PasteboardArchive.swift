// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
public import RemoteDesktopCore
import UniformTypeIdentifiers

/// Why a pasteboard could not be sent.
public enum PasteboardError: LocalizedError, Sendable, Equatable {
    /// Even its text alone compresses to more than a Mac is sent.
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "The clipboard is too large to send to the Mac.", bundle: #bundle)
        }
    }
}

/// The format pasteboard contents travel in: a run of items, each a count of flavors, each flavor a
/// counted name (a uniform type identifier), a reserved word, a count of key/value tags, and
/// counted data. Every count is a big-endian 32-bit integer. The whole archive is zlib-compressed.
public enum PasteboardArchive {
    /// Flavors larger than this are skipped when reading: a copied image can run to many megabytes.
    public static let maximumFlavorSize = 64 << 20
    static let maximumName = 1024
    static let maximumItems = 4096
    /// The most compressed archive Apple's viewer sends (rootshell 8834c77: "Apple's viewer refuses
    /// to send more"). Beyond it, flavors other than text are left out, largest first.
    public static let maximumSentLength = 7 << 20
    /// Flavors that are never left out to make a pasteboard fit.
    static let textFlavors: Set<String> = [
        "public.utf8-plain-text", "public.utf16-plain-text", "public.utf16-external-plain-text", "public.plain-text",
        "NSStringPboardType",
    ]

    /// Encodes items. An empty array produces the archive that clears the Mac's pasteboard.
    public static func encode(_ items: [ClipboardItem]) -> Data {
        var writer = WireWriter(capacity: 256)
        let usable = items.filter { !$0.representations.isEmpty }
        guard !usable.isEmpty else {
            // One item with no flavors. (A flavor with no data would instead be taken as a promise.)
            writer.u32(0)
            return writer.data
        }
        for item in usable {
            // A flavor with no data is a promise to supply it later, which this client never makes.
            let flavors = item.representations.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
            writer.u32(UInt32(flavors.count))
            for (name, data) in flavors {
                writer.u32(UInt32(name.utf8.count))
                writer.bytes(name.utf8)
                writer.u32(0) // reserved
                writer.u32(0) // tags
                writer.u32(UInt32(data.count))
                writer.bytes(data)
            }
        }
        return writer.data
    }

    /// Decodes an inflated archive. Flavors without data (promises) are left out.
    public static func decode(_ archive: Data) throws(WireError) -> [ClipboardItem] {
        var reader = WireReader(archive)
        var items: [ClipboardItem] = []
        while !reader.isAtEnd {
            guard items.count < maximumItems else { throw .malformed("pasteboard archive has too many items") }
            let flavorCount = Int(try reader.u32())
            // Every flavor takes at least sixteen bytes, which bounds a hostile count.
            guard flavorCount <= reader.remaining / 16 + 1 else { throw .malformed("pasteboard item claims \(flavorCount) flavors") }
            var representations: [String: Data] = [:]
            for _ in 0..<flavorCount {
                let nameLength = Int(try reader.u32())
                guard nameLength <= maximumName else { throw .malformed("pasteboard flavor name of \(nameLength) bytes") }
                var name = String(decoding: try reader.take(nameLength), as: UTF8.self)
                try reader.skip(4)
                let tagCount = Int(try reader.u32())
                guard tagCount <= reader.remaining / 8 + 1 else { throw .malformed("pasteboard flavor claims \(tagCount) tags") }
                for _ in 0..<tagCount {
                    let tagClass = try reader.take(min(Int(try reader.u32()), maximumName + 1))
                    let tag = try reader.take(Int(try reader.u32()))
                    // A dynamic type arrives with no name, only its tags (a MIME type, say); several
                    // in one item would otherwise overwrite one another under "".
                    if name.isEmpty, let type = Self.type(tag: tag, tagClass: tagClass) { name = type }
                }
                let dataLength = Int(try reader.u32())
                if dataLength > 0, dataLength <= maximumFlavorSize, !name.isEmpty, representations[name] == nil {
                    representations[name] = try reader.take(dataLength)
                } else {
                    try reader.skip(dataLength)
                }
            }
            if !representations.isEmpty {
                items.append(ClipboardItem(representations: representations))
            }
        }
        return items
    }

    /// The type a tag stands for, as the system derives it (`dyn.…` when it knows none).
    static func type(tag: Data, tagClass: Data) -> String? {
        guard let tag = String(data: tag, encoding: .utf8), !tag.isEmpty,
              let tagClass = String(data: tagClass, encoding: .utf8), !tagClass.isEmpty
        else { return nil }
        return UTType(tag: tag, tagClass: UTTagClass(rawValue: tagClass), conformingTo: nil)?.identifier
    }

    /// Everything an archive holds, promises and tags included, one line per flavor: for diagnostics.
    public static func describe(_ data: PasteboardData) -> String {
        var lines = ["pasteboard: token \(data.token), \(data.isPromisesOnly ? "promises only, " : "")\(data.uncompressedLength) bytes inflated, \(data.compressed.count) sent"]
        guard data.uncompressedLength > 0,
              let inflated = try? InflateStream.inflateWhole(data.compressed, limit: Int(data.uncompressedLength))
        else { return lines.joined(separator: "\n") }
        var reader = WireReader(inflated)
        var item = 0
        func hex(_ data: Data) -> String { data.prefix(32).map { String(format: "%02x", $0) }.joined() }
        func text(_ data: Data) -> String { String(decoding: data.prefix(80), as: UTF8.self).replacingOccurrences(of: "\n", with: "⏎") }
        do {
            while !reader.isAtEnd {
                let flavors = Int(try reader.u32())
                lines.append("  item \(item): \(flavors) flavors")
                for _ in 0..<min(flavors, 200) {
                    let name = String(decoding: try reader.take(Int(try reader.u32())), as: UTF8.self)
                    let reserved = try reader.u32()
                    let tagCount = Int(try reader.u32())
                    var tags: [String] = []
                    for _ in 0..<min(tagCount, 50) {
                        let key = try reader.take(Int(try reader.u32()))
                        let value = try reader.take(Int(try reader.u32()))
                        tags.append("\(text(key))=\(hex(value))")
                    }
                    let length = Int(try reader.u32())
                    let body = try reader.take(length)
                    lines.append("    \(name) reserved \(reserved) tags [\(tags.joined(separator: ", "))] data \(length) \(hex(body)) “\(text(body))”")
                }
                item += 1
            }
        } catch {
            lines.append("  (stopped: \(error))")
        }
        return lines.joined(separator: "\n")
    }

    /// The complete message that puts `items` on the Mac's pasteboard.
    ///
    /// Kept to ``maximumSentLength`` compressed, as Apple's viewer keeps it: flavors other than text
    /// are left out, largest first, until it fits. Text is never left out; text that does not fit
    /// alone is ``PasteboardError/tooLarge``.
    public static func message(_ items: [ClipboardItem], token: UInt32 = 0) throws(PasteboardError) -> Data {
        var items = items
        var archive = encode(items)
        var compressed = Deflate.compressSyncFlushed(archive)
        while compressed.count > maximumSentLength {
            let candidates = items.indices.flatMap { index in
                items[index].representations.filter { !textFlavors.contains($0.key) }.map { (index: index, name: $0.key, size: $0.value.count) }
            }
            guard let largest = candidates.max(by: { $0.size < $1.size }) else { throw .tooLarge }
            items[largest.index].representations[largest.name] = nil
            // Nothing left would clear the Mac's pasteboard, which is not what was copied either.
            guard items.contains(where: { !$0.representations.isEmpty }) else { throw .tooLarge }
            archive = encode(items)
            compressed = Deflate.compressSyncFlushed(archive)
        }
        var writer = WireWriter(capacity: 16 + compressed.count)
        writer.u8(ClientMessageType.pasteboardData)
        writer.zeros(3)
        writer.u32(token)
        writer.u32(UInt32(archive.count))
        writer.u32(UInt32(compressed.count))
        writer.bytes(compressed)
        return writer.data
    }

    /// Inflates and decodes what a Mac sent.
    public static func items(from data: PasteboardData) throws(WireError) -> [ClipboardItem] {
        // An empty pasteboard arrives as a zero length with a few bytes of empty zlib stream.
        guard !data.isPromisesOnly, data.uncompressedLength > 0 else { return [] }
        let inflated: Data
        do {
            inflated = try InflateStream.inflateWhole(data.compressed, limit: Int(data.uncompressedLength))
        } catch {
            throw .malformed("pasteboard archive: \(error)")
        }
        guard inflated.count == Int(data.uncompressedLength) else {
            throw .malformed("pasteboard archive inflated to \(inflated.count) of \(data.uncompressedLength) bytes")
        }
        return try decode(inflated)
    }
}
