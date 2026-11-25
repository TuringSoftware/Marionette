// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import AVFAudio
import Foundation
public import RemoteDesktopCore
import Synchronization

/// Plays decoded remote audio through `AVAudioEngine`.
///
/// Thread-safe. Nothing audio-related is created until the first chunk arrives: a session that never
/// produces sound never starts an engine, never activates an audio session and never interrupts what
/// the user is already listening to.
///
/// Favours latency over completeness: chunks play in arrival order behind a short adaptive cushion
/// (``PlayoutCushion``), a backlog beyond it is skipped, and a jump in presentation times (a new
/// stream) starts the queue afresh.
public final class AudioPlayer: Sendable {
    public struct Statistics: Sendable, Hashable {
        /// Chunks handed to the audio engine.
        public var scheduledChunks = 0
        /// Chunks discarded because playback had fallen behind, or because the engine could not start.
        public var droppedChunks = 0
        /// Times the queue ran dry while sound was coming.
        public var underruns = 0
    }

    /// The most audio that waits in the player before new chunks are dropped: the largest cushion
    /// and the backlog allowed beyond it.
    public static let maximumQueuedDuration: Duration = PlayoutCushion.maximum + PlayoutCushion.excess

    /// Where the sound goes.
    enum Output: Sendable, Hashable {
        /// The device's audio hardware.
        case device
        /// Nowhere: the engine renders on request, in memory. For tests.
        case offline(sampleRate: Double, channelCount: Int)
    }

    private struct Shared {
        var isMuted = false
        var isEngineRunning = false
        var statistics = Statistics()
        var task: Task<Void, Never>?
        /// Bumped by `stop()`, so chunks still in flight from a stopped stream are recognised and ignored.
        var epoch: UInt64 = 0
    }

    private let shared = Mutex(Shared())
    private let queue = DispatchQueue(label: "llc.turing.Marionette.audio", qos: .userInitiated)
    private let pipeline: Pipeline

    public init() {
        pipeline = Pipeline(output: .device, queue: queue)
    }

    init(output: Output, cushion: PlayoutCushion = PlayoutCushion()) {
        pipeline = Pipeline(output: output, queue: queue, cushion: cushion)
    }

    deinit {
        shared.withLock { $0.task }?.cancel()
        let pipeline = pipeline
        queue.async { pipeline.tearDown() }
    }

    // MARK: Control

    /// Plays a stream of chunks, replacing any earlier stream. The engine starts on the first chunk.
    public func start(_ chunks: AsyncStream<AudioChunk>) {
        stop()
        let epoch = shared.withLock { $0.epoch }
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            for await chunk in chunks {
                guard !Task.isCancelled, let self else { return }
                self.enqueue(chunk, epoch: epoch)
            }
        }
        let replaced = shared.withLock { shared in
            defer { shared.task = task }
            return shared.task
        }
        replaced?.cancel()
    }

    /// Stops playback and tears the engine down. Returns once it is down.
    public func stop() {
        let task = shared.withLock { shared in
            shared.epoch += 1
            defer { shared.task = nil }
            return shared.task
        }
        task?.cancel()
        queue.sync { pipeline.tearDown() }
        shared.withLock { $0.isEngineRunning = false }
    }

    /// Plays one chunk directly, bypassing ``start(_:)``. Returns immediately.
    public func enqueue(_ chunk: AudioChunk) {
        enqueue(chunk, epoch: shared.withLock { $0.epoch })
    }

    /// Silences output locally without stopping the stream.
    public var isMuted: Bool {
        get { shared.withLock { $0.isMuted } }
        set {
            shared.withLock { $0.isMuted = newValue }
            let pipeline = pipeline
            queue.async { pipeline.setMuted(newValue) }
        }
    }

    /// Whether the audio engine exists and is running. False until the first chunk has been scheduled.
    public var isEngineRunning: Bool {
        shared.withLock { $0.isEngineRunning }
    }

    public var statistics: Statistics {
        shared.withLock { $0.statistics }
    }

    public var scheduledChunkCount: Int { statistics.scheduledChunks }
    public var droppedChunkCount: Int { statistics.droppedChunks }

    // MARK: Internals

    private func enqueue(_ chunk: AudioChunk, epoch: UInt64) {
        let pipeline = pipeline
        queue.async { [weak self] in
            guard let self else { return }
            let (isCurrent, muted) = self.shared.withLock { ($0.epoch == epoch, $0.isMuted) }
            guard isCurrent else { return }
            let outcome = pipeline.schedule(chunk, muted: muted)
            self.shared.withLock { shared in
                switch outcome {
                case .scheduled: shared.statistics.scheduledChunks += 1
                case .dropped: shared.statistics.droppedChunks += 1
                case .ignored: break
                }
                shared.statistics.underruns = pipeline.underruns
                shared.isEngineRunning = pipeline.isRunning
            }
        }
    }

    /// Waits until every chunk enqueued so far has been scheduled or dropped. For tests.
    func waitUntilIdle() {
        queue.sync {}
    }

    /// Pulls `frameCount` frames through an offline engine and returns the first channel. For tests.
    func renderOffline(frameCount: Int) -> [Float]? {
        queue.sync { pipeline.renderOffline(frameCount: frameCount) }
    }
}

