// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation

/// One coded picture: every NAL unit that shares an RTP timestamp, in order, without start codes.
public struct AccessUnit: Sendable, Equatable {
    public var codec: MediaVideoCodec
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var nalUnits: [Data]
    /// Starts a decodable sequence: an intra picture together with its parameter sets.
    public var isKeyframe: Bool
    /// The Mac's mark on a picture predicted only from one the viewer acknowledged.
    public var isRefresh: Bool
    /// The Mac asked for this picture to be acknowledged.
    public var wantsAcknowledgement: Bool

    /// The picture as an Annex B byte stream: each NAL unit behind a four-byte start code.
    public var annexB: Data {
        var output = Data(capacity: nalUnits.reduce(0) { $0 + $1.count + 4 })
        for unit in nalUnits {
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(unit)
        }
        return output
    }
}

/// HEVC NAL unit types this client looks at (ITU-T H.265 table 7-1) and RFC 7798's packet types.
enum HEVCNAL {
    static let idrWithRADL: UInt8 = 19
    static let idrNoLP: UInt8 = 20
    static let cra: UInt8 = 21
    static let vps: UInt8 = 32
    static let sps: UInt8 = 33
    static let pps: UInt8 = 34
    static let aggregation: UInt8 = 48
    static let fragmentation: UInt8 = 49
    /// RFC 7798's PACI packet, which a Mac never sends; it and the unspecified types after it are
    /// no NAL unit a decoder can take.
    static let paci: UInt8 = 50

    static func type(_ firstByte: UInt8) -> UInt8 {
        firstByte >> 1 & 0x3f
    }
}

/// H.264 NAL unit types this client looks at (ITU-T H.264 table 7-1) and RFC 6184's packet types.
enum H264NAL {
    static let idr: UInt8 = 5
    static let sps: UInt8 = 7
    static let pps: UInt8 = 8
    /// Reserved in H.264. A Mac uses it, with the forbidden bit set, for a packet that carries the
    /// stream's parameter sets inside an MP4 `avc1` sample description.
    static let appleSampleDescription: UInt8 = 18
    static let aggregation: UInt8 = 24
    static let fragmentation: UInt8 = 28

    static func type(_ firstByte: UInt8) -> UInt8 {
        firstByte & 0x1f
    }

    /// The SPS and PPS units of an `avcC` box (ISO/IEC 14496-15, 5.3.3.1) found anywhere in `data`.
    static func parameterSets(inSampleDescription data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        let tag: [UInt8] = Array("avcC".utf8)
        guard bytes.count >= 8, let at = (4...(bytes.count - 4)).first(where: { Array(bytes[$0..<($0 + 4)]) == tag }) else { return nil }
        let boxSize = Int(bytes[at - 4]) << 24 | Int(bytes[at - 3]) << 16 | Int(bytes[at - 2]) << 8 | Int(bytes[at - 1])
        let end = min(bytes.count, at - 4 + max(boxSize, 0))
        var offset = at + 4
        // configurationVersion, profile, compatibility, level, lengthSizeMinusOne.
        offset += 5
        var units: [Data] = []
        func read(count: Int) -> Bool {
            for _ in 0..<count {
                guard offset + 2 <= end else { return false }
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard length > 0, offset + length <= end else { return false }
                units.append(Data(bytes[offset..<(offset + length)]))
                offset += length
            }
            return true
        }
        guard offset < end else { return nil }
        let spsCount = Int(bytes[offset] & 0x1f)
        offset += 1
        guard read(count: spsCount), offset < end else { return nil }
        let ppsCount = Int(bytes[offset])
        offset += 1
        guard read(count: ppsCount) else { return nil }
        let types = units.map { type($0[$0.startIndex]) }
        guard types.contains(sps), types.contains(pps) else { return nil }
        return units
    }
}

/// Alias of ``VideoDepacketizer`` for callers of its HEVC-only name.
public typealias HEVCDepacketizer = VideoDepacketizer

/// Reassembles the pictures of one RTP video stream as a Mac sends a whole display: HEVC
/// (RFC 7798) or H.264 (RFC 6184, packetization mode 1).
///
/// Packets must be fed in sending order. A gap in the sequence numbers spoils the picture it falls
/// in and every picture after it until one the stream can restart from; the depacketizer reports
/// the loss once and then stays quiet until that picture arrives. A picture right after a gap is
/// spoiled too, unless the packet count a Mac puts in every packet shows that none of its own
/// packets went missing.
public struct VideoDepacketizer: Sendable {
    public enum Output: Sendable, Equatable {
        /// The packet was taken; nothing is complete yet.
        case none
        case picture(AccessUnit)
        /// Packets were lost. Ask the Mac for a picture to restart from.
        case loss
    }

