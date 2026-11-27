// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
@testable import AppleScreenSharing
import Foundation
import RemoteDesktopCore
import SwiftSRTP
import Synchronization
import Testing

/// A datagram flow the test stands at the far end of.
final class FakeChannel: DatagramChannel, @unchecked Sendable {
    let localPort: UInt16
    private let lock = NSLock()
    private var onReceive: (@Sendable (Datagram) -> Void)?
    private var sentPackets: [(payload: Data, at: ContinuousClock.Instant)] = []

    init(port: UInt16) {
        localPort = port
    }

    func start(onReceive: @escaping @Sendable (Datagram) -> Void, onClose: @escaping @Sendable (TransportError?) -> Void) {
        lock.withLock { self.onReceive = onReceive }
    }

    func send(_ payload: Data) {
        lock.withLock { sentPackets.append((payload, .now)) }
    }

    func close() {}

    var sent: [Data] { lock.withLock { sentPackets.map(\.payload) } }
    var sentWithTimes: [(payload: Data, at: ContinuousClock.Instant)] { lock.withLock { sentPackets } }

    func arrive(_ payload: Data) {
        let handler = lock.withLock { onReceive }
        handler?(Datagram(payload: payload, receivedAt: .now))
    }
}

final class FakeTransport: TransportProvider {
    let peer = Endpoint(host: "mac.test", port: 5900)
    let isTunnelled = false
    let supportsDatagrams = true
    let channels = Mutex<[UInt16: FakeChannel]>([:])

    func openStream(port: UInt16) async throws -> any ByteStream { throw TransportError.closed }

    func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel {
        let channel = FakeChannel(port: options.localPort ?? 0)
        channels.withLock { $0[options.remotePort] = channel }
        return channel
    }
}

func key(_ seed: UInt8) -> MediaKey {
    MediaKey(bytes: Data((0..<46).map { seed &+ UInt8($0) }))
}

/// A two-byte HEVC NAL header of the given type, then `size` bytes of body.
private func nal(_ type: UInt8, size: Int = 6) -> Data {
    Data([type << 1, 0x01]) + Data(repeating: type, count: size)
}

/// What the receiver reported, in order.
final class EventLog: Sendable {
    let entries = Mutex<[String]>([])
    let units = Mutex<[AccessUnit]>([])
    let audio = Mutex<[UInt32]>([])
    /// The receiver, for the handler to acknowledge pictures as a decoder would.
    let receiver = Mutex<MediaStreamReceiver?>(nil)
    /// Holds the handler on its first picture, as a slow decoder would.
    let stall = Mutex<Duration?>(nil)
}

/// The Mac's end of one picture leg: it sends protected pictures and reads the viewer's requests.
final class FakeMac {
    static let viewerSSRC: UInt32 = 0x3333_4444
    static let mediaSSRC: UInt32 = 0x0BAD_CAFE
    static let offer = MediaOffer(
        sessionID: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
        flags: [.omitCursor],
        audioSSRC: 0x1111_2222,
        audioKeys: MediaLegKeys(viewerToServer: key(1), serverToViewer: key(60)),
        videos: [
            .init(ssrc: viewerSSRC, keys: MediaLegKeys(viewerToServer: key(120), serverToViewer: key(180)), width: 1280, height: 800, codec: .hevc, tilesPerFrame: 1),
        ]
    )

    let transport = FakeTransport()
    let receiver: MediaStreamReceiver
    let log = EventLog()
    var units: [AccessUnit] { log.units.withLock { $0 } }
    var events: [String] { log.entries.withLock { $0 } }
    private var outbound: SRTPSession
    private var inbound: SRTPSession
    /// Separate sessions for what only some tests look at, so reading reports here does not
    /// disturb the replay window `requests()` reads through.
    private var reportsOutbound: SRTPSession
    private var reportsInbound: SRTPSession
    private let audioOutbound: SRTPSession
    private let audioInbound: SRTPSession
    /// The SSRC the Mac sends pictures under: a new one for every offer.
    var mediaSSRC = FakeMac.mediaSSRC
    var sequence: UInt16 = 100
    private var timestamp: UInt32 = 9000
    private var audioSequence: UInt16 = 7000
    private var read = 0

    /// Restart requests are timed against the Mac's one-second rule; tests shorten it to stay quick.
    static var quick: MediaStreamReceiver.Timing {
        var timing = MediaStreamReceiver.Timing()
        timing.serverGap = .milliseconds(150)
        timing.repeatInterval = .milliseconds(100)
        return timing
    }

