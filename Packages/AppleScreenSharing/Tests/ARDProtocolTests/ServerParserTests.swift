// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
import ARDTestSupport
import Foundation
import Testing
import zlib

@Suite struct ServerMessageParserTests {
    static let layoutPayload = ServerBytes.layout(
        framebuffer: (4480, 1800), current: nil, flags: 0x4,
        screens: [
            .init(id: 4, density: 2, points: (0, 0, 900, 1600), pixels: (0, 0, 1800, 3200)),
            .init(id: 1, density: 1, points: (0, 1600, 800, 2880), pixels: (0, 3200, 800, 4480), flags: 0),
        ]
    )

    /// A stream touching every message and rectangle kind the parser knows.
    static let sampleStream: Data = {
        var stream = Data()
        stream.append(ServerBytes.status(.heartbeat))
        stream.append(Data([0x02])) // bell
        stream.append(ServerBytes.update([
            ServerBytes.rectangle(encoding: .appleDisplayLayout, body: ServerBytes.counted16(layoutPayload)),
        ]))
        stream.append(ServerBytes.update([
            ServerBytes.rectangle(x: 2, y: 1, width: 16, height: 16, encoding: .appleCursorImage, body: Data(hex: "00000007") + ServerBytes.counted32(Data([1, 2, 3]))),
            ServerBytes.rectangle(encoding: .appleCursorImage, body: Data(hex: "00000007 00000000")),
            ServerBytes.rectangle(x: 10, y: 20, encoding: .appleCursorPosition),
            ServerBytes.rectangle(encoding: .appleKeyboardSource, body: ServerBytes.counted16(Data(hex: "0001 00000001 0017") + Data("com.apple.keylayout.ABC".utf8))),
            ServerBytes.rectangle(encoding: .appleVendorKeysyms, body: ServerBytes.counted16(Data(hex: "0001 0004 1008fd00 1008fd01 1008fd02 1008fd03"))),
            ServerBytes.rectangle(encoding: .appleDisplayInfo, body: Data(hex: "0800 0600 00000000 0001") + Data(count: 0x1c)),
            ServerBytes.rectangle(encoding: .appleMediaStream, body: ServerBytes.counted16(Data([9, 8, 7]))),
        ]))
        stream.append(ServerBytes.update([
            ServerBytes.rectangle(x: 0, y: 0, width: 2, height: 2, encoding: .raw, body: Data(repeating: 0x55, count: 16)),
            ServerBytes.rectangle(x: 4, y: 4, width: 64, height: 64, encoding: .zlib, body: ServerBytes.counted32(Data(repeating: 0xAB, count: 300))),
            ServerBytes.rectangle(x: 4, y: 4, width: 64, height: 64, encoding: .zrle, body: ServerBytes.counted32(Data(repeating: 0xCD, count: 5))),
            ServerBytes.rectangle(x: 8, y: 8, width: 8, height: 8, encoding: .appleAdaptive, body: ServerBytes.counted32(Data([4, 4]))),
            ServerBytes.rectangle(width: 800, height: 600, encoding: .desktopSize),
        ]))
        stream.append(Data(hex: "03 000000 00000005") + Data("hello".utf8))
        stream.append(Data(hex: "1f 00 01 00 0000002a 00000010 00000003 aabbcc"))
        stream.append(ServerBytes.update([]))
        // RFB's open-ended update: a count of 0xffff closed by a LastRect.
        stream.append(Data(hex: "00 00 ffff") + ServerBytes.rectangle(x: 1, y: 1, width: 1, height: 1, encoding: .raw, body: Data(count: 4)) + ServerBytes.rectangle(encoding: .lastRect))
        stream.append(ServerBytes.status(.pasteboardChanged))
        stream.append(ServerBytes.accessibility)
        stream.append(ServerBytes.userRequest)
        stream.append(ServerBytes.shortUserRequest)
        stream.append(ServerBytes.systemInfo)
        return stream
    }()

