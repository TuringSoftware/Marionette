// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
@testable import RemoteDesktopTransport
import Synchronization
import Testing

/// A channel whose arrivals the test makes up.
private final class FakeChannel: DatagramChannel, @unchecked Sendable {
    let localPort: UInt16 = 4000
    let sent = Mutex<[Data]>([])
    private let lock = NSLock()
    private var onReceive: (@Sendable (Datagram) -> Void)?
    private var onClose: (@Sendable (TransportError?) -> Void)?

    func start(onReceive: @escaping @Sendable (Datagram) -> Void, onClose: @escaping @Sendable (TransportError?) -> Void) {
        lock.withLock {
            self.onReceive = onReceive
            self.onClose = onClose
        }
    }

    func send(_ payload: Data) {
        sent.withLock { $0.append(payload) }
    }

    func close() {
        let handler = lock.withLock { onClose }
        handler?(nil)
    }

    func arrive(_ number: Int) {
        arriveRaw(withUnsafeBytes(of: UInt32(number)) { Data($0) })
    }

    func arriveRaw(_ payload: Data) {
        let handler = lock.withLock { onReceive }
        handler?(Datagram(payload: payload, receivedAt: .now))
    }
}

private func number(_ datagram: Datagram) -> Int {
    Int(datagram.payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
}

/// Pushes `count` numbered datagrams through an impaired channel and returns what came out.
private func run(_ impairment: NetworkImpairment, count: Int = 10_000) -> (delivered: [Int], counts: ImpairmentCounts) {
    let base = FakeChannel()
    let ledger = ImpairmentLedger()
    let channel = ImpairedDatagramChannel(base, impairment: impairment, ledger: ledger)
    let delivered = Mutex<[Int]>([])
    channel.start(onReceive: { datagram in delivered.withLock { $0.append(number(datagram)) } }, onClose: { _ in })
    for index in 0..<count { base.arrive(index) }
    channel.close()
    return (delivered.withLock { $0 }, ledger.snapshot)
}

@Suite struct ImpairmentTests {
    @Test func aCleanPathChangesNothing() {
        let (delivered, counts) = run(NetworkImpairment(), count: 500)
        #expect(delivered == Array(0..<500))
        #expect(counts == ImpairmentCounts(received: 500, droppedInbound: 0, duplicated: 0, reordered: 0, sent: 0, droppedOutbound: 0))
    }

    @Test(arguments: [0.01, 0.05, 0.25])
    func lossIsCloseToTheRateAskedFor(rate: Double) {
        let (delivered, counts) = run(NetworkImpairment(inboundLoss: rate, seed: 7))
        let lost = 10_000 - delivered.count
        #expect(counts.droppedInbound == lost)
        #expect(abs(Double(lost) / 10_000 - rate) < rate * 0.25 + 0.002)
        #expect(delivered == delivered.sorted())
        #expect(Set(delivered).count == delivered.count)
    }

    @Test func theSameSeedLosesTheSameDatagrams() {
        let impairment = NetworkImpairment(inboundLoss: 0.05, duplication: 0.02, reordering: 0.03, burstLength: 0...3, seed: 42)
        #expect(run(impairment).delivered == run(impairment).delivered)
        var other = impairment
        other.seed = 43
        #expect(run(impairment).delivered != run(other).delivered)
    }

    @Test func burstsTakeNeighboursWithThem() {
        let (delivered, _) = run(NetworkImpairment(inboundLoss: 0.01, burstLength: 4...4, seed: 3))
        // Every gap is a whole burst: the datagram that was lost and the four behind it.
        var gaps: [Int] = []
        for (previous, next) in zip(delivered, delivered.dropFirst()) where next != previous + 1 {
            gaps.append(next - previous - 1)
        }
        #expect(!gaps.isEmpty)
        #expect(gaps.allSatisfy { $0 % 5 == 0 })
    }

    @Test func duplicatesArriveBackToBack() {
        let (delivered, counts) = run(NetworkImpairment(duplication: 0.1, seed: 9), count: 2000)
        #expect(delivered.count == 2000 + counts.duplicated)
        #expect(counts.duplicated > 100)
        #expect(Set(delivered).count == 2000)
        #expect(delivered == delivered.sorted())
    }

    @Test func reorderingSwapsNeighboursAndLosesNothing() {
        let (delivered, counts) = run(NetworkImpairment(reordering: 0.1, seed: 11), count: 2000)
        #expect(delivered.sorted() == Array(0..<2000))
        #expect(delivered != Array(0..<2000))
        #expect(counts.reordered > 100)
        // A held datagram goes out right behind the next one: never more than one place late.
        #expect(delivered.enumerated().allSatisfy { abs($0.offset - $0.element) <= 1 })
    }

    @Test func outboundLossIsCountedAndIndependentOfInbound() {
        let base = FakeChannel()
        let ledger = ImpairmentLedger()
        let channel = ImpairedDatagramChannel(base, impairment: NetworkImpairment(outboundLoss: 0.2, seed: 5), ledger: ledger)
        channel.start(onReceive: { _ in }, onClose: { _ in })
        for index in 0..<1000 { channel.send(Data([UInt8(truncatingIfNeeded: index)])) }
        let counts = ledger.snapshot
        #expect(counts.sent == 1000)
        #expect(base.sent.withLock { $0.count } == 1000 - counts.droppedOutbound)
        #expect((150...250).contains(counts.droppedOutbound))
        #expect(channel.localPort == 4000)
    }

    @Test func nothingIsLostDuringTheQuietPeriod() async throws {
        let base = FakeChannel()
        let ledger = ImpairmentLedger()
        let channel = ImpairedDatagramChannel(base, impairment: NetworkImpairment(inboundLoss: 1, outboundLoss: 1, quietPeriod: .milliseconds(300)), ledger: ledger)
        let delivered = Mutex(0)
        channel.start(onReceive: { _ in delivered.withLock { $0 += 1 } }, onClose: { _ in })
        for index in 0..<50 { base.arrive(index) }
        channel.send(Data([1]))
        #expect(delivered.withLock { $0 } == 50)
        #expect(base.sent.withLock { $0.count } == 1)
        try await Task.sleep(for: .milliseconds(400))
        for index in 50..<100 { base.arrive(index) }
        channel.send(Data([2]))
        #expect(delivered.withLock { $0 } == 50)
        #expect(base.sent.withLock { $0.count } == 1)
        #expect(ledger.snapshot.droppedInbound == 50)
    }

    @Test func theProviderImpairsDatagramsAndLeavesItsDescriptionAlone() async throws {
        struct Fake: TransportProvider {
            let peer = Endpoint(host: "fake.test", port: 5900)
            let isTunnelled = false
            let supportsDatagrams = true
            func openStream(port: UInt16) async throws -> any ByteStream { throw TransportError.closed }
            func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel { FakeChannel() }
        }
        let provider = ImpairedTransportProvider(Fake(), impairment: NetworkImpairment(inboundLoss: 1))
        #expect(provider.peer == Endpoint(host: "fake.test", port: 5900))
        #expect(provider.supportsDatagrams)
        #expect(!provider.isTunnelled)
        let channel = try await provider.openDatagramChannel(DatagramOptions(remotePort: 5901))
        #expect(channel is ImpairedDatagramChannel)
    }
}

/// Pushes `count` datagrams of `size` bytes into an impaired channel at once, and waits for what
/// arrives within `window`, with when each arrived.
private func timed(
    _ impairment: NetworkImpairment, count: Int, size: Int = 1000, window: Duration = .milliseconds(600)
) async throws -> (arrivals: [(number: Int, at: Duration)], counts: ImpairmentCounts) {
    let base = FakeChannel()
    let ledger = ImpairmentLedger()
    let channel = ImpairedDatagramChannel(base, impairment: impairment, ledger: ledger)
    let start = ContinuousClock.now
    let arrivals = Mutex<[(number: Int, at: Duration)]>([])
    channel.start(onReceive: { datagram in arrivals.withLock { $0.append((number(datagram), datagram.receivedAt - start)) } }, onClose: { _ in })
    for index in 0..<count {
        var payload = Data(count: size)
        payload.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(index)) { Data($0) })
        base.arriveRaw(payload)
    }
    try await Task.sleep(for: window)
    return (arrivals.withLock { $0 }, ledger.snapshot)
}

