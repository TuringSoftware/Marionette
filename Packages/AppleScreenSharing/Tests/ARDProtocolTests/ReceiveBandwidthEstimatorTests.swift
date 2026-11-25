// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// The cases follow rootshell-vnc's AppleMediaReceiveBandwidthEstimatorTests (MIT, © 2026
// Rootshell LLC, Kit Knox), whose vectors were recorded from Apple's own estimator.

@testable import ARDProtocol
import Foundation
import Testing

@Suite struct ReceiveBandwidthEstimatorTests {
    private func rows(_ vectors: String) -> [[Substring]] {
        vectors.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false) }
    }

    private func expectMatchesApplesEstimator(_ vectors: String) throws {
        var estimator = ReceiveBandwidthEstimator()
        for (index, row) in rows(vectors).enumerated() {
            estimator.calculate(
                time: try #require(Double(row[0].trimmingCharacters(in: .whitespaces))),
                rtpTimestamp: try #require(UInt32(row[1])),
                sizeBytes: try #require(Int(row[2])),
                inTrain: true,
                endOfFrame: row[3] == "1"
            )
            let expected = try #require(Double(row[4]))
            // Recorded arrival times carry nine decimals, so allow 1 ppm.
            #expect(abs(estimator.estimateBps - expected) <= max(1, expected * 1e-6), "row \(index)")
            #expect(estimator.state.rawValue == Int(row[5]), "row \(index)")
        }
    }

    @Test func aStepDownFollowsApplesDivergenceRules() throws {
        try expectMatchesApplesEstimator(BandwidthEstimatorVectors.step100To20To25)
    }

    @Test func timestampWrapReorderingAndRepeatsMatchApples() throws {
        try expectMatchesApplesEstimator(BandwidthEstimatorVectors.wrapReorderDuplicate)
    }

    @Test func theProbingGateGivesApplesReportedFigures() throws {
        var estimator = ReceiveBandwidthEstimator()
        var checked = 0
        for (index, row) in rows(BandwidthEstimatorVectors.gated40To15).enumerated() {
            estimator.notePacket(
                arrivalSeconds: try #require(Double(row[0].trimmingCharacters(in: .whitespaces))),
                rtpTimestamp: try #require(UInt32(row[1])),
                sizeBytes: try #require(Int(row[2])),
                marker: row[3] == "1",
                startsProbe: [2, 3, 6].contains(Int(row[4]))
            )
            guard let expected = Int(row[5]) else { continue }
            checked += 1
            // One 8 kbit/s packing step absorbs the recorded times' rounding.
            #expect(abs(Int(estimator.rctlKbps) - expected) <= 8, "row \(index)")
        }
        #expect(checked == 120)
    }

    @Test func theEstimateIsCappedAndPackedWithTheStableBit() {
        var estimator = ReceiveBandwidthEstimator()
        // Three 300 Mbit/s trains of 20 packets: the first sets the estimate, the next smooth it
        // at the 60 Mbit/s cap.
        for frame in 0..<3 {
            let start = 10.0 + Double(frame) / 60
            for packet in 0..<20 {
                estimator.calculate(
                    time: start + Double(packet) * 1_200 * 8 / 300_000_000,
                    rtpTimestamp: 1_000 + UInt32(frame) * 400,
                    sizeBytes: 1_200,
                    inTrain: true,
                    endOfFrame: packet == 19
                )
            }
        }
        #expect(abs(estimator.estimateBps - 60_000_000) <= 1)
        #expect(estimator.rctlKbps == 60_001)
    }

    @Test func aProbeStartsOnFragmentsAndSlices() {
        #expect(ReceiveBandwidthEstimator.startsProbe(payloadFirstByte: 49 << 1))
        #expect(ReceiveBandwidthEstimator.startsProbe(payloadFirstByte: 1 << 1))
        #expect(!ReceiveBandwidthEstimator.startsProbe(payloadFirstByte: 48 << 1))
        #expect(!ReceiveBandwidthEstimator.startsProbe(payloadFirstByte: 33 << 1))
    }

    /// Until the first measurement the report says the Mac's own ceiling; then the estimate.
    @Test func theRateReportCarriesTheEstimate() throws {
        let epoch = ContinuousClock.now
        var feedback = RateFeedback(epoch: epoch)
        feedback.received(ssrc: 1, timestamp: 100, at: epoch, size: 1200, marker: false, startsProbe: true)
        let before = feedback.report(ssrc: 9, now: epoch)
        #expect(try #require(before).suffix(2) == Data([0xEA, 0x60]))
        // A 40-packet picture arriving at 20 Mbit/s.
        let start = epoch + .seconds(3)
        for packet in 0..<40 {
            feedback.received(
                ssrc: 1, timestamp: 900, at: start + .microseconds(packet * 480),
                size: 1200, marker: packet == 39, startsProbe: true
            )
        }
        let estimate = Int(feedback.bandwidthEstimate)
        #expect((19_000...21_000).contains(estimate))
        let after = feedback.report(ssrc: 9, now: start + .milliseconds(30))
        let field = try #require(after).suffix(2)
        #expect(Int(field[field.startIndex]) << 8 | Int(field[field.startIndex + 1]) == estimate)
    }
}
