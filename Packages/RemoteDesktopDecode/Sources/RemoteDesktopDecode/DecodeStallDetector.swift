// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// Adapted from rootshell-vnc's DecodeOutputStallDetector (MIT, © 2026 Rootshell LLC, Kit Knox).

/// Notices a decoder that takes pictures in and gives nothing back.
///
/// A VideoToolbox session can wedge with no error: pictures go in, no output or failure ever comes
/// out, and the picture freezes while every packet arrives fine. Only the counts tell. A still
/// screen sends no pictures, so silence alone is no stall.
public struct DecodeStallDetector: Sendable {
    /// How long pictures may go in with nothing out before it is a stall.
    public let threshold: Duration
    /// How long after one recovery before another may be called for.
    public let cooldown: Duration

    private var submittedCount = 0
    private var deliveredCount = 0
    private var lastSubmitted = 0
    private var lastDelivered = 0
    private var stalledSince: ContinuousClock.Instant?
    private var lastRecovery: ContinuousClock.Instant?

    public init(threshold: Duration = .seconds(1), cooldown: Duration = .seconds(2)) {
        self.threshold = threshold
        self.cooldown = cooldown
    }

    public mutating func noteSubmitted() {
        submittedCount += 1
    }

    /// The decoder gave a result for a picture: an image, or a failure, either way a sign of life.
    public mutating func noteDelivered() {
        deliveredCount += 1
    }

    /// Whether the decoder has stalled and should be rebuilt now. Says so once per stall, and not
    /// again within the cooldown.
    public mutating func isStalled(at now: ContinuousClock.Instant) -> Bool {
        let newInput = submittedCount > lastSubmitted
        let newOutput = deliveredCount > lastDelivered
        lastSubmitted = submittedCount
        lastDelivered = deliveredCount
        if newOutput {
            stalledSince = nil
            return false
        }
        guard newInput else { return false }
        guard let since = stalledSince else {
            stalledSince = now
            return false
        }
        guard now - since >= threshold, lastRecovery.map({ now - $0 >= cooldown }) ?? true else { return false }
        lastRecovery = now
        stalledSince = nil
        return true
    }
}
