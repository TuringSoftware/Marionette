// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

@testable import ARDProtocol
import ARDTestSupport
import Foundation
import Testing

/// The negotiation blobs Apple's own viewer produced, as recorded in the test suite of
/// andrewtheguy/remotex (MIT, © 2026 Andrew Chen; captured from macOS 26.6). Our builders must
/// reproduce them byte for byte when given the same SSRC, size and tile count.
@Suite struct CapturedOfferTests {
    static let capturedAudioBlob = Data(hex: """
        080110011a120885a2c6b70d1000180020ffbc0128003000320d56696365726f7920312e372e3040004a05080110ab02
        4a0908ea1f1000188080014a0b080010c0d1e123188080204a0b08001080dac409188080064a0a08001080b489131880
        604a0b080010808ece1c188080104a0508101084204a0b08001080c2d72f188080404a05080410e4324a0b080010809b
        ee02188080086880e0f084deafb6a3ee017002800100
        """)

    static let capturedVideoBlob = Data(hex: """
        080110012af5010895a1c8a10b10001a7d087b120a0801100118c387032000120a0801100218c387032000120a080110
        0118c387032000120a0801100218c3870320001a47464c533b4d533a2d313b4c463a2d313b4c54523b43414241433b50
        4f533a303b454f443a313b4854533a323b52523a333b41523a342f332c352f383b58523a342f332c352f383b20011a5c
        0864120a0801100118c387032000120a0801100218c3870320001a3e464c533b4c463a2d313b504f533a353b454f443a
        313b4854533a323b52523a333b504f53453a343b41523a342f332c352f383b58523a342f332c352f383b200e20c00c28
        e80730043801403f48016001320d56696365726f7920312e372e3040004a0a08001080b489131880604a05080110ab02
        4a0908ea1f1000188080014a0b080010c0d1e123188080204a0b08001080dac409188080064a0b080010808ece1c1880
        80104a0508101084204a0b08001080c2d72f188080404a05080410e4324a0b080010809bee0218808008688080e7dedf
        afb6a3ee017002800100
        """)

    /// The varint at `offset`, which is where each blob holds the viewer's SSRC.
    private func varint(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var index = offset
        while true {
            let byte = data[index]
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            index += 1
        }
        return UInt32(value)
    }

    @Test func audioBlobMatchesAppleViewer() {
        let ssrc = varint(Self.capturedAudioBlob, at: 7)
        #expect(MediaOffer.audioBlob(ssrc: ssrc) == Self.capturedAudioBlob)
    }

    @Test func videoBlobMatchesAppleViewer() {
        let ssrc = varint(Self.capturedVideoBlob, at: 8)
        let video = MediaOffer.Video(
            ssrc: ssrc,
            keys: MediaLegKeys(viewerToServer: MediaKey(bytes: Data(count: 46)), serverToViewer: MediaKey(bytes: Data(count: 46))),
            width: 1600, height: 1000, codec: .hevc, tilesPerFrame: 4
        )
        #expect(MediaOffer.videoBlob(video) == Self.capturedVideoBlob)
    }
}
