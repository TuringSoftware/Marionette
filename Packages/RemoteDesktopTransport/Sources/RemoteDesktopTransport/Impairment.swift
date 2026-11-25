// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import RemoteDesktopCore
import Foundation
import Synchronization

/// A bad network, described: what happens to datagrams on their way in and out, and to the bytes of
/// streams.
///
/// Used to test how a session copes with loss, congestion and delay. The same seed gives the same
/// decisions for the same sequence of datagrams, so a failure can be replayed.
public struct NetworkImpairment: Sendable, Hashable {
    /// Chance that a received datagram is dropped, 0–1.
    public var inboundLoss: Double
    /// Chance that a sent datagram is dropped, 0–1.
    public var outboundLoss: Double
    /// Chance that a received datagram is delivered twice.
    public var duplication: Double
    /// Chance that a received datagram is held back and delivered after the one behind it.
    public var reordering: Double
    /// When a datagram is lost, how many of the following ones go with it. `0...0` for single losses.
    public var burstLength: ClosedRange<Int>
    /// How long each flow is left alone after it opens, so that a session can start cleanly and
    /// meet the bad network once it is running.
    public var quietPeriod: Duration
    public var seed: UInt64
    /// Rate of the link received datagrams cross, in bits per second, or `nil` for no limit. Every
    /// datagram channel of a provider shares the one link, as the legs of a session share a path.
    public var inboundBandwidth: Int?
    /// The same for sent datagrams: the uplink.
    public var outboundBandwidth: Int?
    /// How long a datagram may wait in front of a rate-limited link. One that would wait longer is
    /// dropped on arrival: a drop-tail queue measured in time, which is how a keyframe burst meets a
    /// slow path.
    public var queueLimit: Duration
    /// One-way delay added to every datagram, each way.
    public var delay: Duration
    /// Extra one-way delay, chosen per datagram from `0...jitter` by the seeded generator. Datagrams
    /// overtake one another by up to this much, which reorders deeply.
    public var jitter: Duration
    /// What happens to streams (the TCP control channel).
    public var streams: StreamImpairment

    public init(
        inboundLoss: Double = 0, outboundLoss: Double = 0, duplication: Double = 0, reordering: Double = 0,
        burstLength: ClosedRange<Int> = 0...0, quietPeriod: Duration = .zero, seed: UInt64 = 1,
        inboundBandwidth: Int? = nil, outboundBandwidth: Int? = nil, queueLimit: Duration = .milliseconds(100),
        delay: Duration = .zero, jitter: Duration = .zero, streams: StreamImpairment = StreamImpairment()
    ) {
        self.quietPeriod = quietPeriod
        self.inboundLoss = inboundLoss
        self.outboundLoss = outboundLoss
        self.duplication = duplication
        self.reordering = reordering
        self.burstLength = burstLength
        self.seed = seed
        self.inboundBandwidth = inboundBandwidth
        self.outboundBandwidth = outboundBandwidth
        self.queueLimit = queueLimit
        self.delay = delay
        self.jitter = jitter
        self.streams = streams
    }

    var holdsDatagrams: Bool {
        inboundBandwidth != nil || outboundBandwidth != nil || delay > .zero || jitter > .zero
    }
}

/// A bad network for a stream. TCP hides loss from its users; what they see is a slow link, a long
/// one, and stalls while a lost segment is sent again.
public struct StreamImpairment: Sendable, Hashable {
    /// Rate of the link, each way, in bits per second, or `nil` for no limit.
    public var bandwidth: Int?
    /// One-way delay, each way.
    public var delay: Duration
    /// Chance that a segment (1448 bytes) is lost. Nothing is missing afterwards, but it and
    /// everything behind it arrive `stallDuration` late: the head-of-line stall of a retransmission.
    public var stallChance: Double
    /// How late a retransmitted segment arrives: about a retransmission timeout.
    public var stallDuration: Duration

    public init(bandwidth: Int? = nil, delay: Duration = .zero, stallChance: Double = 0, stallDuration: Duration = .milliseconds(250)) {
        self.bandwidth = bandwidth
        self.delay = delay
        self.stallChance = stallChance
        self.stallDuration = stallDuration
    }

    var isClean: Bool { bandwidth == nil && delay == .zero && stallChance == 0 }
}

