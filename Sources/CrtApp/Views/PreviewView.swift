import SwiftUI
import AppKit
import Metal
import MetalKit
import CrtCore

/// SwiftUI wrapper for an MTKView that re-renders the pipeline whenever
/// `state.renderTick` changes.
struct PreviewView: NSViewRepresentable {
    @Environment(AppState.self) private var state

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: state.context.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true            // we drive frames manually
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Touch renderTick so SwiftUI's dependency-tracking subscribes us.
        _ = state.renderTick
        context.coordinator.requestRedraw()
    }

    final class Coordinator: NSObject, MTKViewDelegate {

        /// Live preview is rendered at this maximum long-edge size and then
        /// blit-scaled to the drawable. Keeps perf bounded regardless of
        /// window/Retina size — crt-royale at 4K Retina is otherwise heavy
        /// (~10 passes × 8MP/frame). Export uses the user-chosen size, not
        /// this cap.
        private static let previewMaxLongEdge = 1080

        private weak var view: MTKView?
        private let state: AppState
        private let backgroundColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)

        // Cached offscreen render target used for the preview pass. Recreated
        // when the source aspect changes.
        private var renderTarget: MTLTexture?

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

            // No source loaded → just clear.
            guard let source = state.sourceTexture, let chain = state.chain else {
                clear(drawable: drawable, commandBuffer: cb)
                cb.present(drawable)
                cb.commit()
                return
            }

            // Render into a capped-size offscreen target, then blit-scale
            // into the drawable.
            let target = obtainRenderTarget()
            do {
                try state.pipeline.encode(into: cb,
                                          chain: chain,
                                          inputTexture: source,
                                          outputTexture: target,
                                          downscale: state.downscaleSpec,
                                          frameCount: state.frameCounter)
            } catch {
                clear(drawable: drawable, commandBuffer: cb)
                cb.present(drawable)
                cb.commit()
                return
            }

            // Scale to drawable. MTLBlitCommandEncoder.copy doesn't scale, so
            // use a tiny render pass with a textured fullscreen quad — except
            // we don't have one. Easiest: use MPSImageScale (Metal Performance
            // Shaders) … but that adds a dep. Simpler still: render a fullscreen
            // pass that samples the offscreen texture into the drawable. We
            // do that with a dedicated tiny MSL shader.
            blitScale(source: target, into: drawable.texture, commandBuffer: cb)

            cb.present(drawable)
            cb.commit()
        }

        // MARK: - render target sizing

        private func obtainRenderTarget() -> MTLTexture {
            let aspect = state.sourceAspect
            let cap = Self.previewMaxLongEdge
            let w: Int, h: Int
            if aspect >= 1 {
                w = cap
                h = max(64, Int((Double(cap) / Double(aspect)).rounded()))
            } else {
                h = cap
                w = max(64, Int((Double(cap) * Double(aspect)).rounded()))
            }
            if let t = renderTarget, t.width == w, t.height == h {
                return t
            }
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: w, height: h, mipmapped: false
            )
            d.usage = [.renderTarget, .shaderRead, .shaderWrite]
            d.storageMode = .private
            let t = state.context.device.makeTexture(descriptor: d)!
            renderTarget = t
            return t
        }

        // MARK: - scale offscreen → drawable

        private static let scaleSource: String = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut blit_vs(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            VOut o;
            o.pos = float4(p * 2.0 - 1.0, 0, 1);
            o.uv  = float2(p.x, 1.0 - p.y);
            return o;
        }
        fragment float4 blit_fs(VOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return src.sample(s, in.uv);
        }
        """
        private var blitPipeline: MTLRenderPipelineState?

        private func obtainBlitPipeline(for pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
            if let p = blitPipeline { return p }
            let device = state.context.device
            do {
                let lib = try device.makeLibrary(source: Self.scaleSource, options: nil)
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = lib.makeFunction(name: "blit_vs")
                desc.fragmentFunction = lib.makeFunction(name: "blit_fs")
                desc.colorAttachments[0].pixelFormat = pixelFormat
                let p = try device.makeRenderPipelineState(descriptor: desc)
                blitPipeline = p
                return p
            } catch {
                return nil
            }
        }

        private func blitScale(source: MTLTexture,
                               into destination: MTLTexture,
                               commandBuffer: MTLCommandBuffer) {
            guard let pipe = obtainBlitPipeline(for: destination.pixelFormat) else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = destination
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = backgroundColor
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(pipe)
            enc.setFragmentTexture(source, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        private func clear(drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = backgroundColor
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                enc.endEncoding()
            }
        }
    }
}