    @Test func parsesEveryKind() throws {
        let parsed = try events(in: Self.sampleStream, chunkSizes: [Self.sampleStream.count])
        let summary = parsed.map { event -> String in
            switch event {
            case .updateBegan(let count): "begin(\(count))"
            case .updateEnded: "end"
            case .bell: "bell"
            case .cutText(let text): "cut(\(text))"
            case .status(let status): "status(\(status.rawValue))"
            case .pasteboard(let data): "pasteboard(\(data.token),\(data.isPromisesOnly),\(data.uncompressedLength),\(data.compressed.count))"
            case .drag(let drag): "drag(\(drag.token),\(drag.compressed.count))"
            case .dropDestination(let drop): "drop(\(drop.token),\(drop.path))"
            case .fileTransfer(let message): "file(\(message.transferID),\(message.command))"
            case .notice(let notice):
                switch notice {
                case .accessibility(let feature, let message, let replyTo, let payload): "accessibility(\(feature),\(message),\(replyTo),\(payload.hex))"
                case .userRequest(let version, let request, let first, let second, let extra): "request(\(version),\(request),\(first),\(second),\(extra.hex))"
                case .systemInfo(let version, let token, let flags, let inflated, let payload): "system(\(version),\(token),\(flags),\(inflated),\(payload.count))"
                case .unusable(let type, _): "unusable(\(type))"
                }
            case .rectangle(let rectangle):
                switch rectangle.body {
                case .raw(let data): "raw(\(data.count))"
                case .zlib(let data): "zlib(\(data.count))"
                case .zrle(let data): "zrle(\(data.count))"
                case .adaptive(let data): "adaptive(\(data.count))"
                case .rekey: "rekey"
                case .cursorImage(let id, let data): "cursor(\(id),\(data.count))@\(rectangle.header.x),\(rectangle.header.y)"
                case .cursorPosition: "cursorPos(\(rectangle.header.x),\(rectangle.header.y))"
                case .displayLayout(let layout): "layout(\(layout.screens.count))"
                case .keyboardSource(let source): "keyboard(\(source.inputSourceID),\(source.isSecureInputActive))"
                case .mediaStream(let data): "media(\(data.count))"
                case .desktopSize: "desktopSize(\(rectangle.header.width)x\(rectangle.header.height))"
                case .lastRectangle: "last"
                case .ignored: "ignored"
                case .unusable: "unusable"
                }
            }
        }
        #expect(summary == [
            "status(4)", "bell",
            "begin(1)", "layout(2)", "end",
            "begin(7)", "cursor(7,3)@2,1", "cursor(7,0)@0,0", "cursorPos(10,20)", "keyboard(com.apple.keylayout.ABC,true)", "ignored", "ignored", "media(3)", "end",
            "begin(5)", "raw(16)", "zlib(300)", "zrle(5)", "adaptive(2)", "desktopSize(800x600)", "end",
            "cut(hello)", "pasteboard(42,true,16,3)",
            "begin(0)", "end",
            "begin(65535)", "raw(4)", "last", "end",
            "status(2)",
            "accessibility(1,2,3,6178)", "request(1,7,1,2,0102030405060708)", "request(1,9,0,0,)",
            "system(1,9,1,\(ServerBytes.systemInfoText.utf8.count),\(ServerBytes.systemInfoPayload.count))",
        ])
    }

    @Test func noticesDescribeThemselves() throws {
        let parsed = try events(in: ServerBytes.systemInfo, chunkSizes: [ServerBytes.systemInfo.count])
        guard case .notice(let notice) = parsed.first else {
            Issue.record("expected a notice")
            return
        }
        // The payload is inflated for the diagnostic line.
        #expect(notice.description.contains(ServerBytes.systemInfoText))
    }

    @Test func badSystemInfoIsSteppedOver() throws {
        // A payload length past the end of the message: the message's own length still frames it.
        let stream = Data(hex: "51 00 00000015 0001 00000009 00000000 00000000 00000099 aabbcc") + Data([0x02])
        let parsed = try events(in: stream, chunkSizes: [stream.count])
        #expect(parsed.count == 2)
        #expect(parsed.last == .bell)
        guard case .notice(.unusable(0x51, _)) = parsed.first else {
            Issue.record("expected the system info to be stepped over, got \(parsed)")
            return
        }
    }

    @Test func sameEventsAtEveryChunking() throws {
        let stream = Self.sampleStream
        let reference = try events(in: stream, chunkSizes: [stream.count])
        // One byte at a time: every possible split point at once.
        #expect(try events(in: stream, chunkSizes: repeatElement(1, count: stream.count)) == reference)
        for split in 1..<stream.count {
            #expect(try events(in: stream, chunkSizes: [split, stream.count - split]) == reference, "split at \(split)")
        }
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<200 {
            let sizes = (0..<stream.count).map { _ in Int.random(in: 1...97, using: &generator) }
            #expect(try events(in: stream, chunkSizes: sizes) == reference)
        }
    }

    @Test func rekeyRectangleCarriesExactlyItsBody() throws {
        let body = Data((0..<36).map { UInt8($0) })
        let stream = ServerBytes.update([ServerBytes.rectangle(encoding: .appleRekey, body: body)]) + Data([0xEE, 0xEE, 0xEE])
        var parser = ServerMessageParser()
        var buffer = InboundBuffer()
        buffer.append(stream)
        #expect(try parser.next(from: &buffer) == .updateBegan(rectangleCount: 1))
        guard case .rectangle(let rectangle) = try parser.next(from: &buffer), case .rekey(let parsed) = rectangle.body else {
            Issue.record("expected the rekey rectangle")
            return
        }
        #expect(parsed == body)
        // What follows is ciphertext and must still be in the buffer, untouched.
        #expect(buffer.drain() == Data([0xEE, 0xEE, 0xEE]))
        #expect(try parser.next(from: &buffer) == .updateEnded)
        #expect(!parser.isInsideUpdate)
    }

    @Test func unknownMessageTypeIsFatal() {
        #expect(throws: WireError.malformed("server message type 0x7f")) {
            _ = try events(in: Data([0x7f, 0, 0, 0]), chunkSizes: [4])
        }
    }

    @Test func unrequestedEncodingIsFatal() {
        let stream = ServerBytes.update([ServerBytes.rectangle(encoding: Encoding(rawValue: 5))])
        #expect(throws: WireError.malformed("rectangle encoding 0x5 was never requested")) {
            _ = try events(in: stream, chunkSizes: [stream.count])
        }
    }

    @Test(arguments: [Encoding.zlib, .zrle, .appleAdaptive])
    func oversizedPixelPayloadIsRefusedBeforeWaitingForIt(_ encoding: Encoding) {
        let stream = ServerBytes.update([ServerBytes.rectangle(width: 1, height: 1, encoding: encoding, body: Data(hex: "7fffffff"))])
        #expect(throws: WireError.self) { _ = try events(in: stream, chunkSizes: [stream.count]) }
    }

    @Test func oversizedCursorAndPasteboardAreRefused() {
        let cursor = ServerBytes.update([ServerBytes.rectangle(encoding: .appleCursorImage, body: Data(hex: "00000001 40000000"))])
        #expect(throws: WireError.self) { _ = try events(in: cursor, chunkSizes: [cursor.count]) }
        let pasteboard = Data(hex: "1f 00 00 00 00000000 00000010 7fffffff")
        #expect(throws: WireError.self) { _ = try events(in: pasteboard, chunkSizes: [pasteboard.count]) }
        let inflated = Data(hex: "1f 00 00 00 00000000 7fffffff 00000000")
        #expect(throws: WireError.self) { _ = try events(in: inflated, chunkSizes: [inflated.count]) }
    }

    @Test func shortStatusIsSteppedOver() throws {
        let stream = Data(hex: "14 00 0002 0001") + ServerBytes.status(.heartbeat)
        #expect(try events(in: stream, chunkSizes: [stream.count]) == [
            .notice(.unusable(type: 0x14, reason: "status of 2 bytes")), .status(.heartbeat),
        ])
    }

    @Test(arguments: [
        ServerBytes.layout(framebuffer: (10, 10), current: nil, flags: 0, screens: []),
        ServerBytes.layout(framebuffer: (0, 0), current: nil, flags: 0, screens: [.init(id: 1, density: 1, points: (0, 0, 10, 10), pixels: (0, 0, 10, 10))]),
        ServerBytes.layout(framebuffer: (10, 10), current: nil, flags: 0, screens: [.init(id: 1, density: 1, points: (0, 0, 0, 0), pixels: (0, 0, 0, 0))]),
        ServerBytes.layout(framebuffer: (10, 10), current: nil, flags: 0, screens: [.init(id: 1, density: 1, points: (0, 0, 10, 10), pixels: (0, 0, 10, 10))], declaredCount: 26),
    ])
    func unusableLayoutIsSteppedOver(_ payload: Data) throws {
        // A headless Mac, a user switch or a display being torn down can produce these; the next
        // layout follows, and the session must still be there to read it.
        let stream = ServerBytes.update([
            ServerBytes.rectangle(encoding: .appleDisplayLayout, body: ServerBytes.counted16(payload)),
            ServerBytes.rectangle(encoding: .appleDisplayLayout, body: ServerBytes.counted16(Self.layoutPayload)),
        ])
        let parsed = try events(in: stream, chunkSizes: [stream.count])
        guard parsed.count == 4, case .rectangle(let bad) = parsed[1], case .unusable = bad.body,
              case .rectangle(let good) = parsed[2], case .displayLayout(let layout) = good.body
        else {
            Issue.record("expected an unusable layout, then a usable one: \(parsed)")
            return
        }
        #expect(layout.screens.count == 2)
    }

    @Test func survivesRandomMutationWithoutCrashing() {
        var generator = SeededGenerator(seed: 2026)
        let original = Self.sampleStream
        for _ in 0..<3000 {
            var mutated = original
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                let index = Int.random(in: 0..<mutated.count, using: &generator)
                switch Int.random(in: 0..<3, using: &generator) {
                case 0: mutated[index] = UInt8.random(in: .min ... .max, using: &generator)
                case 1: mutated.remove(at: index)
                default: mutated.insert(UInt8.random(in: .min ... .max, using: &generator), at: index)
                }
            }
            _ = try? events(in: mutated, chunkSizes: [Int.random(in: 1...64, using: &generator), mutated.count])
        }
    }
}

