import SwiftUI
import AppKit
import Metal
import MetalKit
import CrtCore

/// SwiftUI wrapper for an MTKView that re-renders the pipeline whenever
/// `state.chainTick` changes and re-composites on `state.viewTick`. Adds:
///   - capped offscreen render (perf)
///   - shader on/off
///   - compare-line split (drag the line in the preview)
///   - zoom up to 1200% with hold-space-to-pan
struct PreviewView: NSViewRepresentable {
    @Environment(AppState.self) private var state

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeNSView(context: Context) -> PreviewMTKView {
        let view = PreviewMTKView(frame: .zero, device: state.context.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.appState = state
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ nsView: PreviewMTKView, context: Context) {
        _ = state.chainTick
        _ = state.viewTick
        // Animation runs the MTKView's display link; otherwise draw on demand.
        // Property ORDER matters when resuming: the display link only
        // reliably restarts if enableSetNeedsDisplay is already false when
        // isPaused flips to false (toggling Animate off→on froze otherwise).
        let animating = state.animatePreview && !state.exportInProgress
        if animating {
            // The ntsc-rs stage is CPU work at the source's full resolution,
            // and it runs on this thread — measured at ~10 ms a frame on a
            // 1024² source, which at 60 fps leaves almost nothing for the UI
            // and makes the sidebar feel stuck. NTSC is a 30 fps format, so
            // capping there costs nothing visually and halves the load.
            nsView.preferredFramesPerSecond = state.ntscEnabled ? 30 : 60
            if nsView.enableSetNeedsDisplay || nsView.isPaused {
                nsView.enableSetNeedsDisplay = false
                nsView.isPaused = false
            }
        } else {
            if !nsView.isPaused || !nsView.enableSetNeedsDisplay {
                nsView.isPaused = true
                nsView.enableSetNeedsDisplay = true
            }
            context.coordinator.requestRedraw()
        }
    }

    final class Coordinator: NSObject, MTKViewDelegate {

        /// Safety cap on the offscreen render target's long edge (the target
        /// normally matches the drawable size).
        private static let maxTargetLongEdge = 4096
        /// Fewest output rows per source line the chain may render at with
        /// integer scale on. 6 is where the glow shaders stop clipping (see
        /// renderTargetSize); anything the window can't show 1:1 is
        /// area-downsampled for display instead.
        private static let minScanlineMultiple = 6
        /// CRT_SCALE_LOG=1: report drawable/target sizes and letterbox parity.
        private static let scaleLog = ProcessInfo.processInfo.environment["CRT_SCALE_LOG"] == "1"
        private static var lastScaleLogKey = ""

        private weak var view: MTKView?
        private let state: AppState
        private let backgroundColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)

        // Two cached offscreen render targets:
        //   primary   = current shaderEnabled state
        //   secondary = the OTHER state (only populated when compare is on)
        private var primaryTarget: MTLTexture?
        private var secondaryTarget: MTLTexture?
        private var lastTargetWidth: Int = 0
        private var lastTargetHeight: Int = 0

        /// chainTick value the targets currently hold. nil = targets invalid
        /// (never rendered, reallocated, or last render threw) — forces a
        /// chain render on the next draw. View-only redraws (zoom, pan,
        /// compare line) find this equal to the current tick and skip
        /// straight to the composite pass.
        private var lastRenderedChainTick: Int? = nil

        private static let perfLog = ProcessInfo.processInfo.environment["CRT_PERF_LOG"] != nil
        private static var frameCount = 0
        private static var frameMsTotal = 0.0
        private static var frameMsMax = 0.0
        private static var windowStart: UInt64 = 0

        init(state: AppState) {
            self.state = state
        }

        func attach(view: MTKView) {
            self.view = view
            view.clearColor = backgroundColor
        }

        func requestRedraw() {
            view?.setNeedsDisplay(view?.bounds ?? .zero)
        }

        // MARK: MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay(view.bounds)
        }

