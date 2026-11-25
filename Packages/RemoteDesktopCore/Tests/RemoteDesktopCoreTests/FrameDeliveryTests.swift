// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import RemoteDesktopCore
import Testing

private func makeFrame(size: PixelSize = PixelSize(width: 64, height: 32), damage: PixelRect, generation: UInt64 = 1) -> DisplayFrame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, kCVPixelFormatType_32BGRA, nil, &buffer)
    return DisplayFrame(
        display: DisplayID(1),
        surface: .adopting(buffer!),
        pixelSize: size,
        damage: DamageRegion(damage),
        layoutGeneration: generation
    )
}

@Suite struct FrameMailboxTests {
    @Test func deliversPublishedFrame() async {
        let mailbox = FrameMailbox()
        mailbox.publish(makeFrame(damage: PixelRect(x: 0, y: 0, width: 4, height: 4)))
        let frame = await mailbox.next()
        #expect(frame?.damage.bounds == PixelRect(x: 0, y: 0, width: 4, height: 4))
    }

    @Test func mergesDamageOfSkippedFrames() async {
        let mailbox = FrameMailbox()
        mailbox.publish(makeFrame(damage: PixelRect(x: 0, y: 0, width: 4, height: 4)))
        mailbox.publish(makeFrame(damage: PixelRect(x: 20, y: 10, width: 4, height: 4)))
        let frame = await mailbox.next()
        #expect(frame?.damage.rectangles.count == 2)
        #expect(frame?.damage.bounds == PixelRect(x: 0, y: 0, width: 24, height: 14))
    }

    @Test func layoutChangeForcesFullDamage() async {
        let mailbox = FrameMailbox()
        mailbox.publish(makeFrame(damage: PixelRect(x: 0, y: 0, width: 4, height: 4), generation: 1))
        mailbox.publish(makeFrame(damage: PixelRect(x: 1, y: 1, width: 1, height: 1), generation: 2))
        let frame = await mailbox.next()
        #expect(frame?.layoutGeneration == 2)
        #expect(frame?.damage.bounds == PixelRect(x: 0, y: 0, width: 64, height: 32))
    }

    @Test func waitingConsumerIsWoken() async {
        let mailbox = FrameMailbox()
        let consumer = Task { await mailbox.next() }
        try? await Task.sleep(for: .milliseconds(20))
        mailbox.publish(makeFrame(damage: PixelRect(x: 2, y: 2, width: 2, height: 2)))
        #expect(await consumer.value != nil)
    }

    @Test func finishEndsSequenceAndDropsLaterFrames() async {
        let mailbox = FrameMailbox()
        let consumer = Task { await mailbox.next() }
        try? await Task.sleep(for: .milliseconds(20))
        mailbox.finish()
        #expect(await consumer.value == nil)
        mailbox.publish(makeFrame(damage: PixelRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(await mailbox.next() == nil)
    }

    @Test func cancellationReturnsNil() async {
        let mailbox = FrameMailbox()
        let consumer = Task { await mailbox.next() }
        try? await Task.sleep(for: .milliseconds(20))
        consumer.cancel()
        #expect(await consumer.value == nil)
        // The mailbox stays usable for a later consumer.
        mailbox.publish(makeFrame(damage: PixelRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(await mailbox.next() != nil)
    }
}

@Suite struct FrameHubTests {
    @Test func stampsIncreasingSequence() async {
        let hub = FrameHub()
        let mailbox = hub.subscribe()
        hub.publish(makeFrame(damage: PixelRect(x: 0, y: 0, width: 1, height: 1)))
        let first = await mailbox.next()
        hub.publish(makeFrame(damage: PixelRect(x: 0, y: 0, width: 1, height: 1)))
        let second = await mailbox.next()
        #expect(first?.sequence == 1)
        #expect(second?.sequence == 2)
    }

    @Test func lateSubscriberGetsLatestWithFullDamage() async {
        let hub = FrameHub()
        hub.publish(makeFrame(damage: PixelRect(x: 3, y: 3, width: 2, height: 2)))
        let mailbox = hub.subscribe()
        let frame = await mailbox.next()
        #expect(frame?.damage.bounds == PixelRect(x: 0, y: 0, width: 64, height: 32))
    }

    @Test func everySubscriberReceivesEveryRegion() async {
        let hub = FrameHub()
        let slow = hub.subscribe()
        let fast = hub.subscribe()
        hub.publish(makeFrame(damage: PixelRect(x: 0, y: 0, width: 2, height: 2)))
        _ = await fast.next()
        hub.publish(makeFrame(damage: PixelRect(x: 10, y: 10, width: 2, height: 2)))
        #expect(await fast.next()?.damage.bounds == PixelRect(x: 10, y: 10, width: 2, height: 2))
        #expect(await slow.next()?.damage.bounds == PixelRect(x: 0, y: 0, width: 12, height: 12))
    }

    @Test func droppedSubscriberIsForgotten() async {
        let hub = FrameHub()
        do {
            _ = hub.subscribe()
        }
        // Publishing to a hub whose only subscriber is gone must not crash or retain it.
        hub.publish(makeFrame(damage: PixelRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(hub.latestFrame?.sequence == 1)
    }

    @Test func finishEndsSubscribersAndLateOnes() async {
        let hub = FrameHub()
        let mailbox = hub.subscribe()
        hub.finish()
        #expect(await mailbox.next() == nil)
        let late = hub.subscribe()
        #expect(await late.next() == nil)
    }
}

@Suite struct BroadcasterTests {
    @Test func fansOutInOrder() async {
        let broadcaster = Broadcaster<Int>()
        let first = broadcaster.subscribe()
        let second = broadcaster.subscribe()
        for value in 1...3 { broadcaster.send(value) }
        broadcaster.finish()
        var a: [Int] = []
        for await value in first { a.append(value) }
        var b: [Int] = []
        for await value in second { b.append(value) }
        #expect(a == [1, 2, 3])
        #expect(b == [1, 2, 3])
    }

    @Test func replaysLatestToNewSubscriber() async {
        let broadcaster = Broadcaster<String>(replaysLatest: true)
        broadcaster.send("old")
        broadcaster.send("current")
        var iterator = broadcaster.subscribe().makeAsyncIterator()
        #expect(await iterator.next() == "current")
    }

    @Test func subscriptionAfterFinishIsEnded() async {
        let broadcaster = Broadcaster<Int>()
        broadcaster.finish()
        var count = 0
        for await _ in broadcaster.subscribe() { count += 1 }
        #expect(count == 0)
    }
}