@Suite struct DisplayLayoutTests {
    @Test func parsesMixedDensityCombinedLayout() throws {
        var reader = WireReader(ServerMessageParserTests.layoutPayload)
        let layout = try DisplayLayout.parse(&reader)
        #expect(layout.version == 5)
        #expect(layout.currentScreen == nil)
        #expect(layout.flags == [.onConsole])
        #expect([layout.framebufferWidth, layout.framebufferHeight] == ([4480, 1800] as [Int]))
        #expect(layout.screens.map(\.id) == [4, 1])
        let retina = layout.screens[0]
        #expect(retina.density == 2)
        #expect([retina.pointWidth, retina.pointHeight, retina.pixelWidth, retina.pixelHeight] == ([1600, 900, 3200, 1800] as [Int]))
        #expect(retina.flags.contains(.main))
        let standard = layout.screens[1]
        #expect([standard.pixelLeft, standard.pixelTop, standard.pixelWidth, standard.pixelHeight] == ([3200, 0, 1280, 800] as [Int]))
        #expect(standard.pointLeft == 1600)
    }

    @Test func virtualDisplayAtLoginWindow() throws {
        let payload = ServerBytes.layout(
            framebuffer: (2880, 1800), current: nil, flags: 0x15,
            screens: [.init(id: 9, density: 2, points: (0, 0, 900, 1440), pixels: (0, 0, 1800, 2880), flags: 0x5)]
        )
        var reader = WireReader(payload)
        let layout = try DisplayLayout.parse(&reader)
        #expect(layout.flags.contains(.onVirtualDisplay))
        #expect(layout.flags.contains(.loginWindow))
        #expect(layout.screens[0].flags.contains(.dynamicVirtual))
    }

