// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
import ARDTestSupport
import Foundation
import RemoteDesktopCore
import Testing

@Suite struct KeysymTests {
    private func keysym(_ key: KeyCode?, _ characters: String? = nil, ignoring: String? = nil, _ modifiers: KeyModifiers = []) -> UInt32? {
        Keysym.forEvent(KeyEvent(key: key, characters: characters, charactersIgnoringModifiers: ignoring, modifiers: modifiers, phase: .down))
    }

    @Test func namedKeysWinOverCharacters() {
        #expect(keysym(.returnOrEnter, "\r") == 0xff0d)
        #expect(keysym(.escape, "\u{1b}") == 0xff1b)
        #expect(keysym(.deleteBackward, "\u{7f}") == 0xff08)
        #expect(keysym(.deleteForward) == 0xffff)
        #expect(keysym(.tab, "\t") == 0xff09)
        #expect(keysym(.space, " ") == 0x20)
        #expect([KeyCode.leftArrow, .upArrow, .rightArrow, .downArrow].map { keysym($0) } == [0xff51, 0xff52, 0xff53, 0xff54])
        #expect([KeyCode.home, .end, .pageUp, .pageDown].map { keysym($0) } == [0xff50, 0xff57, 0xff55, 0xff56])
        #expect(keysym(.f1) == 0xffbe)
        #expect(keysym(.f12) == 0xffc9)
        #expect(keysym(.f13) == 0xffca)
        #expect(keysym(.keypad0) == 0xffb0)
        #expect(keysym(.keypad9) == 0xffb9)
    }

    @Test func modifiersUseTheKeysymsAMacMapsToItsOwnKeys() {
        // Option must go as Meta and Command as Super: a by-the-book Alt would arrive as Command.
        #expect(keysym(.leftOption) == 0xffe7)
        #expect(keysym(.rightOption) == 0xffe8)
        #expect(keysym(.leftCommand) == 0xffeb)
        #expect(keysym(.rightCommand) == 0xffec)
        #expect(keysym(.leftControl) == 0xffe3)
        #expect(keysym(.rightShift) == 0xffe2)
    }

    @Test func typedCharactersMapDirectly() {
        #expect(keysym(.a, "a") == 0x61)
        #expect(keysym(.a, "A", ignoring: "a", .leftShift) == 0x41)
        #expect(keysym(.e, "é", ignoring: "e", .leftOption) == 0xe9)
        #expect(keysym(.digit2, "€", ignoring: "2", [.leftOption, .leftShift]) == 0x0100_20AC)
        #expect(keysym(nil, "ß") == 0xdf)
        #expect(keysym(nil, "あ") == 0x0100_3042)
        // A Mac drops keysyms beyond U+FFFF; such a character goes as text, as two surrogates
        // (`X11Keysym.keysyms(for:style:)`), never as one key.
        #expect(keysym(nil, "😀") == nil)
    }

    @Test func shortcutsSendTheLetterWhoseCaseMatchesShift() {
        // Under Caps Lock the layout types "Z", but Command-Z must not arrive as Command-Shift-Z.
        #expect(keysym(.z, "Z", ignoring: "Z", [.leftCommand, .capsLock]) == 0x7a)
        #expect(keysym(.z, "z", ignoring: "z", [.leftCommand, .leftShift]) == 0x5a)
        #expect(keysym(.c, "\u{03}", ignoring: "c", .leftControl) == 0x63)
        #expect(keysym(.s, "ß", ignoring: "s", [.leftOption, .leftCommand]) == 0x73)
        #expect(keysym(.digit1, "1", ignoring: "1", .rightCommand) == 0x31)
    }

    @Test func fallsBackToUSLayoutWithoutCharacters() {
        #expect(keysym(.q) == 0x71)
        #expect(keysym(.q, nil, ignoring: nil, .leftShift) == 0x51)
        #expect(keysym(.q, nil, ignoring: nil, .capsLock) == 0x51)
        #expect(keysym(.q, nil, ignoring: nil, [.capsLock, .leftShift]) == 0x71)
        #expect(keysym(.digit5, nil, ignoring: nil, .leftShift) == 0x25)
        #expect(keysym(.digit5, nil, ignoring: nil, .capsLock) == 0x35)
        #expect(keysym(.slash, nil, ignoring: nil, [.leftCommand, .leftShift]) == 0x3f)
        #expect(keysym(.function) == nil)
        #expect(keysym(nil) == nil)
    }

