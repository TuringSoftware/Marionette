// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
@testable import RemoteDesktopRender
import RemoteDesktopSimulated
import Testing

/// A chunk of a constant-amplitude 1 kHz tone.
private func tone(frames: Int = 480, sampleRate: Double = 48_000, channels: Int = 2, amplitude: Float = 0.5, at time: ContinuousClock.Instant = .now) -> AudioChunk {
    var samples = [Float32](repeating: 0, count: frames * channels)
    for frame in 0..<frames {
        let value = amplitude * Float(sin(2 * Double.pi * 1000 * Double(frame) / sampleRate))
        for channel in 0..<channels {
            samples[frame * channels + channel] = value
        }
    }
    return AudioChunk(
        sampleRate: sampleRate,
        channelCount: channels,
        samples: samples.withUnsafeBufferPointer { Data(buffer: $0) },
        presentationTime: time
    )
}

/// The first engine of a process can take several seconds to come up in the iOS simulator.
private let engineStartTimeout: Duration = .seconds(45)

private func peak(_ samples: [Float]) -> Float {
    samples.reduce(0) { max($0, abs($1)) }
}

/// Every test plays into an offline engine: nothing reaches the speakers.
@Suite(.serialized)
struct AudioPlayerTests {
    /// Without a cushion, so that what is queued plays at once; ``PlayoutCushionTests`` and the
    /// tests at the end cover the cushion.
    private func offlinePlayer(cushion: PlayoutCushion = PlayoutCushion(floor: .zero)) -> AudioPlayer {
        AudioPlayer(output: .offline(sampleRate: 48_000, channelCount: 2), cushion: cushion)
    }

    @Test func nothingStartsBeforeTheFirstChunk() async throws {
        // The public initialiser must not touch audio hardware either.
        let idle = AudioPlayer()
        #expect(!idle.isEngineRunning)
        #expect(idle.statistics == AudioPlayer.Statistics())
        idle.stop()
        #expect(!idle.isEngineRunning)

        let player = offlinePlayer()
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        player.start(stream)
        try await Task.sleep(for: .milliseconds(50))
        player.waitUntilIdle()
        #expect(!player.isEngineRunning)
        #expect(player.scheduledChunkCount == 0)
        #expect(player.renderOffline(frameCount: 480) == nil)

        continuation.yield(tone())
        #expect(await eventually(within: engineStartTimeout) { player.scheduledChunkCount == 1 })
        #expect(player.isEngineRunning)
        player.stop()
        #expect(!player.isEngineRunning)
    }

    @Test func chunksComeOutOfTheEngine() throws {
        let player = offlinePlayer()
        for _ in 0..<4 { player.enqueue(tone()) }
        player.waitUntilIdle()
        #expect(player.scheduledChunkCount == 4)
        #expect(player.droppedChunkCount == 0)

        let rendered = try #require(player.renderOffline(frameCount: 1920))
        #expect(rendered.count == 1920)
        #expect(peak(rendered) > 0.3)
        #expect(peak(rendered) < 0.6)

        let after = try #require(player.renderOffline(frameCount: 960))
        #expect(peak(after) < 0.001)
        player.stop()
    }

    @Test func muteSilencesOutputWithoutStoppingTheStream() async throws {
        let player = offlinePlayer()
        // One stream throughout, however long the test takes: chunks stamped as they are made
        // would look like a new stream after a pause, which starts without the cushion's silence.
        var presentation = ContinuousClock.now
        func next() -> AudioChunk {
            defer { presentation += .milliseconds(10) }
            return tone(at: presentation)
        }
        player.isMuted = true
        #expect(player.isMuted)
        for _ in 0..<2 { player.enqueue(next()) }
        player.waitUntilIdle()
        #expect(player.isEngineRunning)
        #expect(player.scheduledChunkCount == 2)
        #expect(peak(try #require(player.renderOffline(frameCount: 960))) < 0.001)
        // The engine says it has played them a moment after rendering them.
        #expect(await eventually { player.hasPlayedEverything })

        player.isMuted = false
        for _ in 0..<2 { player.enqueue(next()) }
        player.waitUntilIdle()
        // The queue had run dry, so the cushion grew: 40 ms of silence come first.
        #expect(peak(try #require(player.renderOffline(frameCount: 1920 + 960))) > 0.3)

        // Muting while running takes effect on audio already queued. Having run dry again, the queue
        // starts with 80 ms of silence, over which the mixer fades out; the tones after it are
        // what is checked.
        #expect(await eventually { player.hasPlayedEverything })
        for _ in 0..<4 { player.enqueue(next()) }
        player.isMuted = true
        player.waitUntilIdle()
        _ = try #require(player.renderOffline(frameCount: 3840))
        #expect(peak(try #require(player.renderOffline(frameCount: 1920))) < 0.001)
        player.stop()
    }