@Suite struct ShapingTests {
    @Test func aRateLimitedLinkQueuesThenDropsTheTail() async throws {
        // 1 Mbit/s with 100 ms of queue: each 1028-byte datagram (with headers) takes 8.2 ms to
        // cross, so about twelve of a 200-datagram burst fit and the rest are dropped on arrival.
        let (arrivals, counts) = try await timed(NetworkImpairment(inboundBandwidth: 1_000_000, queueLimit: .milliseconds(100)), count: 200)
        #expect((11...14).contains(arrivals.count))
        #expect(counts.overflowedInbound == 200 - arrivals.count)
        #expect(arrivals.map(\.number) == Array(0..<arrivals.count))
        let spread = try #require(arrivals.last).at - arrivals[0].at
        #expect(spread > .milliseconds(80) && spread < .milliseconds(200))
    }

    @Test func delayHoldsEveryDatagramAndJitterReordersThem() async throws {
        let (late, _) = try await timed(NetworkImpairment(delay: .milliseconds(80)), count: 50, size: 100)
        #expect(late.count == 50)
        #expect(late.allSatisfy { $0.at >= .milliseconds(80) })
        #expect(late.map(\.number) == Array(0..<50))

        let jittery = NetworkImpairment(seed: 4, delay: .milliseconds(20), jitter: .milliseconds(60))
        let (first, _) = try await timed(jittery, count: 200, size: 100)
        #expect(first.count == 200)
        #expect(first.map(\.number) != Array(0..<200))
        #expect(Set(first.map(\.number)) == Set(0..<200))
        #expect(first.allSatisfy { $0.at >= .milliseconds(20) && $0.at < .milliseconds(200) })
        // Not just neighbours swapped: a datagram can fall many places behind.
        #expect(first.enumerated().contains { abs($0.offset - $0.element.number) >= 5 })
    }

