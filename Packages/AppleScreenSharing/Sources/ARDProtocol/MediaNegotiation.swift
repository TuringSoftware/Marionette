// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// The layout of the offers follows the description and MIT-licensed implementation in
// andrewtheguy/remotex (docs/apple-vnc-889.md, src/vnc_apple_media.rs), © 2026 Andrew Chen.

public import Foundation

/// A minimal protocol-buffers writer: varint and length-delimited fields, which is all the media
/// offers use.
struct ProtobufWriter {
    private(set) var data = Data()

    private mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    mutating func uint(_ field: UInt64, _ value: UInt64) {
        varint(field << 3)
        varint(value)
    }

    mutating func bytes(_ field: UInt64, _ value: Data) {
        varint(field << 3 | 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: UInt64, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: UInt64, _ build: (inout ProtobufWriter) -> Void) {
        var inner = ProtobufWriter()
        build(&inner)
        bytes(field, inner.data)
    }
}

/// Writes the one shape of binary property list the offers need: a flat dictionary of strings to
/// data, small integers and strings, in a given order.
enum BinaryPropertyList {
    enum Value {
        case data(Data)
        case integer(UInt8)
        case string(String)
    }

    static func dictionary(_ entries: [(key: String, value: Value)]) -> Data {
        precondition(entries.count < 15, "the offer dictionary is small")
        func marker(_ output: inout Data, kind: UInt8, count: Int) {
            if count < 15 {
                output.append(kind | UInt8(count))
            } else if count < 256 {
                output.append(contentsOf: [kind | 0x0f, 0x10, UInt8(count)])
            } else {
                output.append(contentsOf: [kind | 0x0f, 0x11, UInt8(count >> 8), UInt8(count & 0xff)])
            }
        }

        var output = Data("bplist00".utf8)
        var offsets: [Int] = []
        let count = entries.count
        // Object 0 is the dictionary: key references 1...n, then value references n+1...2n.
        offsets.append(output.count)
        marker(&output, kind: 0xd0, count: count)
        for index in 0..<count { output.append(UInt8(1 + index)) }
        for index in 0..<count { output.append(UInt8(1 + count + index)) }
        for entry in entries {
            offsets.append(output.count)
            marker(&output, kind: 0x50, count: entry.key.utf8.count)
            output.append(contentsOf: entry.key.utf8)
        }
        for entry in entries {
            offsets.append(output.count)
            switch entry.value {
            case .data(let bytes):
                marker(&output, kind: 0x40, count: bytes.count)
                output.append(bytes)
            case .integer(let value):
                output.append(contentsOf: [0x10, value])
            case .string(let text):
                marker(&output, kind: 0x50, count: text.utf8.count)
                output.append(contentsOf: text.utf8)
            }
        }
        let table = output.count
        precondition(table <= Int(UInt16.max), "offer exceeds two-byte offsets")
        for offset in offsets {
            output.append(contentsOf: [UInt8(offset >> 8), UInt8(offset & 0xff)])
        }
        // Trailer: unused bytes, offset size 2, reference size 1, object count, root, table offset.
        output.append(contentsOf: [0, 0, 0, 0, 0, 0, 2, 1])
        var writer = WireWriter(capacity: 24)
        writer.u64(UInt64(offsets.count))
        writer.u64(0)
        writer.u64(UInt64(table))
        output.append(writer.data)
        return output
    }
}

/// The video codec a Mac is asked to send.
public enum MediaVideoCodec: Sendable, Hashable {
    /// HEVC Range Extensions, 8-bit 4:4:4. Offered alongside H.264; the Mac picks HEVC.
    case hevc
    /// H.264 High, 8-bit 4:2:0. Offered alone, which is the only way to be sent it.
    case h264

    /// The codec an RTP payload type names, if it is one of these.
    public init?(payloadType: UInt8) {
        switch payloadType {
        case 100: self = .hevc
        case 123: self = .h264
        default: return nil
        }
    }

    /// RTP payload type the Mac uses for it.
    public var payloadType: UInt8 {
        switch self {
        case .hevc: 100
        case .h264: 123
        }
    }
}

/// An SRTP master key as the offer carries it: 32 bytes of AES-256 key, then 14 bytes of salt.
public struct MediaKey: Sendable, Hashable {
    public static let length = 46
    public var bytes: Data

