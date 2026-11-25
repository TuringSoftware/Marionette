// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

@testable import AppleScreenSharing
import ARDProtocol
import CoreMedia
import CoreVideo
import Foundation
import RemoteDesktopDecode
import Synchronization
import Testing
import VideoToolbox

/// Encodes frames with the system's H.264 encoder, so the receive path is tested against a real
/// bitstream rather than one this client's own code made up.
private final class H264Source {
    let width: Int
    let height: Int
    private var session: VTCompressionSession?
    private let produced = Produced()

    /// What the encoder hands back, collected under a lock. Sample buffers are not Sendable, but
    /// each is written once by the encoder and read once by the test after the encoder is done.
    private final class Produced: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [CMSampleBuffer] = []

        func add(_ sample: CMSampleBuffer) {
            lock.withLock { samples.append(sample) }
        }

        func takeLast() -> CMSampleBuffer? {
            lock.withLock { samples.popLast() }
        }
    }

    init(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw Failure("no H.264 encoder: \(status)") }
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_Quality, value: 0.95 as CFNumber)
        session = created
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// The pattern of frame `index`: smooth gradients that move, so that each frame differs and
    /// a lossy codec still reproduces them closely.
    func pixels(frame index: Int) -> [UInt8] {
        var output = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                // Every channel stays inside 0–255: a value that wraps makes a hard colour edge,
                // which 4:2:0 chroma blurs whatever the decoder does.
                output[offset] = UInt8(30 + x * 150 / width + index * 4)
                output[offset + 1] = UInt8(40 + y * 150 / height)
                output[offset + 2] = UInt8(60 + (x + y) * 100 / (width + height) + index * 2)
            }
        }
        return output
    }

    /// Encodes frame `index`; the first is a keyframe.
    func encode(frame index: Int) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer, let session else { throw Failure("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let source = pixels(frame: index)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        for row in 0..<height {
            source.withUnsafeBytes { (base + row * stride).copyMemory(from: $0.baseAddress! + row * width * 4, byteCount: width * 4) }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let properties: CFDictionary? = index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let produced = produced
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sample in
            if status == noErr, let sample { produced.add(sample) }
        }
        guard status == noErr else { throw Failure("encode failed: \(status)") }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard let sample = produced.takeLast() else { throw Failure("no sample for frame \(index)") }
        return sample
    }

    static func avcC(of sample: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        else { return nil }
        return atoms["avcC"] as? Data
    }

    /// The sample's NAL units, without their four-byte lengths.
    static func nalUnits(of sample: CMSampleBuffer) -> [Data] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard let pointer else { return [] }
        let bytes = Data(bytes: pointer, count: length)
        var units: [Data] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let size = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard size > 0, offset + size <= bytes.count else { break }
            units.append(bytes.subdata(in: offset..<(offset + size)))
            offset += size
        }
        return units
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first
        else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }
}

/// A picture as a Mac sends its H.264 with one tile: a keyframe opens with a packet of NAL type 18
/// (forbidden bit set) holding four bytes and an `avc1` sample description with the `avcC` box;
/// every unit then goes whole if it fits a packet and as FU-A fragments if not.
private func macPayloads(units: [Data], avcC: Data?, maximum: Int = 1100) -> [Data] {
    var payloads: [Data] = []
    if let avcC {
        func box(_ type: String, _ body: Data) -> Data {
            let size = UInt32(8 + body.count)
            return Data([UInt8(size >> 24), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)]) + Data(type.utf8) + body
        }
        payloads.append(Data([0x92, 0, 0, 0, 1]) + box("avc1", Data(repeating: 0, count: 78) + box("avcC", avcC)))
    }
    for unit in units {
        if unit.count <= maximum {
            payloads.append(unit)
            continue
        }
        let indicator = unit[unit.startIndex] & 0xe0 | 28
        let type = unit[unit.startIndex] & 0x1f
        let body = unit.dropFirst()
        var offset = body.startIndex
        while offset < body.endIndex {
            let end = min(body.endIndex, offset + maximum)
            var header = type
            if offset == body.startIndex { header |= 0x80 }
            if end == body.endIndex { header |= 0x40 }
            payloads.append(Data([indicator, header]) + body[offset..<end])
            offset = end
        }
    }
    return payloads
}

