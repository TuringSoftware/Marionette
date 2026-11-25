// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// The start-up hold and the time-based gap hold follow rootshell-vnc's AppleMediaRTPIngress
// (MIT, © 2026 Rootshell LLC, Kit Knox).

/// Puts packets that overtook each other on the way back into sending order.
///
/// A network may deliver a packet some places late; over Wi-Fi a packet four or more places late
/// in a keyframe's burst of hundreds is common. Read in arrival order that looks like a loss, which
/// costs a restart of the picture stream; held for a moment, the straggler usually turns up. A
/// packet is kept back only while one before it is missing, and only for ``hold`` after it
/// arrived, so a real loss costs that much latency and no more. The first packets of a stream are
/// held for ``startupHold`` so that the stream starts at the lowest number among them, not at
/// whichever overtook the others.
///
/// Call ``release(at:)`` by ``deadline`` for packets to go out when no more arrive.
public struct RTPReorderBuffer: Sendable {
    public let hold: Duration
    public let startupHold: Duration
    /// Packets held at most; past this the oldest gap is given up on at once.
    public let capacity: Int
    /// A packet that seems older than what has gone out, arriving after the stream was silent
    /// this long, is the stream carrying on from further ahead, not a straggler.
    public static let discontinuitySilence: Duration = .seconds(1)

    private struct Held: Sendable {
        var packet: RTPPacket
        var arrival: ContinuousClock.Instant
    }

    private var ssrc: UInt32?
    private var isStarted = false
    private var startupDeadline: ContinuousClock.Instant?
    /// Where order is counted from before the stream starts: its first packet.
    private var origin: UInt16 = 0
    private var next: UInt16 = 0
    /// Packets waiting, in sending order.
    private var held: [Held] = []
    /// Since when the packets after the current gap have waited.
    private var gapSince: ContinuousClock.Instant?
    private var lastArrival: ContinuousClock.Instant?

    public init(hold: Duration = .milliseconds(15), startupHold: Duration = .milliseconds(8), capacity: Int = 4096) {
        self.hold = max(.zero, hold)
        self.startupHold = max(.zero, startupHold)
        self.capacity = max(0, capacity)
    }

    public var isHolding: Bool { !held.isEmpty }

    /// When ``release(at:)`` next has something to let go, if anything is waiting.
    public var deadline: ContinuousClock.Instant? {
        guard !held.isEmpty else { return nil }
        return isStarted ? gapSince.map { $0 + hold } : startupDeadline
    }

    /// Forgets the stream, for one that starts over (a new offer): nothing held goes out.
    public mutating func reset() {
        self = RTPReorderBuffer(hold: hold, startupHold: startupHold, capacity: capacity)
    }

    /// Takes one packet as it arrived; returns those now ready, in sending order. A gap in what
    /// comes back is a loss.
    public mutating func push(_ packet: RTPPacket, at now: ContinuousClock.Instant) -> [RTPPacket] {
        var ready = release(at: now)
        defer { lastArrival = now }
        guard packet.ssrc == ssrc else {
            // A new stream numbers its packets afresh; what waited for the old one goes out as it is.
            ready += held.map(\.packet)
            let keep = (hold, startupHold, capacity)
            self = RTPReorderBuffer(hold: keep.0, startupHold: keep.1, capacity: keep.2)
            ssrc = packet.ssrc
            origin = packet.sequence
            held = [Held(packet: packet, arrival: now)]
            startupDeadline = now + startupHold
            return ready + release(at: now)
        }
        guard isStarted else {
            insert(packet, at: now, relativeTo: origin)
            if held.count > capacity { startupDeadline = now }
            return ready + release(at: now)
        }
        let ahead = Int(Int16(bitPattern: packet.sequence &- next))
        if ahead < -SequenceTracker.maximumLateness || (ahead < 0 && lastArrival.map { now - $0 >= Self.discontinuitySilence } == true) {
            // Further behind than any straggler can be: the sender jumped ahead by more than half
            // the number space. Go on from here; the gap is a loss like any other.
            ready += held.map(\.packet)
            held = []
            gapSince = nil
            next = packet.sequence &+ 1
            return ready + [packet]
        }
        // Older than what has gone out already: it was given up on, or it is a repeat.
        guard ahead >= 0 else { return ready }
        if ahead == 0 {
            next = packet.sequence &+ 1
            return ready + [packet] + releaseRun(at: now)
        }
        insert(packet, at: now, relativeTo: next)
        if gapSince == nil { gapSince = now }
        while held.count > capacity { ready += skipGap(at: now) }
        return ready
    }

    /// Releases what has waited long enough: a stream's first packets after the start-up hold, and
    /// packets held for longer than ``hold`` behind a gap, gap and all.
    public mutating func release(at now: ContinuousClock.Instant) -> [RTPPacket] {
        guard !held.isEmpty else { return [] }
        var ready: [RTPPacket] = []
        if !isStarted {
            guard let startupDeadline, now >= startupDeadline else { return [] }
            isStarted = true
            next = held[0].packet.sequence
            ready += releaseRun(at: now)
        }
        while let since = gapSince, now >= since + hold {
            ready += skipGap(at: now)
        }
        return ready
    }

    /// Puts a packet among the waiting ones in sending order, dropping a repeat.
    private mutating func insert(_ packet: RTPPacket, at now: ContinuousClock.Instant, relativeTo base: UInt16) {
        let distance = Int16(bitPattern: packet.sequence &- base)
        let position = held.firstIndex { Int16(bitPattern: $0.packet.sequence &- base) >= distance } ?? held.endIndex
        if position < held.endIndex, held[position].packet.sequence == packet.sequence { return }
        held.insert(Held(packet: packet, arrival: now), at: position)
    }

    /// Gives up on the packets missing before the nearest waiting one, and releases from there.
    private mutating func skipGap(at now: ContinuousClock.Instant) -> [RTPPacket] {
        guard let nearest = held.first else { return [] }
        next = nearest.packet.sequence
        return releaseRun(at: now)
    }

    /// Releases the waiting packets that now follow on without a gap. Those left behind the next
    /// gap have waited since the earliest of them arrived.
    private mutating func releaseRun(at now: ContinuousClock.Instant) -> [RTPPacket] {
        var count = 0
        while count < held.count, held[count].packet.sequence == next {
            next &+= 1
            count += 1
        }
        let ready = held.prefix(count).map(\.packet)
        held.removeFirst(count)
        if count > 0 || held.isEmpty {
            gapSince = held.map(\.arrival).min()
        }
        return ready
    }
}
