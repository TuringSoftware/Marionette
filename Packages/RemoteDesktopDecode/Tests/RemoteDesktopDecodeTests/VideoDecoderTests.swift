// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
@testable import RemoteDesktopDecode
import Synchronization
import Testing
import VideoToolbox

/// `pattern444.h265`: six pictures of ffmpeg's `testsrc2`, 320 × 240, HEVC Range Extensions 8-bit
/// 4:4:4, full-range BT.709 — the same profile and chroma format a Mac streams. `pattern444-frame5.png`
/// is the last of them as ffmpeg decodes it.
private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Groups NAL units into pictures: parameter sets and other non-slice units belong to the slice
/// that follows them. The fixture has one slice per picture.
private func pictures(in stream: Data) -> [EncodedPicture] {
    var result: [EncodedPicture] = []
    var pending: [Data] = []
    for unit in AnnexB.nalUnits(in: stream) {
        pending.append(unit)
        let type = unit[unit.startIndex] >> 1 & 0x3f
        guard type < 32 else { continue }
        let isKeyframe = (16...21).contains(type) && pending.contains { ($0[$0.startIndex] >> 1 & 0x3f) == 33 }
        result.append(EncodedPicture(codec: .hevc, nalUnits: pending, isKeyframe: isKeyframe, timestamp: UInt32(result.count) * 800))
        pending = []
    }
    return result
}

private func bgra(_ picture: DecodedPicture) -> [UInt8] {
    picture.surface.withUnsafeBuffer { buffer in
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        var pixels = [UInt8](repeating: 0, count: picture.width * picture.height * 4)
        for row in 0..<picture.height {
            pixels.withUnsafeMutableBytes { destination in
                (destination.baseAddress! + row * picture.width * 4).copyMemory(from: base + row * stride, byteCount: picture.width * 4)
            }
        }
        return pixels
    }
}

private func referencePixels(_ png: Data) throws -> (pixels: [UInt8], width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try #require(CGContext(
        data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (pixels, image.width, image.height)
}

/// Peak signal-to-noise ratio over the colour channels, in decibels.
private func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var sum = 0.0
    var count = 0
    for index in stride(from: 0, to: min(a.count, b.count), by: 4) {
        for channel in 0..<3 {
            let difference = Double(a[index + channel]) - Double(b[index + channel])
            sum += difference * difference
            count += 1
        }
    }
    let mse = sum / Double(max(count, 1))
    return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
}

@Suite struct VideoDecoderTests {
    @Test func annexBSplitsOnBothStartCodeLengths() {
        let stream = Data([0, 0, 0, 1, 0x40, 1, 0xAA, 0, 0, 1, 0x42, 1, 0xBB, 0xCC, 0, 0, 0, 1, 0x26, 1])
        #expect(AnnexB.nalUnits(in: stream) == [Data([0x40, 1, 0xAA]), Data([0x42, 1, 0xBB, 0xCC]), Data([0x26, 1])])
        #expect(AnnexB.nalUnits(in: Data([1, 2, 3])).isEmpty)
        #expect(AnnexB.nalUnits(in: Data()).isEmpty)
    }

    @Test func fixtureHasSixPicturesStartingAtAKeyframe() throws {
        let all = pictures(in: try fixture("pattern444.h265"))
        #expect(all.count == 6)
        #expect(all[0].isKeyframe)
        #expect(all.dropFirst().allSatisfy { !$0.isKeyframe })
    }

    @Test func decodesRangeExtensions444InOrderAndMatchesReference() throws {
        let decoded = Mutex<[Result<DecodedPicture, VideoDecoderError>]>([])
        let decoder = VideoDecoder { result in decoded.withLock { $0.append(result) } }
        for picture in pictures(in: try fixture("pattern444.h265")) {
            try decoder.decode(picture)
        }
        decoder.finishPending()

        let results = decoded.withLock { $0 }
        #expect(results.count == 6)
        let frames = try results.map { try $0.get() }
        #expect(frames.map(\.timestamp) == [0, 800, 1600, 2400, 3200, 4000])
        #expect(frames.allSatisfy { $0.width == 320 && $0.height == 240 })
        #expect(decoder.isHardwareAccelerated != nil)

        let reference = try referencePixels(try fixture("pattern444-frame5.png"))
        #expect(reference.width == 320)
        let quality = psnr(bgra(frames[5]), reference.pixels)
        // Two decoders and two colour conversions agree to within rounding; a wrong matrix, range
        // or chroma layout would land far below this.
        #expect(quality > 38, "PSNR against ffmpeg's decode was \(quality) dB")
        // And the pictures are not all the same picture.
        #expect(psnr(bgra(frames[0]), reference.pixels) < quality)
    }

    @Test func refusesToStartAnywhereButAKeyframe() throws {
        let decoder = VideoDecoder { _ in }
        let all = pictures(in: try fixture("pattern444.h265"))
        #expect(throws: VideoDecoderError.needsKeyframe) { try decoder.decode(all[1]) }
        try decoder.decode(all[0])
        try decoder.decode(all[1])
        decoder.invalidate()
        #expect(throws: VideoDecoderError.needsKeyframe) { try decoder.decode(all[2]) }
        decoder.finishPending()
    }

