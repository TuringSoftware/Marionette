// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

@testable import ARDProtocol
import ARDTestSupport
import Foundation
import Testing

/// Reads the varint and length-delimited fields of a protobuf message, for checking what we build.
private func protobufFields(_ data: Data) -> [(field: UInt64, value: UInt64?, bytes: Data?)] {
    var fields: [(UInt64, UInt64?, Data?)] = []
    var index = data.startIndex
    func varint() -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return value
    }
    while index < data.endIndex {
        let key = varint()
        if key & 7 == 0 {
            fields.append((key >> 3, varint(), nil))
        } else {
            let length = Int(varint())
            fields.append((key >> 3, nil, data.subdata(in: index..<(index + length))))
            index += length
        }
    }
    return fields
}

private func key(_ seed: UInt8) -> MediaKey {
    MediaKey(bytes: Data((0..<46).map { seed &+ UInt8($0) }))
}

private let sampleOffer = MediaOffer(
    sessionID: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
    flags: [.sixtyFramesPerSecond, .omitCursor],
    audioSSRC: 0x1111_2222,
    audioKeys: MediaLegKeys(viewerToServer: key(1), serverToViewer: key(60)),
    videos: [
        .init(ssrc: 0x3333_4444, keys: MediaLegKeys(viewerToServer: key(120), serverToViewer: key(180)), width: 2880, height: 1800, codec: .hevc, tilesPerFrame: 1),
    ]
)

@Suite struct MediaOfferTests {
    /// Splits a `0x1c` message into its header fields and offers.
    private func dissect(_ message: Data) throws -> (flags: UInt32, session: Data, audioKeys: (Data, Data), audioOffer: Data, videos: [(keys: (Data, Data), offer: Data)]) {
        var reader = WireReader(message)
        #expect(try reader.u8() == 0x1c)
        #expect(try reader.u8() == 0)
        #expect(try Int(reader.u16()) == message.count - 4)
        #expect(try reader.u16() == 3)
        let flags = try reader.u32()
        let audioLength = Int(try reader.u16())
        let videoLengths = [Int(try reader.u16()), Int(try reader.u16())]
        #expect(try reader.u32() == 0)
        let session = try reader.take(16)
        let audioKeys = (try reader.take(46), try reader.take(46))
        #expect(reader.offset == 0x80)
        let audioOffer = try reader.take(audioLength)
        var videos: [((Data, Data), Data)] = []
        for length in videoLengths where length > 0 {
            videos.append(((try reader.take(46), try reader.take(46)), try reader.take(length)))
        }
        #expect(reader.isAtEnd)
        return (flags, session, audioKeys, audioOffer, videos)
    }

    /// Opens an offer with the system's property-list reader, which checks our writer against Apple's.
    private func open(_ offer: Data) throws -> (mode: Int, callID: String, endpoint: Data, blob: Data) {
        let dictionary = try #require(try PropertyListSerialization.propertyList(from: offer, format: nil) as? [String: Any])
        #expect(Set(dictionary.keys) == ["avcMediaStreamOptionRemoteEndpointInfo", "avcMediaStreamNegotiatorMode", "avcMediaStreamNegotiatorMediaBlob", "avcMediaStreamOptionCallID"])
        let compressed = try #require(dictionary["avcMediaStreamNegotiatorMediaBlob"] as? Data)
        return (
            try #require(dictionary["avcMediaStreamNegotiatorMode"] as? Int),
            try #require(dictionary["avcMediaStreamOptionCallID"] as? String),
            try #require(dictionary["avcMediaStreamOptionRemoteEndpointInfo"] as? Data),
            try InflateStream.inflateWhole(compressed, limit: 1 << 16)
        )
    }

    @Test func messageHeaderAndKeysAreWhereTheMacReadsThem() throws {
        let parts = try dissect(sampleOffer.message())
        #expect(parts.flags == 0x5)
        #expect(parts.session == Data(hex: "00112233445566778899aabbccddeeff"))
        #expect(parts.audioKeys.0 == key(1).bytes)
        #expect(parts.audioKeys.1 == key(60).bytes)
        #expect(parts.videos.count == 1)
        #expect(parts.videos[0].keys.0 == key(120).bytes)
        #expect(parts.videos[0].keys.1 == key(180).bytes)
    }

    @Test func offersAreValidPropertyListsWithTheSessionCallID() throws {
        let parts = try dissect(sampleOffer.message())
        let audio = try open(parts.audioOffer)
        let video = try open(parts.videos[0].offer)
        #expect(audio.mode == 8)
        #expect(video.mode == 7)
        #expect(audio.callID == "00112233-4455-6677-8899-AABBCCDDEEFF")
        #expect(video.callID == audio.callID)
        #expect(audio.endpoint.hex == "080010011a0d" + Data("VirtualMac2,1".utf8).hex + "2208" + Data("2215.5.1".utf8).hex + "2a05" + Data("25G83".utf8).hex)
    }