/// What an impaired path did, for a test's report.
public struct ImpairmentCounts: Sendable, Hashable {
    public var received = 0
    public var droppedInbound = 0
    public var duplicated = 0
    public var reordered = 0
    public var sent = 0
    public var droppedOutbound = 0
    /// Received datagrams dropped because the inbound link's queue was full.
    public var overflowedInbound = 0
    /// Sent datagrams dropped because the uplink's queue was full.
    public var overflowedOutbound = 0
    /// Segments of streams that stalled as if lost and sent again.
    public var streamStalls = 0
}

/// Shared tally of every channel a provider impaired.
public final class ImpairmentLedger: Sendable {
    private let counts = Mutex(ImpairmentCounts())

    public init() {}

    public var snapshot: ImpairmentCounts { counts.withLock { $0 } }

    func update(_ body: (inout ImpairmentCounts) -> Void) {
        counts.withLock { body(&$0) }
    }
}

/// The conditions an impaired provider applies right now. Changing them affects every channel and
/// stream the provider opened, from their next datagram or chunk on, so a test can make the network
/// worse in the middle of a session.
public final class ImpairmentControl: Sendable {
    /// A change of conditions, some time after ``play(_:)`` starts.
    public struct Step: Sendable, Hashable {
        public var after: Duration
        public var impairment: NetworkImpairment

        public init(after: Duration, impairment: NetworkImpairment) {
            self.after = after
            self.impairment = impairment
        }
    }

    private let state: Mutex<NetworkImpairment>

    public init(_ impairment: NetworkImpairment) {
        state = Mutex(impairment)
    }

    public var current: NetworkImpairment { state.withLock { $0 } }

    public func update(_ impairment: NetworkImpairment) {
        state.withLock { $0 = impairment }
    }

    /// Applies each step once its time has passed, counted from now. Cancel the task to stop early.
    @discardableResult
    public func play(_ steps: [Step]) -> Task<Void, Never> {
        let start = ContinuousClock.now
        return Task { [self] in
            for step in steps.sorted(by: { $0.after < $1.after }) {
                do {
                    try await Task.sleep(until: start + step.after, clock: .continuous)
                } catch {
                    return
                }
                update(step.impairment)
            }
        }
    }
}

/// SplitMix64, so the same seed gives the same decisions on every platform.
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// A value in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func chance(_ probability: Double) -> Bool {
        probability > 0 && unit() < probability
    }

    mutating func pick(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    /// A duration in `0...limit`.
    mutating func upTo(_ limit: Duration) -> Duration {
        limit > .zero ? limit * unit() : .zero
    }
}

/// A rate-limited link with a queue in front of it, shared by everything that crosses it.
final class Bottleneck: Sendable {
    private let freeAt = Mutex(ContinuousClock.Instant.now)

    /// Bytes a datagram puts on the wire besides its payload: IPv4 and UDP headers.
    static let datagramOverhead = 28

    /// When `bytes` that reach the link at `arrival` have finished crossing it at `rate` bits per
    /// second, or `nil` if they would wait in the queue for longer than `queueLimit` and are dropped.
    func cross(bytes: Int, arrival: ContinuousClock.Instant, rate: Int, queueLimit: Duration?) -> ContinuousClock.Instant? {
        let transmission = Duration.seconds(Double(bytes * 8) / Double(max(1, rate)))
        return freeAt.withLock { freeAt in
            let start = max(arrival, freeAt)
            if let queueLimit, start - arrival > queueLimit { return nil }
            freeAt = start + transmission
            return freeAt
        }
    }
}

/// Runs work at given instants, in order of instant and then of scheduling, on one serial queue.
final class DelayLine: Sendable {
    private struct Entry {
        let at: ContinuousClock.Instant
        let order: UInt64
        let work: @Sendable () -> Void
    }

    private struct State {
        var entries: [Entry] = []
        var nextOrder: UInt64 = 0
        var isRunning = false
        var isClosed = false
    }

    let queue: DispatchQueue
    private let state = Mutex(State())

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    /// True when nothing is waiting or running: work done now elsewhere cannot overlap or overtake.
    var isIdle: Bool { state.withLock { $0.entries.isEmpty && !$0.isRunning } }

