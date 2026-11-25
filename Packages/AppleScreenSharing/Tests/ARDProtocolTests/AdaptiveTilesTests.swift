// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// The hand-built streams here follow the tests of the MIT-licensed decoder in
// andrewtheguy/remotex (frontend/wasm/apple-adaptive/src/decoder.rs), © 2026 Andrew Chen.

@testable import ARDProtocol
import ARDTestSupport
import CryptoKit
import Foundation
import Testing

/// A stream written most significant bit first, padded with zeros.
private final class BitWriter {
    private var bytes: [UInt8] = []
    private var window: UInt64 = 0
    private var held: UInt32 = 0

    @discardableResult
    func put(_ value: UInt32, _ count: UInt32) -> BitWriter {
        window = window << UInt64(count) | UInt64(value) & ((1 << UInt64(count)) - 1)
        held += count
        while held >= 8 {
            held -= 8
            bytes.append(UInt8(truncatingIfNeeded: window >> UInt64(held)))
        }
        return self
    }

    @discardableResult
    func bits(_ text: String) -> BitWriter {
        for character in text where character == "0" || character == "1" { put(character == "1" ? 1 : 0, 1) }
        return self
    }

    func done() -> [UInt8] {
        if held > 0 { put(0, 8 - held) }
        defer { bytes = [] }
        return bytes
    }
}

private struct Picture {
    var decoder = AdaptiveTileDecoder()
    var pixels: [UInt32]
    let width: Int

    /// Black, with tables of ones so a coefficient is its own dequantized value.
    init(_ width: Int, _ height: Int, withTables: Bool = true) {
        self.width = width
        pixels = [UInt32](repeating: 0xff00_0000, count: width * height)
        decoder.resize(width: width, height: height)
        if withTables { _ = try! decode(0, 0, 0, 0, Picture.tables) }
    }

    static let tables: [UInt8] = [2] + [UInt8](repeating: 1, count: 128)

