// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
public import CoreVideo
public import Foundation
import Synchronization
import VideoToolbox

public enum VideoCodec: Sendable, Hashable {
    case hevc
    case h264
}

/// One coded picture, as NAL units without start codes or length prefixes.
public struct EncodedPicture: Sendable {
    public var codec: VideoCodec
    public var nalUnits: [Data]
    /// Carries parameter sets and an intra picture, so decoding can start here.
    public var isKeyframe: Bool
    /// The stream's own timestamp for the picture, returned with the decoded result.
    public var timestamp: UInt32
    /// Which stream the picture came from (an SSRC, say), returned with the decoded result.
    public var source: UInt32

    public init(codec: VideoCodec, nalUnits: [Data], isKeyframe: Bool, timestamp: UInt32, source: UInt32 = 0) {
        self.codec = codec
        self.nalUnits = nalUnits
        self.isKeyframe = isKeyframe
        self.timestamp = timestamp
        self.source = source
    }
}

public struct DecodedPicture: Sendable {
    /// 32-bit BGRA, IOSurface-backed, Metal-compatible. Carries the stream's colour attachments.
    public var surface: CVReadOnlyPixelBuffer
    public var width: Int
    public var height: Int
    public var timestamp: UInt32
    /// The ``EncodedPicture/source`` of the picture.
    public var source: UInt32 = 0
}

public enum VideoDecoderError: Error, Sendable, Equatable {
    /// Decoding has not started, or was reset, and this picture is not a keyframe.
    case needsKeyframe
    /// A keyframe arrived without usable parameter sets.
    case missingParameterSets
    /// This device cannot decode the stream (for example, no decoder for its chroma format, or no
    /// hardware decoder where one is required).
    case unsupportedStream(status: Int32)
    /// The parameter sets describe pictures larger than the decoder was told to accept.
    case pictureTooLarge(width: Int, height: Int)
    /// A picture failed to decode, and the session with it. Rebuild, and ask for a keyframe.
    case decodeFailed(status: Int32)
    /// The decoder skipped this one picture but is otherwise sound: the picture was damaged
    /// (`kVTVideoDecoderBadDataErr`, -12909) or refers to one that is missing
    /// (`kVTVideoDecoderReferenceMissingErr`, -17694). The session and the pictures it holds are
    /// still good, so a picture predicted from one of them can carry on.
    case pictureSkipped(status: Int32)
    /// The picture decoded but produced no image: the decoder dropped it
    /// (`kVTDecodeInfo_FrameDropped`), or it is not for output. Nothing is wrong.
    case noImage
}

/// Decodes one HEVC or H.264 stream with VideoToolbox, in arrival order, for display.
///
/// Call ``decode(_:)`` from one place at a time. ``invalidate()`` may be called from anywhere, any
/// time, except from the output handler. Results are delivered to the output handler on a
/// VideoToolbox thread, in the order the pictures were submitted; results of a session that has
/// since been invalidated or replaced are not delivered, so a late failure of an old session never
/// reaches the handler as if it were the current one's.
public final class VideoDecoder: Sendable {
    /// The VideoToolbox session and what it was made from. Guarded by `lock`, which is never held
    /// across a call into VideoToolbox that may wait for the decoder.
    private struct Session: @unchecked Sendable {
        var session: VTDecompressionSession?
        var format: CMVideoFormatDescription?
        var parameterSets: [Data] = []
        var codec: VideoCodec?
        var isHardwareAccelerated: Bool?
        /// Bumped whenever the session is replaced or dropped; results carry the one they came from.
        var generation: UInt64 = 0
    }

    private let lock = Mutex(Session())
    private let output: @Sendable (Result<DecodedPicture, VideoDecoderError>) -> Void
    /// Whether a software decoder will do when the hardware refuses the stream. A live screen at a
    /// Mac's sizes is more than a software decoder keeps up with.
    private let allowsSoftwareDecoding: Bool
    /// The largest picture accepted, in pixels: HEVC level 5.1's 8 912 896, by default.
    private let maximumPixels: Int

    /// Whether the current session decodes in hardware. `nil` before the first keyframe.
    public var isHardwareAccelerated: Bool? { lock.withLock { $0.isHardwareAccelerated } }

    /// - Parameters:
    ///   - allowsSoftwareDecoding: Fall back to a software decoder when the hardware one refuses.
    ///   - maximumPixels: Refuse parameter sets that describe larger pictures.
    public init(
        allowsSoftwareDecoding: Bool = true,
        maximumPixels: Int = 8_912_896,
        output: @escaping @Sendable (Result<DecodedPicture, VideoDecoderError>) -> Void
    ) {
        self.output = output
        self.allowsSoftwareDecoding = allowsSoftwareDecoding
        self.maximumPixels = maximumPixels
    }

