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

    // MARK: - downscale

    var downscaleEnabled: Bool = true { didSet { renderTick &+= 1 } }
    var downscaleWidth: Int = 256     { didSet { renderTick &+= 1 } }
    var downscaleHeight: Int = 224    { didSet { renderTick &+= 1 } }
    var downscaleMethod: DownscaleMethod = .area { didSet { renderTick &+= 1 } }

    // MARK: - shader

    var selectedPreset: PresetEntry = Presets.all[0] {
        didSet {
            if selectedPreset != oldValue { reloadChain() }
        }
    }
    private(set) var chain: LRShaderChain?
    private(set) var chainError: String?
    private(set) var paramDescriptors: [LRShaderParam] = []
    var paramValues: [String: Float] = [:] { didSet { applyParams(); renderTick &+= 1 } }

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
        let presetURL = presetsRoot.appendingPathComponent(selectedPreset.relativePath)
        do {
            let c = try LRShaderChain(presetPath: presetURL.path,
                                      commandQueue: context.queue)
            chain = c
            let params = c.parameters()
            paramDescriptors = params
            var initial: [String: Float] = [:]
            for p in params { initial[p.name] = p.initial }
            paramValues = initial   // didSet runs applyParams() with chain already set above
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
