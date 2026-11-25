// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Synchronization

/// Delivers values to any number of `AsyncStream` subscribers.
///
/// Used for low-frequency session traffic (state, layout, clipboard offers). Frames use ``FrameHub``,
/// which has latest-wins semantics instead of a queue.
public final class Broadcaster<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [UInt64: AsyncStream<Element>.Continuation] = [:]
        var nextToken: UInt64 = 0
        var replay: Element?
        var isFinished = false
    }

    private let state = Mutex(State())
    private let replaysLatest: Bool
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    /// - Parameters:
    ///   - replaysLatest: When true, a new subscriber first receives the most recently sent value.
    ///   - bufferingPolicy: Applied to every subscriber stream.
    public init(
        replaysLatest: Bool = false,
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded
    ) {
        self.replaysLatest = replaysLatest
        self.bufferingPolicy = bufferingPolicy
    }

    public func subscribe() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let (token, replay, finished): (UInt64, Element?, Bool) = state.withLock { state in
                let token = state.nextToken
                state.nextToken += 1
                if !state.isFinished {
                    state.continuations[token] = continuation
                }
                return (token, state.replay, state.isFinished)
            }
            if let replay { continuation.yield(replay) }
            if finished {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.continuations.removeValue(forKey: token) }
            }
        }
    }

    public func send(_ element: Element) {
        let targets: [AsyncStream<Element>.Continuation] = state.withLock { state in
            guard !state.isFinished else { return [] }
            if replaysLatest { state.replay = element }
            return Array(state.continuations.values)
        }
        for target in targets { target.yield(element) }
    }

    public func finish() {
        let targets: [AsyncStream<Element>.Continuation] = state.withLock { state in
            state.isFinished = true
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        for target in targets { target.finish() }
    }
}