    @Test func audioBlobNamesTheViewerSSRCAndAcceptedPayloads() throws {
        let blob = try open(try dissect(sampleOffer.message()).audioOffer).blob
        let fields = protobufFields(blob)
        #expect(fields.prefix(2).map(\.value) == [1, 1])
        let stream = protobufFields(try #require(fields.first { $0.field == 3 }?.bytes))
        #expect(stream.map(\.field) == [1, 2, 3, 4, 5, 6])
        #expect(stream[0].value == 0x1111_2222)
        #expect(stream[3].value == 0x5E7F)
        #expect(fields.first { $0.field == 6 }?.bytes == Data("Viceroy 1.7.0".utf8))
        #expect(fields.filter { $0.field == 9 }.count == 10)
        #expect(fields.first { $0.field == 13 }?.value == 17_169_649_764_059_066_368)
        #expect(fields.suffix(2).map(\.field) == [14, 16])
    }

    @Test func videoBlobCarriesSizeTilesAndBothCodecs() throws {
        let blob = try open(try dissect(sampleOffer.message()).videos[0].offer).blob
        let fields = protobufFields(blob)
        let stream = protobufFields(try #require(fields.first { $0.field == 5 }?.bytes))
        #expect(stream.first { $0.field == 1 }?.value == 0x3333_4444)
        #expect(stream.first { $0.field == 4 }?.value == 2880)
        #expect(stream.first { $0.field == 5 }?.value == 1800)
        #expect(stream.first { $0.field == 6 }?.value == 1)
        let codecs = stream.filter { $0.field == 3 }.compactMap(\.bytes).map(protobufFields)
        #expect(codecs.map { $0.first?.value } == [123, 100])
        #expect(String(decoding: try #require(codecs[1].first { $0.field == 3 }?.bytes), as: UTF8.self).hasPrefix("FLS;LF:-1;POS:5;"))
        // The 60 Mbit/s entry is the stream's ceiling; without it the Mac's encoder gets a rate of zero.
        let entries = fields.filter { $0.field == 9 }.compactMap(\.bytes).map(protobufFields)
        #expect(entries.count == 10)
        #expect(entries[0].map(\.value) == [0, 40_000_000, 12_288])
        #expect(entries.contains { $0.map(\.value) == [0, 60_000_000, 262_144] })
        #expect(fields.first { $0.field == 13 }?.value == 17_169_649_764_516_085_760)
    }

    @Test func h264AloneAndTwoDisplays() throws {
        var offer = sampleOffer
        offer.videos[0].codec = .h264
        offer.videos.append(.init(ssrc: 9, keys: MediaLegKeys(viewerToServer: key(7), serverToViewer: key(8)), width: 1920, height: 1080, codec: .h264, tilesPerFrame: 4))
        offer.flags.insert(.sixtyFramesPerSecondSecondStream)
        let parts = try dissect(offer.message())
        #expect(parts.flags == 0x7)
        #expect(parts.videos.count == 2)
        #expect(parts.videos[1].keys.0 == key(7).bytes)
        for (index, video) in parts.videos.enumerated() {
            let stream = protobufFields(try #require(protobufFields(try open(video.offer).blob).first { $0.field == 5 }?.bytes))
            #expect(stream.filter { $0.field == 3 }.count == 1, "only H.264 is offered")
            #expect(stream.first { $0.field == 6 }?.value == (index == 0 ? 1 : 4))
        }
    }

    @Test func isDeterministic() {
        #expect(sampleOffer.message() == sampleOffer.message())
    }
}

@Suite struct MediaReplyTests {
    @Test func portsMessage() throws {
        // Type 1, version, flags; audio 5900 on; video 5901 on; second video off; ten reserved bytes.
        let body = Data(hex: "0001 0001 00000000  170c 00000001  170d 00000001  170e 00000000  00000000000000000000")
        #expect(body.count == 36)
        #expect(try MediaReply.parse(body) == .ports(audio: 5900, video: 5901, secondVideo: nil))
        let two = Data(hex: "0001 0001 00000000  170c 00000001  170d 00000001  170e 00000001  00000000000000000000")
        #expect(try MediaReply.parse(two) == .ports(audio: 5900, video: 5901, secondVideo: 5902))
        let disabled = Data(hex: "0001 0001 00000000  170c 00000001  170d 00000000  170e 00000000  00000000000000000000")
        // A port without its in-use bit is still named; whether it can be used is the session's call.
        #expect(try MediaReply.parse(disabled) == .ports(audio: 5900, video: 5901, secondVideo: nil))
    }

    @Test func answerLengthsMustDescribeTheBody() throws {
        let one = Data(hex: "0002 0001 00000000  0003 0002 0000 00000000") + Data(count: 5)
        #expect(try MediaReply.parse(one) == .answer(videoLegs: 1))
        let two = Data(hex: "0002 0001 00000000  0001 0001 0001 00000000") + Data(count: 3)
        #expect(try MediaReply.parse(two) == .answer(videoLegs: 2))
        // Bytes beyond the parts may be a field a later macOS adds.
        #expect(try MediaReply.parse(one + Data([0])) == .answer(videoLegs: 1))
        #expect(throws: WireError.self) { try MediaReply.parse(one.dropLast()) }
    }

    @Test func failures() throws {
        #expect(try MediaReply.parse(Data(hex: "0003 0001 00000000 00000001 00000001")) == .failure(.heldByAnotherViewer))
        #expect(try MediaReply.parse(Data(hex: "0003 0001 00000000 00000002 00000000")) == .failure(.noConfiguration))
        #expect(try MediaReply.parse(Data(hex: "0003 0001 00000000 00000009 00000004")) == .failure(.other(kind: 9, subCode: 4)))
        #expect(try MediaReply.parse(Data(hex: "0063 0001 00000000")) == .unknown(type: 99))
        #expect(throws: WireError.self) { try MediaReply.parse(Data(hex: "0001 00")) }
    }
}

private func rtp(
    sequence: UInt16, timestamp: UInt32, marker: Bool = false, ssrc: UInt32 = 77, extensionProfile: UInt16? = nil,
    framePackets: UInt16 = 3, payload: Data
) -> RTPPacket {
    var writer = WireWriter()
    writer.u8(extensionProfile == nil ? 0x80 : 0x90)
    writer.u8((marker ? 0x80 : 0) | 100)
    writer.u16(sequence)
    writer.u32(timestamp)
    writer.u32(ssrc)
    if let extensionProfile {
        writer.u16(extensionProfile)
        writer.u16(1)
        writer.u16(framePackets)
        writer.u16(1)
    }
    writer.bytes(payload)
    return try! RTPPacket.parse(writer.data)
}

/// A two-byte HEVC NAL header of the given type, then `size` bytes of body.
private func nal(_ type: UInt8, size: Int = 6, fill: UInt8 = 0xAA) -> Data {
    Data([type << 1, 0x01]) + Data(repeating: fill, count: size)
}

private func aggregation(_ units: [Data]) -> Data {
    var payload = Data([48 << 1, 0x01])
    for unit in units {
        payload.append(contentsOf: [UInt8(unit.count >> 8), UInt8(unit.count & 0xff)])
        payload.append(unit)
    }
    return payload
}

/// Splits a NAL unit into fragmentation units of `size` body bytes.
private func fragments(_ unit: Data, size: Int) -> [Data] {
    let type = unit[0] >> 1 & 0x3f
    let body = unit.dropFirst(2)
    var result: [Data] = []
    var offset = body.startIndex
    while offset < body.endIndex {
        let end = min(body.endIndex, offset + size)
        var header = type
        if offset == body.startIndex { header |= 0x80 }
        if end == body.endIndex { header |= 0x40 }
        result.append(Data([unit[0] & 0x81 | 49 << 1, unit[1], header]) + body[offset..<end])
        offset = end
    }
    return result
}

@Suite struct RTPTests {
    @Test func parsesHeaderExtensionAndFlags() throws {
        let plain = rtp(sequence: 9, timestamp: 1234, marker: true, payload: Data([1, 2, 3]))
        #expect(plain.payloadType == 100)
        #expect(plain.marker)
        #expect(plain.sequence == 9)
        #expect(plain.timestamp == 1234)
        #expect(plain.ssrc == 77)
        #expect(plain.payload == Data([1, 2, 3]))
        #expect(!plain.isRefresh)
        #expect(!plain.wantsAcknowledgement)

        let familiar = rtp(sequence: 1, timestamp: 1, extensionProfile: 0x9301, framePackets: 250, payload: Data([9]))
        #expect(familiar.payload == Data([9]))
        #expect(familiar.mediaControl == MediaControlInfo(profile: 0x9301, framePacketCount: 250, frameSequence: 1))
        #expect(familiar.mediaControl?.version == 2)
        #expect(familiar.mediaControl?.cameraStatus == 0x13)
        #expect(familiar.mediaControl?.isFamiliar == true)
        #expect(rtp(sequence: 1, timestamp: 1, extensionProfile: 0x9311, payload: Data([9])).wantsAcknowledgement)
        #expect(rtp(sequence: 1, timestamp: 1, extensionProfile: 0x9331, payload: Data([9])).isRefresh)
        // The other long-term-reference bits, or another camera status, do not hide the flags.
        #expect(rtp(sequence: 1, timestamp: 1, extensionProfile: 0x9351, payload: Data([9])).wantsAcknowledgement)
        let otherCamera = rtp(sequence: 1, timestamp: 1, extensionProfile: 0x9721, payload: Data([9]))
        #expect(otherCamera.isRefresh)
        #expect(otherCamera.mediaControl?.isFamiliar == false)
        // Some other extension profile is skipped without being read as the Mac's.
        let other = rtp(sequence: 1, timestamp: 1, extensionProfile: 0xBEDE, payload: Data([9]))
        #expect(!other.isRefresh)
        #expect(other.mediaControl == nil)
    }

    @Test func readsTheLongTermReferenceTimestampBeforeTheFrameWord() throws {
        // Flags 0x03: a little-endian timestamp word, then the packet count and picture number.
        let packet = try RTPPacket.parse(Data(hex: "9064 0001 00000001 00000002 9313 0002 78563412 00fa 0007 aa"))
        #expect(packet.mediaControl == MediaControlInfo(profile: 0x9313, longTermReferenceTimestamp: 0x1234_5678, framePacketCount: 250, frameSequence: 7))
        #expect(packet.wantsAcknowledgement)
        #expect(packet.payload == Data([0xaa]))
        // Flags that promise words the extension does not hold are not trusted.
        #expect(try RTPPacket.parse(Data(hex: "9064 0001 00000001 00000002 9303 0001 78563412 aa")).mediaControl == nil)
    }

    @Test func rejectsMalformedPackets() {
        #expect(throws: WireError.self) { try RTPPacket.parse(Data(count: 5)) }
        #expect(throws: WireError.malformed("not RTP version 2")) { try RTPPacket.parse(Data([0x40] + [UInt8](repeating: 0, count: 15))) }
        // Extension claims more words than the packet holds.
        #expect(throws: WireError.self) { try RTPPacket.parse(Data(hex: "9064 0001 00000001 00000002 9301 00ff 00")) }
        // Padding longer than the payload.
        #expect(throws: WireError.self) { try RTPPacket.parse(Data(hex: "a064 0001 00000001 00000002 0109")) }
    }

    @Test func stripsPadding() throws {
        let packet = try RTPPacket.parse(Data(hex: "a064 0001 00000001 00000002 aabb 000003"))
        #expect(packet.payload == Data([0xaa, 0xbb]))
    }

    @Test func classifiesDatagrams() {
        #expect(MediaPacketKind.classify(Data(hex: "80c9 0001 00000001")) == .rtcp)
        #expect(MediaPacketKind.classify(Data(hex: "80c8 0006 00000001")) == .rtcp)
        #expect(MediaPacketKind.classify(Data(hex: "8064 0001 00000001")) == .rtp)
        #expect(MediaPacketKind.classify(Data(hex: "80e4 0001 00000001")) == .rtp)
        #expect(MediaPacketKind.classify(Data(hex: "80c0 0001 00000001")) == .rtcp)
        #expect(MediaPacketKind.classify(Data(hex: "80df 0001 00000001")) == .rtcp)
        #expect(MediaPacketKind.classify(Data(hex: "80e0 0001 00000001")) == .rtp)
        #expect(MediaPacketKind.classify(Data(hex: "0064 0001 00000001")) == .neither)
        #expect(MediaPacketKind.classify(Data([0x80])) == .neither)
    }

    @Test func readsTheClaimedSSRCWithoutDecrypting() {
        #expect(MediaPacketKind.claimedSSRC(Data(hex: "8064 0001 00000001 0a0b0c0d ffff")) == 0x0A0B_0C0D)
        #expect(MediaPacketKind.claimedSSRC(Data(hex: "80c8 0006 0a0b0c0d 00000000")) == 0x0A0B_0C0D)
        #expect(MediaPacketKind.claimedSSRC(Data(hex: "8064 0001 00000001")) == nil)
    }

    @Test func rtcpMessagesMatchTheLayoutsAMacAccepts() {
        #expect(RTCPMessage.receiverReport(ssrc: 0x0102_0304).hex == "80c9000101020304")
        #expect(RTCPMessage.sourceDescription(ssrc: 0x0102_0304).hex == "81ca0002" + "01020304" + "01000000")
        #expect(RTCPMessage.acknowledgement(ssrc: 0x0102_0304, picture: 0xAABB_CCDD).hex == "80cc0003" + "01020304" + "00000005" + "aabbccdd")
        #expect(RTCPMessage.pictureLoss(ssrc: 1, mediaSSRC: 2).hex == "81ce0002" + "00000001" + "00000002")
        #expect(RTCPMessage.refreshRequest(ssrc: 1, mediaSSRC: 2, width: 2880, height: 1800).hex == "82ce0003" + "00000001" + "00000002" + "0b400708")
        #expect(RTCPMessage.leading(RTCPMessage.pictureLoss(ssrc: 0xCAFE, mediaSSRC: 2))?.ssrc == 0xCAFE)
        #expect(RTCPMessage.leading(Data(hex: "80c8 0006 0a0b0c0d"))?.type == 200)
        #expect(RTCPMessage.leading(Data([1, 2, 3])) == nil)
    }
}

@Suite struct RateFeedbackTests {
    @Test func noReportBeforeAPicturePacket() {
        let epoch = ContinuousClock.now
        var feedback = RateFeedback(epoch: epoch)
        #expect(feedback.report(ssrc: 1, now: epoch) == nil)
    }

    @Test func reportLayout() throws {
        let epoch = ContinuousClock.now
        var feedback = RateFeedback(epoch: epoch)
        feedback.received(ssrc: 500, timestamp: 0x0012_3456, at: epoch + .milliseconds(2000))
        feedback.received(ssrc: 500, timestamp: 0x0012_3456, at: epoch + .milliseconds(2001))
        let reportReport = feedback.report(ssrc: 0xAABB_CCDD, now: epoch + .milliseconds(2031))
        let report = try #require(reportReport)
        #expect(report.count == 32)
        var reader = WireReader(report)
        #expect(try reader.u32() == 0x80CC_0007)
        #expect(try reader.u32() == 0xAABB_CCDD)
        #expect(try reader.take(4) == Data("RCTL".utf8))
        #expect(try reader.u8() == 0x85)
        #expect(try reader.u8() == 0)
        #expect(try reader.u16() == 4)
        #expect(try reader.u16() == 0x1234) // timestamp >> 8
        #expect(try reader.u32() == 0)
        #expect(try reader.u16() == 31) // milliseconds since the picture's first packet
        #expect(try reader.u16() == UInt16(2031 * 1024 / 1000)) // viewer clock in 1/1024 s
        #expect(try reader.u16() == 0) // no delay yet
        #expect(try reader.u16() == 1) // running count of packets at the picture's first packet
        #expect(try reader.u16() == 60_000)
    }

    @Test func theEchoIsTheNewestPictureLatchedAtItsFirstPacket() throws {
        let epoch = ContinuousClock.now
        var feedback = RateFeedback(epoch: epoch)
        feedback.received(ssrc: 1, timestamp: 0x0000_1000, at: epoch + .milliseconds(10))
        feedback.received(ssrc: 1, timestamp: 0x0000_2000, at: epoch + .milliseconds(20))
        // A straggler from the older picture, and more of the newer one, move nothing.
        feedback.received(ssrc: 1, timestamp: 0x0000_1000, at: epoch + .milliseconds(25))
        feedback.received(ssrc: 1, timestamp: 0x0000_2000, at: epoch + .milliseconds(28))
        let reportReport = feedback.report(ssrc: 9, now: epoch + .milliseconds(30))
        let report = try #require(reportReport)
        #expect(report.subdata(in: 16..<18) == Data([0x00, 0x20])) // echo of 0x2000
        #expect(report.subdata(in: 22..<24) == Data([0x00, 10])) // held since 20 ms
        #expect(report.subdata(in: 28..<30) == Data([0x00, 2])) // count when the picture began
        // A timestamp further ahead than 0x7fffffff counts as older.
        feedback.received(ssrc: 1, timestamp: 0x8000_2000, at: epoch + .milliseconds(40))
        let laterReport = feedback.report(ssrc: 9, now: epoch + .milliseconds(40))
        let later = try #require(laterReport)
        #expect(later.subdata(in: 16..<18) == Data([0x00, 0x20]))
    }

    @Test func aBurstOfLossIsReportedOnceAndCapped() throws {
        let epoch = ContinuousClock.now
        var feedback = RateFeedback(epoch: epoch)
        feedback.received(ssrc: 1, timestamp: 100, at: epoch)
        feedback.lost(run: 2)
        feedback.lost(run: 5)
        feedback.lost(run: 1)
        let firstReport = feedback.report(ssrc: 9, now: epoch)
        let first = try #require(firstReport)
        #expect(first[28] >> 4 == 5)
        let secondReport = feedback.report(ssrc: 9, now: epoch)
        let second = try #require(secondReport)
        #expect(second[28] >> 4 == 0)
        feedback.lost(run: 400)
        let thirdReport = feedback.report(ssrc: 9, now: epoch)
        let third = try #require(thirdReport)
        #expect(third[28] >> 4 == 15)
        #expect(third[29] == 1)
    }

    @Test func delayGrowsWhenPicturesArriveLaterThanTheirTimestampsAndRecovers() {
        let epoch = ContinuousClock.now
        var feedback = RateFeedback(epoch: epoch)
        // 30 pictures a second on a 24 kHz clock is 800 ticks a picture.
        var arrival = epoch
        var timestamp: UInt32 = 1000
        for _ in 0..<60 {
            feedback.received(ssrc: 1, timestamp: timestamp, at: arrival)
            timestamp &+= 800
            arrival += .microseconds(33_333)
        }
        #expect(feedback.delay < 0.001)
        // A queue builds: each picture now arrives 10 ms later than the last one did.
        for _ in 0..<30 {
            feedback.received(ssrc: 1, timestamp: timestamp, at: arrival)
            timestamp &+= 800
            arrival += .microseconds(43_333)
        }
        #expect(feedback.delay > 0.1)
        let congested = feedback.delay
        // The queue drains: pictures arrive on time again, 300 ms behind where they started.
        for _ in 0..<60 {
            feedback.received(ssrc: 1, timestamp: timestamp, at: arrival)
            timestamp &+= 800
            arrival += .microseconds(33_333)
        }
        #expect(feedback.delay <= congested * 1.5)
    }

    @Test func newStreamStartsTheEstimateAndCountAgain() throws {
        let epoch = ContinuousClock.now
        var feedback = RateFeedback(epoch: epoch)
        for index in 0..<10 {
            feedback.received(ssrc: 1, timestamp: UInt32(index) * 800, at: epoch + .milliseconds(index * 100))
        }
        #expect(feedback.delay > 0)
        feedback.received(ssrc: 2, timestamp: 5, at: epoch + .seconds(2))
        #expect(feedback.delay == 0)
        let reportReport = feedback.report(ssrc: 9, now: epoch + .seconds(2))
        let report = try #require(reportReport)
        #expect(report.subdata(in: 28..<30) == Data([0, 1]))
    }

    @Test func timestampWrapIsNotAJump() {
        let epoch = ContinuousClock.now
        var feedback = RateFeedback(epoch: epoch)
        var timestamp: UInt32 = .max - 2000
        var arrival = epoch
        for _ in 0..<20 {
            feedback.received(ssrc: 1, timestamp: timestamp, at: arrival)
            timestamp &+= 800
            arrival += .microseconds(33_333)
        }
        #expect(feedback.delay < 0.001)
    }
}

@Suite struct HEVCDepacketizerTests {
    private let parameterSets = [nal(32), nal(33), nal(34)]

    private func pictures(_ packets: [RTPPacket], acceptsRefresh: Bool = false) -> [HEVCDepacketizer.Output] {
        var depacketizer = HEVCDepacketizer()
        depacketizer.acceptsRefresh = acceptsRefresh
        return packets.map { depacketizer.push($0) }.filter { $0 != .none }
    }

    /// A keyframe as a Mac sends one: parameter sets aggregated, then the intra slice in fragments.
    private func keyframe(startingAt sequence: UInt16, timestamp: UInt32) -> [RTPPacket] {
        let slice = nal(19, size: 3000, fill: 0x19)
        let pieces = fragments(slice, size: 1000)
        var packets = [rtp(sequence: sequence, timestamp: timestamp, payload: aggregation(parameterSets))]
        for (index, piece) in pieces.enumerated() {
            packets.append(rtp(sequence: sequence &+ UInt16(index + 1), timestamp: timestamp, marker: index == pieces.count - 1, payload: piece))
        }
        return packets
    }

    @Test func reassemblesAggregatedAndFragmentedKeyframe() throws {
        let output = pictures(keyframe(startingAt: 100, timestamp: 5000))
        guard case .picture(let unit) = try #require(output.first), output.count == 1 else {
            Issue.record("expected one picture, got \(output)")
            return
        }
        #expect(unit.isKeyframe)
        #expect(unit.timestamp == 5000)
        #expect(unit.nalUnits.count == 4)
        #expect(unit.nalUnits[0..<3].elementsEqual(parameterSets))
        #expect(unit.nalUnits[3] == nal(19, size: 3000, fill: 0x19))
        #expect(unit.annexB.prefix(6) == Data([0, 0, 0, 1, 32 << 1, 1]))
        #expect(unit.annexB.count == unit.nalUnits.reduce(0) { $0 + $1.count + 4 })
    }

    @Test func picturesBeforeAKeyframeAreWithheld() {
        var packets = [rtp(sequence: 1, timestamp: 100, marker: true, payload: nal(1))]
        packets += keyframe(startingAt: 2, timestamp: 200)
        packets.append(rtp(sequence: 6, timestamp: 300, marker: true, payload: nal(1)))
        let output = pictures(packets)
        #expect(output.count == 2)
        guard case .picture(let first) = output[0], case .picture(let second) = output[1] else {
            Issue.record("expected two pictures")
            return
        }
        #expect(first.isKeyframe)
        #expect(!second.isKeyframe)
        #expect(second.timestamp == 300)
    }

    @Test func lossIsReportedOnceAndRecoversAtKeyframe() {
        var packets = keyframe(startingAt: 0, timestamp: 100)
        packets.append(rtp(sequence: 4, timestamp: 200, marker: true, payload: nal(1)))
        // Sequence 5 is lost.
        packets.append(rtp(sequence: 6, timestamp: 400, marker: true, payload: nal(1)))
        packets.append(rtp(sequence: 7, timestamp: 500, marker: true, payload: nal(1)))
        packets += keyframe(startingAt: 8, timestamp: 600)
        packets.append(rtp(sequence: 12, timestamp: 700, marker: true, payload: nal(1)))
        let output = pictures(packets)
        let summary = output.map { item -> String in
            switch item {
            case .picture(let unit): "\(unit.timestamp)\(unit.isKeyframe ? "K" : "")"
            case .loss: "loss"
            case .none: "-"
            }
        }
        #expect(summary == ["100K", "200", "loss", "600K", "700"])
    }

    @Test func refreshPictureRestartsOnlyWhenAccepted() {
        func stream() -> [RTPPacket] {
            var packets = keyframe(startingAt: 0, timestamp: 100)
            packets.append(rtp(sequence: 5, timestamp: 300, marker: true, payload: nal(1))) // 4 lost
            packets.append(rtp(sequence: 6, timestamp: 400, marker: true, extensionProfile: 0x9331, payload: nal(1)))
            packets.append(rtp(sequence: 7, timestamp: 500, marker: true, payload: nal(1)))
            return packets
        }
        func timestamps(_ output: [HEVCDepacketizer.Output]) -> [UInt32] {
            output.compactMap { if case .picture(let unit) = $0 { unit.timestamp } else { nil } }
        }
        #expect(timestamps(pictures(stream(), acceptsRefresh: true)) == [100, 400, 500])
        #expect(timestamps(pictures(stream(), acceptsRefresh: false)) == [100])
    }

    @Test func keyframeWithALostFragmentIsNotAccepted() {
        var packets = keyframe(startingAt: 0, timestamp: 100)
        packets.remove(at: 2) // a middle fragment of the intra slice
        packets.append(rtp(sequence: 4, timestamp: 200, marker: true, payload: nal(1)))
        #expect(pictures(packets).isEmpty)
    }

    @Test func keyframeWhoseFirstPacketWasLostIsNotAccepted() {
        var packets = keyframe(startingAt: 0, timestamp: 100)
        packets.append(rtp(sequence: 4, timestamp: 200, marker: true, payload: nal(1)))
        // The next keyframe's parameter-set packet (sequence 5) is lost.
        packets += keyframe(startingAt: 5, timestamp: 300).dropFirst()
        let output = pictures(packets)
        #expect(output.count == 3)
        #expect(output.last == .loss)
    }

    @Test func lostMarkerDoesNotMergeTwoPictures() {
        var packets = keyframe(startingAt: 0, timestamp: 100)
        packets.append(rtp(sequence: 4, timestamp: 200, payload: nal(1, fill: 1)))
        // Sequence 5, the marked end of picture 200, is lost.
        packets.append(rtp(sequence: 6, timestamp: 300, marker: true, payload: nal(1, fill: 2)))
        packets += keyframe(startingAt: 7, timestamp: 400)
        let output = pictures(packets)
        guard case .picture(let last) = output.last else {
            Issue.record("expected a picture last")
            return
        }
        #expect(last.timestamp == 400)
        #expect(last.nalUnits.count == 4)
        #expect(output.filter { $0 == .loss }.count == 1)
    }

    @Test func newSSRCStartsOver() {
        var packets = keyframe(startingAt: 0, timestamp: 100)
        packets.append(rtp(sequence: 900, timestamp: 50, marker: true, ssrc: 78, payload: nal(1)))
        let fresh = keyframe(startingAt: 901, timestamp: 60).map {
            rtp(sequence: $0.sequence, timestamp: $0.timestamp, marker: $0.marker, ssrc: 78, payload: $0.payload)
        }
        let output = pictures(packets + fresh)
        // No loss is reported for the jump in sequence numbers: it is a different stream.
        #expect(output.count == 2)
        #expect(!output.contains(.loss))
    }

    @Test func aJumpAheadByMoreThanHalfTheNumberSpaceIsALossNotAStraggler() {
        var packets = keyframe(startingAt: 100, timestamp: 100)
        packets.append(rtp(sequence: 104, timestamp: 200, marker: true, payload: nal(1)))
        // 40 000 packets later, as after a spell in the background: a loss, then a fresh keyframe.
        packets.append(rtp(sequence: 40_104, timestamp: 900, marker: true, payload: nal(1)))
        packets += keyframe(startingAt: 40_105, timestamp: 1000)
        let summary = pictures(packets).map { item -> String in
            switch item {
            case .picture(let unit): "\(unit.timestamp)"
            case .loss: "loss"
            case .none: "-"
            }
        }
        #expect(summary == ["100", "200", "loss", "1000"])
    }

    @Test func aPictureWhosePacketCountIsWholeSurvivesTheGapBeforeIt() {
        // Picture 200 loses its last packet; the refresh picture right after it arrived whole,
        // which only its packet count can tell.
        var packets = keyframe(startingAt: 0, timestamp: 100)
        packets.append(rtp(sequence: 4, timestamp: 200, extensionProfile: 0x9301, framePackets: 2, payload: nal(1)))
        // Sequence 5, the marked end of picture 200, is lost.
        packets.append(rtp(sequence: 6, timestamp: 300, extensionProfile: 0x9321, framePackets: 2, payload: nal(1, fill: 1)))
        packets.append(rtp(sequence: 7, timestamp: 300, marker: true, extensionProfile: 0x9321, framePackets: 2, payload: nal(1, fill: 2)))
        let output = pictures(packets, acceptsRefresh: true)
        #expect(output.count == 3)
        #expect(output[1] == .loss)
        guard case .picture(let refresh) = output[2] else {
            Issue.record("expected the refresh picture, got \(output)")
            return
        }
        #expect(refresh.timestamp == 300)
        #expect(refresh.isRefresh)
        // Had the gap taken the picture's own first packet, its count would fall short.
        var short = keyframe(startingAt: 0, timestamp: 100)
        short.append(rtp(sequence: 5, timestamp: 300, marker: true, extensionProfile: 0x9321, framePackets: 2, payload: nal(1)))
        #expect(pictures(short, acceptsRefresh: true).last == .loss)
    }

    @Test func packetsThatAreNoNALUnitSpoilThePicture() {
        var packets = keyframe(startingAt: 0, timestamp: 100)
        // PACI (type 50) and the unspecified types after it.
        packets.append(rtp(sequence: 4, timestamp: 200, marker: true, payload: nal(50)))
        packets.append(rtp(sequence: 5, timestamp: 300, marker: true, payload: nal(1)))
        packets.append(rtp(sequence: 6, timestamp: 400, marker: true, payload: nal(63)))
        let output = pictures(packets)
        #expect(output.count == 2)
        #expect(output.last == .loss)
    }

    @Test func aPictureOfCountlessTinyUnitsIsRefused() {
        // Aggregation packets of two-byte units: a few hundred to a packet.
        var packets = keyframe(startingAt: 0, timestamp: 100)
        let tiny = aggregation(Array(repeating: Data([1 << 1, 1]), count: 300))
        for index in 0..<5 {
            packets.append(rtp(sequence: UInt16(4 + index), timestamp: 200, marker: index == 4, payload: tiny))
        }
        #expect(pictures(packets).last == .loss)
    }

    @Test func sequenceNumberWrapIsNotALoss() {
        var packets = keyframe(startingAt: 65_533, timestamp: 100)
        packets.append(rtp(sequence: 1, timestamp: 200, marker: true, payload: nal(1)))
        #expect(pictures(packets).count == 2)
    }

    @Test func malformedPayloadsSpoilOnlyTheirPicture() {
        var packets = keyframe(startingAt: 0, timestamp: 100)
        // An aggregation whose length runs past the packet.
        packets.append(rtp(sequence: 4, timestamp: 200, marker: true, payload: Data([48 << 1, 1, 0xFF, 0xFF, 1, 2])))
        // A fragment end with no start.
        packets.append(rtp(sequence: 5, timestamp: 300, marker: true, payload: Data([49 << 1, 1, 0x41, 9])))
        packets.append(rtp(sequence: 6, timestamp: 400, marker: true, payload: Data([1])))
        packets += keyframe(startingAt: 7, timestamp: 500)
        let output = pictures(packets)
        #expect(output.first.map { if case .picture = $0 { true } else { false } } == true)
        #expect(output.filter { $0 == .loss }.count == 1)
        #expect(output.count == 3)
    }

    @Test func survivesRandomPacketsWithoutCrashing() {
        var generator = SeededGenerator(seed: 99)
        var depacketizer = HEVCDepacketizer()
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...40, using: &generator)
            let payload = Data((0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            _ = depacketizer.push(
                rtp(
                    sequence: UInt16.random(in: 0...50, using: &generator),
                    timestamp: UInt32.random(in: 0...5, using: &generator),
                    marker: Bool.random(using: &generator),
                    ssrc: UInt32.random(in: 0...1, using: &generator),
                    payload: payload
                )
            )
        }
    }
}

@Suite struct SequenceTrackerTests {
    @Test func countsWhatTheSenderSent() {
        var tracker = SequenceTracker()
        #expect(tracker.expected == 0)
        for sequence: UInt16 in [10, 11, 12, 15, 16] { tracker.note(sequence) }
        // 10 through 16 is seven packets, of which five arrived.
        #expect(tracker.expected == 7)
    }

    @Test func stragglersAndRepeatsDoNotMoveTheCount() {
        var tracker = SequenceTracker()
        for sequence: UInt16 in [100, 102, 101, 102, 99] { tracker.note(sequence) }
        #expect(tracker.expected == 3)
    }

    @Test func survivesTheNumberingWrappingAround() {
        var tracker = SequenceTracker()
        for sequence: UInt16 in [65534, 65535, 0, 1, 3] { tracker.note(sequence) }
        #expect(tracker.expected == 6)
        // Twice round the number space and a bit.
        var long = SequenceTracker()
        var sequence: UInt16 = 60000
        for _ in 0..<150_000 {
            long.note(sequence)
            sequence &+= 1
        }
        #expect(long.expected == 150_000)
    }

    @Test func aJumpOfMoreThanHalfTheNumberSpaceCountsOnFromThere() {
        var tracker = SequenceTracker()
        for sequence: UInt16 in [100, 101, 102] { tracker.note(sequence) }
        // After a while in the background the Mac is 40 000 packets further on.
        for sequence: UInt16 in [40_102, 40_103, 40_105] { tracker.note(sequence) }
        #expect(tracker.expected == 3 + 4)
        #expect(tracker.extendedHighest == 40_105)
        tracker.note(40_104)
        #expect(tracker.expected == 7)
        // And a jump that wraps the numbering carries the wrap.
        var wrapping = SequenceTracker()
        for sequence: UInt16 in [60_000, 60_001] { wrapping.note(sequence) }
        wrapping.note(30_000)
        #expect(wrapping.expected == 3)
        #expect(wrapping.extendedHighest == 0x1_0000 + 30_000)
    }
}

@Suite struct RTPReorderBufferTests {
    private let epoch = ContinuousClock.now

    private func packet(_ sequence: UInt16, ssrc: UInt32 = 7) -> RTPPacket {
        RTPPacket(payloadType: 100, marker: false, sequence: sequence, timestamp: 0, ssrc: ssrc, payload: Data([UInt8(truncatingIfNeeded: sequence)]))
    }

    /// Pushes sequence numbers 1 ms apart in the given arrival order, then lets time pass; returns
    /// the order they came out in.
    private func run(_ arrivals: [UInt16], hold: Duration = .milliseconds(15), startupHold: Duration = .zero) -> [UInt16] {
        var buffer = RTPReorderBuffer(hold: hold, startupHold: startupHold)
        var out: [UInt16] = []
        for (index, sequence) in arrivals.enumerated() {
            out += buffer.push(packet(sequence), at: epoch + .milliseconds(index)).map(\.sequence)
        }
        return out + buffer.release(at: epoch + .seconds(1)).map(\.sequence)
    }

    @Test func packetsInOrderPassStraightThrough() {
        var buffer = RTPReorderBuffer(startupHold: .zero)
        for sequence: UInt16 in 10...13 {
            #expect(buffer.push(packet(sequence), at: epoch).map(\.sequence) == [sequence])
        }
        #expect(buffer.deadline == nil)
    }

    @Test func aStragglerIsPutBackInItsPlace() {
        #expect(run([10, 12, 11, 13]) == [10, 11, 12, 13])
        // Many places late, as in a keyframe's burst over Wi-Fi.
        #expect(run([10, 12, 13, 14, 15, 16, 17, 11, 18]) == Array(10...18))
        #expect(run([10, 13, 12, 11, 14]) == [10, 11, 12, 13, 14])
    }

    @Test func aLossIsGivenUpOnOnceThePacketsBehindItHaveWaitedTheirTime() {
        var buffer = RTPReorderBuffer(hold: .milliseconds(15), startupHold: .zero)
        #expect(buffer.push(packet(10), at: epoch).map(\.sequence) == [10])
        #expect(buffer.push(packet(12), at: epoch + .milliseconds(1)).isEmpty)
        #expect(buffer.push(packet(13), at: epoch + .milliseconds(5)).isEmpty)
        #expect(buffer.deadline == epoch + .milliseconds(16))
        #expect(buffer.release(at: epoch + .milliseconds(15)).isEmpty)
        #expect(buffer.release(at: epoch + .milliseconds(16)).map(\.sequence) == [12, 13])
        #expect(buffer.deadline == nil)
        // A packet after the deadline sees the gap settled first.
        #expect(buffer.push(packet(15), at: epoch + .milliseconds(20)).isEmpty)
        #expect(buffer.push(packet(16), at: epoch + .milliseconds(40)).map(\.sequence) == [15, 16])
    }

    @Test func tooMuchWaitingGivesTheGapUpAtOnce() {
        var buffer = RTPReorderBuffer(hold: .seconds(10), startupHold: .zero, capacity: 3)
        _ = buffer.push(packet(10), at: epoch)
        var out: [UInt16] = []
        for sequence: UInt16 in [12, 13, 14, 15] { out += buffer.push(packet(sequence), at: epoch).map(\.sequence) }
        #expect(out == [12, 13, 14, 15])
    }

    @Test func aPacketGivenUpOnIsDroppedIfItComesAfterAll() {
        var buffer = RTPReorderBuffer(startupHold: .zero)
        _ = buffer.push(packet(10), at: epoch)
        _ = buffer.push(packet(12), at: epoch)
        #expect(buffer.release(at: epoch + .milliseconds(20)).map(\.sequence) == [12])
        #expect(buffer.push(packet(11), at: epoch + .milliseconds(21)).isEmpty)
        #expect(buffer.push(packet(13), at: epoch + .milliseconds(22)).map(\.sequence) == [13])
    }

    @Test func repeatsAreDropped() {
        #expect(run([10, 10, 12, 12, 11, 11, 13]) == [10, 11, 12, 13])
    }

    @Test func twoGapsAreSettledOneAtATime() {
        // 11 and 14 are missing. 15 and 16 arrive later than 12 and 13, so they wait longer.
        var buffer = RTPReorderBuffer(hold: .milliseconds(15), startupHold: .zero)
        _ = buffer.push(packet(10), at: epoch)
        _ = buffer.push(packet(12), at: epoch + .milliseconds(1))
        _ = buffer.push(packet(13), at: epoch + .milliseconds(2))
        _ = buffer.push(packet(15), at: epoch + .milliseconds(10))
        _ = buffer.push(packet(16), at: epoch + .milliseconds(11))
        #expect(buffer.release(at: epoch + .milliseconds(16)).map(\.sequence) == [12, 13])
        #expect(buffer.isHolding)
        #expect(buffer.deadline == epoch + .milliseconds(25))
        #expect(buffer.push(packet(14), at: epoch + .milliseconds(20)).map(\.sequence) == [14, 15, 16])
        #expect(!buffer.isHolding)
    }

    @Test func aStreamStartsAtItsLowestNumberNotItsFirstArrival() {
        var buffer = RTPReorderBuffer(hold: .milliseconds(15), startupHold: .milliseconds(8))
        #expect(buffer.push(packet(102), at: epoch).isEmpty)
        #expect(buffer.push(packet(100), at: epoch + .milliseconds(1)).isEmpty)
        #expect(buffer.push(packet(101), at: epoch + .milliseconds(2)).isEmpty)
        #expect(buffer.push(packet(104), at: epoch + .milliseconds(3)).isEmpty)
        #expect(buffer.deadline == epoch + .milliseconds(8))
        #expect(buffer.release(at: epoch + .milliseconds(8)).map(\.sequence) == [100, 101, 102])
        // 103 is still awaited, from when 104 arrived.
        #expect(buffer.deadline == epoch + .milliseconds(18))
        #expect(buffer.push(packet(103), at: epoch + .milliseconds(9)).map(\.sequence) == [103, 104])
    }

    @Test func numberingMayWrapAround() {
        #expect(run([65534, 0, 65535, 1]) == [65534, 65535, 0, 1])
        #expect(run([0, 65535, 1], startupHold: .milliseconds(8)) == [65535, 0, 1])
    }

    @Test func aJumpOfMoreThanHalfTheNumberSpaceIsFollowed() {
        var buffer = RTPReorderBuffer(startupHold: .zero)
        _ = buffer.push(packet(100), at: epoch)
        _ = buffer.push(packet(101), at: epoch)
        // The Mac went on sending while this side was in the background: 40 000 further on reads
        // as 25 536 behind. It comes out, and so does what follows it.
        #expect(buffer.push(packet(40_101), at: epoch + .milliseconds(1)).map(\.sequence) == [40_101])
        #expect(buffer.push(packet(40_102), at: epoch + .milliseconds(2)).map(\.sequence) == [40_102])
        // A small step back after a long silence is the stream going on, not a straggler.
        var quiet = RTPReorderBuffer(startupHold: .zero)
        _ = quiet.push(packet(100), at: epoch)
        #expect(quiet.push(packet(90), at: epoch + .seconds(2)).map(\.sequence) == [90])
        #expect(quiet.push(packet(91), at: epoch + .seconds(2)).map(\.sequence) == [91])
        // Without the silence it is.
        #expect(quiet.push(packet(85), at: epoch + .seconds(2)).isEmpty)
    }

    @Test func aNewStreamStartsAfreshAndLetsGoOfTheOld() {
        var buffer = RTPReorderBuffer(startupHold: .zero)
        _ = buffer.push(packet(10), at: epoch)
        #expect(buffer.push(packet(12), at: epoch).isEmpty)
        let out = buffer.push(packet(500, ssrc: 8), at: epoch)
        #expect(out.map(\.sequence) == [12, 500])
        #expect(buffer.push(packet(501, ssrc: 8), at: epoch).map(\.sequence) == [501])
        buffer.reset()
        #expect(buffer.push(packet(9, ssrc: 8), at: epoch).map(\.sequence) == [9])
    }

    @Test func randomShufflesWithinTheHoldAlwaysComeOutInOrder() {
        var generator = SeededGenerator(seed: 1)
        for _ in 0..<200 {
            // Each packet is late by up to 10 places, at 1 ms a packet: well within 15 ms.
            let keyed = (0..<200).map { (index: $0, at: Double($0) + Double.random(in: 0..<10, using: &generator)) }
            let arrivals = keyed.sorted { $0.at < $1.at }.map { UInt16(1000 + $0.index) }
            #expect(run(arrivals, startupHold: .milliseconds(12)) == Array(UInt16(1000)..<1200))
        }
    }
}

@Suite struct H264DepacketizerTests {
    private let sps = Data([0x67, 0x64, 0x00, 0x28, 0xac, 0xd9, 0x40, 0x78])
    private let pps = Data([0x68, 0xeb, 0xe3, 0xcb, 0x22, 0xc0])

    private func idr(size: Int = 3000) -> Data {
        Data([0x65]) + Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    }

    private func slice(size: Int = 300, fill: UInt8 = 0x41) -> Data {
        Data([0x41]) + Data(repeating: fill, count: size)
    }

    /// Four bytes, then an `avc1` sample description whose `avcC` box holds the parameter sets.
    private func sampleDescriptionPacket(sps: Data? = nil, pps: Data? = nil) -> Data {
        let (sps, pps) = (sps ?? self.sps, pps ?? self.pps)
        var config = Data([1, sps[1], sps[2], sps[3], 0xff, 0xe1])
        config.append(contentsOf: [UInt8(sps.count >> 8), UInt8(sps.count & 0xff)])
        config.append(sps)
        config.append(1)
        config.append(contentsOf: [UInt8(pps.count >> 8), UInt8(pps.count & 0xff)])
        config.append(pps)
        func box(_ type: String, _ body: Data) -> Data {
            let size = UInt32(8 + body.count)
            return Data([UInt8(size >> 24), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)]) + Data(type.utf8) + body
        }
        let entry = box("avc1", Data(repeating: 0, count: 78) + box("avcC", config))
        return Data([0x92, 0, 0, 0, 0]) + entry
    }

    /// RFC 6184 FU-A fragments of one NAL unit, `size` payload bytes each.
    private func fragments(_ unit: Data, size: Int = 1000) -> [Data] {
        let indicator = unit[0] & 0xe0 | 28
        let type = unit[0] & 0x1f
        let body = unit.dropFirst()
        var result: [Data] = []
        var offset = body.startIndex
        while offset < body.endIndex {
            let end = min(body.endIndex, offset + size)
            var header = type
            if offset == body.startIndex { header |= 0x80 }
            if end == body.endIndex { header |= 0x40 }
            result.append(Data([indicator, header]) + body[offset..<end])
            offset = end
        }
        return result
    }

    private func packets(_ payloads: [Data], from sequence: UInt16, timestamp: UInt32) -> [RTPPacket] {
        payloads.enumerated().map { index, payload in
            rtp(sequence: sequence &+ UInt16(index), timestamp: timestamp, marker: index == payloads.count - 1, payload: payload)
        }
    }

    private func run(_ packets: [RTPPacket]) -> [VideoDepacketizer.Output] {
        var depacketizer = VideoDepacketizer(codec: .h264)
        return packets.map { depacketizer.push($0) }.filter { $0 != .none }
    }

    @Test func aKeyframeComesWithTheParameterSetsFromItsSampleDescription() throws {
        let unit = idr()
        let output = run(packets([sampleDescriptionPacket()] + fragments(unit), from: 10, timestamp: 900))
        guard case .picture(let picture) = try #require(output.first) else {
            Issue.record("no picture: \(output)")
            return
        }
        #expect(output.count == 1)
        #expect(picture.codec == .h264)
        #expect(picture.isKeyframe)
        #expect(picture.nalUnits == [sps, pps, unit])
        #expect(picture.timestamp == 900)
    }