    /// - Parameter decodes: Acknowledge each picture delivered, as a viewer does once it decoded.
    init(timing: MediaStreamReceiver.Timing = FakeMac.quick, decodes: Bool = true, acknowledgesOnAssembly: Bool = false) async throws {
        let log = log
        receiver = try await MediaStreamReceiver(
            transport: transport, ports: .init(audio: 5900, video: [5901]), offer: Self.offer, timing: timing,
            acknowledgesOnAssembly: acknowledgesOnAssembly
        ) { event in
            switch event {
            case .picture(let leg, let unit, _):
                if let pause = log.stall.withLock({ value -> Duration? in
                    defer { value = nil }
                    return value
                }) {
                    Thread.sleep(forTimeInterval: Double(pause.components.seconds) + Double(pause.components.attoseconds) / 1e18)
                }
                log.units.withLock { $0.append(unit) }
                log.entries.withLock { $0.append("\(unit.isKeyframe ? "keyframe" : unit.isRefresh ? "refresh" : "picture") \(unit.timestamp)") }
                if decodes { log.receiver.withLock { $0 }?.acknowledge(leg: leg, ssrc: unit.ssrc, timestamp: unit.timestamp) }
            case .pictureLoss: log.entries.withLock { $0.append("loss") }
            case .failed: log.entries.withLock { $0.append("failed") }
            case .audio(_, let timestamp, _): log.audio.withLock { $0.append(timestamp) }
            }
        }
        outbound = try SRTPSession(direction: .outbound, masterKey: key(180).bytes)
        inbound = try SRTPSession(direction: .inbound, masterKey: key(120).bytes)
        reportsOutbound = outbound
        reportsInbound = try SRTPSession(direction: .inbound, masterKey: key(120).bytes)
        audioOutbound = try SRTPSession(direction: .outbound, masterKey: key(60).bytes)
        audioInbound = try SRTPSession(direction: .inbound, masterKey: key(1).bytes)
        log.receiver.withLock { [receiver] in $0 = receiver }
        receiver.start()
    }

    var channel: FakeChannel { transport.channels.withLock { $0[5901]! } }
    var audioChannel: FakeChannel { transport.channels.withLock { $0[5900]! } }

    /// The Mac's side of a new offer with new keys for the picture leg: it sends under a new SSRC.
    func takeUp(_ offer: MediaOffer, newSSRC: UInt32) throws {
        outbound = try SRTPSession(direction: .outbound, masterKey: offer.videos[0].keys.serverToViewer.bytes)
        inbound = try SRTPSession(direction: .inbound, masterKey: offer.videos[0].keys.viewerToServer.bytes)
        reportsOutbound = outbound
        reportsInbound = try SRTPSession(direction: .inbound, masterKey: offer.videos[0].keys.viewerToServer.bytes)
        mediaSSRC = newSSRC
        read = channel.sent.count
    }

    /// Numbers `count` packets that never reach the viewer, as a Mac does while the viewer's
    /// sockets are suspended. (The Mac's own SRTP follows its numbering in steps it can track.)
    func skipAhead(_ count: Int) {
        var left = count
        while left > 0 {
            let step = min(left, 16_000)
            sequence &+= UInt16(step)
            left -= step
            var packet = Data([0x80, 100, UInt8(sequence >> 8), UInt8(sequence & 0xff), 0, 0, 0, 0])
            for value in [mediaSSRC] {
                packet.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
            }
            packet.append(Data(repeating: 0, count: 8))
            _ = try! outbound.protect(packet)
        }
        sequence &+= 1
    }

