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
        // Pipelined playback runs the display link at full rate and pulls
        // the due frame inside draw() — the only macOS timer with
        // frame-accurate wake-ups (Task.sleep on the main actor was measured
        // waking 30-55 ms late, capping playback at ~16 fps by itself).
        if state.isPipelinedPlayback {
            nsView.startPlaybackLink()
            return
        }
        nsView.stopPlaybackLink()
        let animating = state.animatePreview && !state.exportInProgress
            && !state.videoPlaying
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
        private static var lastDrawAt: UInt64 = 0
        private static var gapTotal = 0.0
        private static var gapMax = 0.0
        private static var gapN = 0

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

            // Pull-model playback: fetch whichever frame is due right now.
            if state.isPipelinedPlayback { state.consumePipelinedFrame() }
            if Self.perfLog {
                let now = DispatchTime.now().uptimeNanoseconds
                if Self.lastDrawAt != 0 {
                    let gap = Double(now - Self.lastDrawAt) / 1_000_000
                    Self.gapTotal += gap; Self.gapMax = max(Self.gapMax, gap); Self.gapN += 1
                    if Self.gapN >= 48 {
                        fputs(String(format: "[link] draw gap mean %.1f ms max %.1f — paused=%d needsDisp=%d pref=%d screenMax=%d\n",
                                     Self.gapTotal / Double(Self.gapN), Self.gapMax,
                                     view.isPaused ? 1 : 0,
                                     view.enableSetNeedsDisplay ? 1 : 0,
                                     view.preferredFramesPerSecond,
                                     NSScreen.main?.maximumFramesPerSecond ?? -1), stderr)
                        Self.gapTotal = 0; Self.gapMax = 0; Self.gapN = 0
                    }
                }
                Self.lastDrawAt = now
            }

            let animating = state.animatePreview && !state.exportInProgress
                && !state.videoPlaying
            if animating { state.tickFrame() }
            // A still without a timeline runs the glitch receiver on the wall
            // clock while Animate is on (and holds it still while it's off).
            state.advanceAnimateClock(running: animating && state.glitchEnabled
                                      && state.videoSource == nil && !state.timelineEnabled)

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
                if state.ntscEnabled, let cached = state.cachedChainInput {
                    // Frame cache hit: NTSC and downscale already applied.
                    chainSource = cached
                    spec = nil
                } else if state.ntscEnabled, let baked = state.processedSourceTexture {
                    // Pipelined playback already ran the NTSC stage on a
                    // background thread. Downscale into a texture of our own
                    // so the frame cache can keep it (pool memory is
                    // recycled); the compare side keeps using the clean
                    // `source`. No room in the cache → downscale in the
                    // encode below as before.
                    if state.frameCacheHasRoom(forChainInputOf: baked, downscale: spec),
                       let copy = state.pipeline.makeChainInputCopy(
                            source: baked, downscale: spec, commandBuffer: cb) {
                        state.cacheChainInput(copy, forFrame: state.currentFrameIndex)
                        chainSource = copy
                        spec = nil
                    } else {
                        chainSource = baked
                    }
                } else if state.ntscEnabled, let stage = state.ntscStage {
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

                // Glitch stage: the simulated TV receiver, on the downscaled
                // raster (one row per scan line), before the CRT shader.
                if state.glitchEnabled, let glitch = state.glitchRenderer {
                    do {
                        let raster = try spec.map {
                            try glitch.downscaled(chainSource, spec: $0, commandBuffer: cb)
                        } ?? chainSource
                        chainSource = try glitch.encode(into: cb, chainInput: raster,
                                                        time: state.glitchTime,
                                                        settings: state.glitchSettings,
                                                        history: state.glitchHistory)
                        spec = nil
                    } catch {
                        // Show the unglitched frame rather than nothing.
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
            // CRT_COMPOSITE_DUMP=<path.png>: write the drawable's actual
            // pixels once things settle — ground truth for scanline checks.
            // `screencapture -l` returns a 1x image of a 2x window, which
            // halves scanline detail and corrupts modulation measurements.
            if let dumpPath = Self.compositeDumpPath {
                compositeDumpCountdown -= 1
                if compositeDumpCountdown == 0 {
                    cb.addCompletedHandler { _ in
                        Coordinator.writeDump(texture: drawable.texture, to: dumpPath)
                    }
                }
            }
            // CRT_CACHE_CHECK: dump exactly the requested playback frame.
            if let req = state.compositeDumpRequest,
               state.currentFrameIndex == req.frame, state.playbackLoops >= req.minLoop {
                state.dumpServedFromCache = state.cachedChainInput != nil
                state.compositeDumpRequest = nil
                cb.addCompletedHandler { _ in
                    Coordinator.writeDump(texture: drawable.texture, to: req.path)
                }
            }
            cb.commit()
        }

        private static let compositeDumpPath =
            ProcessInfo.processInfo.environment["CRT_COMPOSITE_DUMP"]
        private var compositeDumpCountdown = 30

        private static func writeDump(texture: MTLTexture, to path: String) {
            let w = texture.width, h = texture.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes { buf in
                texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4,
                                 from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            }
            // Drawables are BGRA; swap to RGBA for CGImage.
            for i in stride(from: 0, to: bytes.count, by: 4) {
                bytes.swapAt(i, i + 2)
                bytes[i + 3] = 255
            }
            let cs = CGColorSpaceCreateDeviceRGB()
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8,
                                    bitsPerPixel: 32, bytesPerRow: w * 4,
                                    space: cs, bitmapInfo: info, provider: provider,
                                    decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent),
                  let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
            else { fputs("COMPOSITE-DUMP failed\n", stderr); return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
            fputs("COMPOSITE-DUMP \(path) \(w)x\(h)\n", stderr)
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
            // The picture's size on screen in points, for dragging the crop.
            if let v = view, v.bounds.width > 0, size.width > 0 {
                let k = size.width / v.bounds.width
                state.previewDisplaySize = CGSize(width: CGFloat(plan.displayWidth) / k,
                                                  height: CGFloat(plan.displayHeight) / k)
            }
            if Self.scaleLog {
                let key = "\(Int(size.width))x\(Int(size.height))/\(plan.renderWidth)/\(plan.displayWidth)"
                if key != Self.lastScaleLogKey {
                    Self.lastScaleLogKey = key
                    fputs("[scale] drawable \(Int(size.width))x\(Int(size.height)) render \(plan.renderWidth)x\(plan.renderHeight) (x\(plan.renderMultiple)) display \(plan.displayWidth)x\(plan.displayHeight) (x\(plan.displayMultiple))\n", stderr)
                }
            }
            return (plan.renderWidth, plan.renderHeight)
        }

        /// Fit + letterbox + compare/zoom/pan live in CrtCore so the offscreen
        /// tests drive the very same code (see PreviewCompositorTests).
        private lazy var compositor = PreviewCompositor(context: state.context)

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
            compositor.blitScale(source: intermediate, into: target,
                                 background: backgroundColor, commandBuffer: cb)
        }

        // MARK: - composite (fit + letterbox + compare + zoom/pan)

        private func composite(primaryIn: MTLTexture,
                               secondaryIn: MTLTexture,
                               into dst: MTLTexture,
                               cb: MTLCommandBuffer) {
            // The plan comes from renderTargetSize() on the chain render;
            // composite-only draws (zoom, pan, compare) reuse it.
            guard let plan = scaling else { return }
            let geometry = PreviewGeometry.make(
                plan: plan, drawableWidth: dst.width, drawableHeight: dst.height,
                integerScale: state.integerScale,
                zoom: state.zoom, panX: state.panX, panY: state.panY)
            compositor.composite(primary: primaryIn, secondary: secondaryIn, into: dst,
                                 plan: plan, geometry: geometry,
                                 overlay: .init(compareEnabled: state.compareEnabled,
                                                compareLineX: state.compareLineX),
                                 background: backgroundColor, commandBuffer: cb)
            if Self.scaleLog {
                let sampled = compositor.lastSampledSize
                let dx = dst.width - geometry.targetWidth, dy = dst.height - geometry.targetHeight
                let key = "\(dst.width)x\(dst.height)/\(primaryIn.width)/\(geometry.targetWidth)/\(sampled.width)"
                if key != Self.lastScaleLogKey {
                    Self.lastScaleLogKey = key
                    fputs("[scale] drawable \(dst.width)x\(dst.height) chain-render \(primaryIn.width)x\(primaryIn.height) displayed \(geometry.targetWidth)x\(geometry.targetHeight) sampled \(sampled.width)x\(sampled.height) delta \(dx),\(dy) \(dx % 2 == 0 && dy % 2 == 0 ? "even" : "ODD")\n", stderr)
                }
            }
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

    /// CADisplayLink drive for pipelined playback.
    ///
    /// MTKView's built-in pacing (CVDisplayLink) follows the panel's CURRENT
    /// refresh rate — and ProMotion panels idle down when presents are
    /// sparse, settling into a ~16 Hz equilibrium: few presents → panel
    /// idles → link slows → fewer presents. Measured: 60-62 ms between
    /// draws with preferredFramesPerSecond=60 on a 120 Hz panel. CADisplayLink
    /// carries an explicit preferredFrameRateRange, which keeps the panel's
    /// rate up; the callback drives MTKView.draw() directly.
    private var playbackLink: CADisplayLink?

    func startPlaybackLink() {
        guard playbackLink == nil else { return }
        isPaused = true                 // we drive draws ourselves
        enableSetNeedsDisplay = false
        let link = displayLink(target: self, selector: #selector(playbackLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        playbackLink = link
    }

    func stopPlaybackLink() {
        playbackLink?.invalidate()
        playbackLink = nil
    }

    @objc private func playbackLinkFired() {
        draw()
    }


    weak var appState: AppState?

    private var spaceDown: Bool = false
    private var spaceCursorPushed: Bool = false
    private var draggingCompareLine: Bool = false
    /// Dragging the picture to slide the crop (see dragCrop).
    private var draggingCrop: Bool = false
    private var dragStartCropPosition: Double = 0.5
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
        if state.cropDragAxis != .none {
            (draggingCrop ? NSCursor.closedHand : NSCursor.openHand).set()
            return
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
        // Anywhere else on a cropped picture: drag it to move the crop,
        // double-click it to center the crop.
        if state.cropDragAxis != .none {
            if event.clickCount == 2 {
                state.cropPosition = 0.5
                return
            }
            draggingCrop = true
            dragStartCropPosition = state.cropPosition
            state.beginCropDrag()
            NSCursor.closedHand.set()
        }
    }

    /// Slide the crop so the picture follows the pointer: a point of motion
    /// is as many source pixels as the picture shows per point, and the crop
    /// moves the other way — dragging the picture right shows more of its
    /// left.
    private func dragCrop(to p: NSPoint) {
        guard let state = appState, let full = state.sourcePixelSize, let crop = state.activeCrop else { return }
        let r = crop.rect(width: full.width, height: full.height)
        let display = state.previewDisplaySize
        switch state.cropDragAxis {
        case .width:
            let slack = Double(full.width - r.width)
            guard slack > 0, display.width > 0 else { return }
            let pixels = Double(p.x - dragStartMouse.x) * Double(r.width) / Double(display.width)
            state.dragCrop(to: dragStartCropPosition - pixels / slack)
        case .height:
            let slack = Double(full.height - r.height)
            guard slack > 0, display.height > 0 else { return }
            // NSView's y runs up: the pointer going down takes the picture down
            // and the crop up.
            let pixels = Double(p.y - dragStartMouse.y) * Double(r.height) / Double(display.height)
            state.dragCrop(to: dragStartCropPosition + pixels / slack)
        case .none:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let state = appState else { return }
        let p = convert(event.locationInWindow, from: nil)

        if draggingCompareLine {
            state.compareLineX = clampedCompareX(p)
            return
        }
        if draggingCrop {
            dragCrop(to: p)
            return
        }
        if spaceDown && state.zoom > 1.0 {
            state.spacePanned = true     // a pan, not a play/pause tap
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
        if draggingCrop {
            draggingCrop = false
            appState?.endCropDrag()
            NSCursor.openHand.set()
        }
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