    @Test func derivesDensityWhenMacStatesNone() throws {
        let payload = ServerBytes.layout(
            framebuffer: (1440, 900), current: 3, flags: 0x4,
            screens: [.init(id: 3, density: 0, scale: 0.5, points: (0, 0, 900, 1440), pixels: (0, 0, 900, 1440))]
        )
        var reader = WireReader(payload)
        let layout = try DisplayLayout.parse(&reader)
        #expect(layout.currentScreen == 3)
        #expect(layout.screens[0].density == 2)
        #expect(layout.screens[0].serverScale == 0.5)
    }

    @Test func keepsFirstOfAMirrorSetAndDropsUnusableRecords() throws {
        let payload = ServerBytes.layout(
            framebuffer: (1920, 1080), current: nil, flags: 0x4,
            screens: [
                .init(id: 1, density: 1, points: (0, 0, 1080, 1920), pixels: (0, 0, 1080, 1920), flags: 0x3),
                .init(id: 2, density: 1, points: (0, 0, 1080, 1920), pixels: (0, 0, 1080, 1920), flags: 0x2),
                .init(id: 3, density: 1, points: (0, 0, 0, 0), pixels: (0, 0, 0, 0)),
                .init(id: 4, density: 9, points: (0, 1920, 100, 2020), pixels: (0, 1920, 100, 2020)),
            ]
        )
        var reader = WireReader(payload)
        let layout = try DisplayLayout.parse(&reader)
        // 4 states an impossible density but its bounds give 1, so it stays.
        #expect(layout.screens.map(\.id) == [1, 4])
        #expect(layout.screens[1].density == 1)
    }

