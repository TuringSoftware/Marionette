// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import CoreVideo

/// Pooled buffers for the pictures a back end publishes, at most ``limit`` of each size.
///
/// A display picture is tens of megabytes (a 6K display is 81 MB) and arrives many times a second;
/// allocating one per picture took an iPhone Duo past its memory limit within a second (5K and 6K
/// displays). With ``limit`` of a size in use, ``buffer(width:height:)`` returns `nil` and the back
/// end publishes that picture later.
///
/// Not thread-safe: keep it where the back end makes its pictures.
public struct SnapshotBuffers {
    /// How many buffers of one size may exist at once: one on screen, one on its way there, one
    /// being filled.
    public static let defaultLimit = 3

    public let limit: Int
    private var pools: [PixelSize: CVPixelBufferPool] = [:]

    public init(limit: Int = SnapshotBuffers.defaultLimit) {
        self.limit = limit
    }

    /// A Metal- and CGImage-compatible 32-bit BGRA buffer, or `nil` while ``limit`` of that size are
    /// in use (or memory ran out).
    public mutating func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0, let pool = pool(for: PixelSize(width: width, height: height)) else { return nil }
        let auxiliary = [kCVPixelBufferPoolAllocationThresholdKey: limit] as CFDictionary
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxiliary, &created) == kCVReturnSuccess else {
            return nil
        }
        return created
    }

    /// Drops every pool, e.g. when the picture changes size for good.
    public mutating func removeAll() {
        pools.removeAll()
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
        let poolAttributes = [kCVPixelBufferPoolMaximumBufferAgeKey: 1.0] as CFDictionary
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            return nil
        }
        pools[size] = pool
        return pool
    }
}
