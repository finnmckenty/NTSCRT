import SwiftUI
import AppKit
import Metal
import UniformTypeIdentifiers
import CrtCore

struct ExportPanel: View {
    @Environment(AppState.self) private var state

    /// Quality tiers as bits-per-pixel-per-frame; actual bitrate scales with
    /// resolution and frame rate. CRT output is worst-case for codecs (full-
    /// frame high-frequency scanlines + animated noise), so these run higher
    /// than typical camera-footage rates.
    enum ExportQuality: String, CaseIterable {
        case standard = "Standard"
        case high = "High"
        case veryHigh = "Very high"
        case maximum = "Maximum"

        var bitsPerPixel: Double {
            switch self {
            case .standard: return 0.12
            case .high: return 0.25
            case .veryHigh: return 0.5
            case .maximum: return 1.0
            }
        }
    }

    @State private var longEdge: Int = 1920
    @State private var status: String = ""
    @State private var working: Bool = false
    @State private var progress: Double = 0
    @State private var codec: Mp4Exporter.Codec = .h264
    @State private var quality: ExportQuality = .high

    private var isVideo: Bool { state.videoSource != nil }

    private var computedBitrate: Int {
        let size = outputSize
        let fps = Double(state.videoSource?.frameRate ?? 30)
        return max(2_000_000, Int(Double(size.width * size.height) * fps * quality.bitsPerPixel))
    }

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

    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Twirl(expanded: $expanded)
                Text("Export").font(.headline)
            }

            if expanded {
            HStack {
                Stepper("Long edge \(longEdge) px", value: $longEdge, in: 64...8192, step: 64)
            }
            .font(.caption)

            let size = outputSize
            Text("Output: \(size.width) × \(size.height) px (matches source aspect)")
                .font(.caption).foregroundStyle(.secondary)

            if isVideo {
                HStack {
                    Text("Codec").font(.caption)
                    Picker("", selection: $codec) {
                        ForEach(Mp4Exporter.Codec.allCases, id: \.self) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if !codec.isProRes {
                    HStack {
                        Text("Quality").font(.caption)
                        Picker("", selection: $quality) {
                            ForEach(ExportQuality.allCases, id: \.self) { q in
                                Text(q.rawValue).tag(q)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        Spacer()
                        Text(String(format: "≈ %.1f Mbps", Double(computedBitrate) / 1_000_000))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("Scanline detail is brutal on codecs — use High or above, or ProRes for editing.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "18-07-26 17.42.09" — date + time so repeated exports don't collide.
    private var exportTimestamp: String {
        let f = DateFormatter()
        f.dateFormat = "dd-MM-yy HH.mm.ss"
        return f.string(from: Date())
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
        panel.nameFieldStringValue = "crt export \(exportTimestamp).png"
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
        // Intel Mac: .shared storage needs explicit synchronize for CPU to see GPU writes.
        let sync = cb.makeBlitCommandEncoder()!
        sync.synchronize(resource: staging)
        sync.endEncoding()

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
        panel.allowedContentTypes = [codec.isProRes ? .quickTimeMovie : .mpeg4Movie]
        panel.nameFieldStringValue = "crt export \(exportTimestamp).\(codec.fileExtension)"
        guard panel.runModal() == .OK, let outURL = panel.url else { return }

        let size = outputSize
        working = true
        progress = 0
        status = "Encoding…"
        // Suspend preview animation and playback for the duration: the
        // exporter drives the same Metal queue from its own loop and
        // librashader's Metal runtime is not thread-safe.
        state.stopPlayback()
        state.exportInProgress = true

        let exporter = Mp4Exporter(context: state.context)
        let settings = Mp4Exporter.Settings(
            outputURL: outURL,
            outputWidth: size.width,
            outputHeight: size.height,
            downscale: state.downscaleSpec,
            presetPath: preset.path,
            codec: codec,
            averageBitrate: computedBitrate
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