/// Counts frames the player node has finished with. Written from the audio engine's callback thread,
/// read from the player's queue.
private final class PlaybackCounter: Sendable {
    private let consumed = Atomic<Int>(0)

    var value: Int { consumed.load(ordering: .relaxed) }

    func add(_ frames: Int) {
        consumed.add(frames, ordering: .relaxed)
    }
}

/// How much sound waits in the player ahead of what is heard.
///
/// Sound arrives in 10 ms chunks with network jitter between them. Played the moment each comes,
/// any late chunk is a gap; held too long, the sound lags the picture. The cushion starts at
/// ``initial`` (the queue starts with that much silence ahead of the first chunk), grows by
/// ``growth`` each time the queue runs dry, up to ``maximum``, and shrinks by ``shrink`` after each
/// ``calm`` without running dry. Sound more than ``excess`` beyond the cushion, or more than
/// ``margin`` beyond it for ``settle``, is a backlog (after a burst, say): chunks are skipped until
/// the queue is back to the cushion, so it never stays behind. The constants follow rootshell-vnc's
/// AppleRemoteAudioPlayer (MIT, © 2026 Rootshell LLC, Kit Knox), with a smaller start for less latency.
public struct PlayoutCushion: Sendable, Equatable {
    public static let initial: Duration = .milliseconds(60)
    public static let growth: Duration = .milliseconds(40)
    public static let maximum: Duration = .milliseconds(240)
    public static let shrink: Duration = .milliseconds(20)
    public static let calm: Duration = .seconds(30)
    public static let excess: Duration = .milliseconds(200)
    public static let margin: Duration = .milliseconds(40)
    public static let settle: Duration = .seconds(2)

    public enum Decision: Sendable, Equatable {
        /// Queue it, behind this much silence.
        case play(leadIn: Duration)
        case drop
    }

    /// The smallest cushion, and the first.
    public let floor: Duration
    public private(set) var target: Duration
    public private(set) var underruns = 0
    private var isPlaying = false
    private var calmSince: ContinuousClock.Instant?
    private var overSince: ContinuousClock.Instant?
    private var isDraining = false

    public init(floor: Duration = PlayoutCushion.initial) {
        self.floor = floor
        target = floor
    }

    /// Decides about a chunk arriving `now`, with `queued` still waiting to be heard.
    public mutating func admit(queued: Duration, at now: ContinuousClock.Instant) -> Decision {
        guard isPlaying, queued > .zero else {
            if isPlaying {
                // The queue ran dry: the network is jumpier than the cushion allowed for.
                underruns += 1
                target = min(target + Self.growth, Self.maximum)
            }
            isPlaying = true
            calmSince = now
            overSince = nil
            isDraining = false
            return .play(leadIn: target)
        }
        if let since = calmSince, now - since >= Self.calm {
            target = max(target - Self.shrink, floor)
            calmSince = now
        }
        if queued > target + Self.excess { isDraining = true }
        if queued > target + Self.margin {
            if let since = overSince {
                if now - since >= Self.settle { isDraining = true }
            } else {
                overSince = now
            }
        } else {
            overSince = nil
        }
        if isDraining {
            if queued > target { return .drop }
            isDraining = false
            overSince = nil
        }
        return .play(leadIn: .zero)
    }

    /// Starts over with an empty queue: after a jump in the stream, or a flush. The cushion's size,
    /// which reflects the network, is kept.
    public mutating func restart() {
        isPlaying = false
    }
}

