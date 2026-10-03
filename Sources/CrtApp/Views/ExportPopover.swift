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

    // Sizes and bitrate come from AppState, shared with the Howlaround panel.
    private var computedBitrate: Int { state.exportBitrate(for: outputSize) }
    private var outputSize: (width: Int, height: Int) { state.exportVideoSize }


    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            Text(isVideo ? "Export video" : "Export image")
                .font(.headline)

            // The options themselves are shared with the Screen Loop
            // panel (ExportOptions.swift) — one source of truth.
            ExportSizeOptions()

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

            ExportVideoOptions(lengthSeconds: isVideo ? state.effectiveTimelineDuration
                                                      : state.timelineDuration)

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

    private var hasKeyframes: Bool {
        state.timelineEnabled && !state.timelineKeys.isEmpty
    }

    /// Per-frame keyframe values for a video export, or nil when nothing is
    /// keyed (then the whole clip uses the current settings, as before).
    private var videoFrameParams: FrameParams? {
        guard hasKeyframes, let ev = state.makeTimelineEvaluator() else { return nil }
        let glitchBase = state.glitchValues
        return { i, total in
            let t = total > 1 ? Double(i) / Double(total - 1) : 0
            return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t),
                    glitch: ev.glitchSettings(at: t, base: glitchBase))
        }
    }

    private var buttonLabel: String {
        if state.exportWorking { return "Exporting…" }
        let name = state.exportFormat.buttonName
        if state.exportFormat.isGIF { return "Export GIF…" }
        return isVideo ? "Export \(name)…" : "Export video (\(name))…"
    }

    /// GIF output size: chosen width, height from the source aspect, both even.
    private var gifSize: (width: Int, height: Int) { state.exportGifSize }

    private var gifFrameCount: Int {
        if let vs = state.videoSource {
            let seconds = Double(vs.totalFrames) / Double(max(1, vs.frameRate))
            return max(1, Int((seconds * Double(state.gifFPS)).rounded(.down)))
        }
        return max(1, Int((state.timelineDuration * Double(state.gifFPS)).rounded()))
    }

    // MARK: - PNG (image source)

    private func exportPNG() {
        guard state.sourceTexture != nil else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "crt export \(exportTimestamp).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // The render itself lives in AppState so the headless export check
        // drives exactly what this button does.
        state.exportPNG(to: url, size: outputSize)
    }

    // MARK: - GIF (still or video source)

    private func exportGIF() {
        guard let source = state.sourceTexture, state.chain != nil else { return }

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
        let settings = state.gifExportSettings(outputURL: outURL, size: size)
        let params = state.paramValues
        let ntscJSON: String? = (state.ntscEnabled && state.ntscAvailable)
            ? state.ntscStage?.settingsJSON()
            : nil
        let videoSource = state.videoSource
        // GIFs loop forever by themselves, so the animation spans the whole
        // file rather than repeating in passes.
        let totalFrames = gifFrameCount
        let evaluator = hasKeyframes ? state.makeTimelineEvaluator() : nil
        let glitchBase = state.glitchValues
        let frameParams: FrameParams? =
            evaluator.map { ev in
                { i, total in
                    let t = total > 1 ? Double(i) / Double(total - 1) : 0
                    return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t),
                            glitch: ev.glitchSettings(at: t, base: glitchBase))
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
        let settings = state.mp4ExportSettings(route: .still, outputURL: outURL, size: size,
                                               bitrate: computedBitrate, codec: codec)
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
        let glitchBase = state.glitchValues
        let frameParams: FrameParams? =
            evaluator.map { ev in
                { i, _ in
                    // Phase within the pass, so each loop replays the
                    // animation instead of stretching it across all passes.
                    let within = i % baseFrames
                    let t = baseFrames > 1 ? Double(within) / Double(baseFrames - 1) : 0
                    return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t),
                            glitch: ev.glitchSettings(at: t, base: glitchBase))
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
        let settings = state.mp4ExportSettings(route: .video, outputURL: outURL, size: size,
                                               bitrate: computedBitrate, codec: codec)
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
