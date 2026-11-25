// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ImageIO
public import RemoteDesktopCore

/// Translates clipboard contents between this device's pasteboard and a Mac's.
///
/// A Mac names some types the way its pasteboard did before uniform type identifiers
/// ("NSStringPboardType"), some by MIME type, and many with private or dynamic names this device
/// cannot use. Coming in, the types an app here can paste are given their standard identifiers,
/// UTF-16 text becomes UTF-8, and an image the Mac offers only as TIFF or BMP gets a PNG, which
/// every app reads. Going out, the rich forms of what was copied here travel along with the text.
///
/// The type list follows rootshell-vnc's `ClipboardType` (MIT, `RFBProtocol/Types/ClipboardContent.swift`),
/// with URLs added.
public enum ClipboardConversion {
    public static let utf8Text = "public.utf8-plain-text"
    public static let utf16Text = "public.utf16-plain-text"
    public static let rtf = "public.rtf"
    public static let flatRTFD = "com.apple.flat-rtfd"
    public static let html = "public.html"
    public static let url = "public.url"
    public static let png = "public.png"
    public static let jpeg = "public.jpeg"
    public static let tiff = "public.tiff"
    public static let gif = "com.compuserve.gif"
    public static let heic = "public.heic"
    public static let bmp = "com.microsoft.bmp"

    /// What this device sends of what was copied here, besides plain text.
    public static let outgoingTypes: Set<String> = [utf8Text, rtf, flatRTFD, html, url, png, jpeg, tiff, gif, heic]

    /// Images every app is expected to read directly.
    static let commonImages: Set<String> = [png, jpeg, gif, heic]

    /// A decoded image larger than this is not converted: a PNG of it would not be worth the memory.
    static let maximumConvertedPixels = 64 << 20

    /// The standard identifier for a pasteboard type, MIME type or legacy pasteboard name, or `nil`
    /// for a type that is not carried over.
    public static func canonical(_ name: String) -> String? {
        switch name {
        case utf8Text, "public.plain-text", "NSStringPboardType", "text/plain", "text/plain;charset=utf-8":
            utf8Text
        case utf16Text, "public.utf16-external-plain-text":
            utf16Text
        case rtf, "text/rtf", "application/rtf", "NeXT Rich Text Format v1.0 pasteboard type":
            rtf
        case flatRTFD, "NeXT RTFD pasteboard type":
            flatRTFD
        case html, "text/html", "Apple HTML pasteboard type":
            html
        case url, "Apple URL pasteboard type", "text/uri-list":
            url
        case png, "image/png", "Apple PNG pasteboard type":
            png
        case jpeg, "image/jpeg":
            jpeg
        case tiff, "image/tiff", "NeXT TIFF v4.0 pasteboard type":
            tiff
        case gif, "image/gif":
            gif
        case heic, "image/heic":
            heic
        case bmp, "image/bmp":
            bmp
        default:
            nil
        }
    }

    /// What arrived from the remote computer, in the types this device uses. Items left with
    /// nothing usable are dropped. Converting an image is CPU-bound: call this off the main actor.
    public static func incoming(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.compactMap { item in
            var representations: [String: Data] = [:]
            // Standard names first, so that a legacy duplicate never replaces the real thing.
            let standardFirst = item.representations.filter { canonical($0.key) == $0.key }
                + item.representations.filter { canonical($0.key) != $0.key }
            for (name, data) in standardFirst {
                guard let type = canonical(name), representations[type] == nil else { continue }
                representations[type] = data
            }
            if let utf16 = representations.removeValue(forKey: utf16Text), representations[utf8Text] == nil,
               let text = decodeUTF16(utf16) {
                representations[utf8Text] = Data(text.utf8)
            }
            let types = Set(representations.keys)
            if types.isDisjoint(with: commonImages), let source = representations[tiff] ?? representations[bmp],
               let converted = pngData(from: source) {
                representations[png] = converted
            }
            // Nothing on this device reads BMP; the PNG stands in for it.
            representations[bmp] = nil
            return representations.isEmpty ? nil : ClipboardItem(representations: representations)
        }
    }

    /// One item of this device's pasteboard, as the platform hands it over (type identifier to
    /// `Data`, `String` or `URL`), in the types sent to the remote computer. Images must already be
    /// encoded as data. A URL also travels as text, which is what most Mac apps paste.
    public static func outgoing(_ item: [String: Any]) -> ClipboardItem? {
        var representations: [String: Data] = [:]
        for (name, value) in item {
            guard let type = canonical(name) else { continue }
            let data: Data? = switch value {
            case let data as Data: data
            case let text as String: Data(text.utf8)
            case let url as URL: Data(url.absoluteString.utf8)
            default: nil
            }
            guard let data, !data.isEmpty else { continue }
            if type == utf16Text {
                if representations[utf8Text] == nil, let text = value as? String ?? decodeUTF16(data) {
                    representations[utf8Text] = Data(text.utf8)
                }
            } else if outgoingTypes.contains(type) {
                representations[type] = data
            }
        }
        if representations[utf8Text] == nil, let link = representations[url] {
            representations[utf8Text] = link
        }
        return representations.isEmpty ? nil : ClipboardItem(representations: representations)
    }

    /// UTF-16 text in either byte order, with or without a byte-order mark. Without one, a Mac's
    /// own order is assumed, which is little-endian on every current Mac.
    static func decodeUTF16(_ data: Data) -> String? {
        guard data.count % 2 == 0 else { return nil }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        return String(data: data, encoding: .utf16LittleEndian)
    }

    static func pngData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumConvertedPixels / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, png as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
