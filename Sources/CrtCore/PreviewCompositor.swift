import Foundation
import Metal

/// The preview's last stage: fit the chain render to the display size (or
/// sample it directly when zoomed), then draw it letterboxed or filled with
/// the compare split, zoom and pan. Lives here rather than in the view so
/// tests can drive it offscreen (PreviewCompositorTests) — every preview
/// sampling bug so far has lived in exactly this stage.
public final class PreviewCompositor {

    public struct Overlay {
        public var compareEnabled: Bool
        public var compareLineX: Float
        public init(compareEnabled: Bool, compareLineX: Float) {
            self.compareEnabled = compareEnabled
            self.compareLineX = compareLineX
        }
    }

    private let context: MetalContext
    private var library: MTLLibrary?
    private var blitPipeline: MTLRenderPipelineState?
    private var blitLinearPipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var fitTextures: [MTLTexture?] = [nil, nil]
    /// Size of the texture the last composite sampled — the display fit, or
    /// the full render when zoomed. For the scale log.
    public private(set) var lastSampledSize: (width: Int, height: Int) = (0, 0)

    public init(context: MetalContext) {
        self.context = context
    }

    // MARK: - composite

    /// The chain renders at a whole multiple that may exceed what's shown
    /// (the render floor gives the shader room for scanlines). At fit, step
    /// it down to the DISPLAY size with a box filter — an exact integer
    /// factor with integer scale, a fractional one when filling — and draw
    /// that. Zoomed in, sample the FULL render instead: the box filter
    /// averages scanlines nearly flat at small display multiples (a 6×→2×
    /// fit leaves almost none), which read as "the CRT shader stopped
    /// working" under magnification. The geometry always references the
    /// display size, so which texture backs the sample never moves the
    /// framing.
    public func composite(primary primaryIn: MTLTexture,
                          secondary secondaryIn: MTLTexture,
                          into dst: MTLTexture,
                          plan: PreviewScaling,
                          geometry: PreviewGeometry,
                          overlay: Overlay,
                          background: MTLClearColor,
                          commandBuffer cb: MTLCommandBuffer) {
        var primary = primaryIn
        var secondary = secondaryIn
        if plan.needsDownsample && !geometry.samplesFullRender {
            let fw = plan.displayWidth, fh = plan.displayHeight
            if let fitP = fitTexture(slot: 0, width: fw, height: fh, format: primary.pixelFormat) {
                context.downscaler.encode(into: cb, source: primary, destination: fitP, method: .area)
                primary = fitP
            }
            if overlay.compareEnabled, secondaryIn !== primaryIn,
               let fitS = fitTexture(slot: 1, width: fw, height: fh, format: secondaryIn.pixelFormat) {
                context.downscaler.encode(into: cb, source: secondaryIn, destination: fitS, method: .area)
                secondary = fitS
            } else if secondaryIn === primaryIn {
                secondary = primary
            }
        }
        lastSampledSize = (primary.width, primary.height)

        guard let pipe = compositePipelineState(for: dst.pixelFormat) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = background
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipe)
        enc.setFragmentTexture(primary, index: 0)
        enc.setFragmentTexture(secondary, index: 1)
        var u = CompositeU(
            compareLineX: overlay.compareLineX,
            compareEnabled: overlay.compareEnabled ? 1 : 0,
            zoom: geometry.zoom,
            panX: geometry.panX,
            panY: geometry.panY,
            useNearest: geometry.nearest ? 1 : 0,
            dstW: Float(dst.width),
            dstH: Float(dst.height),
            tgtW: Float(geometry.targetWidth),
            tgtH: Float(geometry.targetHeight),
            offX: Float(geometry.offsetX),
            offY: Float(geometry.offsetY))
        enc.setFragmentBytes(&u, length: MemoryLayout<CompositeU>.size, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: - shader-off blit

    /// Scale `source` into `dst` for the shader-off / original view.
    /// Magnifying a small (downscaled) source → nearest, to show its raw
    /// pixels; minifying a full-res original → linear, to avoid single-tap
    /// aliasing.
    public func blitScale(source: MTLTexture, into dst: MTLTexture,
                          background: MTLClearColor, commandBuffer cb: MTLCommandBuffer) {
        let minifying = source.width > dst.width
        guard let pipe = blitPipelineState(for: dst.pixelFormat, linear: minifying) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = background
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipe)
        enc.setFragmentTexture(source, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: - resources

    private func fitTexture(slot: Int, width: Int, height: Int,
                            format: MTLPixelFormat) -> MTLTexture? {
        if let t = fitTextures[slot], t.width == width, t.height == height,
           t.pixelFormat == format {
            return t
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        let t = context.device.makeTexture(descriptor: d)
        fitTextures[slot] = t
        return t
    }

    private func shaderLibrary() -> MTLLibrary? {
        if let l = library { return l }
        library = try? context.device.makeLibrary(source: Self.shaderSource, options: nil)
        return library
    }

    private func blitPipelineState(for fmt: MTLPixelFormat, linear: Bool) -> MTLRenderPipelineState? {
        if linear, let p = blitLinearPipeline { return p }
        if !linear, let p = blitPipeline { return p }
        guard let lib = shaderLibrary() else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "bv_vs")
        d.fragmentFunction = lib.makeFunction(name: linear ? "bv_blit_linear_fs" : "bv_blit_fs")
        d.colorAttachments[0].pixelFormat = fmt
        let p = try? context.device.makeRenderPipelineState(descriptor: d)
        if linear { blitLinearPipeline = p } else { blitPipeline = p }
        return p
    }

    private func compositePipelineState(for fmt: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = compositePipeline { return p }
        guard let lib = shaderLibrary() else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "bv_vs")
        d.fragmentFunction = lib.makeFunction(name: "bv_composite_fs")
        d.colorAttachments[0].pixelFormat = fmt
        compositePipeline = try? context.device.makeRenderPipelineState(descriptor: d)
        return compositePipeline
    }

    private struct CompositeU {
        var compareLineX: Float
        var compareEnabled: Int32
        var zoom: Float
        var panX: Float
        var panY: Float
        var useNearest: Int32
        var dstW: Float
        var dstH: Float
        var tgtW: Float
        var tgtH: Float
        var offX: Float
        var offY: Float
    }

    private static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; float2 uv; };