    public let codec: MediaVideoCodec
    private var ssrc: UInt32?
    private var nextSequence: UInt16?
    /// H.264's latest parameter sets. A Mac sends them only with a keyframe, inside a sample
    /// description, and a keyframe whose parameter sets came separately still needs them.
    private var parameterSets: [Data] = []
    private var timestamp: UInt32?
    private var units: [Data] = []
    private var fragment: Data?
    /// NAL bytes gathered for the picture so far, fragment included.
    private var gathered = 0
    private var pictureSpoiled = false
    /// The picture's first packet came after a gap, which may have taken its own first packets.
    private var pictureFollowsGap = false
    /// Packets of the picture taken, and how many the Mac says it sent.
    private var picturePackets = 0
    private var framePacketCount: UInt16?
    private var isRefresh = false
    private var wantsAcknowledgement = false
    /// True while pictures cannot be decoded: at the start, and after a loss until a restart point.
    public private(set) var isWaitingForRestart = true
    /// Whether a refresh picture is enough to restart, which is so once a keyframe has been
    /// decoded and its pictures acknowledged.
    public var acceptsRefresh = false
    /// Pictures that arrived whole but could not be started from, and the NAL types and refresh
    /// mark of the latest: for diagnostics.
    public private(set) var withheld = 0
    public private(set) var lastWithheld: (types: [UInt8], isRefresh: Bool)?
    /// Pictures dropped because a packet of theirs was missing or malformed.
    public private(set) var spoiled = 0

    /// Withholds pictures until a keyframe arrives: for a decoder that has lost its footing, which
    /// a refresh picture cannot help.
    public mutating func requireKeyframe() {
        isWaitingForRestart = true
        acceptsRefresh = false
    }

    /// Withholds pictures until one the stream can restart from: for a decoder that dropped a
    /// picture but kept those before it, which a refresh picture can build on.
    public mutating func requireRestart() {
        isWaitingForRestart = true
    }

    /// Total NAL bytes one picture may hold; a 4K intra picture at 60 Mbit/s is well under it.
    static let maximumPictureSize = 32 << 20
    /// NAL units one picture may hold. A Mac's pictures have a handful (parameter sets, one or a
    /// few slices); aggregation packets of two-byte units could otherwise make millions.
    static let maximumUnits = 1024

    public init(codec: MediaVideoCodec = .hevc) {
        self.codec = codec
    }

    public mutating func push(_ packet: RTPPacket) -> Output {
        var output = Output.none
        var followsGap = false
        if packet.ssrc != ssrc {
            // A new offer starts a new stream under a new SSRC, with nothing of the old one to go on from.
            if ssrc != nil { self = VideoDepacketizer(codec: codec) }
            ssrc = packet.ssrc
        } else if let expected = nextSequence, packet.sequence != expected {
            // A little older than expected is a straggler or a repeat; anything else is a gap,
            // including a jump ahead by more than half the number space.
            let distance = Int(Int16(bitPattern: packet.sequence &- expected))
            if distance < 0, distance >= -SequenceTracker.maximumLateness { return .none }
            followsGap = true
            if !isWaitingForRestart {
                isWaitingForRestart = true
                output = .loss
            }
        }
        nextSequence = packet.sequence &+ 1

        if packet.timestamp != timestamp {
            // A picture whose last packet was lost never saw its marker; it is dropped here.
            beginPicture(packet.timestamp)
            // The lost packets may have been this picture's first; its packet count will tell.
            pictureFollowsGap = followsGap
        } else if followsGap {
            pictureSpoiled = true
            fragment = nil
        }
        isRefresh = isRefresh || packet.isRefresh
        wantsAcknowledgement = wantsAcknowledgement || packet.wantsAcknowledgement
        picturePackets += 1
        if let count = packet.mediaControl?.framePacketCount { framePacketCount = count }

        if !pictureSpoiled, !take(packet.payload) {
            pictureSpoiled = true
            fragment = nil
        }

        guard packet.marker else { return output }
        defer { beginPicture(nil) }
        if pictureFollowsGap, framePacketCount.map({ Int($0) != picturePackets }) ?? true {
            pictureSpoiled = true
        }
        guard !pictureSpoiled, fragment == nil, !units.isEmpty else {
            spoiled += 1
            if !isWaitingForRestart {
                isWaitingForRestart = true
                return .loss
            }
            return output
        }
        let isKeyframe: Bool
        let types: [UInt8]
        switch codec {
        case .hevc:
            types = units.map { HEVCNAL.type($0[$0.startIndex]) }
            let hasParameters = types.contains(HEVCNAL.sps) && types.contains(HEVCNAL.pps)
            let hasIntra = types.contains { $0 == HEVCNAL.idrWithRADL || $0 == HEVCNAL.idrNoLP || $0 == HEVCNAL.cra }
            isKeyframe = hasParameters && hasIntra
        case .h264:
            var found = units.map { H264NAL.type($0[$0.startIndex]) }
            let inBand = units.filter { [H264NAL.sps, H264NAL.pps].contains(H264NAL.type($0[$0.startIndex])) }
            if !inBand.isEmpty { parameterSets = inBand }
            // Parameter sets on their own are kept for the keyframe that follows; they are no picture.
            guard found.contains(where: { $0 != H264NAL.sps && $0 != H264NAL.pps }) else { return output }
            let hasIntra = found.contains(H264NAL.idr)
            if hasIntra, inBand.isEmpty, !parameterSets.isEmpty {
                units.insert(contentsOf: parameterSets, at: 0)
                found = units.map { H264NAL.type($0[$0.startIndex]) }
            }
            types = found
            isKeyframe = hasIntra && found.contains(H264NAL.sps) && found.contains(H264NAL.pps)
        }
        if isWaitingForRestart {
            // Only HEVC has refresh pictures; a Mac's H.264 restarts at keyframes alone.
            guard isKeyframe || (codec == .hevc && isRefresh && acceptsRefresh) else {
                withheld += 1
                lastWithheld = (types, isRefresh)
                return output
            }
            isWaitingForRestart = false
        }
        return .picture(
            AccessUnit(
                codec: codec, timestamp: packet.timestamp, ssrc: packet.ssrc, nalUnits: units,
                isKeyframe: isKeyframe, isRefresh: isRefresh, wantsAcknowledgement: wantsAcknowledgement
            )
        )
    }

