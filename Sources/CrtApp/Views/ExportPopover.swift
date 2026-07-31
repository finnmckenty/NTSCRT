import SwiftUI
import AppKit
import Metal
import UniformTypeIdentifiers
import CrtCore

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

/// Export settings + action, shown from the toolbar Export button. Settings
/// and progress live in AppState so they survive the popover closing —
/// the toolbar button shows live progress while an export runs.
struct ExportPopover: View {
    @Environment(AppState.self) private var state

    private var isVideo: Bool { state.videoSource != nil }

    private var computedBitrate: Int {
        let size = outputSize
        let fps = state.videoSource.map { Double($0.frameRate) } ?? Double(state.timelineFPS)
        return max(2_000_000, Int(Double(size.width * size.height) * fps * state.exportQuality.bitsPerPixel))
    }

    /// Output size derived from the requested long edge and the source aspect.
    /// Even values are required by H.264; the rounding clamps that.
    private var outputSize: (width: Int, height: Int) {
        let aspect = state.sourceAspect
        let longEdge = state.exportLongEdge
        let w: Int, h: Int
        if aspect >= 1 {
            w = longEdge
            h = max(64, Int((Double(longEdge) / Double(aspect)).rounded()))
        } else {
            h = longEdge
            w = max(64, Int((Double(longEdge) * Double(aspect)).rounded()))
        }
        return snapped(width: w & ~1, height: h & ~1)
    }

    /// With snapping on, round onto the scanline grid (see ScanlineGrid).
    private func snapped(width: Int, height: Int) -> (width: Int, height: Int) {
        guard state.snapExportToScanlineGrid else { return (width, height) }
        let input = state.chainInputSize
        guard input.width > 0, input.height > 0 else { return (width, height) }
        let s = ScanlineGrid.snappedSize(inputWidth: input.width,
                                         inputHeight: input.height,
                                         targetHeight: height)
        return (s.width & ~1, s.height & ~1)
    }

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            Text(isVideo ? "Export video" : "Export image")
                .font(.headline)

            Stepper("Long edge \(state.exportLongEdge) px",
                    value: $state.exportLongEdge, in: 64...8192, step: 64)
                .font(.caption)

            let size = outputSize
            Text("Output: \(size.width) × \(size.height) px (matches source aspect)")
                .font(.caption).foregroundStyle(.secondary)