    vertex VOut bv_vs(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0, 1);
        o.uv  = float2(p.x, 1.0 - p.y);
        return o;
    }

    // Blit for the shader-off/original view. Nearest for magnification
    // (shows raw pixels of a small source instead of smearing them);
    // the linear variant is used when minifying a full-res original.
    fragment float4 bv_blit_fs(VOut in [[stage_in]],
                               texture2d<float> src [[texture(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        return src.sample(s, in.uv);
    }

    fragment float4 bv_blit_linear_fs(VOut in [[stage_in]],
                                      texture2d<float> src [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return src.sample(s, in.uv);
    }

    // Composite with compare line + zoom + pan. The arithmetic here is
    // mirrored by PreviewGeometry.uv(px:py:) — keep them in step.
    struct CompositeU {
        float compareLineX;     // 0..1
        int   compareEnabled;   // 0 or 1
        float zoom;             // >= 1.0
        float panX;
        float panY;
        int   useNearest;       // 1 when zoomed in (pixel inspection)
        // Letterbox in PIXELS, not fractions: the offset must be a whole
        // number of pixels or nearest sampling lands on texel boundaries.
        float dstW;
        float dstH;
        float tgtW;
        float tgtH;
        float offX;
        float offY;
    };

    fragment float4 bv_composite_fs(VOut in [[stage_in]],
                                    texture2d<float> primary [[texture(0)]],
                                    texture2d<float> secondary [[texture(1)]],
                                    constant CompositeU& u [[buffer(0)]])
    {
        constexpr sampler sampL(filter::linear, address::clamp_to_edge);
        constexpr sampler sampN(filter::nearest, address::clamp_to_edge);

        // Map the fragment to a target pixel, then normalize. Doing the
        // letterbox in pixel space with a whole-pixel offset keeps the
        // sample on texel centers for any drawable size.
        float2 px = float2(in.uv.x * u.dstW - u.offX,
                           in.uv.y * u.dstH - u.offY);
        float2 uv = float2(px.x / u.tgtW, px.y / u.tgtH);
        uv = (uv - 0.5) / u.zoom + 0.5 - float2(u.panX, u.panY);

        // The compare line is drawn BEFORE the bounds check so it stays
        // visible over the letterbox bars — otherwise dragging it to
        // either edge culls it and the divider appears to vanish.
        if (u.compareEnabled != 0) {
            float lineWidth = max(fwidth(in.uv.x) * 1.0, 0.0008);
            if (abs(in.uv.x - u.compareLineX) < lineWidth) {
                return float4(1.0, 1.0, 1.0, 1.0);
            }
        }

        // Out-of-bounds → background.
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            return float4(0.05, 0.05, 0.06, 1.0);
        }

        float4 a = u.useNearest != 0 ? primary.sample(sampN, uv)
                                     : primary.sample(sampL, uv);
        float4 b = u.useNearest != 0 ? secondary.sample(sampN, uv)
                                     : secondary.sample(sampL, uv);

        float4 color;
        if (u.compareEnabled != 0) {
            color = (in.uv.x < u.compareLineX) ? a : b;
        } else {
            color = a;
        }
        return color;
    }
    """
}
