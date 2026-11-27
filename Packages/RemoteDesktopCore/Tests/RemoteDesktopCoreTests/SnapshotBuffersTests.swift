// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import RemoteDesktopCore
import Testing

/// A buffer counts as let go once nothing holds it, so each test keeps the ones "in use" in an
/// array. The pools keep unused buffers for good: which buffer comes back must not depend on how
/// long the machine takes.
@Suite struct SnapshotBuffersTests {
    private let region = PixelRect(x: 0, y: 0, width: 64, height: 32)
    private let changes = [
        PixelRect(x: 1, y: 1, width: 2, height: 2), PixelRect(x: 10, y: 3, width: 4, height: 4), PixelRect(x: 40, y: 20, width: 8, height: 8),
    ]

    /// `#require` cannot hold a mutating call.
    private func take(_ buffers: inout SnapshotBuffers, _ region: PixelRect) throws -> SnapshotBuffers.Snapshot {
        let snapshot = buffers.buffer(for: region)
        return try #require(snapshot)
    }

    @Test func aNewBufferNeedsTheWholeRegion() throws {
        var buffers = SnapshotBuffers(maximumBufferAge: nil)
        #expect(try take(&buffers, region).stale == DamageRegion(region))
    }

    @Test func aBufferUsedAgainNeedsOnlyWhatChangedSinceItsLastUse() throws {
        var buffers = SnapshotBuffers(maximumBufferAge: nil)
        var held = [try take(&buffers, region).finish()]
        buffers.noteChange(in: changes[0])
        held.append(try take(&buffers, region).finish())

        held.removeFirst()
        buffers.noteChange(in: changes[1])
        let third = try take(&buffers, region)
        #expect(third.stale == DamageRegion([changes[0], changes[1]]), "the first buffer, two changes behind")
        held.append(third.finish())

        held.removeFirst()
        buffers.noteChange(in: changes[2])
        #expect(try take(&buffers, region).stale == DamageRegion([changes[1], changes[2]]), "the second buffer")
    }

    @Test func aBufferUsedAgainWithNothingChangedNeedsNothing() throws {
        var buffers = SnapshotBuffers(maximumBufferAge: nil)
        var held = [try take(&buffers, region).finish()]
        held.removeAll()
        #expect(try take(&buffers, region).stale.isEmpty)
    }

    /// A buffer that could not be written is dropped as it is, and must not count as up to date.
    @Test func aBufferThatWasNotFilledStillNeedsWhatItMissed() throws {
        var buffers = SnapshotBuffers(maximumBufferAge: nil)
        var held = [try take(&buffers, region).finish()]
        held.removeAll()
        buffers.noteChange(in: changes[0])
        var unfilled = [try take(&buffers, region).buffer]
        unfilled.removeAll()
        buffers.noteChange(in: changes[1])
        #expect(try take(&buffers, region).stale == DamageRegion([changes[0], changes[1]]))
    }

    @Test func onlyChangesInsideTheRegionCount() throws {
        var buffers = SnapshotBuffers(maximumBufferAge: nil)
        var held = [try take(&buffers, region).finish()]
        held.removeAll()
        buffers.noteChange(in: PixelRect(x: 60, y: 30, width: 10, height: 10))
        buffers.noteChange(in: PixelRect(x: 64, y: 0, width: 8, height: 8))
        #expect(try take(&buffers, region).stale == DamageRegion(PixelRect(x: 60, y: 30, width: 4, height: 2)))
    }

    /// Two displays of one size share a pool.
    @Test func aBufferLastUsedForAnotherRegionNeedsAllOfIt() throws {
        var buffers = SnapshotBuffers(maximumBufferAge: nil)
        var held = [try take(&buffers, region).finish()]
        held.removeAll()
        let other = PixelRect(x: 64, y: 0, width: 64, height: 32)
        #expect(try take(&buffers, other).stale == DamageRegion(other))
    }

    @Test func aBufferFilledWithoutSayingForWhichRegionNeedsAllOfIt() throws {
        var buffers = SnapshotBuffers(maximumBufferAge: nil)
        var held = [try take(&buffers, region).finish()]
        held.removeAll()
        let plain = buffers.buffer(width: region.width, height: region.height)
        var plainlyHeld = [try #require(plain)]
        plainlyHeld.removeAll()
        #expect(try take(&buffers, region).stale == DamageRegion(region))
    }

    @Test func aBufferUnusedForLongerThanTheChangesAreKeptNeedsAllOfIt() throws {
        var buffers = SnapshotBuffers(maximumBufferAge: nil)
        var held = [try take(&buffers, region).finish()]
        for _ in 0...SnapshotBuffers.historyLimit {
            buffers.noteChange(in: changes[0])
            held.append(try take(&buffers, region).finish())
            if held.count > 2 { held.remove(at: 1) }
        }
        // With the other two in use, the next buffer is the old one.
        held.append(try take(&buffers, region).finish())
        held.removeFirst()
        #expect(try take(&buffers, region).stale == DamageRegion(region))
    }

    @Test func afterRemoveAllEveryBufferIsNew() throws {
        var buffers = SnapshotBuffers(maximumBufferAge: nil)
        var held = [try take(&buffers, region).finish()]
        held.removeAll()
        buffers.removeAll()
        #expect(try take(&buffers, region).stale == DamageRegion(region))
    }
}