    @Test func flagsInEitherByteOrder() throws {
        func flags(_ raw: UInt32) throws -> DisplayLayout.Flags {
            var reader = WireReader(ServerBytes.layout(
                framebuffer: (10, 10), current: nil, flags: raw,
                screens: [.init(id: 1, density: 1, points: (0, 0, 10, 10), pixels: (0, 0, 10, 10))]
            ))
            return try DisplayLayout.parse(&reader).flags
        }
        // macOS 27 writes big-endian.
        #expect(try flags(0x5) == [.onVirtualDisplay, .onConsole])
        // A release that wrote them little-endian.
        #expect(try flags(0x0500_0000) == [.onVirtualDisplay, .onConsole])
        #expect(try flags(0x1000_0000) == [.loginWindow])
        // A plausible big-endian reading is never reinterpreted, unknown high bits included.
        #expect(try flags(0x0000_0115).rawValue == 0x115)
        #expect(try flags(0x0100_0001).rawValue == 0x0100_0001)
    }

    @Test func negativeEdgesAreSigned() throws {
        let payload = ServerBytes.layout(
            framebuffer: (1000, 1000), current: nil, flags: 0x4,
            screens: [.init(id: 1, density: 1, points: (-500, -1000, 500, 0), pixels: (0, 0, 1000, 1000))]
        )
        var reader = WireReader(payload)
        let screen = try DisplayLayout.parse(&reader).screens[0]
        #expect([screen.pointLeft, screen.pointTop, screen.pointWidth, screen.pointHeight] == ([-1000, -500, 1000, 1000] as [Int]))
    }

