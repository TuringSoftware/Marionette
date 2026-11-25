// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
import Synchronization

/// What this device's video decoders can do, found by trying rather than by model lists.
public enum DecoderCapabilities {
    /// Whether this device decodes HEVC Range Extensions 8-bit 4:4:4 (a Mac's High Performance
    /// stream) in hardware. Not documented per iPhone and iPad, and software decoding cannot keep
    /// up with a live screen; when false, a viewer should ask the Mac for H.264.
    ///
    /// Worked out by decoding one small 4:4:4 picture. Only a yes is remembered: a probe while
    /// VideoToolbox is unavailable (app in the background, memory short) says no transiently.
    public static var decodesHEVC444InHardware: Bool {
        if confirmed.withLock({ $0 }) { return true }
        let answer = probeHEVC444()
        if answer { confirmed.withLock { $0 = true } }
        return answer
    }

    private static let confirmed = Mutex(false)

    /// Whether a live stream has to be decoded in hardware. False in the simulator, where
    /// VideoToolbox never reports hardware decoding.
    public static let liveStreamsNeedHardware: Bool = {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }()

    /// One 64 × 64 HEVC Range Extensions 4:4:4 keyframe as an Annex B stream: VPS, SPS, PPS, IDR.
    static let hevc444Sample = Data(base64Encoded: "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")!

    static func probeHEVC444() -> Bool {
        let result = Mutex<DecodedPicture?>(nil)
        let decoder = VideoDecoder(allowsSoftwareDecoding: !liveStreamsNeedHardware) { outcome in
            if case .success(let picture) = outcome { result.withLock { $0 = picture } }
        }
        let picture = EncodedPicture(codec: .hevc, nalUnits: AnnexB.nalUnits(in: hevc444Sample), isKeyframe: true, timestamp: 0)
        do {
            try decoder.decode(picture)
        } catch {
            return false
        }
        decoder.finishPending()
        defer { decoder.invalidate() }
        guard decoder.isHardwareAccelerated == true || !liveStreamsNeedHardware, let decoded = result.withLock({ $0 }) else { return false }
        return decoded.width > 0 && decoded.height > 0
    }
}