        func draw(in view: MTKView) {
            // Everything here runs on the main thread (librashader's Metal
            // runtime isn't thread-safe), including the wait for a free
            // drawable — so this interval is exactly how long the UI is
            // blocked per frame.
            let drawStart = Self.perfLog ? DispatchTime.now().uptimeNanoseconds : 0
            defer {
                if Self.perfLog {
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - drawStart) / 1_000_000
                    Self.frameCount += 1
                    Self.frameMsTotal += ms
                    Self.frameMsMax = max(Self.frameMsMax, ms)
                    if Self.windowStart == 0 { Self.windowStart = drawStart }
                    if Self.frameCount >= 60 {
                        let span = Double(DispatchTime.now().uptimeNanoseconds - Self.windowStart) / 1_000_000
                        let fps = Double(Self.frameCount) / (span / 1000)
                        let duty = 100 * Self.frameMsTotal / span
                        fputs(String(format: "[perf] %.0f fps, mean %.1f ms/draw, max %.1f ms — main thread %.0f%% busy\n",
                                     fps, Self.frameMsTotal / Double(Self.frameCount), Self.frameMsMax, duty),
                              stderr)
                        Self.frameCount = 0; Self.frameMsTotal = 0; Self.frameMsMax = 0
                        Self.windowStart = 0
                    }
                }
            }
            guard let drawable = view.currentDrawable,
                  let cb = state.context.queue.makeCommandBuffer() else { return }

            let animating = state.animatePreview && !state.exportInProgress
            if animating { state.tickFrame() }

            guard let source = state.sourceTexture else {
                lastRenderedChainTick = nil
                clearAndPresent(drawable: drawable, cb: cb); return
            }

            // (Re)allocate render targets if size changed. Fresh textures hold
            // garbage, so the chain must re-render into them.
            let inputW = state.downscaleSpec?.width ?? source.width
            let inputH = state.downscaleSpec?.height ?? source.height
            let (tw, th) = renderTargetSize(inputW: inputW, inputH: inputH)
            if tw != lastTargetWidth || th != lastTargetHeight {
                primaryTarget = makeTarget(width: tw, height: th)
                secondaryTarget = makeTarget(width: tw, height: th)
                lastTargetWidth = tw
                lastTargetHeight = th
                lastRenderedChainTick = nil
            }
            guard let primary = primaryTarget else {
                lastRenderedChainTick = nil
                clearAndPresent(drawable: drawable, cb: cb); return
            }

            // Run the filter chain only when shaded pixels changed (or every
            // frame while animating). View-only redraws — zoom, pan, compare
            // line — reuse the cached targets and just re-composite.
            let tick = state.chainTick
            if animating || lastRenderedChainTick != tick {
                if Self.perfLog { fputs("[perf] chain render (tick \(tick))\n", stderr) }

                var allRendered = true

                // ntsc-rs stage: synchronously produce the degraded chain
                // input (downscale + CPU effect); both compare sides then
                // consume it with no further downscaling.
                var chainSource = source
                var spec = state.downscaleSpec
                if state.ntscEnabled, let stage = state.ntscStage {
                    do {
                        chainSource = try state.pipeline.prepareChainInput(
                            source: source, downscale: spec,
                            ntsc: stage, frameCount: state.frameCounter,
                            sourceVersion: state.sourceVersion)
                        spec = nil
                    } catch {
                        // Fall back to the clean path this frame.
                    }
                }

                // Render the primary target (matches current shaderEnabled state).
                do {
                    try renderState(state.shaderEnabled, source: chainSource,
                                    downscale: spec, into: primary, cb: cb)
                } catch {
                    lastRenderedChainTick = nil
                    clearAndPresent(drawable: drawable, cb: cb); return
                }

                // Render secondary only when compare is on. The compare side
                // is the ORIGINAL image — no downscale, no NTSC, no shader —
                // so the split reads as "full pipeline vs untouched source".
                if state.compareEnabled, let secondary = secondaryTarget {
                    do {
                        try renderState(false, source: source,
                                        downscale: nil, into: secondary, cb: cb)
                    } catch {
                        // Non-fatal: skip compare for this frame, retry next draw.
                        allRendered = false
                    }
                }

                lastRenderedChainTick = allRendered ? tick : nil
            } else if Self.perfLog {
                fputs("[perf] composite only (tick \(tick))\n", stderr)
            }