    @Test func parameterSetsSentAsAPictureOfTheirOwnStillReachTheKeyframe() throws {
        var depacketizer = VideoDepacketizer(codec: .h264)
        // The sample description alone, marked as the end of its "picture": no picture comes of it.
        #expect(depacketizer.push(rtp(sequence: 1, timestamp: 100, marker: true, payload: sampleDescriptionPacket())) == .none)
        let unit = idr(size: 500)
        var last = VideoDepacketizer.Output.none
        for packet in packets(fragments(unit, size: 200), from: 2, timestamp: 200) { last = depacketizer.push(packet) }
        guard case .picture(let picture) = last else {
            Issue.record("no keyframe: \(last)")
            return
        }
        #expect(picture.isKeyframe)
        #expect(picture.nalUnits == [sps, pps, unit])
        #expect(depacketizer.withheld == 0)
    }

    @Test func picturesBeforeTheFirstKeyframeAreWithheldAndAfterItDelivered() {
        var all = packets([slice()], from: 1, timestamp: 10)
        all += packets([sampleDescriptionPacket()] + fragments(idr()), from: 2, timestamp: 20)
        let afterKeyframe = UInt16(2 + 1 + fragments(idr()).count)
        all += packets([slice(fill: 1)], from: afterKeyframe, timestamp: 30)
        all += packets([slice(fill: 2)], from: afterKeyframe + 1, timestamp: 40)
        let output = run(all)
        #expect(output.count == 3)
        guard case .picture(let first) = output[0], case .picture(let second) = output[1] else {
            Issue.record("unexpected \(output)")
            return
        }
        #expect(first.isKeyframe && !second.isKeyframe)
        #expect(second.nalUnits == [slice(fill: 1)])
    }