    public init(bytes: Data) {
        precondition(bytes.count == Self.length, "an SRTP master key is 46 bytes")
        self.bytes = bytes
    }
}

/// Keys for one leg of the media stream, one per direction.
public struct MediaLegKeys: Sendable, Hashable {
    /// Protects what the viewer sends: its RTCP reports.
    public var viewerToServer: MediaKey
    /// Protects what the Mac sends: media and its own reports.
    public var serverToViewer: MediaKey

    public init(viewerToServer: MediaKey, serverToViewer: MediaKey) {
        self.viewerToServer = viewerToServer
        self.serverToViewer = serverToViewer
    }
}

/// The viewer's side of a media-stream negotiation: what it offers the Mac in message `0x1c`.
public struct MediaOffer: Sendable {
    public struct Video: Sendable {
        /// The viewer's SSRC on this leg. The Mac only reads reports that lead with it.
        public var ssrc: UInt32
        public var keys: MediaLegKeys
        /// The display's size in backing pixels.
        public var width: UInt16
        public var height: UInt16
        public var codec: MediaVideoCodec
        /// Pictures per frame: 1 for the whole display in one picture, 4 for Apple's four strips.
        public var tilesPerFrame: Int
        /// Offer HDR pictures as well as SDR ones. Apple's viewer does so for a leg whose port the
        /// Mac marked HDR (``MediaReply/ports(audio:video:secondVideo:hdr:)``).
        public var offersHDR: Bool

        public init(ssrc: UInt32, keys: MediaLegKeys, width: UInt16, height: UInt16, codec: MediaVideoCodec, tilesPerFrame: Int, offersHDR: Bool = false) {
            self.ssrc = ssrc
            self.keys = keys
            self.width = width
            self.height = height
            self.codec = codec
            self.tilesPerFrame = tilesPerFrame
            self.offersHDR = offersHDR
        }
    }

    public struct Flags: OptionSet, Sendable {
        public var rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// Configure the first video stream for 60 frames a second where the Mac's encoder allows.
        public static let sixtyFramesPerSecond = Flags(rawValue: 0x1)
        /// The same for the second video stream.
        public static let sixtyFramesPerSecondSecondStream = Flags(rawValue: 0x2)
        /// Capture without the pointer, which the viewer then draws itself.
        public static let omitCursor = Flags(rawValue: 0x4)
    }

    /// Which of the Mac's media configurations the pictures are negotiated under. AVConference
    /// sets each one's bitrate range and rate control from it (`+negotiatorSettingsForMode:`).
    public enum BandwidthProfile: UInt8, Sendable, Hashable {
        /// Negotiator mode 7, remote-desktop screen sharing: 20–60 Mbit/s. Apple's viewer's.
        case full = 7
        /// Negotiator mode 5, CoreDevice screen sharing: 0.33–6 Mbit/s, for paths that cannot
        /// carry the full rate.
        case constrained = 5
    }

    /// Identifies the session in every offer of it.
    public var sessionID: UUID
    public var bandwidthProfile: BandwidthProfile = .full
    public var flags: Flags
    public var audioSSRC: UInt32
    public var audioKeys: MediaLegKeys
    /// One per virtual display, in the Mac's order.
    public var videos: [Video]

    public init(sessionID: UUID, flags: Flags, audioSSRC: UInt32, audioKeys: MediaLegKeys, videos: [Video]) {
        precondition((1...2).contains(videos.count), "one or two video legs")
        self.sessionID = sessionID
        self.flags = flags
        self.audioSSRC = audioSSRC
        self.audioKeys = audioKeys
        self.videos = videos
    }

    // MARK: Constants captured from Apple's viewer

    private static let audioMode: UInt8 = 8
    private static let libraryName = "Viceroy 1.7.0"
    private static let audioField13: UInt64 = 17_169_649_764_059_066_368
    private static let videoField13: UInt64 = 17_169_649_764_516_085_760

    /// The viewer's model and builds, as Apple's client reports them.
    private static let remoteEndpointInfo: Data = {
        var info = ProtobufWriter()
        info.uint(1, 0)
        info.uint(2, 1)
        info.string(3, "VirtualMac2,1")
        info.string(4, "2215.5.1")
        info.string(5, "25G83")
        return info.data
    }()

