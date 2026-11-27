// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import CoreVideo
import IOSurface

/// Pooled buffers for the pictures a back end publishes, at most ``limit`` of each size.
///
/// A display picture is tens of megabytes (a 6K display is 81 MB) and arrives many times a second;
/// allocating one per picture took an iPhone Duo past its memory limit within a second (5K and 6K
/// displays). With ``limit`` of a size in use, ``buffer(width:height:)`` returns `nil` and the back
/// end publishes that picture later.
///
/// A buffer that comes back from the pool still holds the picture it was last given. A back end
/// that says what changes in its picture (``noteChange(in:)``) is told which part of a buffer is
/// out of date (``buffer(for:)``) and copies only that, rather than the whole display for a change
/// of a few pixels.
///
/// Not thread-safe: keep it where the back end makes its pictures.
public struct SnapshotBuffers {
    /// How many buffers of one size may exist at once: one on screen, one on its way there, one
    /// being filled.
    public static let defaultLimit = 3

    public let limit: Int
    private let maximumBufferAge: Duration?
    private var pools: [PixelSize: CVPixelBufferPool] = [:]
    /// What has changed in the picture since a buffer was last handed out.
    private var pending = DamageRegion()
    /// The changes between one hand-out and the next, oldest first. A buffer's surface is marked
    /// with the number of the last entry it holds.
    private var history: [(number: Int, changes: DamageRegion)] = []
    private var latest = 0

    /// How many entries of changes are kept. A buffer that lay unused for longer is copied whole.
    public static let historyLimit = 16
    /// Under this key a surface carries the region it holds and the number of the last changes in
    /// it: `[x, y, number]`. A pool clears a buffer's attachments when it reuses it, but not its
    /// surface's values. Written once a buffer is filled (``Snapshot/finish()``).
    fileprivate static var contentsKey: CFString { "RemoteDesktopCore.SnapshotBuffers.contents" as CFString }

    /// - Parameter maximumBufferAge: how long a buffer nothing uses is kept. For tests, `nil` keeps
    ///   it for good, so that a stalled machine does not decide which buffer comes back.
    public init(limit: Int = SnapshotBuffers.defaultLimit, maximumBufferAge: Duration? = .seconds(1)) {
        self.limit = limit
        self.maximumBufferAge = maximumBufferAge
    }

    /// A buffer handed out for a region of the picture, for the caller to bring up to date.
    public struct Snapshot {
        public let buffer: CVPixelBuffer
        /// The part of the region the buffer does not hold as it is now, in the picture's
        /// coordinates: all of it for a new buffer, and for a reused one what has changed since
        /// it was last finished for the same region.
        public let stale: DamageRegion
        fileprivate let contents: [Int]

        /// Call once ``stale`` is copied into ``buffer``, which then becomes immutable. A buffer
        /// that could not be filled is dropped without it: its surface then still says what it
        /// held before, and its next use copies everything since.
        public func finish() -> CVReadOnlyPixelBuffer {
            if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
                IOSurfaceSetValue(surface, SnapshotBuffers.contentsKey, contents as CFArray)
            }
            return .adopting(buffer)
        }
    }

    /// A Metal- and CGImage-compatible 32-bit BGRA buffer, or `nil` while ``limit`` of that size are
    /// in use (or memory ran out). The caller fills all of it.
    public mutating func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard let buffer = pooledBuffer(width: width, height: height) else { return nil }
        if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            IOSurfaceRemoveValue(surface, Self.contentsKey)
        }
        return buffer
    }

    /// Says that `rectangle` of the picture has changed. Every change has to be told before the
    /// next ``buffer(for:)``: a buffer handed out without it keeps its old pixels there.
    public mutating func noteChange(in rectangle: PixelRect) {
        pending.add(rectangle)
    }

    /// A buffer of the size of `region` for that region of the picture, with the part of it the
    /// caller has to copy. `nil` as for ``buffer(width:height:)``.
    public mutating func buffer(for region: PixelRect) -> Snapshot? {
        guard let buffer = pooledBuffer(width: region.width, height: region.height) else { return nil }
        if !pending.isEmpty {
            latest += 1
            history.append((latest, pending))
            history.removeFirst(max(0, history.count - Self.historyLimit))
            pending = DamageRegion()
        }
        var stale = DamageRegion(region)
        if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue(),
           let contents = IOSurfaceCopyValue(surface, Self.contentsKey) as? [Int], contents.count == 3,
           contents[0] == region.x, contents[1] == region.y,
           contents[2] == latest || history.first.map({ $0.number <= contents[2] + 1 }) == true {
            stale = history.reduce(into: DamageRegion()) { missed, entry in
                if entry.number > contents[2] { missed.formUnion(entry.changes) }
            }.clipped(to: region)
        }
        return Snapshot(buffer: buffer, stale: stale, contents: [region.x, region.y, latest])
    }

    private mutating func pooledBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0, let pool = pool(for: PixelSize(width: width, height: height)) else { return nil }
        let auxiliary = [kCVPixelBufferPoolAllocationThresholdKey: limit] as CFDictionary
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxiliary, &created) == kCVReturnSuccess else {
            return nil
        }
        return created
    }

    /// Drops every pool and what is known of the picture's changes, e.g. when the picture changes
    /// size for good.
    public mutating func removeAll() {
        pools.removeAll()
        history.removeAll()
        pending = DamageRegion()
    }

    private mutating func pool(for size: PixelSize) -> CVPixelBufferPool? {
        if let pool = pools[size] { return pool }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
        ]
        let poolAttributes = maximumBufferAge.map { [kCVPixelBufferPoolMaximumBufferAgeKey: $0 / .seconds(1)] as CFDictionary }
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            return nil
        }
        pools[size] = pool
        return pool
    }
}