    /// Lets the receiver's queues and holds catch up with what was sent.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(40))
        receiver.waitUntilIdle()
    }

    /// One frame of sound, protected, of the given payload type.
    func audioPacket(payloadType: UInt8 = 101, sequence: UInt16? = nil) -> Data {
        let number = sequence ?? audioSequence
        if sequence == nil { audioSequence &+= 1 }
        var packet = Data([0x80, payloadType, UInt8(number >> 8), UInt8(number & 0xff)])
        for value in [UInt32(number) * 480, UInt32(0x5150_5150)] {
            packet.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
        }
        packet.append(Data([0x01, 0x40, 0x20, 0x00]))
        return try! audioOutbound.protect(packet)
    }

    func audioReports() -> [Data] {
        audioChannel.sent.compactMap { try? audioInbound.unprotectRTCP($0) }
    }

    /// The packets of one picture, numbered on from the last. `refresh` and the acknowledgement
    /// mark ride in the header extension, as a Mac sends them.
    func picture(keyframe: Bool = false, refresh: Bool = false, fragments: Int = 6) -> [Data] {
        timestamp &+= 400
        var payloads: [Data] = []
        if keyframe {
            var parameters = Data([48 << 1, 0x01])
            for unit in [nal(32), nal(33), nal(34)] {
                parameters.append(contentsOf: [0, UInt8(unit.count)])
                parameters.append(unit)
            }
            payloads.append(parameters)
        }
        let type: UInt8 = keyframe ? 19 : 1
        for index in 0..<fragments {
            var header = type
            if index == 0 { header |= 0x80 }
            if index == fragments - 1 { header |= 0x40 }
            payloads.append(Data([49 << 1, 0x01, header]) + Data(repeating: UInt8(index), count: 900))
        }
        return payloads.enumerated().map { index, payload in
            var packet = Data([0x90, (index == payloads.count - 1 ? 0x80 : 0) | 100])
            packet.append(contentsOf: [UInt8(sequence >> 8), UInt8(sequence & 0xff)])
            for value in [timestamp, mediaSSRC] {
                packet.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
            }
            // The Mac's fields: the acknowledgement and refresh marks, and the picture's packet count.
            let profile: UInt16 = 0x9301 | 0x0010 | (refresh ? 0x0020 : 0)
            packet.append(contentsOf: [UInt8(profile >> 8), UInt8(profile & 0xff), 0, 1, 0, UInt8(payloads.count), 0, 1])
            packet.append(payload)
            sequence &+= 1
            return try! outbound.protect(packet)
        }
    }

    var currentTimestamp: UInt32 { timestamp }

    /// One picture's payloads as protected RTP packets of `payloadType`, numbered on from the last,
    /// the marker on the last. No header extension: a Mac's H.264 asks for no acknowledgement.
    func packets(_ payloads: [Data], payloadType: UInt8, timestampStep: UInt32 = 400) -> [Data] {
        timestamp &+= timestampStep
        return payloads.enumerated().map { index, payload in
            var packet = Data([0x80, (index == payloads.count - 1 ? 0x80 : 0) | payloadType])
            packet.append(contentsOf: [UInt8(sequence >> 8), UInt8(sequence & 0xff)])
            for value in [timestamp, mediaSSRC] {
                packet.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
            }
            packet.append(payload)
            sequence &+= 1
            return try! outbound.protect(packet)
        }
    }

    func send(_ packets: [Data]) {
        for packet in packets { channel.arrive(packet) }
    }

    /// What the viewer has sent since the last call, decrypted and named.
    func requests() -> [String] {
        timedRequests().map(\.name)
    }

    func timedRequests() -> [(name: String, at: ContinuousClock.Instant)] {
        let all = channel.sentWithTimes
        defer { read = all.count }
        return all[read...].compactMap { sent -> (name: String, at: ContinuousClock.Instant)? in
            Self.describe(sent.payload, inbound: inbound).map { ($0, sent.at) }
        }
    }

    private static func describe(_ protected: Data, inbound: SRTPSession) -> String? {
        guard let clear = try? inbound.unprotectRTCP(protected), clear.count >= 8 else { return "unreadable" }
        let format = clear[clear.startIndex] & 0x1f
        switch (clear[clear.startIndex + 1], format) {
        case (201, _): return nil // receiver report
        case _ where clear.count < 12: return "short rtcp"
        case (204, _):
            let name = clear[(clear.startIndex + 8)..<(clear.startIndex + 12)]
            if name == Data("RCTL".utf8) { return nil }
            let picture = clear.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return "ack \(picture)"
        case (206, 1): return "keyframe request"
        case (206, 2):
            let size = clear.suffix(4)
            let width = Int(size[size.startIndex]) << 8 | Int(size[size.startIndex + 1])
            let height = Int(size[size.startIndex + 2]) << 8 | Int(size[size.startIndex + 3])
            return "refresh request \(width)x\(height)"
        case let (type, format): return "rtcp \(type)/\(format)"
        }
    }

    /// Waits for the viewer's next requests that are not acknowledgements.
    func nextRequests(_ what: String, timeout: Duration = .seconds(2)) async -> [String] {
        var found: [String] = []
        await until(what, timeout: timeout) {
            found += requests().filter { !$0.hasPrefix("ack") }
            return !found.isEmpty
        }
        return found
    }

    /// Sends the viewer a sender report, as the Mac does once a second.
    func sendSenderReport(ntpSeconds: UInt32, ntpFraction: UInt32) {
        var packet = Data([0x80, 200, 0, 6])
        for value in [mediaSSRC, ntpSeconds, ntpFraction, timestamp, 10, 10_000] {
            packet.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
        }
        channel.arrive(try! reportsOutbound.protectRTCP(packet))
    }

    /// The report blocks of the receiver reports the viewer has sent, as 32-bit words after the block's SSRC.
    func receptionReports() -> [[UInt32]] {
        channel.sent.compactMap { protected in
            guard let clear = try? reportsInbound.unprotectRTCP(protected), clear.count == 32, clear[clear.startIndex + 1] == 201 else { return nil }
            return stride(from: 8, to: 32, by: 4).map { offset in
                clear[(clear.startIndex + offset)..<(clear.startIndex + offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            }
        }
    }

    var lastSequence: UInt16 { sequence &- 1 }
}

@Suite struct MediaStreamReceiverTests {
    @Test func picturesAreDeliveredInOrderAndEachIsAcknowledgedOnceDecoded() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        mac.send(mac.picture(keyframe: true))
        let first = mac.currentTimestamp
        mac.send(mac.picture())
        mac.send(mac.picture())
        await mac.settle()
        #expect(mac.events == ["keyframe \(first)", "picture \(first + 400)", "picture \(first + 800)"])
        #expect(mac.requests() == ["ack \(first)", "ack \(first + 400)", "ack \(first + 800)"])
        let statistics = mac.receiver.videoStatistics(leg: 0)
        #expect(statistics.packets == 19)
        #expect(statistics.expectedPackets == 19)
        #expect(statistics.pictures == 3)
        #expect(statistics.keyframes == 1)
        #expect(statistics.losses == 0)
    }

    /// A Mac predicts a refresh picture from an acknowledged one, so only pictures the decoder
    /// really holds may be acknowledged: none just for arriving whole.
    @Test func aPictureThatIsNotDecodedIsNotAcknowledged() async throws {
        let mac = try await FakeMac(decodes: false)
        defer { mac.receiver.stop() }
        mac.send(mac.picture(keyframe: true))
        mac.send(mac.picture())
        await mac.settle()
        #expect(mac.events.count == 2)
        #expect(mac.requests().isEmpty)
        // With nothing acknowledged, a loss can only be mended by a keyframe.
        var broken = mac.picture(fragments: 8)
        broken.remove(at: 1)
        mac.send(broken)
        #expect(await mac.nextRequests("the request").allSatisfy { $0 == "keyframe request" })
    }

    @Test func aToolThatDoesNotDecodeMayHavePicturesAcknowledgedWhole() async throws {
        let mac = try await FakeMac(decodes: false, acknowledgesOnAssembly: true)
        defer { mac.receiver.stop() }
        mac.send(mac.picture(keyframe: true))
        await mac.settle()
        #expect(mac.requests() == ["ack \(mac.currentTimestamp)"])
    }

    @Test func picturesBeforeTheFirstKeyframeAreNotDelivered() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        mac.send(mac.picture())
        mac.send(mac.picture())
        await mac.settle()
        #expect(mac.events.isEmpty)
        // With nothing to start from, the timer asks for a keyframe; no picture is acknowledged.
        var requests: [String] = []
        await until("a keyframe request", timeout: .seconds(1)) {
            requests += mac.requests()
            return !requests.isEmpty
        }
        // One, or on a busy machine the repeats that went out before this looked.
        #expect(!requests.isEmpty && requests.allSatisfy { $0 == "keyframe request" })
    }

    @Test func packetsThatOvertookEachOtherStillMakeTheirPicture() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        var keyframe = mac.picture(keyframe: true)
        let first = mac.currentTimestamp
        // The stream's very first packet overtaken, and others well out of place.
        keyframe.swapAt(0, 1)
        keyframe.swapAt(2, 5)
        keyframe.swapAt(5, 6)
        mac.send(keyframe)
        var next = mac.picture()
        next.swapAt(0, 4)
        mac.send(next)
        await mac.settle()
        #expect(mac.events == ["keyframe \(first)", "picture \(first + 400)"])
        #expect(mac.requests() == ["ack \(first)", "ack \(first + 400)"])
        #expect(mac.receiver.videoStatistics(leg: 0).losses == 0)
    }

    @Test func aBrokenFirstKeyframeIsAskedForAgainAsAKeyframe() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        var keyframe = mac.picture(keyframe: true)
        keyframe.remove(at: 3)
        mac.send(keyframe)
        // Nothing has been acknowledged, so only a keyframe can start the stream. A stream that has
        // not started has lost nothing worth an event; the timer asks for the keyframe.
        mac.send(mac.picture())
        await mac.settle()
        #expect(mac.events.isEmpty)
        var requests: [String] = []
        await until("a keyframe request", timeout: .seconds(1)) {
            requests += mac.requests()
            return !requests.isEmpty
        }
        // One, or on a busy machine the repeats that went out before this looked.
        #expect(!requests.isEmpty && requests.allSatisfy { $0 == "keyframe request" })

        mac.send(mac.picture(keyframe: true))
        let restart = mac.currentTimestamp
        mac.send(mac.picture())
        await mac.settle()
        #expect(mac.events == ["keyframe \(restart)", "picture \(restart + 400)"])
        #expect(mac.requests().filter { $0.hasPrefix("ack") } == ["ack \(restart)", "ack \(restart + 400)"])
    }

    @Test func aLossAfterAnAcknowledgedPictureIsMendedByARefresh() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        mac.send(mac.picture(keyframe: true))
        let first = mac.currentTimestamp
        await mac.settle()
        var broken = mac.picture(fragments: 8)
        broken.remove(at: 1)
        mac.send(broken)
        await mac.settle()
        #expect(mac.events == ["keyframe \(first)", "loss"])
        #expect(mac.requests().filter { $0.hasPrefix("ack") } == ["ack \(first)"])
        // The request waits until the Mac will read it, then goes out.
        #expect(await mac.nextRequests("the refresh request").allSatisfy { $0 == "refresh request 1280x800" })

        // Pictures predicted from the broken one are of no use; they are not delivered or acknowledged.
        mac.send(mac.picture())
        mac.send(mac.picture())
        await mac.settle()
        #expect(mac.events.count == 2)
        #expect(mac.requests().allSatisfy { $0 == "refresh request 1280x800" })

        mac.send(mac.picture(refresh: true))
        let refresh = mac.currentTimestamp
        mac.send(mac.picture())
        await mac.settle()
        #expect(mac.events.suffix(2) == ["refresh \(refresh)", "picture \(refresh + 400)"])
        #expect(mac.requests().filter { $0.hasPrefix("ack") } == ["ack \(refresh)", "ack \(refresh + 400)"])
        let statistics = mac.receiver.videoStatistics(leg: 0)
        #expect(statistics.losses == 1)
        #expect(statistics.expectedPackets == statistics.packets + 1)
    }

    /// A decoder that dropped one picture still holds the ones before it, so a refresh mends it.
    @Test func aSkippedPictureIsMendedByARefresh() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        mac.send(mac.picture(keyframe: true))
        mac.send(mac.picture())
        await mac.settle()
        _ = mac.requests()
        mac.receiver.requestRefresh(leg: 0)
        #expect(await mac.nextRequests("the refresh request").allSatisfy { $0 == "refresh request 1280x800" })
        mac.send(mac.picture())
        await mac.settle()
        #expect(mac.events.count == 2)
        mac.send(mac.picture(refresh: true))
        await mac.settle()
        #expect(mac.events.last == "refresh \(mac.currentTimestamp)")
    }

    /// The case a reorder buffer could hide: the loss is near the end of a picture and the screen
    /// then stays still, so no later packet arrives to show the gap.
    @Test func aLossJustBeforeAStillScreenIsNoticedWithoutMorePackets() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        mac.send(mac.picture(keyframe: true))
        var last = mac.picture(fragments: 6)
        last.remove(at: 4)
        mac.send(last)
        // Only the picture's final packet is behind the gap, and nothing follows it.
        await until("the loss to be noticed", timeout: .seconds(1)) { mac.events.last == "loss" }
        #expect(await mac.nextRequests("the refresh request").contains("refresh request 1280x800"))
    }

    @Test func aRequestIsRepeatedUntilThePictureComes() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        var keyframe = mac.picture(keyframe: true)
        keyframe.remove(at: 2)
        let streamBegan = ContinuousClock.now
        mac.send(keyframe)
        mac.send(mac.picture())
        // One request may be lost on the way, so it is repeated: here first 150 ms into the stream
        // and then every 100 ms.
        var requests: [(name: String, at: ContinuousClock.Instant)] = []
        await until("four requests", timeout: .seconds(5)) {
            requests += mac.timedRequests()
            return requests.count >= 4
        }
        #expect(requests.allSatisfy { $0.name == "keyframe request" })
        // Never sooner than that. A request is timed as it is sent, after the receiver decided on
        // it, and a busy machine can hold one send back until the next is nearly due; but a late
        // send only comes later, so each request is held against the start of the stream.
        for (index, request) in requests.enumerated() {
            let earliest = Duration.milliseconds(150 + 100 * index)
            #expect(request.at - streamBegan >= earliest, "request \(index + 1) after \(request.at - streamBegan)")
        }

        mac.send(mac.picture(keyframe: true))
        await mac.settle()
        _ = mac.requests()
        try await Task.sleep(for: .milliseconds(400))
        #expect(mac.requests().allSatisfy { $0.hasPrefix("ack") })
    }

    /// A decoder that fails cannot use a refresh picture, which builds on pictures it no longer
    /// has; once pictures have been acknowledged only a full keyframe will do.
    @Test func aDecoderThatMustStartOverGetsAFullKeyframeAndNothingBeforeIt() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        mac.send(mac.picture(keyframe: true))
        mac.send(mac.picture())
        await mac.settle()
        _ = mac.requests()
        let before = mac.events.count

        mac.receiver.requestKeyframe(leg: 0)
        #expect(await mac.nextRequests("the keyframe request").allSatisfy { $0 == "keyframe request" })
        mac.send(mac.picture())
        mac.send(mac.picture(refresh: true))
        await mac.settle()
        #expect(mac.events.count == before)
        #expect(mac.requests().allSatisfy { $0 == "keyframe request" })
        try await Task.sleep(for: .milliseconds(350))
        let repeats = mac.requests()
        #expect(!repeats.isEmpty && repeats.allSatisfy { $0 == "keyframe request" })

        mac.send(mac.picture(keyframe: true))
        let restart = mac.currentTimestamp
        await mac.settle()
        #expect(mac.events.last == "keyframe \(restart)")
        #expect(mac.requests().filter { $0.hasPrefix("ack") } == ["ack \(restart)"])
        // From here a loss is again mended the cheap way.
        var broken = mac.picture(fragments: 8)
        broken.remove(at: 1)
        mac.send(broken)
        #expect(await mac.nextRequests("the refresh request").allSatisfy { $0 == "refresh request 1280x800" })
    }

    /// A Mac discards a request made within a second of its last keyframe or refresh picture and
    /// never makes up for it, so with the real timing a request is held until that second is over.
    @Test func requestsWaitOutTheMacsSecond() async throws {
        let mac = try await FakeMac(timing: MediaStreamReceiver.Timing())
        defer { mac.receiver.stop() }
        let began = ContinuousClock.now
        mac.send(mac.picture(keyframe: true))
        await mac.settle()
        var broken = mac.picture(fragments: 8)
        broken.remove(at: 1)
        mac.send(broken)
        await mac.settle()
        #expect(mac.events.last == "loss")
        try await Task.sleep(until: began + .milliseconds(800))
        let early = mac.requests()
        // Only meaningful if this really looked before the second was up; a busy machine may not have.
        if ContinuousClock.now - began < .milliseconds(1000) {
            #expect(early.allSatisfy { $0.hasPrefix("ack") }, "asked while the Mac would not listen")
        }
        let requests = early.filter { !$0.hasPrefix("ack") }.isEmpty ? await mac.nextRequests("the refresh request", timeout: .seconds(2)) : early.filter { !$0.hasPrefix("ack") }
        #expect(!requests.isEmpty && requests.allSatisfy { $0 == "refresh request 1280x800" })
    }

    /// A Mac reads a report block out of every receiver report, whether one is there or not, so
    /// once pictures flow the report says what arrived and echoes the Mac's own report.
    @Test func receiverReportsSayWhatArrivedAndEchoTheSendersReport() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        var keyframe = mac.picture(keyframe: true)
        keyframe.remove(at: 5)
        keyframe.remove(at: 2)
        mac.send(keyframe)
        mac.sendSenderReport(ntpSeconds: 0xAAAA_1234, ntpFraction: 0x5678_BBBB)
        var blocks: [[UInt32]] = []
        await until("a receiver report with a block", timeout: .milliseconds(2500)) {
            blocks = mac.receptionReports()
            return blocks.contains { $0[4] != 0 }
        }
        let block = try #require(blocks.last { $0[4] != 0 })
        #expect(block[0] == FakeMac.mediaSSRC)
        // Two of seven were lost: the running total, and the fraction since the report before.
        #expect(block[1] & 0x00ff_ffff == 2)
        #expect(UInt32(mac.lastSequence) == block[2] & 0xffff)
        // The middle of the sender's clock, and how long it has been held: under three seconds, not zero.
        #expect(block[4] == 0x1234_5678)
        #expect(block[5] > 0 && block[5] < 3 * 65536)
    }

    @Test func packetsUnderAnotherKeyAreCountedAndIgnored() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        let stranger = try SRTPSession(direction: .outbound, masterKey: key(7).bytes)
        var packet = Data([0x80, 100, 0, 1, 0, 0, 0, 1, 0, 0, 0, 9])
        packet.append(Data(repeating: 1, count: 40))
        mac.channel.arrive(try stranger.protect(packet))
        mac.channel.arrive(Data([1, 2, 3]))
        // A replay of a real packet is refused as well.
        let keyframe = mac.picture(keyframe: true)
        mac.send(keyframe)
        mac.channel.arrive(keyframe[0])
        await mac.settle()
        #expect(mac.events.count == 1)
        #expect(mac.receiver.videoStatistics(leg: 0).rejected == 3)
    }

    /// A Mac sends each offer's stream under new SSRCs. A straggler of the old stream must not be
    /// taken for yet another new one, which would throw away the stream that just started.
    @Test func aStragglerOfAReplacedStreamIsTurnedAwayUnread() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        mac.send(mac.picture(keyframe: true))
        await mac.settle()
        let straggler = mac.picture()
        mac.mediaSSRC = 0x0D15_EA5E
        mac.sequence = 30_000
        mac.send(mac.picture(keyframe: true))
        let fresh = mac.currentTimestamp
        await mac.settle()
        mac.send(straggler)
        mac.send(mac.picture())
        await mac.settle()
        #expect(mac.events.suffix(2) == ["keyframe \(fresh)", "picture \(fresh + 400)"])
        let statistics = mac.receiver.videoStatistics(leg: 0)
        #expect(statistics.stalePackets == straggler.count)
        #expect(statistics.rejected == 0)
        #expect(statistics.losses == 0)
    }

    /// For a new offer with new keys: what is under way is dropped, and the new keys are taken up.
    @Test func aNewOfferStartsEveryLegAfresh() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        mac.send(mac.picture(keyframe: true))
        await mac.settle()
        var offer = FakeMac.offer
        offer.videos[0].keys = MediaLegKeys(viewerToServer: key(90), serverToViewer: key(150))
        offer.videos[0].ssrc = 0x7777_8888
        offer.videos[0].width = 2880
        offer.videos[0].height = 1800
        let late = mac.picture()
        try mac.receiver.beginStream(offer)
        try mac.takeUp(offer, newSSRC: 0x0D15_EA5E)
        // A late packet of the old stream is turned away unread.
        mac.send(late)
        mac.send(mac.picture())
        mac.send(mac.picture(keyframe: true))
        let fresh = mac.currentTimestamp
        await mac.settle()
        #expect(mac.events.last == "keyframe \(fresh)")
        #expect(mac.events.count == 2)
        #expect(mac.receiver.videoStatistics(leg: 0).stalePackets == late.count)
        // Replies go out under the new keys and the new SSRC, with the new size.
        mac.send(Array(mac.picture(fragments: 8).dropFirst(2)))
        await mac.settle()
        #expect(await mac.nextRequests("the refresh request").allSatisfy { $0 == "refresh request 2880x1800" })
    }

    /// After a spell in the background a Mac's numbering is further on than SRTP's rollover guess
    /// can follow, and reads as old. The stream carries on all the same.
    @Test func aJumpAheadOfMoreThanHalfTheNumberSpaceIsFollowed() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        mac.sequence = 60_000
        mac.send(mac.picture(keyframe: true))
        mac.send(mac.picture())
        await mac.settle()
        // 40 000 packets later, past a wrap of the numbering.
        mac.skipAhead(40_000)
        try await Task.sleep(for: .milliseconds(600))
        mac.send(mac.picture())
        mac.send(mac.picture(keyframe: true))
        let resumed = mac.currentTimestamp
        mac.send(mac.picture())
        await mac.settle()
        #expect(mac.events.suffix(3) == ["loss", "keyframe \(resumed)", "picture \(resumed + 400)"])
    }

    /// Decoding happens on the leg's own queue, so a slow decoder does not stop the socket being read.
    @Test func aSlowHandlerDoesNotHoldUpTheSocket() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        mac.log.stall.withLock { $0 = .milliseconds(300) }
        mac.send(mac.picture(keyframe: true))
        let began = ContinuousClock.now
        for _ in 0..<5 { mac.send(mac.picture()) }
        #expect(ContinuousClock.now - began < .milliseconds(150))
        await until("every picture", timeout: .seconds(2)) { mac.events.count == 6 }
    }

    @Test func soundIsPutInOrderAndOtherPayloadsAreRefused() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        let packets = (0..<6).map { _ in mac.audioPacket() }
        for index in [0, 2, 1, 3, 5, 4] { mac.audioChannel.arrive(packets[index]) }
        mac.audioChannel.arrive(mac.audioPacket(payloadType: 100))
        await mac.settle()
        let timestamps = mac.log.audio.withLock { $0 }
        #expect(timestamps == (7000..<7006).map { UInt32($0) * 480 })
        #expect(mac.receiver.audioStatistics.rejected == 1)
    }

    /// Apple's viewer sends the sound leg a receiver report with a block, then a source
    /// description with an empty name: 58 bytes protected. Without the block the Mac reads garbage.
    @Test func theSoundLegReportsLikeApplesViewer() async throws {
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        for _ in 0..<4 { mac.audioChannel.arrive(mac.audioPacket()) }
        _ = mac.audioPacket() // lost
        mac.audioChannel.arrive(mac.audioPacket())
        await until("a sound report with a block", timeout: .milliseconds(2500)) {
            mac.audioChannel.sent.contains { $0.count == 58 }
        }
        let report = try #require(mac.audioReports().last { $0.count == 44 })
        #expect(report.prefix(4) == Data([0x81, 201, 0, 7]))
        #expect(report[8..<12] == Data([0x51, 0x50, 0x51, 0x50]))
        #expect(report[13..<16] == Data([0, 0, 1])) // one lost
        #expect(report[32...] == Data([0x81, 202, 0, 2, 0x11, 0x11, 0x22, 0x22, 1, 0, 0, 0]))
    }

    @Test func nothingIsDeliveredAfterStop() async throws {
        let mac = try await FakeMac()
        mac.send(mac.picture(keyframe: true))
        await mac.settle()
        mac.receiver.stop()
        mac.send(mac.picture())
        await mac.settle()
        #expect(mac.events.count == 1)
    }
}