            if !isVideo {
                Button(state.exportWorking ? "Exporting…" : "Export PNG…") { exportPNG() }
                    .disabled(state.sourceTexture == nil || state.chain == nil || state.exportWorking)

                Divider()

                Text(hasKeyframes ? "Video from this image (keyframe animation)"
                                  : "Video from this image (VHS motion)")
                    .font(.caption).bold()
                // Length belongs to the timeline — one source of truth, set
                // where you can see the keyframes. GIF brings its own frame
                // rate, so don't advertise the timeline's here.
                Text(state.exportFormat.isGIF
                     ? String(format: "%.1f s — set in the Timeline", state.timelineDuration)
                     : String(format: "%.1f s at %d fps — set in the Timeline",
                              state.timelineDuration, state.timelineFPS))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Text("Format").font(.caption)
                Picker("", selection: $state.exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            if !state.exportFormat.isGIF {
                HStack(spacing: 6) {
                    Text("Loop").font(.caption)
                    IntField(value: $state.exportLoopCount, range: 1...100, width: 44)
                    Text(state.exportLoopCount == 1 ? "× (plays once)"
                                                    : "× (\(loopedLengthText))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tooltip("Repeat the content this many times in the exported file, so it runs longer somewhere that won't loop it for you. 1 plays through once. GIFs loop forever on their own, so this doesn't apply to them.")
            }

            Toggle("Snap size to scanline grid", isOn: $state.snapExportToScanlineGrid)
                .toggleStyle(.checkbox)
                .font(.caption)
                .tooltip("Round the output so every source line gets the same whole number of rows — the sizes where scanlines land perfectly even. Off, the exporter renders larger and averages down instead, which keeps your exact dimensions.")

            if state.exportFormat.isGIF {
                gifControls
            } else if !state.exportFormat.isProRes {
                HStack {
                    Text("Quality").font(.caption)
                    Picker("", selection: $state.exportQuality) {
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

            Button(buttonLabel) {
                if state.exportFormat.isGIF { exportGIF() }
                else if isVideo { exportMP4() }
                else { exportStillVideo() }
            }
            .disabled(state.sourceTexture == nil || state.chain == nil || state.exportWorking)

            if state.exportWorking {
                ProgressView(value: state.exportProgress)
                    .progressViewStyle(.linear)
            }

            if !state.exportStatus.isEmpty {
                Text(state.exportStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    /// "18-07-26 17.42.09" — date + time so repeated exports don't collide.
    private var exportTimestamp: String {
        let f = DateFormatter()
        f.dateFormat = "dd-MM-yy HH.mm.ss"
        return f.string(from: Date())
    }

    /// Length of the export once looped, for the field's caption.
    private var loopedLengthText: String {
        let once = state.videoSource != nil
            ? state.effectiveTimelineDuration
            : state.timelineDuration
        let total = once * Double(max(1, state.exportLoopCount))
        return total >= 60
            ? String(format: "%d:%04.1f total", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
            : String(format: "%.1f s total", total)
    }

    private var hasKeyframes: Bool {
        state.timelineEnabled && !state.timelineKeys.isEmpty
    }

    /// Per-frame keyframe values for a video export, or nil when nothing is
    /// keyed (then the whole clip uses the current settings, as before).
    private var videoFrameParams: (@Sendable (Int, Int) -> (shader: [String: Float]?, ntscJSON: String?))? {
        guard hasKeyframes, let ev = state.makeTimelineEvaluator() else { return nil }
        return { i, total in
            let t = total > 1 ? Double(i) / Double(total - 1) : 0
            return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t))
        }
    }

    private var buttonLabel: String {
        if state.exportWorking { return "Exporting…" }
        let name = state.exportFormat.buttonName
        if state.exportFormat.isGIF { return "Export GIF…" }
        return isVideo ? "Export \(name)…" : "Export video (\(name))…"
    }

    // MARK: - GIF controls

    /// GIF gets its own width and frame rate — the video settings produce
    /// files nothing will accept (see GifExporter).
    private var gifControls: some View {
        @Bindable var state = state
        let size = gifSize
        let frames = gifFrameCount
        let bytes = GifExporter.estimatedBytes(width: size.width, height: size.height, frames: frames)
        let trueFPS = GifExporter.trueFPS(for: state.gifFPS)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Width").font(.caption)
                IntField(value: $state.gifWidth, range: 64...4096, width: 56)
                Text("px").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $state.gifFPS) {
                    ForEach([6, 12, 24, 30], id: \.self) { f in
                        Text("\(f) fps").tag(f)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .tooltip("GIF size and frame rate. Height follows the source aspect ratio. Length comes from the timeline.")

            Text("\(size.width) × \(size.height) px  ·  \(frames) frames  ·  ≈ \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(bytes > 10_000_000 ? .orange : .secondary)

            if bytes > 10_000_000 {
                Text("Most platforms cap GIFs around 10–15 MB. Drop the width or frame rate.")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("GIF is 256 colours and compresses noise badly, so size climbs fast. Estimate assumes a noisy look; clean ones come in under.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if abs(trueFPS - Double(state.gifFPS)) > 0.2 {
                // GIF delays are whole hundredths of a second, so the rate
                // lands on that grid rather than exactly where asked.
                Text(String(format: "Plays at %.1f fps (GIF timing grid).", trueFPS))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// GIF output size: chosen width, height from the source aspect, both even.
    private var gifSize: (width: Int, height: Int) {
        let w = max(64, state.gifWidth)
        let h = max(64, Int((Double(w) / Double(state.sourceAspect)).rounded()))
        return snapped(width: w & ~1, height: h & ~1)
    }

    private var gifFrameCount: Int {
        if let vs = state.videoSource {
            let seconds = Double(vs.totalFrames) / Double(max(1, vs.frameRate))
            return max(1, Int((seconds * Double(state.gifFPS)).rounded(.down)))
        }
        return max(1, Int((state.timelineDuration * Double(state.gifFPS)).rounded()))
    }

    // MARK: - PNG (image source)

    private func exportPNG() {
        guard let source = state.sourceTexture, let chain = state.chain else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "crt export \(exportTimestamp).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let size = outputSize
        state.exportWorking = true
        state.exportStatus = "Rendering…"

        let device = state.context.device
        let queue = state.context.queue
        guard let target = makeRenderTarget(device: device, width: size.width, height: size.height),
              let staging = makeStagingTexture(device: device, width: size.width, height: size.height),
              let cb = queue.makeCommandBuffer() else {
            state.exportStatus = "Failed to allocate textures"
            state.exportWorking = false
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
            // Same scanline-banding guard the video/GIF paths use.
            if let supersample = SupersampledPass.make(device: device,
                                                       chainInput: state.chainInputSize,
                                                       target: (size.width, size.height)) {
                try supersample.encode(into: cb, pipeline: state.pipeline, chain: chain,
                                       inputTexture: input, outputTexture: target,
                                       downscale: spec, frameCount: state.frameCounter)
            } else {
                try state.pipeline.encode(into: cb,
                                          chain: chain,
                                          inputTexture: input,
                                          outputTexture: target,
                                          downscale: spec,
                                          frameCount: state.frameCounter)
            }
        } catch {
            state.exportStatus = "Render failed: \(error.localizedDescription)"
            state.exportWorking = false
            return
        }

        guard let blit = cb.makeBlitCommandEncoder() else {
            state.exportStatus = "Blit encoder failed"; state.exportWorking = false; return
        }
        blit.copy(from: target,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size.width, height: size.height, depth: 1),
                  to: staging,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        // Discrete-GPU Macs: managed staging needs an explicit synchronize
        // for the CPU to see the GPU's blit (no-op case skipped on unified
        // memory, where staging is .shared; synchronize is illegal there).
        if staging.storageMode == .managed {
            blit.synchronize(resource: staging)
        }
        blit.endEncoding()

        cb.addCompletedHandler { _ in
            DispatchQueue.main.async {
                do {
                    let cg = try makeCGImage(from: staging)
                    try writePNG(cg, to: url)
                    state.exportStatus = "Wrote \(url.lastPathComponent) (\(size.width) × \(size.height))"
                } catch {
                    state.exportStatus = "Write failed: \(error.localizedDescription)"
                }
                state.exportWorking = false
            }
        }
        cb.commit()
    }

    // MARK: - GIF (still or video source)

    private func exportGIF() {
        guard let source = state.sourceTexture, state.chain != nil else { return }
        let preset = state.presetsRoot.appendingPathComponent(state.selectedPreset.relativePath)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "crt export \(exportTimestamp).gif"
        guard panel.runModal() == .OK, let outURL = panel.url else { return }

        let size = gifSize
        state.exportWorking = true
        state.exportProgress = 0
        state.exportStatus = "Encoding GIF…"
        state.stopPlayback()
        state.stopTimelinePreview()
        state.exportInProgress = true

        let exporter = GifExporter(context: state.context)
        let settings = GifExporter.Settings(
            outputURL: outURL,
            width: size.width,
            height: size.height,
            fps: state.gifFPS,
            downscale: state.downscaleSpec,
            presetPath: preset.path
        )
        let params = state.paramValues
        let ntscJSON: String? = (state.ntscEnabled && state.ntscAvailable)
            ? state.ntscStage?.settingsJSON()
            : nil
        let videoSource = state.videoSource
        // GIFs loop forever by themselves, so the animation spans the whole
        // file rather than repeating in passes.
        let totalFrames = gifFrameCount
        let evaluator = hasKeyframes ? state.makeTimelineEvaluator() : nil
        let frameParams: (@Sendable (Int, Int) -> (shader: [String: Float]?, ntscJSON: String?))? =
            evaluator.map { ev in
                { i, total in
                    let t = total > 1 ? Double(i) / Double(total - 1) : 0
                    return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t))
                }
            }
        let state = state

        Task {
            do {
                if let vs = videoSource {
                    try await exporter.exportVideo(source: vs, paramValues: params,
                                                   settings: settings,
                                                   ntscSettingsJSON: ntscJSON,
                                                   frameParams: videoFrameParams) { p in
                        Task { @MainActor in state.exportProgress = p }
                    }
                } else {
                    try await exporter.exportStill(source: source,
                                                   totalFrames: totalFrames,
                                                   paramValues: params,
                                                   settings: settings,
                                                   ntscSettingsJSON: ntscJSON,
                                                   frameParams: frameParams) { p in
                        Task { @MainActor in state.exportProgress = p }
                    }
                }
                let bytes = (try? FileManager.default
                    .attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
                let sizeText = ByteCountFormatter.string(fromByteCount: Int64(bytes ?? 0),
                                                         countStyle: .file)
                await MainActor.run {
                    state.exportStatus = "Wrote \(outURL.lastPathComponent) (\(size.width) × \(size.height), \(sizeText))"
                    state.exportWorking = false
                    state.exportProgress = 1
                    state.exportInProgress = false
                }
            } catch {
                await MainActor.run {
                    state.exportStatus = "GIF export failed: \(error.localizedDescription)"
                    state.exportWorking = false
                    state.exportInProgress = false
                }
            }
        }
    }

    // MARK: - video from a still (VHS motion / keyframe animation)

    private func exportStillVideo() {
        guard let source = state.sourceTexture, state.chain != nil else { return }
        let preset = state.presetsRoot.appendingPathComponent(state.selectedPreset.relativePath)
        let codec = state.exportFormat.codec ?? .h264

        let panel = NSSavePanel()
        panel.allowedContentTypes = [codec.isProRes ? .quickTimeMovie : .mpeg4Movie]
        panel.nameFieldStringValue = "crt export \(exportTimestamp).\(codec.fileExtension)"
        guard panel.runModal() == .OK, let outURL = panel.url else { return }

        let size = outputSize
        state.exportWorking = true
        state.exportProgress = 0
        state.exportStatus = "Encoding…"
        state.stopTimelinePreview()
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
        let baseFrames = state.timelineTotalFrames
        let loops = max(1, state.exportLoopCount)
        let totalFrames = baseFrames * loops
        let fps = state.timelineFPS

        // Keyframes drive per-frame parameters; without keys the params hold
        // and only the frame-seeded VHS noise animates.
        let evaluator = hasKeyframes ? state.makeTimelineEvaluator() : nil
        let frameParams: (@Sendable (Int, Int) -> (shader: [String: Float]?, ntscJSON: String?))? =
            evaluator.map { ev in
                { i, _ in
                    // Phase within the pass, so each loop replays the
                    // animation instead of stretching it across all passes.
                    let within = i % baseFrames
                    let t = baseFrames > 1 ? Double(within) / Double(baseFrames - 1) : 0
                    return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t))
                }
            }
        let state = state

        Task {
            do {
                try await exporter.exportStill(source: source,
                                               totalFrames: totalFrames,
                                               fps: fps,
                                               paramValues: params,
                                               settings: settings,
                                               ntscSettingsJSON: ntscJSON,
                                               frameParams: frameParams) { p in
                    Task { @MainActor in state.exportProgress = p }
                }
                await MainActor.run {
                    state.exportStatus = "Wrote \(outURL.lastPathComponent) (\(size.width) × \(size.height))"
                    state.exportWorking = false
                    state.exportProgress = 1
                    state.exportInProgress = false
                }
            } catch {
                await MainActor.run {
                    state.exportStatus = "Export failed: \(error.localizedDescription)"
                    state.exportWorking = false
                    state.exportInProgress = false
                }
            }
        }
    }

    // MARK: - MP4 (video source)

    private func exportMP4() {
        guard let vs = state.videoSource else { return }
        let preset = state.presetsRoot.appendingPathComponent(state.selectedPreset.relativePath)
        let codec = state.exportFormat.codec ?? .h264

        let panel = NSSavePanel()
        panel.allowedContentTypes = [codec.isProRes ? .quickTimeMovie : .mpeg4Movie]
        panel.nameFieldStringValue = "crt export \(exportTimestamp).\(codec.fileExtension)"
        guard panel.runModal() == .OK, let outURL = panel.url else { return }

        let size = outputSize
        state.exportWorking = true
        state.exportProgress = 0
        state.exportStatus = "Encoding…"
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
        let state = state

        Task {
            do {
                try await exporter.export(source: vs, paramValues: params,
                                          settings: settings,
                                          ntscSettingsJSON: ntscJSON,
                                          frameParams: videoFrameParams) { p in
                    Task { @MainActor in state.exportProgress = p }
                }
                await MainActor.run {
                    state.exportStatus = "Wrote \(outURL.lastPathComponent) (\(size.width) × \(size.height))"
                    state.exportWorking = false
                    state.exportProgress = 1
                    state.exportInProgress = false
                }
            } catch {
                await MainActor.run {
                    state.exportStatus = "Export failed: \(error.localizedDescription)"
                    state.exportWorking = false
                    state.exportInProgress = false
                }
            }
        }
    }
}