            // Final composite into the drawable (compare line + zoom + pan).
            composite(primaryIn: primary,
                      secondaryIn: state.compareEnabled ? (secondaryTarget ?? primary) : primary,
                      into: drawable.texture, cb: cb)

            cb.present(drawable)
            cb.commit()
        }

        // MARK: - target sizing

        /// Sizing decided by PreviewScaler (pure, unit-tested in
        /// PreviewScalingTests) — kept here so composite() can letterbox the
        /// displayed size rather than stretching the render to fill.
        private var scaling: PreviewScaling?

        private func renderTargetSize(inputW: Int, inputH: Int) -> (Int, Int) {
            let size = view?.drawableSize ?? .zero
            let plan = PreviewScaler.plan(
                inputWidth: inputW, inputHeight: inputH,
                drawableWidth: Int(size.width), drawableHeight: Int(size.height),
                integerScale: state.integerScale,
                maxLongEdge: Self.maxTargetLongEdge)
            scaling = plan
            if Self.scaleLog {
                let key = "\(Int(size.width))x\(Int(size.height))/\(plan.renderWidth)/\(plan.displayWidth)"
                if key != Self.lastScaleLogKey {
                    Self.lastScaleLogKey = key
                    fputs("[scale] drawable \(Int(size.width))x\(Int(size.height)) render \(plan.renderWidth)x\(plan.renderHeight) (x\(plan.renderMultiple)) display \(plan.displayWidth)x\(plan.displayHeight) (x\(plan.displayMultiple))\n", stderr)
                }
            }
            return (plan.renderWidth, plan.renderHeight)
        }

        /// Area-downsampler + display-sized textures, allocated only when the
        /// chain renders larger than the window can show.
        private var downscaler: Downscaler?
        private var fitTextures: [MTLTexture?] = [nil, nil]

        private func obtainDownscaler() -> Downscaler? {
            if let d = downscaler { return d }
            downscaler = try? Downscaler(device: state.context.device)
            return downscaler
        }

        private func obtainFitTexture(slot: Int, width: Int, height: Int,
                                      format: MTLPixelFormat) -> MTLTexture? {
            if let t = fitTextures[slot], t.width == width, t.height == height,
               t.pixelFormat == format {
                return t
            }
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]
            d.storageMode = .private
            let t = state.context.device.makeTexture(descriptor: d)
            fitTextures[slot] = t
            return t
        }

        private func makeTarget(width: Int, height: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width, height: height, mipmapped: false
            )
            d.usage = [.renderTarget, .shaderRead, .shaderWrite]
            d.storageMode = .private
            return state.context.device.makeTexture(descriptor: d)!
        }

        // MARK: - render with/without shader into a target

        private func renderState(_ shaderOn: Bool,
                                 source: MTLTexture,
                                 downscale: DownscaleSpec?,
                                 into target: MTLTexture,
                                 cb: MTLCommandBuffer) throws {
            if shaderOn, let chain = state.chain {
                try state.pipeline.encode(into: cb,
                                          chain: chain,
                                          inputTexture: source,
                                          outputTexture: target,
                                          downscale: downscale,
                                          frameCount: state.frameCounter)
                return
            }

            // Shader off: optionally downscale, then upscale into target.
            let intermediate: MTLTexture
            if let spec = downscale {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: source.pixelFormat,
                    width: spec.width, height: spec.height, mipmapped: false
                )
                desc.usage = [.shaderRead, .shaderWrite]
                desc.storageMode = .private
                guard let scratch = state.context.device.makeTexture(descriptor: desc) else {
                    throw NSError(domain: "Preview", code: 1)
                }
                state.context.downscaler.encode(into: cb,
                                                source: source,
                                                destination: scratch,
                                                method: spec.method)
                intermediate = scratch
            } else {
                intermediate = source
            }
            blitScale(source: intermediate, into: target, cb: cb)
        }

        // MARK: - blit shaders (compile lazily)

        private static let shaderSrc: String = """
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

        // Composite with compare line + zoom + pan.
        struct CompositeU {
            float compareLineX;     // 0..1
            int   compareEnabled;   // 0 or 1
            float zoom;             // >= 1.0
            float panX;
            float panY;
            int   useNearest;       // 1 when zoomed in (pixel inspection)
            // Letterbox in PIXELS, not fractions: the offset must be a whole
            // number of pixels or nearest sampling lands on texel boundaries
            // (see the Swift side).
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

            // Map the fragment to a target pixel, then normalise. Doing the
            // letterbox in pixel space with a whole-pixel offset keeps the
            // sample on texel centres for any drawable size.
            float2 px = float2(in.uv.x * u.dstW - u.offX,
                               in.uv.y * u.dstH - u.offY);
            float2 uv = float2(px.x / u.tgtW, px.y / u.tgtH);
            uv = (uv - 0.5) / u.zoom + 0.5 - float2(u.panX, u.panY);

            // The compare line is drawn BEFORE the bounds check so it stays
            // visible over the letterbox bars — otherwise dragging it to
            // either edge (integer scale letterboxes by default) culls it
            // and the divider appears to vanish.
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

            float4 colour;
            if (u.compareEnabled != 0) {
                colour = (in.uv.x < u.compareLineX) ? a : b;
            } else {
                colour = a;
            }
            return colour;
        }
        """

        private var blitPipeline: MTLRenderPipelineState?        // bv_blit_fs (nearest)
        private var blitLinearPipeline: MTLRenderPipelineState?  // bv_blit_linear_fs
        private var compositePipeline: MTLRenderPipelineState?   // bv_composite_fs
        private var msl: MTLLibrary?

        private func library() -> MTLLibrary? {
            if let l = msl { return l }
            msl = try? state.context.device.makeLibrary(source: Self.shaderSrc, options: nil)
            return msl
        }

        private func obtainBlit(for fmt: MTLPixelFormat, linear: Bool) -> MTLRenderPipelineState? {
            if linear, let p = blitLinearPipeline { return p }
            if !linear, let p = blitPipeline { return p }
            guard let lib = library() else { return nil }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "bv_vs")
            d.fragmentFunction = lib.makeFunction(name: linear ? "bv_blit_linear_fs" : "bv_blit_fs")
            d.colorAttachments[0].pixelFormat = fmt
            let p = try? state.context.device.makeRenderPipelineState(descriptor: d)
            if linear { blitLinearPipeline = p } else { blitPipeline = p }
            return p
        }

        private func obtainComposite(for fmt: MTLPixelFormat) -> MTLRenderPipelineState? {
            if let p = compositePipeline { return p }
            guard let lib = library() else { return nil }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "bv_vs")
            d.fragmentFunction = lib.makeFunction(name: "bv_composite_fs")
            d.colorAttachments[0].pixelFormat = fmt
            compositePipeline = try? state.context.device.makeRenderPipelineState(descriptor: d)
            return compositePipeline
        }

        private func blitScale(source: MTLTexture, into dst: MTLTexture, cb: MTLCommandBuffer) {
            // Magnifying a small (downscaled) source → nearest, to show its
            // raw pixels. Minifying a full-res original → linear, to avoid
            // single-tap aliasing.
            let minifying = source.width > dst.width
            guard let pipe = obtainBlit(for: dst.pixelFormat, linear: minifying) else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = dst
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = backgroundColor
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(pipe)
            enc.setFragmentTexture(source, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
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

        private func composite(primaryIn: MTLTexture,
                               secondaryIn: MTLTexture,
                               into dst: MTLTexture,
                               cb: MTLCommandBuffer) {
            var primary = primaryIn
            var secondary = secondaryIn

            // The chain renders at a whole multiple that may exceed what's
            // shown (integer scale keeps a floor so the shader has room to
            // draw scanlines). Step it down to the DISPLAY size — an exact
            // integer factor, so it's a clean box filter — then letterbox
            // that. Applied regardless of zoom: skipping it while zoomed
            // changed the mapping, so toggling integer scale appeared to
            // change the zoom level.
            if let plan = scaling, plan.needsDownsample, let down = obtainDownscaler() {
                let fw = plan.displayWidth, fh = plan.displayHeight
                if let fitP = obtainFitTexture(slot: 0, width: fw, height: fh,
                                               format: primary.pixelFormat) {
                    down.encode(into: cb, source: primary, destination: fitP, method: .area)
                    primary = fitP
                }
                if state.compareEnabled, secondaryIn !== primaryIn,
                   let fitS = obtainFitTexture(slot: 1, width: fw, height: fh,
                                               format: secondaryIn.pixelFormat) {
                    down.encode(into: cb, source: secondaryIn, destination: fitS, method: .area)
                    secondary = fitS
                } else if secondaryIn === primaryIn {
                    secondary = primary
                }
            }

            guard let pipe = obtainComposite(for: dst.pixelFormat) else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = dst
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = backgroundColor
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(pipe)
            enc.setFragmentTexture(primary, index: 0)
            enc.setFragmentTexture(secondary, index: 1)
            // Integer scale letterboxes the (smaller) target at 1:1 in the
            // drawable; otherwise the target is stretched to fill it.
            //
            // The offset must be a WHOLE number of pixels. Centring on a half
            // pixel (which happens whenever drawable − target is odd) puts
            // every nearest-filtered sample exactly on a texel boundary, and
            // float rounding then duplicates some rows and drops others —
            // horizontal banding that appears and disappears as the window is
            // resized. Measured on a 1280 target: an odd delta duplicates
            // ~150 of 1280 rows, an even delta none.
            if Self.scaleLog {
                let dx = dst.width - primary.width, dy = dst.height - primary.height
                let key = "\(dst.width)x\(dst.height)/\(primaryIn.width)/\(primary.width)"
                if key != Self.lastScaleLogKey {
                    Self.lastScaleLogKey = key
                    fputs("[scale] drawable \(dst.width)x\(dst.height) chain-render \(primaryIn.width)x\(primaryIn.height) displayed \(primary.width)x\(primary.height) delta \(dx),\(dy) \(dx % 2 == 0 && dy % 2 == 0 ? "even" : "ODD")\n", stderr)
                }
            }
            // Integer scale letterboxes the displayed image at 1:1; without
            // it the render fills the drawable.
            let stretch = !state.integerScale
            let tgtW = Float(stretch ? dst.width : primary.width)
            let tgtH = Float(stretch ? dst.height : primary.height)
            let offX = stretch ? 0 : Float((dst.width - primary.width) / 2)
            let offY = stretch ? 0 : Float((dst.height - primary.height) / 2)
            var u = CompositeU(
                compareLineX: state.compareLineX,
                compareEnabled: state.compareEnabled ? 1 : 0,
                zoom: max(1, state.zoom),
                panX: state.panX,
                panY: state.panY,
                // Zoomed in = pixel inspection: sample the render targets
                // nearest so magnification doesn't blur them. At fit, linear
                // gives the smoother final-image resample. Integer scale is
                // exact multiples, so nearest is always right there.
                useNearest: (state.zoom > 1.001 || state.integerScale) ? 1 : 0,
                dstW: Float(dst.width),
                dstH: Float(dst.height),
                tgtW: tgtW,
                tgtH: tgtH,
                offX: offX,
                offY: offY
            )
            enc.setFragmentBytes(&u, length: MemoryLayout<CompositeU>.size, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        private func clearAndPresent(drawable: CAMetalDrawable, cb: MTLCommandBuffer) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = backgroundColor
            if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
                enc.endEncoding()
            }
            cb.present(drawable)
            cb.commit()
        }
    }
}

