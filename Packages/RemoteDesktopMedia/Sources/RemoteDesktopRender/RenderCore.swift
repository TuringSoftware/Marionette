// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import QuartzCore
import RemoteDesktopCore

/// The Metal half of ``DisplayRenderer``. Not thread-safe: every call happens on the renderer's
/// serial queue.
final class RenderCore {
    private struct Pipelines {
        var frame: any MTLRenderPipelineState
        var cursor: any MTLRenderPipelineState
        var nearest: any MTLSamplerState
        var linear: any MTLSamplerState
    }

    private struct FrameTexture {
        var texture: any MTLTexture
        /// The Core Video wrapper that owns a zero-copy texture; `nil` for an uploaded one.
        var backing: WrappedSurface?
        var pixelSize: PixelSize
        /// The pixels are PQ-encoded (HDR); otherwise sRGB-encoded.
        var isPQ: Bool
    }

    /// A zero-copy texture's Core Video wrapper, together with the cache that made it.
    ///
    /// The wrapper must live until the GPU has finished sampling it, so its last reference is often
    /// dropped on Metal's completion queue, possibly after the renderer has gone. Releasing a
    /// wrapper whose cache is already freed crashes (in `CVMetalTextureCache::bufferBackingNotInUse`);
    /// holding the cache here, and releasing the wrapper first, rules that out.
    /// `@unchecked Sendable` because both are only ever retained and released, never used.
    private final class WrappedSurface: @unchecked Sendable {
        private var backing: CVMetalTexture?
        private let cache: CVMetalTextureCache

        init(_ backing: CVMetalTexture, cache: CVMetalTextureCache) {
            self.backing = backing
            self.cache = cache
        }

        deinit {
            // The wrapper goes while the cache is certainly still there.
            backing = nil
        }
    }

    /// What SDR frames are drawn into, and what offscreen renders read back.
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    /// What HDR frames are drawn into: PQ-encoded, passed through as they come.
    static let hdrPixelFormat = MTLPixelFormat.bgr10a2Unorm
    /// Where a Mac puts SDR white in its PQ pictures: its desktop's white measured at 100 nits
    /// (macOS 27 and macOS 15). The pointer and the background are drawn at that level too.
    static let referenceWhiteNits = 100.0

    let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private var pipelines: [MTLPixelFormat: Pipelines] = [:]
    private var pipelinesFailed = false
    private var textureCache: CVMetalTextureCache?
    private var textureCacheFailed = false
    private var frameTexture: FrameTexture?
    private var preparedSerial: UInt64?
    private var uploadTexture: (any MTLTexture)?
    private var cursorTextures: [UInt64: any MTLTexture] = [:]
    private(set) var texturePath: DisplayRenderer.TexturePath?

