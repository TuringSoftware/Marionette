// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

@testable import ARDProtocol
import ARDTestSupport
import Foundation
import Testing

/// Damages a valid message as a broken or hostile peer would.
private func mutate(_ data: Data, using generator: inout SeededGenerator) -> Data {
    var bytes = [UInt8](data)
    for _ in 0..<Int.random(in: 1...6, using: &generator) {
        guard !bytes.isEmpty else { break }
        let index = Int.random(in: 0..<bytes.count, using: &generator)
        switch Int.random(in: 0..<5, using: &generator) {
        case 0: bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        case 1: bytes.remove(at: index)
        case 2: bytes.insert(UInt8.random(in: .min ... .max, using: &generator), at: index)
        case 3: bytes.removeSubrange(index...)
        default:
            // A length field at its largest.
            for offset in index..<min(bytes.count, index + Int.random(in: 2...4, using: &generator)) { bytes[offset] = 0xff }
        }
    }
    return Data(bytes)
}

/// Runs `parse` over many mutations of each sample; every one must return or throw, never trap.
private func survives(_ samples: [Data], rounds: Int = 2000, seed: UInt64, _ parse: (Data) -> Void) {
    var generator = SeededGenerator(seed: seed)
    for sample in samples {
        parse(sample)
        for _ in 0..<rounds { parse(mutate(sample, using: &generator)) }
    }
}

@Suite struct HostileInputTests {
    // MARK: Claims of size

    /// A zlib header may claim any size; what is allocated follows what actually inflates.
    @Test func anInflaterDoesNotBelieveTheClaimedSize() throws {
        let stream = InflateStream()
        let chunk = Deflate.compressSyncFlushed(Data(repeating: 7, count: 100))
        let claimed = 65535 * 65535 * 4
        #expect(throws: CompressionError.self) { _ = try stream.inflate(chunk, expecting: claimed) }
        let fresh = InflateStream()
        #expect(try fresh.inflate(Deflate.compressSyncFlushed(Data(repeating: 7, count: 100)), expecting: 100) == Data(repeating: 7, count: 100))
    }

    @Test func aLayoutCannotAskForAnEnormousFramebuffer() {
        let giant = ServerBytes.layout(
            framebuffer: (65535, 65535), current: nil, flags: 0x4,
            screens: [.init(id: 1, density: 1, points: (0, 0, 2000, 2000), pixels: (0, 0, 2000, 2000), flags: 0x1)]
        )
        var reader = WireReader(giant)
        #expect(throws: WireError.self) { _ = try DisplayLayout.parse(&reader) }
        // Three 6K displays side by side still fit.
        let wide = ServerBytes.layout(
            framebuffer: (18048, 3384), current: nil, flags: 0x4,
            screens: [.init(id: 1, density: 2, points: (0, 0, 1692, 9024), pixels: (0, 0, 3384, 18048), flags: 0x1)]
        )
        var wideReader = WireReader(wide)
        #expect((try? DisplayLayout.parse(&wideReader)) != nil)
    }

    // MARK: Mutation