/// `@unchecked Sendable`: `AVAudioEngine` and its nodes are not sendable; every access happens on the
/// owning ``AudioPlayer``'s serial queue.
private final class Pipeline: @unchecked Sendable {
    enum Outcome {
        case scheduled
        case dropped
        case ignored
    }

    /// A presentation time this far from where the previous chunk ended is a new stream, or a
    /// gap long enough that what is queued is stale.
    static let discontinuity: Duration = .milliseconds(250)
    /// Starts that fail this many times in a row rebuild the engine and the audio session.
    static let startFailuresBeforeRebuild = 3

    private let output: AudioPlayer.Output
    private let queue: DispatchQueue
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var counter = PlaybackCounter()
    private var scheduledFrames = 0
    private var consecutiveDroppedFrames = 0
    private var cushion: PlayoutCushion
    private var nextPresentation: ContinuousClock.Instant?
    private var isSessionConfigured = false
    private var retryStartAfter: ContinuousClock.Instant?
    private var startFailures = 0
    /// Set when the system pulled the engine or the media services from under it.
    private var needsRebuild = false
    private var observers: [any NSObjectProtocol] = []

    init(output: AudioPlayer.Output, queue: DispatchQueue, cushion: PlayoutCushion = PlayoutCushion()) {
        self.output = output
        self.queue = queue
        self.cushion = cushion
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var isRunning: Bool { engine?.isRunning ?? false }
    var underruns: Int { cushion.underruns }

    func schedule(_ chunk: AudioChunk, muted: Bool) -> Outcome {
        let frames = chunk.frameCount
        guard frames > 0, chunk.sampleRate > 0, chunk.sampleRate.isFinite, chunk.channelCount > 0 else { return .ignored }
        // Mono and stereo play as they are; anything wider is reduced to its first two channels.
        let playedChannels = min(chunk.channelCount, 2)
        guard let chunkFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: chunk.sampleRate,
            channels: AVAudioChannelCount(playedChannels),
            interleaved: false
        ) else { return .ignored }

        guard prepare(for: chunkFormat, muted: muted), let node else { return .dropped }

        let duration = Duration.seconds(Double(frames) / chunk.sampleRate)
        if let expected = nextPresentation, abs(Self.seconds(chunk.presentationTime - expected)) > Self.seconds(Self.discontinuity) {
            // A new stream, or sound after a long gap: what is queued belongs to the past.
            flush(node)
        }
        nextPresentation = chunk.presentationTime + duration

        let queued = Duration.seconds(Double(max(0, scheduledFrames - counter.value)) / chunk.sampleRate)
        let leadIn: Duration
        switch cushion.admit(queued: queued, at: .now) {
        case .drop:
            consecutiveDroppedFrames += frames
            if Double(consecutiveDroppedFrames) / chunk.sampleRate > 1 {
                // A full second of drops means the queue is not draining at all (the node lost its
                // place after a route change, say). Start it afresh rather than stay silent.
                flush(node)
            }
            return .dropped
        case .play(let silence):
            leadIn = silence
        }
        consecutiveDroppedFrames = 0

        let silentFrames = Int(Self.seconds(leadIn) * chunk.sampleRate)
        if silentFrames > 0, let silence = AVAudioPCMBuffer(pcmFormat: chunkFormat, frameCapacity: AVAudioFrameCount(silentFrames)) {
            silence.frameLength = AVAudioFrameCount(silentFrames)
            if let channels = silence.floatChannelData {
                for channel in 0..<playedChannels { channels[channel].update(repeating: 0, count: silentFrames) }
            }
            enqueue(silence, frames: silentFrames, on: node)
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: chunkFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else { return .dropped }
        buffer.frameLength = AVAudioFrameCount(frames)
        let stride = chunk.channelCount
        chunk.samples.withUnsafeBytes { raw in
            for channel in 0..<playedChannels {
                let destination = channels[channel]
                for frame in 0..<frames {
                    destination[frame] = raw.loadUnaligned(
                        fromByteOffset: (frame * stride + channel) * MemoryLayout<Float32>.size,
                        as: Float32.self
                    )
                }
            }
        }
        enqueue(buffer, frames: frames, on: node)
        return .scheduled
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, frames: Int, on node: AVAudioPlayerNode) {
        let counter = counter
        scheduledFrames += frames
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataConsumed) { _ in
            counter.add(frames)
        }
    }

