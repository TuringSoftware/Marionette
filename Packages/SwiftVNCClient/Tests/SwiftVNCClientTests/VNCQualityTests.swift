// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftVNCClient
import Testing

@Suite struct VNCQualityTests {
    @Test func theEstimateStartsAtALocalNetworksSpeed() {
        #expect(VNCThroughputEstimate().bitsPerSecond == 20_000_000)
        #expect(VNCAdaptiveSettings.automatic(bitsPerSecond: VNCThroughputEstimate().bitsPerSecond) == VNCAdaptiveSettings(jpegQuality: 8, isFullColour: true))
    }

    @Test func anUpdateCountsInProportionToItsLength() {
        var estimate = VNCThroughputEstimate()
        // 125 000 bytes in 100 ms is 10 Mbit/s, weighted a tenth.
        estimate.add(bytes: 125_000, elapsed: .milliseconds(100))
        #expect(estimate.bitsPerSecond == 19_000_000)
    }

    @Test func noUpdateMovesTheEstimateByMoreThanAFifth() {
        var estimate = VNCThroughputEstimate()
        // 250 000 bytes in 2 s is 1 Mbit/s, weighted a fifth rather than all.
        estimate.add(bytes: 250_000, elapsed: .seconds(2))
        #expect(estimate.bitsPerSecond == 16_200_000)
    }

    @Test func anInstantUpdateCountsForAlmostNothing() {
        var estimate = VNCThroughputEstimate()
        estimate.add(bytes: 100, elapsed: .zero)
        #expect(estimate.bitsPerSecond == 20_000_780)
    }

    @Test func aSlowLinkWinsWithinSeconds() {
        var estimate = VNCThroughputEstimate()
        var seconds = 0
        while estimate.bitsPerSecond > VNCAdaptiveSettings.fullColourBitsPerSecond {
            estimate.add(bytes: 25_000, elapsed: .seconds(1))
            seconds += 1
        }
        // A fifth closer to 200 kbit/s each second: 200 000 + 19 800 000 × 0.8ⁿ ≤ 256 000 from n = 27.
        #expect(seconds == 27)
    }

    @Test func qualityAndColoursFallAtTheirThresholds() {
        #expect(VNCAdaptiveSettings.automatic(bitsPerSecond: 16_000_001) == VNCAdaptiveSettings(jpegQuality: 8, isFullColour: true))
        #expect(VNCAdaptiveSettings.automatic(bitsPerSecond: 16_000_000) == VNCAdaptiveSettings(jpegQuality: 6, isFullColour: true))
        #expect(VNCAdaptiveSettings.automatic(bitsPerSecond: 256_001) == VNCAdaptiveSettings(jpegQuality: 6, isFullColour: true))
        #expect(VNCAdaptiveSettings.automatic(bitsPerSecond: 256_000) == VNCAdaptiveSettings(jpegQuality: 6, isFullColour: false))
    }

    @Test func fullColourComesBackOnlyWellAboveWhereItWent() {
        #expect(!VNCAdaptiveSettings.automatic(bitsPerSecond: 262_000, isFullColour: false).isFullColour)
        #expect(!VNCAdaptiveSettings.automatic(bitsPerSecond: 320_000, isFullColour: false).isFullColour)
        #expect(VNCAdaptiveSettings.automatic(bitsPerSecond: 320_001, isFullColour: false).isFullColour)
        #expect(VNCAdaptiveSettings.automatic(bitsPerSecond: 262_000, isFullColour: true).isFullColour)
    }
}