    @Test func conditionsCanChangeMidSession() async throws {
        let base = FakeChannel()
        let control = ImpairmentControl(NetworkImpairment())
        let ledger = ImpairmentLedger()
        let channel = ImpairedDatagramChannel(base, control: control, ledger: ledger)
        let delivered = Mutex(0)
        channel.start(onReceive: { _ in delivered.withLock { $0 += 1 } }, onClose: { _ in })
        for index in 0..<20 { base.arrive(index) }
        #expect(delivered.withLock { $0 } == 20)

        let steps = control.play([
            .init(after: .milliseconds(50), impairment: NetworkImpairment(inboundLoss: 1)),
            .init(after: .milliseconds(150), impairment: NetworkImpairment()),
        ])
        try await Task.sleep(for: .milliseconds(100))
        for index in 20..<40 { base.arrive(index) }
        #expect(delivered.withLock { $0 } == 20)
        await steps.value
        for index in 40..<60 { base.arrive(index) }
        #expect(delivered.withLock { $0 } == 40)
        #expect(ledger.snapshot.droppedInbound == 20)
    }

    @Test func theUplinkHasItsOwnRateAndDelay() async throws {
        let base = FakeChannel()
        let channel = ImpairedDatagramChannel(base, impairment: NetworkImpairment(outboundBandwidth: 800_000, queueLimit: .seconds(1), delay: .milliseconds(30)))
        channel.start(onReceive: { _ in }, onClose: { _ in })
        let start = ContinuousClock.now
        // 20 × 972 bytes (1000 with headers) at 800 kbit/s: 10 ms each.
        for _ in 0..<20 { channel.send(Data(count: 972)) }
        #expect(base.sent.withLock { $0.count } == 0)
        while base.sent.withLock({ $0.count }) < 20, ContinuousClock.now - start < .seconds(2) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let elapsed = ContinuousClock.now - start
        #expect(base.sent.withLock { $0.count } == 20)
        #expect(elapsed > .milliseconds(220) && elapsed < .milliseconds(500))
    }

    @Test func aProviderSharesOneLinkBetweenItsChannels() async throws {
        final class Fake: TransportProvider {
            let channels = Mutex<[FakeChannel]>([])
            let peer = Endpoint(host: "fake.test", port: 5900)
            let isTunnelled = false
            let supportsDatagrams = true
            func openStream(port: UInt16) async throws -> any ByteStream { throw TransportError.closed }
            func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel {
                let channel = FakeChannel()
                channels.withLock { $0.append(channel) }
                return channel
            }
        }
        let fake = Fake()
        let provider = ImpairedTransportProvider(fake, impairment: NetworkImpairment(inboundBandwidth: 1_000_000, queueLimit: .milliseconds(100)))
        let video = try await provider.openDatagramChannel(DatagramOptions(remotePort: 5901))
        let audio = try await provider.openDatagramChannel(DatagramOptions(remotePort: 5902))
        let delivered = Mutex(0)
        video.start(onReceive: { _ in delivered.withLock { $0 += 1 } }, onClose: { _ in })
        audio.start(onReceive: { _ in delivered.withLock { $0 += 1 } }, onClose: { _ in })
        let bases = fake.channels.withLock { $0 }
        for _ in 0..<100 {
            bases[0].arriveRaw(Data(count: 1000))
            bases[1].arriveRaw(Data(count: 1000))
        }
        try await Task.sleep(for: .milliseconds(400))
        // Twelve or so in all, not twelve each.
        #expect((11...14).contains(delivered.withLock { $0 }))
        #expect(provider.ledger.snapshot.overflowedInbound == 200 - delivered.withLock { $0 })
    }
}

