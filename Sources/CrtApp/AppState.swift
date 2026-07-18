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
            if currentFrameIndex != oldValue {
                Task { await reloadVideoFrame() }
            }
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
    var downscaleWidth: Int = 256     { didSet { markChainDirty() } }
    var downscaleHeight: Int = 224    { didSet { markChainDirty() } }
    var downscaleMethod: DownscaleMethod = .area { didSet { markChainDirty() } }

    // MARK: - view (preview-only display state)

    /// Master shader on/off toggle. When false, the preview shows the source
    /// (or downscaled source) without any CRT shader applied.
    var shaderEnabled: Bool = true { didSet { markChainDirty() } }

    /// Compare mode: split the preview with a draggable vertical line —
    /// shader-on on one side, shader-off on the other.
    /// Chain-dirty: toggling on must populate the secondary target.
    var compareEnabled: Bool = false { didSet { markChainDirty() } }
    /// Normalised x-position of the compare line, 0..1.
    var compareLineX: Float = 0.5 { didSet { markViewDirty() } }

    /// Integer scale: size the render target to a whole-number multiple of
    /// the chain input (RetroArch's "Integer Scale"), letterboxed in the
    /// preview. Gives uniform scanline/mask structure — non-integer scales
    /// visually dilute beam-shape and scanline params.
    var integerScale: Bool = false { didSet { markChainDirty() } }

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

    // MARK: - shader

    var selectedPreset: PresetEntry = Presets.all[0] {
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
    var animatePreview: Bool = false { didSet { markChainDirty() } }

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
            for p in params where values[p.name] == nil { values[p.name] = p.initial }
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