// MARK: - PreviewMTKView (input handling)

/// MTKView subclass that handles:
///   - hold space + drag mouse → pan (when zoomed in)
///   - compare mode + drag mouse → move the compare line
///   - cursor changes for visual feedback
final class PreviewMTKView: MTKView {

    weak var appState: AppState?

    private var spaceDown: Bool = false
    private var spaceCursorPushed: Bool = false
    private var draggingCompareLine: Bool = false
    private var dragStartMouse: NSPoint = .zero
    private var dragStartPanX: Float = 0
    private var dragStartPanY: Float = 0

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // MARK: cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    private func updateCursor(at p: NSPoint) {
        guard let state = appState else { return }
        if spaceDown {
            if !spaceCursorPushed {
                NSCursor.openHand.push()
                spaceCursorPushed = true
            }
            return
        }
        if spaceCursorPushed {
            NSCursor.pop()
            spaceCursorPushed = false
        }
        if state.compareEnabled {
            let lineX = bounds.width * CGFloat(state.compareLineX)
            if abs(p.x - lineX) < 8 {
                NSCursor.resizeLeftRight.set()
                return
            }
        }
        NSCursor.arrow.set()
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 /* space */ {
            if !spaceDown {
                spaceDown = true
                if !spaceCursorPushed {
                    NSCursor.openHand.push()
                    spaceCursorPushed = true
                }
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            if spaceCursorPushed {
                NSCursor.pop()
                spaceCursorPushed = false
            }
            return
        }
        super.keyUp(with: event)
    }

