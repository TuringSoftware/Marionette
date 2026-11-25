// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
public import Foundation

public enum AudioDecoderError: Error, Sendable, Equatable {
    case unsupportedFormat(status: Int32)
    case decodeFailed(status: Int32)
}

/// Decodes AAC-ELD access units to interleaved 32-bit float PCM with AudioToolbox.
///
/// The stream is described out of band: a Mac's screen-sharing sound is always AAC-ELD at 48 kHz,
/// stereo, 480 samples a frame, with no SBR, and nothing on the wire says so. Not thread-safe.
public final class AACELDDecoder {
    public let sampleRate: Double
    public let channelCount: Int
    public let framesPerPacket: Int

    private let converter: AudioConverterRef

    /// What the input callback hands the converter: one packet, once.
    private struct Feed {
        var bytes: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        var description = AudioStreamPacketDescription()
    }

    /// Returned by the input callback when it has no packet left; any non-zero value ends the fill.
    private static let noMoreInput: OSStatus = 0x6E6F_6D72 // 'nomr'

    public init(sampleRate: Double = 48_000, channelCount: Int = 2, framesPerPacket: Int = 480) throws(AudioDecoderError) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.framesPerPacket = framesPerPacket

        var input = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: 0, mReserved: 0
        )
        var output = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channelCount), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channelCount),
            mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: 32, mReserved: 0
        )
        var created: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &created)
        guard status == noErr, let created else { throw .unsupportedFormat(status: status) }
        converter = created
    }

    deinit {
        AudioConverterDispose(converter)
    }

    /// Decodes one access unit. Returns interleaved float samples: usually one frame's worth, fewer
    /// (possibly none) while the decoder primes.
    public func decode(_ accessUnit: Data) throws(AudioDecoderError) -> Data {
        guard !accessUnit.isEmpty else { return Data() }
        var output = Data(count: framesPerPacket * channelCount * 4)
        var packets = UInt32(framesPerPacket)
        var status: OSStatus = noErr

        var input = [UInt8](accessUnit)
        let capacity = output.count
        input.withUnsafeMutableBytes { inputBytes in
            var feed = Feed(bytes: inputBytes.baseAddress, count: UInt32(inputBytes.count))
            feed.description.mDataByteSize = UInt32(inputBytes.count)
            output.withUnsafeMutableBytes { outputBytes in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(channelCount), mDataByteSize: UInt32(capacity), mData: outputBytes.baseAddress)
                )
                status = withUnsafeMutablePointer(to: &feed) { feedPointer in
                    AudioConverterFillComplexBuffer(converter, { _, packetCount, bufferList, descriptions, userData in
                        let feed = userData!.assumingMemoryBound(to: Feed.self)
                        guard feed.pointee.count > 0 else {
                            packetCount.pointee = 0
                            return AACELDDecoder.noMoreInput
                        }
                        bufferList.pointee.mNumberBuffers = 1
                        bufferList.pointee.mBuffers.mData = feed.pointee.bytes
                        bufferList.pointee.mBuffers.mDataByteSize = feed.pointee.count
                        if let descriptions {
                            descriptions.pointee = withUnsafeMutablePointer(to: &feed.pointee.description) { $0 }
                        }
                        packetCount.pointee = 1
                        feed.pointee.count = 0
                        return noErr
                    }, feedPointer, &packets, &list, nil)
                }
            }
        }
        guard status == noErr || status == Self.noMoreInput else { throw .decodeFailed(status: status) }
        output.removeSubrange(Int(packets) * channelCount * 4..<output.count)
        return output
    }

    /// Forgets decoder history, after a gap in the stream.
    public func reset() {
        AudioConverterReset(converter)
    }
}