    @Test func dropsChunksWhenPlaybackFallsBehind() async throws {
        let player = offlinePlayer()
        // 600 ms of audio with nobody pulling it out of the engine.
        for _ in 0..<60 { player.enqueue(tone()) }
        player.waitUntilIdle()
        let statistics = player.statistics
        #expect(statistics.scheduledChunks + statistics.droppedChunks == 60)
        // Up to 200 ms beyond the cushion is allowed to queue; then the backlog is skipped.
        #expect(statistics.scheduledChunks == 21)
        #expect(statistics.droppedChunks == 39)

        // Once the queue drains, chunks are accepted again; having run dry, it keeps more in hand.
        _ = try #require(player.renderOffline(frameCount: 48_000 / 2))
        #expect(await eventually { player.hasPlayedEverything })
        player.enqueue(tone())
        player.waitUntilIdle()
        #expect(player.scheduledChunkCount == statistics.scheduledChunks + 1)
        #expect(player.statistics.underruns == 1)
        player.stop()
    }

    @Test func theFirstChunkWaitsBehindTheCushion() throws {
        let player = offlinePlayer(cushion: PlayoutCushion())
        for _ in 0..<4 { player.enqueue(tone()) }
        player.waitUntilIdle()
        #expect(player.scheduledChunkCount == 4)
        // 60 ms of silence, in which later chunks can arrive late without a gap, then the sound.
        #expect(peak(try #require(player.renderOffline(frameCount: 2880))) < 0.001)
        #expect(peak(try #require(player.renderOffline(frameCount: 1920))) > 0.3)
        player.stop()
    }

    @Test func aJumpInPresentationTimeStartsTheQueueAfresh() throws {
        let player = offlinePlayer()
        let start = ContinuousClock.now
        for index in 0..<15 { player.enqueue(tone(amplitude: 0.2, at: start + .milliseconds(10 * index))) }
        // A new stream, two seconds on: the 150 ms still queued of the old one is not played.
        player.enqueue(tone(amplitude: 0.8, at: start + .seconds(2)))
        player.waitUntilIdle()
        let rendered = try #require(player.renderOffline(frameCount: 480))
        #expect(peak(rendered) > 0.6)
        #expect(player.statistics.underruns == 0)
        player.stop()
    }

    @Test func recoversWhenTheQueueNeverDrains() {
        let player = offlinePlayer()
        // Well over a second of consecutive drops: the player flushes and starts again.
        for _ in 0..<200 { player.enqueue(tone()) }
        player.waitUntilIdle()
        #expect(player.scheduledChunkCount > 27)
        #expect(player.isEngineRunning)
        player.stop()
    }

    @Test func followsAFormatChange() throws {
        let player = offlinePlayer()
        player.enqueue(tone())
        player.enqueue(tone(frames: 441, sampleRate: 44_100, channels: 1))
        player.enqueue(tone(frames: 441, sampleRate: 44_100, channels: 1))
        player.waitUntilIdle()
        #expect(player.scheduledChunkCount == 3)
        #expect(player.isEngineRunning)
        #expect(peak(try #require(player.renderOffline(frameCount: 960))) > 0.3)

        // Wider than stereo: the first two channels are played.
        player.enqueue(tone(channels: 6))
        player.waitUntilIdle()
        #expect(player.scheduledChunkCount == 4)
        player.stop()
    }

    @Test func malformedChunksAreIgnored() {
        let player = offlinePlayer()
        player.enqueue(AudioChunk(sampleRate: 48_000, channelCount: 2, samples: Data(), presentationTime: .now))
        player.enqueue(AudioChunk(sampleRate: 0, channelCount: 2, samples: Data(count: 64), presentationTime: .now))
        player.enqueue(AudioChunk(sampleRate: 48_000, channelCount: 0, samples: Data(count: 64), presentationTime: .now))
        // Three bytes short of a whole frame: the partial frame is not read.
        player.enqueue(AudioChunk(sampleRate: 48_000, channelCount: 2, samples: Data(count: 8 * 10 + 5), presentationTime: .now))
        player.waitUntilIdle()
        #expect(player.scheduledChunkCount == 1)
        #expect(player.droppedChunkCount == 0)
        player.stop()
    }

