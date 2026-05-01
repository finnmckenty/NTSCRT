import Foundation
import Metal
import Observation
import CrtAppBridge
import CrtCore

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
                reloadSource()
            }
        }
    }
    private(set) var sourceTexture: MTLTexture?
    private(set) var sourceError: String?

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

    private func reloadSource() {
        guard let url = sourceURL else {
            sourceTexture = nil; sourceError = nil; renderTick &+= 1; return
        }
        do {
            sourceTexture = try loadTexture(url: url, device: context.device)
            sourceError = nil
        } catch {
            sourceTexture = nil
            sourceError = error.localizedDescription
        }
        renderTick &+= 1
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
