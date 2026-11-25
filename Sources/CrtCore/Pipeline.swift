import Foundation
import Metal
import CrtAppBridge

/// Optional pre-shader downscale step.
public struct DownscaleSpec: Equatable, Sendable {
    public var width: Int
    /// Lines the chain receives.
    public var height: Int
    public var method: DownscaleMethod
    /// Rows of the picture each line stands for: 2 when the chain gets one
    /// interlaced field (Digital video's One field), whose lines are twice
    /// as tall as they are wide. Anything that sizes the picture uses
    /// `pictureHeight`; anything about lines (the shader, scanlines) uses
    /// `height`.
    public var lineHeight: Int
    public init(width: Int, height: Int, method: DownscaleMethod, lineHeight: Int = 1) {
        self.width = width
        self.height = height
        self.method = method
        self.lineHeight = max(1, lineHeight)
    }
    public var pictureHeight: Int { height * lineHeight }
}

/// Encodes one frame of: optional downscale → librashader chain → output texture.
///
/// Caller owns the input texture (e.g. the loaded image or a video frame),
/// the output render target, and the command buffer. This class just wires the
/// dispatches in the right order. It never owns the chain — caller passes it
/// in so the chain can be swapped (different preset) without re-creating the
/// pipeline.
public final class Pipeline {

    public let context: MetalContext
    private var downscaleCache: (spec: DownscaleSpec, texture: MTLTexture)?
    /// The picture scaled to what the shader can be given (`shaderInput`).
    private var shaderInputCache: MTLTexture?

    public init(context: MetalContext) {
        self.context = context
    }

    /// Encode the pipeline into `commandBuffer`.
    /// Returns the texture that will hold the final pixels after the buffer
    /// completes (which is just `outputTexture`, returned for symmetry).
    @discardableResult
    public func encode(into commandBuffer: MTLCommandBuffer,
                       chain: LRShaderChain,
                       inputTexture: MTLTexture,
                       outputTexture: MTLTexture,
                       downscale: DownscaleSpec?,
                       frameCount: Int) throws -> MTLTexture {
        let chainInput: MTLTexture
        if let spec = downscale {
            let scratch = obtainDownscaleTexture(for: spec, sourceFormat: inputTexture.pixelFormat)
            context.downscaler.encode(into: commandBuffer,
                                      source: inputTexture,
                                      destination: scratch,
                                      method: spec.method)
            chainInput = scratch
        } else {
            chainInput = inputTexture
        }
        let shaderInput = self.shaderInput(for: chainInput, into: commandBuffer)

        let viewport = MTLViewport(
            originX: 0, originY: 0,
            width: Double(outputTexture.width),
            height: Double(outputTexture.height),
            znear: 0, zfar: 1
        )
        try chain.renderInputTexture(shaderInput,
                                     outputTexture: outputTexture,
                                     viewport: viewport,
                                     frameCount: UInt(frameCount),
                                     commandBuffer: commandBuffer)
        return outputTexture
    }

    /// What the shader is given: the chain input, or — when that is too
    /// large to render at two rows a line (the Downscale off on a large
    /// picture) — the chain input integrated down to the largest size that
    /// can be (`PreviewScaler.shaderInput`).
    private func shaderInput(for chainInput: MTLTexture, into commandBuffer: MTLCommandBuffer) -> MTLTexture {
        let size = PreviewScaler.shaderInput(width: chainInput.width, height: chainInput.height)
        guard size.width != chainInput.width || size.height != chainInput.height else { return chainInput }
        if shaderInputCache?.width != size.width || shaderInputCache?.height != size.height
            || shaderInputCache?.pixelFormat != chainInput.pixelFormat {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: chainInput.pixelFormat, width: size.width, height: size.height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            shaderInputCache = context.device.makeTexture(descriptor: d)
        }
        guard let scratch = shaderInputCache else { return chainInput }
        context.downscaler.encode(into: commandBuffer, source: chainInput, destination: scratch, method: .area)
        return scratch
    }

    /// Synchronously produce the chain input for a frame that needs the
    /// CPU stages — Digital video, then ntsc-rs: they run at the source's
    /// full resolution (matching how ntsc-rs is used standalone; its
    /// scale_settings can scale artifacts with video size), then the
    /// degraded signal is downscaled for the shader. The result replaces both
    /// `inputTexture` and `downscale` in a subsequent `encode` call (pass
    /// downscale: nil). With both stages on they share one readback.
    /// - Parameter sourceVersion: identifies `source`'s contents so the
    ///   stages can skip re-reading unchanged pixels (see NtscStage.process).
    public func prepareChainInput(source: MTLTexture,
                                  downscale: DownscaleSpec?,
                                  ntsc: NtscStage?,
                                  digital: (stage: DigitalStage, input: DigitalFrameInput)? = nil,
                                  frameCount: Int,
                                  sourceVersion: Int? = nil) throws -> MTLTexture {
        let processed: MTLTexture
        if let ntsc {
            processed = try ntsc.process(input: source, frameIndex: frameCount,
                                         inputVersion: sourceVersion,
                                         prefilter: digital.map { $0.stage.prefilter($0.input) },
                                         device: context.device, queue: context.queue)
        } else if let digital {
            processed = try digital.stage.process(input: source, frame: digital.input,
                                                  inputVersion: sourceVersion,
                                                  device: context.device, queue: context.queue)
        } else {
            processed = source
        }
        guard let spec = downscale else { return processed }

        guard let cb = context.queue.makeCommandBuffer() else {
            throw NtscStage.Error.commandBuffer
        }
        let scratch = obtainDownscaleTexture(for: spec, sourceFormat: processed.pixelFormat)
        context.downscaler.encode(into: cb, source: processed,
                                  destination: scratch, method: spec.method)
        cb.commit()
        cb.waitUntilCompleted()
        return scratch
    }

    /// A standalone copy of the chain input for `source` — downscaled by
    /// `spec`, or a plain copy when there is no downscale — in a fresh
    /// private texture the caller owns. Playback frames live in pool memory
    /// the producer recycles, so anything kept beyond the current draw (the
    /// frame cache) has to be copied out first.
    public func makeChainInputCopy(source: MTLTexture,
                                   downscale spec: DownscaleSpec?,
                                   commandBuffer cb: MTLCommandBuffer) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: spec?.width ?? source.width,
            height: spec?.height ?? source.height,
            mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let tex = context.device.makeTexture(descriptor: d) else { return nil }
        if let spec {
            context.downscaler.encode(into: cb, source: source,
                                      destination: tex, method: spec.method)
        } else {
            guard let blit = cb.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: source, to: tex)
            blit.endEncoding()
        }
        return tex
    }

    private func obtainDownscaleTexture(for spec: DownscaleSpec,
                                        sourceFormat: MTLPixelFormat) -> MTLTexture {
        if let cached = downscaleCache, cached.spec == spec,
           cached.texture.pixelFormat == sourceFormat {
            return cached.texture
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: sourceFormat,
            width: spec.width, height: spec.height, mipmapped: false
        )
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        let tex = context.device.makeTexture(descriptor: d)!
        downscaleCache = (spec, tex)
        return tex
    }
}
