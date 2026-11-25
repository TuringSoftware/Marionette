// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Mac-specific packet layouts follow the description and MIT-licensed implementation in
// andrewtheguy/remotex (docs/apple-vnc-889.md, src/vnc_apple_media.rs), © 2026 Andrew Chen.

public import Foundation

/// What a datagram on a media port is.
public enum MediaPacketKind: Sendable, Equatable {
    case rtp
    case rtcp
    case neither

    /// RTCP packet types 192–223 (RFC 5761, 4) occupy the whole second byte, where RTP would read
    /// payload types 64–95, which are never used for media.
    public static func classify(_ datagram: Data) -> MediaPacketKind {
        guard datagram.count >= 8, datagram[datagram.startIndex] >> 6 == 2 else { return .neither }
        return (192...223).contains(datagram[datagram.startIndex + 1]) ? .rtcp : .rtp
    }

    /// The SSRC an RTP or RTCP datagram claims, read before it is authenticated: the field is sent
    /// in the clear, so a receiver can turn away streams it does not want without paying for the
    /// authentication.
    public static func claimedSSRC(_ datagram: Data) -> UInt32? {
        guard datagram.count >= 12 else { return nil }
        let base = datagram.startIndex + (classify(datagram) == .rtcp ? 4 : 8)
        return datagram[base..<(base + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}

/// What a Mac's video packets say about their picture, in the slot of the RTP header extension.
///
/// It is not an RFC 8285 extension: the first two bytes, where a profile would be, are themselves
/// fields (they read `93 01` on macOS 27, with the long-term-reference bits added). Byte 0 is a
/// version in its top two bits and a camera status; byte 1 holds the long-term-reference bits in
/// its high nibble and says which optional words follow in its low one. The layout follows
/// rootshell-vnc's `AppleMediaRTPMediaControlInfo` (MIT, © 2026 Rootshell LLC, Kit Knox).
public struct MediaControlInfo: Sendable, Equatable {
    /// The two bytes as sent.
    public var profile: UInt16
    public var version: UInt8 { UInt8(profile >> 14) }
    public var cameraStatus: UInt8 { UInt8(profile >> 8) & 0x3f }
    /// Bit 0: the Mac keeps this picture for the viewer to acknowledge. Bit 1: the picture is
    /// predicted only from one the viewer acknowledged.
    public var longTermReference: UInt8 { UInt8(truncatingIfNeeded: profile >> 4) & 0x0f }
    /// Present when byte 1 has `0x02`. Little-endian on the wire, unlike everything around it.
    public var longTermReferenceTimestamp: UInt32?
    /// Present when byte 1 has `0x01`, which a Mac's screen stream always sets: how many packets
    /// the picture is sent in, and the picture's own running number.
    public var framePacketCount: UInt16?
    public var frameSequence: UInt16?

    /// What every Mac seen so far sends; anything else is worth a note in the log.
    public var isFamiliar: Bool { profile >> 8 == 0x93 }

    public init(profile: UInt16, longTermReferenceTimestamp: UInt32? = nil, framePacketCount: UInt16? = nil, frameSequence: UInt16? = nil) {
        self.profile = profile
        self.longTermReferenceTimestamp = longTermReferenceTimestamp
        self.framePacketCount = framePacketCount
        self.frameSequence = frameSequence
    }

    /// Reads the fields from an extension's profile and words, or `nil` for an extension that is
    /// not this one (an RFC 8285 extension, or an unknown version).
    static func parse(profile: UInt16, words: Data) -> MediaControlInfo? {
        guard (1...3).contains(profile >> 14), profile != 0xBEDE else { return nil }
        var info = MediaControlInfo(profile: profile)
        var reader = WireReader(words)
        if profile & 0x02 != 0 {
            guard let value = try? reader.u32() else { return nil }
            info.longTermReferenceTimestamp = value.byteSwapped
        }
        if profile & 0x01 != 0, profile >> 14 == 2 {
            guard let count = try? reader.u16(), let sequence = try? reader.u16() else { return nil }
            info.framePacketCount = count
            info.frameSequence = sequence
        }
        return info
    }
}

/// The header of a decrypted RTP packet and where its payload lies.
public struct RTPPacket: Sendable, Equatable {
    public var payloadType: UInt8
    /// Set on the last packet of a picture.
    public var marker: Bool
    public var sequence: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    /// The Mac's mark on a picture it keeps so that the viewer can acknowledge it.
    public var wantsAcknowledgement: Bool
    /// The Mac's mark on a picture predicted only from one the viewer acknowledged.
    public var isRefresh: Bool
    /// The Mac's picture fields, when the packet carries them.
    public var mediaControl: MediaControlInfo?
    public var payload: Data

    public init(
        payloadType: UInt8, marker: Bool, sequence: UInt16, timestamp: UInt32, ssrc: UInt32,
        wantsAcknowledgement: Bool = false, isRefresh: Bool = false, mediaControl: MediaControlInfo? = nil, payload: Data
    ) {
        self.payloadType = payloadType
        self.marker = marker
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.wantsAcknowledgement = wantsAcknowledgement
        self.isRefresh = isRefresh
        self.mediaControl = mediaControl
        self.payload = payload
    }

    /// Parses a packet. The payload shares the packet's storage rather than being copied.
    public static func parse(_ packet: Data) throws(WireError) -> RTPPacket {
        var reader = WireReader(packet)
        let first = try reader.u8()
        guard first >> 6 == 2 else { throw .malformed("not RTP version 2") }
        let second = try reader.u8()
        let sequence = try reader.u16()
        let timestamp = try reader.u32()
        let ssrc = try reader.u32()
        try reader.skip(4 * Int(first & 0x0f)) // contributing sources
        var mediaControl: MediaControlInfo?
        if first & 0x10 != 0 {
            let profile = try reader.u16()
            let words = try reader.take(4 * Int(try reader.u16()))
            mediaControl = MediaControlInfo.parse(profile: profile, words: words)
        }
        var end = packet.endIndex
        if first & 0x20 != 0 {
            guard let count = packet.last, count > 0, Int(count) <= reader.remaining else {
                throw .malformed("RTP padding exceeds the packet")
            }
            end -= Int(count)
        }
        let reference = mediaControl?.longTermReference ?? 0
        return RTPPacket(
            payloadType: second & 0x7f, marker: second & 0x80 != 0,
            sequence: sequence, timestamp: timestamp, ssrc: ssrc,
            wantsAcknowledgement: reference & 0x1 != 0, isRefresh: reference & 0x2 != 0,
            mediaControl: mediaControl,
            payload: packet[(packet.startIndex + reader.offset)..<end]
        )
    }
}

/// The RTCP packets a viewer sends a Mac. Each is complete and unprotected; all go out as SRTCP.
///
/// A Mac reads a datagram only if its first packet names the SSRC the viewer put in its offer.
public enum RTCPMessage {
    public static let senderReportType: UInt8 = 200
    public static let receiverReportType: UInt8 = 201

    private static func header(_ first: UInt8, type: UInt8, words: UInt16, ssrc: UInt32) -> WireWriter {
        var writer = WireWriter(capacity: 32)
        writer.u8(first)
        writer.u8(type)
        writer.u16(words)
        writer.u32(ssrc)
        return writer
    }

    /// A receiver report with no report blocks. A Mac stops a stream that hears none for a while.
    public static func receiverReport(ssrc: UInt32) -> Data {
        header(0x80, type: receiverReportType, words: 1, ssrc: ssrc).data
    }

    /// What a receiver report says about the stream it reports on (RFC 3550, 6.4.1).
    public struct ReceptionReport: Sendable, Equatable {
        public var mediaSSRC: UInt32
        /// Share of packets lost since the last report, as a fraction of 256.
        public var fractionLost: UInt8
        /// Packets lost since the stream began; 24 bits on the wire.
        public var cumulativeLost: UInt32
        public var extendedHighestSequence: UInt32
        public var jitter: UInt32
        /// The middle 32 bits of the NTP time in the sender's latest report, or 0 before one came.
        public var lastSenderReport: UInt32
        /// How long ago that report arrived, in units of 1/65536 s.
        public var delaySinceLastSenderReport: UInt32

        public init(
            mediaSSRC: UInt32, fractionLost: UInt8, cumulativeLost: UInt32, extendedHighestSequence: UInt32,
            jitter: UInt32, lastSenderReport: UInt32, delaySinceLastSenderReport: UInt32
        ) {
            self.mediaSSRC = mediaSSRC
            self.fractionLost = fractionLost
            self.cumulativeLost = cumulativeLost
            self.extendedHighestSequence = extendedHighestSequence
            self.jitter = jitter
            self.lastSenderReport = lastSenderReport
            self.delaySinceLastSenderReport = delaySinceLastSenderReport
        }
    }

    /// A receiver report with one report block, from which the Mac can work out the round trip.
    public static func receiverReport(ssrc: UInt32, report: ReceptionReport) -> Data {
        var writer = header(0x81, type: receiverReportType, words: 7, ssrc: ssrc)
        writer.u32(report.mediaSSRC)
        writer.u32(UInt32(report.fractionLost) << 24 | (report.cumulativeLost & 0x00ff_ffff))
        writer.u32(report.extendedHighestSequence)
        writer.u32(report.jitter)
        writer.u32(report.lastSenderReport)
        writer.u32(report.delaySinceLastSenderReport)
        return writer.data
    }

    /// A source description with one chunk holding an empty CNAME, which Apple's viewer puts after
    /// the receiver report on its sound leg (with the SRTCP trailer the datagram is 58 bytes).
    public static func sourceDescription(ssrc: UInt32) -> Data {
        var writer = header(0x81, type: 202, words: 2, ssrc: ssrc)
        writer.u32(0x0100_0000) // CNAME, length 0; then the end of the list, padded to a word
        return writer.data
    }

    /// The middle 32 bits of the NTP timestamp of a sender report, which a receiver report echoes.
    public static func senderReportTime(_ packet: Data) -> UInt32? {
        guard packet.count >= 16, packet[packet.startIndex + 1] == senderReportType else { return nil }
        let base = packet.startIndex + 8
        let seconds = UInt32(packet[base + 2]) << 8 | UInt32(packet[base + 3])
        let fraction = UInt32(packet[base + 4]) << 8 | UInt32(packet[base + 5])
        return seconds << 16 | fraction
    }

    /// Acknowledges a picture the viewer has whole. `picture` is what the Mac filed it under: its
    /// RTP timestamp in a stream of one picture per frame, its decoding order number in strips.
    /// Must be alone in its datagram.
    public static func acknowledgement(ssrc: UInt32, picture: UInt32) -> Data {
        var writer = header(0x80, type: 204, words: 3, ssrc: ssrc)
        writer.u32(5) // the APP packet's "name"
        writer.u32(picture)
        return writer.data
    }

    /// Picture Loss Indication: the Mac answers with a keyframe.
    public static func pictureLoss(ssrc: UInt32, mediaSSRC: UInt32) -> Data {
        var writer = header(0x81, type: 206, words: 2, ssrc: ssrc)
        writer.u32(mediaSSRC)
        return writer.data
    }

    /// Asks for a picture to go on from after a loss: one predicted from the last acknowledged
    /// picture where there is one, otherwise a keyframe smaller than a PLI brings.
    public static func refreshRequest(ssrc: UInt32, mediaSSRC: UInt32, width: UInt16, height: UInt16) -> Data {
        var writer = header(0x82, type: 206, words: 3, ssrc: ssrc)
        writer.u32(mediaSSRC)
        writer.u16(width)
        writer.u16(height)
        return writer.data
    }

    /// The sender SSRC and packet type of the first packet in an RTCP datagram.
    public static func leading(_ datagram: Data) -> (type: UInt8, ssrc: UInt32)? {
        guard datagram.count >= 8 else { return nil }
        let base = datagram.startIndex
        let ssrc = datagram[(base + 4)..<(base + 8)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (datagram[base + 1], ssrc)
    }
}

/// Builds the rate report a Mac's encoder is steered by.
///
/// The Mac's rate controller acts only on these reports: without them its target stands still. What
/// moves it is the one-way delay — how much later pictures arrive than their timestamps say they
/// were sent, relative to the best case seen — which is the signature of a queue building on the
/// path — and bursts of loss.
public struct RateFeedback: Sendable {
    /// The picture leg's RTP clock, in ticks a second.
    static let videoClock = 24_000.0
    /// The bandwidth reported, in kbit/s, until the estimate has a figure: the Mac's own ceiling
    /// for this kind of stream. The field caps the Mac's rate controller (see
    /// ``ReceiveBandwidthEstimator``), so anything less would hold the stream back for nothing.
    static let reportedBandwidth: UInt16 = 60_000
    /// A lag this far from either average is a jumped clock, not a queue.
    static let spuriousLag = 30.0
    /// The burst field is a nibble.
    static let maximumBurst = 15

    private let epoch: ContinuousClock.Instant
    private var mediaSSRC: UInt32?
    /// The newest picture seen, latched at its first packet: its timestamp, when that packet
    /// arrived, and the running count of packets then. Apple's viewer
    /// (`-[VCVideoStreamRateAdaptationFeedbackOnly updateRTPReceiveWithTimestamp:…]`) records the
    /// three only for the first packet of a newer timestamp, so a straggler from an older picture
    /// or the rest of the same picture leaves them alone.
    private var newest: (timestamp: UInt32, arrival: ContinuousClock.Instant, count: UInt32)?
    private var received: UInt32 = 0
    /// The longest run of packets lost together since the last report.
    private var burst = 0
    private var bandwidth = ReceiveBandwidthEstimator()

    private var first: ContinuousClock.Instant?
    private var previousTimestamp: UInt32 = 0
    private var ticks: UInt64 = 0
    private var shortAverage = 0.0
    private var longAverage = 0.0
    /// The one-way relative delay the next report carries, in seconds.
    public private(set) var delay = 0.0
    /// What the path is estimated to carry, in kbit/s, or 0 before the first measurement.
    public var bandwidthEstimate: UInt16 { bandwidth.rctlKbps }

    public init(epoch: ContinuousClock.Instant) {
        self.epoch = epoch
    }

    /// Records an authentic picture packet. Each new stream (new SSRC) starts the estimate again.
    ///
    /// - Parameters:
    ///   - size: The packet's size, for the bandwidth estimate.
    ///   - marker: Whether it ends its picture.
    ///   - startsProbe: Whether its payload may start a measured train: see
    ///     ``ReceiveBandwidthEstimator/startsProbe(payloadFirstByte:)``.
    public mutating func received(
        ssrc: UInt32, timestamp: UInt32, at arrival: ContinuousClock.Instant,
        size: Int = 0, marker: Bool = false, startsProbe: Bool = false
    ) {
        if ssrc != mediaSSRC {
            self = RateFeedback(epoch: epoch)
            mediaSSRC = ssrc
        }
        received &+= 1
        if size > 0 {
            bandwidth.notePacket(
                arrivalSeconds: Self.seconds(arrival - epoch), rtpTimestamp: timestamp, sizeBytes: size,
                marker: marker, startsProbe: startsProbe
            )
        }
        if let newest {
            // Newer means ahead by less than 0x7fffffff, as Apple's viewer reckons it.
            let ahead = timestamp &- newest.timestamp
            guard ahead != 0, ahead < 0x7fff_ffff else { return }
        }
        newest = (timestamp, arrival, received)

        // Only the first packet of a newer picture is a sample.
        guard let first else {
            restart(timestamp: timestamp, arrival: arrival)
            return
        }
        let step = timestamp &- previousTimestamp
        previousTimestamp = timestamp
        ticks += UInt64(step)
        let lag = Self.seconds(arrival - first) - Double(ticks) / Self.videoClock
        if lag - shortAverage > Self.spuriousLag || longAverage - lag > Self.spuriousLag {
            restart(timestamp: timestamp, arrival: arrival)
            return
        }
        longAverage = 0.9999 * longAverage + 0.0001 * lag
        shortAverage = 0.9 * shortAverage + 0.1 * lag
        delay = shortAverage - longAverage
        if delay < 0 {
            longAverage = shortAverage
            delay = 0
        }
    }

    /// Records packets found missing together: a gap of `run` in the sequence numbers.
    ///
    /// The report's burst nibble is what Apple calls the "max frame burst loss", the longest run of
    /// packets lost within a picture; a Mac that hears 5 or more ramps its rate down to its floor.
    public mutating func lost(run: Int) {
        burst = max(burst, min(run, Self.maximumBurst))
    }

    private mutating func restart(timestamp: UInt32, arrival: ContinuousClock.Instant) {
        first = arrival
        previousTimestamp = timestamp
        ticks = 0
        shortAverage = 0
        longAverage = 0
        delay = 0
    }

    /// The report to send now, once there is a picture packet to echo. Must be alone in its datagram.
    /// A burst of loss is reported once.
    public mutating func report(ssrc: UInt32, now: ContinuousClock.Instant) -> Data? {
        guard let newest else { return nil }
        var writer = WireWriter(capacity: 32)
        writer.u8(0x80)
        writer.u8(204)
        writer.u16(7)
        writer.u32(ssrc)
        writer.bytes("RCTL".utf8)
        writer.u8(0x85)
        writer.u8(0) // a delay the Mac ignores
        writer.u16(4) // payload words after this field
        writer.u16(UInt16(truncatingIfNeeded: newest.timestamp >> 8)) // echo
        writer.u32(0)
        writer.u16(UInt16(clamping: Int(Self.seconds(now - newest.arrival) * 1000))) // held for, ms
        writer.u16(UInt16(truncatingIfNeeded: Int(Self.seconds(now - epoch) * 1024))) // viewer clock
        writer.u16(UInt16(clamping: Int(delay * 8192)))
        writer.u16(UInt16(burst) << 12 | UInt16(newest.count & 0xfff)) // bursty loss; running count
        let estimate = bandwidth.rctlKbps
        writer.u16(estimate == 0 ? Self.reportedBandwidth : estimate)
        burst = 0
        return writer.data
    }

    private static func seconds(_ duration: Duration) -> Double {
        max(0, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}

/// Counts how many packets a sender has sent on one stream, from the sequence numbers that arrive,
/// so that the share that went missing can be worked out (RFC 3550, appendix A.3).
public struct SequenceTracker: Sendable, Equatable {
    /// How far behind the newest a packet may be and still be a straggler. Further back than the
    /// SRTP replay window is a sender that jumped ahead by more than half the number space (a Mac
    /// does after the viewer spent a while in the background), not a late packet.
    public static let maximumLateness = 2048

    private var first: UInt32?
    /// The highest sequence number seen, extended past 16 bits by the number of wraps.
    private var highest: UInt32 = 0
    /// Packets expected before the numbering last jumped.
    private var expectedBeforeJump = 0

    public init() {}

    public mutating func note(_ sequence: UInt16) {
        guard let first else {
            first = UInt32(sequence)
            highest = UInt32(sequence)
            return
        }
        // Ahead by less than half the number space is newer; a little behind is a straggler.
        let ahead = Int(Int16(bitPattern: sequence &- UInt16(truncatingIfNeeded: highest)))
        if ahead > 0 {
            highest &+= UInt32(ahead)
        } else if ahead < -Self.maximumLateness {
            // The numbering jumped: count on from here, without the jump as loss.
            expectedBeforeJump += Int(highest &- first) + 1
            let jumped = (highest & 0xffff_0000) | UInt32(sequence)
            highest = jumped > highest ? jumped : jumped &+ 0x1_0000
            self.first = highest
        }
    }

    /// The newest sequence number seen, extended past 16 bits.
    public var extendedHighest: UInt32 { highest }

    /// Packets the sender must have sent between the first and the newest one seen.
    public var expected: Int {
        first.map { expectedBeforeJump + Int(highest &- $0) + 1 } ?? 0
    }
}