/// One end of an in-memory byte pipe; what is written to one end is read from the other.
private final class PipeEnd: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming = Data()
    private var closed = false
    private var waiter: CheckedContinuation<Void, Never>?
    weak var peer: PipeEnd?

    static func pair() -> (PipeEnd, PipeEnd) {
        let a = PipeEnd(), b = PipeEnd()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    fileprivate func deliver(_ data: Data?) {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            if let data { incoming.append(data) } else { closed = true }
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }

    func read(upTo maxLength: Int) async throws -> Data? {
        while true {
            let result: Data?? = lock.withLock {
                if !incoming.isEmpty {
                    let taken = incoming.prefix(maxLength)
                    incoming.removeFirst(taken.count)
                    return .some(Data(taken))
                }
                return closed ? .some(nil) : nil
            }
            if let result { return result }
            await withCheckedContinuation { continuation in
                let ready = lock.withLock {
                    guard incoming.isEmpty, !closed else { return true }
                    waiter = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }

    func write(_ data: Data) async throws {
        peer?.deliver(data)
    }

    func close() async {
        deliver(nil)
        peer?.deliver(nil)
    }
}

private func readAll(_ count: Int, from stream: any ByteStream) async throws -> Data {
    var collected = Data()
    while collected.count < count, let chunk = try await stream.read(upTo: 65_536) { collected.append(chunk) }
    return collected
}

@Suite struct StreamConditioningTests {
    @Test func aStreamIsDelayedAndRateLimitedEachWay() async throws {
        let (near, far) = PipeEnd.pair()
        let control = ImpairmentControl(NetworkImpairment(streams: StreamImpairment(bandwidth: 800_000, delay: .milliseconds(50))))
        let stream = ImpairedByteStream(near, control: control)

        // Inbound: 20 KB at 800 kbit/s is 200 ms, plus 50 ms of delay.
        let payload = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0) })
        let start = ContinuousClock.now
        try await far.write(payload)
        let first = try #require(try await stream.read(upTo: 1))
        #expect(ContinuousClock.now - start >= .milliseconds(50))
        let rest = try await readAll(payload.count - 1, from: stream)
        #expect(first + rest == payload)
        let inbound = ContinuousClock.now - start
        #expect(inbound > .milliseconds(240) && inbound < .milliseconds(500))

        // Outbound: the same, and nothing reaches the far end before the delay.
        let sentAt = ContinuousClock.now
        try await stream.write(payload)
        #expect(ContinuousClock.now - sentAt >= .milliseconds(190))
        #expect(try await readAll(payload.count, from: far) == payload)
        let outbound = ContinuousClock.now - sentAt
        #expect(outbound > .milliseconds(240) && outbound < .milliseconds(500))
        await stream.close()
    }

    @Test func aLostSegmentStallsEverythingBehindItButLosesNothing() async throws {
        let (near, far) = PipeEnd.pair()
        let ledger = ImpairmentLedger()
        let control = ImpairmentControl(NetworkImpairment(seed: 3, streams: StreamImpairment(stallChance: 0.5, stallDuration: .milliseconds(100))))
        let stream = ImpairedByteStream(near, control: control, ledger: ledger)
        let start = ContinuousClock.now
        try await far.write(Data(repeating: 1, count: 1000))
        try await far.write(Data(repeating: 2, count: 1000))
        try await far.write(Data(repeating: 3, count: 1000))
        let received = try await readAll(3000, from: stream)
        #expect(received == Data(repeating: 1, count: 1000) + Data(repeating: 2, count: 1000) + Data(repeating: 3, count: 1000))
        let stalls = ledger.snapshot.streamStalls
        #expect(stalls > 0)
        #expect(ContinuousClock.now - start >= .milliseconds(100))
        await stream.close()
    }

    @Test func theEndOfTheStreamComesThroughAfterItsData() async throws {
        let (near, far) = PipeEnd.pair()
        let stream = ImpairedByteStream(near, control: ImpairmentControl(NetworkImpairment(streams: StreamImpairment(delay: .milliseconds(30)))))
        try await far.write(Data("bye".utf8))
        await far.close()
        #expect(try await readAll(3, from: stream) == Data("bye".utf8))
        #expect(try await stream.read(upTo: 16) == nil)
    }

    @Test func fixedConditionsLeaveStreamsAloneUnlessTheyNameThem() async throws {
        struct Fake: TransportProvider {
            let peer = Endpoint(host: "fake.test", port: 5900)
            let isTunnelled = false
            let supportsDatagrams = true
            func openStream(port: UInt16) async throws -> any ByteStream { PipeEnd.pair().0 }
            func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel { FakeChannel() }
        }
        #expect(try await ImpairedTransportProvider(Fake(), impairment: NetworkImpairment(inboundLoss: 0.5)).openStream(port: 1) is PipeEnd)
        let slow = NetworkImpairment(streams: StreamImpairment(delay: .milliseconds(10)))
        #expect(try await ImpairedTransportProvider(Fake(), impairment: slow).openStream(port: 1) is ImpairedByteStream)
        #expect(try await ImpairedTransportProvider(Fake(), control: ImpairmentControl(NetworkImpairment())).openStream(port: 1) is ImpairedByteStream)
    }
}
