// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
public import RemoteDesktopCore
import Synchronization

/// Behaviour every back end must have, expressed as runnable checks.
///
/// The same checks run against the simulated back end and, in live tests, against real servers. A
/// front end written against a back end that passes them can rely on the contract documented in
/// `RemoteDesktopCore` instead of on one back end's habits.
public struct BackendConformance: Sendable {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public var check: String
        public var message: String

        public var description: String { "[\(check)] \(message)" }
    }

    public struct Check: Sendable, CustomStringConvertible {
        public var name: String
        var body: @Sendable (BackendConformance) async throws -> Void

        public var description: String { name }
    }

    public var backend: any RemoteDesktopBackend
    /// Produces a fresh request each time; checks connect more than once.
    public var makeRequest: @Sendable () -> ConnectionRequest
    /// Upper bound for any single wait. Generous for real networks.
    public var timeout: Duration

    public init(
        backend: any RemoteDesktopBackend,
        timeout: Duration = .seconds(15),
        makeRequest: @escaping @Sendable () -> ConnectionRequest
    ) {
        self.backend = backend
        self.timeout = timeout
        self.makeRequest = makeRequest
    }

    public func run(_ check: Check) async throws {
        try await check.body(self)
    }

    public static let allChecks: [Check] = [
        Check(name: "connect reports a coherent session") { suite in
            try await suite.withSession("connect reports a coherent session") { session, expect in
                try expect(session.state == .connected, "a new session must be connected, was \(session.state)")
                try expect(session.info.backendID == suite.backend.descriptor.id, "info.backendID must match the descriptor")
                let layout = session.layout
                try expect(!layout.displays.isEmpty, "layout has no displays")
                try expect(layout.generation > 0, "layout generation must be positive")
                try expect(Set(layout.displays.map(\.id)).count == layout.displays.count, "display ids must be unique")
                for display in layout.displays {
                    try expect(!display.pixelSize.isEmpty, "\(display.id) has an empty size")
                    try expect(display.scale >= 1, "\(display.id) has scale below 1")
                }
                for (index, first) in layout.displays.enumerated() {
                    for second in layout.displays.dropFirst(index + 1) {
                        try expect(!first.frameInDesktop.intersects(second.frameInDesktop), "\(first.id) and \(second.id) overlap")
                    }
                }
            }
        },
        Check(name: "first frame is complete") { suite in
            try await suite.withSession("first frame is complete") { session, expect in
                let layout = session.layout
                for display in layout.displays where display.state == .live {
                    let mailbox = session.frames(for: display.id)
                    guard let frame = try await suite.withTimeout("first frame of \(display.id)", { await mailbox.next() }) else {
                        throw Failure(check: "first frame is complete", message: "frame stream of \(display.id) ended before a frame")
                    }
                    try expect(frame.display == display.id, "frame carries the wrong display id")
                    try expect(frame.pixelSize == display.pixelSize, "frame size \(frame.pixelSize) differs from display \(display.pixelSize)")
                    try expect(frame.damage.bounds == PixelRect(size: frame.pixelSize), "first frame must carry full damage, had \(frame.damage.bounds)")
                    let surfaceSize = frame.surface.withUnsafeBuffer {
                        PixelSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0))
                    }
                    try expect(surfaceSize == frame.pixelSize, "surface is \(surfaceSize), frame says \(frame.pixelSize)")
                }
            }
        },
        Check(name: "late subscriber starts with the current frame") { suite in
            try await suite.withSession("late subscriber starts with the current frame") { session, expect in
                guard let display = session.layout.displays.first(where: { $0.state == .live }) else { return }
                let first = session.frames(for: display.id)
                _ = try await suite.withTimeout("first subscriber") { await first.next() }
                let second = session.frames(for: display.id)
                let replay = try await suite.withTimeout("second subscriber") { await second.next() }
                try expect(replay != nil, "second subscriber got no frame")
                try expect(replay?.damage.bounds == replay.map { PixelRect(size: $0.pixelSize) }, "replayed frame must carry full damage")
            }
        },
        Check(name: "unknown display ends immediately") { suite in
            try await suite.withSession("unknown display ends immediately") { session, expect in
                let mailbox = session.frames(for: DisplayID(.max))
                let frame = try await suite.withTimeout("unknown display") { await mailbox.next() }
                try expect(frame == nil, "frames(for:) of an unknown display must be an ended sequence")
            }
        },
        Check(name: "cursor stream starts with a state") { suite in
            try await suite.withSession("cursor stream starts with a state") { session, expect in
                let stream = session.cursor()
                let first = try await suite.withTimeout("first cursor state") {
                    var iterator = stream.makeAsyncIterator()
                    return await iterator.next()
                }
                try expect(first != nil, "cursor() must yield the current state first")
            }
        },
        Check(name: "capabilities explain themselves") { suite in
            try await suite.withSession("capabilities explain themselves") { session, expect in
                let capabilities = session.capabilities
                if let displays = capabilities.displayConfiguration.value {
                    let limits = displays.limits
                    try expect(limits.maximumVirtualDisplays >= 0, "negative virtual display limit")
                    if limits.maximumVirtualDisplays > 0 {
                        try expect(!limits.minimumPointSize.isEmpty, "virtual displays need a minimum size")
                        try expect(!limits.maximumPixelSize.isEmpty, "virtual displays need a maximum size")
                    }
                }
                if let quality = capabilities.quality.value {
                    try expect(!quality.supportedPresets.isEmpty, "quality control without presets")
                }
                if let control = capabilities.control.value {
                    try expect(!control.supportedModes.isEmpty, "session control without modes")
                }
                if session.info.isTunnelled, session.info.mode == .highPerformance {
                    throw Failure(check: "capabilities explain themselves", message: "High Performance cannot be tunnelled")
                }
            }
        },
        Check(name: "suspend and resume round-trip") { suite in
            try await suite.withSession("suspend and resume round-trip") { session, expect in
                await session.suspend()
                try expect(session.state == .suspended || session.state.isDisconnected, "suspend must leave the session suspended")
                await session.resume()
                let state = session.state
                let acceptable: Bool = switch state {
                case .connected: true
                case .disconnected(.connectionLost): true
                default: false
                }
                try expect(acceptable, "after resume the session must be connected or report a lost connection, was \(state)")
            }
        },
        Check(name: "disconnect is terminal and announced") { suite in
            let name = "disconnect is terminal and announced"
            let session = try await suite.connect(name)
            let events = session.events()
            let display = session.layout.displays.first?.id
            let frames = display.map { session.frames(for: $0) }
            let collector = Task { () -> [SessionState] in
                var states: [SessionState] = []
                for await event in events {
                    if case .stateChanged(let state) = event { states.append(state) }
                }
                return states
            }
            await session.disconnect()
            await session.disconnect()
            let states = try await suite.withTimeout("event stream to end") { await collector.value }
            func expect(_ condition: Bool, _ message: String) throws {
                if !condition { throw Failure(check: name, message: message) }
            }
            try expect(session.state == .disconnected(.userInitiated), "state must be disconnected(.userInitiated), was \(session.state)")
            try expect(states.last == .disconnected(.userInitiated), "last announced state must be the disconnect, saw \(states)")
            try expect(states.filter(\.isDisconnected).count == 1, "disconnect must be announced exactly once")
            if let frames {
                let ended = try await suite.withTimeout("frame stream to end") {
                    while await frames.next() != nil {}
                    return true
                }
                try expect(ended, "frame stream must end")
            }
            // Must be harmless after the end.
            session.input.send(.releaseAll)
            session.input.send(.text("ignored"))
            let late = session.events()
            let lateEnded = try await suite.withTimeout("late event subscription to end") {
                for await _ in late {}
                return true
            }
            try expect(lateEnded, "events() after disconnect must be an ended stream")
        },
        Check(name: "cancelled connect leaves nothing behind") { suite in
            let name = "cancelled connect leaves nothing behind"
            let request = suite.makeRequest()
            let backend = suite.backend
            let attempt = Task { () -> Result<any RemoteSession, ConnectionFailure> in
                do throws(ConnectionFailure) {
                    return .success(try await backend.connect(request))
                } catch {
                    return .failure(error)
                }
            }
            attempt.cancel()
            let result = try await suite.withTimeout("cancelled connect to return") { await attempt.value }
            switch result {
            case .failure(.cancelled):
                break
            case .failure(let failure):
                throw Failure(check: name, message: "cancelled connect must throw .cancelled, threw \(failure)")
            case .success(let session):
                // Losing the race is allowed only if the caller still gets a usable session to close.
                await session.disconnect()
            }
        },
    ]

    // MARK: Helpers

    typealias Expect = @Sendable (Bool, String) throws -> Void

    func connect(_ check: String) async throws -> any RemoteSession {
        do {
            return try await withTimeout("connect") { try await backend.connect(makeRequest()) }
        } catch let failure as ConnectionFailure {
            throw Failure(check: check, message: "connect failed: \(failure)")
        }
    }

    func withSession(
        _ check: String,
        _ body: @Sendable (any RemoteSession, Expect) async throws -> Void
    ) async throws {
        let session = try await connect(check)
        do {
            try await body(session) { condition, message in
                if !condition { throw Failure(check: check, message: message) }
            }
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
    }

    /// Runs `operation`, failing if it takes longer than ``timeout``.
    ///
    /// The operation is not assumed to be cancellable: on timeout it is abandoned rather than awaited,
    /// so a back end that hangs produces a failure instead of a hung test run.
    func withTimeout<T: Sendable>(_ what: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let timeout = timeout
        let race = Race<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.arm(continuation)
            let work = Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if race.finish(.failure(Failure(check: "timeout", message: "timed out after \(timeout) waiting for \(what)"))) {
                    work.cancel()
                }
            }
        }
    }
}

/// Resumes a continuation with whichever result arrives first.
private final class Race<T: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<T, any Error>?>(nil)

    func arm(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    /// Returns true if this call decided the race.
    @discardableResult
    func finish(_ result: Result<T, any Error>) -> Bool {
        let winner = continuation.withLock { slot -> CheckedContinuation<T, any Error>? in
            defer { slot = nil }
            return slot
        }
        winner?.resume(with: result)
        return winner != nil
    }
}
