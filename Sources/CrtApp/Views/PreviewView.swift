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
        private weak var view: MTKView?
        private let state: AppState
        private let backgroundColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)

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

            do {
                try state.pipeline.encode(into: cb,
                                          chain: chain,
                                          inputTexture: source,
                                          outputTexture: drawable.texture,
                                          downscale: state.downscaleSpec,
                                          frameCount: state.frameCounter)
            } catch {
                clear(drawable: drawable, commandBuffer: cb)
            }

            cb.present(drawable)
            cb.commit()
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