    @Test func rejectsBadCountsAndSizes() {
        func parse(_ data: Data) throws -> DisplayLayout {
            var reader = WireReader(data)
            return try DisplayLayout.parse(&reader)
        }
        let one = ServerBytes.Screen(id: 1, density: 1, points: (0, 0, 10, 10), pixels: (0, 0, 10, 10))
        #expect(throws: WireError.self) { try parse(Data(count: 10)) }
        #expect(throws: WireError.self) { try parse(ServerBytes.layout(framebuffer: (10, 10), current: nil, flags: 0, screens: [])) }
        #expect(throws: WireError.self) { try parse(ServerBytes.layout(framebuffer: (10, 10), current: nil, flags: 0, screens: [one], declaredCount: 26)) }
        #expect(throws: WireError.self) { try parse(ServerBytes.layout(framebuffer: (10, 10), current: nil, flags: 0, screens: [one], declaredCount: 2)) }
        #expect(throws: WireError.self) { try parse(ServerBytes.layout(framebuffer: (0, 10), current: nil, flags: 0, screens: [one])) }
        let unusable = ServerBytes.Screen(id: 1, density: 1, points: (0, 0, 0, 0), pixels: (0, 0, 0, 0))
        #expect(throws: WireError.malformed("display layout lists no usable screen")) {
            try parse(ServerBytes.layout(framebuffer: (10, 10), current: nil, flags: 0, screens: [unusable]))
        }
    }
}

@Suite struct CompressionTests {
    /// Deflates `chunks` as one zlib stream with a sync flush after each, as an RFB server does.
    static func deflateStream(_ chunks: [Data]) -> [Data] {
        var stream = z_stream()
        deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        defer { deflateEnd(&stream) }
        return chunks.map { chunk in
            var output = Data(count: Int(deflateBound(&stream, uLong(chunk.count))) + 64)
            let capacity = output.count
            let produced: Int = output.withUnsafeMutableBytes { out in
                chunk.withUnsafeBytes { input in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(input.count)
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    deflate(&stream, Z_SYNC_FLUSH)
                    return capacity - Int(stream.avail_out)
                }
            }
            return output.prefix(produced)
        }
    }

    @Test func persistentStreamDecodesChunksThatShareHistory() throws {
        let first = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 / 7) })
        // The second chunk repeats the first, so it compresses to back-references into it.
        let chunks = Self.deflateStream([first, first, Data("tail".utf8)])
        #expect(chunks[1].count < chunks[0].count / 2)
        let inflater = InflateStream()
        #expect(try inflater.inflate(chunks[0], expecting: first.count) == first)
        #expect(try inflater.inflate(chunks[1], expecting: first.count) == first)
        #expect(try inflater.inflate(chunks[2], limit: 100) == Data("tail".utf8))
    }

    @Test func wrongExpectedSizeIsReported() throws {
        let chunk = Self.deflateStream([Data(count: 1000)])[0]
        #expect(throws: CompressionError.tooShort(expected: 2000, actual: 1000)) {
            _ = try InflateStream().inflate(chunk, expecting: 2000)
        }
    }

    @Test func limitStopsADecompressionBomb() {
        let bomb = Deflate.compress(Data(count: 50 << 20))
        #expect(bomb.count < 100_000)
        #expect(throws: CompressionError.tooLarge(limit: 1 << 20)) {
            _ = try InflateStream.inflateWhole(bomb, limit: 1 << 20)
        }
    }

    @Test func corruptInputThrowsAndStreamRecoversAfterReset() throws {
        let inflater = InflateStream()
        #expect(throws: CompressionError.self) { _ = try inflater.inflate(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), limit: 100) }
        // After a failure the stream starts over, so a fresh zlib stream decodes.
        #expect(try inflater.inflate(Deflate.compress(Data("ok".utf8)), limit: 100) == Data("ok".utf8))
    }

    @Test func wholeStreamRoundTrip() throws {
        var generator = SeededGenerator(seed: 1)
        let data = Data((0..<100_000).map { _ in UInt8.random(in: 0...3, using: &generator) })
        #expect(try InflateStream.inflateWhole(Deflate.compress(data), limit: 200_000) == data)
        #expect(try InflateStream.inflateWhole(Deflate.compress(Data()), limit: 10) == Data())
    }
}
