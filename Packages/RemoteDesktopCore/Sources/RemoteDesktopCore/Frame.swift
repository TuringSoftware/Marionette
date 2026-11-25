// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import CoreVideo
import Synchronization

/// One presentable state of a display.
///
/// `surface` always holds the *whole* composited display, never a delta, so a consumer that skips
/// frames still ends up with correct pixels. `damage` says which part differs from the previous frame
/// the same consumer received. Decoding and compositing happen behind the session; consumers never see
/// compressed video.
public struct DisplayFrame: Sendable {
    public var display: DisplayID
    /// Immutable pixels. Back ends publish a new buffer per frame instead of mutating a shared one.
    public var surface: CVReadOnlyPixelBuffer
    public var pixelSize: PixelSize
    public var damage: DamageRegion
    public var layoutGeneration: UInt64
    /// When the frame should be shown, on the continuous clock.
    public var presentationTime: ContinuousClock.Instant
    /// Monotonic per-display counter assigned by the publisher.
    public var sequence: UInt64

    public init(
        display: DisplayID,
        surface: CVReadOnlyPixelBuffer,
        pixelSize: PixelSize,
        damage: DamageRegion,
        layoutGeneration: UInt64,
        presentationTime: ContinuousClock.Instant = .now,
        sequence: UInt64 = 0
    ) {
        self.display = display
        self.surface = surface
        self.pixelSize = pixelSize
        self.damage = damage
        self.layoutGeneration = layoutGeneration
        self.presentationTime = presentationTime
        self.sequence = sequence
    }
}

/// A single-consumer, latest-wins slot for display frames.
///
/// Publishing never blocks and never queues: if the consumer has not collected the previous frame, the
/// new frame replaces it and their damage is merged. That gives natural back-pressure for rendering
/// without ever dropping a region that changed.
public final class FrameMailbox: Sendable, AsyncSequence {
    public typealias Element = DisplayFrame

    private struct State {
        var pending: DisplayFrame?
        var waiter: CheckedContinuation<DisplayFrame?, Never>?
        var isFinished = false
    }

    private let state = Mutex(State())

    public init() {}

    /// Offers a frame to the consumer. Safe to call from any thread.
    public func publish(_ frame: DisplayFrame) {
        let resume: (CheckedContinuation<DisplayFrame?, Never>, DisplayFrame)? = state.withLock { state in
            guard !state.isFinished else { return nil }
            let merged = Self.merge(pending: state.pending, new: frame)
            if let waiter = state.waiter {
                state.waiter = nil
                state.pending = nil
                return (waiter, merged)
            }
            state.pending = merged
            return nil
        }
        resume?.0.resume(returning: resume?.1)
    }

    /// Ends the sequence. A waiting consumer receives `nil`.
    public func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<DisplayFrame?, Never>? in
            state.isFinished = true
            state.pending = nil
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    /// The next frame, or `nil` once the mailbox is finished or the task is cancelled.
    public func next() async -> DisplayFrame? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: DisplayFrame?? = state.withLock { state in
                    if let pending = state.pending {
                        state.pending = nil
                        return .some(pending)
                    }
                    if state.isFinished || Task.isCancelled {
                        return .some(nil)
                    }
                    precondition(state.waiter == nil, "FrameMailbox supports a single consumer")
                    state.waiter = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<DisplayFrame?, Never>? in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: nil)
        }
    }

    private static func merge(pending: DisplayFrame?, new: DisplayFrame) -> DisplayFrame {
        guard let pending else { return new }
        var merged = new
        if pending.layoutGeneration != new.layoutGeneration || pending.pixelSize != new.pixelSize {
            merged.damage = .full(new.pixelSize)
        } else {
            merged.damage = pending.damage.union(new.damage)
        }
        return merged
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let mailbox: FrameMailbox

        public func next() async -> DisplayFrame? {
            await mailbox.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(mailbox: self)
    }
}

/// Fans frames of one display out to any number of consumers, each with its own ``FrameMailbox``.
///
/// A new subscriber immediately receives the most recent frame with full damage, so views that appear
/// mid-session (a second window, an external display, a thumbnail) never start blank. The hub holds
/// subscribers weakly: dropping the mailbox unsubscribes.
public final class FrameHub: Sendable {
    private struct Subscriber {
        weak var mailbox: FrameMailbox?
    }

    private struct State {
        var subscribers: [Subscriber] = []
        var latest: DisplayFrame?
        var sequence: UInt64 = 0
        var isFinished = false
    }

    private let state = Mutex(State())

    public init() {}

    public var latestFrame: DisplayFrame? {
        state.withLock { $0.latest }
    }

    public func subscribe() -> FrameMailbox {
        let mailbox = FrameMailbox()
        let (replay, finished): (DisplayFrame?, Bool) = state.withLock { state in
            if !state.isFinished {
                state.subscribers.removeAll { $0.mailbox == nil }
                state.subscribers.append(Subscriber(mailbox: mailbox))
            }
            var replay = state.latest
            if let size = replay?.pixelSize { replay?.damage = .full(size) }
            return (replay, state.isFinished)
        }
        if let replay { mailbox.publish(replay) }
        if finished { mailbox.finish() }
        return mailbox
    }

    /// Publishes a frame to every subscriber, stamping its sequence number.
    public func publish(_ frame: DisplayFrame) {
        let (stamped, targets): (DisplayFrame, [FrameMailbox]) = state.withLock { state in
            state.sequence += 1
            var stamped = frame
            stamped.sequence = state.sequence
            state.latest = stamped
            let live = state.subscribers.compactMap(\.mailbox)
            if live.count != state.subscribers.count {
                state.subscribers.removeAll { $0.mailbox == nil }
            }
            return (stamped, live)
        }
        for target in targets { target.publish(stamped) }
    }

    /// Ends every subscriber's sequence. Later subscribers receive the last frame, then the end.
    public func finish() {
        let targets: [FrameMailbox] = state.withLock { state in
            state.isFinished = true
            defer { state.subscribers.removeAll() }
            return state.subscribers.compactMap(\.mailbox)
        }
        for target in targets { target.finish() }
    }
}

extension CVReadOnlyPixelBuffer {
    /// Wraps a pixel buffer the caller has finished writing.
    ///
    /// The caller promises that nothing mutates `buffer` after this call. Back ends use it at the one
    /// point where a freshly filled or decoded buffer becomes a published frame.
    public static func adopting(_ buffer: CVPixelBuffer) -> CVReadOnlyPixelBuffer {
        nonisolated(unsafe) let finished = buffer
        return CVReadOnlyPixelBuffer(unsafeBuffer: finished)
    }
}