    @Test func keyframeWithoutParameterSetsIsRejected() throws {
        let decoder = VideoDecoder { _ in }
        var first = pictures(in: try fixture("pattern444.h265"))[0]
        first.nalUnits.removeAll { (32...34).contains($0[$0.startIndex] >> 1 & 0x3f) }
        #expect(throws: VideoDecoderError.missingParameterSets) { try decoder.decode(first) }
    }

    @Test func corruptParameterSetsAreUnsupportedNotACrash() throws {
        let decoder = VideoDecoder { _ in }
        var first = pictures(in: try fixture("pattern444.h265"))[0]
        first.nalUnits = first.nalUnits.map { unit in
            (32...34).contains(unit[unit.startIndex] >> 1 & 0x3f) ? unit.prefix(3) + Data(repeating: 0xFF, count: 5) : unit
        }
        #expect(throws: VideoDecoderError.self) { try decoder.decode(first) }
    }

    @Test func corruptSliceReportsFailureThroughTheHandlerOrThrows() throws {
        let decoded = Mutex<[Result<DecodedPicture, VideoDecoderError>]>([])
        let decoder = VideoDecoder { result in decoded.withLock { $0.append(result) } }
        var all = pictures(in: try fixture("pattern444.h265"))
        try decoder.decode(all[0])
        let slice = all[1].nalUnits[all[1].nalUnits.count - 1]
        all[1].nalUnits[all[1].nalUnits.count - 1] = slice.prefix(2) + Data((0..<slice.count - 2).map { UInt8(truncatingIfNeeded: $0 &* 97 &+ 13) })
        var threw = false
        do { try decoder.decode(all[1]) } catch { threw = true }
        decoder.finishPending()
        let results = decoded.withLock { $0 }
        // A decoder may conceal damage rather than fail; what it must not do is crash or stall.
        #expect(threw || results.count == 2)
    }
}

@Suite struct VideoDecoderRecoveryTests {
    @Test func whatVideoToolboxSaysBecomesWhatToDo() {
        func outcome(_ status: OSStatus, _ flags: VTDecodeInfoFlags = [], image: Bool = false) -> VideoDecoderError? {
            var buffer: CVPixelBuffer?
            if image { CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) }
            if case .failure(let error) = VideoDecoder.result(status: status, flags: flags, image: buffer, timestamp: 1, source: 2) { return error }
            return nil
        }
        // A picture that decodes to nothing is no failure at all.
        #expect(outcome(noErr) == .noImage)
        #expect(outcome(noErr, .frameDropped, image: true) == .noImage)
        #expect(outcome(noErr, image: true) == nil)
        // A damaged picture, or one whose reference is missing, costs that picture only.
        #expect(outcome(-12909) == .pictureSkipped(status: -12909))
        #expect(outcome(-17694) == .pictureSkipped(status: -17694))
        // Anything else takes the session with it.
        #expect(outcome(-12911) == .decodeFailed(status: -12911))
    }

    @Test func parameterSetsForTooLargeAPictureAreRefused() throws {
        let decoder = VideoDecoder(maximumPixels: 320 * 240 - 1) { _ in }
        let first = pictures(in: try fixture("pattern444.h265"))[0]
        #expect(throws: VideoDecoderError.pictureTooLarge(width: 320, height: 240)) { try decoder.decode(first) }
    }

    @Test func manyCopiesOfAParameterSetAreTakenOnce() {
        let sps = Data([33 << 1, 1, 0xAA])
        let huge = Data([34 << 1, 1]) + Data(repeating: 0xBB, count: 2000)
        let units = Array(repeating: sps, count: 1000) + [huge, Data([1 << 1, 1, 0xCC])]
        let (sets, sample) = VideoDecoder.partition(units, codec: .hevc)
        #expect(sets == [sps])
        #expect(sample == [Data([1 << 1, 1, 0xCC])])
    }

    /// Results of a session that has been dropped never reach the handler, so a late failure of
    /// an old session cannot be taken for one of its replacement.
    @Test func nothingOfAnInvalidatedSessionIsDeliveredAfterwards() throws {
        let delivered = Mutex<[Result<DecodedPicture, VideoDecoderError>]>([])
        let decoder = VideoDecoder { result in delivered.withLock { $0.append(result) } }
        let all = pictures(in: try fixture("pattern444.h265"))
        for picture in all { try decoder.decode(picture) }
        decoder.invalidate()
        let settled = delivered.withLock { $0.count }
        Thread.sleep(forTimeInterval: 0.1)
        #expect(delivered.withLock { $0.count } == settled)
        var keyframe = all[0]
        keyframe.source = 0xCAFE
        try decoder.decode(keyframe)
        decoder.finishPending()
        let last = try #require(delivered.withLock { $0.last })
        #expect(try last.get().source == 0xCAFE)
    }

    /// The engine may drop a decoder while its leg is feeding it.
    @Test func invalidatingWhileDecodingNeitherCrashesNorDeadlocks() async throws {
        let decoder = VideoDecoder { _ in }
        let all = pictures(in: try fixture("pattern444.h265"))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<40 {
                    for picture in all { try? decoder.decode(picture) }
                }
            }
            group.addTask {
                for _ in 0..<200 {
                    decoder.invalidate()
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
        }
        decoder.invalidate()
    }
}

