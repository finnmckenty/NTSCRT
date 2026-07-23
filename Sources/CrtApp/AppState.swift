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
    private(set) var sourceTexture: MTLTexture?
    private(set) var sourceError: String?

    /// For video sources only: 0..<videoSource.totalFrames.
    var currentFrameIndex: Int = 0 {
        didSet {
            if currentFrameIndex != oldValue && !suppressFrameReload {
                Task { await reloadVideoFrame() }
            }
        }
    }

    // MARK: - video playback

    private(set) var videoPlaying: Bool = false
    private var playbackTask: Task<Void, Never>?
    /// Set while the playback loop advances the index itself (it fetches
    /// frames directly, so the didSet reload would double-fetch).
    private var suppressFrameReload = false

    func togglePlayback() {
        if videoPlaying { stopPlayback(); return }
        guard videoSource != nil, !exportInProgress else { return }
        videoPlaying = true
        playbackTask = Task { @MainActor [weak self] in
            while let self, self.videoPlaying, !Task.isCancelled {
                guard let vs = self.videoSource, !self.exportInProgress else {
                    self.stopPlayback(); return
                }
                let start = ContinuousClock.now
                let next = (self.currentFrameIndex + 1) % vs.totalFrames
                self.suppressFrameReload = true
                self.currentFrameIndex = next
                self.suppressFrameReload = false
                do {
                    let tex = try await vs.frame(atIndex: next)
                    self.sourceTexture = tex
                    self.tickFrame()          // VHS noise/interlace advance with the video
                    self.markChainDirty()
                } catch {
                    self.stopPlayback(); return
                }
                let frameDuration = Duration.seconds(1.0 / Double(max(1, vs.frameRate)))
                let elapsed = start.duration(to: .now)
                if elapsed < frameDuration {
                    try? await Task.sleep(for: frameDuration - elapsed)
                }
            }
        }
    }

    func stopPlayback() {
        videoPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
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

    // MARK: - VHS / ntsc-rs stage

    /// nil when the ntscrs-capi dylib wasn't found/loaded.
    private(set) var ntscStage: NtscStage?
    private(set) var ntscDescriptors: [NtscSetting] = []
    private(set) var ntscDefaults: [String: Any] = [:]
    /// Flat values in ntsc-rs preset-JSON form (includes "version").
    private(set) var ntscValues: [String: Any] = [:]
    var ntscEnabled: Bool = true { didSet { markChainDirty() } }
    private(set) var ntscError: String?

    var ntscAvailable: Bool { ntscStage != nil }

    func setNtscValue(_ name: String, _ value: Any) {
        ntscValues[name] = value
        pushNtscSettings()
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
        "filter_type": 0,                       // Constant K (blurry)
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
        markChainDirty()
    }

    /// Replace all parameter values (reset-all, preset switch).
    func setAllParams(_ values: [String: Float]) {
        paramValues = values
        for (name, value) in values {
            applyOne(name, value)
        }
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
        ]
    }

    func saveLook(to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: lookDictionary(),
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    func loadLook(from url: URL) throws {
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
        if let v = dict["view"] as? [String: Any] {
            if let b = v["integerScale"] as? Bool { integerScale = b }
            if let b = v["animate"] as? Bool { animatePreview = b }
            if let b = v["compare"] as? Bool { compareEnabled = b }
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
