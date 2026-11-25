// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// The decoding rules follow the description (docs/apple-vnc-889.md, "Apple's own framebuffer
// encodings") and the MIT-licensed decoder (frontend/wasm/apple-adaptive/src/decoder.rs) in
// andrewtheguy/remotex, © 2026 Andrew Chen. They are checked here against pictures captured from
// a Mac (see the tests).

/// Decodes the picture a Mac sends in Standard mode at Adaptive quality: encoding `0x3f3`, which
/// codes the screen in 8 × 8 tiles.
///
/// A rectangle's body is one of three things, told apart by its first byte:
/// - `2`, the quantization tables, sent once before the first picture;
/// - `0`, a full update: every tile of the rectangle, coarsely, as flat colours, copies of
///   neighbours, cached tiles or DCT coefficients short of their low bits;
/// - `1`, a partial update, which gives tiles of the last full update the bits it left out.
///
/// The Mac codes each update against what its viewer will have made of the ones before, so the
/// decoder keeps a record of every tile and a cache of refined ones, and mirrors what Apple's
/// viewer does even with streams that are not what they should be. It paints onto pixels the caller
/// owns: 32 bits each, blue in the low byte, alpha set.
public struct AdaptiveTileDecoder: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        /// A body too short to hold its own header.
        case tooShort(kind: UInt8, length: Int)
        case unknownKind(UInt8)
        case wrongTableLength(Int)
        /// A picture arrived before the quantization tables.
        case noTables
        case outOfBounds
        case badDataOffset(Int)
        /// A stream ran out before the rectangle's last tile.
        case overrun
        /// A stream did not end on its mark.
        case missingMark(expected: UInt8, found: UInt8)
        case badCoefficients
        /// A partial update refines a tile the last full update did not code with coefficients.
        case unrefinable
    }

    static let fullUpdate: UInt8 = 0
    static let partialUpdate: UInt8 = 1
    static let quantizationTables: UInt8 = 2
    static let tablesLength = 129
    /// How far past a body a stream may be read before the body is refused. A stream is read a
    /// few bytes ahead of what it uses, and an update's last tile can end in its last byte.
    static let overread = 500
    static let mark: UInt32 = 0x6d
    static let partialMarks: [UInt32] = [0x6d, 0x76, 0x73]
    /// Cached tiles are numbered from 1, written up to 64,999 and then from 1 again, and read up to 65,000.
    static let cacheReadLimit = 65_000
    static let cacheWriteLimit = 64_999
    static let cachedY = 64
    static let cachedCr = 15
    static let cachedCb = 20
    static let cacheEntrySize = cachedY + cachedCr + cachedCb

    static let white: UInt32 = 0xffff_ffff
    static let black: UInt32 = 0xff00_0000
    /// What a two-colour tile that reuses its colours draws before any were read.
    static let firstPair: (UInt32, UInt32) = (0xffff_ffff, 0xfffe_d5b5)

    /// JPEG's zigzag order: where the k-th coefficient sits in a block, with spare entries for a
    /// run that reads past the end.
    static let natural: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20,
        13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59,
        52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63,
        63, 63, 63, 63, 63, 63,
    ]

    typealias Coefficients = InlineArray<64, Int16>
    typealias Pixels = InlineArray<64, UInt32>

    /// The three blocks of a tile, each in natural order.
    struct Block {
        var y = Coefficients(repeating: 0)
        var cb = Coefficients(repeating: 0)
        var cr = Coefficients(repeating: 0)
    }

    /// What a full update's DCT tile leaves behind for a partial update to refine.
    struct Coded {
        var precision: UInt8 = 0
        /// Y in zigzag order, the DC first, each coefficient in a signed byte.
        var y = InlineArray<64, Int8>(repeating: 0)
        var cr: Int8?
        var cb: Int8?
    }

    /// What is remembered of each tile of the framebuffer.
    struct TileRecord {
        var coded = Coded()
        /// The full update that last drew the tile.
        var update: UInt32 = 0
        /// Where that update copied it from, if it did: the tile, and the pixel the copy started at.
        var copiedFrom: (tile: Int, pixel: Int)?
    }

    struct Tables {
        var luminance = InlineArray<64, Int32>(repeating: 0)
        var chrominance = InlineArray<64, Int32>(repeating: 0)
    }

    public private(set) var width = 0
    public private(set) var height = 0
    private var tilesAcross = 0
    private var tiles: [TileRecord] = []
    private var tables: Tables?
    private let huffman = HuffmanTable.luminanceAC
    private var updates: UInt32 = 0
    /// Cached tiles end to end, allocated when the first is written.
    private var cache: [Int8] = []
    private var cachedCount: UInt32 = 0
    private var lastWritten = 0
    /// The index a tile was last drawn from the cache by, which "the next one" counts from.
    private var lastDrawn: UInt16 = 0

    public init() {}

    public var hasTables: Bool { tables != nil }

    /// Starts over for a framebuffer of a new size, with no tile coded. The tables and the cache
    /// outlive a resize, as the Mac's do.
    public mutating func resize(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        tilesAcross = (self.width + 7) / 8
        tiles = [TileRecord](repeating: TileRecord(), count: tilesAcross * ((self.height + 7) / 8))
    }

    /// Decodes one rectangle's body (the bytes after its length) onto `pixels`, which must hold
    /// `width × height` pixels row after row. Returns whether it drew; the tables do not.
    ///
    /// On failure the framebuffer keeps whatever the rectangle drew before it failed.
    public mutating func decode(
        _ body: [UInt8], x: Int, y: Int, width rectWidth: Int, height rectHeight: Int,
        onto pixels: UnsafeMutableBufferPointer<UInt32>
    ) throws(Failure) -> Bool {
        guard let kind = body.first else { throw .tooShort(kind: 0, length: 0) }
        switch kind {
        case Self.quantizationTables:
            guard body.count == Self.tablesLength else { throw .wrongTableLength(body.count) }
            var read = Tables()
            for index in 0..<64 {
                read.luminance[index] = Int32(body[1 + index])
                read.chrominance[index] = Int32(body[65 + index])
            }
            tables = read
            return false
        case Self.fullUpdate, Self.partialUpdate:
            precondition(pixels.count >= width * height, "the pixel buffer is smaller than the framebuffer")
            guard x >= 0, y >= 0, rectWidth >= 0, rectHeight >= 0,
                  x < width, x + rectWidth <= width, y < height, y + rectHeight <= height
            else { throw .outOfBounds }
            let rect = Rect(x: x, y: y, width: rectWidth, height: rectHeight)
            var canvas = Canvas(pixels: pixels, width: width)
            if kind == Self.fullUpdate {
                try full(rect, body, &canvas)
            } else {
                try partial(rect, body, &canvas)
            }
            return true
        default:
            throw .unknownKind(kind)
        }
    }

    // MARK: Full updates

    private mutating func full(_ rect: Rect, _ body: [UInt8], _ canvas: inout Canvas) throws(Failure) {
        guard body.count >= 6 else { throw .tooShort(kind: Self.fullUpdate, length: body.count) }
        guard let tables else { throw .noTables }
        let precisions = (body[1], body[2])
        let offset = Int(body[3]) << 16 | Int(body[4]) << 8 | Int(body[5])
        guard offset <= body.count else { throw .badDataOffset(offset) }
        var commands = BitReader(body, at: 6)
        var data = BitReader(body, at: offset)
        // One bit the viewer skips.
        _ = commands.get(1)
        updates &+= 1

        var scan = Scan(rect: rect, across: tilesAcross)
        var single = Self.black
        var pair = Self.firstPair
        var previous = Block()
        var lastCoded: Int?
        // Where the tile before this one is, which "a copy of the previous tile" copies; at the
        // update's first tile, the tile itself.
        var before = scan.pixelIndex(width: width)
        while true {
            if commands.isPast { throw .overrun }
            let command = commands.get(3)
            let covered = Self.tilesCovered(&commands)
            for _ in 0..<covered {
                let index = scan.index
                let here = scan.pixelIndex(width: width)
                guard tiles.indices.contains(index) else { throw .outOfBounds }
                tiles[index].update = updates
                tiles[index].copiedFrom = nil
                var drawn = canvas.read(scan)
                switch command {
                case 0:
                    drawn = Pixels(repeating: Self.white)
                case 1:
                    if index >= 1 { tiles[index].copiedFrom = (index - 1, before) }
                    canvas.copy(into: &drawn, from: before)
                case 2:
                    let above = here - 8 * width
                    if index >= tilesAcross { tiles[index].copiedFrom = (index - tilesAcross, max(above, 0)) }
                    canvas.copy(into: &drawn, from: above)
                case 3:
                    Self.masked(&data, &drawn, set: Self.white, clear: Self.black)
                case 4:
                    let two = data.bit()
                    let reuse = data.bit()
                    if two {
                        if !reuse { pair = (Self.colour(&data), Self.colour(&data)) }
                        Self.masked(&data, &drawn, set: pair.0, clear: pair.1)
                    } else {
                        if !reuse { single = Self.colour(&data) }
                        drawn = Pixels(repeating: single)
                    }
                case 5:
                    let last = lastCoded.map { tiles[$0] }
                    let (block, saved) = try Self.expandBlock(&data, previous: previous, precisions: precisions, last: last)
                    switch saved {
                    case .coded(let coded): tiles[index].coded = coded
                    case .last(let record): tiles[index] = record
                    case .nothing: break
                    }
                    previous = block
                    lastCoded = index
                    Self.inverse(block, tables, into: &drawn)
                case 6:
                    let entry = UInt16(truncatingIfNeeded: data.get(16))
                    drawCached(entry, tables, into: &drawn)
                default:
                    drawCached(lastDrawn &+ 1, tables, into: &drawn)
                }
                canvas.write(scan, drawn)
                before = here
                if scan.advance() {
                    let commandsEnd = commands.get(8)
                    guard commandsEnd == Self.mark else {
                        throw .missingMark(expected: UInt8(Self.mark), found: UInt8(truncatingIfNeeded: commandsEnd))
                    }
                    let dataEnd = data.get(8)
                    guard dataEnd == Self.mark else {
                        throw .missingMark(expected: UInt8(Self.mark), found: UInt8(truncatingIfNeeded: dataEnd))
                    }
                    return
                }
            }
            if data.isPast { throw .overrun }
        }
    }

    /// A repeat count: how many tiles a command covers.
    static func tilesCovered(_ bits: inout BitReader) -> UInt32 {
        guard bits.bit() else { return 1 }
        let short = bits.get(4)
        if short != 15 { return short + 2 }
        let first = bits.get(8)
        if first & 0x80 == 0 { return first + 17 }
        let second = bits.get(8)
        if second & 0x80 == 0 { return (second << 7 | (first & 0x7f)) + 17 }
        let third = bits.get(8)
        return (third << 14 | (second & 0x7f) << 7 | (first & 0x7f)) + 17
    }

    /// A signed number: k one bits and a zero, then the value's low bits and its sign.
    static func signedNumber(_ bits: inout BitReader) throws(Failure) -> Int16 {
        var ones: UInt32 = 0
        while bits.bit() {
            ones += 1
            if ones == 39 { throw .badCoefficients }
        }
        let magnitude: UInt32
        switch ones {
        case 0:
            guard bits.bit() else { return 0 }
            magnitude = 1
        case 1: magnitude = 2 + bits.get(1)
        case 2: magnitude = 4 + bits.get(2)
        default: magnitude = 8 * (ones - 2) + bits.get(3)
        }
        let negative = bits.bit()
        let value = Int16(truncatingIfNeeded: magnitude)
        return negative ? 0 &- value : value
    }

    /// A row mask, then for each row whose bit is clear a pixel mask. A set bit takes `set`; a row
    /// whose bit is set is `set` throughout.
    private static func masked(_ data: inout BitReader, _ tile: inout Pixels, set: UInt32, clear: UInt32) {
        let rows = data.get(8)
        for row in 0..<8 {
            if rows & (0x80 >> UInt32(row)) != 0 {
                for column in 0..<8 { tile[row * 8 + column] = set }
                continue
            }
            let pixels = data.get(8)
            for column in 0..<8 {
                tile[row * 8 + column] = pixels & (0x80 >> UInt32(column)) != 0 ? set : clear
            }
        }
    }

    /// A colour: 8-bit Y, then the top six bits of Cb and of Cr.
    private static func colour(_ data: inout BitReader) -> UInt32 {
        let y = Int32(data.get(8))
        let cb = Int32(data.get(6) << 2)
        let cr = Int32(data.get(6) << 2)
        return pixel(y: y, cb: cb, cr: cr)
    }

    /// JPEG's YCbCr to RGB, with the reference library's fixed-point constants.
    @inline(__always)
    static func pixel(y: Int32, cb: Int32, cr: Int32) -> UInt32 {
        let half: Int32 = 1 << 15
        let cb = cb - 128
        let cr = cr - 128
        let red = y + ((91_881 * cr + half) >> 16)
        let green = y + ((-46_802 * cr - 22_554 * cb + half) >> 16)
        let blue = y + ((116_130 * cb + half) >> 16)
        func clamp(_ value: Int32) -> UInt32 { UInt32(min(max(value, 0), 255)) }
        return 0xff00_0000 | clamp(red) << 16 | clamp(green) << 8 | clamp(blue)
    }

    enum Saved {
        case coded(Coded)
        /// The previous DCT tile's record over again, for a tile that repeats it.
        case last(TileRecord)
        case nothing
    }

    /// A DCT tile of a full update: the repeat bit, the chroma and precision bits, the chroma DCs
    /// where they are sent, Y's DC, then Y's AC coefficients.
    static func expandBlock(
        _ data: inout BitReader, previous: Block, precisions: (UInt8, UInt8), last: TileRecord?
    ) throws(Failure) -> (Block, Saved) {
        var block = Block()
        if data.bit() {
            guard let last else { return (block, .nothing) }
            block.y = previous.y
            block.cb[0] = previous.cb[0]
            block.cr[0] = previous.cr[0]
            return (block, .last(last))
        }
        let keepsChroma = data.bit()
        let precision = data.bit() ? precisions.1 : precisions.0
        if keepsChroma {
            block.cb[0] = previous.cb[0]
            block.cr[0] = previous.cr[0]
        } else {
            // Half the previous DC, rounded towards zero, less the number, doubled.
            block.cb[0] = ((previous.cb[0] / 2) &- (try signedNumber(&data))) &* 2
            block.cr[0] = ((previous.cr[0] / 2) &- (try signedNumber(&data))) &* 2
        }
        block.y[0] = previous.y[0] &- (try signedNumber(&data))

        let fine = precision >= 15
        var k = 0 + 1
        var saved = true
        scanning: while k < 64 {
            let early = k < 6
            let below = k < Int(precision)
            // A coefficient is sent short of its low bits: a unit is 1 shifted left by that many.
            let shift: Int32 = fine ? (below ? 1 : 3) : (below ? 3 : 4)
            if data.bit() {
                var ones: Int32 = 0
                while data.bit() {
                    ones += 1
                    if early, ones == 33 { throw .badCoefficients }
                    if !early, ones == 19 {
                        // The viewer keeps what it has and leaves the tile's record as it was.
                        saved = false
                        break scanning
                    }
                }
                let magnitude: Int32
                if early {
                    magnitude = ones < 4 ? 2 + 4 * ones + Int32(data.get(2)) : 18 + 8 * (ones - 4) + Int32(data.get(3))
                } else {
                    switch ones {
                    case 0: magnitude = 2 + Int32(data.get(1))
                    case 1: magnitude = 4 + Int32(data.get(2))
                    default: magnitude = 8 * (ones - 1) + Int32(data.get(3))
                    }
                }
                let value = data.bit() ? -magnitude : magnitude
                block.y[natural[k]] = Int16(truncatingIfNeeded: value << shift)
                k += 1
                continue
            }
            let unit = Int16(1) << Int16(shift)
            switch data.get(2) {
            case 0b00:
                k += 1
            case 0b10:
                block.y[natural[k]] = unit
                k += 1
            case 0b11:
                block.y[natural[k]] = -unit
                k += 1
            default:
                guard data.bit() else { break scanning }
                let r = data.get(2)
                var run = r + 3
                if r == 3 {
                    while true {
                        let more = data.get(3)
                        run += more
                        if more != 7 || k + Int(run & 0xff) >= 64 { break }
                    }
                    if k + Int(run & 0xff) > 63 { throw .badCoefficients }
                    k += Int(run & 0xff)
                } else {
                    k += Int(run)
                }
            }
        }
        guard saved else { return (block, .nothing) }
        var coded = Coded()
        coded.precision = precision
        for index in 0..<64 { coded.y[index] = Int8(truncatingIfNeeded: block.y[natural[index]]) }
        coded.cr = Int8(truncatingIfNeeded: block.cr[0])
        coded.cb = Int8(truncatingIfNeeded: block.cb[0])
        return (block, .coded(coded))
    }

    // MARK: Partial updates

    private mutating func partial(_ rect: Rect, _ body: [UInt8], _ canvas: inout Canvas) throws(Failure) {
        guard body.count >= 3 else { throw .tooShort(kind: Self.partialUpdate, length: body.count) }
        guard let tables else { throw .noTables }
        let crCount = Int(min(body[1], 64))
        let cbCount = Int(min(body[2], 64))
        var bits = BitReader(body, at: 3)
        var scan = Scan(rect: rect, across: tilesAcross)
        while true {
            let index = scan.index
            guard tiles.indices.contains(index) else { throw .outOfBounds }
            let record = tiles[index]
            switch bits.get(2) {
            case 0:
                break
            case 1:
                var drawn = canvas.read(scan)
                let refined = try Self.refine(&bits, record.coded, crCount: crCount, cbCount: cbCount, huffman: huffman)
                Self.inverse(refined.block, tables, into: &drawn)
                store(refined)
                canvas.write(scan, drawn)
            case 2:
                // The copy the full update made, while the tile it copied is still that update's.
                if let source = record.copiedFrom, tiles.indices.contains(source.tile), tiles[source.tile].update == record.update {
                    var drawn = canvas.read(scan)
                    canvas.copy(into: &drawn, from: source.pixel)
                    canvas.write(scan, drawn)
                }
            default:
                let entry = bits.bit() ? lastDrawn &+ 1 : UInt16(truncatingIfNeeded: bits.get(16))
                var drawn = canvas.read(scan)
                drawCached(entry, tables, into: &drawn)
                canvas.write(scan, drawn)
            }
            if scan.advance() {
                for expected in Self.partialMarks {
                    let found = bits.get(8)
                    guard found == expected else {
                        throw .missingMark(expected: UInt8(expected), found: UInt8(truncatingIfNeeded: found))
                    }
                }
                return
            }
            if bits.isPast { throw .overrun }
        }
    }

    /// A refined tile: Y in zigzag order as the cache keeps it, and the whole of each chroma block.
    struct Refined {
        var y = InlineArray<64, Int8>(repeating: 0)
        var cr = Coefficients(repeating: 0)
        var cb = Coefficients(repeating: 0)

        var block: Block {
            var block = Block()
            for index in 0..<64 { block.y[natural[index]] = Int16(y[index]) }
            block.cr = cr
            block.cb = cb
            return block
        }
    }

    /// A partial update's code 1: the bits the full update left out of a tile's Y coefficients,
    /// and its chrominance as JPEG codes it.
    static func refine(
        _ bits: inout BitReader, _ coded: Coded, crCount: Int, cbCount: Int, huffman: HuffmanTable
    ) throws(Failure) -> Refined {
        let precision = Int(coded.precision)
        let count = Int(bits.get(6)) + 1
        var refined = Refined()
        refined.y[0] = coded.y[0]

        /// Moved further from zero by `width` more bits.
        func further(_ bits: inout BitReader, _ coefficient: Int8, _ width: UInt32) -> Int8 {
            let more = Int8(truncatingIfNeeded: bits.get(width))
            return coefficient &+ (coefficient < 0 ? 0 &- more : more)
        }

        let below = min(count, precision)
        if below > 1 {
            for k in 1..<below {
                let coefficient = coded.y[k]
                if precision < 15 {
                    refined.y[k] = coefficient == 0 ? Int8(truncatingIfNeeded: try signedNumber(&bits)) : further(&bits, coefficient, 3)
                } else if coefficient == 0 {
                    // Below the precision of a fine tile a zero is near enough: a bit, and when it
                    // is set a sign for 1 or −1.
                    refined.y[k] = !bits.bit() ? 0 : (bits.bit() ? -1 : 1)
                } else {
                    refined.y[k] = further(&bits, coefficient, 1)
                }
            }
        }
        let from = max(precision, 1)
        if count > from {
            for k in from..<count {
                let coefficient = coded.y[k]
                refined.y[k] = coefficient == 0
                    ? Int8(truncatingIfNeeded: try signedNumber(&bits))
                    : further(&bits, coefficient, precision < 15 ? 4 : 3)
            }
        }

        func chroma(_ bits: inout BitReader, _ dc: Int8?, _ count: Int) throws(Failure) -> Coefficients {
            guard let dc else { throw .unrefinable }
            var block = Coefficients(repeating: 0)
            let bit = bits.bit()
            if dc == 0 {
                block[0] = !bit ? 0 : (bits.bit() ? -1 : 1)
            } else {
                let step: Int8 = bit ? 1 : 0
                block[0] = Int16(dc &+ (dc < 0 ? -step : step))
            }
            var k = 0
            while k < count {
                let symbol = huffman.decode(&bits)
                let run = Int(symbol >> 4)
                let size = UInt32(symbol & 15)
                if size == 0 {
                    if run != 15 { break }
                    k += 15
                } else {
                    k += run
                    var value = Int32(bits.get(size))
                    if value < 1 << (size - 1) { value += 1 - (1 << Int32(size)) }
                    block[natural[k + 1]] = Int16(truncatingIfNeeded: value)
                }
                k += 1
            }
            return block
        }
        refined.cr = try chroma(&bits, coded.cr, crCount)
        refined.cb = try chroma(&bits, coded.cb, cbCount)
        return refined
    }

    // MARK: The cache

    /// Keeps a refined tile under the next index: 64 Y, 15 Cr and 20 Cb coefficients in zigzag order.
    private mutating func store(_ refined: Refined) {
        if cache.isEmpty {
            cache = [Int8](repeating: 0, count: (Self.cacheReadLimit + 1) * Self.cacheEntrySize)
        }
        cachedCount &+= 1
        lastWritten = lastWritten == Self.cacheWriteLimit ? 1 : lastWritten + 1
        let base = lastWritten * Self.cacheEntrySize
        for index in 0..<Self.cachedY { cache[base + index] = refined.y[index] }
        for index in 0..<Self.cachedCr {
            cache[base + Self.cachedY + index] = Int8(truncatingIfNeeded: refined.cr[Self.natural[index]])
        }
        for index in 0..<Self.cachedCb {
            cache[base + Self.cachedY + Self.cachedCr + index] = Int8(truncatingIfNeeded: refined.cb[Self.natural[index]])
        }
    }

    /// Draws the cached tile at `entry`, where there is one; it is then the one "the next" counts from.
    private mutating func drawCached(_ entry: UInt16, _ tables: Tables, into tile: inout Pixels) {
        guard entry != 0, Int(entry) <= Self.cacheReadLimit, UInt32(entry) <= cachedCount, !cache.isEmpty else { return }
        let base = Int(entry) * Self.cacheEntrySize
        var block = Block()
        for index in 0..<Self.cachedY { block.y[Self.natural[index]] = Int16(cache[base + index]) }
        for index in 0..<Self.cachedCr { block.cr[Self.natural[index]] = Int16(cache[base + Self.cachedY + index]) }
        for index in 0..<Self.cachedCb { block.cb[Self.natural[index]] = Int16(cache[base + Self.cachedY + Self.cachedCr + index]) }
        Self.inverse(block, tables, into: &tile)
        lastDrawn = entry
    }

    // MARK: Coefficients to pixels

    /// The three blocks dequantized, inverted and converted to pixels.
    static func inverse(_ block: Block, _ tables: Tables, into tile: inout Pixels) {
        let y = inverseDCT(block.y, tables.luminance)
        let cb = inverseDCT(block.cb, tables.chrominance)
        let cr = inverseDCT(block.cr, tables.chrominance)
        for index in 0..<64 {
            tile[index] = pixel(y: Int32(y[index]), cb: Int32(cb[index]), cr: Int32(cr[index]))
        }
    }

    /// The JPEG reference library's accurate integer inverse DCT (`jidctint.c`), with its output
    /// range limit.
    static func inverseDCT(_ coefficients: Coefficients, _ quantization: InlineArray<64, Int32>) -> InlineArray<64, UInt8> {
        let constBits: Int64 = 13
        let pass1Bits: Int64 = 2

        @inline(__always) func descale(_ value: Int64, _ bits: Int64) -> Int64 {
            (value + (1 << (bits - 1))) >> bits
        }
        /// What a sample outside 0–255 becomes: the library's table, read through its ten-bit mask.
        @inline(__always) func limit(_ value: Int64) -> UInt8 {
            let index = Int32(truncatingIfNeeded: value) & 1023
            switch index {
            case 0..<128: return UInt8(index + 128)
            case 128..<512: return 255
            case 512..<896: return 0
            default: return UInt8(index - 896)
            }
        }
        /// One row or column: its eight outputs before they are descaled.
        @inline(__always) func butterfly(_ v: InlineArray<8, Int64>) -> InlineArray<8, Int64> {
            let z1 = (v[2] + v[6]) * 4433
            let tmp2 = z1 + v[6] * -15137
            let tmp3 = z1 + v[2] * 6270
            let tmp0 = (v[0] + v[4]) << constBits
            let tmp1 = (v[0] - v[4]) << constBits
            let tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2
            var t0 = v[7], t1 = v[5], t2 = v[3], t3 = v[1]
            let s1 = t0 + t3, s2 = t1 + t2, s3 = t0 + t2, s4 = t1 + t3
            let z5 = (s3 + s4) * 9633
            t0 *= 2446
            t1 *= 16819
            t2 *= 25172
            t3 *= 12299
            let m1 = s1 * -7373
            let m2 = s2 * -20995
            let m3 = s3 * -16069 + z5
            let m4 = s4 * -3196 + z5
            t0 += m1 + m3
            t1 += m2 + m4
            t2 += m2 + m3
            t3 += m1 + m4
            return [tmp10 + t3, tmp11 + t2, tmp12 + t1, tmp13 + t0, tmp13 - t0, tmp12 - t1, tmp11 - t2, tmp10 - t3]
        }

        var workspace = InlineArray<64, Int32>(repeating: 0)
        for column in 0..<8 {
            var allZero = true
            for row in 1..<8 where coefficients[row * 8 + column] != 0 {
                allZero = false
                break
            }
            if allZero {
                let dc = Int32(truncatingIfNeeded: (Int64(coefficients[column]) * Int64(quantization[column])) << pass1Bits)
                for row in 0..<8 { workspace[row * 8 + column] = dc }
                continue
            }
            var input = InlineArray<8, Int64>(repeating: 0)
            for row in 0..<8 { input[row] = Int64(coefficients[row * 8 + column]) * Int64(quantization[row * 8 + column]) }
            let output = butterfly(input)
            for row in 0..<8 { workspace[row * 8 + column] = Int32(truncatingIfNeeded: descale(output[row], constBits - pass1Bits)) }
        }
        var samples = InlineArray<64, UInt8>(repeating: 0)
        for row in 0..<8 {
            var allZero = true
            for column in 1..<8 where workspace[row * 8 + column] != 0 {
                allZero = false
                break
            }
            if allZero {
                let flat = limit(descale(Int64(workspace[row * 8]), pass1Bits + 3))
                for column in 0..<8 { samples[row * 8 + column] = flat }
                continue
            }
            var input = InlineArray<8, Int64>(repeating: 0)
            for column in 0..<8 { input[column] = Int64(workspace[row * 8 + column]) }
            let output = butterfly(input)
            for column in 0..<8 { samples[row * 8 + column] = limit(descale(output[column], constBits + pass1Bits + 3)) }
        }
        return samples
    }

    // MARK: Walking a rectangle

    struct Rect {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// The tiles of a rectangle in rows, left to right and top to bottom.
    struct Scan {
        let rect: Rect
        let across: Int
        /// Where the tile is within the rectangle.
        var dx = 0
        var dy = 0
        /// Its index among the framebuffer's tiles, and the index its row starts at.
        var index: Int
        var rowStart: Int

        init(rect: Rect, across: Int) {
            self.rect = rect
            self.across = across
            index = (rect.y >> 3) * across + (rect.x >> 3)
            rowStart = index
        }

        var x: Int { rect.x + dx }
        var y: Int { rect.y + dy }

        /// The tile's top left pixel's place in a framebuffer `width` wide.
        func pixelIndex(width: Int) -> Int { y * width + x }

        /// How much of the tile the rectangle covers.
        var clipped: (width: Int, height: Int) { (min(rect.width - dx, 8), min(rect.height - dy, 8)) }

        /// Moves on. Returns whether the tile just done was the last.
        mutating func advance() -> Bool {
            dx += 8
            if dx < rect.width {
                index += 1
                return false
            }
            dy += 8
            if dy >= rect.height { return true }
            dx = 0
            rowStart += across
            index = rowStart
            return false
        }
    }

    /// The caller's pixels, and the three ways tiles touch them.
    struct Canvas {
        let pixels: UnsafeMutableBufferPointer<UInt32>
        let width: Int

        /// The tile under `scan` as the framebuffer has it; what lies past the rectangle's edge is black.
        func read(_ scan: Scan) -> Pixels {
            var tile = Pixels(repeating: AdaptiveTileDecoder.black)
            let (columns, rows) = scan.clipped
            for row in 0..<max(rows, 0) {
                let start = (scan.y + row) * width + scan.x
                for column in 0..<max(columns, 0) { tile[row * 8 + column] = pixels[start + column] }
            }
            return tile
        }

        /// Paints as much of `tile` as the rectangle covers.
        func write(_ scan: Scan, _ tile: Pixels) {
            let (columns, rows) = scan.clipped
            for row in 0..<max(rows, 0) {
                let start = (scan.y + row) * width + scan.x
                for column in 0..<max(columns, 0) { pixels[start + column] = tile[row * 8 + column] }
            }
        }

        /// Eight rows of eight pixels starting at pixel `at`, the framebuffer read as one run of
        /// rows. A row that starts before the framebuffer is left alone, and so is a pixel past its end.
        func copy(into tile: inout Pixels, from at: Int) {
            for row in 0..<8 {
                let start = at + row * width
                if start < 0 { continue }
                for column in 0..<8 where start + column < pixels.count {
                    tile[row * 8 + column] = pixels[start + column]
                }
            }
        }
    }
}