    @Test func buttonMaskUsesAppleNumbering() {
        #expect(AppleButtonMask.encode([]) == 0)
        #expect(AppleButtonMask.encode(.primary) == 0x01)
        // RFB would put the right button in bit 2; a Mac on this revision reads bit 1.
        #expect(AppleButtonMask.encode(.secondary) == 0x02)
        #expect(AppleButtonMask.encode(.middle) == 0x04)
        #expect(AppleButtonMask.encode([.primary, .secondary, .back]) == 0x03)
    }
}

@Suite struct CursorCacheTests {
    /// A 2 × 2 shape: BGRX pixels, then the separate alpha plane.
    private let raw = Data([
        255, 0, 0, 99, 0, 255, 0, 99, 0, 0, 255, 99, 200, 100, 50, 99,
        255, 128, 0, 255,
    ])

    @Test func storesThenSelects() throws {
        var cache = CursorCache()
        let stored = cache.apply(cacheID: 7, hotspotX: 1, hotspotY: 0, width: 2, height: 2, deflated: Deflate.compress(raw))
        guard case .shape(let image) = stored else {
            Issue.record("expected a shape")
            return
        }
        #expect(image.pixelSize == PixelSize(width: 2, height: 2))
        #expect(image.hotspot == PixelPoint(x: 1, y: 0))
        // Premultiplied by the alpha plane; the pixels' own fourth byte is ignored.
        #expect(image.bgraPixels == Data([255, 0, 0, 255, 0, 128, 0, 128, 0, 0, 0, 0, 200, 100, 50, 255]))

        #expect(cache.apply(cacheID: 7, hotspotX: 0, hotspotY: 0, width: 0, height: 0, deflated: Data()) == .shape(image))
        #expect(cache.apply(cacheID: 8, hotspotX: 0, hotspotY: 0, width: 0, height: 0, deflated: Data()) == .unchanged)
    }

    /// The Mac may store a new shape under a cache id it used before (an arrow, then a resize
    /// pointer, under one id): the new image must not pass for the old one, or a renderer that keeps
    /// a texture per image goes on drawing the old shape.
    @Test func aNewShapeUnderAnOldCacheIDIsANewImage() throws {
        var cache = CursorCache()
        guard case .shape(let first) = cache.apply(cacheID: 7, hotspotX: 0, hotspotY: 0, width: 2, height: 2, deflated: Deflate.compress(raw)) else {
            Issue.record("expected a shape")
            return
        }
        var other = raw
        other[0] = 1
        guard case .shape(let second) = cache.apply(cacheID: 7, hotspotX: 1, hotspotY: 1, width: 2, height: 2, deflated: Deflate.compress(other)) else {
            Issue.record("expected a shape")
            return
        }
        #expect(first.id != second.id)
        #expect(first != second)
        #expect(cache.apply(cacheID: 7, hotspotX: 0, hotspotY: 0, width: 0, height: 0, deflated: Data()) == .shape(second))
    }

    @Test func badShapesAreSkippedWithoutDisturbingGoodOnes() {
        var cache = CursorCache()
        let good = cache.apply(cacheID: 1, hotspotX: 0, hotspotY: 0, width: 2, height: 2, deflated: Deflate.compress(raw))
        #expect(cache.apply(cacheID: 2, hotspotX: 0, hotspotY: 0, width: 2, height: 2, deflated: Data([1, 2, 3])) == .unchanged)
        #expect(cache.apply(cacheID: 3, hotspotX: 0, hotspotY: 0, width: 3, height: 3, deflated: Deflate.compress(raw)) == .unchanged)
        #expect(cache.apply(cacheID: 4, hotspotX: 0, hotspotY: 0, width: 4000, height: 4000, deflated: Deflate.compress(raw)) == .unchanged)
        #expect(cache.apply(cacheID: 5, hotspotX: 0, hotspotY: 0, width: 0, height: 2, deflated: Deflate.compress(raw)) == .unchanged)
        #expect(cache.apply(cacheID: 1, hotspotX: 0, hotspotY: 0, width: 0, height: 0, deflated: Data()) == good)
    }