    /// Audio codecs and, with a first field of zero, bitrate ceilings in bits per second. The third
    /// field says which connections an entry applies to; Screen Sharing's is the 60 Mbit/s one.
    private static let codecEntries: [(UInt64, UInt64, UInt64?)] = [
        (1, 299, nil),
        (4074, 0, 16_384),
        (0, 75_000_000, 524_288),
        (0, 20_000_000, 98_304),
        (0, 40_000_000, 12_288),
        (0, 60_000_000, 262_144),
        (16, 4100, nil),
        (0, 100_000_000, 1_048_576),
        (4, 6500, nil),
        (0, 6_000_000, 131_072),
    ]

    private static func tail(_ blob: inout ProtobufWriter, entries: [(UInt64, UInt64, UInt64?)], field13: UInt64) {
        blob.string(6, libraryName)
        blob.uint(8, 0)
        for entry in entries {
            blob.message(9) { message in
                message.uint(1, entry.0)
                message.uint(2, entry.1)
                if let third = entry.2 { message.uint(3, third) }
            }
        }
        blob.uint(13, field13)
        blob.uint(14, 2)
        blob.uint(16, 0)
    }

    static func audioBlob(ssrc: UInt32) -> Data {
        var blob = ProtobufWriter()
        blob.uint(1, 1)
        blob.uint(2, 1)
        blob.message(3) { stream in
            stream.uint(1, UInt64(ssrc))
            stream.uint(2, 0)
            stream.uint(3, 0)
            // The RTP payload types the viewer takes, one bit each; 0x1000 is AAC-ELD's 101.
            stream.uint(4, 0x5E7F)
            stream.uint(5, 0)
            stream.uint(6, 0)
        }
        tail(&blob, entries: codecEntries, field13: audioField13)
        return blob.data
    }

    static func videoBlob(_ video: Video) -> Data {
        func codec(_ stream: inout ProtobufWriter, id: UInt64, levels: [UInt64], features: String, field4: UInt64) {
            stream.message(3) { codec in
                codec.uint(1, id)
                for level in levels {
                    codec.message(2) { entry in
                        entry.uint(1, 1)
                        entry.uint(2, level)
                        entry.uint(3, 50_115)
                        entry.uint(4, 0)
                    }
                }
                codec.string(3, features)
                codec.uint(4, field4)
            }
        }
        var blob = ProtobufWriter()
        blob.uint(1, 1)
        blob.uint(2, 1)
        blob.message(5) { stream in
            stream.uint(1, UInt64(video.ssrc))
            stream.uint(2, 0)
            codec(&stream, id: 123, levels: [1, 2, 1, 2], features: "FLS;MS:-1;LF:-1;LTR;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:4/3,5/8;XR:4/3,5/8;", field4: 1)
            if video.codec == .hevc {
                codec(&stream, id: 100, levels: [1, 2], features: "FLS;LF:-1;POS:5;EOD:1;HTS:2;RR:3;POSE:4;AR:4/3,5/8;XR:4/3,5/8;", field4: 14)
            }
            stream.uint(4, UInt64(video.width))
            stream.uint(5, UInt64(video.height))
            stream.uint(6, UInt64(video.tilesPerFrame))
            stream.uint(7, 1)
            stream.uint(8, 63)
            // The HDR modes the viewer takes, a bit for each: mode 0 is SDR; Apple's viewer adds
            // mode 3 for an HDR display.
            stream.uint(9, video.offersHDR ? 0b1001 : 0b1)
            stream.uint(12, 1)
        }
        // The same entries with the 40 Mbit/s one moved to the front, as Apple's viewer orders them.
        var entries = codecEntries
        entries.insert(entries.remove(at: 4), at: 0)
        tail(&blob, entries: entries, field13: videoField13)
        return blob.data
    }

    private func wrapped(mode: UInt8, blob: Data) -> Data {
        BinaryPropertyList.dictionary([
            ("avcMediaStreamOptionRemoteEndpointInfo", .data(Self.remoteEndpointInfo)),
            ("avcMediaStreamNegotiatorMode", .integer(mode)),
            ("avcMediaStreamNegotiatorMediaBlob", .data(Deflate.compress(blob, level: -1))),
            ("avcMediaStreamOptionCallID", .string(sessionID.uuidString.uppercased())),
        ])
    }