/// A stream read most significant bit first. Past its end it reads zeros.
struct BitReader {
    private let bytes: [UInt8]
    /// The next byte to take into the window.
    private var next: Int
    private var window: UInt64 = 0
    private var held: UInt32 = 0

    init(_ bytes: [UInt8], at offset: Int) {
        self.bytes = bytes
        next = offset
    }

    /// The next `count` bits, at most 24.
    mutating func get(_ count: UInt32) -> UInt32 {
        while held < count {
            let byte: UInt64 = next < bytes.count ? UInt64(bytes[next]) : 0
            next += 1
            window = (window << 8 | byte) & 0xffff_ffff_ffff
            held += 8
        }
        held -= count
        return UInt32(truncatingIfNeeded: (window >> UInt64(held)) & ((1 << UInt64(count)) - 1))
    }

    mutating func bit() -> Bool { get(1) == 1 }

    /// Whether the stream has been read further past the body than a well-formed one would be.
    var isPast: Bool { next > bytes.count + AdaptiveTileDecoder.overread }
}

/// JPEG's standard Huffman table for luminance AC coefficients, which a refinement's chrominance
/// is coded with.
struct HuffmanTable: Sendable {
    /// The largest code of each length, or −1 where there is none.
    private var largest = [Int32](repeating: -1, count: 17)
    /// The first value of each length, less its first code.
    private var offset = [Int32](repeating: 0, count: 17)
    private let values: [UInt8]

    static let luminanceAC = HuffmanTable(
        counts: [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d],
        values: [
            0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
            0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
            0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
            0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
            0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
            0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
            0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
            0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
            0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
            0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
            0xf9, 0xfa,
        ]
    )

    init(counts: [UInt8], values: [UInt8]) {
        self.values = values
        var code: Int32 = 0
        var first: Int32 = 0
        for (index, count) in counts.enumerated() {
            let length = index + 1
            let count = Int32(count)
            if count > 0 {
                offset[length] = first - code
                code += count
                largest[length] = code - 1
                first += count
            }
            code <<= 1
        }
    }

    /// The next symbol, or 0 (an end of block) for a code no length has, as the viewer reads one.
    func decode(_ bits: inout BitReader) -> UInt8 {
        var code: Int32 = 0
        for length in 1...16 {
            code = code << 1 | Int32(bits.get(1))
            if code <= largest[length] {
                let index = Int(code + offset[length])
                return values.indices.contains(index) ? values[index] : 0
            }
        }
        _ = bits.get(1)
        return 0
    }
}