    @Test func cacheIsBounded() {
        var cache = CursorCache()
        let shape = Deflate.compress(raw)
        for id in UInt32(0)..<300 {
            _ = cache.apply(cacheID: id, hotspotX: 0, hotspotY: 0, width: 2, height: 2, deflated: shape)
            // Selecting shape 10 keeps it in use, so it outlives older and newer neighbours.
            if id > 10 { _ = cache.apply(cacheID: 10, hotspotX: 0, hotspotY: 0, width: 0, height: 0, deflated: Data()) }
        }
        #expect(cache.apply(cacheID: 0, hotspotX: 0, hotspotY: 0, width: 0, height: 0, deflated: Data()) == .unchanged)
        #expect(cache.apply(cacheID: 11, hotspotX: 0, hotspotY: 0, width: 0, height: 0, deflated: Data()) == .unchanged)
        #expect(cache.apply(cacheID: 10, hotspotX: 0, hotspotY: 0, width: 0, height: 0, deflated: Data()) != .unchanged)
        #expect(cache.apply(cacheID: 299, hotspotX: 0, hotspotY: 0, width: 0, height: 0, deflated: Data()) != .unchanged)
    }

    @Test func largeShapesStayWithinTheByteBudget() {
        // 256 × 256 shapes of 256 KiB each: a 16 MiB budget holds 64 of them, wherever they came from.
        let edge = 256
        let shape = Deflate.compress(Data(count: edge * edge * 5))
        #expect(shape.count < 2048)
        var cache = CursorCache()
        for id in UInt32(0)..<200 {
            #expect(cache.apply(cacheID: id, hotspotX: 0, hotspotY: 0, width: UInt16(edge), height: UInt16(edge), deflated: shape) != .unchanged)
        }
        let kept = (UInt32(0)..<200).filter { cache.apply(cacheID: $0, hotspotX: 0, hotspotY: 0, width: 0, height: 0, deflated: Data()) != .unchanged }
        #expect(kept == Array(136..<200))
        let large = Deflate.compress(Data(count: 257 * 257 * 5))
        #expect(cache.apply(cacheID: 999, hotspotX: 0, hotspotY: 0, width: 257, height: 257, deflated: large) == .unchanged)
    }
}

@Suite struct PasteboardArchiveTests {
    @Test func textRoundTrip() throws {
        let items = [ClipboardItem(text: "héllo wörld")]
        let archive = PasteboardArchive.encode(items)
        // One item, one flavor: name, reserved, no tags, data.
        #expect(archive.prefix(8).hex == "00000001" + "00000016")
        #expect(try PasteboardArchive.decode(archive) == items)
    }

    @Test func emptyClearsWithAnItemOfNoFlavors() throws {
        #expect(PasteboardArchive.encode([]) == Data([0, 0, 0, 0]))
        #expect(PasteboardArchive.encode([ClipboardItem(representations: [:])]) == Data([0, 0, 0, 0]))
        #expect(try PasteboardArchive.decode(Data([0, 0, 0, 0])).isEmpty)
        #expect(try PasteboardArchive.decode(Data()).isEmpty)
    }

    @Test func multipleItemsAndFlavorsWithTagsAndPromises() throws {
        var writer = WireWriter()
        func counted(_ text: String) {
            writer.u32(UInt32(text.utf8.count))
            writer.bytes(text.utf8)
        }
        // Item 1: text with one tag, and a promised flavor (no data).
        writer.u32(2)
        counted("public.utf8-plain-text")
        writer.u32(0)
        writer.u32(1)
        counted("key")
        counted("value")
        counted("first")
        counted("public.png")
        writer.u32(0)
        writer.u32(0)
        writer.u32(0)
        // Item 2: one binary flavor.
        writer.u32(1)
        counted("com.example.blob")
        writer.u32(0)
        writer.u32(0)
        writer.u32(3)
        writer.bytes([1, 2, 3])
        let items = try PasteboardArchive.decode(writer.data)
        #expect(items.count == 2)
        #expect(items[0].text == "first")
        #expect(items[0].representations.count == 1)
        #expect(items[1].representations == ["com.example.blob": Data([1, 2, 3])])
    }

    @Test func messageFramesACompressedArchive() throws {
        let items = [ClipboardItem(text: String(repeating: "paste ", count: 500))]
        let message = try PasteboardArchive.message(items, token: 0x0A0B_0C0D)
        var reader = WireReader(message)
        #expect(try reader.u32() == 0x1f00_0000)
        #expect(try reader.u32() == 0x0A0B_0C0D)
        let uncompressed = try reader.u32()
        let compressed = Int(try reader.u32())
        #expect(reader.remaining == compressed)
        #expect(compressed < Int(uncompressed) / 10)
        // Flushed, not ended: the stream closes on a sync marker, with no checksum trailer.
        #expect(message.suffix(4) == Data([0x00, 0x00, 0xff, 0xff]))
        let received = PasteboardData(isPromisesOnly: false, token: 0, uncompressedLength: uncompressed, compressed: try reader.take(compressed))
        #expect(try PasteboardArchive.items(from: received) == items)
    }