    deinit {
        invalidate()
    }

    /// Drops the decoder session, after letting the pictures already submitted finish (their
    /// results are not delivered). The next picture decoded must be a keyframe.
    public func invalidate() {
        let old = lock.withLock { state in
            defer {
                let generation = state.generation &+ 1
                state = Session()
                state.generation = generation
            }
            return state.session
        }
        guard let old else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(old)
        VTDecompressionSessionInvalidate(old)
    }

    /// Submits one picture. Throws if it cannot be submitted; decode failures of a submitted picture
    /// arrive through the output handler.
    public func decode(_ picture: EncodedPicture) throws(VideoDecoderError) {
        let (sets, slices) = Self.partition(picture.nalUnits, codec: picture.codec)
        if picture.isKeyframe {
            guard !sets.isEmpty else { throw .missingParameterSets }
            let current = lock.withLock { ($0.parameterSets, $0.codec, $0.session != nil) }
            if sets != current.0 || picture.codec != current.1 || !current.2 {
                try configure(codec: picture.codec, parameterSets: sets)
            }
        }
        let (session, format, generation) = lock.withLock { ($0.session, $0.format, $0.generation) }
        guard let session, let format else { throw .needsKeyframe }
        guard !slices.isEmpty else { return }

        let sample = try Self.makeSample(slices, format: format, timestamp: picture.timestamp)
        let timestamp = picture.timestamp
        let source = picture.source
        let output = output
        var info = VTDecodeInfoFlags()
        // No `_1xRealTimePlayback`: a live screen has no use for real-time pacing (measured on Apple
        // silicon, 2880 × 1800: a median 5.6 ms a picture with or without it).
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: &info
        ) { [weak self] status, flags, imageBuffer, _, _ in
            guard let self, self.lock.withLock({ $0.generation }) == generation else { return }
            output(Self.result(status: status, flags: flags, image: imageBuffer, timestamp: timestamp, source: source))
        }
        guard status != noErr else { return }
        if Self.skippedFrameStatuses.contains(status) { throw .pictureSkipped(status: status) }
        // A session that refuses a frame is not coming back; start again at the next keyframe,
        // unless it was dropped meanwhile.
        if lock.withLock({ $0.generation }) == generation { invalidate() }
        throw .decodeFailed(status: status)
    }

    /// The statuses with which VideoToolbox skips one picture and keeps going.
    static let skippedFrameStatuses: Set<OSStatus> = [kVTVideoDecoderBadDataErr, -17694]

    static func result(
        status: OSStatus, flags: VTDecodeInfoFlags, image: CVImageBuffer?, timestamp: UInt32, source: UInt32
    ) -> Result<DecodedPicture, VideoDecoderError> {
        guard status == noErr else {
            return .failure(skippedFrameStatuses.contains(status) ? .pictureSkipped(status: status) : .decodeFailed(status: status))
        }
        guard let image, !flags.contains(.frameDropped) else { return .failure(.noImage) }
        // VideoToolbox hands the buffer over; nothing else writes to it from here on.
        nonisolated(unsafe) let finished = image
        return .success(DecodedPicture(
            surface: CVReadOnlyPixelBuffer(unsafeBuffer: finished),
            width: CVPixelBufferGetWidth(image),
            height: CVPixelBufferGetHeight(image),
            timestamp: timestamp,
            source: source
        ))
    }

    /// Waits until every submitted picture has been delivered.
    public func finishPending() {
        if let session = lock.withLock({ $0.session }) {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    private func configure(codec newCodec: VideoCodec, parameterSets sets: [Data]) throws(VideoDecoderError) {
        invalidate()
        let description = try Self.makeFormat(codec: newCodec, parameterSets: sets)
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0, Int(dimensions.width) * Int(dimensions.height) <= maximumPixels else {
            throw .pictureTooLarge(width: Int(dimensions.width), height: Int(dimensions.height))
        }
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        func create(requireHardware: Bool) -> (OSStatus, VTDecompressionSession?) {
            let specification: [CFString: Any] = [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: requireHardware,
            ]
            var created: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: description,
                decoderSpecification: specification as CFDictionary,
                imageBufferAttributes: imageAttributes as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &created
            )
            return (status, created)
        }
        var (status, created) = create(requireHardware: true)
        var hardware = status == noErr && created != nil
        if !hardware, allowsSoftwareDecoding {
            (status, created) = create(requireHardware: false)
        }
        guard status == noErr, let created else { throw .unsupportedStream(status: status) }
        if !hardware {
            var value: Unmanaged<CFBoolean>?
            if VTSessionCopyProperty(created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &value) == noErr,
               let value {
                hardware = CFBooleanGetValue(value.takeRetainedValue())
            }
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        lock.withLock { state in
            state.session = created
            state.format = description
            state.parameterSets = sets
            state.codec = newCodec
            state.isHardwareAccelerated = hardware
            state.generation &+= 1
        }
    }

    // MARK: Bitstream helpers

    /// At most this many distinct parameter sets are taken from a picture, of at most this size:
    /// a real stream has one of each kind, of some tens of bytes.
    static let maximumParameterSets = 16
    static let maximumParameterSetSize = 1024

    /// Splits a picture's NAL units into parameter sets and everything a decoder is fed as the sample.
    /// Parameter sets past the limits above are left out.
    static func partition(_ units: [Data], codec: VideoCodec) -> (parameterSets: [Data], sample: [Data]) {
        var sets: [Data] = []
        var sample: [Data] = []
        for unit in units where !unit.isEmpty {
            let first = unit[unit.startIndex]
            let isParameterSet: Bool
            let isDelimiter: Bool
            switch codec {
            case .hevc:
                let type = first >> 1 & 0x3f
                isParameterSet = (32...34).contains(type)
                isDelimiter = type == 35
            case .h264:
                let type = first & 0x1f
                isParameterSet = type == 7 || type == 8
                isDelimiter = type == 9
            }
            if isParameterSet {
                if unit.count <= maximumParameterSetSize, sets.count < maximumParameterSets, !sets.contains(unit) { sets.append(unit) }
            } else if !isDelimiter {
                sample.append(unit)
            }
        }
        return (sets, sample)
    }

    private static func makeFormat(codec: VideoCodec, parameterSets sets: [Data]) throws(VideoDecoderError) -> CMVideoFormatDescription {
        // The C functions want parallel arrays of pointers and sizes that stay valid for the call.
        let storage = sets.map { [UInt8]($0) }
        var description: CMVideoFormatDescription?
        var status: OSStatus = -1

        func withPointers(_ index: Int, _ pointers: inout [UnsafePointer<UInt8>], _ body: ([UnsafePointer<UInt8>]) -> Void) {
            if index == storage.count {
                body(pointers)
                return
            }
            storage[index].withUnsafeBufferPointer { buffer in
                pointers.append(buffer.baseAddress!)
                withPointers(index + 1, &pointers, body)
            }
        }
        var gathered: [UnsafePointer<UInt8>] = []
        let sizes = storage.map(\.count)
        withPointers(0, &gathered) { pointers in
            switch codec {
            case .hevc:
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description
                )
            case .h264:
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            throw status == -1 ? .missingParameterSets : .unsupportedStream(status: status)
        }
        return description
    }

    /// One sample buffer holding the NAL units, each behind a four-byte length.
    private static func makeSample(_ units: [Data], format: CMVideoFormatDescription, timestamp: UInt32) throws(VideoDecoderError) -> CMSampleBuffer {
        var bytes = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            let length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: length) { bytes.append(contentsOf: $0) }
            bytes.append(unit)
        }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { throw .decodeFailed(status: status) }
        status = bytes.withUnsafeBytes { source in
            CMBlockBufferReplaceDataBytes(with: source.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: source.count)
        }
        guard status == noErr else { throw .decodeFailed(status: status) }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 24_000),
            decodeTimeStamp: .invalid
        )
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw .decodeFailed(status: status) }
        return sample
    }
}

/// Splits an Annex B byte stream (NAL units behind `00 00 01` or `00 00 00 01`) into NAL units.
public enum AnnexB {
    public static func nalUnits(in stream: Data) -> [Data] {
        var units: [Data] = []
        var unitStart: Int?
        var index = stream.startIndex
        let end = stream.endIndex
        while index + 2 < end {
            if stream[index] == 0, stream[index + 1] == 0, stream[index + 2] == 1 {
                if let start = unitStart {
                    // A four-byte start code's leading zero belongs to the code, not the unit before.
                    var stop = index
                    while stop > start, stream[stop - 1] == 0 { stop -= 1 }
                    if stop > start { units.append(stream.subdata(in: start..<stop)) }
                }
                unitStart = index + 3
                index += 3
            } else {
                index += 1
            }
        }
        if let start = unitStart, start < end {
            units.append(stream.subdata(in: start..<end))
        }
        return units
    }
}