    private mutating func beginPicture(_ newTimestamp: UInt32?) {
        timestamp = newTimestamp
        units = []
        fragment = nil
        gathered = 0
        pictureSpoiled = false
        pictureFollowsGap = false
        picturePackets = 0
        framePacketCount = nil
        isRefresh = false
        wantsAcknowledgement = false
    }

    /// Adds one packet's payload to the picture. False if the payload is malformed, or the picture
    /// would grow past its limits.
    private mutating func take(_ payload: Data) -> Bool {
        guard gathered + payload.count <= Self.maximumPictureSize else { return false }
        gathered += payload.count
        let taken = switch codec {
        case .hevc: takeHEVC(payload)
        case .h264: takeH264(payload)
        }
        return taken && units.count <= Self.maximumUnits
    }

    private mutating func takeH264(_ payload: Data) -> Bool {
        guard payload.count >= 1 else { return false }
        let base = payload.startIndex
        switch H264NAL.type(payload[base]) {
        case H264NAL.appleSampleDescription:
            guard fragment == nil, let sets = H264NAL.parameterSets(inSampleDescription: payload) else { return false }
            units.append(contentsOf: sets)
            return true
        case H264NAL.aggregation:
            guard fragment == nil else { return false }
            var offset = base + 1
            while offset < payload.endIndex {
                guard offset + 2 <= payload.endIndex, units.count < Self.maximumUnits else { return false }
                let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                offset += 2
                guard size >= 1, offset + size <= payload.endIndex else { return false }
                units.append(payload.subdata(in: offset..<(offset + size)))
                offset += size
            }
            return true
        case H264NAL.fragmentation:
            guard payload.count >= 3 else { return false }
            let header = payload[base + 1]
            let isStart = header & 0x80 != 0
            let isEnd = header & 0x40 != 0
            if isStart {
                guard fragment == nil else { return false }
                // The original NAL header: the indicator's forbidden bit and importance, the fragment's type.
                var unit = Data(capacity: payload.count * 4)
                unit.append(payload[base] & 0xe0 | header & 0x1f)
                fragment = unit
            }
            guard fragment != nil else { return false }
            fragment?.append(payload[(base + 2)...])
            if isEnd, let whole = fragment {
                units.append(whole)
                fragment = nil
            }
            return true
        case 1...23:
            guard fragment == nil else { return false }
            units.append(Data(payload))
            return true
        default:
            // STAP-B, MTAP and FU-B carry decoding order numbers, which a Mac uses only in strips.
            return false
        }
    }

    private mutating func takeHEVC(_ payload: Data) -> Bool {
        guard payload.count >= 2 else { return false }
        let base = payload.startIndex
        switch HEVCNAL.type(payload[base]) {
        case HEVCNAL.aggregation:
            guard fragment == nil else { return false }
            var offset = base + 2
            while offset < payload.endIndex {
                guard offset + 2 <= payload.endIndex, units.count < Self.maximumUnits else { return false }
                let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                offset += 2
                guard size >= 2, offset + size <= payload.endIndex else { return false }
                units.append(payload.subdata(in: offset..<(offset + size)))
                offset += size
            }
            return true
        case HEVCNAL.fragmentation:
            guard payload.count >= 4 else { return false }
            let header = payload[base + 2]
            let isStart = header & 0x80 != 0
            let isEnd = header & 0x40 != 0
            if isStart {
                guard fragment == nil else { return false }
                // The original NAL header: this packet's, with the fragment's type put back.
                var unit = Data(capacity: payload.count * 4)
                unit.append(payload[base] & 0x81 | (header & 0x3f) << 1)
                unit.append(payload[base + 1])
                fragment = unit
            }
            guard fragment != nil else { return false }
            fragment?.append(payload[(base + 3)...])
            if isEnd, let whole = fragment {
                units.append(whole)
                fragment = nil
            }
            return true
        case HEVCNAL.paci...63:
            return false
        default:
            guard fragment == nil else { return false }
            units.append(Data(payload))
            return true
        }
    }
}