    @Test func stopTearsDownAndIgnoresTheOldStream() async throws {
        let player = offlinePlayer()
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        player.start(stream)
        continuation.yield(tone())
        #expect(await eventually(within: engineStartTimeout) { player.isEngineRunning })

        player.stop()
        #expect(!player.isEngineRunning)
        continuation.yield(tone())
        try await Task.sleep(for: .milliseconds(50))
        player.waitUntilIdle()
        #expect(!player.isEngineRunning)
        #expect(player.scheduledChunkCount == 1)

        let (next, nextContinuation) = AsyncStream<AudioChunk>.makeStream()
        player.start(next)
        player.waitUntilIdle()
        #expect(!player.isEngineRunning)
        nextContinuation.yield(tone())
        #expect(await eventually(within: engineStartTimeout) { player.isEngineRunning })
        player.stop()
    }

    @Test func playsTheSimulatedSessionsTone() async throws {
        var scenario = SimulationScenario.highPerformance
        scenario.phaseDelay = .milliseconds(1)
        scenario.displays = [.init(name: "Built-in Display", pixelSize: PixelSize(width: 320, height: 200), scale: 1)]
        let session = try await SimulatedBackend(scenario: scenario).connectSimulated(
            ConnectionRequest(transport: SimulatedTransport(), prompts: StaticPromptHandler(username: "demo", password: "demo"))
        )
        let audio = try #require(session.capabilities.audio.value)
        let player = offlinePlayer()
        #expect(!player.isEngineRunning)
        player.start(audio.chunks())
        #expect(await eventually(within: engineStartTimeout) { player.scheduledChunkCount >= 5 })
        #expect(player.isEngineRunning)
        // The simulated tone is quiet (amplitude 0.05) but not silent.
        let rendered = try #require(player.renderOffline(frameCount: 480 * 4))
        #expect(peak(rendered) > 0.02)
        player.stop()
        await session.disconnect()
    }
}

@Suite struct PlayoutCushionTests {
    private let start = ContinuousClock.now

    @Test func startsWithItsFloorOfSilence() {
        var cushion = PlayoutCushion()
        #expect(cushion.admit(queued: .zero, at: start) == .play(leadIn: .milliseconds(60)))
        #expect(cushion.admit(queued: .milliseconds(60), at: start) == .play(leadIn: .zero))
    }

    @Test func growsEachTimeTheQueueRunsDryUpToItsMaximum() {
        var cushion = PlayoutCushion()
        _ = cushion.admit(queued: .zero, at: start)
        #expect(cushion.admit(queued: .zero, at: start) == .play(leadIn: .milliseconds(100)))
        for _ in 0..<10 { _ = cushion.admit(queued: .zero, at: start) }
        #expect(cushion.target == .milliseconds(240))
        #expect(cushion.underruns == 11)
        // A flush is no underrun.
        cushion.restart()
        #expect(cushion.admit(queued: .zero, at: start) == .play(leadIn: .milliseconds(240)))
        #expect(cushion.underruns == 11)
    }

    @Test func shrinksAfterAQuietHalfMinute() {
        var cushion = PlayoutCushion()
        _ = cushion.admit(queued: .zero, at: start)
        _ = cushion.admit(queued: .zero, at: start)
        #expect(cushion.target == .milliseconds(100))
        _ = cushion.admit(queued: .milliseconds(100), at: start + .seconds(29))
        #expect(cushion.target == .milliseconds(100))
        _ = cushion.admit(queued: .milliseconds(100), at: start + .seconds(30))
        #expect(cushion.target == .milliseconds(80))
        _ = cushion.admit(queued: .milliseconds(80), at: start + .seconds(60))
        _ = cushion.admit(queued: .milliseconds(80), at: start + .seconds(90))
        #expect(cushion.target == .milliseconds(60))
    }

    @Test func aBacklogIsSkippedBackToTheCushion() {
        var cushion = PlayoutCushion()
        _ = cushion.admit(queued: .zero, at: start)
        // A burst: far more queued than the cushion.
        #expect(cushion.admit(queued: .milliseconds(270), at: start) == .drop)
        // Dropping goes on until the queue is back to the cushion, not just under the limit.
        #expect(cushion.admit(queued: .milliseconds(150), at: start) == .drop)
        #expect(cushion.admit(queued: .milliseconds(60), at: start) == .play(leadIn: .zero))
        #expect(cushion.admit(queued: .milliseconds(90), at: start) == .play(leadIn: .zero))
    }

    @Test func aQueueThatStaysALittleTooLongIsDrainedToo() {
        var cushion = PlayoutCushion()
        _ = cushion.admit(queued: .zero, at: start)
        for step in 0..<20 {
            #expect(cushion.admit(queued: .milliseconds(120), at: start + .milliseconds(100 * step)) == .play(leadIn: .zero))
        }
        #expect(cushion.admit(queued: .milliseconds(120), at: start + .seconds(2)) == .drop)
        #expect(cushion.admit(queued: .milliseconds(50), at: start + .seconds(2)) == .play(leadIn: .zero))
    }
}
