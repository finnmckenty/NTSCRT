import Foundation
import Metal
import CrtAppBridge

/// What a frame looks like with the CRT shader switched off: the chain input
/// — downscaled, with the NTSC stage already applied upstream — scaled to the
/// output with hard pixel edges, the way the preview shows that state.
///
/// An output that is a whole multiple of the input is a plain nearest-
/// neighbour enlargement. Anything else is enlarged (nearest) to the next
/// whole multiple and box-filtered down, so every source pixel keeps the same
/// size instead of some columns coming out one pixel wider than others —
/// the same render-big-then-integrate rule the shader path uses.
public final class ShaderBypass {

    public enum Error: Swift.Error { case textureAllocation }

    private let context: MetalContext
    private let blitter: PreviewCompositor
    private var scratch: MTLTexture?
    private var enlarged: MTLTexture?
    private static let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    public init(context: MetalContext) {
        self.context = context
        self.blitter = PreviewCompositor(context: context)
    }

    public func encode(into cb: MTLCommandBuffer,
                       inputTexture: MTLTexture,
                       outputTexture: MTLTexture,
                       downscale: DownscaleSpec?) throws {
        var pixels = inputTexture
        if let spec = downscale {
            let s = try texture(&scratch, width: spec.width, height: spec.height,
                                format: inputTexture.pixelFormat,
                                usage: [.shaderRead, .shaderWrite])
            context.downscaler.encode(into: cb, source: inputTexture,
                                      destination: s, method: spec.method)
            pixels = s
        }

        let ow = outputTexture.width, oh = outputTexture.height
        let kx = ow / pixels.width, ky = oh / pixels.height
        let wholeMultiple = kx >= 1 && kx == ky
            && pixels.width * kx == ow && pixels.height * ky == oh
        if wholeMultiple {
            // Nearest, since the blit only goes linear when shrinking.
            blitter.blitScale(source: pixels, into: outputTexture,
                              background: Self.clear, commandBuffer: cb)
        } else if ow > pixels.width && oh > pixels.height {
            let k = max(Int((Double(ow) / Double(pixels.width)).rounded(.up)),
                        Int((Double(oh) / Double(pixels.height)).rounded(.up)))
            let big = try texture(&enlarged, width: pixels.width * k, height: pixels.height * k,
                                  format: outputTexture.pixelFormat,
                                  usage: [.renderTarget, .shaderRead])
            blitter.blitScale(source: pixels, into: big,
                              background: Self.clear, commandBuffer: cb)
            context.downscaler.encode(into: cb, source: big,
                                      destination: outputTexture, method: .area)
        } else {
            // The output is smaller than the input: integrate straight down.
            context.downscaler.encode(into: cb, source: pixels,
                                      destination: outputTexture, method: .area)
        }
    }

    private func texture(_ slot: inout MTLTexture?, width: Int, height: Int,
                         format: MTLPixelFormat, usage: MTLTextureUsage) throws -> MTLTexture {
        if let t = slot, t.width == width, t.height == height, t.pixelFormat == format {
            return t
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        guard let t = context.device.makeTexture(descriptor: d) else {
            throw Error.textureAllocation
        }
        slot = t
        return t
    }
}

/// One frame of an export. Every export route — PNG, video from a clip,
/// video from a still, GIF from either — renders through here, so whether
/// the CRT shader runs is decided in exactly one place: `chain == nil` means
/// the shader is off. The routes used to call the chain directly, and none of
/// them looked at the CRT toggle, so exports always had the shader on.
public enum ExportFrame {
    /// `glitch` is required (nil = stage off) for the same reason
    /// `shaderEnabled` is: a route that could leave it out silently would
    /// export without it.
    public static func encode(into cb: MTLCommandBuffer,
                              pipeline: Pipeline,
                              chain: LRShaderChain?,
                              bypass: ShaderBypass,
                              supersample: SupersampledPass?,
                              glitch: GlitchFrame?,
                              inputTexture: MTLTexture,
                              outputTexture: MTLTexture,
                              downscale: DownscaleSpec?,
                              frameCount: Int) throws {
        var inputTexture = inputTexture
        var downscale = downscale
        // The receiver works on scan lines, so it sees the downscaled raster:
        // after NTSC and downscale, before the CRT shader (or its bypass).
        if let g = glitch {
            let chainInput = try downscale.map {
                try g.renderer.downscaled(inputTexture, spec: $0, commandBuffer: cb)
            } ?? inputTexture
            inputTexture = try g.renderer.encode(into: cb, chainInput: chainInput, time: g.time,
                                                 settings: g.settings, history: g.history)
            downscale = nil
        }
        guard let chain else {
            try bypass.encode(into: cb, inputTexture: inputTexture,
                              outputTexture: outputTexture, downscale: downscale)
            return
        }
        if let supersample {
            try supersample.encode(into: cb, pipeline: pipeline, chain: chain,
                                   inputTexture: inputTexture, outputTexture: outputTexture,
                                   downscale: downscale, frameCount: frameCount)
        } else {
            try pipeline.encode(into: cb, chain: chain,
                                inputTexture: inputTexture, outputTexture: outputTexture,
                                downscale: downscale, frameCount: frameCount)
        }
    }
}


/// The glitch stage's inputs for one export frame.
public struct GlitchFrame {
    public let renderer: GlitchRenderer
    /// Seconds from the start of the export (or the clip).
    public let time: Double
    public let settings: GlitchSettings
    public let history: GlitchHistory?
    public init(renderer: GlitchRenderer, time: Double, settings: GlitchSettings,
                history: GlitchHistory? = nil) {
        self.renderer = renderer
        self.time = time
        self.settings = settings
        self.history = history
    }
}

/// Per-frame values from the keyframe timeline: shader parameters, NTSC
/// settings JSON, glitch settings. Called with (frame index, frame count) on
/// the export thread; nil fields leave that stage's settings as they were.
public typealias FrameOverrides = (shader: [String: Float]?, ntscJSON: String?, glitch: GlitchSettings?)
public typealias FrameParams = @Sendable (Int, Int) -> FrameOverrides