    @Test func aggregationPacketsAreUnpacked() throws {
        func aggregate(_ units: [Data]) -> Data {
            var payload = Data([24])
            for unit in units { payload.append(contentsOf: [UInt8(unit.count >> 8), UInt8(unit.count & 0xff)] + unit) }
            return payload
        }
        let unit = idr(size: 40)
        let output = run([rtp(sequence: 5, timestamp: 1, marker: true, payload: aggregate([sps, pps, unit]))])
        guard case .picture(let picture) = try #require(output.first) else {
            Issue.record("no picture")
            return
        }
        #expect(picture.isKeyframe)
        #expect(picture.nalUnits == [sps, pps, unit])
    }

    @Test func aLossNeedsAKeyframeHoweverTheNextPictureIsMarked() {
        var depacketizer = VideoDepacketizer(codec: .h264)
        // A Mac never marks an H.264 picture as a refresh; even one that claimed to be is not trusted.
        depacketizer.acceptsRefresh = true
        var outputs: [VideoDepacketizer.Output] = []
        let keyframe = packets([sampleDescriptionPacket()] + fragments(idr()), from: 1, timestamp: 10)
        for packet in keyframe { outputs.append(depacketizer.push(packet)) }
        let next = UInt16(1 + keyframe.count)
        // Sequence number `next` is lost.
        outputs.append(depacketizer.push(rtp(sequence: next + 1, timestamp: 30, marker: true, payload: slice())))
        outputs.append(depacketizer.push(rtp(sequence: next + 2, timestamp: 40, marker: true, extensionProfile: 0x9331, payload: slice())))
        let again = packets([sampleDescriptionPacket()] + fragments(idr()), from: next + 3, timestamp: 50)
        for packet in again { outputs.append(depacketizer.push(packet)) }
        let reported = outputs.filter { $0 != .none }
        #expect(reported.count == 3)
        #expect(reported[1] == .loss)
        guard case .picture(let restart) = reported[2] else {
            Issue.record("no restart: \(reported)")
            return
        }
        #expect(restart.isKeyframe && restart.timestamp == 50)
    }

    @Test func numberedPacketsAndBrokenDescriptionsSpoilTheirPicture() {
        // FU-B (29) carries decoding order numbers, which only strips use.
        var fuB = fragments(idr(size: 100), size: 200)[0]
        fuB[0] = fuB[0] & 0xe0 | 29
        #expect(run([rtp(sequence: 1, timestamp: 1, marker: true, payload: fuB)]).isEmpty)
        // A sample description with no avcC in it.
        let empty = Data([0x92, 0, 0, 0, 0]) + Data(repeating: 0x33, count: 90)
        #expect(run(packets([empty] + fragments(idr()), from: 1, timestamp: 1)).isEmpty)
        // One whose avcC claims more than it holds.
        var truncated = sampleDescriptionPacket()
        truncated.removeLast(3)
        #expect(run(packets([truncated] + fragments(idr()), from: 1, timestamp: 1)).isEmpty)
    }

    @Test func sampleDescriptionsOfRandomBytesNeverCrash() {
        var generator = SeededGenerator(seed: 2)
        for _ in 0..<2000 {
            var bytes = (0..<Int.random(in: 0...120, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if bytes.count > 20, Bool.random(using: &generator) {
                let at = Int.random(in: 4...(bytes.count - 4), using: &generator)
                bytes.replaceSubrange(at..<(at + 4), with: Array("avcC".utf8))
            }
            _ = H264NAL.parameterSets(inSampleDescription: Data(bytes))
        }
    }
}
