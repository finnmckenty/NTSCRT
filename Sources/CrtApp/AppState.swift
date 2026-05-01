import Foundation
import Metal
import Observation
import UniformTypeIdentifiers
import CrtAppBridge
import CrtCore

enum SourceKind {
    case image
    case video(VideoSource)
}

/// Single source of truth for the running app.
///
/// Owns the Metal context, the render pipeline, the active source/preset, and
/// the parameter slider values. Mutations bump `renderTick` so PreviewView
/// knows to redraw.
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

    var downscaleEnabled: Bool = true { didSet { renderTick &+= 1 } }
    var downscaleWidth: Int = 256     { didSet { renderTick &+= 1 } }
    var downscaleHeight: Int = 224    { didSet { renderTick &+= 1 } }
    var downscaleMethod: DownscaleMethod = .area { didSet { renderTick &+= 1 } }

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
    var paramValues: [String: Float] = [:] { didSet { applyParams(); renderTick &+= 1 } }

    /// Compiled chains kept around so flipping back to a preset is instant.
    /// librashader's Metal runtime does not use the on-disk shader cache, so
    /// each `mtl_filter_chain_create` recompiles every pass — for crt-royale
    /// that's >1 second. Holding the chains in memory turns preset switching
    /// into a no-op after the first visit.
    private var chainCache: [String: LRShaderChain] = [:]
    /// Per-preset parameter values, so each preset remembers its own slider state.
    private var savedParamValues: [String: [String: Float]] = [:]

    // MARK: - render trigger

    /// Bumped on any state mutation that should cause the preview to redraw.
    var renderTick: Int = 0

    // MARK: - frame counter (some shaders animate by frame number)

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

    // MARK: - mutations

    @MainActor
    private func reloadSource() async {
        sourceTexture = nil
        sourceKind = nil
        sourceError = nil
        currentFrameIndex = 0

        guard let url = sourceURL else {
            renderTick &+= 1; return
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
        renderTick &+= 1
    }

    @MainActor
    private func reloadVideoFrame() async {
        guard let vs = videoSource else { return }
        do {
            let tex = try await vs.frame(atIndex: currentFrameIndex)
            sourceTexture = tex
            renderTick &+= 1
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

        // Cache hit: reuse the already-compiled chain. Restore the user's
        // previous slider values for this preset (or fall back to defaults).
        if let cached = chainCache[selectedPreset.id] {
            chain = cached
            let params = cached.parameters()
            paramDescriptors = params
            var values = savedParamValues[selectedPreset.id] ?? [:]
            for p in params where values[p.name] == nil { values[p.name] = p.initial }
            paramValues = values
            chainError = nil
            renderTick &+= 1
            return
        }

        // Cache miss: compile the chain (slow for crt-royale).
        let presetURL = presetsRoot.appendingPathComponent(selectedPreset.relativePath)
        do {
            let c = try LRShaderChain(presetPath: presetURL.path,
                                      commandQueue: context.queue)
            chainCache[selectedPreset.id] = c
            chain = c
            let params = c.parameters()
            paramDescriptors = params
            var initial: [String: Float] = [:]
            for p in params { initial[p.name] = p.initial }
            paramValues = initial
            chainError = nil
        } catch {
            chainError = error.localizedDescription
        }
        renderTick &+= 1
    }

    private func applyParams() {
        guard let chain else { return }
        for (name, value) in paramValues {
            try? chain.setParameter(name, value: value)
        }
    }
}