    func schedule(at instant: ContinuousClock.Instant, _ work: @escaping @Sendable () -> Void) {
        let isEarliest: Bool = state.withLock { state in
            guard !state.isClosed else { return false }
            let entry = Entry(at: instant, order: state.nextOrder, work: work)
            state.nextOrder &+= 1
            let index = state.entries.firstIndex { ($0.at, $0.order) > (entry.at, entry.order) } ?? state.entries.endIndex
            state.entries.insert(entry, at: index)
            return index == 0
        }
        if isEarliest { wake(at: instant) }
    }

    /// Drops whatever has not run yet, then runs `last` after anything running now.
    func close(then last: @escaping @Sendable () -> Void) {
        state.withLock { state in
            state.isClosed = true
            state.entries.removeAll()
        }
        queue.async(execute: last)
    }

    private func wake(at instant: ContinuousClock.Instant) {
        let wait = max(.zero, instant - .now)
        let nanoseconds = wait.components.seconds * 1_000_000_000 + wait.components.attoseconds / 1_000_000_000
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), qos: .userInteractive, flags: .enforceQoS) { [self] in
            fire()
        }
    }

    private func fire() {
        while true {
            let next: Entry? = state.withLock { state in
                guard let first = state.entries.first, first.at <= .now else {
                    state.isRunning = false
                    return nil
                }
                state.isRunning = true
                return state.entries.removeFirst()
            }
            guard let next else { break }
            next.work()
        }
        // Timers may fire early or merge; look again for the earliest that is still to come.
        if let upcoming = state.withLock({ $0.entries.first?.at }) { wake(at: upcoming) }
    }
}

/// A datagram channel with a bad network in front of it.
public final class ImpairedDatagramChannel: DatagramChannel {
    private struct State {
        var generator: SeededGenerator
        var outboundGenerator: SeededGenerator
        var held: Datagram?
        var inboundBurst = 0
        var outboundBurst = 0
        var onReceive: (@Sendable (Datagram) -> Void)?
    }

    private let base: any DatagramChannel
    private let control: ImpairmentControl
    private let ledger: ImpairmentLedger
    private let inboundLink: Bottleneck
    private let outboundLink: Bottleneck
    private let state: Mutex<State>
    private let arrivals: DelayLine
    private let departures: DelayLine
    private let opened = ContinuousClock.now

    public convenience init(_ base: any DatagramChannel, impairment: NetworkImpairment, ledger: ImpairmentLedger = ImpairmentLedger()) {
        self.init(base, control: ImpairmentControl(impairment), ledger: ledger)
    }

    /// A channel whose conditions follow `control`. The seed is the one `control` holds now.
    public convenience init(_ base: any DatagramChannel, control: ImpairmentControl, ledger: ImpairmentLedger = ImpairmentLedger()) {
        self.init(base, control: control, seed: control.current.seed, ledger: ledger, inboundLink: Bottleneck(), outboundLink: Bottleneck())
    }

    init(
        _ base: any DatagramChannel, control: ImpairmentControl, seed: UInt64, ledger: ImpairmentLedger,
        inboundLink: Bottleneck, outboundLink: Bottleneck
    ) {
        self.base = base
        self.control = control
        self.ledger = ledger
        self.inboundLink = inboundLink
        self.outboundLink = outboundLink
        // Separate streams, so what is sent does not change what is lost on the way in.
        state = Mutex(State(
            generator: SeededGenerator(seed: seed),
            outboundGenerator: SeededGenerator(seed: seed ^ 0x5555_5555_5555_5555)
        ))
        arrivals = DelayLine(label: "llc.turing.Marionette.impairment.in")
        departures = DelayLine(label: "llc.turing.Marionette.impairment.out")
    }

    public var localPort: UInt16 { base.localPort }

    private func isQuiet(_ conditions: NetworkImpairment) -> Bool {
        conditions.quietPeriod > .zero && ContinuousClock.now - opened < conditions.quietPeriod
    }

    public func start(onReceive: @escaping @Sendable (Datagram) -> Void, onClose: @escaping @Sendable (TransportError?) -> Void) {
        state.withLock { $0.onReceive = onReceive }
        base.start(
            onReceive: { [self] datagram in
                arrive(datagram)
            },
            onClose: { [self] error in
                let (held, handler) = state.withLock { state -> (Datagram?, (@Sendable (Datagram) -> Void)?) in
                    defer { state.held = nil }
                    return (state.held, state.onReceive)
                }
                if arrivals.isIdle {
                    if let held { handler?(held) }
                    onClose(error)
                } else {
                    // Datagrams still crossing the link are lost with the socket.
                    arrivals.close {
                        if let held { handler?(held) }
                        onClose(error)
                    }
                }
                departures.close {}
            }
        )
    }

