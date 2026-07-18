import SwiftUI
import AppKit
import Metal
import UniformTypeIdentifiers
import CrtCore

struct ExportPanel: View {
    @Environment(AppState.self) private var state

    @State private var longEdge: Int = 1920
    @State private var status: String = ""
    @State private var working: Bool = false
    @State private var progress: Double = 0

    private var isVideo: Bool { state.videoSource != nil }

    /// Output size derived from the requested long edge and the source aspect.
    /// Even values are required by H.264; the rounding clamps that.
    private var outputSize: (width: Int, height: Int) {
        let aspect = state.sourceAspect
        let w: Int, h: Int
        if aspect >= 1 {
            w = longEdge
            h = max(64, Int((Double(longEdge) / Double(aspect)).rounded()))
        } else {
            h = longEdge
            w = max(64, Int((Double(longEdge) * Double(aspect)).rounded()))
        }
        return (w & ~1, h & ~1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export").font(.headline)

            HStack {
                Stepper("Long edge \(longEdge) px", value: $longEdge, in: 64...8192, step: 64)
            }
            .font(.caption)

            let size = outputSize
            Text("Output: \(size.width) × \(size.height) px (matches source aspect)")
                .font(.caption).foregroundStyle(.secondary)

            Button(buttonLabel) {
                if isVideo { exportMP4() } else { exportPNG() }
            }
            .disabled(state.sourceTexture == nil || state.chain == nil || working)

            if working && isVideo {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttonLabel: String {
        if working { return isVideo ? "Exporting MP4…" : "Exporting PNG…" }
        return isVideo ? "Export MP4…" : "Export PNG…"
    }

    // MARK: - PNG (image source)

    private func exportPNG() {
        guard let source = state.sourceTexture, let chain = state.chain else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "crt-output.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let size = outputSize
        working = true
        status = "Rendering…"

        let device = state.context.device
        let queue = state.context.queue
        guard let target = makeRenderTarget(device: device, width: size.width, height: size.height),
              let staging = makeStagingTexture(device: device, width: size.width, height: size.height),
              let cb = queue.makeCommandBuffer() else {
            status = "Failed to allocate textures"
            working = false
            return
        }

        do {
            var input = source
            var spec = state.downscaleSpec
            if state.ntscEnabled, let stage = state.ntscStage {
                input = try state.pipeline.prepareChainInput(
                    source: source, downscale: spec,
                    ntsc: stage, frameCount: state.frameCounter)
                spec = nil
            }
            try state.pipeline.encode(into: cb,
                                      chain: chain,
                                      inputTexture: input,
                                      outputTexture: target,
                                      downscale: spec,
                                      frameCount: state.frameCounter)
        } catch {
            status = "Render failed: \(error.localizedDescription)"
            working = false
            return
        }

        guard let blit = cb.makeBlitCommandEncoder() else {
            status = "Blit encoder failed"; working = false; return
        }
        blit.copy(from: target,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size.width, height: size.height, depth: 1),
                  to: staging,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        cb.addCompletedHandler { _ in
            DispatchQueue.main.async {
                do {
                    let cg = try makeCGImage(from: staging)
                    try writePNG(cg, to: url)
                    status = "Wrote \(url.lastPathComponent) (\(size.width) × \(size.height))"
                } catch {
                    status = "Write failed: \(error.localizedDescription)"
                }
                working = false
            }
        }
        cb.commit()
    }

    // MARK: - MP4 (video source)

    private func exportMP4() {
        guard let vs = state.videoSource else { return }
        let preset = state.presetsRoot.appendingPathComponent(state.selectedPreset.relativePath)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "crt-output.mp4"
        guard panel.runModal() == .OK, let outURL = panel.url else { return }

        let size = outputSize
        working = true
        progress = 0
        status = "Encoding…"
        // Suspend preview animation for the duration: the exporter drives the
        // same Metal queue from its own loop and librashader's Metal runtime
        // is not thread-safe.
        state.exportInProgress = true

        let exporter = Mp4Exporter(context: state.context)
        let settings = Mp4Exporter.Settings(
            outputURL: outURL,
            outputWidth: size.width,
            outputHeight: size.height,
            downscale: state.downscaleSpec,
            presetPath: preset.path
        )
        let params = state.paramValues
        let ntscJSON: String? = (state.ntscEnabled && state.ntscAvailable)
            ? state.ntscStage?.settingsJSON()
            : nil

        Task {
            do {
                try await exporter.export(source: vs, paramValues: params,
                                          settings: settings,
                                          ntscSettingsJSON: ntscJSON) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run {
                    self.status = "Wrote \(outURL.lastPathComponent) (\(size.width) × \(size.height))"
                    self.working = false
                    self.progress = 1
                    state.exportInProgress = false
                }
            } catch {
                await MainActor.run {
                    self.status = "Export failed: \(error.localizedDescription)"
                    self.working = false
                    state.exportInProgress = false
                }
            }
        }
    }
}