private func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var squares = 0.0
    var count = 0.0
    for index in stride(from: 0, to: min(a.count, b.count), by: 4) {
        for channel in 0..<3 {
            let difference = Double(a[index + channel]) - Double(b[index + channel])
            squares += difference * difference
            count += 1
        }
    }
    return squares == 0 ? .infinity : 10 * log10(255 * 255 / (squares / count))
}

@Suite struct H264EndToEndTests {
    /// A real H.264 stream, packetised as a Mac does, through SRTP, the receiver and the system decoder.
    @Test func aMacShapedH264StreamDecodesToThePicturesThatWentIn() async throws {
        let source = try H264Source(width: 320, height: 192)
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }

        let frameCount = 8
        for index in 0..<frameCount {
            let sample = try source.encode(frame: index)
            let keyframe = H264Source.isKeyframe(sample)
            #expect(keyframe == (index == 0), "frame \(index)")
            let payloads = macPayloads(units: H264Source.nalUnits(of: sample), avcC: keyframe ? H264Source.avcC(of: sample) : nil)
            mac.send(mac.packets(payloads, payloadType: 123))
        }
        await mac.settle()
        let units = mac.units
        #expect(units.count == frameCount)
        #expect(units.allSatisfy { $0.codec == .h264 })
        #expect(units.first?.isKeyframe == true)
        #expect(mac.receiver.videoStatistics(leg: 0).codec == .h264)
        // A Mac's H.264 asks for no acknowledgement, and an acknowledgement would reach nothing.
        #expect(mac.requests().allSatisfy { $0.hasPrefix("ack") })

        let decoded = Mutex<[DecodedPicture]>([])
        let decoder = VideoDecoder { result in
            if case .success(let picture) = result { decoded.withLock { $0.append(picture) } }
        }
        for unit in units {
            try decoder.decode(EncodedPicture(codec: .h264, nalUnits: unit.nalUnits, isKeyframe: unit.isKeyframe, timestamp: unit.timestamp))
        }
        decoder.finishPending()
        let pictures = decoded.withLock { $0 }
        #expect(pictures.count == frameCount)
        for (index, picture) in pictures.enumerated() {
            #expect(picture.width == 320 && picture.height == 192)
            let pixels: [UInt8] = picture.surface.withUnsafeBuffer { buffer in
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                return (0..<192).flatMap { row in Array(UnsafeBufferPointer(start: base + row * stride, count: 320 * 4)) }
            }
            // Pictures come out in the order they went in, each like its source.
            let quality = psnr(pixels, source.pixels(frame: index))
            // Measured at 33.7–34.0 dB, with no channel off by more than 1.5 levels on average:
            // the codec's rounding, not a colour mismatch between encoder and decoder.
            #expect(quality > 30, "frame \(index): \(quality) dB")
        }
    }

    /// After a loss an H.264 stream can only restart at a keyframe, so the receiver asks with a
    /// picture-loss indication even though it has delivered pictures before.
    @Test func aLostH264PictureIsRepairedWithAKeyframeRequest() async throws {
        let source = try H264Source(width: 160, height: 96)
        let mac = try await FakeMac()
        defer { mac.receiver.stop() }
        let first = try source.encode(frame: 0)
        mac.send(mac.packets(macPayloads(units: H264Source.nalUnits(of: first), avcC: H264Source.avcC(of: first)), payloadType: 123))
        let second = try source.encode(frame: 1)
        var broken = mac.packets(macPayloads(units: H264Source.nalUnits(of: second), avcC: nil, maximum: 200), payloadType: 123)
        #expect(broken.count > 2)
        broken.remove(at: 1)
        mac.send(broken)
        // The packets after the gap wait a moment for a straggler before it counts as a loss.
        await until("the loss to be noticed", timeout: .seconds(1)) { mac.events.last == "loss" }
        let requests = await mac.nextRequests("the restart request")
        #expect(!requests.isEmpty && requests.allSatisfy { $0 == "keyframe request" })
    }
}