    private func arrive(_ datagram: Datagram) {
        let conditions = control.current
        if isQuiet(conditions) {
            ledger.update { $0.received += 1 }
            deliver([datagram], conditions: conditions, impaired: false)
            return
        }
        var counts = ImpairmentCounts()
        counts.received = 1
        let delivered: [Datagram] = state.withLock { state in
            if state.inboundBurst > 0 {
                state.inboundBurst -= 1
                counts.droppedInbound = 1
                return []
            }
            if state.generator.chance(conditions.inboundLoss) {
                state.inboundBurst = state.generator.pick(conditions.burstLength)
                counts.droppedInbound = 1
                return []
            }
            var output = [datagram]
            if state.generator.chance(conditions.duplication) {
                output.append(datagram)
                counts.duplicated = 1
            }
            if var held = state.held {
                // The one held back goes out behind this one, stamped as arriving with it.
                state.held = nil
                held.receivedAt = datagram.receivedAt
                output.append(held)
            } else if state.generator.chance(conditions.reordering) {
                state.held = output.removeLast()
                counts.reordered = 1
            }
            return output
        }
        ledger.update { total in
            total.received += counts.received
            total.droppedInbound += counts.droppedInbound
            total.duplicated += counts.duplicated
            total.reordered += counts.reordered
        }
        deliver(delivered, conditions: conditions, impaired: true)
    }

    private func deliver(_ datagrams: [Datagram], conditions: NetworkImpairment, impaired: Bool) {
        let handler = state.withLock { $0.onReceive }
        let holds = impaired && conditions.holdsDatagrams
        // At once while nothing is in flight: the only way to keep delivery serial and in order
        // without a hop to another queue.
        if !holds, arrivals.isIdle {
            for datagram in datagrams { handler?(datagram) }
            return
        }
        for datagram in datagrams {
            var due = datagram.receivedAt
            if holds, let rate = conditions.inboundBandwidth {
                guard let crossed = inboundLink.cross(
                    bytes: datagram.payload.count + Bottleneck.datagramOverhead, arrival: due, rate: rate, queueLimit: conditions.queueLimit
                ) else {
                    ledger.update { $0.overflowedInbound += 1 }
                    continue
                }
                due = crossed
            }
            if holds { due += conditions.delay + state.withLock { $0.generator.upTo(conditions.jitter) } }
            let payload = datagram.payload
            arrivals.schedule(at: due) {
                // Stamped when it reaches the socket, as a real late datagram would be.
                handler?(Datagram(payload: payload, receivedAt: .now))
            }
        }
    }

    public func send(_ payload: Data) {
        let conditions = control.current
        let quiet = isQuiet(conditions)
        let dropped: Bool = quiet ? false : state.withLock { state in
            if state.outboundBurst > 0 {
                state.outboundBurst -= 1
                return true
            }
            if state.outboundGenerator.chance(conditions.outboundLoss) {
                state.outboundBurst = state.outboundGenerator.pick(conditions.burstLength)
                return true
            }
            return false
        }
        ledger.update { total in
            total.sent += 1
            if dropped { total.droppedOutbound += 1 }
        }
        guard !dropped else { return }
        let holds = !quiet && conditions.holdsDatagrams
        if !holds, departures.isIdle {
            base.send(payload)
            return
        }
        var due = ContinuousClock.now
        if holds, let rate = conditions.outboundBandwidth {
            guard let crossed = outboundLink.cross(
                bytes: payload.count + Bottleneck.datagramOverhead, arrival: due, rate: rate, queueLimit: conditions.queueLimit
            ) else {
                ledger.update { $0.overflowedOutbound += 1 }
                return
            }
            due = crossed
        }
        if holds { due += conditions.delay + state.withLock { $0.outboundGenerator.upTo(conditions.jitter) } }
        departures.schedule(at: due) { [base] in base.send(payload) }
    }

    public func close() {
        base.close()
    }
}

/// A stream with a bad network in front of it: a rate limit and delay each way, and stalls where
/// TCP would have sent a lost segment again.
public final class ImpairedByteStream: ByteStream {
    private struct Chunk {
        var data: Data
        let due: ContinuousClock.Instant
    }