    func setMuted(_ muted: Bool) {
        engine?.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    func tearDown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        node?.stop()
        engine?.stop()
        if let engine, let node { engine.detach(node) }
        engine = nil
        node = nil
        format = nil
        counter = PlaybackCounter()
        scheduledFrames = 0
        consecutiveDroppedFrames = 0
        cushion.restart()
        nextPresentation = nil
        retryStartAfter = nil
        startFailures = 0
        needsRebuild = false
        // The shared audio session is left active: with `.mixWithOthers` an idle, active session
        // costs nothing and ducks nobody, and another player of this app (a second window's
        // session) may still be using it.
    }

    func renderOffline(frameCount: Int) -> [Float]? {
        guard let engine, engine.isInManualRenderingMode, frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        var result: [Float] = []
        var remaining = frameCount
        while remaining > 0 {
            let step = min(remaining, Int(engine.manualRenderingMaximumFrameCount))
            guard let status = try? engine.renderOffline(AVAudioFrameCount(step), to: buffer),
                  status == .success,
                  let channels = buffer.floatChannelData
            else { return nil }
            result.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            remaining -= step
        }
        return result
    }

    /// The system changed the engine's configuration or reset the media services: everything is
    /// built again on the next chunk.
    func systemReset(sessionToo: Bool) {
        needsRebuild = true
        if sessionToo { isSessionConfigured = false }
    }

    // MARK: Engine

    /// Makes sure a running engine exists whose player node takes `chunkFormat`.
    private func prepare(for chunkFormat: AVAudioFormat, muted: Bool) -> Bool {
        if let retryStartAfter {
            guard ContinuousClock.now >= retryStartAfter else { return false }
            self.retryStartAfter = nil
        }
        if needsRebuild {
            let failures = startFailures
            tearDown()
            startFailures = failures
        }

        if engine == nil {
            guard configureSessionIfNeeded() else { return false }
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: chunkFormat)
            if case .offline(let sampleRate, let channelCount) = output,
               let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount)) {
                do {
                    try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
                } catch {
                    retryStartAfter = .now + .seconds(1)
                    return false
                }
            }
            engine.mainMixerNode.outputVolume = muted ? 0 : 1
            self.engine = engine
            self.node = node
            format = chunkFormat
            observe(engine)
        }
        guard let engine, let node else { return false }

        if format != chunkFormat {
            flush(node)
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: chunkFormat)
            format = chunkFormat
        }

        if !engine.isRunning {
            // First chunk, or the system stopped the engine (route change, interruption).
            do {
                try engine.start()
                startFailures = 0
            } catch {
                // No output device, or the session is interrupted. Try again shortly, not per
                // chunk; after a few failures build everything again, audio session included.
                startFailures += 1
                if startFailures >= Self.startFailuresBeforeRebuild {
                    systemReset(sessionToo: true)
                    startFailures = 0
                }
                retryStartAfter = .now + .seconds(1)
                return false
            }
            flush(node)
        }
        if !node.isPlaying { node.play() }
        return true
    }

    private func flush(_ node: AVAudioPlayerNode) {
        node.stop()
        counter = PlaybackCounter()
        scheduledFrames = 0
        consecutiveDroppedFrames = 0
        cushion.restart()
        if engine?.isRunning == true { node.play() }
    }

    private func observe(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        let queue = queue
        // An engine whose configuration changed (a new route, a new sample rate) has stopped and
        // may no longer fit its connections.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            let pipeline = self
            queue.async { pipeline?.systemReset(sessionToo: false) }
        })
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            let pipeline = self
            queue.async { pipeline?.systemReset(sessionToo: true) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] notification in
            let ended = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .ended
            // The session must be made active again before the engine will start.
            let pipeline = self
            if ended { queue.async { pipeline?.systemReset(sessionToo: true) } }
        })
        #endif
    }

    /// Activates the shared audio session for playback. False while it cannot be, in which case it
    /// is tried again a while later.
    private func configureSessionIfNeeded() -> Bool {
        #if !os(macOS)
        guard output == .device, !isSessionConfigured else { return true }
        let session = AVAudioSession.sharedInstance()
        // Remote sound is the point of the session, so it plays with the silent switch on, but it
        // mixes with whatever else is playing instead of taking over.
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            retryStartAfter = .now + .seconds(1)
            return false
        }
        isSessionConfigured = true
        #endif
        return true
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
