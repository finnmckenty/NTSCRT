import Foundation
import Metal
import Observation
import UniformTypeIdentifiers
import os
import CrtAppBridge
import CrtCore

enum SourceKind {
    case image
    case video(VideoSource)
}

/// Single source of truth for the running app.
///
/// Owns the Metal context, the render pipeline, the active source/preset, and
/// the parameter slider values. Mutations bump `chainTick` (shaded pixels
/// changed — the filter chain must re-run) or `viewTick` (presentation only —
/// re-composite the cached chain output) so PreviewView knows how much work
/// a redraw needs.
@Observable
final class AppState {

    let context: MetalContext
    let pipeline: Pipeline
    let presetsRoot: URL

    // MARK: - source

    var sourceURL: URL? {
        didSet {
            if sourceURL != oldValue {
                Task { await reloadSource() }
            }
        }
    }
    private(set) var sourceKind: SourceKind?
    private(set) var sourceTexture: MTLTexture? {
        didSet { sourceVersion &+= 1 }
    }
    /// Bumped whenever the source pixels change (load, scrub, playback), so
    /// the NTSC stage knows when its cached readback is still good.
    private(set) var sourceVersion: Int = 0
    private(set) var sourceError: String?

    /// For video sources only: 0..<videoSource.totalFrames.
    var currentFrameIndex: Int = 0 {
        didSet {
            if currentFrameIndex != oldValue && !suppressFrameReload {
                if videoPlaying, playbackPipeline != nil {
                    // Seek while playing: the producer is decoding somewhere
                    // else now — restart it at the new position.
                    startPipeline(at: currentFrameIndex)
                } else {
                    Task { await reloadVideoFrame() }
                }
            }
        }
    }

    // MARK: - video playback

    private(set) var videoPlaying: Bool = false
    private var playbackTask: Task<Void, Never>?
    static let playLog = ProcessInfo.processInfo.environment["CRT_PERF_LOG"] != nil
    /// CRT_FORCE_SEEK_DECODE=1: decode playback frames by seeking to each one
    /// (the pre-0.9 path, and what a rotated track still needs).
    static let forceSeekDecode = ProcessInfo.processInfo.environment["CRT_FORCE_SEEK_DECODE"] == "1"
    /// Set while the playback loop advances the index itself (it fetches
    /// frames directly, so the didSet reload would double-fetch).
    private var suppressFrameReload = false
    // MARK: - pipelined playback

    /// Producer for pipelined playback: decodes and runs the NTSC stage on a
    /// background thread so the main thread only renders. See
    /// PlaybackPipeline for the measured rationale.
    private var playbackPipeline: PlaybackPipeline?
    /// Last frame consumed from the pipeline (retains its pixel buffer).
    private var pipelineOutput: PlaybackPipeline.Output?
    /// Source texture with the NTSC stage already baked in, when playback is
    /// pipelined. The preview uses it as the chain input directly (still
    /// downscaled on the GPU); the compare split keeps using the clean
    /// `sourceTexture`. nil = process normally on the main thread.
    private(set) var processedSourceTexture: MTLTexture?
    /// Bumped on any user edit of NTSC settings; queued pipeline frames baked
    /// with an older generation are discarded rather than shown.
    private(set) var ntscGeneration: Int = 0
    /// Dropped-frame count for the current playback run (CRT_PERF_LOG).
    private(set) var playbackDropped: Int = 0

    /// User changed VHS settings: invalidate pre-baked frames everywhere.
    private func noteNtscSettingsEdited() {
        ntscGeneration &+= 1
        processedSourceTexture = nil
        pushPipelineConfig()
    }

    private func pushPipelineConfig() {
        guard let playbackPipeline else { return }
        let ev = (timelineEnabled && !timelineKeys.isEmpty) ? makeTimelineEvaluator() : nil
        let total = timelineTotalFrames
        let perFrame: (@Sendable (Int) -> String?)? = ev.map { e in
            { idx in
                let t = total > 1 ? Double(idx) / Double(total - 1) : 0
                return e.ntscJSON(at: t)
            }
        }
        playbackPipeline.config.update(enabled: ntscEnabled,
                               baseJSON: ntscStage?.settingsJSON(),
                               perFrameJSON: perFrame,
                               generation: ntscGeneration)
    }

    /// Held while a video plays. Without it App Nap coalesces every timing
    /// mechanism in the process — Task.sleep, CVDisplayLink and CADisplayLink
    /// were all measured firing at ~13-16 Hz on an idle main thread, which
    /// capped playback regardless of pipeline throughput. latencyCritical is
    /// exactly the assertion real media apps hold during playback.
    private var playbackActivity: NSObjectProtocol?

    func togglePlayback() {
        if videoPlaying { stopPlayback(); return }
        guard let source = videoSource, !exportInProgress else { return }
        videoPlaying = true
        playbackDropped = 0
        playbackActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "video playback")

        // Rotated tracks still go through the image generator (only it
        // applies preferredTransform); CRT_FORCE_SEEK_DECODE keeps the old
        // path reachable for A/B measurement.
        if source.needsPreferredTransform || Self.forceSeekDecode {
            playbackTask = legacyPlaybackTask(source: source)
            return
        }