    init?(device: any MTLDevice) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        commandQueue.label = "Marionette display"
    }

    // MARK: Targets

    /// Draws into the layer's next drawable and presents it.
    func render(_ inputs: RenderInputs, to layer: CAMetalLayer) {
        guard let size = inputs.geometry.drawablePixelSize else { return }
        let drawableSize = CGSize(width: size.width, height: size.height)
        if layer.drawableSize != drawableSize {
            layer.drawableSize = drawableSize
        }
        // `nextDrawable` waits (up to a second) when every drawable is in flight; that is the
        // back-pressure that keeps this queue from running ahead of the display. The layer's pixel
        // format changes on the main actor when frames turn HDR or back, so the drawable's own
        // format decides the pipeline.
        guard let drawable = layer.nextDrawable(),
              let pipelines = loadPipelines(for: drawable.texture.pixelFormat),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
        encode(inputs, into: drawable.texture, pixelSize: size, commandBuffer: commandBuffer, pipelines: pipelines)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Draws the same composition into a texture and reads it back.
    func renderOffscreen(_ inputs: RenderInputs, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth <= 16_384, pixelHeight <= 16_384,
              let pipelines = loadPipelines(for: Self.pixelFormat)
        else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        var needsSynchronisation = false
        #if os(macOS)
        if device.hasUnifiedMemory {
            descriptor.storageMode = .shared
        } else {
            descriptor.storageMode = .managed
            needsSynchronisation = true
        }
        #else
        descriptor.storageMode = .shared
        #endif
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return nil }
        encode(inputs, into: target, pixelSize: (pixelWidth, pixelHeight), commandBuffer: commandBuffer, pipelines: pipelines)
        #if os(macOS)
        if needsSynchronisation, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        #endif
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let bytesPerRow = pixelWidth * 4
        var data = Data(count: bytesPerRow * pixelHeight)
        data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            target.getBytes(
                base,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
                mipmapLevel: 0
            )
        }
        return Imaging.image(bgra: data, width: pixelWidth, height: pixelHeight, bytesPerRow: bytesPerRow)
    }

    // MARK: Drawing

    private func encode(
        _ inputs: RenderInputs,
        into target: any MTLTexture,
        pixelSize: (width: Int, height: Int),
        commandBuffer: any MTLCommandBuffer,
        pipelines: Pipelines
    ) {
        let targetIsPQ = target.pixelFormat == Self.hdrPixelFormat
        let background = targetIsPQ ? Self.pqEncoded(srgb: inputs.background) : inputs.background
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: background.x,
            green: background.y,
            blue: background.z,
            alpha: 1
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }

        let geometry = inputs.geometry
        guard geometry.isDrawable, geometry.hasContent, let frame = prepareFrameTexture(for: inputs) else { return }
        if let backing = frame.backing {
            commandBuffer.addCompletedHandler { _ in withExtendedLifetime(backing) {} }
        }

        let devicePixelsPerRemotePixel =
            geometry.contentFrame.width / geometry.viewSize.width * Double(pixelSize.width) / Double(frame.pixelSize.width)
        let isWholeMultiple = devicePixelsPerRemotePixel >= 0.999
            && abs(devicePixelsPerRemotePixel - devicePixelsPerRemotePixel.rounded()) < 0.002
        var uniforms = QuadUniforms(rect: Self.normalised(geometry.contentFrame, in: geometry.viewSize))
        uniforms.options.x = devicePixelsPerRemotePixel < 0.999 ? 1 : 0
        uniforms.setEncodings(imageIsPQ: frame.isPQ, targetIsPQ: targetIsPQ)
        encoder.setRenderPipelineState(pipelines.frame)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentTexture(frame.texture, index: 0)
        // Whole multiples (1:1, 2x, 3x) stay pixel-exact; everything else is smoothed.
        encoder.setFragmentSamplerState(isWholeMultiple ? pipelines.nearest : pipelines.linear, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        guard let pointer = CursorLayout.pointerPosition(for: inputs),
              let image = inputs.cursor.image ?? Imaging.stockArrow,
              let rect = CursorLayout.frame(pointer: pointer, image: image, geometry: geometry, displayPixelSize: frame.pixelSize),
              let texture = cursorTexture(for: image)
        else { return }
        var cursorUniforms = QuadUniforms(rect: Self.normalised(rect, in: geometry.viewSize))
        cursorUniforms.setEncodings(imageIsPQ: false, targetIsPQ: targetIsPQ)
        encoder.setRenderPipelineState(pipelines.cursor)
        encoder.setVertexBytes(&cursorUniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&cursorUniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(pipelines.linear, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// An sRGB colour as PQ code values, with SDR white at ``referenceWhiteNits``.
    static func pqEncoded(srgb colour: SIMD3<Double>) -> SIMD3<Double> {
        func linear(_ value: Double) -> Double {
            let value = min(max(value, 0), 1)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func pq(_ value: Double) -> Double {
            let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
            let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
            let power = pow(value, m1)
            return pow((c1 + c2 * power) / (1 + c3 * power), m2)
        }
        let scale = referenceWhiteNits / 10_000
        return SIMD3(pq(linear(colour.x) * scale), pq(linear(colour.y) * scale), pq(linear(colour.z) * scale))
    }

    /// Layer points (top-left origin) to normalised device coordinates: left, top, right, bottom.
    private static func normalised(_ rect: CGRect, in view: CGSize) -> SIMD4<Float> {
        SIMD4(
            Float(rect.minX / view.width * 2 - 1),
            Float(1 - rect.minY / view.height * 2),
            Float(rect.maxX / view.width * 2 - 1),
            Float(1 - rect.maxY / view.height * 2)
        )
    }

    // MARK: Textures

    /// The texture for the current frame. A frame that cannot be turned into a texture leaves the
    /// previous one in place, so the display never goes blank because of one bad surface.
    private func prepareFrameTexture(for inputs: RenderInputs) -> FrameTexture? {
        guard let frame = inputs.frame else { return nil }
        if preparedSerial == inputs.frameSerial { return frameTexture }
        preparedSerial = inputs.frameSerial
        if let wrapped = wrap(frame) {
            frameTexture = wrapped
            uploadTexture = nil
            texturePath = .zeroCopy
        } else if let uploaded = upload(frame) {
            frameTexture = uploaded
            texturePath = .upload
        }
        if let textureCache {
            // Lets Core Video recycle wrappers of surfaces that are no longer referenced.
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        return frameTexture
    }

    private func loadTextureCache() -> CVMetalTextureCache? {
        if let textureCache { return textureCache }
        if textureCacheFailed { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            textureCacheFailed = true
            return nil
        }
        textureCache = cache
        return cache
    }

    /// The texture format a surface's pixels read as: 8-bit BGRA, or 10-bit RGB packed in 32 bits.
    private static func textureFormat(of buffer: CVPixelBuffer) -> MTLPixelFormat? {
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_32BGRA: .bgra8Unorm
        case kCVPixelFormatType_ARGB2101010LEPacked: .bgr10a2Unorm
        default: nil
        }
    }

    /// Zero-copy: the IOSurface behind the pixel buffer becomes the texture's storage.
    private func wrap(_ frame: DisplayFrame) -> FrameTexture? {
        guard let cache = loadTextureCache() else { return nil }
        var result: FrameTexture?
        frame.surface.withUnsafeBuffer { buffer in
            guard let format = Self.textureFormat(of: buffer),
                  CVPixelBufferGetIOSurface(buffer) != nil
            else { return }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            var backing: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                buffer,
                nil,
                format,
                width,
                height,
                0,
                &backing
            )
            guard status == kCVReturnSuccess, let backing, let texture = CVMetalTextureGetTexture(backing) else { return }
            result = FrameTexture(
                texture: texture,
                backing: WrappedSurface(backing, cache: cache),
                pixelSize: Self.mappingSize(frame, width: width, height: height),
                isPQ: Imaging.isPQ(buffer)
            )
        }
        return result
    }

    /// Fallback: copy the pixels into a texture of our own.
    private func upload(_ frame: DisplayFrame) -> FrameTexture? {
        var result: FrameTexture?
        frame.surface.withUnsafeBuffer { buffer in
            guard let format = Self.textureFormat(of: buffer),
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
            else { return }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return }

            var texture = uploadTexture
            if texture?.width != width || texture?.height != height || texture?.pixelFormat != format {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                descriptor.usage = [.shaderRead]
                texture = device.makeTexture(descriptor: descriptor)
                uploadTexture = texture
            }
            guard let texture else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)
            )
            result = FrameTexture(texture: texture, backing: nil, pixelSize: Self.mappingSize(frame, width: width, height: height), isPQ: Imaging.isPQ(buffer))
        }
        return result
    }

    /// The size pointer coordinates are measured against: what the frame declares, or the surface's
    /// real size if a back end left the declaration empty.
    private static func mappingSize(_ frame: DisplayFrame, width: Int, height: Int) -> PixelSize {
        frame.pixelSize.isEmpty ? PixelSize(width: width, height: height) : frame.pixelSize
    }

    private func cursorTexture(for image: CursorImage) -> (any MTLTexture)? {
        if let cached = cursorTextures[image.id] { return cached }
        let width = image.pixelSize.width
        let height = image.pixelSize.height
        guard width > 0, height > 0, width <= 1024, height <= 1024, image.bgraPixels.count >= width * height * 4 else {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        image.bgraPixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: width * 4
            )
        }
        // A session uses a handful of shapes; a runaway server must not grow this without bound.
        if cursorTextures.count >= 32 { cursorTextures.removeAll() }
        cursorTextures[image.id] = texture
        return texture
    }

    // MARK: Pipelines

    /// The pipelines that draw into targets of `format`, one of ``pixelFormat`` and ``hdrPixelFormat``.
    private func loadPipelines(for format: MTLPixelFormat) -> Pipelines? {
        if let made = pipelines[format] { return made }
        if pipelinesFailed || (format != Self.pixelFormat && format != Self.hdrPixelFormat) { return nil }
        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            guard let vertex = library.makeFunction(name: Shaders.vertexFunction),
                  let frameFragment = library.makeFunction(name: Shaders.frameFragmentFunction),
                  let cursorFragment = library.makeFunction(name: Shaders.cursorFragmentFunction)
            else {
                pipelinesFailed = true
                return nil
            }

            let frameDescriptor = MTLRenderPipelineDescriptor()
            frameDescriptor.label = "Marionette frame"
            frameDescriptor.vertexFunction = vertex
            frameDescriptor.fragmentFunction = frameFragment
            frameDescriptor.colorAttachments[0].pixelFormat = format

            let cursorDescriptor = MTLRenderPipelineDescriptor()
            cursorDescriptor.label = "Marionette cursor"
            cursorDescriptor.vertexFunction = vertex
            cursorDescriptor.fragmentFunction = cursorFragment
            let attachment = cursorDescriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

            let nearestDescriptor = MTLSamplerDescriptor()
            nearestDescriptor.minFilter = .nearest
            nearestDescriptor.magFilter = .nearest
            nearestDescriptor.sAddressMode = .clampToEdge
            nearestDescriptor.tAddressMode = .clampToEdge
            let linearDescriptor = MTLSamplerDescriptor()
            linearDescriptor.minFilter = .linear
            linearDescriptor.magFilter = .linear
            linearDescriptor.sAddressMode = .clampToEdge
            linearDescriptor.tAddressMode = .clampToEdge

            guard let nearest = device.makeSamplerState(descriptor: nearestDescriptor),
                  let linear = device.makeSamplerState(descriptor: linearDescriptor)
            else {
                pipelinesFailed = true
                return nil
            }
            let made = Pipelines(
                frame: try device.makeRenderPipelineState(descriptor: frameDescriptor),
                cursor: try device.makeRenderPipelineState(descriptor: cursorDescriptor),
                nearest: nearest,
                linear: linear
            )
            pipelines[format] = made
            return made
        } catch {
            pipelinesFailed = true
            assertionFailure("Marionette shaders failed to build: \(error)")
            return nil
        }
    }
}