    private struct State {
        var chunks: [Chunk] = []
        var buffered = 0
        var end: Result<Void, TransportError>?
        var reader: CheckedContinuation<Void, Never>?
        var generator: SeededGenerator
        var inboundFreeAt = ContinuousClock.Instant.now
        var lastInboundDue = ContinuousClock.Instant.now
        var outboundFreeAt = ContinuousClock.Instant.now
        var lastOutboundDue = ContinuousClock.Instant.now
        var writeFailure: TransportError?
    }

    /// How far ahead of the link the stream reads from the real connection. Beyond this it stops
    /// reading, so the sender meets TCP's own back-pressure instead of an unbounded buffer here.
    private static let readAhead = Duration.milliseconds(200)
    private static let segment = 1448

    private let base: any ByteStream
    private let control: ImpairmentControl
    private let ledger: ImpairmentLedger
    private let state: Mutex<State>
    private let outbound: AsyncStream<Chunk>.Continuation
    private let tasks: Mutex<[Task<Void, Never>]>

    public init(_ base: any ByteStream, control: ImpairmentControl, ledger: ImpairmentLedger = ImpairmentLedger()) {
        self.base = base
        self.control = control
        self.ledger = ledger
        state = Mutex(State(generator: SeededGenerator(seed: control.current.seed ^ 0x3c3c_3c3c_3c3c_3c3c)))
        let (stream, continuation) = AsyncStream.makeStream(of: Chunk.self)
        outbound = continuation
        tasks = Mutex([])
        let pumps: [Task<Void, Never>] = [
            Task { [weak self] in await self?.pumpInbound() },
            Task { [weak self] in await self?.pumpOutbound(stream) },
        ]
        tasks.withLock { $0 = pumps }
    }

    deinit {
        outbound.finish()
        for task in tasks.withLock({ $0 }) { task.cancel() }
    }

    /// When `bytes` passed now finish crossing a link that is free from `freeAt`, plus delay and
    /// any stall; never earlier than `last`, as TCP delivers in order.
    private static func due(
        bytes: Int, conditions: StreamImpairment, freeAt: inout ContinuousClock.Instant,
        last: inout ContinuousClock.Instant, generator: inout SeededGenerator
    ) -> (due: ContinuousClock.Instant, stalls: Int) {
        let now = ContinuousClock.now
        var crossed = now
        if let rate = conditions.bandwidth {
            crossed = max(now, freeAt) + .seconds(Double(bytes * 8) / Double(max(1, rate)))
            freeAt = crossed
        }
        var stalls = 0
        for _ in 0..<((bytes + segment - 1) / segment) where generator.chance(conditions.stallChance) {
            stalls += 1
        }
        let due = max(last, crossed + conditions.delay + conditions.stallDuration * stalls)
        last = due
        return (due, stalls)
    }

    private func pumpInbound() async {
        while !Task.isCancelled {
            let data: Data?
            do {
                data = try await base.read(upTo: 1 << 16)
            } catch {
                finishInbound(.failure(error as? TransportError ?? .other(detail: String(describing: error))))
                return
            }
            guard let data else {
                finishInbound(.success(()))
                return
            }
            let conditions = control.current.streams
            let (reader, stalls, linkFreeAt): (CheckedContinuation<Void, Never>?, Int, ContinuousClock.Instant) = state.withLock { state in
                let (due, stalls) = Self.due(
                    bytes: data.count, conditions: conditions, freeAt: &state.inboundFreeAt,
                    last: &state.lastInboundDue, generator: &state.generator
                )
                state.chunks.append(Chunk(data: data, due: due))
                state.buffered += data.count
                defer { state.reader = nil }
                return (state.reader, stalls, state.inboundFreeAt)
            }
            if stalls > 0 { ledger.update { $0.streamStalls += stalls } }
            reader?.resume()
            if linkFreeAt - .now > Self.readAhead {
                try? await Task.sleep(until: linkFreeAt - Self.readAhead, clock: .continuous)
            }
        }
    }

    private func finishInbound(_ end: Result<Void, TransportError>) {
        let reader = state.withLock { state in
            if state.end == nil { state.end = end }
            defer { state.reader = nil }
            return state.reader
        }
        reader?.resume()
    }