    // MARK: mouse

    /// Keep the compare line a few points inside the edges so it never
    /// vanishes (or becomes ungrabbable) when dragged all the way across.
    private func clampedCompareX(_ p: CGPoint) -> Float {
        let m = 3.0 / max(bounds.width, 1)
        return Float(max(m, min(1 - m, p.x / bounds.width)))
    }

    override func mouseDown(with event: NSEvent) {
        guard let state = appState else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragStartMouse = p
        dragStartPanX = state.panX
        dragStartPanY = state.panY

        if spaceDown {
            NSCursor.closedHand.set()
            return
        }
        if state.compareEnabled {
            let lineX = bounds.width * CGFloat(state.compareLineX)
            if abs(p.x - lineX) < 12 {
                draggingCompareLine = true
                state.compareLineX = clampedCompareX(p)
                return
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let state = appState else { return }
        let p = convert(event.locationInWindow, from: nil)

        if draggingCompareLine {
            state.compareLineX = clampedCompareX(p)
            return
        }
        if spaceDown && state.zoom > 1.0 {
            // Pan in image-uv space. Drag right → image moves right, which in
            // texture-space means panX increases.
            let dx = Float(p.x - dragStartMouse.x) / Float(bounds.width)
            let dy = Float(p.y - dragStartMouse.y) / Float(bounds.height)
            // Clamp so we can't pan past the image edge.
            let halfRange = (1.0 - 1.0 / state.zoom) * 0.5
            state.panX = max(-halfRange, min(halfRange, dragStartPanX + dx / state.zoom))
            // y in NSView is bottom-up; the shader's y is top-down, so flip.
            state.panY = max(-halfRange, min(halfRange, dragStartPanY - dy / state.zoom))
        }
    }

    override func mouseUp(with event: NSEvent) {
        draggingCompareLine = false
        if spaceDown { NSCursor.openHand.set() }
    }

    // MARK: scroll → zoom (handy bonus)

    override func scrollWheel(with event: NSEvent) {
        guard let state = appState, event.modifierFlags.contains(.option) || event.subtype == .mouseEvent else {
            super.scrollWheel(with: event); return
        }
        let dy = Float(event.scrollingDeltaY)
        state.zoom = max(1.0, min(12.0, state.zoom * (1 + dy * 0.005)))
    }
}