        playbackFPS = Double(max(1, source.frameRate))
        startPipeline(at: (currentFrameIndex + 1) % max(1, source.totalFrames))
        // Consumption is pull-model from the display link (see
        // consumePipelinedFrame); a nudge starts the first draw.
        markChainDirty()
    }

    private func startPipeline(at frame: Int) {
        guard let source = videoSource else { return }
        playbackPipeline?.stop()
        let cfg = PlaybackPipeline.Config(enabled: ntscEnabled,
                                          baseJSON: ntscStage?.settingsJSON(),
                                          perFrameJSON: nil,
                                          generation: ntscGeneration)
        let pipe = PlaybackPipeline(source: source, device: context.device,
                                    startFrame: frame, config: cfg)
        playbackPipeline = pipe
        pushPipelineConfig()   // fills in the keyframe evaluator if any
        pipe.start()
        pipelineScheduleBase = frame
        playbackClockStart = nil    // re-prime on the next display tick
    }

    /// Where the consumer's schedule (re)starts, in producer-absolute frames.
    private var pipelineScheduleBase = 0

    /// Pull-model consumer, called from the MTKView's display link each
    /// refresh while a video plays. The display link is the only timer on
    /// macOS with frame-accurate wake-ups — Task.sleep on the main actor was
    /// measured waking 30-55 ms late on an otherwise idle main thread, which
    /// alone capped playback at ~16 fps. The schedule is wall-clock: the
    /// frame due *now* is shown, later frames wait, missed frames drop.
    private var playbackClockStart: ContinuousClock.Instant?
    private var playbackScheduleBase = 0
    private var playbackFPS = 24.0
    private(set) var playbackDisplayed = 0
    private var playbackLogStart = ContinuousClock.now

    var isPipelinedPlayback: Bool { videoPlaying && playbackPipeline != nil }

    func consumePipelinedFrame() {
        guard videoPlaying, let pipe = playbackPipeline else { return }
        guard !exportInProgress else { stopPlayback(); return }

        // Prime: the clock starts when the first frame exists, so the
        // schedule can't run ahead of a producer that hasn't begun.
        if playbackClockStart == nil {
            guard pipe.hasOutput() else { return }
            playbackClockStart = .now
            playbackScheduleBase = pipe.firstQueuedIndex() ?? pipelineScheduleBase
            playbackDisplayed = 0
            playbackLogStart = .now
        }
        guard let clockStart = playbackClockStart else { return }

        let elapsed = clockStart.duration(to: .now)
        let secs = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let schedule = playbackScheduleBase + Int(secs * playbackFPS)

        pipe.setTargetAbsoluteIndex(schedule)
        let (out, dropped) = pipe.takeReady(schedule: schedule, generation: ntscGeneration)
        playbackDropped += dropped
        guard let out else { return }

        pipelineOutput = out
        suppressFrameReload = true
        currentFrameIndex = out.frameIndex
        suppressFrameReload = false
        sourceTexture = out.clean
        processedSourceTexture = out.processed
        // Playhead + keyframed shader params for this frame (librashader is
        // main-thread; NTSC is already baked).
        applyTimeline(atFrame: out.frameIndex)
        tickFrame()
        markChainDirty()
        playbackDisplayed += 1

        if Self.playLog, playbackDisplayed % 48 == 0 {
            let span = playbackLogStart.duration(to: .now)
            let s = Double(span.components.seconds)
                + Double(span.components.attoseconds) / 1e18
            fputs(String(format: "[play] displayed %.1f fps, dropped %d total — %@\n",
                         48.0 / max(s, 0.001), playbackDropped,
                         pipe.takeStatsLine() as NSString), stderr)
            playbackLogStart = .now
        }
    }

    /// Pre-pipeline path: seek + decode each frame via the image generator.
    private func legacyPlaybackTask(source vs: VideoSource) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            var deadline = ContinuousClock.now
            while let self, self.videoPlaying, !Task.isCancelled {
                guard !self.exportInProgress else { self.stopPlayback(); return }
                let next = (self.currentFrameIndex + 1) % vs.totalFrames
                self.suppressFrameReload = true
                self.currentFrameIndex = next
                self.suppressFrameReload = false
                do {
                    self.sourceTexture = try await vs.frame(atIndex: next)
                    self.applyTimeline(atFrame: next)
                    self.tickFrame()
                    self.markChainDirty()
                } catch {
                    self.stopPlayback(); return
                }
                let frameDuration = Duration.seconds(1.0 / Double(max(1, vs.frameRate)))
                deadline = deadline.advanced(by: frameDuration)
                let now = ContinuousClock.now
                if deadline > now {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                } else if now - deadline > frameDuration {
                    deadline = now
                }
            }
        }
    }

    func stopPlayback() {
        videoPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        playbackPipeline?.stop()
        playbackPipeline = nil
        playbackClockStart = nil
        if let activity = playbackActivity {
            ProcessInfo.processInfo.endActivity(activity)
            playbackActivity = nil
        }
    }
    var videoSource: VideoSource? {
        if case .video(let v) = sourceKind { return v }
        return nil
    }

    /// Aspect ratio (width / height) of the loaded source. Used by the preview
    /// to letterbox/pillarbox the MTKView so the source isn't stretched, and
    /// by the exporter to derive height from a chosen long edge.
    var sourceAspect: CGFloat {
        if let tex = sourceTexture, tex.height > 0 {
            return CGFloat(tex.width) / CGFloat(tex.height)
        }
        if let vs = videoSource, vs.pixelSize.height > 0 {
            return vs.pixelSize.width / vs.pixelSize.height
        }
        return 16.0 / 9.0
    }

    // MARK: - downscale

    var downscaleEnabled: Bool = true { didSet { markChainDirty() } }
    /// Downscale is width-only: the horizontal resolution is chosen (or
    /// picked from a console preset), and the height follows the source's
    /// aspect ratio so any input shape works.
    var downscaleWidth: Int = 320     { didSet { markChainDirty() } }
    /// Selected preset label, purely cosmetic ("Custom" when hand-edited).
    var downscalePreset: String = "VGA (320px)"
    var downscaleMethod: DownscaleMethod = .nearest { didSet { markChainDirty() } }

    /// Derived from the source aspect (rounded to even lines).
    var downscaleHeight: Int {
        let aspect = max(0.05, Double(sourceAspect))
        return max(16, 2 * Int((Double(downscaleWidth) / aspect / 2).rounded()))
    }

    // MARK: - view (preview-only display state)

    /// Master shader on/off toggle. When false, the preview shows the source
    /// (or downscaled source) without any CRT shader applied.
    var shaderEnabled: Bool = true { didSet { markChainDirty() } }

    /// Compare mode: split the preview with a draggable vertical line —
    /// shader-on on one side, shader-off on the other.
    /// Chain-dirty: toggling on must populate the secondary target.
    var compareEnabled: Bool = true { didSet { markChainDirty() } }
    /// Normalised x-position of the compare line, 0..1.
    var compareLineX: Float = 0.5 { didSet { markViewDirty() } }

    /// Integer scale: size the render target to a whole-number multiple of
    /// the chain input (RetroArch's "Integer Scale"), letterboxed in the
    /// preview. Gives uniform scanline/mask structure — non-integer scales
    /// visually dilute beam-shape and scanline params.
    var integerScale: Bool = true { didSet { markChainDirty() } }

    /// Preview zoom factor (1.0 = fit, up to 12.0 = 1200%).
    var zoom: Float = 1.0 {
        didSet {
            if zoom <= 1.0 { panX = 0; panY = 0 }
            markViewDirty()
        }
    }
    /// Pan offset in normalised image space (clamped so panning can't expose
    /// beyond the source bounds at the current zoom).
    var panX: Float = 0.0 { didSet { markViewDirty() } }
    var panY: Float = 0.0 { didSet { markViewDirty() } }

    func resetView() {
        zoom = 1.0
        panX = 0
        panY = 0
    }

    // MARK: - timeline (keyframe animation, image sources → video)

    /// Timeline mode: animate parameters over time and render the result as
    /// video. On a still the length is ours to choose; on a video the clip
    /// supplies it, and the playhead IS the video position — one time axis,
    /// not two disagreeing scrubbers.
    var timelineEnabled: Bool = false {
        didSet { if !timelineEnabled { stopTimelinePreview() } }
    }
    var timelineKeys: [Keyframe] = []
    /// Output length in seconds. Keyframe times are normalized (0…1), so
    /// changing the duration stretches the whole animation proportionally.
    var timelineDuration: Double = 5.0
    var timelineFPS: Int = 30
    /// Playhead position, normalized 0…1.
    private(set) var playheadT: Double = 0
    private(set) var timelinePlaying = false
    private var timelinePreviewTask: Task<Void, Never>?

    var isImageSource: Bool {
        if case .image = sourceKind { return true }
        return false
    }

    /// Resolution the shader actually renders from.
    var chainInputSize: (width: Int, height: Int) {
        ScanlineGrid.chainInputSize(width: sourceTexture?.width ?? 0,
                                    height: sourceTexture?.height ?? 0,
                                    downscale: downscaleSpec)
    }

    /// Frames the timeline spans. A video's own frames, or the chosen
    /// duration × frame rate for a still.
    var timelineTotalFrames: Int {
        if let vs = videoSource { return max(1, vs.totalFrames) }
        return max(1, Int((timelineDuration * Double(timelineFPS)).rounded()))
    }

    /// Length in seconds — the clip's for a video, the chosen one otherwise.
    var effectiveTimelineDuration: Double {
        if let vs = videoSource {
            return Double(vs.totalFrames) / Double(max(1, vs.frameRate))
        }
        return timelineDuration
    }

    /// Frame rate the timeline runs at (a video's own; ours for a still).
    var effectiveTimelineFPS: Int {
        if let vs = videoSource { return max(1, Int(Double(vs.frameRate).rounded())) }
        return timelineFPS
    }

    /// Timelines are available for stills and video alike.
    var timelineAvailable: Bool { sourceKind != nil }

    /// Normalized position of a video frame.
    private func normalizedTime(forFrame index: Int) -> Double {
        let last = max(1, timelineTotalFrames - 1)
        return min(1, max(0, Double(index) / Double(last)))
    }

    /// How close the playhead must be to a keyframe to count as parked on it.
    /// A still can land exactly; video time is quantized to frames, so half a
    /// frame is as close as it gets.
    private var parkedTolerance: Double {
        guard videoSource != nil else { return 1e-6 }
        return 0.5 / Double(max(1, timelineTotalFrames - 1))
    }

    /// Value-captured evaluator for scrubbing and export. nil when there are
    /// no keyframes.
    func makeTimelineEvaluator() -> TimelineEvaluator? {
        var meta: [String: TimelineEvaluator.ShaderMeta] = [:]
        for p in paramDescriptors {
            meta[p.name] = .init(minimum: p.minimum, maximum: p.maximum, step: p.step)
        }
        var interp: [String: TimelineEvaluator.NtscInterp] = [:]
        func walk(_ settings: [NtscSetting]) {
            for s in settings {
                switch s.kind {
                case .boolean, .enumeration: interp[s.name] = .hold
                case .int:                   interp[s.name] = .lerpInt
                case .percentage, .float:    interp[s.name] = .lerp
                case .group(let children):   walk(children)
                // Presentation-only grouping: recurse, or its children drop
                // out of keyframe interpolation entirely.
                case .section(let children): walk(children)
                }
            }
        }
        walk(ntscDescriptors)
        return TimelineEvaluator(keys: timelineKeys, shaderMeta: meta, ntscInterp: interp)
    }

    /// Snapshot the current whole state into a keyframe at the playhead.
    /// Replaces an existing key sitting (nearly) on the playhead — that's
    /// the only way values are ever keyed; scrubbing and slider edits never
    /// auto-key.
    /// Move the playhead to a video frame and apply the animation there,
    /// without seeking (the caller already has the frame).
    private func applyTimeline(atFrame index: Int) {
        playheadT = normalizedTime(forFrame: index)
        guard timelineEnabled, let ev = makeTimelineEvaluator() else { return }
        withAutoKeySuppressed {
            setAllParams(paramValues.merging(ev.shaderParams(at: playheadT)) { _, new in new })
            applyNtscValues(ev.ntscValues(at: playheadT))
        }
    }

    /// Keep the playhead in step when the transport moves the frame by other
    /// means (scrubber, arrow keys, load).
    func syncPlayheadToCurrentFrame() {
        guard videoSource != nil else { return }
        applyTimeline(atFrame: currentFrameIndex)
    }

    func setKeyframeAtPlayhead() {
        let snapshot = Keyframe(t: playheadT,
                                shaderParams: paramValues,
                                ntscValues: ntscValues)
        if let i = timelineKeys.firstIndex(where: { abs($0.t - playheadT) < max(0.005, parkedTolerance) }) {
            var k = timelineKeys[i]
            k.shaderParams = snapshot.shaderParams
            k.ntscValues = snapshot.ntscValues
            timelineKeys[i] = k
        } else {
            timelineKeys.append(snapshot)
            timelineKeys.sort { $0.t < $1.t }
        }
    }

    func deleteKeyframe(id: UUID) {
        timelineKeys.removeAll { $0.id == id }
    }

    func setKeyframeEasing(id: UUID, _ easing: KeyEasing) {
        guard let i = timelineKeys.firstIndex(where: { $0.id == id }) else { return }
        timelineKeys[i].easing = easing
    }

    func moveKeyframe(id: UUID, to t: Double) {
        guard let i = timelineKeys.firstIndex(where: { $0.id == id }) else { return }
        timelineKeys[i].t = min(1, max(0, t))
        timelineKeys.sort { $0.t < $1.t }
    }

    /// Move the playhead and apply the interpolated state to the live
    /// controls (sliders follow, like scrubbing in an NLE).
    func scrubTimeline(to t: Double) {
        var target = min(1, max(0, t))
        // Magnetic playhead: land exactly on a nearby keyframe (~5px) so the
        // applied values are that keyframe's own — which is also what makes
        // it editable in place (see autoKeyIfParked).
        if let near = timelineKeys.min(by: { abs($0.t - target) < abs($1.t - target) }),
           abs(near.t - target) < 0.004 {
            target = near.t
        }
        // On a video the playhead and the transport are the same thing:
        // moving it seeks the clip, and time quantizes to whole frames.
        if let vs = videoSource {
            let frame = Int((target * Double(max(1, vs.totalFrames - 1))).rounded())
            target = normalizedTime(forFrame: frame)
            if frame != currentFrameIndex { currentFrameIndex = frame }
        }
        playheadT = target
        guard timelineEnabled, let ev = makeTimelineEvaluator() else { return }
        // Applying interpolated values must never look like a user edit.
        withAutoKeySuppressed {
            setAllParams(paramValues.merging(ev.shaderParams(at: playheadT)) { _, new in new })
            applyNtscValues(ev.ntscValues(at: playheadT))
        }
    }

    // MARK: - auto-keying

    /// True while parameter writes come from the app (scrubbing, preset
    /// load, chain reload) rather than from the user turning a knob.
    private var suppressAutoKey = false

    private func withAutoKeySuppressed(_ body: () -> Void) {
        let previous = suppressAutoKey
        suppressAutoKey = true
        body()
        suppressAutoKey = previous
    }

    /// When the playhead sits exactly on a keyframe, editing any parameter
    /// rewrites that keyframe — the After Effects / Premiere behaviour, so
    /// tweaking a look you've jumped to doesn't silently get discarded on
    /// the next scrub. Only ever fires for user edits, and only for an
    /// exact hit: at any other time the live values are interpolated, and
    /// baking those into a keyframe would drag it toward its neighbour.
    private func autoKeyIfParked() {
        guard timelineEnabled, !suppressAutoKey, !timelinePlaying, !exportInProgress else { return }
        guard let i = timelineKeys.firstIndex(where: { abs($0.t - playheadT) < parkedTolerance })
        else { return }
        timelineKeys[i].shaderParams = paramValues
        timelineKeys[i].ntscValues = ntscValues
    }

    func toggleTimelinePreview() {
        // A video plays through its own transport; the timeline just follows.
        if videoSource != nil { togglePlayback(); return }
        if timelinePlaying { stopTimelinePreview(); return }
        guard timelineEnabled, isImageSource, !exportInProgress else { return }
        timelinePlaying = true
        timelinePreviewTask = Task { @MainActor [weak self] in
            while let self, self.timelinePlaying, !Task.isCancelled {
                guard !self.exportInProgress else { self.stopTimelinePreview(); return }
                let start = ContinuousClock.now
                let dt = 1.0 / Double(self.timelineTotalFrames)
                var next = self.playheadT + dt
                if next > 1 { next = 0 }        // loop, like video playback
                self.scrubTimeline(to: next)
                self.tickFrame()                // VHS noise advances too
                self.markChainDirty()
                let frameDuration = Duration.seconds(1.0 / Double(max(1, self.timelineFPS)))
                let elapsed = start.duration(to: .now)
                if elapsed < frameDuration {
                    try? await Task.sleep(for: frameDuration - elapsed)
                }
            }
        }
    }

    func stopTimelinePreview() {
        timelinePlaying = false
        timelinePreviewTask?.cancel()
        timelinePreviewTask = nil
    }

    // MARK: - VHS / ntsc-rs stage

    /// nil when the ntscrs-capi dylib wasn't found/loaded.
    private(set) var ntscStage: NtscStage?
    private(set) var ntscDescriptors: [NtscSetting] = []
    private(set) var ntscDefaults: [String: Any] = [:]
    /// Flat values in ntsc-rs preset-JSON form (includes "version").
    private(set) var ntscValues: [String: Any] = [:]
    var ntscEnabled: Bool = true {
        didSet { noteNtscSettingsEdited(); markChainDirty() }
    }
    private(set) var ntscError: String?

    var ntscAvailable: Bool { ntscStage != nil }

    func setNtscValue(_ name: String, _ value: Any) {
        ntscValues[name] = value
        pushNtscSettings()
        autoKeyIfParked()
        noteNtscSettingsEdited()
        markChainDirty()
    }

    func ntscBool(_ name: String) -> Bool {
        (ntscValues[name] as? Bool) ?? ((ntscValues[name] as? NSNumber)?.boolValue ?? false)
    }

    func ntscNumber(_ name: String) -> Double {
        (ntscValues[name] as? NSNumber)?.doubleValue ?? 0
    }

    func resetNtsc() {
        ntscValues = ntscDefaults
        pushNtscSettings()
        autoKeyIfParked()
        noteNtscSettingsEdited()
        markChainDirty()
    }

    /// Replace the whole VHS settings dict at once (timeline scrub/load).
    func applyNtscValues(_ values: [String: Any]) {
        ntscValues = values
        pushNtscSettings()
        markChainDirty()
    }

    private func pushNtscSettings() {
        guard let stage = ntscStage,
              let data = try? JSONSerialization.data(withJSONObject: ntscValues),
              let json = String(data: data, encoding: .utf8) else { return }
        do {
            try stage.setSettingsJSON(json)
            ntscError = nil
        } catch {
            ntscError = error.localizedDescription
        }
    }

    /// The app's house VHS look, overlaid on ntsc-rs library defaults —
    /// Finn's dialed-in settings (2026-07-18). Reset returns here.
    private static let appNtscDefaults: [String: Any] = [
        "filter_type": 1,                       // Butterworth (sharper)
        "composite_preemphasis": 1.106,
        "composite_noise_intensity": 0.204,
        "composite_noise_frequency": 0.8576,
        "composite_noise_detail": 2,
        "snow_intensity": 0,
        "video_scanline_phase_shift_offset": 3,
        "luma_smear": 0.6692,
        // Offset must stay below height or the switch band leaves the frame
        // and the whole effect goes dead (measured: literally zero output
        // change with 6/18).
        "head_switching_height": 8,
        "head_switching_offset": 3,
        "head_switching_horizontal_shift": 41.57,
        "head_switching_mid_line_jitter": 0.181,
        "tracking_noise_height": 63,
        "ringing_power": 5.674,
        "ringing_scale": 4.935,
        "luma_noise_intensity": 0.153,
        "chroma_noise_intensity": 0.201,
        "chroma_noise_frequency": 0.0777,
        "chroma_phase_error": 0.016,
        "chroma_phase_noise_intensity": 0.029,
        "chroma_delay_horizontal": 2.667,
        "chroma_delay_vertical": 2,
        "vhs_chroma_loss": 0.124,
        // Scale artifacts with the input resolution: these effects are sized
        // in signal lines/pixels, and at 1080p+ inputs they're proportionally
        // tiny (and then further diluted by the downscale) without this.
        "scale_with_video_size": true,
        // Below 1.0 the whole signal stage lands lighter — the house look
        // was too aggressive out of the box.
        "bandwidth_scale": 0.3,                 // Horizontal scale
        "vertical_scale": 0.3,
    ]

    /// House shader tweaks per preset (vs the shaders' declared defaults).
    static let appShaderDefaults: [String: [String: Float]] = [
        "glow_gauss": ["BOOST": 1.1, "GLOW_ROLLOFF": 2.4, "BLOOM_STRENGTH": 0.1],
        "glow_lanczos": ["BOOST": 1.1, "GLOW_ROLLOFF": 2.4, "BLOOM_STRENGTH": 0.1],
    ]

    private func setUpNtsc() {
        guard let stage = NtscStage() else { return }
        ntscStage = stage
        if let descJSON = NtscStage.descriptorsJSON() {
            ntscDescriptors = NtscSetting.parse(descriptorsJSON: descJSON)
        }
        if let json = stage.settingsJSON(),
           let data = json.data(using: .utf8),
           var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict.merge(Self.appNtscDefaults) { _, ours in ours }
            ntscDefaults = dict
            ntscValues = dict
            pushNtscSettings()
        }
    }

    // MARK: - shader

    var selectedPreset: PresetEntry =
        Presets.all.first { $0.id == "glow_gauss" } ?? Presets.all[0] {
        didSet {
            if selectedPreset != oldValue {
                // Stash the outgoing preset's slider values so we can restore
                // them if the user comes back to it.
                savedParamValues[oldValue.id] = paramValues
                reloadChain()
            }
        }
    }
    private(set) var chain: LRShaderChain?
    private(set) var chainError: String?
    private(set) var paramDescriptors: [LRShaderParam] = []
    private(set) var paramValues: [String: Float] = [:]

    /// Compiled chains kept around so flipping back to a preset is instant.
    /// librashader's Metal runtime does not use the on-disk shader cache, so
    /// each `mtl_filter_chain_create` recompiles every pass — for crt-royale
    /// that's >1 second. Holding the chains in memory turns preset switching
    /// into a no-op after the first visit.
    private var chainCache: [String: LRShaderChain] = [:]
    /// Per-preset parameter values, so each preset remembers its own slider state.
    private var savedParamValues: [String: [String: Float]] = [:]

    // MARK: - render triggers

    /// Bumped when shaded pixels change (source, preset, params, downscale,
    /// shader/compare toggles) — the filter chain must re-run.
    private(set) var chainTick: Int = 0
    /// Bumped on presentation-only changes (zoom, pan, compare line) — the
    /// preview only needs to re-composite its cached chain output.
    private(set) var viewTick: Int = 0

    func markChainDirty() { chainTick &+= 1 }
    func markViewDirty() { viewTick &+= 1 }

    // MARK: - frame counter (some shaders animate by frame number)

    /// Run the preview continuously, advancing the frame counter each draw,
    /// so frame-count-dependent parameters (interlacing, animated NTSC
    /// artifacts) are visible. Off = on-demand rendering, zero idle GPU cost.
    var animatePreview: Bool = true { didSet { markChainDirty() } }

    // MARK: - export settings/state (toolbar popover)

    var exportLongEdge: Int = 1920
    var exportFormat: ExportFormat = .h264
    /// GIF gets its own size and frame rate: it's a 256-colour, poorly
    /// compressing format, so the sizes that work for MP4 produce files
    /// nothing will accept (a 1080px 5s 30fps GIF of VHS noise is ~30 MB).
    var gifWidth: Int = 480
    var gifFPS: Int = 12
    /// Round the export size to a whole multiple of the chain input, so
    /// every source line gets the same number of output rows (no scanline
    /// banding). Off = keep the exact size asked for; the exporters then
    /// supersample instead.
    var snapExportToScanlineGrid: Bool = false
    var exportQuality: ExportQuality = .high
    /// How many times an exported video plays through. 1 = once. Written as
    /// repeated passes so the file is genuinely longer — for places that
    /// don't loop video on playback.
    var exportLoopCount: Int = 1
    var exportStatus: String = ""
    var exportProgress: Double = 0
    var exportWorking: Bool = false

    /// True while an MP4 export is running. The exporter drives its own frame
    /// loop against the shared Metal queue, and librashader's Metal runtime is
    /// not thread-safe — the preview suspends animation for the duration.
    var exportInProgress: Bool = false { didSet { markChainDirty() } }

    private(set) var frameCounter: Int = 0
    func tickFrame() { frameCounter &+= 1 }

    // MARK: - init

    init(context: MetalContext, presetsRoot: URL) throws {
        self.context = context
        self.pipeline = Pipeline(context: context)
        self.presetsRoot = presetsRoot
        setUpNtsc()
        reloadChain()
    }

    // MARK: - derived

    var downscaleSpec: DownscaleSpec? {
        downscaleEnabled
            ? DownscaleSpec(width: downscaleWidth, height: downscaleHeight, method: downscaleMethod)
            : nil
    }

    /// Height (in lines) of what the shader chain actually receives — the
    /// downscale target if enabled, else the raw source. Some params
    /// (interlacing) only activate above a threshold height.
    var chainInputHeight: Int? {
        if downscaleEnabled { return downscaleHeight }
        return sourceTexture?.height
    }

    // MARK: - mutations

    @MainActor
    private func reloadSource() async {
        stopPlayback()
        sourceTexture = nil
        sourceKind = nil
        sourceError = nil
        currentFrameIndex = 0

        guard let url = sourceURL else {
            markChainDirty(); return
        }

        if isVideoURL(url) {
            do {
                let vs = try await VideoSource(url: url, device: context.device)
                sourceKind = .video(vs)
                let tex = try await vs.frame(atIndex: 0)
                sourceTexture = tex
            } catch {
                sourceError = error.localizedDescription
            }
        } else {
            do {
                let tex = try loadTexture(url: url, device: context.device)
                sourceTexture = tex
                sourceKind = .image
            } catch {
                sourceError = error.localizedDescription
            }
        }
        markChainDirty()
    }

    @MainActor
    private func reloadVideoFrame() async {
        guard let vs = videoSource else { return }
        do {
            let tex = try await vs.frame(atIndex: currentFrameIndex)
            sourceTexture = tex
            processedSourceTexture = nil    // draw re-processes on main
            // Scrubbing the transport moves the playhead too, so a keyframed
            // animation follows the frame you land on.
            applyTimeline(atFrame: currentFrameIndex)
            markChainDirty()
        } catch {
            sourceError = error.localizedDescription
        }
    }

    private func isVideoURL(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
        }
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }

    private func reloadChain() {
        // Preset switches restore stored values; that isn't a user edit.
        let previousSuppress = suppressAutoKey
        suppressAutoKey = true
        defer { suppressAutoKey = previousSuppress }

        chain = nil
        paramDescriptors = []
        paramValues = [:]

        loggedParamErrors.removeAll()

        // Cache hit: reuse the already-compiled chain. Restore the user's
        // previous slider values for this preset (or fall back to defaults).
        // The cached chain still holds the values from its last use, so the
        // restored set must be re-applied.
        if let cached = chainCache[selectedPreset.id] {
            chain = cached
            let params = dedupeByName(cached.parameters())
            paramDescriptors = params
            var values = savedParamValues[selectedPreset.id] ?? [:]
            for p in params where values[p.name] == nil {
                values[p.name] = Self.appShaderDefaults[selectedPreset.id]?[p.name] ?? p.initial
            }
            setAllParams(values)
            chainError = nil
            return
        }

        // Cache miss: compile the chain (slow for crt-royale).
        let presetURL = presetsRoot.appendingPathComponent(selectedPreset.relativePath)
        do {
            let c = try LRShaderChain(presetPath: presetURL.path,
                                      commandQueue: context.queue)
            chainCache[selectedPreset.id] = c
            chain = c
            let params = dedupeByName(c.parameters())
            paramDescriptors = params
            var initial: [String: Float] = [:]
            for p in params { initial[p.name] = p.initial }
            // House defaults, then any values remembered for this preset.
            if let house = Self.appShaderDefaults[selectedPreset.id] {
                initial.merge(house) { _, h in h }
            }
            if let saved = savedParamValues[selectedPreset.id] {
                initial.merge(saved) { _, s in s }
            }
            setAllParams(initial)
            chainError = nil
        } catch {
            chainError = error.localizedDescription
            markChainDirty()
        }
    }

    /// Multi-pass presets re-declare shared params in every pass (crt-royale
    /// reflects 460 entries for ~46 unique params). One runtime value exists
    /// per name, so keep the first declaration of each — otherwise the panel
    /// repeats the whole set per pass and ForEach gets duplicate ids.
    private func dedupeByName(_ params: [LRShaderParam]) -> [LRShaderParam] {
        var seen = Set<String>()
        return params.filter { seen.insert($0.name).inserted }
    }

    // MARK: - parameter setting

    /// Set a single parameter. The one hot path — a slider drag applies just
    /// the changed value instead of re-pushing the whole dict.
    func setParam(_ name: String, _ value: Float) {
        guard paramValues[name] != value else { return }
        paramValues[name] = value
        applyOne(name, value)
        autoKeyIfParked()
        markChainDirty()
    }

    /// Replace all parameter values (reset-all, preset switch).
    func setAllParams(_ values: [String: Float]) {
        paramValues = values
        for (name, value) in values {
            applyOne(name, value)
        }
        autoKeyIfParked()
        markChainDirty()
    }

    /// Names whose setParameter already failed, so each failure logs once
    /// instead of on every slider tick.
    private var loggedParamErrors: Set<String> = []
    private static let log = Logger(subsystem: "local.crt-app", category: "params")

    // MARK: - look files (save/load the whole visual configuration)

    enum LookError: Swift.Error, LocalizedError {
        case badFile
        var errorDescription: String? { "not a crt-app look file" }
    }

    func lookDictionary() -> [String: Any] {
        [
            "version": 1,
            "downscale": [
                "enabled": downscaleEnabled,
                "width": downscaleWidth,
                "preset": downscalePreset,
                "method": downscaleMethod.rawValue,
            ],
            "ntsc": [
                "enabled": ntscEnabled,
                "settings": ntscValues,
            ],
            "shader": [
                "enabled": shaderEnabled,
                "preset": selectedPreset.id,
                "params": paramValues.mapValues { Double($0) },
            ],
            "view": [
                "integerScale": integerScale,
                "animate": animatePreview,
                "compare": compareEnabled,
            ],
            "timeline": [
                "enabled": timelineEnabled,
                "duration": timelineDuration,
                "fps": timelineFPS,
                "keys": timelineKeys.map { k in
                    [
                        "t": k.t,
                        "easing": k.easing.rawValue,
                        "shader": k.shaderParams.mapValues { Double($0) },
                        "ntsc": k.ntscValues,
                    ] as [String: Any]
                },
            ],
        ]
    }

    func saveLook(to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: lookDictionary(),
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    func loadLook(from url: URL) throws {
        // Loading a preset writes every parameter; it must not rewrite the
        // keyframes it is in the middle of restoring.
        let previousSuppress = suppressAutoKey
        suppressAutoKey = true
        defer { suppressAutoKey = previousSuppress }

        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LookError.badFile
        }
        if let d = dict["downscale"] as? [String: Any] {
            if let v = d["enabled"] as? Bool { downscaleEnabled = v }
            if let v = d["width"] as? Int { downscaleWidth = v }
            if let v = d["preset"] as? String { downscalePreset = v } else { downscalePreset = "Custom" }
            // Old look files carried an explicit height; it is now derived
            // from the source aspect, so it is intentionally ignored.
            if let v = d["method"] as? String, let m = DownscaleMethod(rawValue: v) {
                downscaleMethod = m
            }
        }
        if let n = dict["ntsc"] as? [String: Any] {
            if let settings = n["settings"] as? [String: Any], ntscStage != nil {
                ntscValues = settings
                pushNtscSettings()
            }
            if let v = n["enabled"] as? Bool { ntscEnabled = v }
        }
        if let s = dict["shader"] as? [String: Any] {
            let params = (s["params"] as? [String: Double])?.mapValues { Float($0) } ?? [:]
            if let presetID = s["preset"] as? String,
               let preset = Presets.all.first(where: { $0.id == presetID }) {
                savedParamValues[presetID] = params
                if preset != selectedPreset {
                    selectedPreset = preset       // reloadChain restores params
                } else if !params.isEmpty {
                    setAllParams(paramValues.merging(params) { _, new in new })
                }
            }
            if let v = s["enabled"] as? Bool { shaderEnabled = v }
        }
        noteNtscSettingsEdited()
        if let v = dict["view"] as? [String: Any] {
            if let b = v["integerScale"] as? Bool { integerScale = b }
            if let b = v["animate"] as? Bool { animatePreview = b }
            if let b = v["compare"] as? Bool { compareEnabled = b }
        }
        if let t = dict["timeline"] as? [String: Any] {
            if let d = t["duration"] as? Double { timelineDuration = d }
            if let f = t["fps"] as? Int { timelineFPS = f }
            if let rawKeys = t["keys"] as? [[String: Any]] {
                timelineKeys = rawKeys.compactMap { k in
                    guard let kt = k["t"] as? Double else { return nil }
                    let easing = (k["easing"] as? String).flatMap(KeyEasing.init(rawValue:)) ?? .linear
                    let shader = (k["shader"] as? [String: Double])?.mapValues { Float($0) } ?? [:]
                    let ntsc = k["ntsc"] as? [String: Any] ?? [:]
                    return Keyframe(t: kt, easing: easing, shaderParams: shader, ntscValues: ntsc)
                }.sorted { $0.t < $1.t }
            }
            if let e = t["enabled"] as? Bool { timelineEnabled = e && timelineAvailable }
            // A preset carrying keyframes opens the timeline, whether or not
            // it was open when the preset was saved — otherwise the animation
            // is loaded but invisible, and the preset looks like it did
            // nothing.
            if !timelineKeys.isEmpty && timelineAvailable {
                timelineEnabled = true
                scrubTimeline(to: 0)
            }
        }
        markChainDirty()
    }

    private func applyOne(_ name: String, _ value: Float) {
        guard let chain else { return }
        do {
            try chain.setParameter(name, value: value)
        } catch {
            if loggedParamErrors.insert(name).inserted {
                Self.log.warning("setParameter(\(name)) failed: \(error.localizedDescription)")
            }
        }
    }
}
