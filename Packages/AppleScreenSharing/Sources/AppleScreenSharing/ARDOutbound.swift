// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDCrypto
import Foundation
import RemoteDesktopCore
import Synchronization

/// The single ordered path for everything the viewer sends.
///
/// `send` never blocks and may be called from any thread. Sealing and queueing happen in one
/// critical section, so records reach the wire in the order they were sealed — the only order in
/// which the Mac can open them.
final class ARDOutbound: Sendable {
    private struct RoomWaiter {
        var id: UInt64
        var limit: Int
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var sealer: RecordSealer?
        var continuation: AsyncStream<Data>.Continuation?
        var failure: ARDError?
        /// Bytes handed to ``send(_:)`` and not yet written.
        var queuedBytes = 0
        /// When the transport last took a chunk, or when the queue was last empty: the clock a room
        /// waiter's patience runs on.
        var lastProgress = ContinuousClock.now
        var roomWaiters: [RoomWaiter] = []
        var nextWaiterID: UInt64 = 0
    }

    /// Shared with the writer task, which outlives no one but starts before `self` is complete.
    private final class Box: Sendable {
        let state: Mutex<State>
        init(_ state: sending State) { self.state = Mutex(state) }
    }

    private let box: Box
    private let writer: Task<Void, Never>
    /// How long a room waiter waits while nothing at all is written before giving up: a peer that
    /// advertises a zero window would otherwise hold it for ever.
    private let stallTimeout: Duration

    init(stream: any ByteStream, stallTimeout: Duration = .seconds(30), onFailure: @escaping @Sendable (ARDError) -> Void) {
        self.stallTimeout = stallTimeout
        let (queue, continuation) = AsyncStream.makeStream(of: Data.self)
        let box = Box(State(continuation: continuation))
        self.box = box
        writer = Task {
            for await chunk in queue {
                do {
                    try await stream.write(chunk)
                } catch {
                    let failure = ARDError(error)
                    // Nothing queued will be written now: say so to everyone waiting and later.
                    box.state.withLock { state in
                        state.failure = state.failure ?? failure
                        state.continuation?.finish()
                        state.continuation = nil
                    }
                    onFailure(failure)
                    Self.releaseWaiters(box)
                    return
                }
                let ready = box.state.withLock { state in
                    state.queuedBytes -= chunk.count
                    state.lastProgress = .now
                    let queued = state.queuedBytes
                    let ready = state.roomWaiters.filter { queued < $0.limit }.map(\.continuation)
                    state.roomWaiters.removeAll { queued < $0.limit }
                    return ready
                }
                for waiter in ready { waiter.resume() }
            }
            Self.releaseWaiters(box)
        }
    }

    /// Ends every room wait: each then finds the connection failed or finished, and throws.
    private static func releaseWaiters(_ box: Box) {
        let (waiters, failure) = box.state.withLock { state in
            defer { state.roomWaiters.removeAll() }
            return (state.roomWaiters.map(\.continuation), state.failure ?? .closedByPeer)
        }
        for waiter in waiters { waiter.resume(throwing: failure) }
    }

    /// Takes a waiter out, if it is waiting, and ends its wait with `error`. False if it is not
    /// waiting (yet, or any more).
    @discardableResult
    private func fail(waiter id: UInt64, with error: ARDError) -> Bool {
        let waiter = box.state.withLock { state -> RoomWaiter? in
            guard let index = state.roomWaiters.firstIndex(where: { $0.id == id }) else { return nil }
            return state.roomWaiters.remove(at: index)
        }
        waiter?.continuation.resume(throwing: error)
        return waiter != nil
    }

    /// Bytes handed to ``send(_:)`` and not yet written.
    var queuedBytes: Int { box.state.withLock { $0.queuedBytes } }

    /// Waits until fewer than `limit` bytes are queued, so a bulk sender (a file transfer) keeps the
    /// queue short: input queued behind it then waits milliseconds, not the length of the file.
    ///
    /// Throws the connection's failure (or ``ARDError/closedByPeer`` once it has finished),
    /// ``ARDError/cancelled`` when the task is cancelled, and `.transport(.timedOut)` after the stall
    /// timeout passes with the transport taking nothing.
    func waitForRoom(below limit: Int) async throws(ARDError) {
        let id = box.state.withLock { state in
            state.nextWaiterID += 1
            return state.nextWaiterID
        }
        let watchdog = Task {
            while true {
                let idle = box.state.withLock { ContinuousClock.now - $0.lastProgress }
                // The waiter may not have queued itself yet; this task ends with the wait.
                if idle >= stallTimeout, fail(waiter: id, with: .transport(.timedOut)) { return }
                try await Task.sleep(for: max(stallTimeout - idle, .milliseconds(100)))
            }
        }
        defer { watchdog.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let outcome = box.state.withLock { state -> Result<Void, ARDError>? in
                        if let failure = state.failure { return .failure(failure) }
                        guard state.continuation != nil else { return .failure(.closedByPeer) }
                        if Task.isCancelled { return .failure(.cancelled) }
                        if state.queuedBytes < limit { return .success(()) }
                        state.roomWaiters.append(RoomWaiter(id: id, limit: limit, continuation: continuation))
                        return nil
                    }
                    if let outcome { continuation.resume(with: outcome) }
                }
            } onCancel: {
                fail(waiter: id, with: .cancelled)
            }
        } catch {
            throw ARDError(error)
        }
    }

    /// Queues one complete message.
    func send(_ message: Data) {
        box.state.withLock { state in
            guard state.failure == nil, let continuation = state.continuation else { return }
            // Waiting starts now if nothing was queued: an idle connection has made no progress to wait on.
            if state.queuedBytes == 0 { state.lastProgress = .now }
            if let sealer = state.sealer {
                do {
                    let sealed = try sealer.seal(message)
                    state.queuedBytes += sealed.count
                    continuation.yield(sealed)
                } catch {
                    state.failure = ARDError(error)
                }
            } else {
                state.queuedBytes += message.count
                continuation.yield(message)
            }
        }
    }

    /// From now on every message is sealed in records under `keys`.
    func startSealing(with keys: RecordKeys) throws(ARDError) {
        do {
            try box.state.withLock { state in
                state.sealer = try RecordSealer(keys: keys)
            }
        } catch {
            throw ARDError(error)
        }
    }

    /// Stops accepting messages. Already queued ones are still written; nobody waits for room any more.
    func finish() {
        box.state.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
        }
        Self.releaseWaiters(box)
    }

    /// Waits until everything queued before ``finish()`` has been handed to the transport.
    func drained() async {
        await writer.value
    }

    func cancel() {
        finish()
        writer.cancel()
    }
}
