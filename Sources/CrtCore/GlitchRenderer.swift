import Foundation
import Metal

/// How glitch settings varied over time, for re-simulating a stretch of
/// history exactly: sampled once per frame, as playback and export advance.
public struct GlitchHistory {
    public let frameDuration: Double
    public let settingsAt: (Double) -> GlitchSettings
    /// Changes whenever the history would (keyframes, timing, base values),
    /// so checkpoints taken under one history are never reused for another.
    public let id: Int
    public init(frameDuration: Double, id: Int,
                settingsAt: @escaping (Double) -> GlitchSettings) {
        self.frameDuration = frameDuration
        self.settingsAt = settingsAt
        self.id = id
    }
}

/// The glitch stage for one consumer (the preview, or one export): a TV
/// receiver simulation plus the GPU pass that draws what it displays.
///
/// Time only runs forward inside the simulation. Moving forward a little —
/// playback, Animate, an export's next frame — continues it, so a knob
/// turned mid-playback changes what happens from then on, as on a real
/// set. Jumping (scrubbing, a new export) or changing settings while time
/// stands still re-simulates from zero, so a given moment always looks the
/// same.
public final class GlitchRenderer {
    private let context: MetalContext
    private let stage: GlitchStage
    private var simulator: ReceiverSimulator?
    private var lastSettings: GlitchSettings?
    /// Snapshots from deterministic runs, about one per simulated second,
    /// valid for re-simulating the same history (`checkpointKey`).
    private var checkpoints: [ReceiverSimulator.Snapshot] = []
    private var checkpointKey: CheckpointKey?
    private enum CheckpointKey: Equatable {
        case constant([String: Double])        // the timing knobs
        case history(Int, Double)
    }
    private var output: MTLTexture?
    private var scratch: MTLTexture?
    public private(set) var lastPlan: GlitchFieldPlan?

    /// Forward jumps longer than this re-simulate instead of stepping.
    public static let maxStep = 1.0

    public init(context: MetalContext) throws {
        self.context = context
        stage = try GlitchStage(device: context.device)
    }

    /// Bring the receiver to `time` and draw the displayed field from
    /// `chainInput` (the picture after NTSC and downscale). Returns the
    /// texture to feed the CRT shader; it is reused on the next call.
    public func encode(into cb: MTLCommandBuffer,
                       chainInput: MTLTexture,
                       time: Double,
                       settings: GlitchSettings,
                       history: @autoclosure () -> GlitchHistory? = nil) throws -> MTLTexture {
        let raster = ReceiverRaster(width: chainInput.width, activeLines: chainInput.height)
        let sim: ReceiverSimulator
        var fresh = false
        if let s = simulator, s.raster == raster {
            sim = s
        } else {
            sim = ReceiverSimulator(raster: raster)
            simulator = sim
            fresh = true
            checkpoints = []
            checkpointKey = nil
        }
        // One scan line of tolerance: after an advance the simulation sits
        // up to a line past the requested time.
        let lineTime = 1 / (Double(raster.totalLines) * NTSCTiming.fieldRate)
        let standingStill = abs(time - sim.time) <= 2 * lineTime
        let jumped = time < sim.time - 2 * lineTime || time - sim.time > Self.maxStep
        let retuned = standingStill && lastSettings != nil && lastSettings?.timing != settings.timing
        if fresh || jumped || retuned {
            resimulate(sim, to: time, settings: settings, history: history())
        } else {
            sim.advance(to: time, settings: settings)
            // Playing on under the same constant settings extends the
            // checkpoints, so scrubbing back over played time stays quick.
            if checkpointKey == .constant(settings.timing),
               sim.time >= (checkpoints.last?.time ?? 0) + 1 {
                checkpoints.append(sim.snapshot())
            }
        }
        lastSettings = settings
        let plan = sim.plan()
        lastPlan = plan
        return try render(into: cb, chainInput: chainInput, plan: plan)
    }

    /// Deterministic re-run to `time`, resuming from the latest checkpoint
    /// of the same history when there is one.
    private func resimulate(_ sim: ReceiverSimulator, to time: Double,
                            settings: GlitchSettings, history: GlitchHistory?) {
        let key: CheckpointKey = history.map { .history($0.id, $0.frameDuration) } ?? .constant(settings.timing)
        if key != checkpointKey {
            checkpoints = []
            checkpointKey = key
        }
        let resume = checkpoints.last(where: { $0.time <= time })
        if let history {
            sim.resimulate(to: time, frameDuration: history.frameDuration,
                           settingsAt: history.settingsAt, resumeFrom: resume) { [weak self] snap in
                guard let self, snap.time > (self.checkpoints.last?.time ?? -1) else { return }
                self.checkpoints.append(snap)
            }
            return
        }
        // Constant settings: the state at any moment is a pure function of
        // time, so checkpoints can sit on whole seconds.
        if let resume { sim.restore(resume) } else { sim.reset() }
        var next = max(1, ((resume?.time ?? 0) + 1).rounded(.down))
        while next < time {
            sim.advance(to: next, settings: settings)
            if sim.time > (checkpoints.last?.time ?? -1) { checkpoints.append(sim.snapshot()) }
            next += 1
        }
        sim.advance(to: time, settings: settings)
    }

    /// Draw a plan again without moving time (a still export of exactly what
    /// the preview shows).
    public func render(into cb: MTLCommandBuffer, chainInput: MTLTexture,
                       plan: GlitchFieldPlan) throws -> MTLTexture {
        let out = try texture(&output, width: chainInput.width, height: chainInput.height,
                              format: chainInput.pixelFormat, usage: [.shaderRead, .shaderWrite])
        stage.encode(into: cb, input: chainInput, output: out, plan: plan)
        return out
    }

    /// The chain input at the downscale resolution, in a texture of our own
    /// — the stage works per scan line, so it needs the downscaled raster.
    public func downscaled(_ source: MTLTexture, spec: DownscaleSpec,
                           commandBuffer cb: MTLCommandBuffer) throws -> MTLTexture {
        let t = try texture(&scratch, width: spec.width, height: spec.height,
                            format: source.pixelFormat, usage: [.shaderRead, .shaderWrite])
        context.downscaler.encode(into: cb, source: source, destination: t, method: spec.method)
        return t
    }

    private func texture(_ slot: inout MTLTexture?, width: Int, height: Int,
                         format: MTLPixelFormat, usage: MTLTextureUsage) throws -> MTLTexture {
        if let t = slot, t.width == width, t.height == height, t.pixelFormat == format { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                         height: height, mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        guard let t = context.device.makeTexture(descriptor: d) else {
            throw NSError(domain: "GlitchRenderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "texture allocation"])
        }
        slot = t
        return t
    }
}