/// The watchdog's verdict on a picture leg, from its counters alone.
@Suite struct MediaHealthTests {
    private let start = ContinuousClock.now

    private func health(heard: Duration?, waiting: Duration? = nil, at now: Duration, epoch: Duration = .zero) -> MediaLegStatistics.Health {
        var statistics = MediaLegStatistics()
        statistics.lastAuthenticPacket = heard.map { start + $0 }
        statistics.waitingForRestartSince = waiting.map { start + $0 }
        return statistics.health(at: start + now, since: start + epoch, silenceLimit: .seconds(8), repairLimit: .seconds(15))
    }

    @Test func aLegThatKeepsReportingIsHealthyHoweverStillTheScreen() {
        #expect(health(heard: .seconds(99), at: .seconds(100)) == .healthy)
        #expect(health(heard: .seconds(93), at: .seconds(100)) == .healthy)
    }

    @Test func silenceIsCountedFromTheLastAuthenticPacket() {
        #expect(health(heard: .seconds(92), at: .seconds(100)) == .silent)
        #expect(health(heard: .seconds(10), at: .seconds(100)) == .silent)
    }

    @Test func aLegThatNeverSpokeIsGivenItsTimeFromTheEpoch() {
        #expect(health(heard: nil, at: .seconds(7)) == .healthy)
        #expect(health(heard: nil, at: .seconds(8)) == .silent)
    }

    /// Sockets do not run in the background, so what was heard before the app came back says nothing.
    @Test func timeInTheBackgroundDoesNotCount() {
        #expect(health(heard: .seconds(10), at: .seconds(105), epoch: .seconds(100)) == .healthy)
        #expect(health(heard: .seconds(10), at: .seconds(108), epoch: .seconds(100)) == .silent)
        #expect(health(heard: .seconds(104), waiting: .seconds(20), at: .seconds(105), epoch: .seconds(100)) == .healthy)
    }

    @Test func picturesBrokenForTooLongAreUnrepaired() {
        #expect(health(heard: .seconds(99), waiting: .seconds(90), at: .seconds(100)) == .healthy)
        #expect(health(heard: .seconds(99), waiting: .seconds(85), at: .seconds(100)) == .unrepaired)
        // Silence is the plainer finding when both hold.
        #expect(health(heard: .seconds(80), waiting: .seconds(70), at: .seconds(100)) == .silent)
    }
}
