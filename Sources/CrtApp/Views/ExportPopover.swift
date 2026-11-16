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
    private var outputSize: (width: Int, height: Int) { state.exportVideoSize }


    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            Text("Export")
                .font(.headline)

            // The options themselves are shared with the Screen Loop
            // panel (ExportOptions.swift) — one source of truth.
            ExportSizeOptions()

            // A PNG is always on offer: the picture, or a clip's frame under
            // the playhead.
            HStack(spacing: 8) {
                Button(state.exportWorking ? "Exporting…" : "Export PNG…") { exportPNG() }
                    .disabled(state.sourceTexture == nil || state.chain == nil || state.exportWorking)
                if isVideo {
                    Text("This frame (\(frameTime))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            if isVideo {
                Text(String(format: "The whole clip (%.1f s)", state.effectiveTimelineDuration))
                    .font(.caption).bold()
            } else {
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
                exportMovie()
            }
            .disabled(state.sourceTexture == nil || state.chain == nil || state.exportWorking)

            Divider()

            // Last and set apart: it ignores the size above and copies the
            // preview as drawn — scanlines at screen pixels, zoom and all.
            Text("The viewport").font(.caption).bold()
            HStack(spacing: 8) {
                Button("Export viewport…") { exportViewport() }
                    .disabled(state.sourceTexture == nil || state.exportWorking)
                Text(viewportCaption)
                    .font(.caption).foregroundStyle(.secondary)
            }

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

    /// Where the playhead is in a clip, "0:05.12".
    private var frameTime: String {
        let fps = Double(max(1, state.videoSource?.frameRate ?? 1))
        let t = Double(state.currentFrameIndex) / fps
        return String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    /// "18-07-26 17.42.09" — date + time so repeated exports don't collide.
    private var exportTimestamp: String {
        let f = DateFormatter()
        f.dateFormat = "dd-MM-yy HH.mm.ss"
        return f.string(from: Date())
    }

    private var hasKeyframes: Bool { state.hasTimelineKeys }

    private var buttonLabel: String {
        if state.exportWorking { return "Exporting…" }
        let name = state.exportFormat.buttonName
        if state.exportFormat.isGIF { return "Export GIF…" }
        return isVideo ? "Export \(name)…" : "Export video (\(name))…"
    }

    // MARK: - PNG (an image, or a clip's current frame)

    private func exportPNG() {
        guard state.sourceTexture != nil else { return }
        // A clip holds still on the frame being saved.
        if state.videoPlaying { state.stopPlayback() }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "crt export \(exportTimestamp).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // The render itself lives in AppState so the headless export check
        // drives exactly what this button does.
        state.exportPNG(to: url, size: outputSize)
    }

    // MARK: - viewport (the preview as drawn)

    /// "1,412 × 1,412 screen pixels" — what the preview shows right now.
    private var viewportCaption: String {
        guard let size = state.viewportPixelSize else { return "As shown, at screen pixels" }
        return "\(size.width.formatted()) × \(size.height.formatted()) screen pixels"
    }

    private func exportViewport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "crt viewport \(exportTimestamp).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.exportViewport(to: url)
    }

    // MARK: - GIF, a clip, or a video from a still

    /// The movie button: pick a file, then AppState's export (shared with
    /// `NTSCRT render`) does the rest.
    private func exportMovie() {
        guard state.sourceTexture != nil, state.chain != nil else { return }
        let gif = state.exportFormat.isGIF
        let ext = gif ? "gif" : (state.exportFormat.codec ?? .h264).fileExtension
        let panel = NSSavePanel()
        panel.allowedContentTypes = [gif ? .gif : (state.exportFormat.isProRes ? .quickTimeMovie : .mpeg4Movie)]
        panel.nameFieldStringValue = "crt export \(exportTimestamp).\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.runMovieExport(to: url)
    }
}
