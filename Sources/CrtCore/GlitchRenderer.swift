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

    /// Re-runs longer than this (simulated seconds from where one can
    /// resume) go to a background thread when `rerunsInBackground` is on.
    /// A second of simulation is ~35 ms; a minute is ~2 s, which on the
    /// main thread froze the app for every tick of a VCR knob dragged on a
    /// paused clip.
    public static let backgroundRerunAbove = 1.5

    /// The preview turns this on: a long exact re-run happens off the main
    /// thread while the preview shows the knobs applied to the state it
    /// has, and `onSettled` (main thread) asks for a redraw when the exact
    /// state is ready. Exports leave it off — every frame they draw is exact.
    public var rerunsInBackground = false
    public var onSettled: (() -> Void)?

    /// The background re-run in flight.
    private final class Rerun: @unchecked Sendable {
        let key: CheckpointKey
        let time: Double
        let raster: ReceiverRaster
        let settings: GlitchSettings
        /// The checkpoints it started from, and the one it resumed at.
        let kept: [ReceiverSimulator.Snapshot]
        let resume: ReceiverSimulator.Snapshot?
        private let lock = NSLock()
        private var _cancelled = false
        private var _done: (sim: ReceiverSimulator, taken: [ReceiverSimulator.Snapshot])?
        init(key: CheckpointKey, time: Double, raster: ReceiverRaster, settings: GlitchSettings,
             kept: [ReceiverSimulator.Snapshot], resume: ReceiverSimulator.Snapshot?) {
            self.key = key; self.time = time; self.raster = raster; self.settings = settings
            self.kept = kept; self.resume = resume
        }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
        func finish(_ sim: ReceiverSimulator, _ taken: [ReceiverSimulator.Snapshot]) {
            lock.lock(); _done = (sim, taken); lock.unlock()
        }
        /// The finished simulation, handed over once.
        func takeResult() -> (sim: ReceiverSimulator, taken: [ReceiverSimulator.Snapshot])? {
            lock.lock(); defer { lock.unlock() }
            let d = _done
            _done = nil
            return d
        }
    }
    private var rerun: Rerun?
    /// The time of the frame drawn last, for telling how far playback moved
    /// while a re-run is in flight.
    private var lastTime: Double?
    /// CRT_RERUN_LOG=1: report background re-runs landing.
    private static let logReruns = ProcessInfo.processInfo.environment["CRT_RERUN_LOG"] != nil
    private func cancelRerun() { rerun?.cancel(); rerun = nil }

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
        // A finished background re-run is taken up by the next frame drawn.
        // (Waiting for its own hop to the main queue held the old state on
        // screen for half a second and more during playback, when the main
        // thread has little time between frames.)
        if let job = rerun, job.raster == raster { adopt(job) }
        let sim: ReceiverSimulator
        var fresh = false
        if let s = simulator, s.raster == raster {
            sim = s
        } else {
            sim = ReceiverSimulator(raster: raster)
            simulator = sim
            fresh = true
            cancelRerun()
            checkpoints = []
            checkpointKey = nil
        }
        // One scan line of tolerance: after an advance the simulation sits
        // up to a line past the requested time.
        let lineTime = 1 / (Double(raster.totalLines) * NTSCTiming.fieldRate)
        let standingStill = abs(time - sim.time) <= 2 * lineTime
        let jumped = time < sim.time - 2 * lineTime || time - sim.time > Self.maxStep
        let retuned = standingStill && lastSettings != nil && lastSettings?.timing != settings.timing
        let past = standingStill ? nil : history()
        if fresh || jumped || retuned {
            let h = past ?? history()
            let key: CheckpointKey = h.map { .history($0.id, $0.frameDuration) } ?? .constant(settings.timing)
            let resumeAt = key == checkpointKey ? checkpoints.last(where: { $0.time <= time })?.time : nil
            let span = time - (resumeAt ?? -ReceiverSimulator.warmup)
            if rerunsInBackground, span > Self.backgroundRerunAbove {
                if let r = rerun, r.key == key, r.raster == raster, r.time <= time + 2 * lineTime {
                    // Already on its way to here, or to a moment before it
                    // (playing on, or scrubbing forward); from where it
                    // lands, the rest is a short step. Until then the state
                    // we have runs on by as much as the playhead moved, so
                    // a playing picture doesn't stand still meanwhile.
                    if let last = lastTime, time > last, time - last <= Self.maxStep {
                        sim.advance(to: sim.time + (time - last), settings: settings)
                    }
                } else {
                    showMeanwhile(sim, at: time, settings: settings, retuned: retuned, fresh: fresh)
                    startRerun(key: key, to: time, settings: settings, history: h, raster: raster)
                }
            } else {
                cancelRerun()
                resimulate(sim, to: time, settings: settings, history: h)
            }
        } else if let past, checkpointKey == .history(past.id, past.frameDuration) {
            // A short step forward through keyframed knobs (playback, or a
            // scrub of under a second): run it frame by frame through the
            // keyframes, exactly as the re-run from zero would, so a moment
            // looks the same however the playhead got there.
            sim.resimulate(to: time, frameDuration: past.frameDuration,
                           settingsAt: past.settingsAt, resumeFrom: sim.snapshot())
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
        lastTime = time
        let plan = sim.plan()
        lastPlan = plan
        return try render(into: cb, chainInput: chainInput, plan: plan)
    }

    /// Forget the simulation: the next frame starts from a freshly
    /// simulated set at its time, as if these settings had always been on.
    /// (A new look must not inherit the last one's rolling picture or lost
    /// tracking, which turning a knob mid-play rightly would.)
    public func restart() {
        cancelRerun()
        simulator = nil
        checkpoints = []
        checkpointKey = nil
        lastSettings = nil
        lastTime = nil
    }

    /// While a background re-run works: the knobs applied to the state the
    /// simulation has (a knob turned on a paused frame), a checkpoint within
    /// a second of a jump stepped on to it, or a fresh set's first moment.
    private func showMeanwhile(_ sim: ReceiverSimulator, at time: Double,
                               settings: GlitchSettings, retuned: Bool, fresh: Bool) {
        if retuned {
            sim.advance(to: sim.time, settings: settings)
        } else if let c = checkpoints.last(where: { $0.time <= time && time - $0.time <= Self.maxStep }) {
            sim.restore(c)
            sim.advance(to: time, settings: settings)
        } else if fresh {
            sim.advance(to: 0, settings: settings)
        }
    }

    /// The exact re-run on a fresh simulator off the main thread, adopted
    /// (with its checkpoints) if nothing has superseded it by the time it
    /// finishes.
    private func startRerun(key: CheckpointKey, to time: Double, settings: GlitchSettings,
                            history: GlitchHistory?, raster: ReceiverRaster) {
        cancelRerun()
        if Self.logReruns { fputs(String(format: "RERUN start to %.2f s\n", time), stderr) }
        let kept = key == checkpointKey ? checkpoints : []
        let resume = kept.last(where: { $0.time <= time })
        let job = Rerun(key: key, time: time, raster: raster, settings: settings,
                        kept: kept, resume: resume)
        rerun = job
        nonisolated(unsafe) let history = history
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sim = ReceiverSimulator(raster: raster)
            var taken: [ReceiverSimulator.Snapshot] = []
            if let history {
                sim.resimulate(to: time, frameDuration: history.frameDuration,
                               settingsAt: history.settingsAt, resumeFrom: resume,
                               checkpoint: { taken.append($0) }, isCancelled: { job.cancelled })
            } else {
                if let resume {
                    sim.restore(resume)
                } else {
                    sim.advance(to: 0, settings: settings)
                    taken.append(sim.snapshot(at: 0))
                }
                var next = max(1, ((resume?.time ?? 0) + 1).rounded(.down))
                while next < time, !job.cancelled {
                    sim.advance(to: next, settings: settings)
                    taken.append(sim.snapshot())
                    next += 1
                }
                if !job.cancelled { sim.advance(to: time, settings: settings) }
            }
            guard !job.cancelled else {
                if Self.logReruns { fputs("RERUN cancelled\n", stderr) }
                return
            }
            job.finish(sim, taken)
            DispatchQueue.main.async {
                // A playing preview has usually taken it up already (the
                // next frame drawn does); a paused one is asked to redraw.
                guard let self, !job.cancelled else { return }
                if self.rerun === job { self.adopt(job) }
                self.onSettled?()
            }
        }
    }

    /// Take up a background re-run's simulation and checkpoints, if it has
    /// finished and nothing has superseded it.
    private func adopt(_ job: Rerun) {
        guard rerun === job, !job.cancelled, let done = job.takeResult() else { return }
        rerun = nil
        simulator = done.sim
        checkpointKey = job.key
        var all = job.kept.filter { $0.time <= (job.resume?.time ?? -.infinity) }
        for snap in done.taken where snap.time > (all.last?.time ?? -.infinity) { all.append(snap) }
        checkpoints = all
        lastSettings = job.settings
        if Self.logReruns { fputs(String(format: "RERUN landed at %.2f s\n", job.time), stderr) }
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
        // time, so checkpoints can sit on whole seconds — time zero among
        // them, the warmed-up set a looping clip returns to on every pass
        // (without it each loop re-ran the two-second warm-up).
        if let resume {
            sim.restore(resume)
        } else {
            sim.reset()
            sim.advance(to: 0, settings: settings)
            if checkpoints.isEmpty { checkpoints.append(sim.snapshot(at: 0)) }
        }
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