    @Test func hostileArchivesAreRejected() {
        #expect(throws: WireError.self) { try PasteboardArchive.decode(Data(hex: "7fffffff")) }
        #expect(throws: WireError.self) { try PasteboardArchive.decode(Data(hex: "00000001 7fffffff")) }
        #expect(throws: WireError.self) { try PasteboardArchive.decode(Data(hex: "00000001 00000001 41 00000000 7fffffff")) }
        #expect(throws: WireError.self) { try PasteboardArchive.decode(Data(hex: "00000001 00000001 41 00000000 00000000 00000009 0102")) }
        let lying = PasteboardData(isPromisesOnly: false, token: 0, uncompressedLength: 4, compressed: Deflate.compress(Data(count: 4000)))
        #expect(throws: WireError.self) { try PasteboardArchive.items(from: lying) }
        // What a Mac sends for an empty pasteboard: no length, and an empty flushed stream.
        let empty = PasteboardData(isPromisesOnly: false, token: 0, uncompressedLength: 0, compressed: Deflate.compressSyncFlushed(Data()))
        #expect(throws: Never.self) { _ = try PasteboardArchive.items(from: empty) }
        let promises = PasteboardData(isPromisesOnly: true, token: 0, uncompressedLength: 0, compressed: Data())
        #expect(throws: Never.self) { _ = try PasteboardArchive.items(from: promises) }
    }

    @Test func dynamicTypesAreKeyedByTheirTag() throws {
        var writer = WireWriter()
        func counted(_ text: String) {
            writer.u32(UInt32(text.utf8.count))
            writer.bytes(text.utf8)
        }
        // One item with two nameless flavors told apart only by their MIME tags, and a named one.
        writer.u32(3)
        for (mime, byte) in [("image/png", UInt8(1)), ("text/x-made-up", 2)] {
            counted("")
            writer.u32(0)
            writer.u32(1)
            counted("public.mime-type")
            counted(mime)
            writer.u32(1)
            writer.u8(byte)
        }
        counted("public.utf8-plain-text")
        writer.u32(0)
        writer.u32(0)
        counted("text")
        let representations = try #require(try PasteboardArchive.decode(writer.data).first).representations
        #expect(representations.count == 3)
        #expect(representations["public.png"] == Data([1]))
        let dynamic = try #require(representations.first { $0.key.hasPrefix("dyn.") })
        #expect(dynamic.value == Data([2]))
        #expect(representations["public.utf8-plain-text"] == Data("text".utf8))
    }

    @Test func anOversizedPasteboardKeepsItsText() throws {
        // Random bytes do not compress, so 8 MiB of them cannot go; the text and the small image can.
        var generator = SeededGenerator(seed: 11)
        let noise = Data((0..<(8 << 20)).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let items = [
            ClipboardItem(representations: ["public.utf8-plain-text": Data("caption".utf8), "public.tiff": noise, "public.png": Data(count: 100)]),
        ]
        let message = try PasteboardArchive.message(items)
        #expect(message.count <= PasteboardArchive.maximumSentLength + 16)
        var reader = WireReader(message)
        try reader.skip(8)
        let uncompressed = try reader.u32()
        let compressed = try reader.take(Int(try reader.u32()))
        let sent = try PasteboardArchive.items(from: PasteboardData(isPromisesOnly: false, token: 0, uncompressedLength: uncompressed, compressed: compressed))
        #expect(sent == [ClipboardItem(representations: ["public.utf8-plain-text": Data("caption".utf8), "public.png": Data(count: 100)])])
        // An image alone that cannot fit is refused rather than sent as an empty pasteboard.
        #expect(throws: PasteboardError.tooLarge) { try PasteboardArchive.message([ClipboardItem(representations: ["public.tiff": noise])]) }
    }

    @Test func survivesRandomMutation() throws {
        let original = PasteboardArchive.encode([ClipboardItem(representations: ["public.utf8-plain-text": Data("abc".utf8), "public.rtf": Data(count: 40)])])
        var generator = SeededGenerator(seed: 5)
        for _ in 0..<5000 {
            var mutated = original
            let index = Int.random(in: 0..<mutated.count, using: &generator)
            mutated[index] = UInt8.random(in: .min ... .max, using: &generator)
            _ = try? PasteboardArchive.decode(mutated)
        }
    }
}
