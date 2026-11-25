// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import RemoteDesktopDecode
import Testing

/// Encodes interleaved float PCM to AAC-ELD access units with the system encoder, so the decoder
/// can be tested on a stream of the shape a Mac sends without storing one.
private final class ELDEncoder {
    let converter: AudioConverterRef
    let framesPerPacket: Int
    private var pending: [Float32] = []

    private struct Feed {
        var bytes: UnsafeMutableRawPointer?
        var frames: UInt32
    }

    init?(framesPerPacket: Int) {
        var input = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var output = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        var created: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &created) == noErr, let created else { return nil }
        converter = created
        self.framesPerPacket = framesPerPacket
    }

    deinit {
        AudioConverterDispose(converter)
    }

    func encode(_ frame: [Float32]) -> Data? {
        var samples = frame
        var packet = Data(count: 4096)
        var packets: UInt32 = 1
        var description = AudioStreamPacketDescription()
        let capacity = packet.count
        let status: OSStatus = samples.withUnsafeMutableBytes { input in
            var feed = Feed(bytes: input.baseAddress, frames: UInt32(frame.count / 2))
            return packet.withUnsafeMutableBytes { output in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(capacity), mData: output.baseAddress))
                return withUnsafeMutablePointer(to: &feed) { feedPointer in
                    AudioConverterFillComplexBuffer(converter, { _, count, buffers, _, userData in
                        let feed = userData!.assumingMemoryBound(to: Feed.self)
                        guard feed.pointee.frames > 0 else {
                            count.pointee = 0
                            return 1
                        }
                        buffers.pointee.mNumberBuffers = 1
                        buffers.pointee.mBuffers.mData = feed.pointee.bytes
                        buffers.pointee.mBuffers.mDataByteSize = feed.pointee.frames * 8
                        count.pointee = feed.pointee.frames
                        feed.pointee.frames = 0
                        return noErr
                    }, feedPointer, &packets, &list, &description)
                }
            }
        }
        guard status == noErr || status == 1, packets == 1 else { return nil }
        return packet.subdata(in: Int(description.mStartOffset)..<Int(description.mStartOffset) + Int(description.mDataByteSize))
    }
}

@Suite struct AACELDDecoderTests {
    @Test func decodesAToneEncodedBySystemEncoder() throws {
        let encoder = try #require(ELDEncoder(framesPerPacket: 480), "this system has no AAC-ELD encoder at 480 samples a frame")
        let decoder = try AACELDDecoder()
        #expect(decoder.framesPerPacket == 480)

        var phase = 0.0
        var decoded: [Float32] = []
        var packetSizes: [Int] = []
        for _ in 0..<60 {
            var frame = [Float32](repeating: 0, count: 960)
            for index in 0..<480 {
                let value = Float32(sin(phase) * 0.5)
                frame[index * 2] = value
                frame[index * 2 + 1] = value
                phase += 2 * .pi * 1000 / 48_000
            }
            guard let packet = encoder.encode(frame) else { continue }
            packetSizes.append(packet.count)
            let samples = try decoder.decode(packet)
            #expect(samples.count % 8 == 0)
            #expect(samples.count <= 480 * 8)
            samples.withUnsafeBytes { decoded.append(contentsOf: $0.bindMemory(to: Float32.self)) }
        }
        #expect(packetSizes.count >= 50)
        // Nearly every packet yields a full 10 ms frame.
        #expect(decoded.count >= 45 * 960)

        // After the codec's start-up, the output is the tone: its level, and energy at 1 kHz.
        let steady = Array(decoded.dropFirst(10 * 960))
        let left = stride(from: 0, to: steady.count, by: 2).map { Double(steady[$0]) }
        let rms = (left.reduce(0) { $0 + $1 * $1 } / Double(left.count)).squareRoot()
        #expect(abs(rms - 0.5 / 2.0.squareRoot()) < 0.05, "RMS was \(rms)")
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in left.enumerated() {
            let angle = 2 * Double.pi * 1000 * Double(index) / 48_000
            real += sample * cos(angle)
            imaginary += sample * sin(angle)
        }
        let toneAmplitude = 2 * (real * real + imaginary * imaginary).squareRoot() / Double(left.count)
        #expect(abs(toneAmplitude - 0.5) < 0.05, "1 kHz amplitude was \(toneAmplitude)")
    }

    @Test func emptyAndGarbageInputDoNotCrash() throws {
        let decoder = try AACELDDecoder()
        #expect(try decoder.decode(Data()) == Data())
        for seed in UInt8(0)..<20 {
            let garbage = Data((0..<Int(seed) * 7 + 3).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
            _ = try? decoder.decode(garbage)
        }
        decoder.reset()
        // The four-byte frame a Mac sends while it plays nothing.
        let silence = try decoder.decode(Data([0x00, 0x68, 0x34, 0x00]))
        #expect(silence.count <= 480 * 8)
    }
}