    private func pumpOutbound(_ chunks: AsyncStream<Chunk>) async {
        for await chunk in chunks {
            try? await Task.sleep(until: chunk.due, clock: .continuous)
            do {
                try await base.write(chunk.data)
            } catch {
                let failure = error as? TransportError ?? .other(detail: String(describing: error))
                state.withLock { $0.writeFailure = failure }
                return
            }
        }
    }

    public func read(upTo maxLength: Int) async throws -> Data? {
        enum Next {
            case data(Data)
            case wait(ContinuousClock.Instant)
            case park
            case end(Result<Void, TransportError>)
        }
        while true {
            let next: Next = state.withLock { state in
                guard let first = state.chunks.first else {
                    return state.end.map(Next.end) ?? .park
                }
                guard first.due <= .now else { return .wait(first.due) }
                let count = min(max(1, maxLength), first.data.count)
                let taken = first.data.prefix(count)
                if count == first.data.count {
                    state.chunks.removeFirst()
                } else {
                    state.chunks[0].data = Data(first.data.dropFirst(count))
                }
                state.buffered -= count
                return .data(Data(taken))
            }
            switch next {
            case .data(let data):
                return data
            case .wait(let instant):
                try await Task.sleep(until: instant, clock: .continuous)
            case .park:
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let ready = state.withLock { state in
                        guard state.chunks.isEmpty, state.end == nil else { return true }
                        state.reader = continuation
                        return false
                    }
                    if ready { continuation.resume() }
                }
            case .end(.success):
                return nil
            case .end(.failure(let error)):
                throw error
            }
        }
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let conditions = control.current.streams
        let (due, stalls, sent, failure) = state.withLock { state in
            let (due, stalls) = Self.due(
                bytes: data.count, conditions: conditions, freeAt: &state.outboundFreeAt,
                last: &state.lastOutboundDue, generator: &state.generator
            )
            return (due, stalls, state.outboundFreeAt, state.writeFailure)
        }
        if let failure { throw failure }
        if stalls > 0 { ledger.update { $0.streamStalls += stalls } }
        outbound.yield(Chunk(data: data, due: due))
        // The writer waits while its bytes cross the link, as it would for a socket's send buffer.
        if sent > .now { try await Task.sleep(until: sent, clock: .continuous) }
    }

    public func close() async {
        outbound.finish()
        for task in tasks.withLock({ $0 }) { task.cancel() }
        await base.close()
        finishInbound(.failure(.closed))
    }
}

/// Any transport provider, with its datagram channels impaired, and its streams too when the
/// conditions say so.
public struct ImpairedTransportProvider: TransportProvider {
    public let base: any TransportProvider
    public let control: ImpairmentControl
    public let ledger: ImpairmentLedger
    private let impairsStreams: Bool
    private let inboundLink = Bottleneck()
    private let outboundLink = Bottleneck()

    /// Fixed conditions. Streams pass through untouched unless `impairment.streams` asks otherwise.
    public init(_ base: any TransportProvider, impairment: NetworkImpairment, ledger: ImpairmentLedger = ImpairmentLedger()) {
        self.base = base
        control = ImpairmentControl(impairment)
        self.ledger = ledger
        impairsStreams = !impairment.streams.isClean
    }

    /// Conditions that may change while the session runs, through `control`. Streams are always
    /// wrapped, so that a later change can reach them.
    public init(_ base: any TransportProvider, control: ImpairmentControl, ledger: ImpairmentLedger = ImpairmentLedger()) {
        self.base = base
        self.control = control
        self.ledger = ledger
        impairsStreams = true
    }

    public var impairment: NetworkImpairment { control.current }
    public var peer: Endpoint { base.peer }
    public var isTunnelled: Bool { base.isTunnelled }
    public var supportsDatagrams: Bool { base.supportsDatagrams }

    public func openStream(port: UInt16) async throws -> any ByteStream {
        let stream = try await base.openStream(port: port)
        return impairsStreams ? ImpairedByteStream(stream, control: control, ledger: ledger) : stream
    }

    public func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel {
        // Each flow gets its own decisions, the same ones every run, but they all share one link.
        let seed = control.current.seed &+ UInt64(options.remotePort) &* 0x0100_0000_01b3
        return ImpairedDatagramChannel(
            try await base.openDatagramChannel(options), control: control, seed: seed, ledger: ledger,
            inboundLink: inboundLink, outboundLink: outboundLink
        )
    }
}
