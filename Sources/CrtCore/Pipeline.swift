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
