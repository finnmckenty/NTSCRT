import Foundation
import Metal
import CrtAppBridge

/// Optional pre-shader downscale step.
public struct DownscaleSpec: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var method: DownscaleMethod
    public init(width: Int, height: Int, method: DownscaleMethod) {
        self.width = width
        self.height = height
        self.method = method
    }

    /// Clamp a downscale width to the range the UI enforces (16...4096).
    /// Look/preset files are user-editable JSON, so a width loaded from disk
    /// can be 0, negative, or absurdly large — any of which makes
    /// `makeTexture` return nil and (before the guard in
    /// `Pipeline.obtainDownscaleTexture`) trapped the render thread. Shared
    /// here so the load path and the spec constructor agree on the bounds.
    public static func clampedWidth(_ width: Int) -> Int {
        min(max(width, 16), 4096)
    }
}

/// Encodes one frame of: optional downscale → librashader chain → output texture.
///
/// Caller owns the input texture (e.g. the loaded image or a video frame),
/// the output render target, and the command buffer. This class just wires the
/// dispatches in the right order. It never owns the chain — caller passes it
/// in so the chain can be swapped (different preset) without re-creating the
/// pipeline.
public final class Pipeline {

    public enum Error: Swift.Error, LocalizedError {
        case downscaleTextureAlloc
        public var errorDescription: String? {
            switch self {
            case .downscaleTextureAlloc:
                return "downscale: staging texture allocation failed (check the downscale width)"
            }
        }
    }

    public let context: MetalContext
    private var downscaleCache: (spec: DownscaleSpec, texture: MTLTexture)?

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
            let scratch = try obtainDownscaleTexture(for: spec, sourceFormat: inputTexture.pixelFormat)
            context.downscaler.encode(into: commandBuffer,
                                      source: inputTexture,
                                      destination: scratch,
                                      method: spec.method)
            chainInput = scratch
        } else {
            chainInput = inputTexture
        }

        let viewport = MTLViewport(
            originX: 0, originY: 0,
            width: Double(outputTexture.width),
            height: Double(outputTexture.height),
            znear: 0, zfar: 1
        )
        try chain.renderInputTexture(chainInput,
                                     outputTexture: outputTexture,
                                     viewport: viewport,
                                     frameCount: UInt(frameCount),
                                     commandBuffer: commandBuffer)
        return outputTexture
    }

    /// Synchronously produce the chain input for a frame that needs the
    /// ntsc-rs stage: the CPU effect runs at the source's full resolution
    /// (matching how ntsc-rs is used standalone; its scale_settings can
    /// scale artifacts with video size), then the degraded signal is
    /// downscaled for the shader. The result replaces both `inputTexture`
    /// and `downscale` in a subsequent `encode` call (pass downscale: nil).
    /// - Parameter sourceVersion: identifies `source`'s contents so the NTSC
    ///   stage can skip re-reading unchanged pixels (see NtscStage.process).
    public func prepareChainInput(source: MTLTexture,
                                  downscale: DownscaleSpec?,
                                  ntsc: NtscStage,
                                  frameCount: Int,
                                  sourceVersion: Int? = nil) throws -> MTLTexture {
        let processed = try ntsc.process(input: source, frameIndex: frameCount,
                                         inputVersion: sourceVersion,
                                         device: context.device, queue: context.queue)
        guard let spec = downscale else { return processed }

        guard let cb = context.queue.makeCommandBuffer() else {
            throw NtscStage.Error.commandBuffer
        }
        let scratch = try obtainDownscaleTexture(for: spec, sourceFormat: processed.pixelFormat)
        context.downscaler.encode(into: cb, source: processed,
                                  destination: scratch, method: spec.method)
        cb.commit()
        cb.waitUntilCompleted()
        return scratch
    }

    private func obtainDownscaleTexture(for spec: DownscaleSpec,
                                        sourceFormat: MTLPixelFormat) throws -> MTLTexture {
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
        // makeTexture returns nil for invalid dimensions (zero/negative, or a
        // size the device can't allocate). The UI and loadLook clamp the width,
        // but don't trap here — throw so a bad spec surfaces as an error rather
        // than crashing the render/export thread.
        guard let tex = context.device.makeTexture(descriptor: d) else {
            throw Error.downscaleTextureAlloc
        }
        downscaleCache = (spec, tex)
        return tex
    }
}