    @discardableResult
    mutating func decode(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ body: [UInt8]) throws(AdaptiveTileDecoder.Failure) -> Bool {
        var result: Result<Bool, AdaptiveTileDecoder.Failure> = .success(false)
        pixels.withUnsafeMutableBufferPointer { buffer in
            do throws(AdaptiveTileDecoder.Failure) {
                result = .success(try decoder.decode(body, x: x, y: y, width: w, height: h, onto: buffer))
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }

    func tile(_ x: Int, _ y: Int) -> [UInt32] {
        (0..<64).map { pixels[(y + $0 / 8) * width + x + $0 % 8] }
    }
}

private let white: UInt32 = 0xffff_ffff
private let black: UInt32 = 0xff00_0000

private func rgb(_ red: UInt32, _ green: UInt32, _ blue: UInt32) -> UInt32 {
    0xff00_0000 | red << 16 | green << 8 | blue
}

/// A full update of `commands` and `data`, each ended with its mark, at the coarse precisions a Mac starts with.
private func full(_ commands: BitWriter, _ data: BitWriter = BitWriter()) -> [UInt8] {
    commands.put(0x6d, 8)
    data.put(0x6d, 8)
    let (commandBytes, dataBytes) = (commands.done(), data.done())
    let offset = 6 + commandBytes.count
    return [0, 3, 5, UInt8(offset >> 16), UInt8(offset >> 8 & 0xff), UInt8(offset & 0xff)] + commandBytes + dataBytes
}

/// A command, after the one bit the stream starts with, covering one tile.
private func one(_ command: UInt32) -> BitWriter {
    let commands = BitWriter()
    commands.bits("0").put(command, 3).bits("0")
    return commands
}

private func partial(_ refinement: BitWriter, marked: Bool = true) -> [UInt8] {
    if marked { refinement.put(0x6d, 8).put(0x76, 8).put(0x73, 8) }
    return [1, 14, 19] + refinement.done()
}

/// A DCT tile whose Y DC is −8 and the rest nothing: a flat 127 grey through the reference transform.
private func flatTile(_ data: BitWriter) {
    // Not a repeat, the chroma sent, the first precision; both chroma DCs 0.
    data.bits("0 0 0").bits("00 00")
    // The Y DC, 0 less 8: three ones and a zero, three bits of 0, positive.
    data.bits("1110 000 0")
    // The end of the block.
    data.bits("0 01 0")
}

@Suite struct AdaptiveTileDecoderTests {
    @Test func aWhiteTileFillsTheTileAndNothingElse() throws {
        var picture = Picture(16, 8)
        #expect(try picture.decode(0, 0, 8, 8, full(one(0))))
        #expect(picture.tile(0, 0).allSatisfy { $0 == white })
        #expect(picture.tile(8, 0).allSatisfy { $0 == black })
    }

    @Test func aRepeatCoversTheTilesInRowsAndClipsTheEdges() throws {
        var picture = Picture(24, 16)
        // `1` and four bits of 3: five tiles, the rectangle's six less one, which a second command finishes.
        let commands = BitWriter()
        commands.bits("0").put(0, 3).bits("1 0011").put(0, 3).bits("0")
        try picture.decode(0, 0, 20, 12, full(commands))
        for y in 0..<16 {
            for x in 0..<24 {
                #expect(picture.pixels[y * 24 + x] == (x < 20 && y < 12 ? white : black), "\(x),\(y)")
            }
        }
    }

    @Test func aRepeatOfMoreThanSixteenIsCountedInSevenBitGroups() {
        let bits = BitWriter()
        bits.bits("0 1 0011 1 1111").put(3, 8).bits("1 1111").put(0x80 | 5, 8).put(2, 8)
        var reader = BitReader(bits.done(), at: 0)
        #expect(AdaptiveTileDecoder.tilesCovered(&reader) == 1)
        #expect(AdaptiveTileDecoder.tilesCovered(&reader) == 5)
        #expect(AdaptiveTileDecoder.tilesCovered(&reader) == 3 + 17)
        #expect(AdaptiveTileDecoder.tilesCovered(&reader) == (2 << 7 | 5) + 17)
    }

    @Test func signedNumbersCoverEveryLength() throws {
        let bits = BitWriter()
        // 0; 1; −1; 2 + 1 = 3; −(4 + 2) = −6; 8 + 5 = 13; 16 + 7 = 23, negative.
        bits.bits("0 0").bits("0 1 0").bits("0 1 1").bits("10 1 0").bits("110 10 1").bits("1110 101 0").bits("11110 111 1")
        var reader = BitReader(bits.done(), at: 0)
        var values: [Int16] = []
        for _ in 0..<7 { values.append(try AdaptiveTileDecoder.signedNumber(&reader)) }
        #expect(values == [0, 1, -1, 3, -6, 13, -23])
        // A run of ones with no end is refused rather than read for ever.
        var endless = BitReader([UInt8](repeating: 0xff, count: 16), at: 0)
        #expect(throws: AdaptiveTileDecoder.Failure.badCoefficients) { _ = try AdaptiveTileDecoder.signedNumber(&endless) }
    }

    @Test func aBlackAndWhiteTileIsARowMaskThenItsPixels() throws {
        var picture = Picture(8, 8)
        let data = BitWriter()
        // Every row but the first is white; the first is its pixel mask.
        data.put(0b0111_1111, 8).put(0b1000_0001, 8)
        try picture.decode(0, 0, 8, 8, full(one(3), data))
        let pixels = picture.tile(0, 0)
        #expect(Array(pixels[..<8]) == [white, black, black, black, black, black, black, white])
        #expect(pixels[8...].allSatisfy { $0 == white })
    }

    @Test func aColouredTileIsOneColourOrTwoAndMayTakeTheLastOnesAgain() throws {
        var picture = Picture(32, 8)
        let commands = BitWriter()
        // Four tiles of the one command: `1` and two, which is two more than that.
        commands.bits("0").put(4, 3).bits("1 0010")
        let data = BitWriter()
        // One colour: Y 76, Cb and Cr at the centre, a grey.
        data.bits("0 0").put(76, 8).put(32, 6).put(32, 6)
        // Two, red and blue: every row their mask, the first colour where it is set.
        data.bits("1 0").put(76, 8).put(21, 6).put(63, 6).put(29, 8).put(63, 6).put(26, 6)
        data.put(0, 8)
        for _ in 0..<8 { data.put(0b1111_0000, 8) }
        // The one colour again, without reading it, and the two again.
        data.bits("0 1").bits("1 1").put(0xff, 8)
        try picture.decode(0, 0, 32, 8, full(commands, data))

        let grey = AdaptiveTileDecoder.pixel(y: 76, cb: 128, cr: 128)
        #expect(grey == rgb(76, 76, 76))
        #expect(picture.tile(0, 0).allSatisfy { $0 == grey })
        let red = AdaptiveTileDecoder.pixel(y: 76, cb: 84, cr: 252)
        let blue = AdaptiveTileDecoder.pixel(y: 29, cb: 252, cr: 104)
        // Red really is red and blue blue: the channels are not swapped.
        #expect(red >> 16 & 0xff > 200 && red & 0xff < 40)
        #expect(blue & 0xff > 200 && blue >> 16 & 0xff < 40)
        #expect(Array(picture.tile(8, 0)[..<8]) == [red, red, red, red, blue, blue, blue, blue])
        #expect(picture.tile(16, 0).allSatisfy { $0 == grey })
        #expect(picture.tile(24, 0).allSatisfy { $0 == red }, "a row whose bit is set is the first colour")
    }

    @Test func twoColoursReusedBeforeAnyWereReadAreTheViewersOwn() throws {
        var picture = Picture(8, 8)
        let data = BitWriter()
        data.bits("1 1").put(0, 8)
        for _ in 0..<8 { data.put(0b1010_1010, 8) }
        try picture.decode(0, 0, 8, 8, full(one(4), data))
        #expect(Array(picture.tile(0, 0)[..<4]) == [white, rgb(254, 213, 181), white, rgb(254, 213, 181)])
    }

    @Test func copiesTakeTheTileBeforeAndTheTileAbove() throws {
        var picture = Picture(16, 16)
        let commands = BitWriter()
        // White, a copy of it to the right; then a copy from above, and black.
        commands.bits("0").put(0, 3).bits("0").put(1, 3).bits("0").put(2, 3).bits("0").put(3, 3).bits("0")
        let data = BitWriter()
        data.put(0, 8)
        for _ in 0..<8 { data.put(0, 8) }
        try picture.decode(0, 0, 16, 16, full(commands, data))
        #expect(picture.tile(8, 0).allSatisfy { $0 == white })
        #expect(picture.tile(0, 8).allSatisfy { $0 == white })
        #expect(picture.tile(8, 8).allSatisfy { $0 == black })
    }

    @Test func aDCTTileIsInvertedByTheReferenceTransform() throws {
        var picture = Picture(8, 8)
        let data = BitWriter()
        flatTile(data)
        try picture.decode(0, 0, 8, 8, full(one(5), data))
        #expect(picture.tile(0, 0).allSatisfy { $0 == rgb(127, 127, 127) })
    }

    @Test func aRefinedTileIsCachedAndDrawnAgainByItsIndex() throws {
        var picture = Picture(16, 8)
        let commands = BitWriter()
        commands.bits("0").put(5, 3).bits("0").put(0, 3).bits("0")
        let data = BitWriter()
        flatTile(data)
        try picture.decode(0, 0, 16, 8, full(commands, data))

        // Refined: one Y coefficient, the DC; each chroma DC left at 0 and its AC coefficients an end of block.
        let refinement = BitWriter()
        refinement.bits("01").put(0, 6).bits("0 1010").bits("0 1010")
        #expect(try picture.decode(0, 0, 8, 8, partial(refinement)))
        #expect(picture.tile(0, 0).allSatisfy { $0 == rgb(127, 127, 127) })
        #expect(picture.tile(8, 0).allSatisfy { $0 == white })

        // The next cached tile after none drawn yet is the first: the refined one.
        #expect(try picture.decode(8, 0, 8, 8, full(one(7))))
        #expect(picture.tile(8, 0).allSatisfy { $0 == rgb(127, 127, 127) })
        // By its index, too, and an index nothing was cached under draws nothing.
        let byIndex = BitWriter()
        byIndex.put(1, 16)
        try picture.decode(0, 0, 8, 8, full(one(0)))
        try picture.decode(0, 0, 8, 8, full(one(6), byIndex))
        #expect(picture.tile(0, 0).allSatisfy { $0 == rgb(127, 127, 127) })
        let missing = BitWriter()
        missing.put(9, 16)
        try picture.decode(0, 0, 8, 8, full(one(0)))
        try picture.decode(0, 0, 8, 8, full(one(6), missing))
        #expect(picture.tile(0, 0).allSatisfy { $0 == white })
    }

    @Test func aTileTheFullUpdateDidNotCodeCannotBeRefined() throws {
        var picture = Picture(8, 8)
        try picture.decode(0, 0, 8, 8, full(one(0)))
        let refinement = BitWriter()
        refinement.bits("01").put(0, 6).bits("0 1010").bits("0 1010")
        #expect(throws: AdaptiveTileDecoder.Failure.unrefinable) { try picture.decode(0, 0, 8, 8, partial(refinement, marked: false)) }
    }

    @Test func aPartialCopyRepeatsTheFullUpdatesCopy() throws {
        var picture = Picture(16, 8)
        let commands = BitWriter()
        commands.bits("0").put(0, 3).bits("0").put(1, 3).bits("0")
        try picture.decode(0, 0, 16, 8, full(commands))
        picture.pixels[8] = black
        picture.pixels[0] = rgb(1, 2, 3)
        let refinement = BitWriter()
        refinement.bits("00 10")
        try picture.decode(0, 0, 16, 8, partial(refinement))
        #expect(picture.pixels[8] == rgb(1, 2, 3), "copied again from where the copy came from")
    }

    @Test func whatDoesNotFitOrDoesNotEndOnItsMarkIsRefused() throws {
        var picture = Picture(8, 8, withTables: false)
        let body = full(one(0))
        #expect(throws: AdaptiveTileDecoder.Failure.noTables) { try picture.decode(0, 0, 8, 8, body) }
        #expect(!picture.decoder.hasTables)
        #expect(try picture.decode(0, 0, 0, 0, Picture.tables) == false)
        #expect(picture.decoder.hasTables)
        #expect(throws: AdaptiveTileDecoder.Failure.outOfBounds) { try picture.decode(0, 0, 16, 8, body) }
        #expect(throws: AdaptiveTileDecoder.Failure.outOfBounds) { try picture.decode(8, 0, 0, 0, body) }
        var cut = body
        cut[cut.count - 1] = 0
        #expect(throws: AdaptiveTileDecoder.Failure.missingMark(expected: 0x6d, found: 0)) { try picture.decode(0, 0, 8, 8, cut) }
        #expect(throws: AdaptiveTileDecoder.Failure.wrongTableLength(2)) { try picture.decode(0, 0, 0, 0, [2, 1]) }
        #expect(throws: AdaptiveTileDecoder.Failure.unknownKind(7)) { try picture.decode(0, 0, 8, 8, [7]) }
        #expect(throws: AdaptiveTileDecoder.Failure.tooShort(kind: 0, length: 0)) { try picture.decode(0, 0, 8, 8, []) }
        #expect(throws: AdaptiveTileDecoder.Failure.tooShort(kind: 0, length: 3)) { try picture.decode(0, 0, 8, 8, [0, 3, 5]) }
        #expect(throws: AdaptiveTileDecoder.Failure.badDataOffset(0x010000)) { try picture.decode(0, 0, 8, 8, [0, 3, 5, 1, 0, 0]) }
    }

    @Test func aStreamThatNeverEndsIsRefusedNotReadForEver() throws {
        var picture = Picture(64, 64)
        // Commands of one white tile each run out long before 64 tiles; zeros follow, which read
        // as more white tiles until the marks fail.
        #expect(throws: AdaptiveTileDecoder.Failure.self) { try picture.decode(0, 0, 64, 64, [0, 3, 5, 0, 0, 6, 0, 0]) }
        // A partial update of nothing but zeros leaves every tile alone and then lacks its marks.
        #expect(throws: AdaptiveTileDecoder.Failure.self) { try picture.decode(0, 0, 64, 64, [1, 14, 19, 0]) }
    }

    @Test func randomBodiesNeverCrashOrWriteOutsideTheFramebuffer() {
        var generator = SeededGenerator(seed: 3)
        for round in 0..<300 {
            var picture = Picture(40, 24)
            // A guard band the decoder must not touch lies outside the 40 × 24 it was told about.
            picture.pixels += [UInt32](repeating: 0x1234_5678, count: 40 * 8)
            for _ in 0..<6 {
                var body = (0..<Int.random(in: 1...400, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
                body[0] = UInt8.random(in: 0...1, using: &generator)
                if body.count > 6, body[0] == 0 {
                    body[3] = 0
                    body[4] = 0
                    body[5] = UInt8.random(in: 6...UInt8(min(body.count, 255)), using: &generator)
                }
                let x = Int.random(in: 0..<40, using: &generator), y = Int.random(in: 0..<24, using: &generator)
                _ = try? picture.decode(x, y, Int.random(in: 1...(40 - x), using: &generator), Int.random(in: 1...(24 - y), using: &generator), body)
            }
            #expect(picture.pixels[(40 * 24)...].allSatisfy { $0 == 0x1234_5678 }, "round \(round)")
        }
    }

    @Test func theReferenceTransformMatchesItsKnownOutputs() {
        let ones = InlineArray<64, Int32>(repeating: 1)
        // A DC alone is the mean, the transform's rounding on top.
        var coefficients = InlineArray<64, Int16>(repeating: 0)
        coefficients[0] = 80
        let flat = AdaptiveTileDecoder.inverseDCT(coefficients, ones)
        #expect((0..<64).allSatisfy { flat[$0] == 138 })
        // One horizontal frequency: every row the same, odd about the centre.
        coefficients = InlineArray<64, Int16>(repeating: 0)
        coefficients[1] = 100
        let wave = AdaptiveTileDecoder.inverseDCT(coefficients, ones)
        for row in 0..<8 {
            for x in 0..<8 { #expect(wave[row * 8 + x] == wave[x]) }
            for x in 0..<4 { #expect(Int(wave[row * 8 + x]) - 128 == 128 - Int(wave[row * 8 + 7 - x])) }
            #expect(wave[row * 8] > wave[row * 8 + 3] && wave[row * 8 + 3] > 128)
        }
        // Out-of-range samples saturate rather than wrap.
        coefficients = InlineArray<64, Int16>(repeating: 0)
        coefficients[0] = 2000
        let bright = AdaptiveTileDecoder.inverseDCT(coefficients, ones)
        #expect((0..<64).allSatisfy { bright[$0] == 255 })
        coefficients[0] = -2000
        let dark = AdaptiveTileDecoder.inverseDCT(coefficients, ones)
        #expect((0..<64).allSatisfy { dark[$0] == 0 })
    }
}

/// Rectangles a Mac running macOS 27.0 sent for its menu bar's clock, as captured by `marionettectl`.
@Suite struct AdaptiveCaptureTests {
    private func capture() throws -> [(x: Int, y: Int, width: Int, height: Int, body: [UInt8])] {
        let directory = try #require(Bundle.module.url(forResource: "Fixtures/adaptive", withExtension: nil))
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let numbers = url.deletingPathExtension().lastPathComponent.split(separator: "-").suffix(4).compactMap { Int($0) }
                return (numbers[0], numbers[1], numbers[2], numbers[3], [UInt8](try Data(contentsOf: url)))
            }
    }

    @Test func aMacsOwnRectanglesDecodeToTheirLastTile() throws {
        var picture = Picture(2048, 64, withTables: false)
        for (index, rectangle) in try capture().enumerated() {
            // Every stream must end exactly on its mark: one bit read wrongly anywhere and it does not.
            let drew = try picture.decode(rectangle.x, rectangle.y, rectangle.width, rectangle.height, rectangle.body)
            #expect(drew == (index > 0))
        }
        #expect((0..<64).allSatisfy { y in picture.pixels[(y * 2048)..<(y * 2048 + 1752)].allSatisfy { $0 == black } })
        // The clock is light text on the menu bar: both light and dark pixels, nothing garish.
        let clock = (8..<56).flatMap { y in (1752..<2048).map { x in picture.pixels[y * 2048 + x] } }
        let light = clock.filter { $0 & 0xff > 200 && $0 >> 8 & 0xff > 200 && $0 >> 16 & 0xff > 200 }.count
        #expect(light > 300 && light < clock.count / 4)
        // A golden digest of the decoded pixels, checked by eye.
        let digest = picture.pixels.withUnsafeBytes { SHA256.hash(data: $0) }
        #expect(digest.map { String(format: "%02x", $0) }.joined() == "f39cbc17c9377392ebc929922f5dba500187ff331320e2884f513fe704ba2680")
    }
}
