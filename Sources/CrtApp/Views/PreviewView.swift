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
        let animating = state.animatePreview && !state.exportInProgress
        nsView.isPaused = !animating
        nsView.enableSetNeedsDisplay = !animating
        nsView.preferredFramesPerSecond = 60
        context.coordinator.requestRedraw()
    }

    final class Coordinator: NSObject, MTKViewDelegate {

        /// Safety cap on the offscreen render target's long edge (the target
        /// normally matches the drawable size).
        private static let maxTargetLongEdge = 4096

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

                // Render the primary target (matches current shaderEnabled state).
                do {
                    try renderState(state.shaderEnabled, source: source, into: primary, cb: cb)
                } catch {
                    lastRenderedChainTick = nil
                    clearAndPresent(drawable: drawable, cb: cb); return
                }

                // Render secondary only when compare is on — that's the OTHER state.
                if state.compareEnabled, let secondary = secondaryTarget {
                    do {
                        try renderState(!state.shaderEnabled, source: source, into: secondary, cb: cb)
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
            composite(primary: primary,
                      secondary: state.compareEnabled ? (secondaryTarget ?? primary) : primary,
                      into: drawable.texture, cb: cb)

            cb.present(drawable)
            cb.commit()
        }

        // MARK: - target sizing

        private func renderTargetSize(inputW: Int, inputH: Int) -> (Int, Int) {
            // Render the chain at the drawable's resolution — RetroArch
            // renders at the viewport size, and mask/scanline structure only
            // reads correctly when target pixels map 1:1 to screen pixels.
            // (The MTKView is aspect-fitted to the source, so the drawable
            // already carries the source aspect.) Capped for safety.
            if let size = view?.drawableSize, size.width >= 1, size.height >= 1 {
                if state.integerScale, inputW > 0, inputH > 0 {
                    // Largest whole multiple of the chain input that fits the
                    // drawable; the composite letterboxes it at 1:1.
                    let k = max(1, min(Int(size.width) / inputW,
                                       Int(size.height) / inputH))
                    return (inputW * k, inputH * k)
                }
                let cap = Double(Self.maxTargetLongEdge)
                let scale = min(1.0, cap / Double(max(size.width, size.height)))
                return (max(64, Int(Double(size.width) * scale)),
                        max(64, Int(Double(size.height) * scale)))
            }
            // Before first layout: source aspect at 1080 long edge.
            let aspect = state.sourceAspect
            let cap = 1080
            if aspect >= 1 {
                let h = max(64, Int((Double(cap) / Double(aspect)).rounded()))
                return (cap, h)
            } else {
                let w = max(64, Int((Double(cap) * Double(aspect)).rounded()))
                return (w, cap)
            }
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
                                 into target: MTLTexture,
                                 cb: MTLCommandBuffer) throws {
            if shaderOn, let chain = state.chain {
                try state.pipeline.encode(into: cb,
                                          chain: chain,
                                          inputTexture: source,
                                          outputTexture: target,
                                          downscale: state.downscaleSpec,
                                          frameCount: state.frameCounter)
                return
            }

            // Shader off: optionally downscale, then upscale into target.
            let intermediate: MTLTexture
            if let spec = state.downscaleSpec {
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

        // Upscale blit for the shader-off view (tiny downscaled src -> 1080p
        // target). Nearest, so the preview shows the raw downscaled pixels
        // instead of bilinearly smearing them.
        fragment float4 bv_blit_fs(VOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]]) {
            constexpr sampler s(filter::nearest, address::clamp_to_edge);
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
            float fitX;             // target/drawable fraction (1 = fill)
            float fitY;
        };

        fragment float4 bv_composite_fs(VOut in [[stage_in]],
                                        texture2d<float> primary [[texture(0)]],
                                        texture2d<float> secondary [[texture(1)]],
                                        constant CompositeU& u [[buffer(0)]])
        {
            constexpr sampler sampL(filter::linear, address::clamp_to_edge);
            constexpr sampler sampN(filter::nearest, address::clamp_to_edge);

            // Letterbox (integer scale), then zoom + pan around the centre.
            float2 uv = (in.uv - 0.5) / float2(u.fitX, u.fitY);
            uv = uv / u.zoom;
            uv = uv + 0.5 - float2(u.panX, u.panY);

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
                // 1 px line in screen space (approximate using uv-derivatives).
                float lineWidth = max(fwidth(in.uv.x) * 1.0, 0.0008);
                if (abs(in.uv.x - u.compareLineX) < lineWidth) {
                    colour = float4(1.0, 1.0, 1.0, 1.0);
                }
            } else {
                colour = a;
            }
            return colour;
        }
        """

        private var blitPipeline: MTLRenderPipelineState?       // bv_blit_fs
        private var compositePipeline: MTLRenderPipelineState?  // bv_composite_fs
        private var msl: MTLLibrary?

        private func library() -> MTLLibrary? {
            if let l = msl { return l }
            msl = try? state.context.device.makeLibrary(source: Self.shaderSrc, options: nil)
            return msl
        }

        private func obtainBlit(for fmt: MTLPixelFormat) -> MTLRenderPipelineState? {
            if let p = blitPipeline { return p }
            guard let lib = library() else { return nil }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "bv_vs")
            d.fragmentFunction = lib.makeFunction(name: "bv_blit_fs")
            d.colorAttachments[0].pixelFormat = fmt
            blitPipeline = try? state.context.device.makeRenderPipelineState(descriptor: d)
            return blitPipeline
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
            guard let pipe = obtainBlit(for: dst.pixelFormat) else { return }
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
            var fitX: Float
            var fitY: Float
        }

        private func composite(primary: MTLTexture,
                               secondary: MTLTexture,
                               into dst: MTLTexture,
                               cb: MTLCommandBuffer) {
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
            // drawable; otherwise the target fills it (they normally match).
            let fitX = state.integerScale ? Float(primary.width) / Float(dst.width) : 1
            let fitY = state.integerScale ? Float(primary.height) / Float(dst.height) : 1
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
                fitX: min(1, fitX),
                fitY: min(1, fitY)
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
                state.compareLineX = Float(max(0, min(1, p.x / bounds.width)))
                return
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let state = appState else { return }
        let p = convert(event.locationInWindow, from: nil)

        if draggingCompareLine {
            state.compareLineX = Float(max(0, min(1, p.x / bounds.width)))
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