    /// The complete `0x1c` message.
    public func message() -> Data {
        let audio = wrapped(mode: Self.audioMode, blob: Self.audioBlob(ssrc: audioSSRC))
        let videoOffers = videos.map { wrapped(mode: bandwidthProfile.rawValue, blob: Self.videoBlob($0)) }

        var writer = WireWriter(capacity: 0x80 + audio.count + videoOffers.reduce(0) { $0 + $1.count + 92 })
        writer.u8(ClientMessageType.mediaOffer)
        writer.u8(0)
        writer.u16(0) // body length, filled in below
        writer.u16(3) // version
        writer.u32(flags.rawValue)
        writer.u16(UInt16(audio.count))
        writer.u16(UInt16(videoOffers[0].count))
        writer.u16(videoOffers.count > 1 ? UInt16(videoOffers[1].count) : 0)
        writer.u32(0)
        writer.bytes(withUnsafeBytes(of: sessionID.uuid) { Data($0) })
        writer.bytes(audioKeys.viewerToServer.bytes)
        writer.bytes(audioKeys.serverToViewer.bytes)
        precondition(writer.count == 0x80)
        writer.bytes(audio)
        for (video, offer) in zip(videos, videoOffers) {
            writer.bytes(video.keys.viewerToServer.bytes)
            writer.bytes(video.keys.serverToViewer.bytes)
            writer.bytes(offer)
        }
        var message = writer.data
        let bodyLength = message.count - 4
        precondition(bodyLength <= Int(UInt16.max), "media offer exceeds its length field")
        message[2] = UInt8(bodyLength >> 8)
        message[3] = UInt8(bodyLength & 0xff)
        return message
    }
}

/// What a Mac says about the media stream, carried in rectangles of the media-stream encoding.
public enum MediaReply: Sendable, Equatable {
    /// The Mac is ready for an offer. Media will come from these ports on the Mac to the same port
    /// numbers on the viewer. `hdr` has an entry for each picture port, in order: whether the Mac
    /// marked it HDR.
    case ports(audio: UInt16, video: UInt16, secondVideo: UInt16?, hdr: [Bool])
    /// The Mac accepted the offer; the stream starts.
    case answer(videoLegs: Int)
    /// The Mac could not start the stream.
    case failure(MediaFailure)
    case unknown(type: UInt16)

    public static func parse(_ body: Data) throws(WireError) -> MediaReply {
        var reader = WireReader(body)
        guard reader.remaining >= 8 else { throw .malformed("media-stream reply of \(reader.remaining) bytes") }
        let type = try reader.u16()
        try reader.skip(6) // version and flags
        switch type {
        case 1:
            guard reader.remaining >= 28 else { throw .malformed("media-stream port message of \(body.count) bytes") }
            // Bit 0 of each port's flags word marks it as in use. Every Mac seen sets it for sound and
            // the first picture; what clearing it would mean is unknown, so those two ports are taken
            // as named and the session's own checks decide whether they can be used. Bit 1 of a
            // picture port's word marks its display HDR: Apple's viewer then offers HDR pictures.
            let audioPort = try reader.u16()
            try reader.skip(4)
            let videoPort = try reader.u16()
            let videoFlags = try reader.u32()
            let secondPort = try reader.u16()
            let secondFlags = try reader.u32()
            let hasSecond = secondFlags & 1 != 0
            var hdr = [videoFlags & 2 != 0]
            if hasSecond { hdr.append(secondFlags & 2 != 0) }
            return .ports(audio: audioPort, video: videoPort, secondVideo: hasSecond ? secondPort : nil, hdr: hdr)
        case 2:
            guard reader.remaining >= 10 else { throw .malformed("media-stream answer of \(body.count) bytes") }
            let audio = Int(try reader.u16())
            let video = Int(try reader.u16())
            let second = Int(try reader.u16())
            try reader.skip(4)
            // Bytes after the three parts may be a field a later macOS adds; they are not read.
            guard reader.remaining >= audio + video + second else {
                throw .malformed("media-stream answer lengths do not describe its \(body.count) bytes")
            }
            return .answer(videoLegs: second == 0 ? 1 : 2)
        case 3:
            guard reader.remaining >= 8 else { throw .malformed("media-stream error of \(body.count) bytes") }
            let kind = try reader.u32()
            let subCode = try reader.u32()
            if kind == 1, subCode == 1 { return .failure(.heldByAnotherViewer) }
            if kind == 2 { return .failure(.noConfiguration) }
            return .failure(.other(kind: kind, subCode: subCode))
        default:
            return .unknown(type: type)
        }
    }
}

public enum MediaFailure: Sendable, Hashable {
    /// Another viewer already holds this Mac's media stream. A Mac gives it to one viewer at a time.
    case heldByAnotherViewer
    /// The Mac could make no stream configuration from the offer.
    case noConfiguration
    case other(kind: UInt32, subCode: UInt32)
}