    @Test func handshakeParsersSurviveDamage() {
        survives([Data("RFB 003.889\n".utf8), Data("RFB 003.008\n".utf8)], seed: 1) { data in
            var reader = WireReader(data)
            _ = try? ProtocolVersion.parse(&reader)
        }
        survives([Data([4, 30, 33, 36, 35]), Data([0, 0, 0, 0, 5]) + Data("Nope.".utf8)], seed: 2) { data in
            var reader = WireReader(data)
            _ = try? SecurityOffer.parse(&reader)
        }
        var serverInit = Data([0x08, 0x00, 0x06, 0x00, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        let name = Data([0, 0, 0, 0, 0x52]) + Data([0xbf, 0xf6, 0xe7, 0x2f, 0xec]) + Data(count: 11) + Data("Mac".utf8)
        serverInit.append(contentsOf: [0, 0, 0, UInt8(name.count)])
        serverInit.append(name)
        survives([serverInit], seed: 3) { data in
            var reader = WireReader(data)
            _ = try? ServerInit.parse(&reader, extended: true)
        }
    }

    @Test func layoutsSurviveDamage() {
        survives([ServerMessageParserTests.layoutPayload], rounds: 4000, seed: 4) { data in
            var reader = WireReader(data)
            if let layout = try? DisplayLayout.parse(&reader) {
                #expect(layout.framebufferWidth * layout.framebufferHeight <= DisplayLayout.maximumFramebufferPixels)
                #expect(!layout.screens.isEmpty)
            }
        }
    }

    @Test func mediaRepliesAndPacketsSurviveDamage() {
        let ports = Data(hex: "0001 0001 00000000  170c 00000001  170d 00000001  170e 00000000  00000000000000000000")
        survives([ports], seed: 5) { data in _ = try? MediaReply.parse(data) }
        var packet = Data([0x90, 0xe4, 0x12, 0x34, 0, 0, 0x10, 0, 0, 0, 0, 7, 0x93, 0x31, 0, 1, 0, 3, 0, 1])
        packet.append(Data(repeating: 0x55, count: 40))
        survives([packet, Data([0xa0, 100, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 2, 3, 4])], seed: 6) { data in
            _ = MediaPacketKind.classify(data)
            _ = RTCPMessage.leading(data)
            _ = RTCPMessage.senderReportTime(data)
            if let parsed = try? RTPPacket.parse(data) {
                #expect(parsed.payload.count <= data.count)
            }
        }
    }

    @Test func inflatingDamagedStreamsFailsCleanly() {
        let original = Deflate.compressSyncFlushed(Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<1500 {
            let damaged = mutate(original, using: &generator)
            let stream = InflateStream()
            if let output = try? stream.inflate(damaged, limit: 1 << 20) { #expect(output.count <= 1 << 20) }
            _ = try? InflateStream().inflate(damaged, expecting: Int.random(in: 0...(1 << 22), using: &generator))
            _ = try? InflateStream.inflateWhole(damaged, limit: 1 << 20)
        }
    }

    @Test func cursorShapesSurviveDamageAndAnySize() {
        var cache = CursorCache()
        var pixels = Data(count: 32 * 32 * 4)
        pixels.append(Data(repeating: 0xff, count: 32 * 32))
        let shape = Deflate.compress(pixels)
        var generator = SeededGenerator(seed: 8)
        for round in 0..<3000 {
            let width = UInt16.random(in: 0...UInt16.max, using: &generator)
            let height = UInt16.random(in: 0...UInt16.max, using: &generator)
            let deflated = round % 3 == 0 ? shape : mutate(shape, using: &generator)
            let update = cache.apply(cacheID: UInt32(round % 300), hotspotX: 0, hotspotY: 0, width: round % 2 == 0 ? 32 : width, height: round % 2 == 0 ? 32 : height, deflated: deflated)
            if case .shape(let image) = update {
                #expect(image.bgraPixels.count == image.pixelSize.width * image.pixelSize.height * 4)
            }
        }
    }

    @Test func sessionSelectSurvivesDamage() {
        let samples = [
            Data(SessionSelectTests.offer), Data(SessionSelectTests.accepted), Data(SessionSelectTests.declined),
            Data(SessionSelectTests.askAnswer),
            SessionSelectAnswer(command: .logInAsSelf, viewerName: "x", sealedCredentials: Data(count: 128)).encoded,
        ]
        survives(samples, seed: 9) { data in
            var reader = WireReader(data)
            _ = try? SessionSelectOffer.parse(&reader)
            reader = WireReader(data)
            _ = try? SessionSelectResult.parse(&reader)
            reader = WireReader(data)
            _ = try? SessionSelectAnswer.parse(&reader)
        }
    }

    @Test func fileTransferMessagesSurviveDamage() throws {
        var samples: [Data] = []
        for name in ["upload-folder-from-viewer", "download-file-from-mac", "drag-from-mac", "drop-destination", "received-from-mac", "download-folder-with-links"] {
            samples.append(Data(try FileTransferTests.fixture(name).prefix(600)))
        }
        survives(samples, rounds: 3000, seed: 10) { data in
            var reader = WireReader(data)
            _ = try? FileTransferMessage.parse(&reader)
            reader = WireReader(data)
            _ = try? DragPasteboard.parse(&reader)
            reader = WireReader(data)
            _ = try? DropDestination.parse(&reader)
            var receiver = FileTransferReceiver()
            reader = WireReader(data)
            while let message = try? FileTransferMessage.parse(&reader) {
                guard (try? receiver.receive(message.body)) != nil else { break }
            }
        }
    }
}