@Suite struct DecodeStallDetectorTests {
    private let start = ContinuousClock.now

    private func stall(_ detector: inout DecodeStallDetector, _ now: ContinuousClock.Instant) -> Bool {
        detector.isStalled(at: now)
    }

    @Test func picturesInWithNothingOutForASecondIsAStall() {
        var detector = DecodeStallDetector(threshold: .seconds(1), cooldown: .seconds(2))
        detector.noteSubmitted()
        #expect(stall(&detector, start) == false)
        detector.noteSubmitted()
        #expect(stall(&detector, start + .milliseconds(500)) == false)
        detector.noteSubmitted()
        #expect(stall(&detector, start + .milliseconds(1000)) == true)
        // Once, and not again within the cooldown.
        detector.noteSubmitted()
        #expect(stall(&detector, start + .milliseconds(1100)) == false)
        detector.noteSubmitted()
        #expect(stall(&detector, start + .milliseconds(2500)) == false)
        detector.noteSubmitted()
        #expect(stall(&detector, start + .milliseconds(3200)) == true)
    }

    @Test func anyOutputOrNoInputIsNoStall() {
        var detector = DecodeStallDetector()
        for step in 0..<30 {
            detector.noteSubmitted()
            if step % 5 == 0 { detector.noteDelivered() }
            #expect(stall(&detector, start + .milliseconds(100 * step)) == false)
        }
        // A still screen: nothing goes in, nothing comes out.
        var still = DecodeStallDetector()
        still.noteSubmitted()
        still.noteDelivered()
        #expect(stall(&still, start) == false)
        #expect(stall(&still, start + .seconds(10)) == false)
    }
}

@Suite struct DecoderCapabilityTests {
    @Test func theProbeSampleIsOneWholeKeyframe() {
        let units = AnnexB.nalUnits(in: DecoderCapabilities.hevc444Sample)
        #expect(units.map { $0[$0.startIndex] >> 1 & 0x3f } == [32, 33, 34, 20])
    }

    /// Every Apple silicon Mac decodes HEVC 4:4:4 in hardware, so on the machines these tests run
    /// on the probe must say yes; a no here means the probe is broken, not the Mac.
    @Test func anAppleSiliconMacDecodesHEVC444InHardware() {
        #expect(DecoderCapabilities.probeHEVC444())
        #expect(DecoderCapabilities.decodesHEVC444InHardware)
    }

    @Test func theTenBitProbeSampleIsOneWholeKeyframe() {
        let units = AnnexB.nalUnits(in: DecoderCapabilities.hevc444TenBitSample)
        #expect(units.map { $0[$0.startIndex] >> 1 & 0x3f } == [32, 33, 34, 20])
    }

    /// An M3 Mac decodes it in hardware; an older Apple silicon Mac may not, so this only asks
    /// that the probe and its remembered answer agree.
    @Test func theTenBitProbeAgreesWithItself() {
        #expect(DecoderCapabilities.probe(DecoderCapabilities.hevc444TenBitSample) == DecoderCapabilities.decodesHEVC444TenBitInHardware)
    }
}

@Suite struct DeepPictureTests {
    /// A 10-bit stream decodes to 10-bit RGB that keeps the stream's colour tags, which is what
    /// lets the renderer show it as HDR.
    @Test func aTenBitStreamDecodesToTenBitRGBWithItsColourTags() throws {
        let decoded = Mutex<DecodedPicture?>(nil)
        let decoder = VideoDecoder { result in
            if case .success(let picture) = result { decoded.withLock { $0 = picture } }
        }
        try decoder.decode(EncodedPicture(codec: .hevc, nalUnits: AnnexB.nalUnits(in: DecoderCapabilities.hevc444TenBitSample), isKeyframe: true, timestamp: 0))
        decoder.finishPending()
        let picture = try #require(decoded.withLock { $0 })
        #expect(picture.width == 64 && picture.height == 64)
        picture.surface.withUnsafeBuffer { buffer in
            #expect(CVPixelBufferGetPixelFormatType(buffer) == VideoDecoder.deepPixelFormat)
            let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
            #expect(transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
            let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
            #expect(primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        }
    }

    @Test func anEightBitStreamStillDecodesToBGRA() throws {
        let decoded = Mutex<DecodedPicture?>(nil)
        let decoder = VideoDecoder { result in
            if case .success(let picture) = result { decoded.withLock { $0 = picture } }
        }
        try decoder.decode(EncodedPicture(codec: .hevc, nalUnits: AnnexB.nalUnits(in: DecoderCapabilities.hevc444Sample), isKeyframe: true, timestamp: 0))
        decoder.finishPending()
        let picture = try #require(decoded.withLock { $0 })
        picture.surface.withUnsafeBuffer { buffer in
            #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        }
    }
}
